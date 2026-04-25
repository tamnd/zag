//! Method table for `bytearray`. Same shape as listmethods.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const Str = @import("../object/string.zig").Str;

const Interp = @import("interp.zig").Interp;

fn coerceByte(interp: *Interp, v: Value) !u8 {
    const i: i64 = switch (v) {
        .small_int => |x| x,
        .boolean => |b| @intFromBool(b),
        else => {
            try interp.typeError("an integer is required");
            return error.TypeError;
        },
    };
    if (i < 0 or i > 255) {
        try interp.raisePy("ValueError", "byte must be in range(0, 256)");
        return error.PyException;
    }
    return @intCast(i);
}

fn appendImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const byte = try coerceByte(interp, args[1]);
    try args[0].bytearray.data.append(interp.allocator, byte);
    return Value.none;
}

fn extendImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const dst = args[0].bytearray;
    switch (args[1]) {
        .bytes => |b| try dst.data.appendSlice(interp.allocator, b.data),
        .bytearray => |b| try dst.data.appendSlice(interp.allocator, b.data.items),
        else => {
            const lst = try @import("builtins.zig").materialize(interp, args[1]);
            for (lst.items.items) |x| {
                const byte = try coerceByte(interp, x);
                try dst.data.append(interp.allocator, byte);
            }
        },
    }
    return Value.none;
}

fn popImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const ba = args[0].bytearray;
    const n = ba.data.items.len;
    if (n == 0) {
        try interp.indexError("pop from empty bytearray");
        return error.IndexError;
    }
    var idx: i64 = if (args.len < 2) @as(i64, @intCast(n)) - 1 else switch (args[1]) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        else => {
            try interp.typeError("pop() index must be an integer");
            return error.TypeError;
        },
    };
    if (idx < 0) idx += @intCast(n);
    if (idx < 0 or idx >= @as(i64, @intCast(n))) {
        try interp.indexError("pop index out of range");
        return error.IndexError;
    }
    const byte = ba.data.orderedRemove(@intCast(idx));
    return Value{ .small_int = @intCast(byte) };
}

fn hexImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const data = args[0].bytearray.data.items;
    var buf = try interp.allocator.alloc(u8, data.len * 2);
    const hex = "0123456789abcdef";
    for (data, 0..) |c, i| {
        buf[i * 2] = hex[c >> 4];
        buf[i * 2 + 1] = hex[c & 0xf];
    }
    const s = try Str.fromOwnedSlice(interp.allocator, buf);
    return Value{ .str = s };
}

fn decodeImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const s = try Str.init(interp.allocator, args[0].bytearray.data.items);
    return Value{ .str = s };
}

var append_entry: BuiltinFn = .{ .name = "append", .func = appendImpl };
var extend_entry: BuiltinFn = .{ .name = "extend", .func = extendImpl };
var pop_entry: BuiltinFn = .{ .name = "pop", .func = popImpl };
var hex_entry: BuiltinFn = .{ .name = "hex", .func = hexImpl };
var decode_entry: BuiltinFn = .{ .name = "decode", .func = decodeImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "append")) return &append_entry;
    if (std.mem.eql(u8, name, "extend")) return &extend_entry;
    if (std.mem.eql(u8, name, "pop")) return &pop_entry;
    if (std.mem.eql(u8, name, "hex")) return &hex_entry;
    if (std.mem.eql(u8, name, "decode")) return &decode_entry;
    return null;
}
