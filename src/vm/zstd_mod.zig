//! `compression.zstd` module — zstd compress/decompress.
//! Compress: raw-block zstd frames (uncompressed, valid zstd format).
//! Decompress: std.compress.zstd.

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
const Tuple = @import("../object/tuple.zig").Tuple;
const List = @import("../object/list.zig").List;
const Interp = @import("interp.zig").Interp;

// Mirror io_mod.Buf layout
const IoModBuf = struct {
    data: std.ArrayList(u8),
    pos: usize = 0,
    closed: bool = false,
};

const ZSTD_MAGIC = [4]u8{ 0x28, 0xB5, 0x2F, 0xFD };
const BLOCK_SIZE_MAX: usize = 1 << 17; // 128KB

// ===== Raw-frame compressor =====
// Produces valid zstd frames using raw (uncompressed) blocks.
pub fn compress(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);

    // Magic
    try out.appendSlice(a, &ZSTD_MAGIC);

    // FHD: FCS_Flag=3 (8-byte content size), Single_Segment=0, no checksum
    // FHD bits: [7:6]=FCS_Flag, [5]=Single_Segment, [4]=unused, [3]=checksum, [1:0]=dict_id
    // FCS_Flag=3 → bits 7:6 = 11 → 0b11000000 = 0xC0
    // Window_Descriptor needed when Single_Segment=0
    const fhd: u8 = 0xC0; // FCS_Flag=3, Single_Segment=0
    try out.append(a, fhd);

    // Window_Descriptor: exponent=17 (window=128KB), mantissa=0
    // Format: bits [7:3]=exponent, bits[2:0]=mantissa; window_size = (mantissa+8) * 2^(exponent-1) ... actually:
    // window_log = 10 + (WD >> 3), mantissa = WD & 7
    // window_size = (1 + (mantissa/8)) * 2^window_log
    // For window=128KB=131072 = 2^17: window_log=17, so WD>>3=7, mantissa=0 → WD=56=0x38
    try out.append(a, 0x38);

    // Content size (8 bytes, LE)
    var cs_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &cs_buf, @intCast(data.len), .little);
    try out.appendSlice(a, &cs_buf);

    // Blocks
    var pos: usize = 0;
    while (pos < data.len or data.len == 0) {
        const end = @min(pos + BLOCK_SIZE_MAX, data.len);
        const block_data = data[pos..end];
        const is_last = end == data.len;
        const bsize = block_data.len;
        // Block header (24-bit LE): bits[0]=Last_Block, bits[2:1]=Block_Type(0=raw), bits[23:3]=Block_Size
        const hdr_val: u32 = @intCast((bsize << 3) | (@as(usize, if (is_last) 1 else 0)));
        try out.append(a, @intCast(hdr_val & 0xFF));
        try out.append(a, @intCast((hdr_val >> 8) & 0xFF));
        try out.append(a, @intCast((hdr_val >> 16) & 0xFF));
        try out.appendSlice(a, block_data);
        if (data.len == 0) break;
        pos = end;
        if (is_last) break;
    }

    return out.toOwnedSlice(a);
}

// Parse the raw frame header to find how many input bytes form the first frame.
// Returns null if the frame is incomplete or malformed.
fn findFrameEnd(data: []const u8) ?usize {
    if (data.len < 6 or !std.mem.eql(u8, data[0..4], &ZSTD_MAGIC)) return null;
    const fhd = data[4];
    const fcs_flag = (fhd >> 6) & 3;
    const single_seg: u8 = (fhd >> 5) & 1;
    var pos: usize = 5;
    if (single_seg == 0) {
        if (pos >= data.len) return null;
        pos += 1; // Window_Descriptor
    }
    const cs_bytes: usize = switch (fcs_flag) {
        0 => if (single_seg == 1) @as(usize, 1) else 0,
        1 => 2,
        2 => 4,
        3 => 8,
        else => 0,
    };
    if (pos + cs_bytes > data.len) return null;
    pos += cs_bytes;
    while (pos + 3 <= data.len) {
        const hdr: u32 = @as(u32, data[pos]) | (@as(u32, data[pos + 1]) << 8) | (@as(u32, data[pos + 2]) << 16);
        const last = hdr & 1;
        const btype = (hdr >> 1) & 3;
        const bsize: usize = hdr >> 3;
        pos += 3;
        switch (btype) {
            0, 2 => { // Raw or Compressed block
                if (pos + bsize > data.len) return null;
                pos += bsize;
            },
            1 => { // RLE block
                if (pos + 1 > data.len) return null;
                pos += 1;
            },
            else => return null,
        }
        if (last == 1) return pos;
    }
    return null;
}

