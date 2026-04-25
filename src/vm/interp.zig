const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;

const Dict = @import("../object/dict.zig").Dict;
const Code = @import("../object/code.zig").Code;
const Frame = @import("frame.zig").Frame;
const dispatch = @import("dispatch.zig");
const builtins = @import("builtins.zig");

pub const Interp = struct {
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    globals: *Dict,
    builtins: *Dict,

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

    pub fn unsupportedOpcode(self: *Interp, opcode: u8, ip: u32) !void {
        const op = @import("../op/opcode.zig");
        try self.stderr.print(
            "zag: unsupported opcode {d} ({s}) at ip={d}\n",
            .{ opcode, op.opcodeName(opcode), ip },
        );
        try self.stderr.flush();
    }
};
