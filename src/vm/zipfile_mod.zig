//! `zipfile` module. Implements ZIP read/write with STORED and DEFLATED
//! compression. Supports BytesIO and file-path as the file argument.

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
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Interp = @import("interp.zig").Interp;
const zlib_mod = @import("zlib_mod.zig");

const ZIP_STORED: u16 = 0;
const ZIP_DEFLATED: u16 = 8;
const ZIP_BZIP2: u16 = 12;
const ZIP_LZMA: u16 = 14;

const bz2lib = @import("../lib/bz2.zig");
const lzmalib = @import("../lib/lzma.zig");

// ===== State structs =====

const ZipEntry = struct {
    name: []u8,
    data: []u8, // uncompressed data (owned)
    compressed: []u8, // compressed data (owned; == data slice if stored)
    compression: u16,
    crc32: u32,
    local_offset: u64,
    allocator: std.mem.Allocator,
    compressed_owned: bool, // true if compressed is a separate alloc from data

    fn deinit(e: *ZipEntry) void {
        e.allocator.free(e.name);
        if (e.compressed_owned) {
            e.allocator.free(e.compressed);
        }
        e.allocator.free(e.data);
    }
};

// The io_mod Buf struct mirrors this (must stay in sync with io_mod.zig).
const IoBuf = struct {
    data: std.ArrayList(u8),
    pos: usize,
    closed: bool,
};

const ZipFileState = struct {
    mode_write: bool,
    mode_append: bool,
    compression: u16,
    entries: std.ArrayListUnmanaged(ZipEntry),
    path: []u8,
    zip_buf: std.ArrayListUnmanaged(u8),
    read_buf: []u8, // owned slice of the full ZIP bytes for read mode
    closed: bool,
    allocator: std.mem.Allocator,
    file_is_instance: bool,
    bytesio_ptr: usize, // IoBuf* as integer if file_is_instance

    fn deinit(s: *ZipFileState) void {
        for (s.entries.items) |*e| e.deinit();
        s.entries.deinit(s.allocator);
        s.zip_buf.deinit(s.allocator);
        if (s.read_buf.len > 0) s.allocator.free(s.read_buf);
        s.allocator.free(s.path);
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

fn argStr(v: Value) ?[]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        else => null,
    };
}

fn argBytes(v: Value) ![]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

fn writeU16LE(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: u16) !void {
    const b = [2]u8{ @truncate(v), @truncate(v >> 8) };
    try buf.appendSlice(a, &b);
}

fn writeU32LE(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: u32) !void {
    const b = [4]u8{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16), @truncate(v >> 24) };
    try buf.appendSlice(a, &b);
}

fn readU16LE(data: []const u8, off: usize) u16 {
    return @as(u16, data[off]) | (@as(u16, data[off + 1]) << 8);
}

fn readU32LE(data: []const u8, off: usize) u32 {
    return @as(u32, data[off]) |
        (@as(u32, data[off + 1]) << 8) |
        (@as(u32, data[off + 2]) << 16) |
        (@as(u32, data[off + 3]) << 24);
}

