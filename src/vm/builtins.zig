const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Interp = @import("interp.zig").Interp;
const List = @import("../object/list.zig").List;
const Iter = @import("../object/iter.zig").Iter;

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

fn iterableItems(v: Value) ?[]const Value {
    return switch (v) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => null,
    };
}

pub fn sumBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const items = iterableItems(args[0]) orelse {
        try interp.typeError("sum() argument must be iterable");
        return error.TypeError;
    };
    var acc: i64 = 0;
    for (items) |it| {
        switch (it) {
            .small_int => |i| acc += i,
            .boolean => |b| acc += @intFromBool(b),
            else => {
                try interp.typeError("unsupported operand type for +");
                return error.TypeError;
            },
        }
    }
    return Value{ .small_int = acc };
}

pub fn sortedBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const items = iterableItems(args[0]) orelse {
        try interp.typeError("sorted() argument must be iterable");
        return error.TypeError;
    };
    const out = try List.init(interp.allocator);
    for (items) |it| try out.append(interp.allocator, it);
    const slice = out.items.items;
    std.sort.pdq(Value, slice, {}, lessThanForSort);
    return Value{ .list = out };
}

fn lessThanForSort(_: void, a: Value, b: Value) bool {
    if (a.order(b)) |o| return o == .lt;
    return false;
}

/// Python `range(stop)` and `range(start, stop)`. We hand back an
/// `Iter` directly rather than a separate range sequence object —
/// for `for i in range(...):` the distinction is invisible, and
/// fixtures don't yet exercise len/contains/repr on a range.
pub fn rangeBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    var start: i64 = 0;
    var stop: i64 = 0;
    if (args.len == 1) {
        stop = try intArg(interp, args[0]);
    } else if (args.len == 2) {
        start = try intArg(interp, args[0]);
        stop = try intArg(interp, args[1]);
    } else {
        try interp.typeError("range expected 1 or 2 arguments");
        return error.TypeError;
    }
    const it = try Iter.init(interp.allocator, .{ .range = .{
        .current = start,
        .stop = stop,
        .step = 1,
    } });
    return Value{ .iter = it };
}

fn intArg(interp: *Interp, v: Value) !i64 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        else => {
            try interp.typeError("range argument must be int");
            return error.TypeError;
        },
    };
}

pub fn install(interp: *Interp) !void {
    try interp.registerBuiltin("print", print);
    try interp.registerBuiltin("abs", absBuiltin);
    try interp.registerBuiltin("len", lenBuiltin);
    try interp.registerBuiltin("sum", sumBuiltin);
    try interp.registerBuiltin("sorted", sortedBuiltin);
    try interp.registerBuiltin("range", rangeBuiltin);
}
