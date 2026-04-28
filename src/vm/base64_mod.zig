//! `base64` module — b64/b32/b16/b85/a85 encode/decode for fixtures 65 & 210.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "base64");
    try regKw(interp, m, "b64encode", b64encodeFn, b64encodeKw);
    try regKw(interp, m, "standard_b64encode", b64encodeFn, b64encodeKw);
    try regKw(interp, m, "b64decode", b64decodeFn, b64decodeKw);
    try regKw(interp, m, "standard_b64decode", b64decodeFn, b64decodeKw);
    try reg(interp, m, "urlsafe_b64encode", urlsafeEncodeFn);
    try regKw(interp, m, "urlsafe_b64decode", urlsafeDecodeFn, urlsafeDecodeKw);
    try reg(interp, m, "b32encode", b32encodeFn);
    try regKw(interp, m, "b32decode", b32decodeFn, b32decodeKw);
    try reg(interp, m, "b32hexencode", b32hexencodeFn);
    try regKw(interp, m, "b32hexdecode", b32hexdecodeFn, b32hexdecodeKw);
    try reg(interp, m, "b16encode", b16encodeFn);
    try regKw(interp, m, "b16decode", b16decodeFn, b16decodeKw);
    try reg(interp, m, "encodebytes", encodebytesFn);
    try reg(interp, m, "decodebytes", decodebytesFn);
    try regKw(interp, m, "b85encode", b85encodeFn, b85encodeKw);
    try reg(interp, m, "b85decode", b85decodeFn);
    try regKw(interp, m, "a85encode", a85encodeFn, a85encodeKw);
    try regKw(interp, m, "a85decode", a85decodeFn, a85decodeKw);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, f: BuiltinFnPtr) !void {
    const bf = try interp.allocator.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = bf });
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, f: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const bf = try interp.allocator.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f, .kw_func = kw };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = bf });
}

fn gi(p: *anyopaque) *Interp { return @ptrCast(@alignCast(p)); }

fn argBytes(v: Value) ![]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        .bytearray => |b| b.data.items,
        else => error.TypeError,
    };
}

fn kwBool(kw_names: []const Value, kw_values: []const Value, key: []const u8, default: bool) bool {
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, key)) return kv.isTruthy();
    }
    return default;
}

fn kwBytes(kw_names: []const Value, kw_values: []const Value, key: []const u8) ?[]const u8 {
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, key)) return argBytes(kv) catch null;
    }
    return null;
}

// ─── base64 standard ─────────────────────────────────────────────────────────

const STD_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn b64encode(a: std.mem.Allocator, src: []const u8, alphabet: []const u8) ![]u8 {
    if (src.len == 0) return a.dupe(u8, "");
    const out_len = ((src.len + 2) / 3) * 4;
    const out = try a.alloc(u8, out_len);
    var i: usize = 0;
    var j: usize = 0;
    while (i + 3 <= src.len) : (i += 3) {
        out[j]     = alphabet[src[i] >> 2];
        out[j + 1] = alphabet[((src[i] & 3) << 4) | (src[i+1] >> 4)];
        out[j + 2] = alphabet[((src[i+1] & 0xf) << 2) | (src[i+2] >> 6)];
        out[j + 3] = alphabet[src[i+2] & 0x3f];
        j += 4;
    }
    switch (src.len - i) {
        1 => {
            out[j]     = alphabet[src[i] >> 2];
            out[j + 1] = alphabet[(src[i] & 3) << 4];
            out[j + 2] = '='; out[j + 3] = '=';
        },
        2 => {
            out[j]     = alphabet[src[i] >> 2];
            out[j + 1] = alphabet[((src[i] & 3) << 4) | (src[i+1] >> 4)];
            out[j + 2] = alphabet[(src[i+1] & 0xf) << 2];
            out[j + 3] = '=';
        },
        else => {},
    }
    return out;
}