fn crc32Of(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

// Read all bytes from a BytesIO instance's internal IoBuf from current pos.
fn bytesioReadAll(a: std.mem.Allocator, inst: *Instance) ![]u8 {
    const v = inst.dict.getStr("_buf") orelse return error.AttributeError;
    const buf: *IoBuf = @ptrFromInt(@as(usize, @intCast(v.small_int)));
    const remaining = if (buf.pos <= buf.data.items.len) buf.data.items[buf.pos..] else &.{};
    const out = try a.dupe(u8, remaining);
    buf.pos = buf.data.items.len;
    return out;
}

// Write bytes into a BytesIO instance's IoBuf at current pos.
fn bytesioWriteAll(a: std.mem.Allocator, inst: *Instance, data: []const u8) !void {
    const v = inst.dict.getStr("_buf") orelse return error.AttributeError;
    const buf: *IoBuf = @ptrFromInt(@as(usize, @intCast(v.small_int)));
    // Append at pos (overwrite or extend).
    if (buf.pos == buf.data.items.len) {
        try buf.data.appendSlice(a, data);
    } else {
        const need = buf.pos + data.len;
        if (need > buf.data.items.len) try buf.data.resize(a, need);
        @memcpy(buf.data.items[buf.pos .. buf.pos + data.len], data);
    }
    buf.pos += data.len;
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

// ===== ZIP builder =====

fn buildZipBytes(a: std.mem.Allocator, entries: []const ZipEntry) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);

    // Local file headers + data
    var offsets = try a.alloc(u32, entries.len);
    defer a.free(offsets);

    for (entries, 0..) |e, i| {
        offsets[i] = @intCast(out.items.len);
        // Local file header signature
        try out.appendSlice(a, "\x50\x4b\x03\x04");
        try writeU16LE(&out, a, 20); // version needed
        try writeU16LE(&out, a, 0); // general purpose bit flag
        try writeU16LE(&out, a, e.compression);
        try writeU16LE(&out, a, 0); // mod time
        try writeU16LE(&out, a, 0); // mod date
        try writeU32LE(&out, a, e.crc32);
        try writeU32LE(&out, a, @intCast(e.compressed.len));
        try writeU32LE(&out, a, @intCast(e.data.len));
        try writeU16LE(&out, a, @intCast(e.name.len));
        try writeU16LE(&out, a, 0); // extra field length
        try out.appendSlice(a, e.name);
        try out.appendSlice(a, e.compressed);
    }

    const cd_offset: u32 = @intCast(out.items.len);

    // Central directory
    for (entries, 0..) |e, i| {
        try out.appendSlice(a, "\x50\x4b\x01\x02");
        try writeU16LE(&out, a, 20); // version made by
        try writeU16LE(&out, a, 20); // version needed
        try writeU16LE(&out, a, 0); // bit flag
        try writeU16LE(&out, a, e.compression);
        try writeU16LE(&out, a, 0); // mod time
        try writeU16LE(&out, a, 0); // mod date
        try writeU32LE(&out, a, e.crc32);
        try writeU32LE(&out, a, @intCast(e.compressed.len));
        try writeU32LE(&out, a, @intCast(e.data.len));
        try writeU16LE(&out, a, @intCast(e.name.len));
        try writeU16LE(&out, a, 0); // extra field length
        try writeU16LE(&out, a, 0); // comment length
        try writeU16LE(&out, a, 0); // disk number start
        try writeU16LE(&out, a, 0); // internal attrs
        try writeU32LE(&out, a, 0); // external attrs
        try writeU32LE(&out, a, offsets[i]);
        try out.appendSlice(a, e.name);
    }

    const cd_size: u32 = @intCast(out.items.len - cd_offset);
    const n_entries: u16 = @intCast(entries.len);

    // End of central directory
    try out.appendSlice(a, "\x50\x4b\x05\x06");
    try writeU16LE(&out, a, 0); // disk number
    try writeU16LE(&out, a, 0); // start disk
    try writeU16LE(&out, a, n_entries);
    try writeU16LE(&out, a, n_entries);
    try writeU32LE(&out, a, cd_size);
    try writeU32LE(&out, a, cd_offset);
    try writeU16LE(&out, a, 0); // comment length

    return out.toOwnedSlice(a);
}

// ===== ZIP parser =====

fn hasValidZipEOCD(data: []const u8) bool {
    if (data.len < 22) return false;
    const max_search: usize = @min(data.len, 65535 + 22);
    const search_start = data.len - max_search;
    var i: usize = data.len - 22;
    while (true) {
        if (data[i] == 0x50 and i + 3 < data.len and
            data[i + 1] == 0x4b and
            data[i + 2] == 0x05 and
            data[i + 3] == 0x06) return true;
        if (i == search_start) break;
        i -= 1;
    }
    return false;
}

