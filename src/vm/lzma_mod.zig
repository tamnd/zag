//! `lzma` module. XZ compress/decompress using src/lib/lzma.zig (store mode).
//! LZMACompressor, LZMADecompressor, LZMAFile, lzma.open.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Bytes = @import("../object/bytes.zig").Bytes;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const lzmalib = @import("../lib/lzma.zig");

// ===== State structs =====

const CompressorState = struct {
    buf: std.ArrayListUnmanaged(u8),
    flushed: bool,
    allocator: std.mem.Allocator,

    fn deinit(s: *CompressorState) void {
        s.buf.deinit(s.allocator);
    }
};

const DecompressorState = struct {
    in_buf: std.ArrayListUnmanaged(u8),
    out_buf: std.ArrayListUnmanaged(u8),
    out_pos: usize,
    eof: bool,
    unused_data: std.ArrayListUnmanaged(u8),
    needs_input: bool,
    allocator: std.mem.Allocator,

    fn deinit(s: *DecompressorState) void {
        s.in_buf.deinit(s.allocator);
        s.out_buf.deinit(s.allocator);
        s.unused_data.deinit(s.allocator);
    }
};

const LzmaFileState = struct {
    path: []u8,
    mode_write: bool,
    text_mode: bool,
    buf: std.ArrayListUnmanaged(u8),
    pos: usize,
    closed: bool,
    allocator: std.mem.Allocator,

    fn deinit(s: *LzmaFileState) void {
        s.allocator.free(s.path);
        s.buf.deinit(s.allocator);
    }
};

// ===== Helpers =====

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

fn methodReg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn methodRegKw(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn argBytes(v: Value) ![]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

fn argStr(v: Value) ?[]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        else => null,
    };
}

fn readFileToBytes(interp: *Interp, path: []const u8) ![]u8 {
    const a = interp.allocator;
    var file = std.Io.Dir.cwd().openFile(interp.io, path, .{}) catch return error.FileNotFound;
    defer file.close(interp.io);
    var data: std.ArrayListUnmanaged(u8) = .empty;
    errdefer data.deinit(a);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(interp.io, &read_buf);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const got = reader.interface.readSliceShort(chunk[0..]) catch break;
        if (got == 0) break;
        try data.appendSlice(a, chunk[0..got]);
    }
    return data.toOwnedSlice(a);
}

fn writeBytesToFile(interp: *Interp, path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(interp.io, path, .{ .truncate = true });
    defer file.close(interp.io);
    var write_buf: [4096]u8 = undefined;
    var w = file.writer(interp.io, &write_buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

// ===== Module build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "lzma");

    if (interp.lzma_error_class == null) try buildErrorClass(interp);
    if (interp.lzma_compressor_class == null) try buildCompressorClass(interp);
    if (interp.lzma_decompressor_class == null) try buildDecompressorClass(interp);
    if (interp.lzma_file_class == null) try buildLzmaFileClass(interp);

    try m.attrs.setStr(a, "LZMAError", Value{ .class = interp.lzma_error_class.? });
    try m.attrs.setStr(a, "LZMACompressor", Value{ .class = interp.lzma_compressor_class.? });
    try m.attrs.setStr(a, "LZMADecompressor", Value{ .class = interp.lzma_decompressor_class.? });
    try m.attrs.setStr(a, "LZMAFile", Value{ .class = interp.lzma_file_class.? });

    try regKw(a, m, "compress", lzmaCompressFn, lzmaCompressKw);
    try reg(a, m, "decompress", lzmaDecompressFn);
    try regKw(a, m, "open", lzmaOpenFn, lzmaOpenKw);

    // Format constants
    try m.attrs.setStr(a, "FORMAT_AUTO", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "FORMAT_XZ", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "FORMAT_ALONE", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "FORMAT_RAW", Value{ .small_int = 3 });
    // Check constants
    try m.attrs.setStr(a, "CHECK_NONE", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "CHECK_CRC32", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "CHECK_CRC64", Value{ .small_int = 4 });
    try m.attrs.setStr(a, "CHECK_SHA256", Value{ .small_int = 10 });
    // is_check_supported
    try reg(a, m, "is_check_supported", isCheckSupportedFn);

    return m;
}

fn buildErrorClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    interp.lzma_error_class = try Class.init(a, "LZMAError", &.{}, d);
}

