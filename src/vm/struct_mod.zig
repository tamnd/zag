//! Pinhole `struct`: pack/unpack/calcsize/pack_into/unpack_from/iter_unpack
//! plus a Struct class. Codes: bBhHiIlLqQfdes?cxp. Endian byte ('<', '>',
//! '!', '=', '@') leads, then a sequence of count-prefixed format codes.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Bytearray = @import("../object/bytearray.zig").Bytearray;
const Tuple = @import("../object/tuple.zig").Tuple;
const List = @import("../object/list.zig").List;
const Iter = @import("../object/iter.zig").Iter;
const Str = @import("../object/string.zig").Str;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const BigInt = @import("../object/bigint.zig").BigInt;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "struct");
    try ensureClasses(interp);
    try m.attrs.setStr(a, "error", Value{ .class = interp.struct_error_class.? });
    try m.attrs.setStr(a, "Struct", blk: {
        const f = try a.create(BuiltinFn);
        f.* = .{ .name = "Struct", .func = structCtorFn };
        break :blk Value{ .builtin_fn = f };
    });
    try reg(interp, m, "calcsize", calcsizeFn);
    try reg(interp, m, "pack", packFn);
    try reg(interp, m, "unpack", unpackFn);
    try reg(interp, m, "unpack_from", unpackFromFn);
    try reg(interp, m, "pack_into", packIntoFn);
    try reg(interp, m, "iter_unpack", iterUnpackFn);
    return m;
}

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;
    if (interp.struct_error_class == null) {
        const exc_cls = blk: {
            if (interp.builtins.getStr("Exception")) |v| if (v == .class) break :blk v.class;
            break :blk null;
        };
        const d = try Dict.init(a);
        if (exc_cls) |ec| {
            interp.struct_error_class = try Class.init(a, "error", &.{ec}, d);
        } else {
            interp.struct_error_class = try Class.init(a, "error", &.{}, d);
        }
    }
    if (interp.struct_struct_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "pack", structPackMethod);
        try methodReg(a, d, "unpack", structUnpackMethod);
        try methodReg(a, d, "unpack_from", structUnpackFromMethod);
        try methodReg(a, d, "pack_into", structPackIntoMethod);
        try methodReg(a, d, "iter_unpack", structIterUnpackMethod);
        interp.struct_struct_class = try Class.init(a, "Struct", &.{}, d);
    }
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn raiseStructError(interp: *Interp, msg: []const u8) anyerror {
    const a = interp.allocator;
    const cls = interp.struct_error_class.?;
    const inst = Instance.init(a, cls) catch return error.OutOfMemory;
    const t = Tuple.init(a, 1) catch return error.OutOfMemory;
    const s = Str.init(a, msg) catch return error.OutOfMemory;
    t.items[0] = Value{ .str = s };
    inst.dict.setStr(a, "args", Value{ .tuple = t }) catch return error.OutOfMemory;
    interp.current_exc = Value{ .instance = inst };
    return error.PyException;
}

fn raiseStructErrorFmt(interp: *Interp, comptime fmt: []const u8, args: anytype) anyerror {
    const a = interp.allocator;
    const msg = std.fmt.allocPrint(a, fmt, args) catch return error.OutOfMemory;
    defer a.free(msg);
    return raiseStructError(interp, msg);
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
        'b', 'B', 'c', 'x', '?', 's', 'p' => 1,
        'h', 'H', 'e' => 2,
        'i', 'I', 'l', 'L', 'f' => 4,
        'q', 'Q', 'd' => 8,
        else => 0,
    };
}

fn isValidCode(c: u8) bool {
    return switch (c) {
        'b', 'B', 'c', 'x', '?', 's', 'p', 'h', 'H', 'e', 'i', 'I', 'l', 'L', 'f', 'q', 'Q', 'd' => true,
        else => false,
    };
}

const Field = struct { count: usize, code: u8 };

fn parseFields(interp: *Interp, body: []const u8) ![]Field {
    const a = interp.allocator;
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
        if (i >= body.len) return raiseStructError(interp, "bad char in struct format");
        const code = body[i];
        i += 1;
        if (!isValidCode(code)) {
            return raiseStructErrorFmt(interp, "bad char in struct format: '{c}'", .{code});
        }
        try out.append(a, .{ .count = if (any) count else 1, .code = code });
    }
    return out.toOwnedSlice(a);
}

fn fieldByteSize(f: Field) usize {
    if (f.code == 's' or f.code == 'p') return f.count;
    return f.count * codeSize(f.code);
}