fn parseZip(a: std.mem.Allocator, data: []const u8) !std.ArrayListUnmanaged(ZipEntry) {
    var entries: std.ArrayListUnmanaged(ZipEntry) = .empty;
    errdefer {
        for (entries.items) |*e| e.deinit();
        entries.deinit(a);
    }

    if (data.len < 22) return entries; // too small for EOCD

    // Find EOCD signature near end of file
    // EOCD is at least 22 bytes; comment up to 65535 bytes.
    const max_search: usize = @min(data.len, 65535 + 22);
    const search_start = data.len - max_search;
    var eocd_off: ?usize = null;
    var i: usize = data.len - 22;
    while (true) {
        if (data[i] == 0x50 and i + 3 < data.len and
            data[i + 1] == 0x4b and
            data[i + 2] == 0x05 and
            data[i + 3] == 0x06)
        {
            eocd_off = i;
            break;
        }
        if (i == search_start) break;
        i -= 1;
    }

    const eocd = eocd_off orelse return entries;

    const cd_count = readU16LE(data, eocd + 10);
    const cd_size_bytes = readU32LE(data, eocd + 12);
    _ = cd_size_bytes;
    const cd_off = readU32LE(data, eocd + 16);

    var pos: usize = cd_off;
    var j: usize = 0;
    while (j < cd_count) : (j += 1) {
        if (pos + 46 > data.len) break;
        if (data[pos] != 0x50 or data[pos + 1] != 0x4b or
            data[pos + 2] != 0x01 or data[pos + 3] != 0x02) break;

        const compression = readU16LE(data, pos + 10);
        const crc = readU32LE(data, pos + 16);
        const comp_size = readU32LE(data, pos + 20);
        const uncomp_size = readU32LE(data, pos + 24);
        const fname_len = readU16LE(data, pos + 28);
        const extra_len = readU16LE(data, pos + 30);
        const comment_len = readU16LE(data, pos + 32);
        const local_off = readU32LE(data, pos + 42);

        if (pos + 46 + fname_len > data.len) break;
        const fname = data[pos + 46 .. pos + 46 + fname_len];

        pos += 46 + fname_len + extra_len + comment_len;

        // Read local header to find data offset
        if (local_off + 30 > data.len) continue;
        if (data[local_off] != 0x50 or data[local_off + 1] != 0x4b or
            data[local_off + 2] != 0x03 or data[local_off + 3] != 0x04) continue;

        const local_fname_len = readU16LE(data, local_off + 26);
        const local_extra_len = readU16LE(data, local_off + 28);
        const data_off = local_off + 30 + local_fname_len + local_extra_len;

        if (data_off + comp_size > data.len) continue;
        const comp_data = data[data_off .. data_off + comp_size];

        // Decompress if needed
        const uncomp_data: []u8 = switch (compression) {
            ZIP_DEFLATED => blk: {
                const result = zlib_mod.zlibDecompress(a, comp_data, -15) catch continue;
                break :blk result.out;
            },
            ZIP_BZIP2 => blk: {
                const r = bz2lib.decompress(a, comp_data) catch continue;
                break :blk r.out;
            },
            ZIP_LZMA => blk: {
                // Lzma-in-zip has a 4-byte version+flags header before the lzma data
                const lzma_raw = if (comp_data.len > 4) comp_data[4..] else comp_data;
                const r = lzmalib.decompress(a, lzma_raw) catch {
                    const r2 = lzmalib.decompress(a, comp_data) catch continue;
                    break :blk r2.out;
                };
                break :blk r.out;
            },
            else => try a.dupe(u8, comp_data),
        };

        const owned_comp: []u8 = try a.dupe(u8, comp_data);

        const e = ZipEntry{
            .name = try a.dupe(u8, fname),
            .data = uncomp_data,
            .compressed = owned_comp,
            .compression = compression,
            .crc32 = crc,
            .local_offset = local_off,
            .allocator = a,
            .compressed_owned = true,
        };
        _ = uncomp_size;
        try entries.append(a, e);
    }

    return entries;
}

// ===== ZipFile state helpers =====

fn zfStateFrom(inst: *Instance) *ZipFileState {
    const v = inst.dict.getStr("_zf").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn findEntry(state: *ZipFileState, name: []const u8) ?*ZipEntry {
    for (state.entries.items) |*e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

// ===== ZipExtFile class (returned by open()) =====

fn buildZipExtFileClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "read", extfileReadFn);
    try methodReg(a, d, "close", extfileCloseFn);
    try methodReg(a, d, "__enter__", extfileEnterFn);
    try methodReg(a, d, "__exit__", extfileExitFn);
    interp.zipfile_extfile_class = try Class.init(a, "ZipExtFile", &.{}, d);
}