fn isCheckSupportedFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .boolean = true };
}

// ===== lzma.compress / lzma.decompress =====

fn lzmaCompressImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    const a = interp.allocator;
    if (args.len < 1) {
        try raiseLzmaError(interp, "compress() requires data");
        return error.PyException;
    }
    const data = argBytes(args[0]) catch {
        try raiseLzmaError(interp, "data must be bytes-like");
        return error.PyException;
    };
    // preset kwarg (ignored for store mode, but we accept it)
    _ = kw_names;
    _ = kw_vals;
    const out = lzmalib.compress(a, data) catch {
        try raiseLzmaError(interp, "compress failed");
        return error.PyException;
    };
    defer a.free(out);
    return Value{ .bytes = try Bytes.init(a, out) };
}

fn lzmaCompressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return lzmaCompressImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn lzmaCompressKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return lzmaCompressImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

fn lzmaDecompressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) {
        try raiseLzmaError(interp, "decompress() requires data");
        return error.PyException;
    }
    const data = argBytes(args[0]) catch {
        try raiseLzmaError(interp, "data must be bytes-like");
        return error.PyException;
    };
    var all_out: std.ArrayListUnmanaged(u8) = .empty;
    defer all_out.deinit(a);
    var remaining = data;
    while (remaining.len > 0) {
        const r = lzmalib.decompress(a, remaining) catch {
            try raiseLzmaError(interp, "Invalid data stream");
            return error.PyException;
        };
        defer a.free(r.out);
        try all_out.appendSlice(a, r.out);
        if (r.consumed == 0 or r.consumed > remaining.len) break;
        remaining = remaining[r.consumed..];
    }
    return Value{ .bytes = try Bytes.init(a, all_out.items) };
}

fn raiseLzmaError(interp: *Interp, msg: []const u8) !void {
    const a = interp.allocator;
    const cls = interp.lzma_error_class orelse {
        try interp.raisePy("Exception", msg);
        return;
    };
    const inst = try Instance.init(a, cls);
    const t = try @import("../object/tuple.zig").Tuple.init(a, 1);
    t.items[0] = Value{ .str = try Str.init(a, msg) };
    try inst.dict.setStr(a, "args", Value{ .tuple = t });
    interp.current_exc = Value{ .instance = inst };
}

// ===== LZMACompressor =====

fn buildCompressorClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodRegKw(a, d, "__init__", czInitFn, czInitKw);
    try methodReg(a, d, "compress", czCompressFn);
    try methodRegKw(a, d, "flush", czFlushFn, czFlushKw);
    interp.lzma_compressor_class = try Class.init(a, "LZMACompressor", &.{}, d);
}

fn czStateFrom(inst: *Instance) *CompressorState {
    const v = inst.dict.getStr("_cz").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn czInitImpl(interp: *Interp, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state = try a.create(CompressorState);
    state.* = .{ .buf = .empty, .flushed = false, .allocator = a };
    try inst.dict.setStr(a, "_cz", Value{ .small_int = @intCast(@intFromPtr(state)) });
    return Value{ .none = {} };
}
fn czInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return czInitImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn czInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return czInitImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

fn czCompressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const state = czStateFrom(args[0].instance);
    const data = argBytes(args[1]) catch return Value{ .bytes = try Bytes.init(a, &.{}) };
    try state.buf.appendSlice(a, data);
    return Value{ .bytes = try Bytes.init(a, &.{}) };
}

fn czFlushImpl(interp: *Interp, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const state = czStateFrom(args[0].instance);
    if (state.flushed) {
        try interp.raisePy("EOFError", "End of stream already reached");
        return error.PyException;
    }
    state.flushed = true;
    const out = lzmalib.compress(a, state.buf.items) catch {
        try raiseLzmaError(interp, "compress failed");
        return error.PyException;
    };
    defer a.free(out);
    return Value{ .bytes = try Bytes.init(a, out) };
}
fn czFlushFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return czFlushImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn czFlushKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return czFlushImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

// ===== LZMADecompressor =====

