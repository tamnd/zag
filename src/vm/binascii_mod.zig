//! `binascii` module — hex/base64/uu/qp/hqx/crc conversion for fixtures 65 & 211.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Str = @import("../object/string.zig").Str;
const Tuple = @import("../object/tuple.zig").Tuple;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

var g_error_class: ?*Class = null;
var g_incomplete_class: ?*Class = null;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "binascii");

    // Error subclasses ValueError
    const err_d = try Dict.init(a);
    var ve_bases: [1]*Class = undefined;
    var err_bases: []const *Class = &.{};
    if (interp.builtins.getStr("ValueError")) |ve| {
        if (ve == .class) { ve_bases[0] = ve.class; err_bases = ve_bases[0..1]; }
    }
    const err_cls = try Class.init(a, "Error", err_bases, err_d);
    g_error_class = err_cls;
    try m.attrs.setStr(a, "Error", Value{ .class = err_cls });

    // Incomplete subclasses Exception
    const inc_d = try Dict.init(a);
    var exc_bases: [1]*Class = undefined;
    var inc_bases: []const *Class = &.{};
    if (interp.builtins.getStr("Exception")) |exc| {
        if (exc == .class) { exc_bases[0] = exc.class; inc_bases = exc_bases[0..1]; }
    }
    const inc_cls = try Class.init(a, "Incomplete", inc_bases, inc_d);
    g_incomplete_class = inc_cls;
    try m.attrs.setStr(a, "Incomplete", Value{ .class = inc_cls });

    try regKw(interp, m, "hexlify", hexlifyFn, hexlifyKw);
    try regKw(interp, m, "b2a_hex", hexlifyFn, hexlifyKw);
    try reg(interp, m, "unhexlify", unhexlifyFn);
    try reg(interp, m, "a2b_hex", unhexlifyFn);
    try regKw(interp, m, "b2a_base64", b2aBase64Fn, b2aBase64Kw);
    try regKw(interp, m, "a2b_base64", a2bBase64Fn, a2bBase64Kw);
    try reg(interp, m, "crc32", crc32Fn);
    try reg(interp, m, "crc_hqx", crcHqxFn);
    try regKw(interp, m, "b2a_uu", b2aUuFn, b2aUuKw);
    try reg(interp, m, "a2b_uu", a2bUuFn);
    try regKw(interp, m, "b2a_qp", b2aQpFn, b2aQpKw);
    try regKw(interp, m, "a2b_qp", a2bQpFn, a2bQpKw);
    try reg(interp, m, "rlecode_hqx", rlecodeHqxFn);
    try reg(interp, m, "rledecode_hqx", rledecodeHqxFn);
    try reg(interp, m, "b2a_hqx", b2aHqxFn);
    try reg(interp, m, "a2b_hqx", a2bHqxFn);
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

fn gi(p: *anyopaque) *Interp { return @ptrCast(@alignCast(p)); }

fn argBytes(v: Value) ![]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

fn kwBool(kw_names: []const Value, kw_values: []const Value, name: []const u8, def: bool) bool {
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, name)) return kv.isTruthy();
    }
    return def;
}

fn kwOptBytes(kw_names: []const Value, kw_values: []const Value, name: []const u8) ?[]const u8 {
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, name)) {
            return argBytes(kv) catch null;
        }
    }
    return null;
}

fn kwInt(kw_names: []const Value, kw_values: []const Value, name: []const u8, def: i64) i64 {
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, name)) {
            return switch (kv) {
                .small_int => |i| i,
                else => def,
            };
        }
    }
    return def;
}

fn raiseError(interp: *Interp, msg: []const u8) !void {
    if (g_error_class) |cls| {
        try interp.raiseDecimal(cls, msg);
    } else {
        try interp.raisePy("ValueError", msg);
    }
}

fn hexVal(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

// ── hexlify ──────────────────────────────────────────────────────────────────

fn hexlifyFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return hexlifyKw(p, args, &.{}, &.{});
}

