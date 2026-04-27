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
const dispatch = @import("dispatch.zig");

const Md5 = std.crypto.hash.Md5;
const Sha1 = std.crypto.hash.Sha1;
const Sha224 = std.crypto.hash.sha2.Sha224;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Sha3_224 = std.crypto.hash.sha3.Sha3_224;
const Sha3_256 = std.crypto.hash.sha3.Sha3_256;
const Sha3_384 = std.crypto.hash.sha3.Sha3_384;
const Sha3_512 = std.crypto.hash.sha3.Sha3_512;
const Shake128 = std.crypto.hash.sha3.Shake128;
const Shake256 = std.crypto.hash.sha3.Shake256;
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const Blake2s128 = std.crypto.hash.blake2.Blake2s128;
const Blake2s256 = std.crypto.hash.blake2.Blake2s256;

const Kind = enum(i64) {
    md5 = 0,
    sha1 = 1,
    sha224 = 2,
    sha256 = 3,
    sha384 = 4,
    sha512 = 5,
    sha3_224 = 6,
    sha3_256 = 7,
    sha3_384 = 8,
    sha3_512 = 9,
    shake_128 = 10,
    shake_256 = 11,
    blake2b_512 = 12,
    blake2b_256 = 13,
    blake2s_256 = 14,
    blake2s_128 = 15,
};

const State = union(enum) {
    md5: Md5,
    sha1: Sha1,
    sha224: Sha224,
    sha256: Sha256,
    sha384: Sha384,
    sha512: Sha512,
    sha3_224: Sha3_224,
    sha3_256: Sha3_256,
    sha3_384: Sha3_384,
    sha3_512: Sha3_512,
    shake_128: Shake128,
    shake_256: Shake256,
    blake2b_512: Blake2b512,
    blake2b_256: Blake2b256,
    blake2s_256: Blake2s256,
    blake2s_128: Blake2s128,
};

fn newInstance(interp: *Interp, kind: Kind, initial: ?[]const u8, key: ?[]const u8) !Value {
    try ensureClass(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.hashlib_hash_class.?);
    const state_ptr = try a.create(State);
    state_ptr.* = switch (kind) {
        .md5 => .{ .md5 = Md5.init(.{}) },
        .sha1 => .{ .sha1 = Sha1.init(.{}) },
        .sha224 => .{ .sha224 = Sha224.init(.{}) },
        .sha256 => .{ .sha256 = Sha256.init(.{}) },
        .sha384 => .{ .sha384 = Sha384.init(.{}) },
        .sha512 => .{ .sha512 = Sha512.init(.{}) },
        .sha3_224 => .{ .sha3_224 = Sha3_224.init(.{}) },
        .sha3_256 => .{ .sha3_256 = Sha3_256.init(.{}) },
        .sha3_384 => .{ .sha3_384 = Sha3_384.init(.{}) },
        .sha3_512 => .{ .sha3_512 = Sha3_512.init(.{}) },
        .shake_128 => .{ .shake_128 = Shake128.init(.{}) },
        .shake_256 => .{ .shake_256 = Shake256.init(.{}) },
        .blake2b_512 => .{ .blake2b_512 = Blake2b512.init(.{ .key = key }) },
        .blake2b_256 => .{ .blake2b_256 = Blake2b256.init(.{ .key = key }) },
        .blake2s_256 => .{ .blake2s_256 = Blake2s256.init(.{ .key = key }) },
        .blake2s_128 => .{ .blake2s_128 = Blake2s128.init(.{ .key = key }) },
    };
    if (initial) |data| updateState(state_ptr, data);

    try inst.dict.setStr(a, "_state", Value{ .small_int = @intCast(@intFromPtr(state_ptr)) });
    try inst.dict.setStr(a, "_kind", Value{ .small_int = @intFromEnum(kind) });

    const name = switch (kind) {
        .md5 => "md5",
        .sha1 => "sha1",
        .sha224 => "sha224",
        .sha256 => "sha256",
        .sha384 => "sha384",
        .sha512 => "sha512",
        .sha3_224 => "sha3_224",
        .sha3_256 => "sha3_256",
        .sha3_384 => "sha3_384",
        .sha3_512 => "sha3_512",
        .shake_128 => "shake_128",
        .shake_256 => "shake_256",
        .blake2b_512, .blake2b_256 => "blake2b",
        .blake2s_256, .blake2s_128 => "blake2s",
    };
    try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, name) });

    const sz: i64 = switch (kind) {
        .md5 => 16,
        .sha1 => 20,
        .sha224 => 28,
        .sha256 => 32,
        .sha384 => 48,
        .sha512 => 64,
        .sha3_224 => 28,
        .sha3_256 => 32,
        .sha3_384 => 48,
        .sha3_512 => 64,
        .shake_128 => 32,
        .shake_256 => 64,
        .blake2b_512 => 64,
        .blake2b_256 => 32,
        .blake2s_256 => 32,
        .blake2s_128 => 16,
    };
    try inst.dict.setStr(a, "digest_size", Value{ .small_int = sz });

    const block_sz: i64 = switch (kind) {
        .md5, .sha1, .sha224, .sha256 => 64,
        .sha384, .sha512 => 128,
        .sha3_224 => 144,
        .sha3_256 => 136,
        .sha3_384 => 104,
        .sha3_512 => 72,
        .shake_128 => 168,
        .shake_256 => 136,
        .blake2b_512, .blake2b_256 => 128,
        .blake2s_256, .blake2s_128 => 64,
    };
    try inst.dict.setStr(a, "block_size", Value{ .small_int = block_sz });

    return Value{ .instance = inst };
}

