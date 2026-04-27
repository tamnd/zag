//! Pinhole `hashlib`: md5, sha1, sha256, sha512, plus `new(name, ...)`.
//! Hash objects are Python instances whose `_kind` (0-3) selects the
//! algorithm and `_state` stores the running hasher pointer.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
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

const Kind = enum(i64) { md5 = 0, sha1 = 1, sha224 = 2, sha256 = 3, sha384 = 4, sha512 = 5 };

const State = union(enum) {
    md5: Md5,
    sha1: Sha1,
    sha224: Sha224,
    sha256: Sha256,
    sha384: Sha384,
    sha512: Sha512,
};


pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "hashlib");
    try ensureClass(interp);
    try reg(interp, m, "md5", md5Fn);
    try reg(interp, m, "sha1", sha1Fn);
    try reg(interp, m, "sha224", sha224Fn);
    try reg(interp, m, "sha256", sha256Fn);
    try reg(interp, m, "sha384", sha384Fn);
    try reg(interp, m, "sha512", sha512Fn);
    try reg(interp, m, "new", newFn);
    // algorithms_available / algorithms_guaranteed: frozenset of algorithm names
    const Set = @import("../object/set.zig").Set;
    const names = [_][]const u8{ "md5", "sha1", "sha224", "sha256", "sha384", "sha512", "blake2b", "blake2s" };
    const avail_set = try Set.init(a);
    for (names) |name| {
        const s = try @import("../object/string.zig").Str.init(a, name);
        try avail_set.add(a, Value{ .str = s });
    }
    try m.attrs.setStr(a, "algorithms_available", Value{ .set = avail_set });
    try m.attrs.setStr(a, "algorithms_guaranteed", Value{ .set = avail_set });
    return m;
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

fn argBytes(v: Value) ![]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

fn newInstance(interp: *Interp, kind: Kind, initial: ?[]const u8) !Value {
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
    };
    const ns = try Str.init(a, name);
    try inst.dict.setStr(a, "name", Value{ .str = ns });

    const sz: i64 = switch (kind) {
        .md5 => 16,
        .sha1 => 20,
        .sha224 => 28,
        .sha256 => 32,
        .sha384 => 48,
        .sha512 => 64,
    };
    try inst.dict.setStr(a, "digest_size", Value{ .small_int = sz });

    const block_sz: i64 = switch (kind) {
        .md5, .sha1, .sha224, .sha256 => 64,
        .sha384, .sha512 => 128,
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
    }
}

fn finalize(s: *State, out: []u8) void {
    // Hash a clone so calling digest() doesn't mutate the running state.
    var copy = s.*;
    switch (copy) {
        .md5 => |*h| h.final(out[0..16]),
        .sha1 => |*h| h.final(out[0..20]),
        .sha224 => |*h| h.final(out[0..28]),
        .sha256 => |*h| h.final(out[0..32]),
        .sha384 => |*h| h.final(out[0..48]),
        .sha512 => |*h| h.final(out[0..64]),
    }
}

fn statePtr(inst: *Instance) *State {
    const v = inst.dict.getStr("_state").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn digestSize(inst: *Instance) usize {
    return @intCast(inst.dict.getStr("digest_size").?.small_int);
}

fn md5Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const data: ?[]const u8 = if (args.len >= 1) try argBytes(args[0]) else null;
    return try newInstance(interp, .md5, data);
}

fn sha1Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const data: ?[]const u8 = if (args.len >= 1) try argBytes(args[0]) else null;
    return try newInstance(interp, .sha1, data);
}

fn sha224Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const data: ?[]const u8 = if (args.len >= 1) try argBytes(args[0]) else null;
    return try newInstance(interp, .sha224, data);
}

fn sha384Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const data: ?[]const u8 = if (args.len >= 1) try argBytes(args[0]) else null;
    return try newInstance(interp, .sha384, data);
}

fn sha256Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const data: ?[]const u8 = if (args.len >= 1) try argBytes(args[0]) else null;
    return try newInstance(interp, .sha256, data);
}

fn sha512Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const data: ?[]const u8 = if (args.len >= 1) try argBytes(args[0]) else null;
    return try newInstance(interp, .sha512, data);
}

fn newFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const name = args[0].str.bytes;
    const kind: Kind = if (std.mem.eql(u8, name, "md5"))
        .md5
    else if (std.mem.eql(u8, name, "sha1"))
        .sha1
    else if (std.mem.eql(u8, name, "sha224"))
        .sha224
    else if (std.mem.eql(u8, name, "sha256"))
        .sha256
    else if (std.mem.eql(u8, name, "sha384"))
        .sha384
    else if (std.mem.eql(u8, name, "sha512"))
        .sha512
    else {
        try interp.raisePy("ValueError", "unknown hash algorithm");
        return error.PyException;
    };
    const data: ?[]const u8 = if (args.len >= 2) try argBytes(args[1]) else null;
    return try newInstance(interp, kind, data);
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
    return Value{ .instance = new_inst };
}

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
    const sz = digestSize(inst);
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
    const sz = digestSize(inst);
    var raw_buf: [64]u8 = undefined;
    finalize(statePtr(inst), raw_buf[0..sz]);
    const out = try a.alloc(u8, sz * 2);
    const hex = "0123456789abcdef";
    for (raw_buf[0..sz], 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    const s = try Str.init(a, out);
    a.free(out);
    return Value{ .str = s };
}