fn hexlifyKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = argBytes(args[0]) catch {
        try interp.typeError("hexlify: expected bytes"); return error.TypeError;
    };
    // sep arg can be positional (args[1]) or keyword
    var sep: ?[]const u8 = if (args.len >= 2) argBytes(args[1]) catch null else null;
    if (sep == null) sep = kwOptBytes(kw_names, kw_values, "sep");
    const bps_raw: i64 = if (args.len >= 3)
        (switch (args[2]) { .small_int => |i| i, else => 1 })
    else
        kwInt(kw_names, kw_values, "bytes_per_sep", 1);

    const hex = "0123456789abcdef";

    if (sep == null or sep.?.len == 0 or src.len == 0) {
        const out = try a.alloc(u8, src.len * 2);
        for (src, 0..) |b, i| {
            out[i * 2] = hex[b >> 4];
            out[i * 2 + 1] = hex[b & 0xf];
        }
        return Value{ .bytes = try Bytes.fromOwnedSlice(a, out) };
    }

    const s = sep.?;
    const bps: usize = if (bps_raw < 0) @intCast(-bps_raw) else @intCast(bps_raw);
    const safe_bps = if (bps == 0) 1 else bps;

    // Count groups and separators
    const n_groups = (src.len + safe_bps - 1) / safe_bps;
    const n_seps = if (n_groups > 0) n_groups - 1 else 0;
    const out = try a.alloc(u8, src.len * 2 + n_seps * s.len);
    var oi: usize = 0;

    if (bps_raw >= 0) {
        // Group from left
        var i: usize = 0;
        var grp: usize = 0;
        while (i < src.len) : (grp += 1) {
            if (grp > 0) {
                @memcpy(out[oi..oi+s.len], s);
                oi += s.len;
            }
            const end = @min(i + safe_bps, src.len);
            while (i < end) : (i += 1) {
                out[oi] = hex[src[i] >> 4];
                out[oi+1] = hex[src[i] & 0xf];
                oi += 2;
            }
        }
    } else {
        // Group from right: first group may be smaller
        const tail = src.len % safe_bps;
        const first = if (tail == 0) safe_bps else tail;
        var i: usize = 0;
        var grp: usize = 0;
        while (i < src.len) : (grp += 1) {
            if (grp > 0) {
                @memcpy(out[oi..oi+s.len], s);
                oi += s.len;
            }
            const group_size = if (grp == 0) first else safe_bps;
            const end = i + group_size;
            var j = i;
            while (j < end) : (j += 1) {
                out[oi] = hex[src[j] >> 4];
                out[oi+1] = hex[src[j] & 0xf];
                oi += 2;
            }
            i = end;
        }
    }

    return Value{ .bytes = try Bytes.fromOwnedSlice(a, out) };
}

// ── unhexlify ────────────────────────────────────────────────────────────────

fn unhexlifyFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = argBytes(args[0]) catch {
        try interp.typeError("unhexlify: expected bytes"); return error.TypeError;
    };
    if (src.len % 2 != 0) {
        try raiseError(interp, "Odd-length string");
        return error.PyException;
    }
    const out = try a.alloc(u8, src.len / 2);
    var i: usize = 0;
    while (i < src.len) : (i += 2) {
        const hi = hexVal(src[i]) catch {
            a.free(out);
            try raiseError(interp, "Non-hexadecimal digit found");
            return error.PyException;
        };
        const lo = hexVal(src[i + 1]) catch {
            a.free(out);
            try raiseError(interp, "Non-hexadecimal digit found");
            return error.PyException;
        };
        out[i / 2] = (hi << 4) | lo;
    }
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, out) };
}

// ── base64 ───────────────────────────────────────────────────────────────────

