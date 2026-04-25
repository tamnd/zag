//! Pinhole `os`. Just enough surface for fixtures: `remove`/`unlink`.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "os");
    try reg(interp, m, "remove", removeFn);
    try reg(interp, m, "unlink", removeFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn removeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("os.remove expects a path");
        return error.TypeError;
    }
    std.Io.Dir.cwd().deleteFile(interp.io, args[0].str.bytes) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", args[0].str.bytes);
            return error.PyException;
        },
        else => return err,
    };
    return Value.none;
}
