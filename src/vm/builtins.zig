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

pub fn absBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.stderr.print(
            "TypeError: abs() takes exactly one argument ({d} given)\n",
            .{args.len},
        );
        try interp.stderr.flush();
        return error.TypeError;
    }
    return switch (args[0]) {
        .small_int => |i| Value{ .small_int = if (i < 0) -i else i },
        .float => |f| Value{ .float = if (f < 0) -f else f },
        .boolean => |b| Value{ .small_int = if (b) 1 else 0 },
        else => |v| blk: {
            try interp.stderr.print(
                "TypeError: bad operand type for abs(): '{s}'\n",
                .{v.typeName()},
            );
            try interp.stderr.flush();
            break :blk error.TypeError;
        },
    };
}

pub fn lenBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.stderr.print(
            "TypeError: len() takes exactly one argument ({d} given)\n",
            .{args.len},
        );
        try interp.stderr.flush();
        return error.TypeError;
    }
    return switch (args[0]) {
        .str => |s| Value{ .small_int = @intCast(s.len()) },
        .bytes => |b| Value{ .small_int = @intCast(b.data.len) },
        .tuple => |t| Value{ .small_int = @intCast(t.items.len) },
        .list => |l| Value{ .small_int = @intCast(l.items.items.len) },
        .dict => |d| Value{ .small_int = @intCast(d.count()) },
        else => |v| blk: {
            try interp.stderr.print(
                "TypeError: object of type '{s}' has no len()\n",
                .{v.typeName()},
            );
            try interp.stderr.flush();
            break :blk error.TypeError;
        },
    };
}

pub fn install(interp: *Interp) !void {
    try interp.registerBuiltin("print", print);
    try interp.registerBuiltin("abs", absBuiltin);
    try interp.registerBuiltin("len", lenBuiltin);
}
