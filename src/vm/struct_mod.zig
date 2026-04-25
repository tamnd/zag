//! Pinhole `struct`: pack/unpack/calcsize/unpack_from for the fixture's
//! format strings. Endian byte ('<', '>', '!', '=', '@') leads, then
//! a sequence of count-prefixed format codes.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Tuple = @import("../object/tuple.zig").Tuple;
const BigInt = @import("../object/bigint.zig").BigInt;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "struct");
    try reg(interp, m, "calcsize", calcsizeFn);
    try reg(interp, m, "pack", packFn);
    try reg(interp, m, "unpack", unpackFn);
    try reg(interp, m, "unpack_from", unpackFromFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

const Endian = enum { little, big };

fn parseEndian(fmt: []const u8) struct { endian: Endian, rest: []const u8 } {
    if (fmt.len == 0) return .{ .endian = .little, .rest = fmt };
    return switch (fmt[0]) {
        '<' => .{ .endian = .little, .rest = fmt[1..] },
        '>', '!' => .{ .endian = .big, .rest = fmt[1..] },
        '=', '@' => .{ .endian = .little, .rest = fmt[1..] },
        else => .{ .endian = .little, .rest = fmt },
    };
}

fn codeSize(c: u8) usize {
    return switch (c) {
        'b', 'B', 'c', 'x', '?', 's' => 1,
        'h', 'H' => 2,
        'i', 'I', 'l', 'L', 'f' => 4,
        'q', 'Q', 'd' => 8,
        else => 0,
    };
}

const Field = struct { count: usize, code: u8 };

fn parseFields(a: std.mem.Allocator, body: []const u8) ![]Field {
    var out: std.ArrayList(Field) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < body.len) {
        while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
        if (i >= body.len) break;
        var count: usize = 0;
        var any = false;
        while (i < body.len and body[i] >= '0' and body[i] <= '9') {
            count = count * 10 + (body[i] - '0');
            i += 1;
            any = true;
        }
        if (i >= body.len) return error.BadStruct;
        const code = body[i];
        i += 1;
        try out.append(a, .{ .count = if (any) count else 1, .code = code });
    }
    return out.toOwnedSlice(a);
}

fn fieldByteSize(f: Field) usize {
    if (f.code == 's') return f.count;
    return f.count * codeSize(f.code);
}

fn formatSize(a: std.mem.Allocator, fmt: []const u8) !usize {
    const ep = parseEndian(fmt);
    const fields = try parseFields(a, ep.rest);
    defer a.free(fields);
    var total: usize = 0;
    for (fields) |f| total += fieldByteSize(f);
    return total;
}

fn calcsizeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const sz = try formatSize(interp.allocator, args[0].str.bytes);
    return Value{ .small_int = @intCast(sz) };
}

fn writeIntLe(buf: []u8, val: i128, n: usize) void {
    var v: u128 = @bitCast(val);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[i] = @truncate(v & 0xff);
        v >>= 8;
    }
}

fn writeIntBe(buf: []u8, val: i128, n: usize) void {
    var v: u128 = @bitCast(val);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[n - 1 - i] = @truncate(v & 0xff);
        v >>= 8;
    }
}

fn readUInt(buf: []const u8, n: usize, endian: Endian) u128 {
    var v: u128 = 0;
    if (endian == .little) {
        var i: usize = n;
        while (i > 0) : (i -= 1) {
            v = (v << 8) | buf[i - 1];
        }
    } else {
        for (buf[0..n]) |b| v = (v << 8) | b;
    }
    return v;
}

fn signExtend(v: u128, n: usize) i128 {
    const bits: u8 = @intCast(n * 8);
    const sign_bit = (@as(u128, 1) << @intCast(bits - 1));
    if ((v & sign_bit) != 0) {
        const mask = (@as(u128, 1) << @intCast(bits)) - 1;
        return @as(i128, @bitCast(v | ~mask));
    }
    return @intCast(v);
}

fn intValueFromI128(a: std.mem.Allocator, v: i128) !Value {
    if (v >= std.math.minInt(i64) and v <= std.math.maxInt(i64)) {
        return Value{ .small_int = @intCast(v) };
    }
    const neg = v < 0;
    const mag: u128 = @intCast(if (neg) -v else v);
    const hi: u64 = @truncate(mag >> 64);
    const lo: u64 = @truncate(mag);
    var managed = try std.math.big.int.Managed.initSet(a, hi);
    errdefer managed.deinit();
    try managed.shiftLeft(&managed, 64);
    var lo_m = try std.math.big.int.Managed.initSet(a, lo);
    defer lo_m.deinit();
    try managed.add(&managed, &lo_m);
    if (neg) managed.negate();
    const big = try BigInt.fromManaged(a, managed);
    return Value{ .big_int = big };
}

fn intValueFromU128(a: std.mem.Allocator, v: u128) !Value {
    if (v <= std.math.maxInt(i64)) return Value{ .small_int = @intCast(v) };
    const hi: u64 = @truncate(v >> 64);
    const lo: u64 = @truncate(v);
    var managed = try std.math.big.int.Managed.initSet(a, hi);
    errdefer managed.deinit();
    try managed.shiftLeft(&managed, 64);
    var lo_m = try std.math.big.int.Managed.initSet(a, lo);
    defer lo_m.deinit();
    try managed.add(&managed, &lo_m);
    const big = try BigInt.fromManaged(a, managed);
    return Value{ .big_int = big };
}

fn intFromValue(v: Value) !i128 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        .big_int => |bi| bi.inner.toInt(i128) catch error.TypeError,
        else => error.TypeError,
    };
}

