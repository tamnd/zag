//! Pinhole `base64` module: b64/urlsafe/b32/b16 encode/decode.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "base64");
    try reg(interp, m, "b64encode", b64encodeFn);
    try reg(interp, m, "standard_b64encode", b64encodeFn);
    try reg(interp, m, "b64decode", b64decodeFn);
    try reg(interp, m, "standard_b64decode", b64decodeFn);
    try reg(interp, m, "urlsafe_b64encode", urlsafeEncodeFn);
    try reg(interp, m, "urlsafe_b64decode", urlsafeDecodeFn);
    try reg(interp, m, "b32encode", b32encodeFn);
    try reg(interp, m, "b32decode", b32decodeFn);
    try reg(interp, m, "b16encode", b16encodeFn);
    try reg(interp, m, "b16decode", b16decodeFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn argBytes(v: Value) ![]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

// --- base64 (standard + url-safe) ---

const STD_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn b64encode(a: std.mem.Allocator, src: []const u8, alphabet: []const u8) ![]u8 {
    const out_len = ((src.len + 2) / 3) * 4;
    const out = try a.alloc(u8, out_len);
    var i: usize = 0;
    var j: usize = 0;
    while (i + 3 <= src.len) : (i += 3) {
        const b0 = src[i];
        const b1 = src[i + 1];
        const b2 = src[i + 2];
        out[j] = alphabet[b0 >> 2];
        out[j + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[j + 2] = alphabet[((b1 & 0x0f) << 2) | (b2 >> 6)];
        out[j + 3] = alphabet[b2 & 0x3f];
        j += 4;
    }
    const rem = src.len - i;
    if (rem == 1) {
        const b0 = src[i];
        out[j] = alphabet[b0 >> 2];
        out[j + 1] = alphabet[(b0 & 0x03) << 4];
        out[j + 2] = '=';
        out[j + 3] = '=';
    } else if (rem == 2) {
        const b0 = src[i];
        const b1 = src[i + 1];
        out[j] = alphabet[b0 >> 2];
        out[j + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[j + 2] = alphabet[(b1 & 0x0f) << 2];
        out[j + 3] = '=';
    }
    return out;
}

fn b64decode(a: std.mem.Allocator, src: []const u8, alphabet: []const u8) ![]u8 {
    if (src.len % 4 != 0) return error.InvalidBase64;
    var lookup: [256]i16 = .{-1} ** 256;
    for (alphabet, 0..) |c, idx| lookup[c] = @intCast(idx);

    // Strip trailing '='.
    var end = src.len;
    while (end > 0 and src[end - 1] == '=') end -= 1;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    var buf: u32 = 0;
    var bits: u32 = 0;
    for (src[0..end]) |c| {
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
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const enc = try b64encode(a, src, STD_ALPHABET);
    const b = try Bytes.fromOwnedSlice(a, enc);
    return Value{ .bytes = b };
}

fn b64decodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const dec = b64decode(a, src, STD_ALPHABET) catch |err| switch (err) {
        error.InvalidBase64 => {
            try interp.raisePy("ValueError", "invalid base64 input");
            return error.PyException;
        },
        else => return err,
    };
    const b = try Bytes.fromOwnedSlice(a, dec);
    return Value{ .bytes = b };
}

fn urlsafeEncodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const enc = try b64encode(a, src, URL_ALPHABET);
    const b = try Bytes.fromOwnedSlice(a, enc);
    return Value{ .bytes = b };
}

fn urlsafeDecodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const dec = try b64decode(a, src, URL_ALPHABET);
    const b = try Bytes.fromOwnedSlice(a, dec);
    return Value{ .bytes = b };
}

// --- base32 ---

const B32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

fn b32encode(a: std.mem.Allocator, src: []const u8) ![]u8 {
    const groups = (src.len + 4) / 5;
    const out_len = groups * 8;
    const out = try a.alloc(u8, out_len);
    var i: usize = 0;
    var j: usize = 0;
    while (i + 5 <= src.len) : (i += 5) {
        const v: u64 = (@as(u64, src[i]) << 32) | (@as(u64, src[i + 1]) << 24) | (@as(u64, src[i + 2]) << 16) | (@as(u64, src[i + 3]) << 8) | @as(u64, src[i + 4]);
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const shift: u6 = @intCast((7 - k) * 5);
            out[j + k] = B32_ALPHABET[(v >> shift) & 0x1f];
        }
        j += 8;
    }
    const rem = src.len - i;
    if (rem > 0) {
        var v: u64 = 0;
        var k: usize = 0;
        while (k < 5) : (k += 1) {
            v <<= 8;
            if (k < rem) v |= src[i + k];
        }
        // Number of valid output chars based on rem.
        const valid: usize = switch (rem) {
            1 => 2,
            2 => 4,
            3 => 5,
            4 => 7,
            else => 8,
        };
        var ki: usize = 0;
        while (ki < 8) : (ki += 1) {
            if (ki < valid) {
                const shift: u6 = @intCast((7 - ki) * 5);
                out[j + ki] = B32_ALPHABET[(v >> shift) & 0x1f];
            } else {
                out[j + ki] = '=';
            }
        }
    }
    return out;
}

fn b32decode(a: std.mem.Allocator, src: []const u8) ![]u8 {
    var lookup: [256]i16 = .{-1} ** 256;
    for (B32_ALPHABET, 0..) |c, idx| lookup[c] = @intCast(idx);

    var end = src.len;
    while (end > 0 and src[end - 1] == '=') end -= 1;

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
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const enc = try b32encode(a, src);
    const b = try Bytes.fromOwnedSlice(a, enc);
    return Value{ .bytes = b };
}

fn b32decodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const dec = try b32decode(a, src);
    const b = try Bytes.fromOwnedSlice(a, dec);
    return Value{ .bytes = b };
}

// --- base16 (uppercase hex) ---

fn b16encodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    const out = try a.alloc(u8, src.len * 2);
    const hex = "0123456789ABCDEF";
    for (src, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    const bv = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = bv };
}

fn b16decodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const src = try argBytes(args[0]);
    if (src.len % 2 != 0) return error.InvalidBase16;
    const out = try a.alloc(u8, src.len / 2);
    var i: usize = 0;
    while (i < src.len) : (i += 2) {
        out[i / 2] = (try hexVal(src[i])) * 16 + (try hexVal(src[i + 1]));
    }
    const bv = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = bv };
}

fn hexVal(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A' + 10,
        'a'...'f' => c - 'a' + 10,
        else => error.InvalidBase16,
    };
}

