//! Implements Python's PEP 3101 format mini-language for the value
//! types FORMAT_WITH_SPEC pushes through it: int, float, str.
//!
//! Spec grammar (subset that fixtures exercise):
//! `[[fill]align][sign][#][0][width][,][.precision][type]`

const std = @import("std");
const Value = @import("../object/value.zig").Value;

pub const Spec = struct {
    fill: u8 = ' ',
    alignment: ?u8 = null, // '<' '>' '=' '^'
    sign: ?u8 = null, // '+' '-' ' '
    alt: bool = false,
    zero: bool = false,
    width: usize = 0,
    comma: bool = false,
    precision: ?usize = null,
    typ: ?u8 = null,
};

fn isAlign(c: u8) bool {
    return c == '<' or c == '>' or c == '=' or c == '^';
}

pub fn parseSpec(s: []const u8) Spec {
    var spec: Spec = .{};
    var i: usize = 0;
    // [[fill]align]
    if (s.len >= 2 and isAlign(s[1])) {
        spec.fill = s[0];
        spec.alignment = s[1];
        i = 2;
    } else if (s.len >= 1 and isAlign(s[0])) {
        spec.alignment = s[0];
        i = 1;
    }
    // [sign]
    if (i < s.len and (s[i] == '+' or s[i] == '-' or s[i] == ' ')) {
        spec.sign = s[i];
        i += 1;
    }
    // [#]
    if (i < s.len and s[i] == '#') {
        spec.alt = true;
        i += 1;
    }
    // [0]
    if (i < s.len and s[i] == '0') {
        spec.zero = true;
        i += 1;
    }
    // [width]
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        spec.width = spec.width * 10 + (s[i] - '0');
    }
    // [,]
    if (i < s.len and s[i] == ',') {
        spec.comma = true;
        i += 1;
    }
    // [.precision]
    if (i < s.len and s[i] == '.') {
        i += 1;
        var p: usize = 0;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            p = p * 10 + (s[i] - '0');
        }
        spec.precision = p;
    }
    // [type]
    if (i < s.len) spec.typ = s[i];
    return spec;
}

fn insertCommas(alloc: std.mem.Allocator, digits: []const u8) ![]u8 {
    if (digits.len <= 3) return alloc.dupe(u8, digits);
    const n_commas = (digits.len - 1) / 3;
    const out = try alloc.alloc(u8, digits.len + n_commas);
    var src: usize = digits.len;
    var dst: usize = out.len;
    var since: usize = 0;
    while (src > 0) {
        if (since == 3) {
            dst -= 1;
            out[dst] = ',';
            since = 0;
        }
        src -= 1;
        dst -= 1;
        out[dst] = digits[src];
        since += 1;
    }
    return out;
}

fn signChar(neg: bool, sign: ?u8) ?u8 {
    if (neg) return '-';
    return switch (sign orelse 0) {
        '+' => '+',
        ' ' => ' ',
        else => null,
    };
}

fn padFinal(alloc: std.mem.Allocator, sign: ?u8, body: []const u8, spec: Spec, default_align: u8) ![]u8 {
    const sign_len: usize = if (sign != null) 1 else 0;
    const total = sign_len + body.len;
    if (total >= spec.width) {
        const out = try alloc.alloc(u8, total);
        if (sign) |c| out[0] = c;
        @memcpy(out[sign_len..], body);
        return out;
    }
    const pad = spec.width - total;
    const out = try alloc.alloc(u8, spec.width);
    const a = spec.alignment orelse default_align;
    // Zero-padding mode (`0` flag with no explicit align) fills between
    // sign and body so "+00042" lines up like Python.
    if (spec.zero and spec.alignment == null) {
        if (sign) |c| out[0] = c;
        var k: usize = 0;
        while (k < pad) : (k += 1) out[sign_len + k] = '0';
        @memcpy(out[sign_len + pad ..], body);
        return out;
    }
    switch (a) {
        '<' => {
            if (sign) |c| out[0] = c;
            @memcpy(out[sign_len .. sign_len + body.len], body);
            var k: usize = 0;
            while (k < pad) : (k += 1) out[sign_len + body.len + k] = spec.fill;
        },
        '>' => {
            var k: usize = 0;
            while (k < pad) : (k += 1) out[k] = spec.fill;
            if (sign) |c| out[pad] = c;
            @memcpy(out[pad + sign_len ..], body);
        },
        '^' => {
            const left = pad / 2;
            const right = pad - left;
            var k: usize = 0;
            while (k < left) : (k += 1) out[k] = spec.fill;
            if (sign) |c| out[left] = c;
            @memcpy(out[left + sign_len .. left + sign_len + body.len], body);
            k = 0;
            while (k < right) : (k += 1) out[left + sign_len + body.len + k] = spec.fill;
        },
        '=' => {
            if (sign) |c| out[0] = c;
            var k: usize = 0;
            while (k < pad) : (k += 1) out[sign_len + k] = spec.fill;
            @memcpy(out[sign_len + pad ..], body);
        },
        else => unreachable,
    }
    return out;
}