fn b64decode(a: std.mem.Allocator, raw: []const u8, alphabet: []const u8, validate: bool) ![]u8 {
    // Strip whitespace (unless validate=true, which disallows it)
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(a);
    for (raw) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (validate) return error.InvalidBase64;
            continue;
        }
        try stripped.append(a, c);
    }
    const src = stripped.items;
    if (src.len % 4 != 0) return error.InvalidBase64;
    var padded: std.ArrayList(u8) = .empty;
    defer padded.deinit(a);
    try padded.appendSlice(a, src);

    var lookup: [256]i16 = .{-1} ** 256;
    for (alphabet, 0..) |c, idx| lookup[c] = @intCast(idx);
    lookup['='] = 0;

    var end = padded.items.len;
    while (end > 0 and padded.items[end - 1] == '=') end -= 1;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: u32 = 0;
    var bits: u32 = 0;
    for (padded.items[0..end]) |c| {
        const v = lookup[c];
        if (v < 0) return error.InvalidBase64;
        buf = (buf << 6) | @as(u32, @intCast(v));
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            try out.append(a, @intCast((buf >> @intCast(bits)) & 0xff));
        }
    }
    return out.toOwnedSlice(a);
}

fn b64encodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return b64encodeKw(p, args, &.{}, &.{});
}
fn b64encodeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = argBytes(args[0]) catch {
        try interp.typeError("b64encode: expected bytes"); return error.TypeError;
    };
    const alt = kwBytes(kw_names, kw_values, "altchars");
    var alphabet_buf: [64]u8 = undefined;
    const alphabet: []const u8 = if (alt) |ac| blk: {
        if (ac.len != 2) { try interp.typeError("altchars must be 2 bytes"); return error.TypeError; }
        @memcpy(&alphabet_buf, STD_ALPHABET);
        alphabet_buf[62] = ac[0];
        alphabet_buf[63] = ac[1];
        break :blk alphabet_buf[0..64];
    } else STD_ALPHABET;
    const enc = try b64encode(a, src, alphabet);
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, enc) };
}

fn b64decodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return b64decodeKw(p, args, &.{}, &.{});
}
fn b64decodeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = argBytes(args[0]) catch {
        try interp.typeError("b64decode: expected bytes/str"); return error.TypeError;
    };
    const validate = kwBool(kw_names, kw_values, "validate", false);
    const alt = kwBytes(kw_names, kw_values, "altchars");
    var alphabet_buf: [64]u8 = undefined;
    const alphabet: []const u8 = if (alt) |ac| blk: {
        @memcpy(&alphabet_buf, STD_ALPHABET);
        if (ac.len == 2) { alphabet_buf[62] = ac[0]; alphabet_buf[63] = ac[1]; }
        break :blk alphabet_buf[0..64];
    } else STD_ALPHABET;
    const dec = b64decode(a, src, alphabet, validate) catch |err| switch (err) {
        error.InvalidBase64 => {
            try interp.raisePy("ValueError", "invalid base64");
            return error.PyException;
        },
        else => return err,
    };
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, dec) };
}

fn urlsafeEncodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, try b64encode(a, src, URL_ALPHABET)) };
}

fn urlsafeDecodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return urlsafeDecodeKw(p, args, &.{}, &.{});
}
fn urlsafeDecodeKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const dec = try b64decode(a, src, URL_ALPHABET, false);
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, dec) };
}

// ─── encodebytes / decodebytes ───────────────────────────────────────────────

fn encodebytesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    // Encode in chunks of 57 bytes (→ 76 base64 chars), append \n after each line
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < src.len) {
        const end = @min(i + 57, src.len);
        const line = try b64encode(a, src[i..end], STD_ALPHABET);
        defer a.free(line);
        try out.appendSlice(a, line);
        try out.append(a, '\n');
        i = end;
    }
    if (src.len == 0) try out.append(a, '\n');
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, try a.dupe(u8, out.items)) };
}