pub fn decompress(a: std.mem.Allocator, data: []const u8) !struct { out: []u8, consumed: usize } {
    if (data.len < 4 or !std.mem.eql(u8, data[0..4], &ZSTD_MAGIC))
        return error.InvalidZstd;
    const frame_end = findFrameEnd(data) orelse return error.InvalidZstd;
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var reader: std.Io.Reader = .fixed(data[0..frame_end]);
    const buf_size = std.compress.zstd.default_window_len + std.compress.zstd.block_size_max;
    const buf = try a.alloc(u8, buf_size);
    defer a.free(buf);
    var decomp: std.compress.zstd.Decompress = .init(&reader, buf, .{});
    _ = decomp.reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => return error.InvalidZstd,
        else => return err,
    };
    return .{ .out = try aw.toOwnedSlice(), .consumed = frame_end };
}

// ===== Exception =====

fn raiseZstdError(interp: *Interp, msg: []const u8) !void {
    const a = interp.allocator;
    const cls = interp.zstd_error_class orelse {
        try interp.raisePy("ValueError", msg);
        return;
    };
    const inst = try Instance.init(a, cls);
    const t = try Tuple.init(a, 1);
    t.items[0] = Value{ .str = try Str.init(a, msg) };
    try inst.dict.setStr(a, "args", Value{ .tuple = t });
    interp.current_exc = Value{ .instance = inst };
}

// ===== arg helpers =====

fn argBytes(v: Value) ?[]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        else => null,
    };
}

fn argStr(v: Value) ?[]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        else => null,
    };
}

// ===== compress / decompress functions =====

fn compressFnImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    _ = kw_names;
    _ = kw_vals;
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.raisePy("TypeError", "compress requires data");
        return error.PyException;
    }
    const data = argBytes(args[0]) orelse {
        try interp.raisePy("TypeError", "data must be bytes");
        return error.PyException;
    };
    const out = compress(a, data) catch {
        try raiseZstdError(interp, "compress failed");
        return error.PyException;
    };
    defer a.free(out);
    return Value{ .bytes = try Bytes.init(a, out) };
}

fn compressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return compressFnImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn compressKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return compressFnImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

fn decompressFnImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    _ = kw_names;
    _ = kw_vals;
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.raisePy("TypeError", "decompress requires data");
        return error.PyException;
    }
    const data = argBytes(args[0]) orelse {
        try interp.raisePy("TypeError", "data must be bytes");
        return error.PyException;
    };
    const result = decompress(a, data) catch {
        try raiseZstdError(interp, "invalid zstd frame");
        return error.PyException;
    };
    defer a.free(result.out);
    return Value{ .bytes = try Bytes.init(a, result.out) };
}

fn decompressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return decompressFnImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn decompressKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return decompressFnImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

// ===== ZstdCompressor =====
// Buffers all data; emits complete frame on flush() or compress(..., FLUSH_FRAME).

const CompressorState = struct {
    buf: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    fn deinit(s: *CompressorState) void {
        s.buf.deinit(s.allocator);
    }
};

fn coInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .none = {} };
    const state = try a.create(CompressorState);
    state.* = .{ .buf = .empty, .allocator = a };
    try args[0].instance.dict.setStr(a, "_cs", Value{ .small_int = @intCast(@intFromPtr(state)) });
    return Value{ .none = {} };
}

fn coCompressFnImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    _ = kw_names;
    _ = kw_vals;
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .bytes = try Bytes.init(a, &.{}) };
    const inst = args[0].instance;
    const sv = inst.dict.getStr("_cs") orelse return Value{ .bytes = try Bytes.init(a, &.{}) };
    const state: *CompressorState = @ptrFromInt(@as(usize, @intCast(sv.small_int)));
    if (args.len >= 2) {
        const data = argBytes(args[1]) orelse &.{};
        try state.buf.appendSlice(a, data);
    }
    // mode arg: if FLUSH_FRAME (2), emit frame now
    var flush_frame = false;
    if (args.len >= 3) {
        if (args[2] == .small_int and args[2].small_int == 2) flush_frame = true;
    }
    if (flush_frame) {
        const out = compress(a, state.buf.items) catch return Value{ .bytes = try Bytes.init(a, &.{}) };
        defer a.free(out);
        state.buf.clearRetainingCapacity();
        return Value{ .bytes = try Bytes.init(a, out) };
    }
    return Value{ .bytes = try Bytes.init(a, &.{}) };
}

