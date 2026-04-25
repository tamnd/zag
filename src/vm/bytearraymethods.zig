//! Method table for `bytearray`. Mutating methods live here; shared
//! bytes/bytearray methods come from `bytesmethods` via fallback.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Interp = @import("interp.zig").Interp;
const bytesmethods = @import("bytesmethods.zig");

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

fn clearImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    args[0].bytearray.data.clearRetainingCapacity();
    return Value.none;
}

fn reverseImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    std.mem.reverse(u8, args[0].bytearray.data.items);
    return Value.none;
}

fn insertImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const ba = args[0].bytearray;
    if (args[1] != .small_int and args[1] != .boolean) {
        try interp.typeError("insert() index must be an integer");
        return error.TypeError;
    }
    var idx: i64 = if (args[1] == .boolean) @intFromBool(args[1].boolean) else args[1].small_int;
    const n: i64 = @intCast(ba.data.items.len);
    if (idx < 0) idx += n;
    if (idx < 0) idx = 0;
    if (idx > n) idx = n;
    const byte = try coerceByte(interp, args[2]);
    try ba.data.insert(interp.allocator, @intCast(idx), byte);
    return Value.none;
}

fn removeImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const ba = args[0].bytearray;
    const byte = try coerceByte(interp, args[1]);
    if (std.mem.indexOfScalar(u8, ba.data.items, byte)) |idx| {
        _ = ba.data.orderedRemove(idx);
        return Value.none;
    }
    try interp.raisePy("ValueError", "value not found in bytearray");
    return error.PyException;
}

var append_entry: BuiltinFn = .{ .name = "append", .func = appendImpl };
var extend_entry: BuiltinFn = .{ .name = "extend", .func = extendImpl };
var pop_entry: BuiltinFn = .{ .name = "pop", .func = popImpl };
var clear_entry: BuiltinFn = .{ .name = "clear", .func = clearImpl };
var reverse_entry: BuiltinFn = .{ .name = "reverse", .func = reverseImpl };
var insert_entry: BuiltinFn = .{ .name = "insert", .func = insertImpl };
var remove_entry: BuiltinFn = .{ .name = "remove", .func = removeImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "append")) return &append_entry;
    if (std.mem.eql(u8, name, "extend")) return &extend_entry;
    if (std.mem.eql(u8, name, "pop")) return &pop_entry;
    if (std.mem.eql(u8, name, "clear")) return &clear_entry;
    if (std.mem.eql(u8, name, "reverse")) return &reverse_entry;
    if (std.mem.eql(u8, name, "insert")) return &insert_entry;
    if (std.mem.eql(u8, name, "remove")) return &remove_entry;
    return bytesmethods.lookup(name);
}
