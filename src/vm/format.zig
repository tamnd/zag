//! Implements Python's PEP 3101 format mini-language for the value
//! types FORMAT_WITH_SPEC pushes through it: int, float, str.
//!
//! Spec grammar (subset that fixtures exercise):
//! `[[fill]align][sign][#][0][width][,|_][.precision][type]`

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
    underscore: bool = false,
    precision: ?usize = null,
    typ: ?u8 = null,
};

fn isAlign(c: u8) bool {
    return c == '<' or c == '>' or c == '=' or c == '^';
}

pub fn parseSpec(s: []const u8) Spec {
    var spec: Spec = .{};
    var i: usize = 0;
    if (s.len >= 2 and isAlign(s[1])) {
        spec.fill = s[0];
        spec.alignment = s[1];
        i = 2;
    } else if (s.len >= 1 and isAlign(s[0])) {
        spec.alignment = s[0];
        i = 1;
    }
    if (i < s.len and (s[i] == '+' or s[i] == '-' or s[i] == ' ')) {
        spec.sign = s[i];
        i += 1;
    }
    if (i < s.len and s[i] == '#') {
        spec.alt = true;
        i += 1;
    }
    if (i < s.len and s[i] == '0') {
        spec.zero = true;
        i += 1;
    }
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        spec.width = spec.width * 10 + (s[i] - '0');
    }
    if (i < s.len and s[i] == ',') {
        spec.comma = true;
        i += 1;
    } else if (i < s.len and s[i] == '_') {
        spec.underscore = true;
        i += 1;
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        var p: usize = 0;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            p = p * 10 + (s[i] - '0');
        }
        spec.precision = p;
    }
    if (i < s.len) spec.typ = s[i];
    return spec;
}