fn formatSize(interp: *Interp, fmt: []const u8) !usize {
    const a = interp.allocator;
    const ep = parseEndian(fmt);
    const fields = try parseFields(interp, ep.rest);
    defer a.free(fields);
    var total: usize = 0;
    for (fields) |f| total += fieldByteSize(f);
    return total;
}

fn calcsizeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return raiseStructError(interp, "calcsize() argument must be str");
    const sz = try formatSize(interp, args[0].str.bytes);
    return Value{ .small_int = @intCast(sz) };
}

fn writeIntLe(buf: []u8, val: u128, n: usize) void {
    var v = val;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[i] = @truncate(v & 0xff);
        v >>= 8;
    }
}

fn writeIntBe(buf: []u8, val: u128, n: usize) void {
    var v = val;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[n - 1 - i] = @truncate(v & 0xff);
        v >>= 8;
    }
}

fn writeBits(buf: []u8, val: u128, n: usize, endian: Endian) void {
    if (endian == .little) writeIntLe(buf, val, n) else writeIntBe(buf, val, n);
}

fn readUInt(buf: []const u8, n: usize, endian: Endian) u128 {
    var v: u128 = 0;
    if (endian == .little) {
        var i: usize = n;
        while (i > 0) : (i -= 1) v = (v << 8) | buf[i - 1];
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

fn intFromValue(interp: *Interp, v: Value) !i128 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        .big_int => |bi| bi.inner.toInt(i128) catch return raiseStructError(interp, "int too large to convert"),
        else => raiseStructError(interp, "required argument is not an integer"),
    };
}

fn floatFromValue(interp: *Interp, v: Value) !f64 {
    return switch (v) {
        .small_int => |i| @floatFromInt(i),
        .boolean => |b| @floatFromInt(@intFromBool(b)),
        .float => |f| f,
        else => raiseStructError(interp, "required argument is not a float"),
    };
}

fn bytesFromValue(v: Value) ?[]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        .str => |s| s.bytes,
        else => null,
    };
}

fn writeableBytesFrom(v: Value) ?*Bytearray {
    return switch (v) {
        .bytearray => |b| b,
        else => null,
    };
}

fn intRangeCheck(interp: *Interp, v: i128, lo: i128, hi: i128) !void {
    if (v < lo or v > hi) {
        return raiseStructErrorFmt(
            interp,
            "argument out of range",
            .{},
        );
    }
}

fn maskU128(bits: u8) u128 {
    if (bits == 128) return ~@as(u128, 0);
    return (@as(u128, 1) << @intCast(bits)) - 1;
}

// IEEE 754 binary16 from f32: round-to-nearest-even.
fn f32ToHalfBits(x: f32) u16 {
    const u: u32 = @bitCast(x);
    const sign: u16 = @intCast((u >> 31) & 0x1);
    const exp32: i32 = @intCast((u >> 23) & 0xff);
    const mant32: u32 = u & 0x7fffff;
    if (exp32 == 0xff) {
        // inf or nan
        const m: u16 = if (mant32 != 0) 0x200 else 0;
        return (sign << 15) | 0x7c00 | m;
    }
    const e = exp32 - 127 + 15;
    if (e >= 0x1f) return (sign << 15) | 0x7c00; // overflow → inf
    if (e <= 0) {
        if (e < -10) return sign << 15; // underflow → 0
        // subnormal
        const mant_with_implicit: u32 = mant32 | 0x800000;
        const shift: u5 = @intCast(14 - e);
        var rounded: u32 = mant_with_implicit >> shift;
        const bit_under = (mant_with_implicit >> (shift - 1)) & 1;
        if (bit_under != 0) rounded += 1;
        return (sign << 15) | @as(u16, @intCast(rounded));
    }
    const mant16: u16 = @intCast(mant32 >> 13);
    var bits: u16 = (sign << 15) | (@as(u16, @intCast(e)) << 10) | mant16;
    if ((mant32 & 0x1000) != 0) bits += 1;
    return bits;
}

fn halfBitsToF32(h: u16) f32 {
    const sign: u32 = @intCast((h >> 15) & 0x1);
    const exp16: u32 = @intCast((h >> 10) & 0x1f);
    const mant16: u32 = @intCast(h & 0x3ff);
    const sign32: u32 = sign << 31;
    if (exp16 == 0) {
        if (mant16 == 0) return @bitCast(sign32);
        // subnormal
        var mant = mant16;
        var e: i32 = -1;
        while ((mant & 0x400) == 0) {
            mant <<= 1;
            e -= 1;
        }
        mant &= 0x3ff;
        const exp32: u32 = @intCast(127 - 15 + e + 1);
        return @bitCast(sign32 | (exp32 << 23) | (mant << 13));
    }
    if (exp16 == 0x1f) {
        const m32: u32 = mant16 << 13;
        return @bitCast(sign32 | 0x7f800000 | m32);
    }
    const exp32: u32 = exp16 + (127 - 15);
    return @bitCast(sign32 | (exp32 << 23) | (mant16 << 13));
}

