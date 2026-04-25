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
    /// Cached builtin modules. Today only `asyncio`; lazily built on
    /// first IMPORT_NAME so a script that doesn't import it pays
    /// nothing.
    asyncio_module: ?*Module = null,
    /// Pre-registered user-module code objects, keyed by module name.
    /// Populated by the embedder (the test harness pre-registers every
    /// helper `.pyc`; the CLI pre-registers siblings of the entry
    /// `.pyc`). Looked up on IMPORT_NAME after builtins.
    module_codes: std.StringHashMapUnmanaged(*Code) = .empty,
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
    /// The body isn't run until something actually imports it; this
    /// only stashes the code object.
    pub fn registerModuleCode(self: *Interp, name: []const u8, code: *Code) !void {
        try self.module_codes.put(self.allocator, name, code);
    }

    /// Drive a user module to first execution and cache it. Subsequent
    /// imports of the same name return this cached `*Module`. Returns
    /// null if the name isn't pre-registered; the caller decides how
    /// to surface that (today: ImportError).
    pub fn loadUserModule(self: *Interp, name: []const u8) !?*Module {
        if (self.user_modules.get(name)) |m| return m;
        const code = self.module_codes.get(name) orelse return null;
        const mod_globals = try Dict.init(self.allocator);
        const name_val = try Str.init(self.allocator, name);
        try mod_globals.setStr(self.allocator, "__name__", Value{ .str = name_val });
        const m = try Module.init(self.allocator, name);
        m.attrs = mod_globals;
        // Insert before running the body so a circular re-import
        // returns the partially-populated module rather than looping.
        try self.user_modules.put(self.allocator, name, m);
        const frame = try Frame.init(self.allocator, code, mod_globals, self.builtins, mod_globals);
        defer frame.deinit(self.allocator);
        _ = dispatch.run(self, frame) catch |err| {
            _ = self.user_modules.remove(name);
            return err;
        };
        return m;
    }

    /// Hand back the builtin module of the given name (today: just
    /// `asyncio`). Cached on first access so identity holds across
    /// re-imports.
    pub fn getBuiltinModule(self: *Interp, name: []const u8) ?*Module {
        if (std.mem.eql(u8, name, "asyncio")) {
            if (self.asyncio_module) |m| return m;
            const m = asyncio_mod.build(self) catch return null;
            self.asyncio_module = m;
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
