//! Pinhole `zlib`. Uses std.compress.flate for real deflate/zlib/gzip
//! compression. Supports wbits: positive=zlib, negative=raw, >=24=gzip.
//! crc32/adler32 match CPython's output exactly.

const std = @import("std");
const flate = std.compress.flate;

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Tuple = @import("../object/tuple.zig").Tuple;
const Bytes = @import("../object/bytes.zig").Bytes;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "zlib");

    if (interp.zlib_error_class == null) try buildZlibErrorClass(interp);
    try m.attrs.setStr(a, "error", Value{ .class = interp.zlib_error_class.? });

    if (interp.zlib_cobj_class == null) try buildCobjClass(interp);
    if (interp.zlib_dobj_class == null) try buildDobjClass(interp);

    try regKw(a, m, "compress", compressFn, compressKw);
    try regKw(a, m, "decompress", decompressFn, decompressKw);
    try reg(a, m, "crc32", crc32Fn);
    try reg(a, m, "adler32", adler32Fn);
    try regKw(a, m, "compressobj", compressobjFn, compressobjKw);
    try regKw(a, m, "decompressobj", decompressobjFn, decompressobjKw);

    const consts = &[_]struct { []const u8, i64 }{
        .{ "Z_NO_COMPRESSION", 0 },
        .{ "Z_BEST_SPEED", 1 },
        .{ "Z_BEST_COMPRESSION", 9 },
        .{ "Z_DEFAULT_COMPRESSION", -1 },
        .{ "MAX_WBITS", 15 },
        .{ "DEFLATED", 8 },
        .{ "DEF_BUF_SIZE", 16384 },
        .{ "DEF_MEM_LEVEL", 8 },
        .{ "Z_DEFAULT_STRATEGY", 0 },
        .{ "Z_FILTERED", 1 },
        .{ "Z_HUFFMAN_ONLY", 2 },
        .{ "Z_RLE", 3 },
        .{ "Z_FIXED", 4 },
        .{ "Z_NO_FLUSH", 0 },
        .{ "Z_PARTIAL_FLUSH", 1 },
        .{ "Z_SYNC_FLUSH", 2 },
        .{ "Z_FULL_FLUSH", 3 },
        .{ "Z_FINISH", 4 },
        .{ "Z_BLOCK", 5 },
        .{ "Z_TREES", 6 },
    };
    for (consts) |pair| {
        try m.attrs.setStr(a, pair[0], Value{ .small_int = pair[1] });
    }
    return m;
}

fn reg(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn argBytes(v: Value) ![]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

fn containerFromWbits(wbits: i64) flate.Container {
    if (wbits < 0) return .raw;
    if (wbits >= 24) return .gzip;
    return .zlib;
}

fn levelToOpts(level: i64) flate.Compress.Options {
    return switch (level) {
        1 => .level_1,
        2 => .level_2,
        3 => .level_3,
        4 => .level_4,
        5 => .level_5,
        7 => .level_7,
        8 => .level_8,
        9 => .level_9,
        else => .level_6, // 6 and -1 (default)
    };
}

pub fn zlibCompress(a: std.mem.Allocator, data: []const u8, level: i64, wbits: i64) ![]u8 {
    const container = containerFromWbits(wbits);
    // level 0 = minimum compression — use level 1 (fastest)
    const effective_level: i64 = if (level == 0) 1 else level;
    const opts = levelToOpts(effective_level);
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    // Compress.init asserts output.buffer.len > 8; pre-allocate enough space.
    try aw.ensureTotalCapacity(data.len + 64);
    var history: [flate.max_window_len * 2]u8 = undefined;
    var c = try flate.Compress.init(&aw.writer, &history, container, opts);
    try c.writer.writeAll(data);
    try c.finish();
    return try aw.toOwnedSlice();
}

pub fn zlibDecompress(a: std.mem.Allocator, data: []const u8, wbits: i64) !struct { out: []u8, consumed: usize } {
    const container = containerFromWbits(wbits);
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var reader: std.Io.Reader = .fixed(data);
    // Use empty buffer (direct mode) so streamRemaining writes directly to aw.writer.
    // Indirect mode (&buf) buffers data inside the Decompress struct and ignores the writer.
    var decomp: flate.Decompress = .init(&reader, container, &.{});
    _ = decomp.reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => return error.InvalidData,
        else => return err,
    };
    const consumed = reader.seek;
    return .{ .out = try aw.toOwnedSlice(), .consumed = consumed };
}

// Keep lzCompressPub / lzDecompressPub as aliases for backward compat
// (gzip_mod.zig uses them)
pub fn lzCompressPub(a: std.mem.Allocator, data: []const u8) ![]u8 {
    return zlibCompress(a, data, -1, 15);
}

