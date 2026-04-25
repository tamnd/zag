//! Pinhole `uuid`. UUID values are instances whose dict carries
//! `bytes`, `hex`, `int`, `version`, `variant`, `urn`, `bytes_le`,
//! `fields`, plus a cached `_canon` string for `__str__`.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Str = @import("../object/string.zig").Str;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const BigInt = @import("../object/bigint.zig").BigInt;
const Tuple = @import("../object/tuple.zig").Tuple;
const Interp = @import("interp.zig").Interp;

const Md5 = std.crypto.hash.Md5;
const Sha1 = std.crypto.hash.Sha1;

var g_prng: ?std.Random.DefaultPrng = null;

fn rng() std.Random {
    if (g_prng == null) {
        g_prng = std.Random.DefaultPrng.init(0xC0FFEE1234567890);
    }
    return g_prng.?.random();
}

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "uuid");
    try ensureClass(interp);
    try regKw(interp, m, "UUID", uuidCtorFn, uuidCtorKw);
    try reg(interp, m, "uuid4", uuid4Fn);
    try reg(interp, m, "uuid5", uuid5Fn);
    try reg(interp, m, "uuid3", uuid3Fn);

    var ns_bytes: [16]u8 = undefined;
    parseHex("6ba7b810-9dad-11d1-80b4-00c04fd430c8", &ns_bytes) catch unreachable;
    const ns = try makeInstance(interp, ns_bytes);
    try m.attrs.setStr(interp.allocator, "NAMESPACE_DNS", ns);

    var ns_url: [16]u8 = undefined;
    parseHex("6ba7b811-9dad-11d1-80b4-00c04fd430c8", &ns_url) catch unreachable;
    const nu = try makeInstance(interp, ns_url);
    try m.attrs.setStr(interp.allocator, "NAMESPACE_URL", nu);

    var ns_oid: [16]u8 = undefined;
    parseHex("6ba7b812-9dad-11d1-80b4-00c04fd430c8", &ns_oid) catch unreachable;
    try m.attrs.setStr(interp.allocator, "NAMESPACE_OID", try makeInstance(interp, ns_oid));

    var ns_x500: [16]u8 = undefined;
    parseHex("6ba7b814-9dad-11d1-80b4-00c04fd430c8", &ns_x500) catch unreachable;
    try m.attrs.setStr(interp.allocator, "NAMESPACE_X500", try makeInstance(interp, ns_x500));

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

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn ensureClass(interp: *Interp) !void {
    if (interp.uuid_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "__str__", uuidStr);
    try methodReg(a, d, "__repr__", uuidRepr);
    try methodReg(a, d, "__eq__", uuidEq);
    try methodReg(a, d, "__ne__", uuidNe);
    try methodReg(a, d, "__hash__", uuidHash);
    interp.uuid_class = try Class.init(a, "UUID", &.{}, d);
}

fn argBytes(v: Value) ![]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn stripPrefixes(s: []const u8) []const u8 {
    var out = s;
    if (out.len >= 9 and (std.ascii.startsWithIgnoreCase(out, "urn:uuid:"))) out = out[9..];
    if (out.len >= 1 and out[0] == '{') out = out[1..];
    if (out.len >= 1 and out[out.len - 1] == '}') out = out[0 .. out.len - 1];
    return out;
}

fn parseHex(input: []const u8, out: *[16]u8) !void {
    const s = stripPrefixes(input);
    var i: usize = 0;
    var j: usize = 0;
    while (i < s.len) {
        if (s[i] == '-') {
            i += 1;
            continue;
        }
        if (j >= 16) return error.InvalidHex;
        if (i + 1 >= s.len) return error.InvalidHex;
        const hi = try hexNibble(s[i]);
        const lo = try hexNibble(s[i + 1]);
        out[j] = (hi << 4) | lo;
        j += 1;
        i += 2;
    }
    if (j != 16) return error.InvalidHex;
}

fn writeHex(dst: []u8, src: []const u8) void {
    const hex = "0123456789abcdef";
    for (src, 0..) |b, i| {
        dst[i * 2] = hex[b >> 4];
        dst[i * 2 + 1] = hex[b & 0x0f];
    }
}

