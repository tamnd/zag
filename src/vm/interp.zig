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