fn decodebytesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const dec = try b64decode(a, src, STD_ALPHABET, false);
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, dec) };
}

// ─── base32 ──────────────────────────────────────────────────────────────────

const B32_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const B32HEX_ALPHA = "0123456789ABCDEFGHIJKLMNOPQRSTUV";

fn b32encodeGeneric(a: std.mem.Allocator, src: []const u8, alpha: []const u8) ![]u8 {
    const groups = (src.len + 4) / 5;
    const out = try a.alloc(u8, groups * 8);
    var i: usize = 0;
    var j: usize = 0;
    while (i + 5 <= src.len) : (i += 5) {
        const v: u64 = (@as(u64, src[i]) << 32) | (@as(u64, src[i+1]) << 24) |
                       (@as(u64, src[i+2]) << 16) | (@as(u64, src[i+3]) << 8) | src[i+4];
        for (0..8) |k| { out[j+k] = alpha[(v >> @intCast((7-k)*5)) & 0x1f]; }
        j += 8;
    }
    const rem = src.len - i;
    if (rem > 0) {
        var v: u64 = 0;
        for (0..5) |k| { v <<= 8; if (k < rem) v |= src[i+k]; }
        const valid: usize = switch (rem) { 1=>2, 2=>4, 3=>5, 4=>7, else=>8 };
        for (0..8) |k| {
            out[j+k] = if (k < valid) alpha[(v >> @intCast((7-k)*5)) & 0x1f] else '=';
        }
    }
    return out;
}

fn b32decodeGeneric(a: std.mem.Allocator, src: []const u8, alpha: []const u8, casefold: bool) ![]u8 {
    var lookup: [256]i16 = .{-1} ** 256;
    for (alpha, 0..) |c, idx| {
        lookup[c] = @intCast(idx);
        if (casefold and c >= 'A' and c <= 'Z') lookup[c - 'A' + 'a'] = @intCast(idx);
        if (casefold and c >= '0' and c <= '9') {} // already set
    }
    var end = src.len;
    while (end > 0 and src[end-1] == '=') end -= 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: u64 = 0;
    var bits: u32 = 0;
    for (src[0..end]) |c| {
        const v = lookup[c];
        if (v < 0) return error.InvalidBase32;
        buf = (buf << 5) | @as(u64, @intCast(v));
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            try out.append(a, @intCast((buf >> @intCast(bits)) & 0xff));
        }
    }
    return out.toOwnedSlice(a);
}

fn b32encodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, try b32encodeGeneric(a, src, B32_ALPHA)) };
}

fn b32decodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return b32decodeKw(p, args, &.{}, &.{});
}
fn b32decodeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const cf = kwBool(kw_names, kw_values, "casefold", false);
    const dec = b32decodeGeneric(a, src, B32_ALPHA, cf) catch {
        try interp.raisePy("ValueError", "invalid base32"); return error.PyException;
    };
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, dec) };
}

fn b32hexencodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, try b32encodeGeneric(a, src, B32HEX_ALPHA)) };
}

fn b32hexdecodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return b32hexdecodeKw(p, args, &.{}, &.{});
}
fn b32hexdecodeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const cf = kwBool(kw_names, kw_values, "casefold", false);
    const dec = b32decodeGeneric(a, src, B32HEX_ALPHA, cf) catch {
        try interp.raisePy("ValueError", "invalid base32hex"); return error.PyException;
    };
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, dec) };
}

// ─── base16 ──────────────────────────────────────────────────────────────────

fn b16encodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const out = try a.alloc(u8, src.len * 2);
    const HEX = "0123456789ABCDEF";
    for (src, 0..) |b, i| { out[i*2] = HEX[b >> 4]; out[i*2+1] = HEX[b & 0xf]; }
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, out) };
}

