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

fn bytesLike(v: Value) ?[]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        else => null,
    };
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

fn countImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const hay = args[0].bytearray.data.items;
    const needle = bytesLike(args[1]) orelse {
        try interp.typeError("count() argument must be bytes-like");
        return error.TypeError;
    };
    if (needle.len == 0) return Value{ .small_int = @intCast(hay.len + 1) };
    var n: i64 = 0;
    var i: usize = 0;
    while (i + needle.len <= hay.len) {
        if (std.mem.eql(u8, hay[i .. i + needle.len], needle)) {
            n += 1;
            i += needle.len;
        } else i += 1;
    }
    return Value{ .small_int = n };
}

fn findImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const hay = args[0].bytearray.data.items;
    const needle = bytesLike(args[1]) orelse {
        try interp.typeError("find() argument must be bytes-like");
        return error.TypeError;
    };
    if (std.mem.indexOf(u8, hay, needle)) |idx| return Value{ .small_int = @intCast(idx) };
    return Value{ .small_int = -1 };
}

fn indexImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const hay = args[0].bytearray.data.items;
    const needle = bytesLike(args[1]) orelse {
        try interp.typeError("index() argument must be bytes-like");
        return error.TypeError;
    };
    if (std.mem.indexOf(u8, hay, needle)) |idx| return Value{ .small_int = @intCast(idx) };
    try interp.raisePy("ValueError", "subsection not found");
    return error.PyException;
}

fn startswithImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const hay = args[0].bytearray.data.items;
    const needle = bytesLike(args[1]) orelse {
        try interp.typeError("startswith() argument must be bytes-like");
        return error.TypeError;
    };
    return Value{ .boolean = std.mem.startsWith(u8, hay, needle) };
}

fn endswithImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const hay = args[0].bytearray.data.items;
    const needle = bytesLike(args[1]) orelse {
        try interp.typeError("endswith() argument must be bytes-like");
        return error.TypeError;
    };
    return Value{ .boolean = std.mem.endsWith(u8, hay, needle) };
}

fn replaceImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const Bytearray = @import("../object/bytearray.zig").Bytearray;
    const hay = args[0].bytearray.data.items;
    const old = bytesLike(args[1]) orelse {
        try interp.typeError("replace() arguments must be bytes-like");
        return error.TypeError;
    };
    const new = bytesLike(args[2]) orelse {
        try interp.typeError("replace() arguments must be bytes-like");
        return error.TypeError;
    };
    const out = try Bytearray.init(interp.allocator);
    if (old.len == 0) {
        try out.data.appendSlice(interp.allocator, hay);
        return Value{ .bytearray = out };
    }
    var i: usize = 0;
    while (i < hay.len) {
        if (i + old.len <= hay.len and std.mem.eql(u8, hay[i .. i + old.len], old)) {
            try out.data.appendSlice(interp.allocator, new);
            i += old.len;
        } else {
            try out.data.append(interp.allocator, hay[i]);
            i += 1;
        }
    }
    return Value{ .bytearray = out };
}

fn splitImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const Bytearray = @import("../object/bytearray.zig").Bytearray;
    const List = @import("../object/list.zig").List;
    const hay = args[0].bytearray.data.items;
    const sep = if (args.len >= 2) (bytesLike(args[1]) orelse {
        try interp.typeError("split() separator must be bytes-like");
        return error.TypeError;
    }) else {
        try interp.typeError("split(None) on bytearray not supported in zag");
        return error.TypeError;
    };
    const out = try List.init(interp.allocator);
    if (sep.len == 0) {
        try interp.raisePy("ValueError", "empty separator");
        return error.PyException;
    }
    var i: usize = 0;
    var start: usize = 0;
    while (i + sep.len <= hay.len) {
        if (std.mem.eql(u8, hay[i .. i + sep.len], sep)) {
            const piece = try Bytearray.fromSlice(interp.allocator, hay[start..i]);
            try out.append(interp.allocator, Value{ .bytearray = piece });
            i += sep.len;
            start = i;
        } else i += 1;
    }
    const tail = try Bytearray.fromSlice(interp.allocator, hay[start..]);
    try out.append(interp.allocator, Value{ .bytearray = tail });
    return Value{ .list = out };
}

var append_entry: BuiltinFn = .{ .name = "append", .func = appendImpl };
var extend_entry: BuiltinFn = .{ .name = "extend", .func = extendImpl };
var pop_entry: BuiltinFn = .{ .name = "pop", .func = popImpl };
var hex_entry: BuiltinFn = .{ .name = "hex", .func = hexImpl };
var decode_entry: BuiltinFn = .{ .name = "decode", .func = decodeImpl };
var clear_entry: BuiltinFn = .{ .name = "clear", .func = clearImpl };
var reverse_entry: BuiltinFn = .{ .name = "reverse", .func = reverseImpl };
var insert_entry: BuiltinFn = .{ .name = "insert", .func = insertImpl };
var remove_entry: BuiltinFn = .{ .name = "remove", .func = removeImpl };
var count_entry: BuiltinFn = .{ .name = "count", .func = countImpl };
var find_entry: BuiltinFn = .{ .name = "find", .func = findImpl };
var index_entry: BuiltinFn = .{ .name = "index", .func = indexImpl };
var startswith_entry: BuiltinFn = .{ .name = "startswith", .func = startswithImpl };
var endswith_entry: BuiltinFn = .{ .name = "endswith", .func = endswithImpl };
var replace_entry: BuiltinFn = .{ .name = "replace", .func = replaceImpl };
var split_entry: BuiltinFn = .{ .name = "split", .func = splitImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "append")) return &append_entry;
    if (std.mem.eql(u8, name, "extend")) return &extend_entry;
    if (std.mem.eql(u8, name, "pop")) return &pop_entry;
    if (std.mem.eql(u8, name, "hex")) return &hex_entry;
    if (std.mem.eql(u8, name, "decode")) return &decode_entry;
    if (std.mem.eql(u8, name, "clear")) return &clear_entry;
    if (std.mem.eql(u8, name, "reverse")) return &reverse_entry;
    if (std.mem.eql(u8, name, "insert")) return &insert_entry;
    if (std.mem.eql(u8, name, "remove")) return &remove_entry;
    if (std.mem.eql(u8, name, "count")) return &count_entry;
    if (std.mem.eql(u8, name, "find")) return &find_entry;
    if (std.mem.eql(u8, name, "index")) return &index_entry;
    if (std.mem.eql(u8, name, "startswith")) return &startswith_entry;
    if (std.mem.eql(u8, name, "endswith")) return &endswith_entry;
    if (std.mem.eql(u8, name, "replace")) return &replace_entry;
    if (std.mem.eql(u8, name, "split")) return &split_entry;
    return null;
}