fn updateState(s: *State, data: []const u8) void {
    switch (s.*) {
        .md5 => |*h| h.update(data),
        .sha1 => |*h| h.update(data),
        .sha224 => |*h| h.update(data),
        .sha256 => |*h| h.update(data),
        .sha384 => |*h| h.update(data),
        .sha512 => |*h| h.update(data),
        .sha3_224 => |*h| h.update(data),
        .sha3_256 => |*h| h.update(data),
        .sha3_384 => |*h| h.update(data),
        .sha3_512 => |*h| h.update(data),
        .shake_128 => |*h| h.update(data),
        .shake_256 => |*h| h.update(data),
        .blake2b_512 => |*h| h.update(data),
        .blake2b_256 => |*h| h.update(data),
        .blake2s_256 => |*h| h.update(data),
        .blake2s_128 => |*h| h.update(data),
    }
}

fn finalize(s: *State, out: []u8) void {
    var copy = s.*;
    switch (copy) {
        .md5 => |*h| h.final(out[0..16]),
        .sha1 => |*h| h.final(out[0..20]),
        .sha224 => |*h| h.final(out[0..28]),
        .sha256 => |*h| h.final(out[0..32]),
        .sha384 => |*h| h.final(out[0..48]),
        .sha512 => |*h| h.final(out[0..64]),
        .sha3_224 => |*h| h.final(out[0..28]),
        .sha3_256 => |*h| h.final(out[0..32]),
        .sha3_384 => |*h| h.final(out[0..48]),
        .sha3_512 => |*h| h.final(out[0..64]),
        .shake_128 => |*h| h.final(out),
        .shake_256 => |*h| h.final(out),
        .blake2b_512 => |*h| h.final(out[0..64]),
        .blake2b_256 => |*h| h.final(out[0..32]),
        .blake2s_256 => |*h| h.final(out[0..32]),
        .blake2s_128 => |*h| h.final(out[0..16]),
    }
}

fn statePtr(inst: *Instance) *State {
    const v = inst.dict.getStr("_state").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn getKind(inst: *Instance) Kind {
    const v = inst.dict.getStr("_kind") orelse return .md5;
    return @enumFromInt(v.small_int);
}

fn digestSize(inst: *Instance) usize {
    return @intCast(inst.dict.getStr("digest_size").?.small_int);
}

fn argBytes(v: Value) ![]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

fn nameToKind(name: []const u8) ?Kind {
    if (std.mem.eql(u8, name, "md5")) return .md5;
    if (std.mem.eql(u8, name, "sha1")) return .sha1;
    if (std.mem.eql(u8, name, "sha224")) return .sha224;
    if (std.mem.eql(u8, name, "sha256")) return .sha256;
    if (std.mem.eql(u8, name, "sha384")) return .sha384;
    if (std.mem.eql(u8, name, "sha512")) return .sha512;
    if (std.mem.eql(u8, name, "sha3_224")) return .sha3_224;
    if (std.mem.eql(u8, name, "sha3_256")) return .sha3_256;
    if (std.mem.eql(u8, name, "sha3_384")) return .sha3_384;
    if (std.mem.eql(u8, name, "sha3_512")) return .sha3_512;
    if (std.mem.eql(u8, name, "shake_128")) return .shake_128;
    if (std.mem.eql(u8, name, "shake_256")) return .shake_256;
    if (std.mem.eql(u8, name, "blake2b")) return .blake2b_512;
    if (std.mem.eql(u8, name, "blake2s")) return .blake2s_256;
    return null;
}

// --- constructors ---

fn simpleHashFn(interp: *Interp, kind: Kind, args: []const Value) anyerror!Value {
    const data: ?[]const u8 = if (args.len >= 1) argBytes(args[0]) catch null else null;
    return try newInstance(interp, kind, data, null);
}

fn simpleHashKwFn(interp: *Interp, kind: Kind, args: []const Value) anyerror!Value {
    // ignore kwargs (e.g. usedforsecurity)
    return simpleHashFn(interp, kind, args);
}

fn md5Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return simpleHashFn(@ptrCast(@alignCast(p)), .md5, args);
}
fn md5KwFn(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    _ = kn; _ = kv;
    return simpleHashKwFn(@ptrCast(@alignCast(p)), .md5, args);
}