const B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn b64encode(a: std.mem.Allocator, src: []const u8, with_newline: bool) ![]u8 {
    const enc_len = ((src.len + 2) / 3) * 4;
    const total = enc_len + @as(usize, if (with_newline) 1 else 0);
    const out = try a.alloc(u8, total);
    var i: usize = 0;
    var j: usize = 0;
    while (i + 3 <= src.len) : (i += 3) {
        const b0 = src[i]; const b1 = src[i+1]; const b2 = src[i+2];
        out[j]   = B64_ALPHABET[b0 >> 2];
        out[j+1] = B64_ALPHABET[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[j+2] = B64_ALPHABET[((b1 & 0x0f) << 2) | (b2 >> 6)];
        out[j+3] = B64_ALPHABET[b2 & 0x3f];
        j += 4;
    }
    const rem = src.len - i;
    if (rem == 1) {
        out[j] = B64_ALPHABET[src[i] >> 2];
        out[j+1] = B64_ALPHABET[(src[i] & 0x03) << 4];
        out[j+2] = '='; out[j+3] = '=';
    } else if (rem == 2) {
        out[j] = B64_ALPHABET[src[i] >> 2];
        out[j+1] = B64_ALPHABET[((src[i] & 0x03) << 4) | (src[i+1] >> 4)];
        out[j+2] = B64_ALPHABET[(src[i+1] & 0x0f) << 2];
        out[j+3] = '=';
    }
    if (with_newline) out[enc_len] = '\n';
    return out;
}

fn b2aBase64Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return b2aBase64Kw(p, args, &.{}, &.{});
}
fn b2aBase64Kw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = argBytes(args[0]) catch { try interp.typeError("b2a_base64: expected bytes"); return error.TypeError; };
    const newline = kwBool(kw_names, kw_values, "newline", true);
    const out = try b64encode(a, src, newline);
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, out) };
}

fn a2bBase64Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return a2bBase64Kw(p, args, &.{}, &.{});
}
fn a2bBase64Kw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = argBytes(args[0]) catch { try interp.typeError("a2b_base64: expected bytes"); return error.TypeError; };
    const strict = kwBool(kw_names, kw_values, "strict_mode", false);

    var lookup: [256]i16 = .{-1} ** 256;
    for (B64_ALPHABET, 0..) |c, idx| lookup[c] = @intCast(idx);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: u32 = 0;
    var bits: u32 = 0;
    for (src) |c| {
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t') {
            if (strict) {
                try raiseError(interp, "Non-base64 digit found");
                return error.PyException;
            }
            continue;
        }
        if (c == '=') continue;
        const v = lookup[c];
        if (v < 0) {
            try raiseError(interp, "Invalid base64-encoded string");
            return error.PyException;
        }
        buf = (buf << 6) | @as(u32, @intCast(v));
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            try out.append(a, @intCast((buf >> @intCast(bits)) & 0xff));
        }
    }
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, try out.toOwnedSlice(a)) };
}

// ── crc32 ────────────────────────────────────────────────────────────────────

fn crc32Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return error.TypeError;
    const data = try argBytes(args[0]);
    const seed: u32 = if (args.len >= 2 and args[1] == .small_int)
        @truncate(@as(u64, @bitCast(args[1].small_int)))
    else 0;
    var c = std.hash.Crc32.init();
    c.crc = seed ^ 0xFFFFFFFF;
    c.update(data);
    return Value{ .small_int = @intCast(c.final()) };
}

// ── crc_hqx ──────────────────────────────────────────────────────────────────

fn crcHqxFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2) return error.TypeError;
    const data = try argBytes(args[0]);
    const init_crc: u16 = switch (args[1]) {
        .small_int => |i| @truncate(@as(u64, @bitCast(i))),
        else => 0,
    };
    var crc: u16 = init_crc;
    for (data) |b| {
        crc ^= @as(u16, b) << 8;
        for (0..8) |_| {
            if (crc & 0x8000 != 0) {
                crc = (crc << 1) ^ 0x1021;
            } else {
                crc <<= 1;
            }
        }
    }
    return Value{ .small_int = @intCast(crc) };
}

// ── UU encoding ──────────────────────────────────────────────────────────────

fn uuChar(v: u6, backtick: bool) u8 {
    if (v == 0 and backtick) return '`';
    return @as(u8, v) + 0x20;
}