pub fn lzDecompressPub(a: std.mem.Allocator, data: []const u8) ![]u8 {
    const r = try zlibDecompress(a, data, 15);
    return r.out;
}

// ===== compress / decompress =====

fn compressImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.raisePy("TypeError", "compress requires data");
        return error.PyException;
    }
    const data = argBytes(args[0]) catch {
        try interp.raisePy("TypeError", "compress argument must be bytes-like");
        return error.PyException;
    };
    var level: i64 = -1;
    var wbits: i64 = 15;
    if (args.len >= 2 and args[1] == .small_int) level = args[1].small_int;
    if (args.len >= 3 and args[2] == .small_int) wbits = args[2].small_int;
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str) {
            if (std.mem.eql(u8, kn.str.bytes, "level") and v == .small_int) level = v.small_int;
            if (std.mem.eql(u8, kn.str.bytes, "wbits") and v == .small_int) wbits = v.small_int;
        }
    }
    const out = zlibCompress(a, data, level, wbits) catch {
        try raiseZlibError(interp, "compress failed");
        return error.PyException;
    };
    defer a.free(out);
    const b = try Bytes.init(a, out);
    return Value{ .bytes = b };
}

fn compressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return compressImpl(interp, args, &.{}, &.{});
}
fn compressKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return compressImpl(interp, args, kn, kv);
}

fn decompressImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.raisePy("TypeError", "decompress requires data");
        return error.PyException;
    }
    const data = argBytes(args[0]) catch {
        try interp.raisePy("TypeError", "decompress argument must be bytes-like");
        return error.PyException;
    };
    var wbits: i64 = 15;
    if (args.len >= 2 and args[1] == .small_int) wbits = args[1].small_int;
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "wbits") and v == .small_int) wbits = v.small_int;
    }
    const result = zlibDecompress(a, data, wbits) catch {
        try raiseZlibError(interp, "error -3 while decompressing data: incorrect header check");
        return error.PyException;
    };
    defer a.free(result.out);
    const b = try Bytes.init(a, result.out);
    return Value{ .bytes = b };
}

fn decompressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return decompressImpl(interp, args, &.{}, &.{});
}
fn decompressKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return decompressImpl(interp, args, kn, kv);
}

// ===== crc32 / adler32 =====

fn crc32Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return error.TypeError;
    const data = try argBytes(args[0]);
    // CRC32 ISO HDLC: initial = 0xFFFFFFFF, xor_output = 0xFFFFFFFF
    // internal state after output `s` = s ^ 0xFFFFFFFF
    var crc: std.hash.Crc32 = .init();
    if (args.len >= 2 and args[1] == .small_int) {
        const seed: u32 = @truncate(@as(u64, @bitCast(args[1].small_int)));
        crc = .{ .crc = seed ^ 0xFFFFFFFF };
    }
    crc.update(data);
    const v: u32 = crc.final();
    return Value{ .small_int = @intCast(v) };
}

fn adler32Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return error.TypeError;
    const data = try argBytes(args[0]);
    var adler: std.hash.Adler32 = .{};
    if (args.len >= 2 and args[1] == .small_int) {
        const seed: u32 = @truncate(@as(u64, @bitCast(args[1].small_int)));
        adler = .{ .adler = seed };
    }
    adler.update(data);
    const v: u32 = adler.adler;
    return Value{ .small_int = @intCast(v) };
}

// ===== zlib.error =====

fn buildZlibErrorClass(interp: *Interp) !void {
    const a = interp.allocator;
    const exc_v = interp.builtins.getStr("Exception") orelse return error.NameError;
    if (exc_v != .class) return error.TypeError;
    const d = try Dict.init(a);
    interp.zlib_error_class = try Class.init(a, "error", &.{exc_v.class}, d);
}

fn raiseZlibError(interp: *Interp, msg: []const u8) !void {
    const cls = interp.zlib_error_class orelse {
        try interp.raisePy("Exception", msg);
        return;
    };
    const inst = try Instance.init(interp.allocator, cls);
    const t = try Tuple.init(interp.allocator, 1);
    t.items[0] = Value{ .str = try Str.init(interp.allocator, msg) };
    try inst.dict.setStr(interp.allocator, "args", Value{ .tuple = t });
    interp.current_exc = Value{ .instance = inst };
}

// ===== compressobj =====

const Cobj = struct {
    buf: std.ArrayList(u8),
    level: i64,
    wbits: i64,
};

fn buildCobjClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "compress", cobjCompress);
    try methodReg(a, d, "flush", cobjFlush);
    interp.zlib_cobj_class = try Class.init(a, "Compress", &.{}, d);
}

fn methodReg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn cobjFromInst(inst: *Instance) *Cobj {
    const v = inst.dict.getStr("_cobj").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn compressobjFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return compressobjImpl(p, args, &.{}, &.{});
}

