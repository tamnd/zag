//! Shared helpers for bytes/bytearray methods.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;

const Bytes = @import("../object/bytes.zig").Bytes;
const Bytearray = @import("../object/bytearray.zig").Bytearray;
const Str = @import("../object/string.zig").Str;
const List = @import("../object/list.zig").List;
const Interp = @import("interp.zig").Interp;

pub fn dataOf(v: Value) ?[]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        else => null,
    };
}

pub fn isMutable(v: Value) bool {
    return v == .bytearray;
}

pub fn wrap(interp: *Interp, mutable: bool, data: []const u8) !Value {
    if (mutable) {
        const ba = try Bytearray.fromSlice(interp.allocator, data);
        return Value{ .bytearray = ba };
    }
    const b = try Bytes.init(interp.allocator, data);
    return Value{ .bytes = b };
}

pub fn wrapOwned(interp: *Interp, mutable: bool, data: []u8) !Value {
    if (mutable) {
        const ba = try Bytearray.fromSlice(interp.allocator, data);
        interp.allocator.free(data);
        return Value{ .bytearray = ba };
    }
    const b = try Bytes.fromOwnedSlice(interp.allocator, data);
    return Value{ .bytes = b };
}

fn isAsciiSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 11 or c == 12;
}

fn stripChars(args: []const Value) []const u8 {
    if (args.len < 2) return "";
    return dataOf(args[1]) orelse "";
}

pub fn parseHex(allocator: std.mem.Allocator, s: []const u8) !?[]u8 {
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(allocator);
    for (s) |c| if (!isAsciiSpace(c)) try clean.append(allocator, c);
    if (clean.items.len % 2 != 0) return null;
    const out = try allocator.alloc(u8, clean.items.len / 2);
    var i: usize = 0;
    while (i < clean.items.len) : (i += 2) {
        const hi = std.fmt.charToDigit(clean.items[i], 16) catch return null;
        const lo = std.fmt.charToDigit(clean.items[i + 1], 16) catch return null;
        out[i / 2] = (hi << 4) | lo;
    }
    return out;
}

pub fn hexImpl(interp: *Interp, args: []const Value) !Value {
    const data = dataOf(args[0]).?;
    const buf = try interp.allocator.alloc(u8, data.len * 2);
    const hex = "0123456789abcdef";
    for (data, 0..) |c, i| {
        buf[i * 2] = hex[c >> 4];
        buf[i * 2 + 1] = hex[c & 0xf];
    }
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, buf) };
}

pub fn joinImpl(interp: *Interp, args: []const Value) !Value {
    const sep = dataOf(args[0]).?;
    const lst = try @import("builtins.zig").materialize(interp, args[1]);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);
    for (lst.items.items, 0..) |x, i| {
        if (i > 0) try buf.appendSlice(interp.allocator, sep);
        const piece = dataOf(x) orelse {
            try interp.typeError("bytes.join argument must be bytes-like");
            return error.TypeError;
        };
        try buf.appendSlice(interp.allocator, piece);
    }
    const owned = try buf.toOwnedSlice(interp.allocator);
    return wrapOwned(interp, isMutable(args[0]), owned);
}

pub fn stripImpl(interp: *Interp, args: []const Value) !Value {
    const data = dataOf(args[0]).?;
    const chars = stripChars(args);
    var lo: usize = 0;
    var hi: usize = data.len;
    while (lo < hi) : (lo += 1) {
        const c = data[lo];
        const drop = if (chars.len == 0) isAsciiSpace(c) else std.mem.indexOfScalar(u8, chars, c) != null;
        if (!drop) break;
    }
    while (hi > lo) {
        const c = data[hi - 1];
        const drop = if (chars.len == 0) isAsciiSpace(c) else std.mem.indexOfScalar(u8, chars, c) != null;
        if (!drop) break;
        hi -= 1;
    }
    return wrap(interp, isMutable(args[0]), data[lo..hi]);
}

pub fn lstripImpl(interp: *Interp, args: []const Value) !Value {
    const data = dataOf(args[0]).?;
    const chars = stripChars(args);
    var lo: usize = 0;
    while (lo < data.len) : (lo += 1) {
        const c = data[lo];
        const drop = if (chars.len == 0) isAsciiSpace(c) else std.mem.indexOfScalar(u8, chars, c) != null;
        if (!drop) break;
    }
    return wrap(interp, isMutable(args[0]), data[lo..]);
}

pub fn rstripImpl(interp: *Interp, args: []const Value) !Value {
    const data = dataOf(args[0]).?;
    const chars = stripChars(args);
    var hi: usize = data.len;
    while (hi > 0) {
        const c = data[hi - 1];
        const drop = if (chars.len == 0) isAsciiSpace(c) else std.mem.indexOfScalar(u8, chars, c) != null;
        if (!drop) break;
        hi -= 1;
    }
    return wrap(interp, isMutable(args[0]), data[0..hi]);
}