fn extfileReadFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const data_v = inst.dict.getStr("_data") orelse return Value{ .bytes = try Bytes.init(a, &.{}) };
    return data_v;
}

fn extfileCloseFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .none = {} };
}

fn extfileEnterFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    return args[0];
}

fn extfileExitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return extfileCloseFn(p, args);
}

// ===== ZipInfo class builder =====

fn ziIsDirFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return Value{ .boolean = false };
    const inst = args[0].instance;
    const filename_v = inst.dict.getStr("filename") orelse return Value{ .boolean = false };
    if (filename_v != .str) return Value{ .boolean = false };
    const name = filename_v.str.bytes;
    return Value{ .boolean = std.mem.endsWith(u8, name, "/") };
}

fn ziInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value{ .none = {} };
    const inst = args[0].instance;
    const filename: []const u8 = argBytes(args[1]) catch "";
    try inst.dict.setStr(a, "filename", Value{ .str = try Str.init(a, filename) });
    try inst.dict.setStr(a, "file_size", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "compress_size", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "compress_type", Value{ .small_int = ZIP_STORED });
    return Value{ .none = {} };
}

fn buildZipInfoClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "__init__", ziInitFn);
    try methodReg(a, d, "is_dir", ziIsDirFn);
    interp.zipfile_info_class = try Class.init(a, "ZipInfo", &.{}, d);
}

// Make a ZipInfo instance for an entry
fn makeZipInfo(interp: *Interp, e: *const ZipEntry) !Value {
    if (interp.zipfile_info_class == null) try buildZipInfoClass(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.zipfile_info_class.?);
    try inst.dict.setStr(a, "filename", Value{ .str = try Str.init(a, e.name) });
    try inst.dict.setStr(a, "file_size", Value{ .small_int = @intCast(e.data.len) });
    try inst.dict.setStr(a, "compress_size", Value{ .small_int = @intCast(e.compressed.len) });
    try inst.dict.setStr(a, "compress_type", Value{ .small_int = @intCast(e.compression) });
    return Value{ .instance = inst };
}

// ===== ZipFile class builder =====

fn raiseBadZip(interp: *Interp, msg: []const u8) !void {
    const a = interp.allocator;
    const cls = interp.zipfile_badzip_class orelse {
        try interp.raisePy("OSError", msg);
        return;
    };
    const inst = try Instance.init(a, cls);
    const t = try Tuple.init(a, 1);
    t.items[0] = Value{ .str = try Str.init(a, msg) };
    try inst.dict.setStr(a, "args", Value{ .tuple = t });
    interp.current_exc = Value{ .instance = inst };
}

fn buildBadZipClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    interp.zipfile_badzip_class = try Class.init(a, "BadZipFile", &.{}, d);
}

fn buildZipFileClass(interp: *Interp) !void {
    if (interp.zipfile_badzip_class == null) try buildBadZipClass(interp);
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodRegKw(a, d, "__init__", zfInitFn, zfInitKw);
    try methodRegKw(a, d, "writestr", zfWritestrFn, zfWritestrKw);
    try methodReg(a, d, "read", zfReadFn);
    try methodReg(a, d, "namelist", zfNamelistFn);
    try methodReg(a, d, "infolist", zfInfolistFn);
    try methodReg(a, d, "getinfo", zfGetinfoFn);
    try methodReg(a, d, "open", zfOpenFn);
    try methodReg(a, d, "close", zfCloseFn);
    try methodReg(a, d, "__enter__", zfEnterFn);
    try methodReg(a, d, "__exit__", zfExitFn);
    try methodReg(a, d, "testzip", zfTestzipFn);
    try methodReg(a, d, "extractall", zfExtractallFn);
    try methodRegKw(a, d, "extract", zfExtractFn, zfExtractKw);
    interp.zipfile_class = try Class.init(a, "ZipFile", &.{}, d);
}

// ===== __init__ =====

