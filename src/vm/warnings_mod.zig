//! Pinhole `warnings`: just enough for `warnings.warn(msg, category)`
//! to print a CPython-shaped line to stderr. No filter system.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;

const Module = @import("../object/module.zig").Module;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "warnings");
    try reg(interp, m, "warn", warnFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn warnFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const msg: []const u8 = if (args.len > 0 and args[0] == .str) args[0].str.bytes else "";
    const cat_name: []const u8 = blk: {
        if (args.len >= 2 and args[1] == .class) break :blk args[1].class.name;
        break :blk "UserWarning";
    };
    try interp.stderr.print("{s}: {s}\n", .{ cat_name, msg });
    try interp.stderr.flush();
    return Value.none;
}