fn sha1Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return simpleHashFn(@ptrCast(@alignCast(p)), .sha1, args);
}
fn sha1KwFn(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    _ = kn; _ = kv;
    return simpleHashKwFn(@ptrCast(@alignCast(p)), .sha1, args);
}

fn sha224Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return simpleHashFn(@ptrCast(@alignCast(p)), .sha224, args);
}
fn sha256Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return simpleHashFn(@ptrCast(@alignCast(p)), .sha256, args);
}
fn sha384Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return simpleHashFn(@ptrCast(@alignCast(p)), .sha384, args);
}
fn sha512Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return simpleHashFn(@ptrCast(@alignCast(p)), .sha512, args);
}

fn sha3_224Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return simpleHashFn(@ptrCast(@alignCast(p)), .sha3_224, args);
}
fn sha3_256Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return simpleHashFn(@ptrCast(@alignCast(p)), .sha3_256, args);
}
fn sha3_384Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return simpleHashFn(@ptrCast(@alignCast(p)), .sha3_384, args);
}
fn sha3_512Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return simpleHashFn(@ptrCast(@alignCast(p)), .sha3_512, args);
}

fn shake128Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return simpleHashFn(@ptrCast(@alignCast(p)), .shake_128, args);
}
fn shake256Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return simpleHashFn(@ptrCast(@alignCast(p)), .shake_256, args);
}

fn blake2bFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const data: ?[]const u8 = if (args.len >= 1) argBytes(args[0]) catch null else null;
    return try newInstance(interp, .blake2b_512, data, null);
}

fn blake2bKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const data: ?[]const u8 = if (args.len >= 1) argBytes(args[0]) catch null else null;
    var digest_sz: i64 = 64;
    var key: ?[]const u8 = null;
    for (kw_names, kw_values) |kn, kv| {
        const kname = if (kn == .str) kn.str.bytes else continue;
        if (std.mem.eql(u8, kname, "digest_size")) {
            if (kv == .small_int) digest_sz = kv.small_int;
        } else if (std.mem.eql(u8, kname, "key")) {
            key = argBytes(kv) catch null;
        }
    }
    const kind: Kind = if (digest_sz <= 32) .blake2b_256 else .blake2b_512;
    return try newInstance(interp, kind, data, key);
}

fn blake2sFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const data: ?[]const u8 = if (args.len >= 1) argBytes(args[0]) catch null else null;
    return try newInstance(interp, .blake2s_256, data, null);
}

fn blake2sKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const data: ?[]const u8 = if (args.len >= 1) argBytes(args[0]) catch null else null;
    var digest_sz: i64 = 32;
    var key: ?[]const u8 = null;
    for (kw_names, kw_values) |kn, kv| {
        const kname = if (kn == .str) kn.str.bytes else continue;
        if (std.mem.eql(u8, kname, "digest_size")) {
            if (kv == .small_int) digest_sz = kv.small_int;
        } else if (std.mem.eql(u8, kname, "key")) {
            key = argBytes(kv) catch null;
        }
    }
    const kind: Kind = if (digest_sz <= 16) .blake2s_128 else .blake2s_256;
    return try newInstance(interp, kind, data, key);
}

fn newFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "new() requires algorithm name");
        return error.PyException;
    }
    const name = args[0].str.bytes;
    const kind = nameToKind(name) orelse {
        try interp.raisePy("ValueError", "unknown hash algorithm");
        return error.PyException;
    };
    const data: ?[]const u8 = if (args.len >= 2) argBytes(args[1]) catch null else null;
    return try newInstance(interp, kind, data, null);
}