const PackCtx = struct {
    fmt: []const u8,
    args: []const Value,
    arg_off: usize, // start index in args for values
};

fn packBytes(interp: *Interp, fmt: []const u8, args: []const Value) ![]u8 {
    const a = interp.allocator;
    const ep = parseEndian(fmt);
    const fields = try parseFields(interp, ep.rest);
    defer a.free(fields);

    var total: usize = 0;
    for (fields) |f| total += fieldByteSize(f);
    const out = try a.alloc(u8, total);
    @memset(out, 0);
    var off: usize = 0;
    var arg_i: usize = 0;

    for (fields) |f| {
        if (f.code == 's') {
            if (arg_i >= args.len) return raiseStructError(interp, "pack expected more arguments");
            const data = bytesFromValue(args[arg_i]) orelse return raiseStructError(interp, "argument must be bytes");
            arg_i += 1;
            const n = f.count;
            const cp = @min(n, data.len);
            @memcpy(out[off .. off + cp], data[0..cp]);
            if (cp < n) @memset(out[off + cp .. off + n], 0);
            off += n;
            continue;
        }
        if (f.code == 'p') {
            if (arg_i >= args.len) return raiseStructError(interp, "pack expected more arguments");
            const data = bytesFromValue(args[arg_i]) orelse return raiseStructError(interp, "argument must be bytes");
            arg_i += 1;
            const n = f.count;
            if (n == 0) {
                continue;
            }
            const max_data = if (n - 1 < 255) n - 1 else 255;
            const cp = @min(max_data, data.len);
            out[off] = @intCast(cp);
            @memcpy(out[off + 1 .. off + 1 + cp], data[0..cp]);
            if (1 + cp < n) @memset(out[off + 1 + cp .. off + n], 0);
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
            if (arg_i >= args.len) return raiseStructError(interp, "pack expected more arguments");
            const v = args[arg_i];
            arg_i += 1;
            const sz = codeSize(f.code);
            switch (f.code) {
                'b' => {
                    const x = try intFromValue(interp, v);
                    try intRangeCheck(interp, x, -128, 127);
                    writeBits(out[off..], @bitCast(@as(i128, x)), sz, ep.endian);
                },
                'h' => {
                    const x = try intFromValue(interp, v);
                    try intRangeCheck(interp, x, -32768, 32767);
                    writeBits(out[off..], @bitCast(@as(i128, x)), sz, ep.endian);
                },
                'i', 'l' => {
                    const x = try intFromValue(interp, v);
                    try intRangeCheck(interp, x, -2147483648, 2147483647);
                    writeBits(out[off..], @as(u128, @bitCast(x)) & maskU128(@intCast(sz * 8)), sz, ep.endian);
                },
                'q' => {
                    const x = try intFromValue(interp, v);
                    writeBits(out[off..], @as(u128, @bitCast(x)) & maskU128(@intCast(sz * 8)), sz, ep.endian);
                },
                'B' => {
                    const x = try intFromValue(interp, v);
                    try intRangeCheck(interp, x, 0, 255);
                    writeBits(out[off..], @bitCast(@as(i128, x)), sz, ep.endian);
                },
                'H' => {
                    const x = try intFromValue(interp, v);
                    try intRangeCheck(interp, x, 0, 65535);
                    writeBits(out[off..], @bitCast(@as(i128, x)), sz, ep.endian);
                },
                'I', 'L' => {
                    const x = try intFromValue(interp, v);
                    try intRangeCheck(interp, x, 0, 4294967295);
                    writeBits(out[off..], @bitCast(@as(i128, x)), sz, ep.endian);
                },
                'Q' => {
                    const x = try intFromValue(interp, v);
                    writeBits(out[off..], @as(u128, @bitCast(x)) & maskU128(64), sz, ep.endian);
                },
                '?' => {
                    out[off] = if (v.isTruthy()) 1 else 0;
                },
                'f' => {
                    const f32v: f32 = @floatCast(try floatFromValue(interp, v));
                    const bits: u32 = @bitCast(f32v);
                    writeBits(out[off..], @intCast(bits), sz, ep.endian);
                },
                'd' => {
                    const f64v: f64 = try floatFromValue(interp, v);
                    const bits: u64 = @bitCast(f64v);
                    writeBits(out[off..], @intCast(bits), sz, ep.endian);
                },
                'e' => {
                    const f32v: f32 = @floatCast(try floatFromValue(interp, v));
                    const h: u16 = f32ToHalfBits(f32v);
                    writeBits(out[off..], @intCast(h), sz, ep.endian);
                },
                'c' => {
                    const data = bytesFromValue(v) orelse return raiseStructError(interp, "char must be bytes");
                    if (data.len != 1) return raiseStructError(interp, "char arg must be a bytes object of length 1");
                    out[off] = data[0];
                },
                else => return raiseStructError(interp, "bad char in struct format"),
            }
            off += sz;
        }
    }
    return out;
}