fn buildDecompressorClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodRegKw(a, d, "__init__", dzInitFn, dzInitKw);
    try methodRegKw(a, d, "decompress", dzDecompressFn, dzDecompressKw);
    interp.lzma_decompressor_class = try Class.init(a, "LZMADecompressor", &.{}, d);
}

fn dzStateFrom(inst: *Instance) *DecompressorState {
    const v = inst.dict.getStr("_dz").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn dzInitImpl(interp: *Interp, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state = try a.create(DecompressorState);
    state.* = .{
        .in_buf = .empty,
        .out_buf = .empty,
        .out_pos = 0,
        .eof = false,
        .unused_data = .empty,
        .needs_input = true,
        .allocator = a,
    };
    try inst.dict.setStr(a, "_dz", Value{ .small_int = @intCast(@intFromPtr(state)) });
    try inst.dict.setStr(a, "eof", Value{ .boolean = false });
    try inst.dict.setStr(a, "unused_data", Value{ .bytes = try Bytes.init(a, &.{}) });
    try inst.dict.setStr(a, "needs_input", Value{ .boolean = true });
    return Value{ .none = {} };
}
fn dzInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dzInitImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn dzInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return dzInitImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

fn dzDecompressImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) anyerror!Value {
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state = dzStateFrom(inst);

    if (state.eof and state.out_pos >= state.out_buf.items.len) {
        try interp.raisePy("EOFError", "End of stream already reached");
        return error.PyException;
    }

    const chunk = if (args.len >= 2) argBytes(args[1]) catch &.{} else &.{};
    var max_length: i64 = -1;
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "max_length") and v == .small_int)
            max_length = v.small_int;
    }
    if (args.len >= 3 and args[2] == .small_int) max_length = args[2].small_int;

    try state.in_buf.appendSlice(a, chunk);

    if (state.out_pos >= state.out_buf.items.len and !state.eof and state.in_buf.items.len >= 4) {
        const r = lzmalib.decompress(a, state.in_buf.items) catch |err| {
            if (err == error.InvalidData) {
                // Check magic to distinguish partial vs invalid
                if (state.in_buf.items.len >= 6 and
                    !std.mem.eql(u8, state.in_buf.items[0..6], &[_]u8{ 0xFD, '7', 'z', 'X', 'Z', 0x00 }))
                {
                    try raiseLzmaError(interp, "Invalid data stream");
                    return error.PyException;
                }
                // Incomplete stream — wait for more input
                state.needs_input = true;
                try inst.dict.setStr(a, "needs_input", Value{ .boolean = true });
                return Value{ .bytes = try Bytes.init(a, &.{}) };
            }
            // EndOfStream or other error — treat as incomplete
            state.needs_input = true;
            try inst.dict.setStr(a, "needs_input", Value{ .boolean = true });
            return Value{ .bytes = try Bytes.init(a, &.{}) };
        };
        const consumed = r.consumed;
        const leftover = state.in_buf.items[consumed..];
        try state.unused_data.appendSlice(a, leftover);
        state.in_buf.items.len = 0;

        state.out_buf.items.len = 0;
        state.out_pos = 0;
        try state.out_buf.appendSlice(a, r.out);
        a.free(r.out);

        state.eof = true;
        state.needs_input = false;
    }

    const avail = if (state.out_pos < state.out_buf.items.len)
        state.out_buf.items[state.out_pos..]
    else
        &.{};

    const n: usize = if (max_length >= 0 and @as(usize, @intCast(max_length)) < avail.len)
        @intCast(max_length)
    else
        avail.len;

    const result = avail[0..n];
    state.out_pos += n;

    const still_buffered = state.out_pos < state.out_buf.items.len;
    const needs = !state.eof and state.in_buf.items.len == 0 and !still_buffered;
    state.needs_input = needs;

    try inst.dict.setStr(a, "eof", Value{ .boolean = state.eof and !still_buffered });
    try inst.dict.setStr(a, "needs_input", Value{ .boolean = needs });
    try inst.dict.setStr(a, "unused_data", Value{ .bytes = try Bytes.init(a, state.unused_data.items) });

    return Value{ .bytes = try Bytes.init(a, result) };
}
fn dzDecompressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dzDecompressImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn dzDecompressKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return dzDecompressImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