fn coCompressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return coCompressFnImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn coCompressKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return coCompressFnImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

fn coFlushFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .bytes = try Bytes.init(a, &.{}) };
    const sv = args[0].instance.dict.getStr("_cs") orelse return Value{ .bytes = try Bytes.init(a, &.{}) };
    const state: *CompressorState = @ptrFromInt(@as(usize, @intCast(sv.small_int)));
    const out = compress(a, state.buf.items) catch return Value{ .bytes = try Bytes.init(a, &.{}) };
    defer a.free(out);
    state.buf.clearRetainingCapacity();
    return Value{ .bytes = try Bytes.init(a, out) };
}

// ===== ZstdDecompressor =====

const DecompressorState = struct {
    in_buf: std.ArrayListUnmanaged(u8),  // compressed data accumulator
    out_buf: std.ArrayListUnmanaged(u8), // decompressed data not yet returned
    out_pos: usize,
    eof: bool,
    unused_data: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    fn deinit(s: *DecompressorState) void {
        s.in_buf.deinit(s.allocator);
        s.out_buf.deinit(s.allocator);
        s.unused_data.deinit(s.allocator);
    }
};

fn doInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .none = {} };
    const inst = args[0].instance;
    const state = try a.create(DecompressorState);
    state.* = .{
        .in_buf = .empty,
        .out_buf = .empty,
        .out_pos = 0,
        .eof = false,
        .unused_data = .empty,
        .allocator = a,
    };
    try inst.dict.setStr(a, "_ds", Value{ .small_int = @intCast(@intFromPtr(state)) });
    try inst.dict.setStr(a, "eof", Value{ .boolean = false });
    try inst.dict.setStr(a, "unused_data", Value{ .bytes = try Bytes.init(a, &.{}) });
    return Value{ .none = {} };
}

fn doDecompressFnImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) {
        return Value{ .bytes = try Bytes.init(a, &.{}) };
    }
    const inst = args[0].instance;
    const sv = inst.dict.getStr("_ds") orelse return Value{ .bytes = try Bytes.init(a, &.{}) };
    const state: *DecompressorState = @ptrFromInt(@as(usize, @intCast(sv.small_int)));

    var max_len: i64 = -1;
    if (args.len >= 3 and args[2] == .small_int) max_len = args[2].small_int;
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "max_length") and v == .small_int)
            max_len = v.small_int;
    }

    // Append new input
    if (args.len >= 2) {
        const new_data = argBytes(args[1]) orelse &.{};
        try state.in_buf.appendSlice(a, new_data);
    }

    // If we haven't fully decompressed yet, try now
    if (!state.eof and state.out_buf.items.len == 0) {
        const all_in = state.in_buf.items;
        if (all_in.len >= 4 and std.mem.eql(u8, all_in[0..4], &ZSTD_MAGIC)) {
            if (decompress(a, all_in)) |r| {
                try state.out_buf.appendSlice(a, r.out);
                // bytes after the consumed frame are unused_data
                if (r.consumed < all_in.len) {
                    try state.unused_data.appendSlice(a, all_in[r.consumed..]);
                }
                a.free(r.out);
                state.eof = true;
                state.in_buf.clearRetainingCapacity();
            } else |_| {
                // Partial/incomplete frame — keep buffering
            }
        } else if (all_in.len >= 4) {
            // Has data but no magic — garbage
            try raiseZstdError(interp, "invalid zstd frame");
            return error.PyException;
        }
    }

    // Return up to max_len bytes from out_buf
    const available = state.out_buf.items[state.out_pos..];
    const to_return: usize = if (max_len < 0) available.len else @min(@as(usize, @intCast(max_len)), available.len);
    const result = available[0..to_return];
    const out = try Bytes.init(a, result);
    state.out_pos += to_return;

    // Update eof and unused_data on instance
    const fully_consumed = state.out_pos >= state.out_buf.items.len;
    if (state.eof and fully_consumed) {
        try inst.dict.setStr(a, "eof", Value{ .boolean = true });
        try inst.dict.setStr(a, "unused_data", Value{ .bytes = try Bytes.init(a, state.unused_data.items) });
    }

    return Value{ .bytes = out };
}