fn b2aUuFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return b2aUuKw(p, args, &.{}, &.{});
}
fn b2aUuKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = argBytes(args[0]) catch { try interp.typeError("b2a_uu: expected bytes"); return error.TypeError; };
    if (src.len > 45) {
        try raiseError(interp, "At most 45 bytes at once");
        return error.PyException;
    }
    const backtick = kwBool(kw_names, kw_values, "backtick", false);
    // Output: 1 length byte + ceil(len/3)*4 data bytes + '\n'
    const enc_groups = (src.len + 2) / 3;
    const out_len = 1 + enc_groups * 4 + 1;
    const out = try a.alloc(u8, out_len);
    out[0] = uuChar(@truncate(src.len), backtick);
    var i: usize = 0;
    var j: usize = 1;
    while (i < src.len) : (i += 3) {
        const b0 = src[i];
        const b1: u8 = if (i+1 < src.len) src[i+1] else 0;
        const b2: u8 = if (i+2 < src.len) src[i+2] else 0;
        out[j]   = uuChar(@truncate(b0 >> 2), backtick);
        out[j+1] = uuChar(@truncate(((b0 & 0x03) << 4) | (b1 >> 4)), backtick);
        out[j+2] = uuChar(@truncate(((b1 & 0x0f) << 2) | (b2 >> 6)), backtick);
        out[j+3] = uuChar(@truncate(b2 & 0x3f), backtick);
        j += 4;
    }
    out[out_len - 1] = '\n';
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, out) };
}

fn a2bUuFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = argBytes(args[0]) catch { try interp.typeError("a2b_uu: expected bytes"); return error.TypeError; };
    if (src.len == 0) return Value{ .bytes = try Bytes.fromOwnedSlice(a, try a.dupe(u8, &.{})) };
    // First char is the length
    const length: usize = (src[0] - 0x20) & 0x3f;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 1;
    while (i + 3 < src.len) : (i += 4) {
        const c0 = (src[i] - 0x20) & 0x3f;
        const c1 = (src[i+1] - 0x20) & 0x3f;
        const c2 = (src[i+2] - 0x20) & 0x3f;
        const c3 = (src[i+3] - 0x20) & 0x3f;
        try out.append(a, (c0 << 2) | (c1 >> 4));
        try out.append(a, ((c1 & 0x0f) << 4) | (c2 >> 2));
        try out.append(a, ((c2 & 0x03) << 6) | c3);
    }
    // Truncate to declared length
    if (out.items.len > length) out.items.len = length;
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, try out.toOwnedSlice(a)) };
}

// ── Quoted-Printable ─────────────────────────────────────────────────────────

fn b2aQpFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return b2aQpKw(p, args, &.{}, &.{});
}
fn b2aQpKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = argBytes(args[0]) catch { try interp.typeError("b2a_qp: expected bytes"); return error.TypeError; };
    const header = kwBool(kw_names, kw_values, "header", false);
    const hex = "0123456789ABCDEF";

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (src) |c| {
        if (header and c == ' ') {
            try out.append(a, '_');
        } else if (c == '=' or c < 0x21 or c > 0x7e) {
            try out.append(a, '=');
            try out.append(a, hex[c >> 4]);
            try out.append(a, hex[c & 0xf]);
        } else {
            try out.append(a, c);
        }
    }
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, try out.toOwnedSlice(a)) };
}

fn a2bQpFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return a2bQpKw(p, args, &.{}, &.{});
}
fn a2bQpKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = argBytes(args[0]) catch { try interp.typeError("a2b_qp: expected bytes"); return error.TypeError; };
    const header = kwBool(kw_names, kw_values, "header", false);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (header and c == '_') {
            try out.append(a, ' ');
            i += 1;
        } else if (c == '=' and i + 2 < src.len) {
            const hi = hexVal(src[i+1]) catch {
                try out.append(a, c);
                i += 1;
                continue;
            };
            const lo = hexVal(src[i+2]) catch {
                try out.append(a, c);
                i += 1;
                continue;
            };
            try out.append(a, (hi << 4) | lo);
            i += 3;
        } else {
            try out.append(a, c);
            i += 1;
        }
    }
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, try out.toOwnedSlice(a)) };
}