fn packFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return raiseStructError(interp, "pack() format must be str");
    const out = try packBytes(interp, args[0].str.bytes, args[1..]);
    const b = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = b };
}

fn unpackInto(interp: *Interp, fmt: []const u8, buf: []const u8, offset: usize, exact: bool) !*Tuple {
    const a = interp.allocator;
    const ep = parseEndian(fmt);
    const fields = try parseFields(interp, ep.rest);
    defer a.free(fields);

    var total: usize = 0;
    for (fields) |f| total += fieldByteSize(f);
    if (exact and offset == 0 and buf.len != total) {
        return raiseStructErrorFmt(interp, "unpack requires a buffer of {d} bytes", .{total});
    }
    if (offset + total > buf.len) {
        return raiseStructErrorFmt(interp, "unpack requires a buffer of at least {d} bytes for unpacking", .{total});
    }

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
        if (f.code == 'p') {
            const n = f.count;
            const len_byte: usize = if (n == 0) 0 else buf[off];
            const cap = if (n == 0) 0 else n - 1;
            const len_used = @min(len_byte, cap);
            const b = try Bytes.init(a, buf[off + 1 .. off + 1 + len_used]);
            try out.append(a, Value{ .bytes = b });
            off += n;
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
                'e' => {
                    const u = readUInt(buf[off..], sz, ep.endian);
                    const h: u16 = @intCast(u);
                    const f32v: f32 = halfBitsToF32(h);
                    try out.append(a, Value{ .float = @floatCast(f32v) });
                },
                'c' => {
                    const b = try Bytes.init(a, buf[off .. off + 1]);
                    try out.append(a, Value{ .bytes = b });
                },
                else => return raiseStructError(interp, "bad char in struct format"),
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
    if (args.len < 2 or args[0] != .str) return raiseStructError(interp, "unpack() format must be str");
    const buf = bytesFromValue(args[1]) orelse return raiseStructError(interp, "unpack() buffer must be bytes-like");
    const t = try unpackInto(interp, args[0].str.bytes, buf, 0, true);
    return Value{ .tuple = t };
}

fn unpackFromFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str) return raiseStructError(interp, "unpack_from() format must be str");
    const buf = bytesFromValue(args[1]) orelse return raiseStructError(interp, "unpack_from() buffer must be bytes-like");
    const offset: usize = if (args.len >= 3 and args[2] == .small_int and args[2].small_int >= 0)
        @intCast(args[2].small_int)
    else
        0;
    const t = try unpackInto(interp, args[0].str.bytes, buf, offset, false);
    return Value{ .tuple = t };
}

fn packIntoFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3 or args[0] != .str) return raiseStructError(interp, "pack_into requires format, buffer, offset");
    const ba = writeableBytesFrom(args[1]) orelse return raiseStructError(interp, "pack_into buffer must be a writable bytes-like object");
    const off = switch (args[2]) {
        .small_int => |n| n,
        .boolean => |b| @as(i64, @intFromBool(b)),
        else => return raiseStructError(interp, "pack_into offset must be int"),
    };
    const packed_bytes = try packBytes(interp, args[0].str.bytes, args[3..]);
    defer a.free(packed_bytes);
    if (off < 0 or @as(usize, @intCast(off)) + packed_bytes.len > ba.data.items.len) {
        return raiseStructErrorFmt(interp, "pack_into requires a buffer of at least {d} bytes", .{@as(usize, @intCast(off)) + packed_bytes.len});
    }
    @memcpy(ba.data.items[@intCast(off) .. @as(usize, @intCast(off)) + packed_bytes.len], packed_bytes);
    return Value.none;
}