pub fn upperImpl(interp: *Interp, args: []const Value) !Value {
    const data = dataOf(args[0]).?;
    const out = try interp.allocator.alloc(u8, data.len);
    for (data, 0..) |c, i| out[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    return wrapOwned(interp, isMutable(args[0]), out);
}

pub fn lowerImpl(interp: *Interp, args: []const Value) !Value {
    const data = dataOf(args[0]).?;
    const out = try interp.allocator.alloc(u8, data.len);
    for (data, 0..) |c, i| out[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    return wrapOwned(interp, isMutable(args[0]), out);
}

const PadMode = enum { center, ljust, rjust };

fn padFill(args: []const Value) u8 {
    if (args.len >= 3) {
        if (dataOf(args[2])) |d| if (d.len == 1) return d[0];
    }
    return ' ';
}

fn padImpl(interp: *Interp, args: []const Value, mode: PadMode) !Value {
    const data = dataOf(args[0]).?;
    const width: usize = blk: {
        const w = args[1];
        const wi: i64 = switch (w) {
            .small_int => |i| i,
            .boolean => |b| @intFromBool(b),
            else => 0,
        };
        if (wi <= @as(i64, @intCast(data.len))) break :blk data.len;
        break :blk @intCast(wi);
    };
    const pad_total = width - data.len;
    const fill = padFill(args);
    const out = try interp.allocator.alloc(u8, width);
    switch (mode) {
        .center => {
            const left = pad_total / 2;
            // CPython: extra pad goes on the right when total is odd.
            const right = pad_total - left;
            @memset(out[0..left], fill);
            @memcpy(out[left .. left + data.len], data);
            @memset(out[left + data.len .. left + data.len + right], fill);
        },
        .ljust => {
            @memcpy(out[0..data.len], data);
            @memset(out[data.len..], fill);
        },
        .rjust => {
            @memset(out[0..pad_total], fill);
            @memcpy(out[pad_total..], data);
        },
    }
    return wrapOwned(interp, isMutable(args[0]), out);
}

pub fn centerImpl(interp: *Interp, args: []const Value) !Value {
    return padImpl(interp, args, .center);
}
pub fn ljustImpl(interp: *Interp, args: []const Value) !Value {
    return padImpl(interp, args, .ljust);
}
pub fn rjustImpl(interp: *Interp, args: []const Value) !Value {
    return padImpl(interp, args, .rjust);
}

pub fn zfillImpl(interp: *Interp, args: []const Value) !Value {
    const data = dataOf(args[0]).?;
    const wi: i64 = switch (args[1]) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        else => 0,
    };
    if (wi <= @as(i64, @intCast(data.len))) return wrap(interp, isMutable(args[0]), data);
    const width: usize = @intCast(wi);
    const out = try interp.allocator.alloc(u8, width);
    const has_sign = data.len > 0 and (data[0] == '+' or data[0] == '-');
    const pad_total = width - data.len;
    if (has_sign) {
        out[0] = data[0];
        @memset(out[1 .. 1 + pad_total], '0');
        @memcpy(out[1 + pad_total ..], data[1..]);
    } else {
        @memset(out[0..pad_total], '0');
        @memcpy(out[pad_total..], data);
    }
    return wrapOwned(interp, isMutable(args[0]), out);
}

pub fn countImpl(interp: *Interp, args: []const Value) !Value {
    const hay = dataOf(args[0]).?;
    const needle = dataOf(args[1]) orelse {
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

pub fn findImpl(interp: *Interp, args: []const Value) !Value {
    const hay = dataOf(args[0]).?;
    const needle = dataOf(args[1]) orelse {
        try interp.typeError("find() argument must be bytes-like");
        return error.TypeError;
    };
    if (std.mem.indexOf(u8, hay, needle)) |idx| return Value{ .small_int = @intCast(idx) };
    return Value{ .small_int = -1 };
}

pub fn rfindImpl(interp: *Interp, args: []const Value) !Value {
    const hay = dataOf(args[0]).?;
    const needle = dataOf(args[1]) orelse {
        try interp.typeError("rfind() argument must be bytes-like");
        return error.TypeError;
    };
    if (std.mem.lastIndexOf(u8, hay, needle)) |idx| return Value{ .small_int = @intCast(idx) };
    return Value{ .small_int = -1 };
}

pub fn indexImpl(interp: *Interp, args: []const Value) !Value {
    const hay = dataOf(args[0]).?;
    const needle = dataOf(args[1]) orelse {
        try interp.typeError("index() argument must be bytes-like");
        return error.TypeError;
    };
    if (std.mem.indexOf(u8, hay, needle)) |idx| return Value{ .small_int = @intCast(idx) };
    try interp.raisePy("ValueError", "subsection not found");
    return error.PyException;
}

pub fn startswithImpl(interp: *Interp, args: []const Value) !Value {
    const hay = dataOf(args[0]).?;
    const needle = dataOf(args[1]) orelse {
        try interp.typeError("startswith() argument must be bytes-like");
        return error.TypeError;
    };
    return Value{ .boolean = std.mem.startsWith(u8, hay, needle) };
}

pub fn endswithImpl(interp: *Interp, args: []const Value) !Value {
    const hay = dataOf(args[0]).?;
    const needle = dataOf(args[1]) orelse {
        try interp.typeError("endswith() argument must be bytes-like");
        return error.TypeError;
    };
    return Value{ .boolean = std.mem.endsWith(u8, hay, needle) };
}

pub fn replaceImpl(interp: *Interp, args: []const Value) !Value {
    const hay = dataOf(args[0]).?;
    const old = dataOf(args[1]) orelse {
        try interp.typeError("replace() arguments must be bytes-like");
        return error.TypeError;
    };
    const new = dataOf(args[2]) orelse {
        try interp.typeError("replace() arguments must be bytes-like");
        return error.TypeError;
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);
    if (old.len == 0) {
        try buf.appendSlice(interp.allocator, hay);
    } else {
        var i: usize = 0;
        while (i < hay.len) {
            if (i + old.len <= hay.len and std.mem.eql(u8, hay[i .. i + old.len], old)) {
                try buf.appendSlice(interp.allocator, new);
                i += old.len;
            } else {
                try buf.append(interp.allocator, hay[i]);
                i += 1;
            }
        }
    }
    const owned = try buf.toOwnedSlice(interp.allocator);
    return wrapOwned(interp, isMutable(args[0]), owned);
}

pub fn splitImpl(interp: *Interp, args: []const Value) !Value {
    const hay = dataOf(args[0]).?;
    const mutable = isMutable(args[0]);
    const out = try List.init(interp.allocator);
    if (args.len < 2 or args[1] == .none) {
        // Split on runs of ASCII whitespace.
        var i: usize = 0;
        while (i < hay.len) {
            while (i < hay.len and isAsciiSpace(hay[i])) : (i += 1) {}
            if (i >= hay.len) break;
            const start = i;
            while (i < hay.len and !isAsciiSpace(hay[i])) : (i += 1) {}
            try out.append(interp.allocator, try wrap(interp, mutable, hay[start..i]));
        }
        return Value{ .list = out };
    }
    const sep = dataOf(args[1]) orelse {
        try interp.typeError("split() separator must be bytes-like");
        return error.TypeError;
    };
    if (sep.len == 0) {
        try interp.raisePy("ValueError", "empty separator");
        return error.PyException;
    }
    var i: usize = 0;
    var start: usize = 0;
    while (i + sep.len <= hay.len) {
        if (std.mem.eql(u8, hay[i .. i + sep.len], sep)) {
            try out.append(interp.allocator, try wrap(interp, mutable, hay[start..i]));
            i += sep.len;
            start = i;
        } else i += 1;
    }
    try out.append(interp.allocator, try wrap(interp, mutable, hay[start..]));
    return Value{ .list = out };
}

pub fn decodeImpl(interp: *Interp, args: []const Value) !Value {
    const data = dataOf(args[0]).?;
    return Value{ .str = try Str.init(interp.allocator, data) };
}

pub fn fromhexImpl(
    interp_opaque: *anyopaque,
    args: []const Value,
    _: []const Value,
    _: []const Value,
) anyerror!Value {
    return fromhexCore(interp_opaque, args, false);
}

pub fn fromhexBytearrayImpl(
    interp_opaque: *anyopaque,
    args: []const Value,
    _: []const Value,
    _: []const Value,
) anyerror!Value {
    return fromhexCore(interp_opaque, args, true);
}

pub fn fromhexPos(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return fromhexCore(interp_opaque, args, false);
}

pub fn fromhexBytearrayPos(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return fromhexCore(interp_opaque, args, true);
}

fn fromhexCore(interp_opaque: *anyopaque, args: []const Value, mutable: bool) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("fromhex() requires a string");
        return error.TypeError;
    }
    const parsed = try parseHex(interp.allocator, args[0].str.bytes);
    if (parsed == null) {
        try interp.raisePy("ValueError", "non-hexadecimal number found in fromhex()");
        return error.PyException;
    }
    return wrapOwned(interp, mutable, parsed.?);
}
