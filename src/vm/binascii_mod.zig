//! Pinhole `binascii`: hex/base64 conversion plus `crc32`. Stays
//! byte-for-byte compatible with CPython for the helpers the fixture
//! reaches for.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "binascii");
    try reg(interp, m, "hexlify", hexlifyFn);
    try reg(interp, m, "b2a_hex", hexlifyFn);
    try reg(interp, m, "unhexlify", unhexlifyFn);
    try reg(interp, m, "a2b_hex", unhexlifyFn);
    try regKw(interp, m, "b2a_base64", b2aBase64Fn, b2aBase64Kw);
    try reg(interp, m, "a2b_base64", a2bBase64Fn);
    try reg(interp, m, "crc32", crc32Fn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn argBytes(v: Value) ![]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

fn hexVal(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn hexlifyFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = try argBytes(args[0]);
    const out = try a.alloc(u8, src.len * 2);
    const hex = "0123456789abcdef";
    for (src, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    const bv = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = bv };
}

fn unhexlifyFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = try argBytes(args[0]);
    if (src.len % 2 != 0) {
        try interp.raisePy("ValueError", "odd-length hex string");
        return error.PyException;
    }
    const out = try a.alloc(u8, src.len / 2);
    var i: usize = 0;
    while (i < src.len) : (i += 2) {
        const hi = hexVal(src[i]) catch {
            a.free(out);
            try interp.raisePy("ValueError", "non-hex digit found");
            return error.PyException;
        };
        const lo = hexVal(src[i + 1]) catch {
            a.free(out);
            try interp.raisePy("ValueError", "non-hex digit found");
            return error.PyException;
        };
        out[i / 2] = (hi << 4) | lo;
    }
    const bv = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = bv };
}

const B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn b64encode(a: std.mem.Allocator, src: []const u8, with_newline: bool) ![]u8 {
    const enc_len = ((src.len + 2) / 3) * 4;
    const total = enc_len + @as(usize, if (with_newline) 1 else 0);
    const out = try a.alloc(u8, total);
    var i: usize = 0;
    var j: usize = 0;
    while (i + 3 <= src.len) : (i += 3) {
        const b0 = src[i];
        const b1 = src[i + 1];
        const b2 = src[i + 2];
        out[j] = B64_ALPHABET[b0 >> 2];
        out[j + 1] = B64_ALPHABET[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[j + 2] = B64_ALPHABET[((b1 & 0x0f) << 2) | (b2 >> 6)];
        out[j + 3] = B64_ALPHABET[b2 & 0x3f];
        j += 4;
    }
    const rem = src.len - i;
    if (rem == 1) {
        const b0 = src[i];
        out[j] = B64_ALPHABET[b0 >> 2];
        out[j + 1] = B64_ALPHABET[(b0 & 0x03) << 4];
        out[j + 2] = '=';
        out[j + 3] = '=';
    } else if (rem == 2) {
        const b0 = src[i];
        const b1 = src[i + 1];
        out[j] = B64_ALPHABET[b0 >> 2];
        out[j + 1] = B64_ALPHABET[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[j + 2] = B64_ALPHABET[(b1 & 0x0f) << 2];
        out[j + 3] = '=';
    }
    if (with_newline) out[enc_len] = '\n';
    return out;
}

fn b2aBase64Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return b2aBase64Kw(p, args, &.{}, &.{});
}

fn b2aBase64Kw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = try argBytes(args[0]);
    var newline = true;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "newline")) {
            newline = kv.isTruthy();
        }
    }
    const out = try b64encode(a, src, newline);
    const b = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = b };
}

fn a2bBase64Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = try argBytes(args[0]);
    var lookup: [256]i16 = .{-1} ** 256;
    for (B64_ALPHABET, 0..) |c, idx| lookup[c] = @intCast(idx);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: u32 = 0;
    var bits: u32 = 0;
    for (src) |c| {
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t' or c == '=') continue;
        const v = lookup[c];
        if (v < 0) {
            try interp.raisePy("ValueError", "invalid base64 input");
            return error.PyException;
        }
        buf = (buf << 6) | @as(u32, @intCast(v));
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            try out.append(a, @intCast((buf >> @intCast(bits)) & 0xff));
        }
    }
    const slice = try out.toOwnedSlice(a);
    const b = try Bytes.fromOwnedSlice(a, slice);
    return Value{ .bytes = b };
}

fn crc32Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return error.TypeError;
    const data = try argBytes(args[0]);
    const seed: u32 = if (args.len >= 2 and args[1] == .small_int)
        @truncate(@as(u64, @bitCast(args[1].small_int)))
    else
        0;
    var c = std.hash.Crc32.init();
    c.crc = seed ^ 0xFFFFFFFF;
    c.update(data);
    return Value{ .small_int = @intCast(c.final()) };
}