fn zfInitImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) anyerror!Value {
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) {
        try interp.raisePy("TypeError", "ZipFile requires file argument");
        return error.PyException;
    }
    const inst = args[0].instance;
    const file_arg = args[1];

    var mode_str: []const u8 = "r";
    var compression: u16 = ZIP_STORED;

    if (args.len >= 3) {
        if (argStr(args[2])) |s| mode_str = s;
    }
    if (args.len >= 4 and args[3] == .small_int) {
        compression = @intCast(@as(u64, @bitCast(args[3].small_int)) & 0xffff);
    }
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str) {
            const k = kn.str.bytes;
            if (std.mem.eql(u8, k, "mode")) {
                if (argStr(v)) |s| mode_str = s;
            } else if (std.mem.eql(u8, k, "compression") and v == .small_int) {
                compression = @intCast(@as(u64, @bitCast(v.small_int)) & 0xffff);
            }
        }
    }

    const is_write = std.mem.eql(u8, mode_str, "w");
    const is_append = std.mem.eql(u8, mode_str, "a");
    const is_read = !is_write and !is_append;

    const file_is_instance = (file_arg == .instance);

    const state = try a.create(ZipFileState);
    state.* = .{
        .mode_write = is_write or is_append,
        .mode_append = is_append,
        .compression = compression,
        .entries = .empty,
        .path = try a.dupe(u8, ""),
        .zip_buf = .empty,
        .read_buf = &.{},
        .closed = false,
        .allocator = a,
        .file_is_instance = file_is_instance,
        .bytesio_ptr = 0,
    };

    if (file_is_instance) {
        // Store the IoBuf pointer for later BytesIO writes.
        const buf_v = file_arg.instance.dict.getStr("_buf") orelse {
            state.deinit();
            a.destroy(state);
            try interp.raisePy("TypeError", "file argument must be a file-like object or string");
            return error.PyException;
        };
        state.bytesio_ptr = @as(usize, @intCast(buf_v.small_int));
    } else {
        // String path
        const path_s = argStr(file_arg) orelse {
            state.deinit();
            a.destroy(state);
            try interp.raisePy("TypeError", "file must be a string path or BytesIO");
            return error.PyException;
        };
        a.free(state.path);
        state.path = try a.dupe(u8, path_s);
    }

    // For read mode: load data
    if (is_read or is_append) {
        const zip_data: []u8 = blk: {
            if (file_is_instance) {
                const buf: *IoBuf = @ptrFromInt(state.bytesio_ptr);
                const remaining = if (buf.pos <= buf.data.items.len) buf.data.items[buf.pos..] else &.{};
                break :blk try a.dupe(u8, remaining);
            } else {
                break :blk readFileToBytes(interp, state.path) catch |err| switch (err) {
                    error.FileNotFound => if (is_append) {
                        // File doesn't exist yet — start fresh for append mode
                        break :blk try a.dupe(u8, &.{});
                    } else {
                        state.deinit();
                        a.destroy(state);
                        try raiseBadZip(interp, "File is not a zip file");
                        return error.PyException;
                    },
                    else => {
                        state.deinit();
                        a.destroy(state);
                        try raiseBadZip(interp, "File is not a zip file");
                        return error.PyException;
                    },
                };
            }
        };

        if (zip_data.len > 0) {
            if (is_read and !hasValidZipEOCD(zip_data)) {
                a.free(zip_data);
                state.deinit();
                a.destroy(state);
                try raiseBadZip(interp, "File is not a zip file");
                return error.PyException;
            }
            state.read_buf = zip_data;
            state.entries = parseZip(a, zip_data) catch .empty;
        } else {
            a.free(zip_data);
        }
    }

    try inst.dict.setStr(a, "_zf", Value{ .small_int = @intCast(@intFromPtr(state)) });
    return Value{ .none = {} };
}

fn zfInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return zfInitImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn zfInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return zfInitImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

// ===== writestr =====

