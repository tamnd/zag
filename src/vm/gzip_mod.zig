//! Pinhole `gzip`: compress / decompress. Reuses the LZ-based byte
//! format from zlib_mod -- not real gzip, just round-trip consistent.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Interp = @import("interp.zig").Interp;
const zlib_mod = @import("zlib_mod.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "gzip");
    try reg(interp, m, "compress", compressFn);
    try reg(interp, m, "decompress", decompressFn);
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

fn compressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const data = try argBytes(args[0]);
    const out = try zlib_mod.lzCompressPub(a, data);
    const b = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = b };
}

fn decompressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const data = try argBytes(args[0]);
    const out = zlib_mod.lzDecompressPub(a, data) catch {
        try interp.raisePy("Exception", "decompression failed");
        return error.PyException;
    };
    const b = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = b };
}
