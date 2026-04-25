//! Method table for `list`. Same convention as strmethods: each
//! function takes (interp, args) where args[0] is self.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Interp = @import("interp.zig").Interp;

fn appendImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    try args[0].list.append(interp.allocator, args[1]);
    return Value.none;
}

fn extendImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const dst = args[0].list;
    switch (args[1]) {
        .list => |l| for (l.items.items) |it| try dst.append(interp.allocator, it),
        .tuple => |t| for (t.items) |it| try dst.append(interp.allocator, it),
        else => {
            try interp.typeError("extend() argument must be iterable");
            return error.TypeError;
        },
    }
    return Value.none;
}

fn popImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const lst = args[0].list;
    if (lst.items.items.len == 0) {
        try interp.indexError("pop from empty list");
        return error.IndexError;
    }
    return lst.items.pop().?;
}

fn reverseImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const items = args[0].list.items.items;
    std.mem.reverse(Value, items);
    return Value.none;
}

var append_entry: BuiltinFn = .{ .name = "append", .func = appendImpl };
var extend_entry: BuiltinFn = .{ .name = "extend", .func = extendImpl };
var pop_entry: BuiltinFn = .{ .name = "pop", .func = popImpl };
var reverse_entry: BuiltinFn = .{ .name = "reverse", .func = reverseImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "append")) return &append_entry;
    if (std.mem.eql(u8, name, "extend")) return &extend_entry;
    if (std.mem.eql(u8, name, "pop")) return &pop_entry;
    if (std.mem.eql(u8, name, "reverse")) return &reverse_entry;
    return null;
}