// ===== LZMAFile =====

fn buildLzmaFileClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodRegKw(a, d, "__init__", bfInitFn, bfInitKw);
    try methodReg(a, d, "write", bfWriteFn);
    try methodRegKw(a, d, "read", bfReadFn, bfReadKw);
    try methodReg(a, d, "readline", bfReadlineFn);
    try methodReg(a, d, "peek", bfPeekFn);
    try methodReg(a, d, "tell", bfTellFn);
    try methodRegKw(a, d, "seek", bfSeekFn, bfSeekKw);
    try methodReg(a, d, "close", bfCloseFn);
    try methodReg(a, d, "flush", bfFlushFn);
    try methodReg(a, d, "readable", bfReadableFn);
    try methodReg(a, d, "writable", bfWritableFn);
    try methodReg(a, d, "__enter__", bfEnterFn);
    try methodReg(a, d, "__exit__", bfExitFn);
    interp.lzma_file_class = try Class.init(a, "LZMAFile", &.{}, d);
}

fn bfStateFrom(inst: *Instance) *LzmaFileState {
    const v = inst.dict.getStr("_lf").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn bfInitImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) anyerror!Value {
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;

    var path_str: []const u8 = "";
    var mode_str: []const u8 = "rb";

    if (args.len >= 2 and args[1] != .none) {
        if (argStr(args[1])) |s| path_str = s;
        if (args[1] == .bytes) path_str = args[1].bytes.data;
    }
    if (args.len >= 3 and args[2] != .none) {
        if (argStr(args[2])) |s| mode_str = s;
    }
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str) {
            const k = kn.str.bytes;
            if (std.mem.eql(u8, k, "mode")) { if (argStr(v)) |s| mode_str = s; }
        }
    }

    const is_write = std.mem.startsWith(u8, mode_str, "w") or std.mem.startsWith(u8, mode_str, "a");
    const is_text = std.mem.endsWith(u8, mode_str, "t");

    const state = try a.create(LzmaFileState);
    state.* = .{
        .path = try a.dupe(u8, path_str),
        .mode_write = is_write,
        .text_mode = is_text,
        .buf = .empty,
        .pos = 0,
        .closed = false,
        .allocator = a,
    };

    if (!is_write and path_str.len > 0) {
        const file_data = readFileToBytes(interp, path_str) catch {
            state.deinit();
            a.destroy(state);
            try interp.raisePy("OSError", "cannot open lzma file");
            return error.PyException;
        };
        defer a.free(file_data);
        var remaining = file_data;
        while (remaining.len > 0) {
            const r = lzmalib.decompress(a, remaining) catch {
                state.deinit();
                a.destroy(state);
                try raiseLzmaError(interp, "not an lzma/xz file");
                return error.PyException;
            };
            try state.buf.appendSlice(a, r.out);
            a.free(r.out);
            if (r.consumed == 0 or r.consumed > remaining.len) break;
            remaining = remaining[r.consumed..];
        }
    }

    try inst.dict.setStr(a, "_lf", Value{ .small_int = @intCast(@intFromPtr(state)) });
    try inst.dict.setStr(a, "closed", Value{ .boolean = false });
    return Value{ .none = {} };
}
fn bfInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return bfInitImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn bfInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return bfInitImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

fn bfWriteFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const state = bfStateFrom(args[0].instance);
    if (state.closed) {
        try interp.raisePy("ValueError", "write to closed file");
        return error.PyException;
    }
    const data_val = if (args.len >= 2) args[1] else Value{ .bytes = try Bytes.init(a, &.{}) };
    const data: []const u8 = switch (data_val) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        else => &.{},
    };
    try state.buf.appendSlice(a, data);
    return Value{ .small_int = @intCast(data.len) };
}

