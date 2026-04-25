//! Pinhole `gzip`: compress / decompress. Reuses the LZ-based byte
//! format from zlib_mod -- not real gzip, just round-trip consistent.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Interp = @import("interp.zig").Interp;
const zlib_mod = @import("zlib_mod.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "gzip");
    try regKw(interp, m, "compress", compressFn, compressKw);
    try reg(interp, m, "decompress", decompressFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
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

const GZIP_HEADER = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff };

fn compressKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return compressFn(p, args);
}

fn compressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const data = try argBytes(args[0]);
    const lz = try zlib_mod.lzCompressPub(a, data);
    defer a.free(lz);
    const out = try a.alloc(u8, GZIP_HEADER.len + lz.len);
    @memcpy(out[0..GZIP_HEADER.len], &GZIP_HEADER);
    @memcpy(out[GZIP_HEADER.len..], lz);
    const b = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = b };
}

fn decompressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const data = try argBytes(args[0]);
    if (data.len < GZIP_HEADER.len or data[0] != 0x1f or data[1] != 0x8b) {
        try interp.raisePy("Exception", "not a gzip stream");
        return error.PyException;
    }
    const out = zlib_mod.lzDecompressPub(a, data[GZIP_HEADER.len..]) catch {
        try interp.raisePy("Exception", "decompression failed");
        return error.PyException;
    };
    const b = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = b };
}