fn doDecompressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return doDecompressFnImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn doDecompressKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return doDecompressFnImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

// ===== ZstdDict =====

fn zdInitImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    _ = kw_names;
    _ = kw_vals;
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value{ .none = {} };
    const data = argBytes(args[1]) orelse &.{};
    try args[0].instance.dict.setStr(a, "_data", Value{ .bytes = try Bytes.init(a, data) });
    return Value{ .none = {} };
}
fn zdInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return zdInitImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn zdInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return zdInitImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

// ===== ZstdFile =====
// Reuses the same IoModBuf pattern for bytesio.

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

const ZstdFileState = struct {
    path: []u8,
    mode_write: bool,
    text_mode: bool,
    buf: std.ArrayListUnmanaged(u8), // for write: accumulated; for read: decompressed
    pos: usize,
    closed: bool,
    allocator: std.mem.Allocator,
    fn deinit(s: *ZstdFileState) void {
        s.allocator.free(s.path);
        s.buf.deinit(s.allocator);
    }
};

fn zfStateFrom(inst: *Instance) ?*ZstdFileState {
    const v = inst.dict.getStr("_zf") orelse return null;
    if (v.small_int == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn zfInitImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    if (args.len < 2 or args[0] != .instance) return Value{ .none = {} };
    const a = interp.allocator;
    const inst = args[0].instance;
    const path_s = argStr(args[1]) orelse return Value{ .none = {} };
    var mode_str: []const u8 = "rb";
    if (args.len >= 3) mode_str = argStr(args[2]) orelse "rb";
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "mode"))
            mode_str = argStr(v) orelse mode_str;
    }
    const is_write = std.mem.startsWith(u8, mode_str, "w");
    const text_mode = std.mem.endsWith(u8, mode_str, "t");
    const state = try a.create(ZstdFileState);
    state.* = .{
        .path = try a.dupe(u8, path_s),
        .mode_write = is_write,
        .text_mode = text_mode,
        .buf = .empty,
        .pos = 0,
        .closed = false,
        .allocator = a,
    };
    if (!is_write) {
        const file_data = readFileToBytes(interp, path_s) catch {
            a.free(state.path);
            a.destroy(state);
            try interp.raisePy("OSError", "file not found");
            return error.PyException;
        };
        defer a.free(file_data);
        const dr = decompress(a, file_data) catch {
            a.free(state.path);
            a.destroy(state);
            try interp.raisePy("OSError", "not a zstd file");
            return error.PyException;
        };
        try state.buf.appendSlice(a, dr.out);
        a.free(dr.out);
    }
    try inst.dict.setStr(a, "_zf", Value{ .small_int = @intCast(@intFromPtr(state)) });
    try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, path_s) });
    try inst.dict.setStr(a, "mode", Value{ .str = try Str.init(a, mode_str) });
    try inst.dict.setStr(a, "closed", Value{ .boolean = false });
    return Value{ .none = {} };
}
fn zfInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return zfInitImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn zfInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return zfInitImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

fn zfEnterFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return Value{ .none = {} };
    return args[0];
}

fn zfExitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .none = {} };
    const state = zfStateFrom(args[0].instance) orelse return Value{ .none = {} };
    if (state.closed) return Value{ .none = {} };
    state.closed = true;
    try args[0].instance.dict.setStr(a, "closed", Value{ .boolean = true });
    if (state.mode_write) {
        const raw = state.buf.items;
        const compressed = compress(a, raw) catch {
            state.deinit();
            a.destroy(state);
            return Value{ .none = {} };
        };
        defer a.free(compressed);
        writeBytesToFile(interp, state.path, compressed) catch {};
    }
    state.deinit();
    a.destroy(state);
    return Value{ .none = {} };
}

fn zfWriteFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value{ .small_int = 0 };
    const state = zfStateFrom(args[0].instance) orelse return Value{ .small_int = 0 };
    const data: []const u8 = switch (args[1]) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        else => &.{},
    };
    try state.buf.appendSlice(a, data);
    return Value{ .small_int = @intCast(data.len) };
}