fn b16decodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return b16decodeKw(p, args, &.{}, &.{});
}
fn b16decodeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const cf = kwBool(kw_names, kw_values, "casefold", false);
    if (src.len % 2 != 0) { try interp.raisePy("ValueError", "odd length"); return error.PyException; }
    const out = try a.alloc(u8, src.len / 2);
    var i: usize = 0;
    while (i < src.len) : (i += 2) {
        const hi = hexNibble(src[i], cf) catch { try interp.raisePy("ValueError", "invalid hex"); return error.PyException; };
        const lo = hexNibble(src[i+1], cf) catch { try interp.raisePy("ValueError", "invalid hex"); return error.PyException; };
        out[i/2] = hi * 16 + lo;
    }
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, out) };
}

fn hexNibble(c: u8, casefold: bool) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A' + 10,
        'a'...'f' => if (casefold) c - 'a' + 10 else error.InvalidHex,
        else => error.InvalidHex,
    };
}

// ─── base85 ──────────────────────────────────────────────────────────────────

const B85_ALPHA = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~";

fn b85encode(a: std.mem.Allocator, src: []const u8, pad: bool) ![]u8 {
    _ = pad;
    const alpha = B85_ALPHA;
    // Pad to multiple of 4
    const padded_len = (src.len + 3) & ~@as(usize, 3);
    var padded = try a.alloc(u8, padded_len);
    defer a.free(padded);
    @memcpy(padded[0..src.len], src);
    for (src.len..padded_len) |k| padded[k] = 0;

    const groups = padded_len / 4;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for (0..groups) |g| {
        const v: u32 = (@as(u32, padded[g*4]) << 24) | (@as(u32, padded[g*4+1]) << 16) |
                       (@as(u32, padded[g*4+2]) << 8) | padded[g*4+3];
        var tmp: [5]u8 = undefined;
        var x = v;
        for (0..5) |k| {
            tmp[4-k] = alpha[x % 85];
            x /= 85;
        }
        // For the last group, only emit as many chars as needed
        const is_last = (g == groups - 1);
        const rem = src.len % 4;
        const chars: usize = if (is_last and rem != 0) rem + 1 else 5;
        try out.appendSlice(a, tmp[0..chars]);
    }
    return a.dupe(u8, out.items);
}

fn b85decode(a: std.mem.Allocator, src: []const u8) ![]u8 {
    var lookup: [256]i8 = .{-1} ** 256;
    for (B85_ALPHA, 0..) |c, idx| lookup[c] = @intCast(idx);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < src.len) {
        // Find chunk size (5 or partial at end)
        const rem = src.len - i;
        const chunk = @min(5, rem);
        if (chunk < 2) break; // invalid
        var v: u32 = 0;
        for (0..5) |k| {
            v *= 85;
            const c: u8 = if (k < chunk) src[i+k] else '~'; // pad with b85 value 84
            const lv = lookup[c];
            if (lv < 0) return error.InvalidBase85;
            v += @intCast(lv);
        }
        const bytes_out: usize = if (chunk < 5) chunk - 1 else 4;
        for (0..4) |k| {
            if (k < bytes_out) try out.append(a, @intCast((v >> @as(u5, @intCast(24 - k*8))) & 0xff));
        }
        i += chunk;
    }
    return a.dupe(u8, out.items);
}

fn b85encodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return b85encodeKw(p, args, &.{}, &.{});
}
fn b85encodeKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const enc = try b85encode(a, src, false);
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, enc) };
}

fn b85decodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const dec = b85decode(a, src) catch {
        try interp.raisePy("ValueError", "invalid base85"); return error.PyException;
    };
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, dec) };
}

// ─── ascii85 ─────────────────────────────────────────────────────────────────