fn zfWritestrImpl(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_vals: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3 or args[0] != .instance) {
        try interp.raisePy("TypeError", "writestr requires name and data");
        return error.PyException;
    }
    const state = zfStateFrom(args[0].instance);
    if (state.closed) {
        try interp.raisePy("ValueError", "write to closed ZipFile");
        return error.PyException;
    }
    // args[1] can be a str/bytes name or a ZipInfo instance
    var name_bytes: []const u8 = "";
    if (args[1] == .instance) {
        const info_inst = args[1].instance;
        const fname_v = info_inst.dict.getStr("filename") orelse {
            try interp.raisePy("TypeError", "ZipInfo missing filename");
            return error.PyException;
        };
        name_bytes = argBytes(fname_v) catch "";
    } else {
        name_bytes = argBytes(args[1]) catch {
            try interp.raisePy("TypeError", "name must be str, bytes, or ZipInfo");
            return error.PyException;
        };
    }
    const raw_data = argBytes(args[2]) catch {
        try interp.raisePy("TypeError", "data must be bytes-like or str");
        return error.PyException;
    };

    var compression: u16 = state.compression;
    for (kw_names, kw_vals) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "compress_type")) {
            if (kv == .small_int) compression = @intCast(kv.small_int);
        }
    }

    const crc = crc32Of(raw_data);
    const owned_data = try a.dupe(u8, raw_data);

    var compressed: []u8 = undefined;
    var compressed_owned: bool = undefined;

    switch (compression) {
        ZIP_DEFLATED => {
            const comp = zlib_mod.zlibCompress(a, raw_data, -1, -15) catch {
                a.free(owned_data);
                try interp.raisePy("OSError", "deflate compress failed");
                return error.PyException;
            };
            compressed = comp;
            compressed_owned = true;
        },
        ZIP_BZIP2 => {
            const comp = bz2lib.compress(a, raw_data, 9) catch {
                a.free(owned_data);
                try interp.raisePy("OSError", "bzip2 compress failed");
                return error.PyException;
            };
            compressed = comp;
            compressed_owned = true;
        },
        ZIP_LZMA => {
            const comp = lzmalib.compress(a, raw_data) catch {
                a.free(owned_data);
                try interp.raisePy("OSError", "lzma compress failed");
                return error.PyException;
            };
            compressed = comp;
            compressed_owned = true;
        },
        else => {
            compressed = owned_data;
            compressed_owned = false;
        },
    }

    const e = ZipEntry{
        .name = try a.dupe(u8, name_bytes),
        .data = owned_data,
        .compressed = compressed,
        .compression = compression,
        .crc32 = crc,
        .local_offset = 0,
        .allocator = a,
        .compressed_owned = compressed_owned,
    };
    try state.entries.append(a, e);
    return Value{ .none = {} };
}
fn zfWritestrFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return zfWritestrImpl(p, args, &.{}, &.{});
}
fn zfWritestrKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return zfWritestrImpl(p, args, kn, kv);
}

// ===== read =====

fn zfReadFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) {
        try interp.raisePy("TypeError", "read requires name");
        return error.PyException;
    }
    const state = zfStateFrom(args[0].instance);
    const name = argBytes(args[1]) catch {
        try interp.raisePy("TypeError", "name must be str or bytes");
        return error.PyException;
    };
    const e = findEntry(state, name) orelse {
        try interp.raisePy("KeyError", "no such file in ZIP");
        return error.PyException;
    };
    return Value{ .bytes = try Bytes.init(a, e.data) };
}

// ===== namelist =====

fn zfNamelistFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const state = zfStateFrom(args[0].instance);
    const out = try List.init(a);
    for (state.entries.items) |*e| {
        try out.append(a, Value{ .str = try Str.init(a, e.name) });
    }
    return Value{ .list = out };
}

// ===== infolist =====

fn zfInfolistFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const state = zfStateFrom(args[0].instance);
    const out = try List.init(a);
    for (state.entries.items) |*e| {
        try out.append(a, try makeZipInfo(interp, e));
    }
    return Value{ .list = out };
}

// ===== getinfo =====

fn zfGetinfoFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) {
        try interp.raisePy("TypeError", "getinfo requires name");
        return error.PyException;
    }
    const state = zfStateFrom(args[0].instance);
    const name = argBytes(args[1]) catch {
        try interp.raisePy("TypeError", "name must be str");
        return error.PyException;
    };
    const e = findEntry(state, name) orelse {
        try interp.raisePy("KeyError", "no such file in ZIP");
        return error.PyException;
    };
    return makeZipInfo(interp, e);
}