// ── RLE for BinHex ───────────────────────────────────────────────────────────

fn rlecodeHqxFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = argBytes(args[0]) catch { try interp.typeError("rlecode_hqx: expected bytes"); return error.TypeError; };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < src.len) {
        const b = src[i];
        if (b == 0x90) {
            // 0x90 is always encoded as 0x90 0x00 (one at a time)
            try out.append(a, 0x90);
            try out.append(a, 0x00);
            i += 1;
        } else {
            var run: usize = 1;
            while (i + run < src.len and src[i + run] == b and run < 255) run += 1;
            try out.append(a, b);
            if (run > 1) {
                try out.append(a, 0x90);
                try out.append(a, @intCast(run));
            }
            i += run;
        }
    }
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, try out.toOwnedSlice(a)) };
}

fn rledecodeHqxFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = argBytes(args[0]) catch { try interp.typeError("rledecode_hqx: expected bytes"); return error.TypeError; };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var last_byte: u8 = 0;
    var i: usize = 0;
    while (i < src.len) {
        const b = src[i];
        i += 1;
        if (b != 0x90) {
            try out.append(a, b);
            last_byte = b;
        } else {
            if (i >= src.len) break;
            const count = src[i];
            i += 1;
            if (count == 0) {
                try out.append(a, 0x90);
                last_byte = 0x90;
            } else {
                // count-1 additional copies (first copy was already output)
                for (0..count - 1) |_| try out.append(a, last_byte);
            }
        }
    }
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, try out.toOwnedSlice(a)) };
}

// ── BinHex 4.0 (b2a_hqx / a2b_hqx) ─────────────────────────────────────────

// 64-char BinHex4 alphabet: printable ASCII 0x21–0x60
const HQX_ALPHA: [64]u8 = blk: {
    var t: [64]u8 = undefined;
    for (0..64) |i| t[i] = @intCast(0x21 + i);
    break :blk t;
};

fn b2aHqxFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = argBytes(args[0]) catch { try interp.typeError("b2a_hqx: expected bytes"); return error.TypeError; };

    // 6-bit encoding: every 3 bytes → 4 6-bit chars
    const out_len = ((src.len + 2) / 3) * 4;
    const out = try a.alloc(u8, out_len);
    var i: usize = 0;
    var j: usize = 0;
    while (i < src.len) : (i += 3) {
        const b0 = src[i];
        const b1: u8 = if (i+1 < src.len) src[i+1] else 0;
        const b2: u8 = if (i+2 < src.len) src[i+2] else 0;
        out[j]   = HQX_ALPHA[b0 >> 2];
        out[j+1] = HQX_ALPHA[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[j+2] = HQX_ALPHA[((b1 & 0x0f) << 2) | (b2 >> 6)];
        out[j+3] = HQX_ALPHA[b2 & 0x3f];
        j += 4;
    }
    return Value{ .bytes = try Bytes.fromOwnedSlice(a, out) };
}

fn a2bHqxFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = argBytes(args[0]) catch { try interp.typeError("a2b_hqx: expected bytes"); return error.TypeError; };

    var lookup: [256]i8 = .{-1} ** 256;
    for (HQX_ALPHA, 0..) |c, idx| lookup[c] = @intCast(idx);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: u32 = 0;
    var bits: u32 = 0;
    for (src) |c| {
        const v = lookup[c];
        if (v < 0) continue; // skip unknown chars (like newlines)
        buf = (buf << 6) | @as(u32, @intCast(v));
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            try out.append(a, @intCast((buf >> @intCast(bits)) & 0xff));
        }
    }
    const dec = try out.toOwnedSlice(a);
    const tup = try Tuple.init(a, 2);
    tup.items[0] = Value{ .bytes = try Bytes.fromOwnedSlice(a, dec) };
    tup.items[1] = Value{ .small_int = 0 };
    return Value{ .tuple = tup };
}
