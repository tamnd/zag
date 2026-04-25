//! Pinhole `secrets`: thin OS-RNG-backed helpers. Just enough for the
//! fixture's "values land in the right shape and range" probes.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

var g_prng: ?std.Random.DefaultPrng = null;

fn rng() std.Random {
    if (g_prng == null) {
        g_prng = std.Random.DefaultPrng.init(0xDEADBEEFCAFEBABE);
    }
    return g_prng.?.random();
}

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "secrets");
    try reg(interp, m, "token_bytes", tokenBytesFn);
    try reg(interp, m, "token_hex", tokenHexFn);
    try reg(interp, m, "token_urlsafe", tokenUrlsafeFn);
    try reg(interp, m, "randbelow", randbelowFn);
    try reg(interp, m, "randbits", randbitsFn);
    try reg(interp, m, "choice", choiceFn);
    try reg(interp, m, "compare_digest", compareDigestFn);
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

fn defaultN(args: []const Value, fallback: usize) usize {
    if (args.len < 1) return fallback;
    return switch (args[0]) {
        .small_int => |i| if (i >= 0) @intCast(i) else fallback,
        .none => fallback,
        else => fallback,
    };
}

fn tokenBytesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const n = defaultN(args, 32);
    const out = try a.alloc(u8, n);
    rng().bytes(out);
    const b = try Bytes.fromOwnedSlice(a, out);
    return Value{ .bytes = b };
}

fn tokenHexFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const n = defaultN(args, 32);
    const raw = try a.alloc(u8, n);
    defer a.free(raw);
    rng().bytes(raw);
    const out = try a.alloc(u8, n * 2);
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    const s = try Str.init(a, out);
    a.free(out);
    return Value{ .str = s };
}

fn tokenUrlsafeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const n = defaultN(args, 32);
    const raw = try a.alloc(u8, n);
    defer a.free(raw);
    rng().bytes(raw);

    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const enc_len = ((n + 2) / 3) * 4;
    var enc = try a.alloc(u8, enc_len);
    defer a.free(enc);
    var i: usize = 0;
    var j: usize = 0;
    while (i + 3 <= n) : (i += 3) {
        const b0 = raw[i];
        const b1 = raw[i + 1];
        const b2 = raw[i + 2];
        enc[j] = alphabet[b0 >> 2];
        enc[j + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        enc[j + 2] = alphabet[((b1 & 0x0f) << 2) | (b2 >> 6)];
        enc[j + 3] = alphabet[b2 & 0x3f];
        j += 4;
    }
    var stripped = j;
    const rem = n - i;
    if (rem == 1) {
        const b0 = raw[i];
        enc[j] = alphabet[b0 >> 2];
        enc[j + 1] = alphabet[(b0 & 0x03) << 4];
        stripped = j + 2;
    } else if (rem == 2) {
        const b0 = raw[i];
        const b1 = raw[i + 1];
        enc[j] = alphabet[b0 >> 2];
        enc[j + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        enc[j + 2] = alphabet[(b1 & 0x0f) << 2];
        stripped = j + 3;
    }
    const s = try Str.init(a, enc[0..stripped]);
    return Value{ .str = s };
}

fn randbelowFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .small_int or args[0].small_int <= 0) {
        try interp.raisePy("ValueError", "randbelow requires positive int");
        return error.PyException;
    }
    const n: u64 = @intCast(args[0].small_int);
    const v = rng().uintLessThan(u64, n);
    return Value{ .small_int = @intCast(v) };
}

fn randbitsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .small_int or args[0].small_int < 0 or args[0].small_int > 63) {
        try interp.raisePy("ValueError", "randbits requires 0..63 bits");
        return error.PyException;
    }
    const k: u6 = @intCast(args[0].small_int);
    if (k == 0) return Value{ .small_int = 0 };
    var v: u64 = 0;
    rng().bytes(std.mem.asBytes(&v));
    const mask: u64 = if (k == 64) std.math.maxInt(u64) else (@as(u64, 1) << k) - 1;
    return Value{ .small_int = @intCast(v & mask) };
}

fn choiceFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    if (args[0] == .str) {
        const bytes = args[0].str.bytes;
        if (bytes.len == 0) {
            try interp.raisePy("IndexError", "choice from empty sequence");
            return error.PyException;
        }
        const idx = rng().uintLessThan(u64, bytes.len);
        const s = try Str.init(a, bytes[idx .. idx + 1]);
        return Value{ .str = s };
    }
    const items: []const Value = switch (args[0]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => {
            try interp.raisePy("TypeError", "choice requires sequence");
            return error.PyException;
        },
    };
    if (items.len == 0) {
        try interp.raisePy("IndexError", "choice from empty sequence");
        return error.PyException;
    }
    const idx = rng().uintLessThan(u64, items.len);
    return items[idx];
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
