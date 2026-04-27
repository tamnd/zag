//! Pinhole `hmac`: RFC 2104 keyed hash on top of `hashlib`. Keeps a
//! cached running state on the instance dict so successive `update`
//! calls work; `digest`/`hexdigest` finalize a clone, leaving the
//! state intact.

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
const Interp = @import("interp.zig").Interp;

const Md5 = std.crypto.hash.Md5;
const Sha1 = std.crypto.hash.Sha1;
const Sha224 = std.crypto.hash.sha2.Sha224;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Sha3_256 = std.crypto.hash.sha3.Sha3_256;
const Sha3_512 = std.crypto.hash.sha3.Sha3_512;

const Algo = enum { md5, sha1, sha224, sha256, sha384, sha512, sha3_256, sha3_512 };

const State = union(Algo) {
    md5: Md5,
    sha1: Sha1,
    sha224: Sha224,
    sha256: Sha256,
    sha384: Sha384,
    sha512: Sha512,
    sha3_256: Sha3_256,
    sha3_512: Sha3_512,
};

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "hmac");
    try ensureClass(interp);
    try regKw(interp, m, "new", newFn, newKw);
    try reg(interp, m, "digest", digestFn);
    try reg(interp, m, "compare_digest", compareDigestFn);
    return m;
}

fn methodRegKw(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
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
    if (interp.hmac_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "update", hmacUpdate);
    try methodReg(a, d, "digest", hmacDigest);
    try methodReg(a, d, "hexdigest", hmacHexdigest);
    try methodReg(a, d, "copy", hmacCopy);
    interp.hmac_class = try Class.init(a, "HMAC", &.{}, d);
}

fn argBytes(v: Value) ![]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

fn algoFromValue(v: Value) ?Algo {
    const name = switch (v) {
        .str => |s| s.bytes,
        .builtin_fn => |f| f.name,
        else => return null,
    };
    if (std.mem.eql(u8, name, "md5")) return .md5;
    if (std.mem.eql(u8, name, "sha1")) return .sha1;
    if (std.mem.eql(u8, name, "sha224")) return .sha224;
    if (std.mem.eql(u8, name, "sha256")) return .sha256;
    if (std.mem.eql(u8, name, "sha384")) return .sha384;
    if (std.mem.eql(u8, name, "sha512")) return .sha512;
    if (std.mem.eql(u8, name, "sha3_256")) return .sha3_256;
    if (std.mem.eql(u8, name, "sha3_512")) return .sha3_512;
    return null;
}

fn algoBlockSize(a: Algo) usize {
    return switch (a) {
        .md5, .sha1, .sha224, .sha256 => 64,
        .sha384, .sha512 => 128,
        .sha3_256 => 136,
        .sha3_512 => 72,
    };
}

fn algoDigestSize(a: Algo) usize {
    return switch (a) {
        .md5 => 16,
        .sha1 => 20,
        .sha224 => 28,
        .sha256 => 32,
        .sha384 => 48,
        .sha512 => 64,
        .sha3_256 => 32,
        .sha3_512 => 64,
    };
}

fn algoName(a: Algo) []const u8 {
    return switch (a) {
        .md5 => "md5",
        .sha1 => "sha1",
        .sha224 => "sha224",
        .sha256 => "sha256",
        .sha384 => "sha384",
        .sha512 => "sha512",
        .sha3_256 => "sha3_256",
        .sha3_512 => "sha3_512",
    };
}

fn initState(a: Algo) State {
    return switch (a) {
        .md5 => .{ .md5 = Md5.init(.{}) },
        .sha1 => .{ .sha1 = Sha1.init(.{}) },
        .sha224 => .{ .sha224 = Sha224.init(.{}) },
        .sha256 => .{ .sha256 = Sha256.init(.{}) },
        .sha384 => .{ .sha384 = Sha384.init(.{}) },
        .sha512 => .{ .sha512 = Sha512.init(.{}) },
        .sha3_256 => .{ .sha3_256 = Sha3_256.init(.{}) },
        .sha3_512 => .{ .sha3_512 = Sha3_512.init(.{}) },
    };
}

fn updateState(s: *State, data: []const u8) void {
    switch (s.*) {
        .md5 => |*h| h.update(data),
        .sha1 => |*h| h.update(data),
        .sha224 => |*h| h.update(data),
        .sha256 => |*h| h.update(data),
        .sha384 => |*h| h.update(data),
        .sha512 => |*h| h.update(data),
        .sha3_256 => |*h| h.update(data),
        .sha3_512 => |*h| h.update(data),
    }
}

fn finalState(s: *State, out: []u8) void {
    var copy = s.*;
    switch (copy) {
        .md5 => |*h| h.final(out[0..16]),
        .sha1 => |*h| h.final(out[0..20]),
        .sha224 => |*h| h.final(out[0..28]),
        .sha256 => |*h| h.final(out[0..32]),
        .sha384 => |*h| h.final(out[0..48]),
        .sha512 => |*h| h.final(out[0..64]),
        .sha3_256 => |*h| h.final(out[0..32]),
        .sha3_512 => |*h| h.final(out[0..64]),
    }
}

fn hashOnce(a: Algo, data: []const u8, out: []u8) void {
    var s = initState(a);
    updateState(&s, data);
    finalState(&s, out);
}

// 200 covers all supported block sizes: SHA3-256=136, SHA-512=128, etc.
const MAX_BLOCK = 200;

const HmacState = struct {
    algo: Algo,
    inner: State,
    outer_key: [MAX_BLOCK]u8,
    outer_key_len: usize,
};