fn iterUnpackBuild(interp: *Interp, fmt: []const u8, data: []const u8) !Value {
    const a = interp.allocator;
    const item_size = try formatSize(interp, fmt);
    if (item_size == 0) return raiseStructError(interp, "iter_unpack format size is 0");
    if (data.len % item_size != 0) {
        return raiseStructErrorFmt(interp, "iterative unpacking requires a buffer whose length is a multiple of {d}", .{item_size});
    }
    const lst = try List.init(a);
    var pos: usize = 0;
    while (pos < data.len) : (pos += item_size) {
        const t = try unpackInto(interp, fmt, data[pos .. pos + item_size], 0, false);
        try lst.items.append(a, Value{ .tuple = t });
    }
    const it = try Iter.init(a, .{ .list = lst });
    return Value{ .iter = it };
}

fn iterUnpackFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str) return raiseStructError(interp, "iter_unpack() format must be str");
    const buf = bytesFromValue(args[1]) orelse return raiseStructError(interp, "iter_unpack() buffer must be bytes-like");
    return iterUnpackBuild(interp, args[0].str.bytes, buf);
}

// ---- Struct class ----

fn structCtorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    try ensureClasses(interp);
    if (args.len < 1 or args[0] != .str) return raiseStructError(interp, "Struct() format must be str");
    const fmt = args[0].str.bytes;
    const sz = try formatSize(interp, fmt);
    const inst = try Instance.init(a, interp.struct_struct_class.?);
    const fmt_dup = try Str.init(a, fmt);
    try inst.dict.setStr(a, "format", Value{ .str = fmt_dup });
    try inst.dict.setStr(a, "size", Value{ .small_int = @intCast(sz) });
    return Value{ .instance = inst };
}

fn structFmt(args: []const Value) ?[]const u8 {
    if (args.len < 1 or args[0] != .instance) return null;
    const v = args[0].instance.dict.getStr("format") orelse return null;
    if (v != .str) return null;
    return v.str.bytes;
}

fn structPackMethod(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const fmt = structFmt(args) orelse return raiseStructError(interp, "Struct.pack: bad self");
    const out = try packBytes(interp, fmt, args[1..]);
    const b = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = b };
}

fn structUnpackMethod(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const fmt = structFmt(args) orelse return raiseStructError(interp, "Struct.unpack: bad self");
    if (args.len < 2) return raiseStructError(interp, "unpack() missing buffer");
    const buf = bytesFromValue(args[1]) orelse return raiseStructError(interp, "unpack() buffer must be bytes-like");
    const t = try unpackInto(interp, fmt, buf, 0, true);
    return Value{ .tuple = t };
}

fn structUnpackFromMethod(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const fmt = structFmt(args) orelse return raiseStructError(interp, "Struct.unpack_from: bad self");
    if (args.len < 2) return raiseStructError(interp, "unpack_from() missing buffer");
    const buf = bytesFromValue(args[1]) orelse return raiseStructError(interp, "unpack_from() buffer must be bytes-like");
    const offset: usize = if (args.len >= 3 and args[2] == .small_int and args[2].small_int >= 0)
        @intCast(args[2].small_int)
    else
        0;
    const t = try unpackInto(interp, fmt, buf, offset, false);
    return Value{ .tuple = t };
}

fn structPackIntoMethod(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const fmt = structFmt(args) orelse return raiseStructError(interp, "Struct.pack_into: bad self");
    if (args.len < 3) return raiseStructError(interp, "pack_into requires buffer and offset");
    const ba = writeableBytesFrom(args[1]) orelse return raiseStructError(interp, "pack_into buffer must be a writable bytes-like object");
    const off = switch (args[2]) {
        .small_int => |n| n,
        .boolean => |b| @as(i64, @intFromBool(b)),
        else => return raiseStructError(interp, "pack_into offset must be int"),
    };
    const packed_bytes = try packBytes(interp, fmt, args[3..]);
    defer a.free(packed_bytes);
    if (off < 0 or @as(usize, @intCast(off)) + packed_bytes.len > ba.data.items.len) {
        return raiseStructErrorFmt(interp, "pack_into requires a buffer of at least {d} bytes", .{@as(usize, @intCast(off)) + packed_bytes.len});
    }
    @memcpy(ba.data.items[@intCast(off) .. @as(usize, @intCast(off)) + packed_bytes.len], packed_bytes);
    return Value.none;
}

fn structIterUnpackMethod(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const fmt = structFmt(args) orelse return raiseStructError(interp, "Struct.iter_unpack: bad self");
    if (args.len < 2) return raiseStructError(interp, "iter_unpack() missing buffer");
    const buf = bytesFromValue(args[1]) orelse return raiseStructError(interp, "iter_unpack() buffer must be bytes-like");
    return iterUnpackBuild(interp, fmt, buf);
}
