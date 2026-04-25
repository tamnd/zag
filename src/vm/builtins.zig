const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Interp = @import("interp.zig").Interp;

pub const BuiltinError = error{
    BadArgument,
    OutOfMemory,
    WriteFailed,
};

pub fn print(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const w = interp.stdout;
    for (args, 0..) |a, i| {
        if (i != 0) try w.writeByte(' ');
        try a.writeStr(w);
    }
    try w.writeByte('\n');
    try w.flush();
    return Value.none;
}

pub fn install(interp: *Interp) !void {
    try interp.registerBuiltin("print", print);
}
