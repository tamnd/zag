//! Method table for `float`.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Tuple = @import("../object/tuple.zig").Tuple;
const Interp = @import("interp.zig").Interp;

fn isIntegerImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const f = args[0].float;
    if (std.math.isNan(f) or std.math.isInf(f)) return Value{ .boolean = false };
    return Value{ .boolean = @floor(f) == f };
}

fn asIntegerRatioImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const f = args[0].float;
    if (std.math.isNan(f) or std.math.isInf(f)) {
        try interp.raisePy("OverflowError", "cannot convert to integer ratio");
        return error.PyException;
    }
    // Use IEEE 754 decomposition: f = m * 2^e with m in [0.5, 1).
    const fr = std.math.frexp(f);
    var num_bits: f64 = fr.significand;
    var exp: i32 = fr.exponent;
    // Multiply mantissa to get integer.
    var i: i32 = 0;
    while (i < 53) : (i += 1) {
        if (@floor(num_bits) == num_bits) break;
        num_bits *= 2.0;
        exp -= 1;
    }
    var n: i64 = @intFromFloat(num_bits);
    var d: i64 = 1;
    if (exp > 0) {
        n <<= @intCast(exp);
    } else {
        d <<= @intCast(-exp);
    }
    // Reduce by GCD.
    var a: i64 = if (n < 0) -n else n;
    var b: i64 = d;
    while (b != 0) {
        const t = b;
        b = @mod(a, b);
        a = t;
    }
    n = @divTrunc(n, a);
    d = @divTrunc(d, a);
    const t = try Tuple.init(interp.allocator, 2);
    t.items[0] = Value{ .small_int = n };
    t.items[1] = Value{ .small_int = d };
    return Value{ .tuple = t };
}

fn conjugateImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    return args[0];
}

pub fn fromHexImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("float.fromhex() requires a string");
        return error.TypeError;
    }
    const s = std.mem.trim(u8, args[0].str.bytes, " \t\r\n");
    var i: usize = 0;
    var sign: f64 = 1.0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        if (s[i] == '-') sign = -1.0;
        i += 1;
    }
    if (i + 1 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) i += 2;
    // mantissa: hex digits with optional '.'
    var mant: f64 = 0.0;
    var frac_bits: i32 = 0;
    var saw_dot = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '.') {
            if (saw_dot) break;
            saw_dot = true;
            continue;
        }
        const d: ?u8 = blk: {
            if (c >= '0' and c <= '9') break :blk c - '0';
            if (c >= 'a' and c <= 'f') break :blk 10 + (c - 'a');
            if (c >= 'A' and c <= 'F') break :blk 10 + (c - 'A');
            break :blk null;
        };
        if (d == null) break;
        mant = mant * 16.0 + @as(f64, @floatFromInt(d.?));
        if (saw_dot) frac_bits += 4;
    }
    var exp: i32 = 0;
    if (i < s.len and (s[i] == 'p' or s[i] == 'P')) {
        i += 1;
        var esign: i32 = 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            if (s[i] == '-') esign = -1;
            i += 1;
        }
        var e: i32 = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            e = e * 10 + @as(i32, @intCast(s[i] - '0'));
        }
        exp = esign * e;
    }
    const total_exp: i32 = exp - frac_bits;
    const out = sign * mant * std.math.pow(f64, 2.0, @floatFromInt(total_exp));
    return Value{ .float = out };
}

pub fn fromHexPos(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return fromHexImpl(interp_opaque, args);
}

var is_integer_entry: BuiltinFn = .{ .name = "is_integer", .func = isIntegerImpl };
var as_integer_ratio_entry: BuiltinFn = .{ .name = "as_integer_ratio", .func = asIntegerRatioImpl };
var conjugate_entry: BuiltinFn = .{ .name = "conjugate", .func = conjugateImpl };
pub var from_hex_entry: BuiltinFn = .{ .name = "fromhex", .func = fromHexPos };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "is_integer")) return &is_integer_entry;
    if (std.mem.eql(u8, name, "as_integer_ratio")) return &as_integer_ratio_entry;
    if (std.mem.eql(u8, name, "conjugate")) return &conjugate_entry;
    return null;
}