fn fileDigestFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[1] != .str) {
        try interp.raisePy("TypeError", "file_digest() requires (fp, name)");
        return error.PyException;
    }
    const fp = args[0];
    const algo_name = args[1].str.bytes;
    const kind = nameToKind(algo_name) orelse {
        try interp.raisePy("ValueError", "unknown hash algorithm");
        return error.PyException;
    };
    const read_fn = try dispatch.loadAttrValue(interp, fp, "read");
    const data_val = try dispatch.invoke(interp, read_fn, &.{});
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    switch (data_val) {
        .bytes => |b| try buf.appendSlice(a, b.data),
        .bytearray => |b| try buf.appendSlice(a, b.data.items),
        .str => |s| try buf.appendSlice(a, s.bytes),
        else => {},
    }
    return try newInstance(interp, kind, buf.items, null);
}

// --- hash methods ---

fn hashUpdate(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const data = try argBytes(args[1]);
    updateState(statePtr(args[0].instance), data);
    return Value.none;
}

fn hashDigest(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const kind = getKind(inst);
    const sz: usize = switch (kind) {
        .shake_128, .shake_256 => if (args.len >= 2 and args[1] == .small_int) @intCast(args[1].small_int) else digestSize(inst),
        else => digestSize(inst),
    };
    const out = try a.alloc(u8, sz);
    finalize(statePtr(inst), out);
    const b = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = b };
}

fn hashHexdigest(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const kind = getKind(inst);
    const sz: usize = switch (kind) {
        .shake_128, .shake_256 => if (args.len >= 2 and args[1] == .small_int) @intCast(args[1].small_int) else digestSize(inst),
        else => digestSize(inst),
    };
    const raw = try a.alloc(u8, sz);
    defer a.free(raw);
    finalize(statePtr(inst), raw);
    const out = try a.alloc(u8, sz * 2);
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    const s = try Str.init(a, out);
    a.free(out);
    return Value{ .str = s };
}

fn hashCopy(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const new_inst = try Instance.init(a, interp.hashlib_hash_class.?);
    const new_state = try a.create(State);
    new_state.* = statePtr(inst).*;
    try new_inst.dict.setStr(a, "_state", Value{ .small_int = @intCast(@intFromPtr(new_state)) });
    if (inst.dict.getStr("_kind")) |k| try new_inst.dict.setStr(a, "_kind", k);
    if (inst.dict.getStr("name")) |k| try new_inst.dict.setStr(a, "name", k);
    if (inst.dict.getStr("digest_size")) |k| try new_inst.dict.setStr(a, "digest_size", k);
    if (inst.dict.getStr("block_size")) |k| try new_inst.dict.setStr(a, "block_size", k);
    return Value{ .instance = new_inst };
}

// --- class setup ---

fn ensureClass(interp: *Interp) !void {
    if (interp.hashlib_hash_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "update", hashUpdate);
    try methodReg(a, d, "digest", hashDigest);
    try methodReg(a, d, "hexdigest", hashHexdigest);
    try methodReg(a, d, "copy", hashCopy);
    interp.hashlib_hash_class = try Class.init(a, "Hash", &.{}, d);
}

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
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

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "hashlib");
    try ensureClass(interp);

    try regKw(interp, m, "md5", md5Fn, md5KwFn);
    try regKw(interp, m, "sha1", sha1Fn, sha1KwFn);
    try reg(interp, m, "sha224", sha224Fn);
    try reg(interp, m, "sha256", sha256Fn);
    try reg(interp, m, "sha384", sha384Fn);
    try reg(interp, m, "sha512", sha512Fn);
    try reg(interp, m, "sha3_224", sha3_224Fn);
    try reg(interp, m, "sha3_256", sha3_256Fn);
    try reg(interp, m, "sha3_384", sha3_384Fn);
    try reg(interp, m, "sha3_512", sha3_512Fn);
    try reg(interp, m, "shake_128", shake128Fn);
    try reg(interp, m, "shake_256", shake256Fn);
    try regKw(interp, m, "blake2b", blake2bFn, blake2bKwFn);
    try regKw(interp, m, "blake2s", blake2sFn, blake2sKwFn);
    try reg(interp, m, "new", newFn);
    try reg(interp, m, "file_digest", fileDigestFn);

    const Set = @import("../object/set.zig").Set;
    const algo_names = [_][]const u8{
        "md5", "sha1", "sha224", "sha256", "sha384", "sha512",
        "sha3_224", "sha3_256", "sha3_384", "sha3_512",
        "shake_128", "shake_256",
        "blake2b", "blake2s",
    };
    const avail_set = try Set.init(a);
    for (algo_names) |name| {
        const s = try Str.init(a, name);
        try avail_set.add(a, Value{ .str = s });
    }
    try m.attrs.setStr(a, "algorithms_available", Value{ .set = avail_set });
    try m.attrs.setStr(a, "algorithms_guaranteed", Value{ .set = avail_set });
    return m;
}
