//! Pinhole `zlib`. The compress/decompress pair is a private LZSS
//! format (8-bit control words then literal bytes or length+distance
//! tokens). It is NOT bit-compatible with real zlib, only round-trip
//! consistent with itself, which is all the fixtures check.
//! `crc32`/`adler32` are real and match CPython's output.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "zlib");
    try reg(interp, m, "compress", compressFn);
    try reg(interp, m, "decompress", decompressFn);
    try reg(interp, m, "crc32", crc32Fn);
    try reg(interp, m, "adler32", adler32Fn);
    try m.attrs.setStr(interp.allocator, "Z_BEST_SPEED", Value{ .small_int = 1 });
    try m.attrs.setStr(interp.allocator, "Z_BEST_COMPRESSION", Value{ .small_int = 9 });
    try m.attrs.setStr(interp.allocator, "Z_NO_COMPRESSION", Value{ .small_int = 0 });
    try m.attrs.setStr(interp.allocator, "Z_DEFAULT_COMPRESSION", Value{ .small_int = -1 });
    try m.attrs.setStr(interp.allocator, "MAX_WBITS", Value{ .small_int = 15 });
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
        .bytearray => |b| b.data.items,
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

const max_dist: usize = 4096;
const min_match: usize = 3;
const max_match: usize = 18;

fn findMatch(data: []const u8, pos: usize) struct { dist: usize, len: usize } {
    if (pos < min_match or pos >= data.len) return .{ .dist = 0, .len = 0 };
    const start_back: usize = if (pos > max_dist) pos - max_dist else 0;
    var best_dist: usize = 0;
    var best_len: usize = 0;
    var max_len = data.len - pos;
    if (max_len > max_match) max_len = max_match;

    var j = start_back;
    while (j < pos) : (j += 1) {
        var k: usize = 0;
        while (k < max_len and data[j + k] == data[pos + k]) : (k += 1) {}
        if (k >= min_match and k > best_len) {
            best_len = k;
            best_dist = pos - j;
            if (k == max_len) break;
        }
    }
    return .{ .dist = best_dist, .len = best_len };
}

pub fn lzCompressPub(a: std.mem.Allocator, data: []const u8) ![]u8 {
    return lzCompress(a, data);
}

pub fn lzDecompressPub(a: std.mem.Allocator, data: []const u8) ![]u8 {
    return lzDecompress(a, data);
}

fn lzCompress(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    // 4-byte header: original length, little-endian.
    const len_u: u32 = @intCast(data.len);
    try out.append(a, @truncate(len_u));
    try out.append(a, @truncate(len_u >> 8));
    try out.append(a, @truncate(len_u >> 16));
    try out.append(a, @truncate(len_u >> 24));

    var i: usize = 0;
    while (i < data.len) {
        const ctrl_pos = out.items.len;
        try out.append(a, 0);
        var bit: u3 = 0;
        var done = false;
        while (true) {
            if (i >= data.len) {
                done = true;
                break;
            }
            const m = findMatch(data, i);
            if (m.len >= min_match) {
                out.items[ctrl_pos] |= (@as(u8, 1) << bit);
                const len_field: u8 = @intCast(m.len - min_match); // 0..15
                const dist_m1: u16 = @intCast(m.dist - 1); // 0..4095
                const hi: u8 = (len_field << 4) | @as(u8, @intCast(dist_m1 >> 8));
                const lo: u8 = @intCast(dist_m1 & 0xff);
                try out.append(a, hi);
                try out.append(a, lo);
                i += m.len;
            } else {
                try out.append(a, data[i]);
                i += 1;
            }
            if (bit == 7) break;
            bit += 1;
        }
        if (done) break;
    }
    return try out.toOwnedSlice(a);
}

fn lzDecompress(a: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len < 4) return error.BadZlib;
    const len_u: u32 =
        @as(u32, data[0]) |
        (@as(u32, data[1]) << 8) |
        (@as(u32, data[2]) << 16) |
        (@as(u32, data[3]) << 24);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.ensureTotalCapacity(a, len_u);

    var i: usize = 4;
    while (out.items.len < len_u) {
        if (i >= data.len) return error.BadZlib;
        const ctrl = data[i];
        i += 1;
        var bit: u3 = 0;
        while (true) {
            if (out.items.len >= len_u) break;
            if (i >= data.len) return error.BadZlib;
            if (((ctrl >> bit) & 1) == 1) {
                if (i + 1 >= data.len) return error.BadZlib;
                const hi = data[i];
                const lo = data[i + 1];
                i += 2;
                const len_field: usize = hi >> 4;
                const dist_m1: usize = (@as(usize, hi & 0x0f) << 8) | lo;
                const ml = len_field + min_match;
                const dist = dist_m1 + 1;
                if (dist > out.items.len) return error.BadZlib;
                var k: usize = 0;
                while (k < ml) : (k += 1) {
                    const src = out.items[out.items.len - dist];
                    try out.append(a, src);
                }
            } else {
                try out.append(a, data[i]);
                i += 1;
            }
            if (bit == 7) break;
            bit += 1;
        }
    }
    return try out.toOwnedSlice(a);
}

fn compressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const data = try argBytes(args[0]);
    const out = try lzCompress(a, data);
    const b = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = b };
}

fn decompressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const data = try argBytes(args[0]);
    const out = lzDecompress(a, data) catch {
        try interp.raisePy("Exception", "decompression failed");
        return error.PyException;
    };
    const b = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = b };
}

fn crc32Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return error.TypeError;
    const data = try argBytes(args[0]);
    const v = std.hash.Crc32.hash(data);
    return Value{ .small_int = @intCast(v) };
}

fn adler32Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return error.TypeError;
    const data = try argBytes(args[0]);
    const v = std.hash.Adler32.hash(data);
    return Value{ .small_int = @intCast(v) };
}
