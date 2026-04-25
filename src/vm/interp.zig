const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;

const Dict = @import("../object/dict.zig").Dict;
const Code = @import("../object/code.zig").Code;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Instance = @import("../object/instance.zig").Instance;
const Module = @import("../object/module.zig").Module;
const Frame = @import("frame.zig").Frame;
const dispatch = @import("dispatch.zig");
const builtins = @import("builtins.zig");
const asyncio_mod = @import("asyncio.zig");
const importlib_mod = @import("importlib.zig");
const functools_mod = @import("functools_mod.zig");
const itertools_mod = @import("itertools_mod.zig");
const operator_mod = @import("operator_mod.zig");
const collections_mod = @import("collections_mod.zig");
const math_mod = @import("math_mod.zig");
const heapq_mod = @import("heapq_mod.zig");
const bisect_mod = @import("bisect_mod.zig");
const random_mod = @import("random_mod.zig");

pub const Interp = struct {
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    globals: *Dict,
    builtins: *Dict,
    /// The live Python exception, or null. Set by `raisePy` (or
    /// directly by RAISE_VARARGS) before the dispatch loop sees
    /// `error.PyException`; the exception-table catch loop reads it.
    current_exc: ?Value = null,
    /// The value produced by the most recent YIELD_VALUE. Read by the
    /// generator-send wrapper after `error.GenYield` escapes dispatch.
    gen_yielded: ?Value = null,
    /// Cached builtin modules. Lazily built on first import so a
    /// script that doesn't reach for them pays nothing.
    asyncio_module: ?*Module = null,
    importlib_module: ?*Module = null,
    functools_module: ?*Module = null,
    itertools_module: ?*Module = null,
    operator_module: ?*Module = null,
    collections_module: ?*Module = null,
    math_module: ?*Module = null,
    heapq_module: ?*Module = null,
    bisect_module: ?*Module = null,
    random_module: ?*Module = null,
    /// Pre-registered user-module code objects, keyed by module name.
    /// Populated by the embedder (the test harness pre-registers every
    /// helper `.pyc`; the CLI pre-registers siblings of the entry
    /// `.pyc`). Looked up on IMPORT_NAME after builtins.
    module_codes: std.StringHashMapUnmanaged(ModuleCode) = .empty,
    /// Already-executed user modules, keyed by name. First import runs
    /// the body; subsequent imports return the cached `*Module` so
    /// identity holds (e.g. `import x as a; import x as b; a is b`).
    user_modules: std.StringHashMapUnmanaged(*Module) = .empty,
    /// The synthetic class returned by `type(some_module)`. Built
    /// lazily so scripts that never call `type()` on a module pay
    /// nothing. CPython's spelling of this is `types.ModuleType`; we
    /// expose it directly off `type()` because that's all the
    /// fixtures probe.
    module_type: ?*@import("../object/class.zig").Class = null,
    /// Same lazy-cached pattern for `type(complex_val)` so the result
    /// has `.__name__ == "complex"`. The builtin `complex` name itself
    /// stays bound to a constructor function; this class is only
    /// reachable via `type()`.
    complex_type: ?*@import("../object/class.zig").Class = null,
    /// Lazy `type(set_val)` / `type(frozenset_val)` classes. The
    /// builtin `set`/`frozenset` names are constructors; these are
    /// only the synthetic classes that `type()` returns.
    set_type: ?*@import("../object/class.zig").Class = null,
    frozenset_type: ?*@import("../object/class.zig").Class = null,
    bytearray_type: ?*@import("../object/class.zig").Class = null,
    bytes_type: ?*@import("../object/class.zig").Class = null,
    memoryview_type: ?*@import("../object/class.zig").Class = null,
    ellipsis_type: ?*@import("../object/class.zig").Class = null,
    not_implemented_type: ?*@import("../object/class.zig").Class = null,
    slice_type: ?*@import("../object/class.zig").Class = null,

    pub const ModuleCode = struct { code: *Code, is_package: bool };

    pub fn init(
        allocator: std.mem.Allocator,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !Interp {
        return .{
            .allocator = allocator,
            .stdout = stdout,
            .stderr = stderr,
            .globals = try Dict.init(allocator),
            .builtins = try Dict.init(allocator),
        };
    }

    pub fn installBuiltins(self: *Interp) !void {
        try builtins.install(self);
    }

    pub fn registerBuiltin(self: *Interp, name: []const u8, func: BuiltinFnPtr) !void {
        const f = try self.allocator.create(BuiltinFn);
        f.* = .{ .name = name, .func = func };
        try self.builtins.setStr(self.allocator, name, Value{ .builtin_fn = f });
    }

    pub fn registerBuiltinKw(
        self: *Interp,
        name: []const u8,
        func: BuiltinFnPtr,
        kw_func: value_mod.BuiltinKwFnPtr,
    ) !void {
        const f = try self.allocator.create(BuiltinFn);
        f.* = .{ .name = name, .func = func, .kw_func = kw_func };
        try self.builtins.setStr(self.allocator, name, Value{ .builtin_fn = f });
    }

    pub fn run(self: *Interp, code: *Code) !Value {
        // Module frame: locals alias globals at the module level.
        const frame = try Frame.init(self.allocator, code, self.globals, self.builtins, self.globals);
        defer frame.deinit(self.allocator);

        // Seed __name__ = "__main__" for scripts that test it.
        const name_str_mod = @import("../object/string.zig");
        const name_val = try name_str_mod.Str.init(self.allocator, "__main__");
        try self.globals.setStr(self.allocator, "__name__", Value{ .str = name_val });

        return try dispatch.run(self, frame);
    }

    pub fn nameError(self: *Interp, name: []const u8) !void {
        try self.stderr.print("NameError: name '{s}' is not defined\n", .{name});
        try self.stderr.flush();
    }

    pub fn attributeError(self: *Interp, type_name: []const u8, attr: []const u8) !void {
        try self.stderr.print(
            "AttributeError: '{s}' object has no attribute '{s}'\n",
            .{ type_name, attr },
        );
        try self.stderr.flush();
    }

    pub fn indexError(self: *Interp, msg: []const u8) !void {
        try self.stderr.print("IndexError: {s}\n", .{msg});
        try self.stderr.flush();
    }

    pub fn typeError(self: *Interp, msg: []const u8) !void {
        try self.stderr.print("TypeError: {s}\n", .{msg});
        try self.stderr.flush();
    }

    /// Build an exception instance of `cls_name` with `args = (msg,)`
    /// and stash it as `current_exc`. The caller still has to return
    /// `error.PyException` to kick the dispatch unwind.
    pub fn raisePy(self: *Interp, cls_name: []const u8, msg: []const u8) !void {
        const cls_val = self.builtins.getStr(cls_name) orelse {
            try self.stderr.print("zag: missing exception class '{s}'\n", .{cls_name});
            try self.stderr.flush();
            return error.NameError;
        };
        if (cls_val != .class) return error.TypeError;
        const inst = try Instance.init(self.allocator, cls_val.class);
        const t = try Tuple.init(self.allocator, 1);
        const s = try Str.init(self.allocator, msg);
        t.items[0] = Value{ .str = s };
        try inst.dict.setStr(self.allocator, "args", Value{ .tuple = t });
        self.current_exc = Value{ .instance = inst };
    }

    /// Like `raisePy` but takes a Value for `args[0]` (e.g., the
    /// generator's return value flowing into StopIteration).
    pub fn raisePyValue(self: *Interp, cls_name: []const u8, val: Value) !void {
        const cls_val = self.builtins.getStr(cls_name) orelse {
            try self.stderr.print("zag: missing exception class '{s}'\n", .{cls_name});
            try self.stderr.flush();
            return error.NameError;
        };
        if (cls_val != .class) return error.TypeError;
        const inst = try Instance.init(self.allocator, cls_val.class);
        const t = try Tuple.init(self.allocator, 1);
        t.items[0] = val;
        try inst.dict.setStr(self.allocator, "args", Value{ .tuple = t });
        self.current_exc = Value{ .instance = inst };
    }

    pub fn importError(self: *Interp, name: []const u8) !void {
        try self.stderr.print("ImportError: no module named '{s}'\n", .{name});
        try self.stderr.flush();
    }

    /// Register a pre-loaded `.pyc` so that `import name` finds it.
    /// The body isn't run until something actually imports it.
    /// `is_package` is true for `__init__.py` modules, which then host
    /// submodule attributes.
    pub fn registerModuleCode(
        self: *Interp,
        name: []const u8,
        code: *Code,
        is_package: bool,
    ) !void {
        try self.module_codes.put(self.allocator, name, .{ .code = code, .is_package = is_package });
    }

    /// Load a single (non-dotted) module from its registered code,
    /// caching the result. Returns null if not registered. Internal
    /// helper for `loadModuleChain` — callers wanting dotted-name
    /// resolution (the import opcodes) go through that instead.
    fn loadOneModule(self: *Interp, name: []const u8) !?*Module {
        if (self.user_modules.get(name)) |m| return m;
        const reg = self.module_codes.get(name) orelse return null;
        const mod_globals = try Dict.init(self.allocator);
        const name_val = try Str.init(self.allocator, name);
        try mod_globals.setStr(self.allocator, "__name__", Value{ .str = name_val });
        // CPython sets __package__ to the parent dotted name (or "" at
        // top level). Packages set it to their own name. Relative
        // imports inside the body read this back.
        const dot = std.mem.lastIndexOfScalar(u8, name, '.');
        const pkg: []const u8 = if (reg.is_package)
            name
        else if (dot) |d| name[0..d] else "";
        const pkg_val = try Str.init(self.allocator, pkg);
        try mod_globals.setStr(self.allocator, "__package__", Value{ .str = pkg_val });
        const m = try Module.init(self.allocator, name);
        m.attrs = mod_globals;
        m.is_package = reg.is_package;
        // Insert before running the body so a circular re-import
        // returns the partially-populated module rather than looping.
        try self.user_modules.put(self.allocator, name, m);
        const frame = try Frame.init(self.allocator, reg.code, mod_globals, self.builtins, mod_globals);
        defer frame.deinit(self.allocator);
        _ = dispatch.run(self, frame) catch |err| {
            _ = self.user_modules.remove(name);
            return err;
        };
        return m;
    }

    pub const Chain = struct { top: *Module, innermost: *Module };

    /// Load every prefix of a dotted name, binding each leaf as an
    /// attribute on its parent. Returns the outermost (`top`) and
    /// innermost (`innermost`) modules — IMPORT_NAME picks one based
    /// on whether the fromlist is empty.
    pub fn loadModuleChain(self: *Interp, qname: []const u8) !?Chain {
        var top: ?*Module = null;
        var innermost: ?*Module = null;
        var i: usize = 0;
        while (true) {
            const next = std.mem.indexOfScalarPos(u8, qname, i, '.');
            const end = next orelse qname.len;
            const sub = qname[0..end];
            const m = (try self.loadOneModule(sub)) orelse return null;
            if (top == null) top = m;
            if (innermost) |parent| {
                try parent.attrs.setStr(self.allocator, sub[i..end], Value{ .module = m });
            }
            innermost = m;
            if (next == null) break;
            i = next.? + 1;
        }
        return Chain{ .top = top.?, .innermost = innermost.? };
    }

    /// Hand back the builtin module of the given name. Cached on
    /// first access so identity holds across re-imports.
    pub fn getBuiltinModule(self: *Interp, name: []const u8) ?*Module {
        if (std.mem.eql(u8, name, "asyncio")) {
            if (self.asyncio_module) |m| return m;
            const m = asyncio_mod.build(self) catch return null;
            self.asyncio_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "importlib")) {
            if (self.importlib_module) |m| return m;
            const m = importlib_mod.build(self) catch return null;
            self.importlib_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "functools")) {
            if (self.functools_module) |m| return m;
            const m = functools_mod.build(self) catch return null;
            self.functools_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "itertools")) {
            if (self.itertools_module) |m| return m;
            const m = itertools_mod.build(self) catch return null;
            self.itertools_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "operator")) {
            if (self.operator_module) |m| return m;
            const m = operator_mod.build(self) catch return null;
            self.operator_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "collections")) {
            if (self.collections_module) |m| return m;
            const m = collections_mod.build(self) catch return null;
            self.collections_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "math")) {
            if (self.math_module) |m| return m;
            const m = math_mod.build(self) catch return null;
            self.math_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "heapq")) {
            if (self.heapq_module) |m| return m;
            const m = heapq_mod.build(self) catch return null;
            self.heapq_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "bisect")) {
            if (self.bisect_module) |m| return m;
            const m = bisect_mod.build(self) catch return null;
            self.bisect_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "random")) {
            if (self.random_module) |m| return m;
            const m = random_mod.build(self) catch return null;
            self.random_module = m;
            return m;
        }
        return null;
    }

    pub fn unsupportedOpcode(self: *Interp, opcode: u8, ip: u32) !void {
        const op = @import("../op/opcode.zig");
        try self.stderr.print(
            "zag: unsupported opcode {d} ({s}) at ip={d}\n",
            .{ opcode, op.opcodeName(opcode), ip },
        );
        try self.stderr.flush();
    }
};