// ===== open =====

fn zfOpenFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) {
        try interp.raisePy("TypeError", "open requires name");
        return error.PyException;
    }
    const state = zfStateFrom(args[0].instance);
    const name = argBytes(args[1]) catch {
        try interp.raisePy("TypeError", "name must be str");
        return error.PyException;
    };
    const e = findEntry(state, name) orelse {
        try interp.raisePy("KeyError", "no such file in ZIP");
        return error.PyException;
    };

    if (interp.zipfile_extfile_class == null) try buildZipExtFileClass(interp);

    // Create a ZipExtFile instance wrapping the uncompressed data
    const ext_inst = try Instance.init(a, interp.zipfile_extfile_class.?);
    try ext_inst.dict.setStr(a, "_data", Value{ .bytes = try Bytes.init(a, e.data) });
    return Value{ .instance = ext_inst };
}

// ===== close =====

fn zfCloseFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state = zfStateFrom(inst);
    if (state.closed) return Value{ .none = {} };

    if (state.mode_write) {
        // Build the ZIP bytes
        const zip_bytes = buildZipBytes(a, state.entries.items) catch {
            try interp.raisePy("OSError", "failed to build ZIP");
            return error.PyException;
        };
        defer a.free(zip_bytes);

        if (state.file_is_instance) {
            // Write to BytesIO
            const buf: *IoBuf = @ptrFromInt(state.bytesio_ptr);
            try buf.data.appendSlice(a, zip_bytes);
            buf.pos = buf.data.items.len;
        } else if (state.path.len > 0) {
            writeBytesToFile(interp, state.path, zip_bytes) catch {
                try interp.raisePy("OSError", "cannot write zip file");
                return error.PyException;
            };
        }
    }

    state.closed = true;
    try inst.dict.setStr(a, "closed", Value{ .boolean = true });
    return Value{ .none = {} };
}

// ===== __enter__ / __exit__ =====

fn zfEnterFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    return args[0];
}

fn zfExitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return zfCloseFn(p, args[0..1]);
}

// ===== testzip / extractall / extract =====

fn zfTestzipFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .none = {} };
}

fn writeEntryToDir(interp: *Interp, dir: []const u8, e: *const ZipEntry) !void {
    const a = interp.allocator;
    const full_path = try std.fs.path.join(a, &.{ dir, e.name });
    defer a.free(full_path);
    if (std.mem.endsWith(u8, e.name, "/")) {
        std.Io.Dir.cwd().createDir(interp.io, full_path, .default_dir) catch {};
        return;
    }
    if (std.fs.path.dirname(full_path)) |parent| {
        std.Io.Dir.cwd().createDirPath(interp.io, parent) catch {};
    }
    try writeBytesToFile(interp, full_path, e.data);
}

fn zfExtractallFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return Value{ .none = {} };
    const state = zfStateFrom(args[0].instance);
    const dir: []const u8 = if (args.len >= 2) (argStr(args[1]) orelse ".") else ".";
    for (state.entries.items) |*e| {
        writeEntryToDir(interp, dir, e) catch {};
    }
    return Value{ .none = {} };
}

fn zfExtractImpl(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value{ .none = {} };
    const state = zfStateFrom(args[0].instance);
    const name = argBytes(args[1]) catch return Value{ .none = {} };
    const dir: []const u8 = if (args.len >= 3) (argStr(args[2]) orelse ".") else ".";
    const e = findEntry(state, name) orelse {
        try interp.raisePy("KeyError", "no such file in ZIP");
        return error.PyException;
    };
    writeEntryToDir(interp, dir, e) catch {};
    const full_path = try std.fs.path.join(a, &.{ dir, e.name });
    const result = Value{ .str = try Str.init(a, full_path) };
    a.free(full_path);
    return result;
}
fn zfExtractFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return zfExtractImpl(p, args);
}
fn zfExtractKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return zfExtractImpl(p, args);
}

// ===== is_zipfile =====