fn formatInt(alloc: std.mem.Allocator, i: i64, spec: Spec) ![]u8 {
    const neg = i < 0;
    const abs: u64 = if (neg) @intCast(-(i + 1) + 1) else @intCast(i);
    var buf: [80]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const t: u8 = spec.typ orelse 'd';
    const written: []const u8 = blk: {
        switch (t) {
            'd' => try w.printInt(abs, 10, .lower, .{}),
            'b' => try w.printInt(abs, 2, .lower, .{}),
            'o' => try w.printInt(abs, 8, .lower, .{}),
            'x' => try w.printInt(abs, 16, .lower, .{}),
            'X' => try w.printInt(abs, 16, .upper, .{}),
            else => try w.printInt(abs, 10, .lower, .{}),
        }
        break :blk w.buffered();
    };
    var digits = try alloc.dupe(u8, written);
    if (spec.comma and (t == 'd')) {
        digits = try insertCommas(alloc, digits);
    }
    const sign = signChar(neg, spec.sign);
    return padFinal(alloc, sign, digits, spec, '>');
}

fn formatFloat(alloc: std.mem.Allocator, f: f64, spec: Spec) ![]u8 {
    const neg = f < 0;
    const abs = if (neg) -f else f;
    const prec: usize = spec.precision orelse 6;
    var buf: [128]u8 = undefined;
    const t: u8 = spec.typ orelse 'g';
    const written: []const u8 = switch (t) {
        'f', 'F' => try std.fmt.bufPrint(&buf, "{d:.[1]}", .{ abs, prec }),
        'e' => try formatScientific(&buf, abs, prec, false),
        'E' => try formatScientific(&buf, abs, prec, true),
        else => try std.fmt.bufPrint(&buf, "{d:.[1]}", .{ abs, prec }),
    };
    const body = try alloc.dupe(u8, written);
    const sign = signChar(neg, spec.sign);
    return padFinal(alloc, sign, body, spec, '>');
}

fn formatScientific(buf: []u8, abs: f64, prec: usize, upper: bool) ![]const u8 {
    // Compute decimal exponent. Zig's `{e}` produces variable-width
    // exponents like `e0`; Python pads to two digits with sign.
    var mantissa: f64 = abs;
    var exp: i32 = 0;
    if (abs != 0.0) {
        const lg = @log10(abs);
        exp = @intFromFloat(@floor(lg));
        mantissa = abs / std.math.pow(f64, 10.0, @floatFromInt(exp));
        // Floating-point drift: snap a 9.99... back to 10.0 and bump exp.
        if (mantissa >= 10.0) {
            mantissa /= 10.0;
            exp += 1;
        }
    }
    const exp_sign: u8 = if (exp < 0) '-' else '+';
    const exp_abs: u32 = @intCast(if (exp < 0) -exp else exp);
    const e_char: u8 = if (upper) 'E' else 'e';
    const mantissa_text = try std.fmt.bufPrint(buf, "{d:.[1]}", .{ mantissa, prec });
    const off = mantissa_text.len;
    const tail = try std.fmt.bufPrint(buf[off..], "{c}{c}{d:0>2}", .{ e_char, exp_sign, exp_abs });
    return buf[0 .. off + tail.len];
}

fn formatStr(alloc: std.mem.Allocator, s: []const u8, spec: Spec) ![]u8 {
    var body: []const u8 = s;
    if (spec.precision) |p| {
        if (p < body.len) body = body[0..p];
    }
    return padFinal(alloc, null, body, spec, '<');
}

pub fn format(alloc: std.mem.Allocator, v: Value, spec_str: []const u8) ![]u8 {
    const spec = parseSpec(spec_str);
    return switch (v) {
        .small_int => |i| formatInt(alloc, i, spec),
        .boolean => |b| formatInt(alloc, @intFromBool(b), spec),
        .float => |f| formatFloat(alloc, f, spec),
        .str => |s| formatStr(alloc, s.bytes, spec),
        else => error.TypeError,
    };
}
