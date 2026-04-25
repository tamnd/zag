//! Method table for `int` (small_int / boolean).

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Bytes = @import("../object/bytes.zig").Bytes;
const Tuple = @import("../object/tuple.zig").Tuple;
const Interp = @import("interp.zig").Interp;

fn asInt(v: Value) i64 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| if (b) 1 else 0,
        else => 0,
    };
}

fn bitLengthImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    var n = asInt(args[0]);
    if (n < 0) n = -n;
    var bits: i64 = 0;
    while (n != 0) : (n >>= 1) bits += 1;
    return Value{ .small_int = bits };
}

fn bitCountImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    var n = asInt(args[0]);
    if (n < 0) n = -n;
    var c: i64 = 0;
    while (n != 0) : (n &= n - 1) c += 1;
    return Value{ .small_int = c };
}

fn toBytesCore(
    interp: *Interp,
    n: i64,
    length: usize,
    big_endian: bool,
    signed: bool,
) !Value {
    const buf = try interp.allocator.alloc(u8, length);
    var v: u64 = if (signed and n < 0)
        @bitCast(n)
    else
        @intCast(n);
    if (length < 8) {
        const mask: u64 = (@as(u64, 1) << @intCast(length * 8)) - 1;
        v &= mask;
    }
    var i: usize = 0;
    while (i < length) : (i += 1) {
        const shift: u6 = @intCast((length - 1 - i) * 8);
        buf[i] = @intCast((v >> shift) & 0xff);
    }
    if (!big_endian) std.mem.reverse(u8, buf);
    return Value{ .bytes = try Bytes.fromOwnedSlice(interp.allocator, buf) };
}

fn toBytesImpl(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const n = asInt(args[0]);
    const length: usize = if (args.len >= 2 and args[1] == .small_int) @intCast(args[1].small_int) else 1;
    const byteorder: []const u8 = if (args.len >= 3 and args[2] == .str) args[2].str.bytes else "big";
    var signed = false;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "signed")) signed = kv.isTruthy();
    }
    return toBytesCore(interp, n, length, std.mem.eql(u8, byteorder, "big"), signed);
}

fn toBytesPos(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return toBytesImpl(interp_opaque, args, &.{}, &.{});
}

fn conjugateImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    return args[0];
}

fn asIntegerRatioImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const t = try Tuple.init(interp.allocator, 2);
    t.items[0] = Value{ .small_int = asInt(args[0]) };
    t.items[1] = Value{ .small_int = 1 };
    return Value{ .tuple = t };
}

pub fn fromBytesImpl(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1) {
        try interp.typeError("int.from_bytes() missing argument");
        return error.TypeError;
    }
    const data: []const u8 = switch (args[0]) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        else => {
            try interp.typeError("int.from_bytes() requires bytes-like");
            return error.TypeError;
        },
    };
    const byteorder: []const u8 = if (args.len >= 2 and args[1] == .str) args[1].str.bytes else "big";
    var signed = false;
    if (args.len >= 3 and args[2] == .boolean) signed = args[2].boolean;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "signed")) signed = kv.isTruthy();
    }
    const big = std.mem.eql(u8, byteorder, "big");
    var v: u64 = 0;
    if (big) {
        for (data) |c| v = (v << 8) | c;
    } else {
        var i: usize = data.len;
        while (i > 0) {
            i -= 1;
            v = (v << 8) | data[i];
        }
    }
    if (signed and data.len > 0) {
        const top_byte = if (big) data[0] else data[data.len - 1];
        if (top_byte & 0x80 != 0) {
            const bits = data.len * 8;
            const sign_bit: u64 = @as(u64, 1) << @intCast(bits - 1);
            const mask: u64 = if (bits >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(bits)) - 1;
            const sv: i64 = @intCast(@as(i65, @intCast(v & mask)) - @as(i65, @intCast(sign_bit)) * 2);
            return Value{ .small_int = sv };
        }
    }
    return Value{ .small_int = @intCast(v) };
}

pub fn fromBytesPos(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return fromBytesImpl(interp_opaque, args, &.{}, &.{});
}

var bit_length_entry: BuiltinFn = .{ .name = "bit_length", .func = bitLengthImpl };
var bit_count_entry: BuiltinFn = .{ .name = "bit_count", .func = bitCountImpl };
var to_bytes_entry: BuiltinFn = .{ .name = "to_bytes", .func = toBytesPos, .kw_func = toBytesImpl };
var conjugate_entry: BuiltinFn = .{ .name = "conjugate", .func = conjugateImpl };
var as_integer_ratio_entry: BuiltinFn = .{ .name = "as_integer_ratio", .func = asIntegerRatioImpl };
pub var from_bytes_entry: BuiltinFn = .{ .name = "from_bytes", .func = fromBytesPos, .kw_func = fromBytesImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "bit_length")) return &bit_length_entry;
    if (std.mem.eql(u8, name, "bit_count")) return &bit_count_entry;
    if (std.mem.eql(u8, name, "to_bytes")) return &to_bytes_entry;
    if (std.mem.eql(u8, name, "conjugate")) return &conjugate_entry;
    if (std.mem.eql(u8, name, "as_integer_ratio")) return &as_integer_ratio_entry;
    return null;
}

pub fn lookupAttr(name: []const u8) ?Value {
    if (std.mem.eql(u8, name, "numerator")) return null;
    if (std.mem.eql(u8, name, "denominator")) return null;
    if (std.mem.eql(u8, name, "real")) return null;
    if (std.mem.eql(u8, name, "imag")) return null;
    return null;
}