fn floatFromValue(v: Value) !f64 {
    return switch (v) {
        .small_int => |i| @floatFromInt(i),
        .float => |f| f,
        else => error.TypeError,
    };
}

fn bytesFromValue(v: Value) ![]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

fn packFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const fmt = args[0].str.bytes;
    const ep = parseEndian(fmt);
    const fields = try parseFields(a, ep.rest);
    defer a.free(fields);

    const total = blk: {
        var t: usize = 0;
        for (fields) |f| t += fieldByteSize(f);
        break :blk t;
    };
    const out = try a.alloc(u8, total);
    var off: usize = 0;
    var arg_i: usize = 1;

    for (fields) |f| {
        if (f.code == 's') {
            if (arg_i >= args.len) return error.TypeError;
            const data = try bytesFromValue(args[arg_i]);
            arg_i += 1;
            const n = f.count;
            const cp = @min(n, data.len);
            @memcpy(out[off .. off + cp], data[0..cp]);
            if (cp < n) @memset(out[off + cp .. off + n], 0);
            off += n;
            continue;
        }
        if (f.code == 'x') {
            @memset(out[off .. off + f.count], 0);
            off += f.count;
            continue;
        }
        var k: usize = 0;
        while (k < f.count) : (k += 1) {
            if (arg_i >= args.len) return error.TypeError;
            const v = args[arg_i];
            arg_i += 1;
            const sz = codeSize(f.code);
            switch (f.code) {
                'b', 'h', 'i', 'l', 'q' => {
                    const x = try intFromValue(v);
                    if (ep.endian == .little) writeIntLe(out[off..], x, sz) else writeIntBe(out[off..], x, sz);
                },
                'B', 'H', 'I', 'L', 'Q' => {
                    const x = try intFromValue(v);
                    if (ep.endian == .little) writeIntLe(out[off..], x, sz) else writeIntBe(out[off..], x, sz);
                },
                '?' => {
                    out[off] = if (v.isTruthy()) 1 else 0;
                },
                'f' => {
                    const f32v: f32 = @floatCast(try floatFromValue(v));
                    const bits: u32 = @bitCast(f32v);
                    if (ep.endian == .little) writeIntLe(out[off..], @intCast(bits), sz) else writeIntBe(out[off..], @intCast(bits), sz);
                },
                'd' => {
                    const f64v: f64 = try floatFromValue(v);
                    const bits: u64 = @bitCast(f64v);
                    if (ep.endian == .little) writeIntLe(out[off..], @intCast(bits), sz) else writeIntBe(out[off..], @intCast(bits), sz);
                },
                'c' => {
                    const data = try bytesFromValue(v);
                    if (data.len < 1) return error.TypeError;
                    out[off] = data[0];
                },
                else => return error.BadStruct,
            }
            off += sz;
        }
    }
    const b = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = b };
}

fn unpackInto(a: std.mem.Allocator, fmt: []const u8, buf: []const u8, offset: usize) !*Tuple {
    const ep = parseEndian(fmt);
    const fields = try parseFields(a, ep.rest);
    defer a.free(fields);

    var total: usize = 0;
    for (fields) |f| total += fieldByteSize(f);
    if (offset + total > buf.len) return error.OutOfBounds;

    var out: std.ArrayList(Value) = .empty;
    errdefer out.deinit(a);

    var off = offset;
    for (fields) |f| {
        if (f.code == 's') {
            const slice = buf[off .. off + f.count];
            const b = try Bytes.init(a, slice);
            try out.append(a, Value{ .bytes = b });
            off += f.count;
            continue;
        }
        if (f.code == 'x') {
            off += f.count;
            continue;
        }
        var k: usize = 0;
        while (k < f.count) : (k += 1) {
            const sz = codeSize(f.code);
            switch (f.code) {
                'b', 'h', 'i', 'l', 'q' => {
                    const u = readUInt(buf[off..], sz, ep.endian);
                    const s = signExtend(u, sz);
                    try out.append(a, try intValueFromI128(a, s));
                },
                'B', 'H', 'I', 'L', 'Q' => {
                    const u = readUInt(buf[off..], sz, ep.endian);
                    try out.append(a, try intValueFromU128(a, u));
                },
                '?' => {
                    try out.append(a, Value{ .boolean = buf[off] != 0 });
                },
                'f' => {
                    const u = readUInt(buf[off..], sz, ep.endian);
                    const bits: u32 = @intCast(u);
                    const f32v: f32 = @bitCast(bits);
                    try out.append(a, Value{ .float = @floatCast(f32v) });
                },
                'd' => {
                    const u = readUInt(buf[off..], sz, ep.endian);
                    const bits: u64 = @intCast(u);
                    const f64v: f64 = @bitCast(bits);
                    try out.append(a, Value{ .float = f64v });
                },
                'c' => {
                    const b = try Bytes.init(a, buf[off .. off + 1]);
                    try out.append(a, Value{ .bytes = b });
                },
                else => return error.BadStruct,
            }
            off += sz;
        }
    }

    const t = try Tuple.init(a, out.items.len);
    for (out.items, 0..) |v, i| t.items[i] = v;
    out.deinit(a);
    return t;
}

fn unpackFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .str) return error.TypeError;
    const buf = try bytesFromValue(args[1]);
    const t = try unpackInto(a, args[0].str.bytes, buf, 0);
    return Value{ .tuple = t };
}

fn unpackFromFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .str) return error.TypeError;
    const buf = try bytesFromValue(args[1]);
    const offset: usize = if (args.len >= 3 and args[2] == .small_int and args[2].small_int >= 0)
        @intCast(args[2].small_int)
    else
        0;
    const t = try unpackInto(a, args[0].str.bytes, buf, offset);
    return Value{ .tuple = t };
}