fn isZipfileFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return Value{ .boolean = false };

    const data: []const u8 = blk: {
        switch (args[0]) {
            .bytes => |b| break :blk b.data,
            .str => |s| {
                // String argument is a file path — read and check.
                const file_data = readFileToBytes(interp, s.bytes) catch break :blk &.{};
                defer a.free(file_data);
                const result = file_data.len >= 4 and
                    file_data[0] == 0x50 and file_data[1] == 0x4b and
                    (file_data[2] == 0x03 or file_data[2] == 0x05 or file_data[2] == 0x07) and
                    (file_data[3] == 0x04 or file_data[3] == 0x06 or file_data[3] == 0x08);
                return Value{ .boolean = result };
            },
            .instance => |inst| {
                // BytesIO: read from current pos
                const buf_v = inst.dict.getStr("_buf") orelse break :blk &.{};
                const buf: *IoBuf = @ptrFromInt(@as(usize, @intCast(buf_v.small_int)));
                const remaining = if (buf.pos <= buf.data.items.len) buf.data.items[buf.pos..] else &.{};
                break :blk remaining;
            },
            else => {
                // Try as file path
                if (argStr(args[0])) |path| {
                    const file_data = readFileToBytes(interp, path) catch break :blk &.{};
                    defer a.free(file_data);
                    const result = file_data.len >= 4 and
                        file_data[0] == 0x50 and file_data[1] == 0x4b and
                        (file_data[2] == 0x03 or file_data[2] == 0x05 or file_data[2] == 0x07) and
                        (file_data[3] == 0x04 or file_data[3] == 0x06 or file_data[3] == 0x08);
                    return Value{ .boolean = result };
                }
                break :blk &.{};
            },
        }
    };

    const result = data.len >= 4 and
        data[0] == 0x50 and data[1] == 0x4b and
        (data[2] == 0x03 or data[2] == 0x05 or data[2] == 0x07) and
        (data[3] == 0x04 or data[3] == 0x06 or data[3] == 0x08);
    return Value{ .boolean = result };
}

// ===== ZipFile constructor wrapper =====

fn zipFileCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    return zipFileCtorImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}

fn zipFileCtorKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return zipFileCtorImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

fn zipFileCtorImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) anyerror!Value {
    if (interp.zipfile_class == null) try buildZipFileClass(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.zipfile_class.?);
    const self = Value{ .instance = inst };
    // Build args: self + original args
    var init_args = try a.alloc(Value, args.len + 1);
    defer a.free(init_args);
    init_args[0] = self;
    @memcpy(init_args[1..], args);
    _ = try zfInitImpl(interp, init_args, kw_names, kw_vals);
    return self;
}

// ===== Module build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "zipfile");

    if (interp.zipfile_badzip_class == null) try buildBadZipClass(interp);
    if (interp.zipfile_class == null) try buildZipFileClass(interp);
    if (interp.zipfile_info_class == null) try buildZipInfoClass(interp);
    if (interp.zipfile_extfile_class == null) try buildZipExtFileClass(interp);

    try m.attrs.setStr(a, "ZIP_STORED", Value{ .small_int = ZIP_STORED });
    try m.attrs.setStr(a, "ZIP_DEFLATED", Value{ .small_int = ZIP_DEFLATED });
    try m.attrs.setStr(a, "ZIP_BZIP2", Value{ .small_int = ZIP_BZIP2 });
    try m.attrs.setStr(a, "ZIP_LZMA", Value{ .small_int = ZIP_LZMA });
    try m.attrs.setStr(a, "ZipFile", Value{ .class = interp.zipfile_class.? });
    try m.attrs.setStr(a, "ZipInfo", Value{ .class = interp.zipfile_info_class.? });
    try m.attrs.setStr(a, "BadZipFile", Value{ .class = interp.zipfile_badzip_class.? });
    try m.attrs.setStr(a, "BadZipfile", Value{ .class = interp.zipfile_badzip_class.? });
    try regKw(a, m, "is_zipfile", isZipfileFn, isZipfileFn_kw);

    return m;
}

fn isZipfileFn_kw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return isZipfileFn(p, args);
}