fn a85encode(a: std.mem.Allocator, src: []const u8, adobe: bool, wrapcol: usize) ![]u8 {
    const padded_len = (src.len + 3) & ~@as(usize, 3);
    var padded = try a.alloc(u8, padded_len);
    defer a.free(padded);
    @memcpy(padded[0..src.len], src);
    for (src.len..padded_len) |k| padded[k] = 0;

    const groups = padded_len / 4;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    if (adobe) try out.appendSlice(a, "<~");
    var col: usize = if (adobe) 2 else 0;
    for (0..groups) |g| {
        const v: u32 = (@as(u32, padded[g*4]) << 24) | (@as(u32, padded[g*4+1]) << 16) |
                       (@as(u32, padded[g*4+2]) << 8) | padded[g*4+3];
        const is_last = (g == groups - 1);
        const rem = src.len % 4;
        // Special: all-zero group (but not if it's a partial last)
        if (v == 0 and !(is_last and rem != 0)) {
            if (wrapcol > 0 and col + 1 > wrapcol) { try out.append(a, '\n'); col = 0; }
            try out.append(a, 'z');
            col += 1;
        } else {
            var tmp: [5]u8 = undefined;
            var x = v;
            for (0..5) |k| { tmp[4-k] = @as(u8, @intCast(x % 85)) + 33; x /= 85; }
            const chars: usize = if (is_last and rem != 0) rem + 1 else 5;
            for (tmp[0..chars]) |c| {
                if (wrapcol > 0 and col >= wrapcol) { try out.append(a, '\n'); col = 0; }
                try out.append(a, c);
                col += 1;
            }
        }
    }
    if (adobe) try out.appendSlice(a, "~>");
    return a.dupe(u8, out.items);
}

fn a85decode(a: std.mem.Allocator, src: []const u8, adobe: bool, ignorews: bool) ![]u8 {
    var start: usize = 0;
    var end: usize = src.len;
    if (adobe) {
        if (src.len >= 2 and src[0] == '<' and src[1] == '~') start = 2;
        if (src.len >= 2 and src[end-1] == '>' and src[end-2] == '~') end -= 2;
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var group: [5]u8 = undefined;
    var gc: usize = 0;
    var i = start;
    while (i < end) : (i += 1) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (ignorews or true) continue; // always skip whitespace
        }
        if (c == 'z') {
            if (gc != 0) return error.InvalidA85;
            try out.appendSlice(a, &[_]u8{0, 0, 0, 0});
            continue;
        }
        if (c < 33 or c > 117) return error.InvalidA85;
        group[gc] = c;
        gc += 1;
        if (gc == 5) {
            var v: u32 = 0;
            for (group) |b| { v = v * 85 + (b - 33); }
            try out.append(a, @intCast((v >> 24) & 0xff));
            try out.append(a, @intCast((v >> 16) & 0xff));
            try out.append(a, @intCast((v >> 8) & 0xff));
            try out.append(a, @intCast(v & 0xff));
            gc = 0;
        }
    }
    // Handle partial last group
    if (gc > 0) {
        var v: u32 = 0;
        for (0..5) |k| { v = v * 85 + (if (k < gc) @as(u32, group[k] - 33) else 84); }
        for (0..gc - 1) |k| {
            try out.append(a, @intCast((v >> @as(u5, @intCast(24 - k*8))) & 0xff));
        }
    }
    return a.dupe(u8, out.items);
}

fn a85encodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return a85encodeKw(p, args, &.{}, &.{});
}
fn a85encodeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const adobe = kwBool(kw_names, kw_values, "adobe", false);
    const wrapcol: usize = 0; // no wrapping by default
    const enc = try a85encode(a, src, adobe, wrapcol);
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, enc) };
}

fn a85decodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return a85decodeKw(p, args, &.{}, &.{});
}
fn a85decodeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const adobe = kwBool(kw_names, kw_values, "adobe", false);
    const ignorews = kwBool(kw_names, kw_values, "ignorechars", true);
    const dec = a85decode(a, src, adobe, ignorews) catch {
        try interp.raisePy("ValueError", "invalid ascii85"); return error.PyException;
    };
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, dec) };
}