fn compressobjKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return compressobjImpl(p, args, kn, kv);
}

fn compressobjImpl(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_vals: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (interp.zlib_cobj_class == null) try buildCobjClass(interp);

    var level: i64 = -1;
    var wbits: i64 = 15;
    if (args.len >= 1 and args[0] == .small_int) level = args[0].small_int;
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str) {
            if (std.mem.eql(u8, kn.str.bytes, "level") and v == .small_int) level = v.small_int;
            if (std.mem.eql(u8, kn.str.bytes, "wbits") and v == .small_int) wbits = v.small_int;
        }
    }

    const co = try a.create(Cobj);
    co.* = .{ .buf = .empty, .level = level, .wbits = wbits };
    const inst = try Instance.init(a, interp.zlib_cobj_class.?);
    try inst.dict.setStr(a, "_cobj", Value{ .small_int = @intCast(@intFromPtr(co)) });
    return Value{ .instance = inst };
}

fn cobjCompress(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const co = cobjFromInst(args[0].instance);
    const data: []const u8 = if (args.len >= 2) (argBytes(args[1]) catch &.{}) else &.{};
    try co.buf.appendSlice(a, data);
    const b = try Bytes.init(a, &.{});
    return Value{ .bytes = b };
}

fn cobjFlush(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const co = cobjFromInst(args[0].instance);
    // flush_mode: Z_FINISH=4 (default), Z_SYNC_FLUSH=2, Z_FULL_FLUSH=3, etc.
    // For non-finish modes, defer compression: just return empty bytes.
    const flush_mode: i64 = if (args.len >= 2 and args[1] == .small_int) args[1].small_int else 4;
    if (flush_mode != 4) {
        return Value{ .bytes = try Bytes.init(a, &.{}) };
    }
    const out = zlibCompress(a, co.buf.items, co.level, co.wbits) catch {
        try raiseZlibError(interp, "compress failed");
        return error.PyException;
    };
    defer a.free(out);
    co.buf.clearRetainingCapacity();
    const b = try Bytes.init(a, out);
    return Value{ .bytes = b };
}

// ===== decompressobj =====

const Dobj = struct {
    pending: std.ArrayList(u8),
    unused_data_bytes: std.ArrayList(u8),
    wbits: i64,
};

fn buildDobjClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "decompress", dobjDecompress);
    try methodReg(a, d, "flush", dobjFlush);
    interp.zlib_dobj_class = try Class.init(a, "Decompress", &.{}, d);
}

fn dobjFromInst(inst: *Instance) *Dobj {
    const v = inst.dict.getStr("_dobj").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn decompressobjFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return decompressobjImpl(p, args, &.{}, &.{});
}

fn decompressobjKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return decompressobjImpl(p, args, kn, kv);
}

fn decompressobjImpl(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_vals: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (interp.zlib_dobj_class == null) try buildDobjClass(interp);

    var wbits: i64 = 15;
    if (args.len >= 1 and args[0] == .small_int) wbits = args[0].small_int;
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "wbits") and v == .small_int) wbits = v.small_int;
    }

    const dobj = try a.create(Dobj);
    dobj.* = .{
        .pending = .empty,
        .unused_data_bytes = .empty,
        .wbits = wbits,
    };

    const inst = try Instance.init(a, interp.zlib_dobj_class.?);
    try inst.dict.setStr(a, "_dobj", Value{ .small_int = @intCast(@intFromPtr(dobj)) });
    try inst.dict.setStr(a, "unused_data", Value{ .bytes = try Bytes.init(a, &.{}) });
    try inst.dict.setStr(a, "unconsumed_tail", Value{ .bytes = try Bytes.init(a, &.{}) });
    return Value{ .instance = inst };
}

fn dobjDecompress(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const dobj = dobjFromInst(inst);

    const data: []const u8 = if (args.len >= 2) (argBytes(args[1]) catch &.{}) else &.{};
    try dobj.pending.appendSlice(a, data);

    const result = zlibDecompress(a, dobj.pending.items, dobj.wbits) catch {
        const b = try Bytes.init(a, &.{});
        return Value{ .bytes = b };
    };
    errdefer a.free(result.out);

    const extra = dobj.pending.items[result.consumed..];
    dobj.unused_data_bytes.clearRetainingCapacity();
    try dobj.unused_data_bytes.appendSlice(a, extra);
    dobj.pending.clearRetainingCapacity();

    const unused_b = try Bytes.init(a, dobj.unused_data_bytes.items);
    try inst.dict.setStr(a, "unused_data", Value{ .bytes = unused_b });

    defer a.free(result.out);
    const b = try Bytes.init(a, result.out);
    return Value{ .bytes = b };
}

fn dobjFlush(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const b = try Bytes.init(interp.allocator, &.{});
    return Value{ .bytes = b };
}