fn bfReadImpl(interp: *Interp, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const state = bfStateFrom(args[0].instance);
    if (state.closed) {
        try interp.raisePy("ValueError", "read from closed file");
        return error.PyException;
    }
    var size: i64 = -1;
    if (args.len >= 2 and args[1] == .small_int) size = args[1].small_int;
    const avail = state.buf.items[state.pos..];
    const n: usize = if (size < 0 or @as(usize, @intCast(size)) >= avail.len)
        avail.len
    else
        @intCast(size);
    const chunk = avail[0..n];
    state.pos += n;
    if (state.text_mode) return Value{ .str = try Str.init(a, chunk) };
    return Value{ .bytes = try Bytes.init(a, chunk) };
}
fn bfReadFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return bfReadImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn bfReadKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return bfReadImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

fn bfReadlineFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const state = bfStateFrom(args[0].instance);
    const avail = state.buf.items[state.pos..];
    if (avail.len == 0) {
        if (state.text_mode) return Value{ .str = try Str.init(a, "") };
        return Value{ .bytes = try Bytes.init(a, &.{}) };
    }
    const nl = std.mem.indexOfScalar(u8, avail, '\n');
    const n = if (nl) |idx| idx + 1 else avail.len;
    state.pos += n;
    if (state.text_mode) return Value{ .str = try Str.init(a, avail[0..n]) };
    return Value{ .bytes = try Bytes.init(a, avail[0..n]) };
}

fn bfPeekFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const state = bfStateFrom(args[0].instance);
    const avail = state.buf.items[state.pos..];
    var n: usize = avail.len;
    if (args.len >= 2 and args[1] == .small_int) {
        const req: usize = @intCast(@max(0, args[1].small_int));
        if (req < n) n = req;
    }
    return Value{ .bytes = try Bytes.init(a, avail[0..n]) };
}

fn bfTellFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const state = bfStateFrom(args[0].instance);
    if (state.mode_write) return Value{ .small_int = @intCast(state.buf.items.len) };
    return Value{ .small_int = @intCast(state.pos) };
}

fn bfSeekImpl(_: *Interp, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const state = bfStateFrom(args[0].instance);
    const offset: i64 = if (args[1] == .small_int) args[1].small_int else 0;
    var whence: i64 = 0;
    if (args.len >= 3 and args[2] == .small_int) whence = args[2].small_int;
    const data_len: i64 = @intCast(state.buf.items.len);
    const cur: i64 = @intCast(state.pos);
    const new_pos: i64 = switch (whence) {
        0 => offset,
        1 => cur + offset,
        2 => data_len + offset,
        else => cur,
    };
    state.pos = @intCast(@max(0, @min(new_pos, data_len)));
    return Value{ .small_int = @intCast(state.pos) };
}
fn bfSeekFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return bfSeekImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn bfSeekKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return bfSeekImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

fn bfCloseFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state = bfStateFrom(inst);
    if (state.closed) return Value{ .none = {} };
    if (state.mode_write and state.path.len > 0) {
        const out = lzmalib.compress(a, state.buf.items) catch {
            try raiseLzmaError(interp, "compress failed on close");
            return error.PyException;
        };
        defer a.free(out);
        writeBytesToFile(interp, state.path, out) catch {
            try interp.raisePy("OSError", "cannot write lzma file");
            return error.PyException;
        };
    }
    state.closed = true;
    try inst.dict.setStr(a, "closed", Value{ .boolean = true });
    return Value{ .none = {} };
}

fn bfFlushFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .none = {} };
}

fn bfReadableFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const state = bfStateFrom(args[0].instance);
    return Value{ .boolean = !state.mode_write };
}

fn bfWritableFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const state = bfStateFrom(args[0].instance);
    return Value{ .boolean = state.mode_write };
}

fn bfEnterFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    return args[0];
}

fn bfExitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return bfCloseFn(p, args[0..1]);
}

// ===== lzma.open =====

fn lzmaOpenImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    if (interp.lzma_file_class == null) try buildLzmaFileClass(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.lzma_file_class.?);
    const self = Value{ .instance = inst };
    var init_args: [3]Value = undefined;
    init_args[0] = self;
    var n: usize = 1;
    if (args.len >= 1) { init_args[1] = args[0]; n = 2; }
    if (args.len >= 2) { init_args[2] = args[1]; n = 3; }
    _ = try bfInitImpl(interp, init_args[0..n], kw_names, kw_vals);
    return self;
}
fn lzmaOpenFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return lzmaOpenImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn lzmaOpenKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return lzmaOpenImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}