fn canonical(a: std.mem.Allocator, raw: [16]u8) ![]u8 {
    var out = try a.alloc(u8, 36);
    var hex_buf: [32]u8 = undefined;
    writeHex(&hex_buf, raw[0..]);
    @memcpy(out[0..8], hex_buf[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex_buf[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex_buf[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex_buf[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex_buf[20..32]);
    return out;
}

fn variantString(b8: u8) []const u8 {
    const top = b8 >> 5;
    if (top < 0b100) return "reserved for NCS compatibility";
    if (top < 0b110) return "specified in RFC 4122";
    if (top < 0b111) return "reserved for Microsoft compatibility";
    return "reserved for future definition";
}

fn makeInstance(interp: *Interp, raw: [16]u8) !Value {
    try ensureClass(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.uuid_class.?);

    const bytes_copy = try a.dupe(u8, raw[0..]);
    const bv = try Bytes.fromOwnedSlice(a, bytes_copy);
    try inst.dict.setStr(a, "bytes", Value{ .bytes = bv });

    // bytes_le: swap fields 1 (4B), 2 (2B), 3 (2B), keep last 8 bytes.
    var le_buf: [16]u8 = undefined;
    le_buf[0] = raw[3];
    le_buf[1] = raw[2];
    le_buf[2] = raw[1];
    le_buf[3] = raw[0];
    le_buf[4] = raw[5];
    le_buf[5] = raw[4];
    le_buf[6] = raw[7];
    le_buf[7] = raw[6];
    @memcpy(le_buf[8..16], raw[8..16]);
    const le_bv = try Bytes.fromOwnedSlice(a, try a.dupe(u8, le_buf[0..]));
    try inst.dict.setStr(a, "bytes_le", Value{ .bytes = le_bv });

    const hex_buf = try a.alloc(u8, 32);
    writeHex(hex_buf, raw[0..]);
    const hex_s = try Str.init(a, hex_buf);
    a.free(hex_buf);
    try inst.dict.setStr(a, "hex", Value{ .str = hex_s });

    var u128_val: u128 = 0;
    for (raw) |b| u128_val = (u128_val << 8) | b;
    const big = try BigInt.fromManaged(
        a,
        try std.math.big.int.Managed.initSet(a, u128_val),
    );
    try inst.dict.setStr(a, "int", Value{ .big_int = big });

    const variant = raw[8] >> 6;
    if (variant == 0b10) {
        const ver: i64 = @intCast(raw[6] >> 4);
        try inst.dict.setStr(a, "version", Value{ .small_int = ver });
    } else {
        try inst.dict.setStr(a, "version", Value.none);
    }

    const var_str = try Str.init(a, variantString(raw[8]));
    try inst.dict.setStr(a, "variant", Value{ .str = var_str });

    const can = try canonical(a, raw);
    const can_s = try Str.init(a, can);
    try inst.dict.setStr(a, "_canon", Value{ .str = can_s });

    const urn_buf = try std.fmt.allocPrint(a, "urn:uuid:{s}", .{can});
    a.free(can);
    const urn_s = try Str.init(a, urn_buf);
    a.free(urn_buf);
    try inst.dict.setStr(a, "urn", Value{ .str = urn_s });

    // fields: (time_low, time_mid, time_hi_version, clock_seq_hi_variant, clock_seq_low, node)
    const tup = try Tuple.init(a, 6);
    const time_low: i64 = (@as(i64, raw[0]) << 24) | (@as(i64, raw[1]) << 16) | (@as(i64, raw[2]) << 8) | @as(i64, raw[3]);
    const time_mid: i64 = (@as(i64, raw[4]) << 8) | @as(i64, raw[5]);
    const time_hi: i64 = (@as(i64, raw[6]) << 8) | @as(i64, raw[7]);
    const clock_hi: i64 = @as(i64, raw[8]);
    const clock_lo: i64 = @as(i64, raw[9]);
    var node: i64 = 0;
    for (raw[10..16]) |b| node = (node << 8) | @as(i64, b);
    tup.items[0] = Value{ .small_int = time_low };
    tup.items[1] = Value{ .small_int = time_mid };
    tup.items[2] = Value{ .small_int = time_hi };
    tup.items[3] = Value{ .small_int = clock_hi };
    tup.items[4] = Value{ .small_int = clock_lo };
    tup.items[5] = Value{ .small_int = node };
    try inst.dict.setStr(a, "fields", Value{ .tuple = tup });

    return Value{ .instance = inst };
}

fn rawFromInstance(inst: *Instance) [16]u8 {
    const bv = inst.dict.getStr("bytes").?;
    var out: [16]u8 = undefined;
    @memcpy(out[0..], bv.bytes.data[0..16]);
    return out;
}

fn intToRaw16(allocator: std.mem.Allocator, big: *BigInt, raw: *[16]u8) !void {
    // Render as hex, left-pad to 32 chars, parse back.
    const hex_str = try big.inner.toString(allocator, 16, .lower);
    defer allocator.free(hex_str);
    if (hex_str.len > 32) return error.InvalidHex;
    var padded: [32]u8 = .{'0'} ** 32;
    @memcpy(padded[32 - hex_str.len ..], hex_str);
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const hi = try hexNibble(padded[i * 2]);
        const lo = try hexNibble(padded[i * 2 + 1]);
        raw[i] = (hi << 4) | lo;
    }
}

fn uuidCtorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return uuidCtorKw(p, args, &.{}, &.{});
}

fn uuidCtorKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var raw: [16]u8 = undefined;
    var have = false;

    if (args.len >= 1 and args[0] != .none) {
        const s = try argBytes(args[0]);
        parseHex(s, &raw) catch {
            try interp.raisePy("ValueError", "badly formed hexadecimal UUID string");
            return error.PyException;
        };
        have = true;
    }
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const name = kn.str.bytes;
        if (std.mem.eql(u8, name, "hex")) {
            const s = try argBytes(kv);
            parseHex(s, &raw) catch {
                try interp.raisePy("ValueError", "badly formed hexadecimal UUID string");
                return error.PyException;
            };
            have = true;
        } else if (std.mem.eql(u8, name, "bytes")) {
            const b = try argBytes(kv);
            if (b.len != 16) {
                try interp.raisePy("ValueError", "bytes is not a 16-char string");
                return error.PyException;
            }
            @memcpy(raw[0..], b[0..16]);
            have = true;
        } else if (std.mem.eql(u8, name, "bytes_le")) {
            const b = try argBytes(kv);
            if (b.len != 16) {
                try interp.raisePy("ValueError", "bytes_le is not 16 bytes");
                return error.PyException;
            }
            raw[0] = b[3];
            raw[1] = b[2];
            raw[2] = b[1];
            raw[3] = b[0];
            raw[4] = b[5];
            raw[5] = b[4];
            raw[6] = b[7];
            raw[7] = b[6];
            @memcpy(raw[8..16], b[8..16]);
            have = true;
        } else if (std.mem.eql(u8, name, "int")) {
            switch (kv) {
                .small_int => |i| {
                    var v: u128 = @intCast(i);
                    var k: usize = 16;
                    while (k > 0) {
                        k -= 1;
                        raw[k] = @truncate(v & 0xff);
                        v >>= 8;
                    }
                },
                .big_int => |bi| intToRaw16(interp.allocator, bi, &raw) catch {
                    try interp.raisePy("ValueError", "int out of range");
                    return error.PyException;
                },
                else => return error.TypeError,
            }
            have = true;
        }
    }
    if (!have) {
        try interp.raisePy("TypeError", "UUID requires hex, bytes, bytes_le, or int");
        return error.PyException;
    }
    return makeInstance(interp, raw);
}