fn zfReadFnImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    _ = kw_names;
    _ = kw_vals;
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .bytes = try Bytes.init(a, &.{}) };
    const state = zfStateFrom(args[0].instance) orelse return Value{ .bytes = try Bytes.init(a, &.{}) };
    var n: i64 = -1;
    if (args.len >= 2 and args[1] == .small_int) n = args[1].small_int;
    const avail = if (state.pos <= state.buf.items.len) state.buf.items[state.pos..] else &.{};
    const to_read: usize = if (n < 0) avail.len else @min(@as(usize, @intCast(n)), avail.len);
    const result = avail[0..to_read];
    const out = try Bytes.init(a, result);
    state.pos += to_read;
    if (state.text_mode) {
        return Value{ .str = try Str.init(a, result) };
    }
    return Value{ .bytes = out };
}
fn zfReadFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return zfReadFnImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn zfReadKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return zfReadFnImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

fn zfReadlineFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .bytes = try Bytes.init(a, &.{}) };
    const state = zfStateFrom(args[0].instance) orelse return Value{ .bytes = try Bytes.init(a, &.{}) };
    const avail = if (state.pos <= state.buf.items.len) state.buf.items[state.pos..] else &.{};
    if (avail.len == 0) return Value{ .bytes = try Bytes.init(a, &.{}) };
    const nl = std.mem.indexOfScalar(u8, avail, '\n');
    const end = if (nl) |n| n + 1 else avail.len;
    const line = avail[0..end];
    state.pos += end;
    return Value{ .bytes = try Bytes.init(a, line) };
}

fn zfTellFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value{ .small_int = 0 };
    const state = zfStateFrom(args[0].instance) orelse return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(state.pos) };
}

fn zfSeekFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = interp;
    if (args.len < 2 or args[0] != .instance) return Value{ .small_int = 0 };
    const state = zfStateFrom(args[0].instance) orelse return Value{ .small_int = 0 };
    const offset: i64 = switch (args[1]) { .small_int => |n| n, else => 0 };
    var whence: i64 = 0;
    if (args.len >= 3 and args[2] == .small_int) whence = args[2].small_int;
    const size: i64 = @intCast(state.buf.items.len);
    const new_pos: i64 = switch (whence) {
        0 => offset,
        1 => @as(i64, @intCast(state.pos)) + offset,
        2 => size + offset,
        else => @as(i64, @intCast(state.pos)),
    };
    state.pos = @intCast(@max(0, @min(new_pos, size)));
    return Value{ .small_int = @intCast(state.pos) };
}

fn zfPeekFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .bytes = try Bytes.init(a, &.{}) };
    const state = zfStateFrom(args[0].instance) orelse return Value{ .bytes = try Bytes.init(a, &.{}) };
    var n: usize = 1;
    if (args.len >= 2 and args[1] == .small_int) n = @intCast(args[1].small_int);
    const avail = if (state.pos <= state.buf.items.len) state.buf.items[state.pos..] else &.{};
    const to_peek = @min(n, avail.len);
    return Value{ .bytes = try Bytes.init(a, avail[0..to_peek]) };
}

fn zfReadableFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value{ .boolean = false };
    const state = zfStateFrom(args[0].instance) orelse return Value{ .boolean = false };
    return Value{ .boolean = !state.mode_write };
}

fn zfWritableFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value{ .boolean = false };
    const state = zfStateFrom(args[0].instance) orelse return Value{ .boolean = false };
    return Value{ .boolean = state.mode_write };
}

// ===== module-level open =====

fn openFnImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    if (args.len < 1) {
        try interp.raisePy("TypeError", "open requires filename");
        return error.PyException;
    }
    const a = interp.allocator;
    const zf_cls = interp.zstd_file_class orelse {
        try interp.raisePy("TypeError", "ZstdFile class not built");
        return error.PyException;
    };
    const inst = try Instance.init(a, zf_cls);
    // Pass self + args to zfInitImpl
    var init_args = try a.alloc(Value, args.len + 1);
    defer a.free(init_args);
    init_args[0] = Value{ .instance = inst };
    @memcpy(init_args[1..], args);
    _ = try zfInitImpl(interp, init_args, kw_names, kw_vals);
    return Value{ .instance = inst };
}
fn openFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return openFnImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn openKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return openFnImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