/// Insert `sep` every `group` chars from the right.
fn groupString(alloc: std.mem.Allocator, digits: []const u8, sep: u8, group: usize) ![]u8 {
    if (digits.len <= group) return alloc.dupe(u8, digits);
    const n = (digits.len - 1) / group;
    const out = try alloc.alloc(u8, digits.len + n);
    var src: usize = digits.len;
    var dst: usize = out.len;
    var since: usize = 0;
    while (src > 0) {
        if (since == group) {
            dst -= 1;
            out[dst] = sep;
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

/// Pads body to spec.width given an optional sign prefix. If `prefix`
/// is non-empty (alt-form like "0x"), it sits between sign and body
/// for zero-pad mode.
fn padFinalP(alloc: std.mem.Allocator, sign: ?u8, prefix: []const u8, body: []const u8, spec: Spec, default_align: u8) ![]u8 {
    const sign_len: usize = if (sign != null) 1 else 0;
    const total = sign_len + prefix.len + body.len;
    if (total >= spec.width) {
        const out = try alloc.alloc(u8, total);
        if (sign) |c| out[0] = c;
        @memcpy(out[sign_len .. sign_len + prefix.len], prefix);
        @memcpy(out[sign_len + prefix.len ..], body);
        return out;
    }
    const pad = spec.width - total;
    const out = try alloc.alloc(u8, spec.width);
    const a = spec.alignment orelse default_align;
    if (spec.zero and spec.alignment == null) {
        if (sign) |c| out[0] = c;
        @memcpy(out[sign_len .. sign_len + prefix.len], prefix);
        var k: usize = 0;
        while (k < pad) : (k += 1) out[sign_len + prefix.len + k] = '0';
        @memcpy(out[sign_len + prefix.len + pad ..], body);
        return out;
    }
    switch (a) {
        '<' => {
            if (sign) |c| out[0] = c;
            @memcpy(out[sign_len .. sign_len + prefix.len], prefix);
            @memcpy(out[sign_len + prefix.len .. sign_len + prefix.len + body.len], body);
            var k: usize = 0;
            while (k < pad) : (k += 1) out[sign_len + prefix.len + body.len + k] = spec.fill;
        },
        '>' => {
            var k: usize = 0;
            while (k < pad) : (k += 1) out[k] = spec.fill;
            if (sign) |c| out[pad] = c;
            @memcpy(out[pad + sign_len .. pad + sign_len + prefix.len], prefix);
            @memcpy(out[pad + sign_len + prefix.len ..], body);
        },
        '^' => {
            const left = pad / 2;
            const right = pad - left;
            var k: usize = 0;
            while (k < left) : (k += 1) out[k] = spec.fill;
            if (sign) |c| out[left] = c;
            @memcpy(out[left + sign_len .. left + sign_len + prefix.len], prefix);
            @memcpy(out[left + sign_len + prefix.len .. left + sign_len + prefix.len + body.len], body);
            k = 0;
            while (k < right) : (k += 1) out[left + sign_len + prefix.len + body.len + k] = spec.fill;
        },
        '=' => {
            if (sign) |c| out[0] = c;
            @memcpy(out[sign_len .. sign_len + prefix.len], prefix);
            var k: usize = 0;
            while (k < pad) : (k += 1) out[sign_len + prefix.len + k] = spec.fill;
            @memcpy(out[sign_len + prefix.len + pad ..], body);
        },
        else => unreachable,
    }
    return out;
}

fn formatInt(alloc: std.mem.Allocator, i: i64, spec: Spec) ![]u8 {
    // c type: render as a single Unicode codepoint.
    if (spec.typ == @as(?u8, 'c')) {
        if (i < 0 or i > 0x10FFFF) return error.ValueError;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(i), &buf) catch return error.ValueError;
        return padFinalP(alloc, null, "", buf[0..n], spec, '<');
    }
    const t: u8 = blk: {
        const tt = spec.typ orelse 'd';
        if (tt == 'n') break :blk 'd';
        break :blk tt;
    };

    const neg = i < 0;
    const abs: u64 = if (neg) @intCast(-(i + 1) + 1) else @intCast(i);
    var buf: [80]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    switch (t) {
        'd' => try w.printInt(abs, 10, .lower, .{}),
        'b' => try w.printInt(abs, 2, .lower, .{}),
        'o' => try w.printInt(abs, 8, .lower, .{}),
        'x' => try w.printInt(abs, 16, .lower, .{}),
        'X' => try w.printInt(abs, 16, .upper, .{}),
        else => try w.printInt(abs, 10, .lower, .{}),
    }
    const digits = w.buffered();

    const prefix: []const u8 = if (spec.alt) switch (t) {
        'b' => "0b",
        'o' => "0o",
        'x' => "0x",
        'X' => "0X",
        else => "",
    } else "";

    const group_size: usize = switch (t) {
        'd' => 3,
        'b', 'o', 'x', 'X' => 4,
        else => 0,
    };
    const sep: ?u8 = if (spec.comma and t == 'd') ',' else if (spec.underscore and group_size > 0) '_' else null;

    const sign = signChar(neg, spec.sign);
    const sign_len: usize = if (sign != null) 1 else 0;

    // Decide pre-pad target digit count for zero-padding.
    var target_d: usize = digits.len;
    if (spec.zero and spec.alignment == null) {
        const overhead = sign_len + prefix.len;
        if (sep) |_| {
            while (true) {
                const gl = if (target_d == 0) 0 else target_d + (target_d - 1) / group_size;
                if (overhead + gl >= spec.width) break;
                target_d += 1;
            }
        } else {
            if (overhead + target_d < spec.width) target_d = spec.width - overhead;
        }
    }
    const padded: []u8 = if (target_d > digits.len) blk: {
        const p = try alloc.alloc(u8, target_d);
        @memset(p[0 .. target_d - digits.len], '0');
        @memcpy(p[target_d - digits.len ..], digits);
        break :blk p;
    } else try alloc.dupe(u8, digits);

    const grouped: []const u8 = if (sep) |s| try groupString(alloc, padded, s, group_size) else padded;

    // Once we pre-padded, suppress padFinal's zero-fill so it doesn't
    // pile more zeros on top.
    var spec2 = spec;
    if (target_d > digits.len) spec2.zero = false;
    return padFinalP(alloc, sign, prefix, grouped, spec2, '>');
}

fn formatFloat(alloc: std.mem.Allocator, f: f64, spec: Spec) ![]u8 {
    var fff = f;
    var typ: u8 = spec.typ orelse 'g';
    var trail: u8 = 0;
    if (typ == '%') {
        fff = fff * 100.0;
        typ = 'f';
        trail = '%';
    }
    if (typ == 'n') typ = 'g';
    const neg = fff < 0;
    const abs = if (neg) -fff else fff;
    const prec: usize = spec.precision orelse 6;

    var buf: [128]u8 = undefined;
    const written: []const u8 = switch (typ) {
        'f', 'F' => try std.fmt.bufPrint(&buf, "{d:.[1]}", .{ abs, prec }),
        'e' => try formatScientific(&buf, abs, prec, false),
        'E' => try formatScientific(&buf, abs, prec, true),
        'g', 'G' => try formatG(&buf, abs, prec, typ == 'G', spec.alt),
        else => try std.fmt.bufPrint(&buf, "{d:.[1]}", .{ abs, prec }),
    };

    var body: []u8 = try alloc.dupe(u8, written);
    if (spec.comma or spec.underscore) {
        const sep: u8 = if (spec.comma) ',' else '_';
        const dot = std.mem.indexOfScalar(u8, body, '.') orelse body.len;
        const e_idx = std.mem.indexOfAny(u8, body, "eE") orelse body.len;
        const int_end = @min(dot, e_idx);
        const grouped = try groupString(alloc, body[0..int_end], sep, 3);
        const new_body = try alloc.alloc(u8, grouped.len + body.len - int_end);
        @memcpy(new_body[0..grouped.len], grouped);
        @memcpy(new_body[grouped.len..], body[int_end..]);
        body = new_body;
    }
    if (trail != 0) {
        const new_body = try alloc.alloc(u8, body.len + 1);
        @memcpy(new_body[0..body.len], body);
        new_body[body.len] = trail;
        body = new_body;
    }
    const sign = signChar(neg, spec.sign);
    return padFinalP(alloc, sign, "", body, spec, '>');
}

fn formatScientific(buf: []u8, abs: f64, prec: usize, upper: bool) ![]const u8 {
    var mantissa: f64 = abs;
    var exp: i32 = 0;
    if (abs != 0.0) {
        const lg = @log10(abs);
        exp = @intFromFloat(@floor(lg));
        mantissa = abs / std.math.pow(f64, 10.0, @floatFromInt(exp));
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

/// Python's `:g` -- pick fixed vs exponent based on the magnitude,
/// then strip trailing zeros and a dangling decimal point unless
/// `alt` is set (which preserves them).
fn formatG(buf: []u8, abs: f64, precision: usize, upper: bool, alt: bool) ![]const u8 {
    const p: usize = if (precision == 0) 1 else precision;
    var exp: i32 = 0;
    if (abs != 0.0) {
        const lg = @log10(abs);
        exp = @intFromFloat(@floor(lg));
    }
    const use_exp = exp < -4 or exp >= @as(i32, @intCast(p));
    var raw_buf: [128]u8 = undefined;
    const raw: []const u8 = if (use_exp)
        try formatScientific(&raw_buf, abs, p - 1, upper)
    else blk: {
        const dec_digits: usize = @intCast(@as(i32, @intCast(p)) - 1 - exp);
        break :blk try std.fmt.bufPrint(&raw_buf, "{d:.[1]}", .{ abs, dec_digits });
    };
    if (alt) {
        @memcpy(buf[0..raw.len], raw);
        return buf[0..raw.len];
    }
    var mant_end: usize = raw.len;
    var exp_part: []const u8 = "";
    for (raw, 0..) |c, i| {
        if (c == 'e' or c == 'E') {
            mant_end = i;
            exp_part = raw[i..];
            break;
        }
    }
    var mant = raw[0..mant_end];
    if (std.mem.indexOfScalar(u8, mant, '.')) |_| {
        while (mant.len > 0 and mant[mant.len - 1] == '0') mant = mant[0 .. mant.len - 1];
        if (mant.len > 0 and mant[mant.len - 1] == '.') mant = mant[0 .. mant.len - 1];
    }
    const total = mant.len + exp_part.len;
    @memcpy(buf[0..mant.len], mant);
    @memcpy(buf[mant.len..total], exp_part);
    return buf[0..total];
}

fn formatStr(alloc: std.mem.Allocator, s: []const u8, spec: Spec) ![]u8 {
    var body: []const u8 = s;
    if (spec.precision) |p| {
        if (p < body.len) body = body[0..p];
    }
    return padFinalP(alloc, null, "", body, spec, '<');
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