fn uuid4Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    var raw: [16]u8 = undefined;
    rng().bytes(raw[0..]);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    return makeInstance(interp, raw);
}

fn uuid5Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const ns_raw = rawFromInstance(args[0].instance);
    const name = try argBytes(args[1]);

    var hasher = Sha1.init(.{});
    hasher.update(ns_raw[0..]);
    hasher.update(name);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);

    var raw: [16]u8 = undefined;
    @memcpy(raw[0..], digest[0..16]);
    raw[6] = (raw[6] & 0x0f) | 0x50;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    return makeInstance(interp, raw);
}

fn uuid3Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const ns_raw = rawFromInstance(args[0].instance);
    const name = try argBytes(args[1]);

    var hasher = Md5.init(.{});
    hasher.update(ns_raw[0..]);
    hasher.update(name);
    var digest: [16]u8 = undefined;
    hasher.final(&digest);

    var raw: [16]u8 = digest;
    raw[6] = (raw[6] & 0x0f) | 0x30;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    return makeInstance(interp, raw);
}

fn uuidStr(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance.dict.getStr("_canon").?;
}

fn uuidRepr(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const canon = args[0].instance.dict.getStr("_canon").?.str.bytes;
    const out = try std.fmt.allocPrint(a, "UUID('{s}')", .{canon});
    const s = try Str.init(a, out);
    a.free(out);
    return Value{ .str = s };
}

fn uuidEq(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    if (args[1] != .instance) return Value{ .boolean = false };
    const a_raw = rawFromInstance(args[0].instance);
    const b_raw = rawFromInstance(args[1].instance);
    return Value{ .boolean = std.mem.eql(u8, a_raw[0..], b_raw[0..]) };
}

fn uuidNe(p: *anyopaque, args: []const Value) anyerror!Value {
    const r = try uuidEq(p, args);
    return Value{ .boolean = !r.boolean };
}

fn uuidHash(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const raw = rawFromInstance(args[0].instance);
    var v: i64 = 0;
    for (raw) |b| v = (v *% 31) +% @as(i64, b);
    return Value{ .small_int = v };
}