// ===== registration helpers =====

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

fn buildZstdErrorClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    interp.zstd_error_class = try Class.init(a, "ZstdError", &.{}, d);
}

fn buildZstdCompressorClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "__init__", coInitFn);
    try methodRegKw(a, d, "compress", coCompressFn, coCompressKw);
    try methodReg(a, d, "flush", coFlushFn);
    interp.zstd_compressor_class = try Class.init(a, "ZstdCompressor", &.{}, d);
}

fn buildZstdDecompressorClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "__init__", doInitFn);
    try methodRegKw(a, d, "decompress", doDecompressFn, doDecompressKw);
    interp.zstd_decompressor_class = try Class.init(a, "ZstdDecompressor", &.{}, d);
}

fn buildZstdDictClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodRegKw(a, d, "__init__", zdInitFn, zdInitKw);
    interp.zstd_dict_class = try Class.init(a, "ZstdDict", &.{}, d);
}

fn buildZstdFileClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodRegKw(a, d, "__init__", zfInitFn, zfInitKw);
    try methodReg(a, d, "__enter__", zfEnterFn);
    try methodReg(a, d, "__exit__", zfExitFn);
    try methodReg(a, d, "write", zfWriteFn);
    try methodRegKw(a, d, "read", zfReadFn, zfReadKw);
    try methodReg(a, d, "readline", zfReadlineFn);
    try methodReg(a, d, "tell", zfTellFn);
    try methodReg(a, d, "seek", zfSeekFn);
    try methodReg(a, d, "peek", zfPeekFn);
    try methodReg(a, d, "readable", zfReadableFn);
    try methodReg(a, d, "writable", zfWritableFn);
    interp.zstd_file_class = try Class.init(a, "ZstdFile", &.{}, d);
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "zstd");

    if (interp.zstd_error_class == null) try buildZstdErrorClass(interp);
    if (interp.zstd_compressor_class == null) try buildZstdCompressorClass(interp);
    if (interp.zstd_decompressor_class == null) try buildZstdDecompressorClass(interp);
    if (interp.zstd_dict_class == null) try buildZstdDictClass(interp);
    if (interp.zstd_file_class == null) try buildZstdFileClass(interp);

    try regKw(a, m, "compress", compressFn, compressKw);
    try regKw(a, m, "decompress", decompressFn, decompressKw);
    try m.attrs.setStr(a, "ZstdCompressor", Value{ .class = interp.zstd_compressor_class.? });
    try m.attrs.setStr(a, "ZstdDecompressor", Value{ .class = interp.zstd_decompressor_class.? });
    try m.attrs.setStr(a, "ZstdDict", Value{ .class = interp.zstd_dict_class.? });
    try m.attrs.setStr(a, "ZstdFile", Value{ .class = interp.zstd_file_class.? });
    try m.attrs.setStr(a, "ZstdError", Value{ .class = interp.zstd_error_class.? });
    try regKw(a, m, "open", openFn, openKw);
    try m.attrs.setStr(a, "COMPRESSION_LEVEL_DEFAULT", Value{ .small_int = 3 });
    try m.attrs.setStr(a, "zstd_version", Value{ .str = try Str.init(a, "1.5.7") });
    const vt = try Tuple.init(a, 3);
    vt.items[0] = Value{ .small_int = 1 };
    vt.items[1] = Value{ .small_int = 5 };
    vt.items[2] = Value{ .small_int = 7 };
    try m.attrs.setStr(a, "zstd_version_info", Value{ .tuple = vt });

    // Attach constants to ZstdCompressor class
    const co_cls = interp.zstd_compressor_class.?;
    try co_cls.dict.setStr(a, "CONTINUE", Value{ .small_int = 0 });
    try co_cls.dict.setStr(a, "FLUSH_BLOCK", Value{ .small_int = 1 });
    try co_cls.dict.setStr(a, "FLUSH_FRAME", Value{ .small_int = 2 });

    return m;
}

// ===== compression.zstd package builder =====
pub fn buildCompressionPackage(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "compression");
    const zstd_m = try build(interp);
    try m.attrs.setStr(a, "zstd", Value{ .module = zstd_m });
    return m;
}