fn newHmacState(allocator: std.mem.Allocator, algo: Algo, key: []const u8) !*HmacState {
    const block_size = algoBlockSize(algo);
    var key_buf: [MAX_BLOCK]u8 = undefined;
    @memset(key_buf[0..block_size], 0);
    if (key.len > block_size) {
        var tmp: [64]u8 = undefined;
        const ds = algoDigestSize(algo);
        hashOnce(algo, key, tmp[0..ds]);
        @memcpy(key_buf[0..ds], tmp[0..ds]);
    } else {
        @memcpy(key_buf[0..key.len], key);
    }

    var ipad: [MAX_BLOCK]u8 = undefined;
    var opad: [MAX_BLOCK]u8 = undefined;
    var i: usize = 0;
    while (i < block_size) : (i += 1) {
        ipad[i] = key_buf[i] ^ 0x36;
        opad[i] = key_buf[i] ^ 0x5c;
    }

    const st = try allocator.create(HmacState);
    st.* = .{
        .algo = algo,
        .inner = initState(algo),
        .outer_key = opad,
        .outer_key_len = block_size,
    };
    updateState(&st.inner, ipad[0..block_size]);
    return st;
}

fn finalizeHmac(st: *HmacState, out: []u8) void {
    const ds = algoDigestSize(st.algo);
    var inner_digest: [64]u8 = undefined;
    finalState(&st.inner, inner_digest[0..ds]);

    var outer = initState(st.algo);
    updateState(&outer, st.outer_key[0..st.outer_key_len]);
    updateState(&outer, inner_digest[0..ds]);
    finalState(&outer, out[0..ds]);
}

fn hmacStatePtr(inst: *Instance) *HmacState {
    const v = inst.dict.getStr("_state").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn newFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return newKw(p, args, &.{}, &.{});
}

fn newKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    try ensureClass(interp);
    if (args.len < 1) return error.TypeError;
    const key = try argBytes(args[0]);
    var msg: ?[]const u8 = if (args.len >= 2) try argBytes(args[1]) else null;
    var algo_val: ?Value = if (args.len >= 3) args[2] else null;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const n = kn.str.bytes;
        if (std.mem.eql(u8, n, "digestmod")) algo_val = kv
        else if (std.mem.eql(u8, n, "msg")) msg = try argBytes(kv);
    }
    const algo: Algo = if (algo_val) |v| (algoFromValue(v) orelse {
        try interp.raisePy("ValueError", "unknown digest");
        return error.PyException;
    }) else {
        try interp.raisePy("TypeError", "Missing required argument 'digestmod'");
        return error.PyException;
    };

    const st = try newHmacState(a, algo, key);
    if (msg) |m| updateState(&st.inner, m);

    const inst = try Instance.init(a, interp.hmac_class.?);
    try inst.dict.setStr(a, "_state", Value{ .small_int = @intCast(@intFromPtr(st)) });
    const name_str = try std.fmt.allocPrint(a, "hmac-{s}", .{algoName(algo)});
    const name = try Str.init(a, name_str);
    a.free(name_str);
    try inst.dict.setStr(a, "name", Value{ .str = name });
    try inst.dict.setStr(a, "digest_size", Value{ .small_int = @intCast(algoDigestSize(algo)) });
    try inst.dict.setStr(a, "block_size", Value{ .small_int = @intCast(algoBlockSize(algo)) });
    return Value{ .instance = inst };
}

fn digestFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3) return error.TypeError;
    const key = try argBytes(args[0]);
    const msg = try argBytes(args[1]);
    const algo = algoFromValue(args[2]) orelse {
        try interp.raisePy("ValueError", "unknown digest");
        return error.PyException;
    };
    const st = try newHmacState(a, algo, key);
    defer a.destroy(st);
    updateState(&st.inner, msg);
    const ds = algoDigestSize(algo);
    const out = try a.alloc(u8, ds);
    finalizeHmac(st, out);
    const b = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = b };
}

fn hmacUpdate(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const data = try argBytes(args[1]);
    updateState(&hmacStatePtr(args[0].instance).inner, data);
    return Value.none;
}

fn hmacDigest(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const st = hmacStatePtr(args[0].instance);
    const ds = algoDigestSize(st.algo);
    const out = try a.alloc(u8, ds);
    finalizeHmac(st, out);
    const b = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = b };
}

fn hmacCopy(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const old_st = hmacStatePtr(inst);
    const new_st = try a.create(HmacState);
    new_st.* = old_st.*;
    const new_inst = try Instance.init(a, interp.hmac_class.?);
    try new_inst.dict.setStr(a, "_state", Value{ .small_int = @intCast(@intFromPtr(new_st)) });
    if (inst.dict.getStr("name")) |v| try new_inst.dict.setStr(a, "name", v);
    if (inst.dict.getStr("digest_size")) |v| try new_inst.dict.setStr(a, "digest_size", v);
    if (inst.dict.getStr("block_size")) |v| try new_inst.dict.setStr(a, "block_size", v);
    return Value{ .instance = new_inst };
}

fn hmacHexdigest(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const st = hmacStatePtr(args[0].instance);
    const ds = algoDigestSize(st.algo);
    var raw: [64]u8 = undefined;
    finalizeHmac(st, raw[0..ds]);
    const out = try a.alloc(u8, ds * 2);
    const hex = "0123456789abcdef";
    for (raw[0..ds], 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    const s = try Str.init(a, out);
    a.free(out);
    return Value{ .str = s };
}

fn compareDigestFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2) return error.TypeError;
    const ax = try argBytes(args[0]);
    const bx = try argBytes(args[1]);
    if (ax.len != bx.len) return Value{ .boolean = false };
    var diff: u8 = 0;
    for (ax, bx) |x, y| diff |= x ^ y;
    return Value{ .boolean = diff == 0 };
}
