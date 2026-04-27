//! `tarfile` module — POSIX ustar read/write with gz/bz2/xz compression.

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
const zlib_mod = @import("zlib_mod.zig");
const bz2lib = @import("../lib/bz2.zig");
const lzmalib = @import("../lib/lzma.zig");

const TAR_BLOCK: usize = 512;
pub const REGTYPE: u8 = '0';
pub const DIRTYPE: u8 = '5';

// ===== TAR entry =====

const TarEntry = struct {
    name: []u8,
    size: u64,
    typeflag: u8,
    data: []u8,
    allocator: std.mem.Allocator,

    fn deinit(e: *TarEntry) void {
        e.allocator.free(e.name);
        e.allocator.free(e.data);
    }
};

// ===== State =====

const Compression = enum { none, gz, bz2, xz };

const TarFileState = struct {
    path: []u8,
    mode_write: bool,
    compression: Compression,
    entries: std.ArrayListUnmanaged(TarEntry),
    raw_data: []u8,
    closed: bool,
    allocator: std.mem.Allocator,

    fn deinit(s: *TarFileState) void {
        s.allocator.free(s.path);
        for (s.entries.items) |*e| e.deinit();
        s.entries.deinit(s.allocator);
        if (s.raw_data.len > 0) s.allocator.free(s.raw_data);
    }
};

// Mirror io_mod's Buf layout so we can create BytesIO instances.
const IoModBuf = struct {
    data: std.ArrayList(u8),
    pos: usize = 0,
    closed: bool = false,
};

// ===== File I/O =====

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

// ===== BytesIO helper =====

fn makeBytesIO(interp: *Interp, data: []const u8) !Value {
    const a = interp.allocator;
    const cls = interp.io_bytesio_class orelse return Value{ .none = {} };
    const inst = try Instance.init(a, cls);
    const buf = try a.create(IoModBuf);
    buf.* = .{ .data = .empty };
    try buf.data.appendSlice(interp.allocator, data);
    try inst.dict.setStr(a, "_buf", Value{ .small_int = @intCast(@intFromPtr(buf)) });
    try inst.dict.setStr(a, "closed", Value{ .boolean = false });
    return Value{ .instance = inst };
}

// ===== TAR parser =====

fn parseOctal(s: []const u8) u64 {
    var result: u64 = 0;
    for (s) |c| {
        if (c == 0 or c == ' ') break;
        if (c < '0' or c > '7') break;
        result = result * 8 + (c - '0');
    }
    return result;
}

fn parseTar(a: std.mem.Allocator, data: []const u8) !std.ArrayListUnmanaged(TarEntry) {
    var entries: std.ArrayListUnmanaged(TarEntry) = .empty;
    errdefer {
        for (entries.items) |*e| e.deinit();
        entries.deinit(a);
    }
    var pos: usize = 0;
    var zero_blocks: usize = 0;
    while (pos + TAR_BLOCK <= data.len) {
        const hdr = data[pos .. pos + TAR_BLOCK];
        pos += TAR_BLOCK;
        var all_zero = true;
        for (hdr) |b| {
            if (b != 0) { all_zero = false; break; }
        }
        if (all_zero) {
            zero_blocks += 1;
            if (zero_blocks >= 2) break;
            continue;
        }
        zero_blocks = 0;
        const raw_name = hdr[0..100];
        var name_len: usize = 0;
        while (name_len < 100 and raw_name[name_len] != 0) name_len += 1;
        const prefix_raw = hdr[345..500];
        var prefix_len: usize = 0;
        while (prefix_len < 155 and prefix_raw[prefix_len] != 0) prefix_len += 1;
        var name: []u8 = undefined;
        if (prefix_len > 0) {
            name = try a.alloc(u8, prefix_len + 1 + name_len);
            @memcpy(name[0..prefix_len], prefix_raw[0..prefix_len]);
            name[prefix_len] = '/';
            @memcpy(name[prefix_len + 1 ..], raw_name[0..name_len]);
        } else {
            name = try a.dupe(u8, raw_name[0..name_len]);
        }
        const size = parseOctal(hdr[124..136]);
        const typeflag = hdr[156];
        const data_blocks = (size + TAR_BLOCK - 1) / TAR_BLOCK;
        const data_end = pos + data_blocks * TAR_BLOCK;
        if (data_end > data.len) {
            a.free(name);
            break;
        }
        const entry_data = try a.dupe(u8, data[pos .. pos + size]);
        pos += data_blocks * TAR_BLOCK;
        try entries.append(a, TarEntry{
            .name = name,
            .size = size,
            .typeflag = typeflag,
            .data = entry_data,
            .allocator = a,
        });
    }
    return entries;
}

// ===== TAR builder =====

fn computeChecksum(hdr: []const u8) u32 {
    var sum: u32 = 0;
    for (0..148) |i| sum += hdr[i];
    sum += 8 * 0x20;
    for (156..TAR_BLOCK) |i| sum += hdr[i];
    return sum;
}

fn buildTar(a: std.mem.Allocator, entries: []const TarEntry) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    for (entries) |e| {
        var hdr = [_]u8{0} ** TAR_BLOCK;
        const name_len = @min(e.name.len, 99);
        @memcpy(hdr[0..name_len], e.name[0..name_len]);
        @memcpy(hdr[100..108], "0000644\x00");
        @memcpy(hdr[108..116], "0000000\x00");
        @memcpy(hdr[116..124], "0000000\x00");
        _ = std.fmt.bufPrint(hdr[124..136], "{o:0>11}\x00", .{e.size}) catch {};
        @memcpy(hdr[136..148], "00000000000\x00");
        @memcpy(hdr[148..156], "        ");
        hdr[156] = if (e.typeflag == 0) REGTYPE else e.typeflag;
        @memcpy(hdr[257..263], "ustar\x00");
        @memcpy(hdr[263..265], "00");
        const cksum = computeChecksum(&hdr);
        _ = std.fmt.bufPrint(hdr[148..155], "{o:0>6}\x00", .{cksum}) catch {};
        hdr[155] = ' ';
        try out.appendSlice(a, &hdr);
        try out.appendSlice(a, e.data);
        const pad = (TAR_BLOCK - (e.data.len % TAR_BLOCK)) % TAR_BLOCK;
        if (pad > 0) try out.appendNTimes(a, 0, pad);
    }
    try out.appendNTimes(a, 0, TAR_BLOCK * 2);
    return out.toOwnedSlice(a);
}

// ===== State helpers =====

fn stateFrom(inst: *Instance) ?*TarFileState {
    const v = inst.dict.getStr("_tf") orelse return null;
    if (v.small_int == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn findEntry(state: *TarFileState, name: []const u8) ?*TarEntry {
    for (state.entries.items) |*e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

// ===== Compression =====

fn compressTar(a: std.mem.Allocator, raw: []const u8, comp: Compression) ![]u8 {
    return switch (comp) {
        .none => try a.dupe(u8, raw),
        .gz => try zlib_mod.zlibCompress(a, raw, -1, 31),
        .bz2 => try bz2lib.compress(a, raw, 9),
        .xz => try lzmalib.compress(a, raw),
    };
}

fn decompressTar(a: std.mem.Allocator, raw: []const u8, comp: Compression) ![]u8 {
    return switch (comp) {
        .none => try a.dupe(u8, raw),
        .gz => blk: {
            const r = try zlib_mod.zlibDecompress(a, raw, 31);
            break :blk r.out;
        },
        .bz2 => blk: {
            const r = try bz2lib.decompress(a, raw);
            break :blk r.out;
        },
        .xz => blk: {
            const r = lzmalib.decompress(a, raw) catch {
                const r2 = try lzmalib.decompress(a, if (raw.len > 4) raw[4..] else raw);
                break :blk r2.out;
            };
            break :blk r.out;
        },
    };
}

// ===== Exception helpers =====

fn raiseTarReadError(interp: *Interp, msg: []const u8) !void {
    const a = interp.allocator;
    const cls = interp.tarfile_read_error_class orelse {
        try interp.raisePy("OSError", msg);
        return;
    };
    const inst = try Instance.init(a, cls);
    const t = try Tuple.init(a, 1);
    t.items[0] = Value{ .str = try Str.init(a, msg) };
    try inst.dict.setStr(a, "args", Value{ .tuple = t });
    interp.current_exc = Value{ .instance = inst };
}

// ===== Arg helpers =====

fn argStr(v: Value) ?[]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        else => null,
    };
}

// ===== TarInfo methods =====

fn tiInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value{ .none = {} };
    const inst = args[0].instance;
    const name = argStr(args[1]) orelse "";
    try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, name) });
    try inst.dict.setStr(a, "size", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "type", Value{ .small_int = REGTYPE });
    return Value{ .none = {} };
}

fn tiTypeFlag(inst: *Instance) u8 {
    const t = inst.dict.getStr("type") orelse return REGTYPE;
    return switch (t) {
        .small_int => |n| @intCast(n),
        else => REGTYPE,
    };
}

fn tiIsfileFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value{ .boolean = false };
    const tf = tiTypeFlag(args[0].instance);
    return Value{ .boolean = tf == REGTYPE or tf == 0 };
}

fn tiIsdirFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value{ .boolean = false };
    return Value{ .boolean = tiTypeFlag(args[0].instance) == DIRTYPE };
}

// ===== TarFile open implementation =====

fn tfOpenImpl(interp: *Interp, path_val: Value, mode_str: []const u8) !Value {
    const a = interp.allocator;
    const is_write = std.mem.startsWith(u8, mode_str, "w");
    const compression: Compression = blk: {
        if (std.mem.endsWith(u8, mode_str, "gz")) break :blk .gz;
        if (std.mem.endsWith(u8, mode_str, "bz2")) break :blk .bz2;
        if (std.mem.endsWith(u8, mode_str, "xz")) break :blk .xz;
        break :blk .none;
    };
    const path_s = argStr(path_val) orelse {
        try interp.raisePy("TypeError", "path must be a string");
        return error.PyException;
    };
    const tf_cls = interp.tarfile_class orelse {
        try interp.raisePy("TypeError", "tarfile class not built");
        return error.PyException;
    };
    const inst = try Instance.init(a, tf_cls);
    const state = try a.create(TarFileState);
    state.* = .{
        .path = try a.dupe(u8, path_s),
        .mode_write = is_write,
        .compression = compression,
        .entries = .empty,
        .raw_data = &.{},
        .closed = false,
        .allocator = a,
    };
    if (!is_write) {
        const file_data = readFileToBytes(interp, path_s) catch {
            a.free(state.path);
            a.destroy(state);
            try raiseTarReadError(interp, "file not found");
            return error.PyException;
        };
        defer a.free(file_data);
        const tar_data = decompressTar(a, file_data, compression) catch {
            a.free(state.path);
            a.destroy(state);
            try raiseTarReadError(interp, "not a tar file");
            return error.PyException;
        };
        if (tar_data.len < TAR_BLOCK) {
            a.free(tar_data);
            a.free(state.path);
            a.destroy(state);
            try raiseTarReadError(interp, "not a tar file");
            return error.PyException;
        }
        state.raw_data = tar_data;
        state.entries = parseTar(a, tar_data) catch .empty;
    }
    try inst.dict.setStr(a, "_tf", Value{ .small_int = @intCast(@intFromPtr(state)) });
    return Value{ .instance = inst };
}

// ===== tarfile.open =====

fn tfOpenFnImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    if (args.len < 1) {
        try interp.raisePy("TypeError", "open requires name");
        return error.PyException;
    }
    var mode_str: []const u8 = "r";
    if (args.len >= 2) mode_str = argStr(args[1]) orelse "r";
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "mode"))
            mode_str = argStr(v) orelse mode_str;
    }
    // auto-detect
    if (std.mem.eql(u8, mode_str, "r:*") or std.mem.eql(u8, mode_str, "r")) {
        const comps = [_][]const u8{ "r", "r:gz", "r:bz2", "r:xz" };
        for (comps) |m| {
            const r = tfOpenImpl(interp, args[0], m) catch continue;
            interp.current_exc = Value{ .none = {} };
            return r;
        }
        try raiseTarReadError(interp, "not a tar file");
        return error.PyException;
    }
    return tfOpenImpl(interp, args[0], mode_str);
}

fn tfOpenFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return tfOpenFnImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn tfOpenKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return tfOpenFnImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

// ===== TarFile.__init__ =====

fn tfInitImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    if (args.len < 2 or args[0] != .instance) {
        try interp.raisePy("TypeError", "TarFile.__init__ requires path");
        return error.PyException;
    }
    const inst = args[0].instance;
    var mode_str: []const u8 = "r";
    if (args.len >= 3) mode_str = argStr(args[2]) orelse "r";
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "mode"))
            mode_str = argStr(v) orelse mode_str;
    }
    const result = tfOpenImpl(interp, args[1], mode_str) catch |err| return err;
    if (result == .instance) {
        const tf_v = result.instance.dict.getStr("_tf") orelse return Value{ .none = {} };
        try inst.dict.setStr(interp.allocator, "_tf", tf_v);
    }
    return Value{ .none = {} };
}
fn tfInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return tfInitImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn tfInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return tfInitImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

// ===== context manager =====

fn tfEnterFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return Value{ .none = {} };
    return args[0];
}

fn tfExitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .none = {} };
    const state = stateFrom(args[0].instance) orelse return Value{ .none = {} };
    if (state.closed) return Value{ .none = {} };
    state.closed = true;
    if (state.mode_write) {
        const tar_bytes = buildTar(a, state.entries.items) catch {
            state.deinit();
            a.destroy(state);
            return Value{ .none = {} };
        };
        defer a.free(tar_bytes);
        const final = compressTar(a, tar_bytes, state.compression) catch tar_bytes;
        defer if (final.ptr != tar_bytes.ptr) a.free(final);
        writeBytesToFile(interp, state.path, final) catch {};
    }
    state.deinit();
    a.destroy(state);
    return Value{ .none = {} };
}

// ===== addfile =====

fn tfAddfileFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .instance) {
        try interp.raisePy("TypeError", "addfile(tarinfo[, fileobj])");
        return error.PyException;
    }
    const state = stateFrom(args[0].instance) orelse return Value{ .none = {} };
    const ti = args[1].instance;
    const name_v = ti.dict.getStr("name") orelse return Value{ .none = {} };
    const name = argStr(name_v) orelse "";
    const size_v = ti.dict.getStr("size") orelse Value{ .small_int = 0 };
    const size: usize = switch (size_v) {
        .small_int => |n| @intCast(n),
        .big_int => |bi| @intCast(bi.inner.toConst().toInt(usize) catch 0),
        else => 0,
    };
    const typeflag_v = ti.dict.getStr("type") orelse Value{ .small_int = REGTYPE };
    const typeflag: u8 = switch (typeflag_v) {
        .small_int => |n| @intCast(n),
        else => REGTYPE,
    };
    var data: []u8 = &.{};
    if (args.len >= 3 and args[2] == .instance) {
        const fileobj = args[2].instance;
        const buf_v = fileobj.dict.getStr("_buf") orelse {
            data = try a.dupe(u8, &.{});
            try state.entries.append(a, TarEntry{
                .name = try a.dupe(u8, name),
                .size = size,
                .typeflag = typeflag,
                .data = data,
                .allocator = a,
            });
            return Value{ .none = {} };
        };
        const buf: *IoModBuf = @ptrFromInt(@as(usize, @intCast(buf_v.small_int)));
        const avail = if (buf.pos <= buf.data.items.len) buf.data.items[buf.pos..] else &.{};
        const to_read = @min(size, avail.len);
        data = try a.dupe(u8, avail[0..to_read]);
    }
    try state.entries.append(a, TarEntry{
        .name = try a.dupe(u8, name),
        .size = size,
        .typeflag = typeflag,
        .data = data,
        .allocator = a,
    });
    return Value{ .none = {} };
}

// ===== add (directory walk) =====

fn tfAddImpl(interp: *Interp, state: *TarFileState, real_path: []const u8, arcname: []const u8) !void {
    const a = interp.allocator;
    const stat = std.Io.Dir.cwd().statFile(interp.io, real_path, .{}) catch return;
    if (stat.kind == .directory) {
        try state.entries.append(a, TarEntry{
            .name = try a.dupe(u8, arcname),
            .size = 0,
            .typeflag = DIRTYPE,
            .data = try a.dupe(u8, &.{}),
            .allocator = a,
        });
        var dir = std.Io.Dir.cwd().openDir(interp.io, real_path, .{ .iterate = true }) catch return;
        defer dir.close(interp.io);
        var it = dir.iterate();
        var children: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (children.items) |c| a.free(c);
            children.deinit(a);
        }
        while (try it.next(interp.io)) |entry| {
            try children.append(a, try a.dupe(u8, entry.name));
        }
        std.sort.heap([]u8, children.items, {}, struct {
            fn lt(_: void, x: []u8, y: []u8) bool { return std.mem.lessThan(u8, x, y); }
        }.lt);
        for (children.items) |child| {
            const child_real = try std.fmt.allocPrint(a, "{s}/{s}", .{ real_path, child });
            defer a.free(child_real);
            const child_arc = try std.fmt.allocPrint(a, "{s}/{s}", .{ arcname, child });
            defer a.free(child_arc);
            try tfAddImpl(interp, state, child_real, child_arc);
        }
    } else {
        const data = readFileToBytes(interp, real_path) catch return;
        try state.entries.append(a, TarEntry{
            .name = try a.dupe(u8, arcname),
            .size = @intCast(data.len),
            .typeflag = REGTYPE,
            .data = data,
            .allocator = a,
        });
    }
}

fn tfAddFnImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    if (args.len < 2 or args[0] != .instance) {
        try interp.raisePy("TypeError", "add requires name");
        return error.PyException;
    }
    const state = stateFrom(args[0].instance) orelse return Value{ .none = {} };
    const path_s = argStr(args[1]) orelse {
        try interp.raisePy("TypeError", "name must be a string");
        return error.PyException;
    };
    var arcname: []const u8 = path_s;
    if (args.len >= 3) arcname = argStr(args[2]) orelse path_s;
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "arcname"))
            arcname = argStr(v) orelse arcname;
    }
    try tfAddImpl(interp, state, path_s, arcname);
    return Value{ .none = {} };
}
fn tfAddFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return tfAddFnImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn tfAddKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return tfAddFnImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

// ===== getnames =====

fn tfGetnamesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .none = {} };
    const state = stateFrom(args[0].instance) orelse return Value{ .none = {} };
    const lst = try List.init(a);
    for (state.entries.items) |e| {
        try lst.items.append(a, Value{ .str = try Str.init(a, e.name) });
    }
    return Value{ .list = lst };
}

// ===== makeTarInfo / getmembers / getmember =====

fn makeTarInfo(interp: *Interp, e: *const TarEntry) !Value {
    const a = interp.allocator;
    const ti_cls = interp.tarfile_info_class orelse return Value{ .none = {} };
    const inst = try Instance.init(a, ti_cls);
    try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, e.name) });
    try inst.dict.setStr(a, "size", Value{ .small_int = @intCast(e.size) });
    try inst.dict.setStr(a, "type", Value{ .small_int = e.typeflag });
    return Value{ .instance = inst };
}

fn tfGetmembersFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .none = {} };
    const state = stateFrom(args[0].instance) orelse return Value{ .none = {} };
    const lst = try List.init(a);
    for (state.entries.items) |*e| {
        try lst.items.append(a, try makeTarInfo(interp, e));
    }
    return Value{ .list = lst };
}

fn tfGetmemberFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) {
        try interp.raisePy("KeyError", "getmember requires name");
        return error.PyException;
    }
    const state = stateFrom(args[0].instance) orelse {
        try interp.raisePy("KeyError", "no such member");
        return error.PyException;
    };
    const name = argStr(args[1]) orelse {
        try interp.raisePy("KeyError", "name must be a string");
        return error.PyException;
    };
    const e = findEntry(state, name) orelse {
        try interp.raisePy("KeyError", name);
        return error.PyException;
    };
    return makeTarInfo(interp, e);
}

// ===== extractfile =====

fn tfExtractfileFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return Value{ .none = {} };
    const state = stateFrom(args[0].instance) orelse return Value{ .none = {} };
    const name: []const u8 = switch (args[1]) {
        .str => |s| s.bytes,
        .instance => |inst| blk: {
            const nv = inst.dict.getStr("name") orelse return Value{ .none = {} };
            break :blk argStr(nv) orelse return Value{ .none = {} };
        },
        else => return Value{ .none = {} },
    };
    const e = findEntry(state, name) orelse return Value{ .none = {} };
    return makeBytesIO(interp, e.data);
}

// ===== extractall =====

fn tfExtractallFnImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    if (args.len < 1 or args[0] != .instance) return Value{ .none = {} };
    const state = stateFrom(args[0].instance) orelse return Value{ .none = {} };
    var path_s: []const u8 = ".";
    if (args.len >= 2) path_s = argStr(args[1]) orelse ".";
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "path"))
            path_s = argStr(v) orelse path_s;
    }
    const a = interp.allocator;
    for (state.entries.items) |e| {
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ path_s, e.name });
        defer a.free(full);
        if (e.typeflag == DIRTYPE) {
            std.Io.Dir.cwd().createDir(interp.io, full, .default_dir) catch {};
        } else {
            if (std.fs.path.dirname(full)) |parent| {
                std.Io.Dir.cwd().createDir(interp.io, parent, .default_dir) catch {};
            }
            writeBytesToFile(interp, full, e.data) catch {};
        }
    }
    return Value{ .none = {} };
}
fn tfExtractallFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return tfExtractallFnImpl(@ptrCast(@alignCast(p)), args, &.{}, &.{});
}
fn tfExtractallKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return tfExtractallFnImpl(@ptrCast(@alignCast(p)), args, kn, kv);
}

// ===== __iter__ / __next__ =====

fn tfIterFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return Value{ .none = {} };
    return args[0];
}

fn tfNextFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    }
    const inst = args[0].instance;
    const state = stateFrom(inst) orelse {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    };
    const idx_v = inst.dict.getStr("_iter_idx") orelse Value{ .small_int = 0 };
    const idx: usize = @intCast(idx_v.small_int);
    if (idx >= state.entries.items.len) {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    }
    try inst.dict.setStr(a, "_iter_idx", Value{ .small_int = @intCast(idx + 1) });
    return makeTarInfo(interp, &state.entries.items[idx]);
}

// ===== is_tarfile =====

fn isTarfileFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return Value{ .boolean = false };
    const path_s = argStr(args[0]) orelse return Value{ .boolean = false };
    const data = readFileToBytes(interp, path_s) catch return Value{ .boolean = false };
    defer a.free(data);
    const comps = [_]Compression{ .none, .gz, .bz2, .xz };
    for (comps) |comp| {
        const decompressed = decompressTar(a, data, comp) catch continue;
        defer a.free(decompressed);
        if (decompressed.len >= TAR_BLOCK) return Value{ .boolean = true };
    }
    return Value{ .boolean = false };
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

// ===== Class builders =====

fn buildTarInfoClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "__init__", tiInitFn);
    try methodReg(a, d, "isfile", tiIsfileFn);
    try methodReg(a, d, "isreg", tiIsfileFn);
    try methodReg(a, d, "isdir", tiIsdirFn);
    interp.tarfile_info_class = try Class.init(a, "TarInfo", &.{}, d);
}

fn buildTarErrorClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    interp.tarfile_error_class = try Class.init(a, "TarError", &.{}, d);
}

fn buildReadErrorClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    const bases_buf = if (interp.tarfile_error_class) |c| blk: {
        const b = try a.alloc(*Class, 1);
        b[0] = c;
        break :blk b;
    } else try a.alloc(*Class, 0);
    defer a.free(bases_buf);
    interp.tarfile_read_error_class = try Class.init(a, "ReadError", bases_buf, d);
}

fn buildTarFileClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodRegKw(a, d, "__init__", tfInitFn, tfInitKw);
    try methodReg(a, d, "__enter__", tfEnterFn);
    try methodReg(a, d, "__exit__", tfExitFn);
    try methodReg(a, d, "addfile", tfAddfileFn);
    try methodRegKw(a, d, "add", tfAddFn, tfAddKw);
    try methodReg(a, d, "getnames", tfGetnamesFn);
    try methodReg(a, d, "getmembers", tfGetmembersFn);
    try methodReg(a, d, "getmember", tfGetmemberFn);
    try methodReg(a, d, "extractfile", tfExtractfileFn);
    try methodRegKw(a, d, "extractall", tfExtractallFn, tfExtractallKw);
    try methodReg(a, d, "__iter__", tfIterFn);
    try methodReg(a, d, "__next__", tfNextFn);
    interp.tarfile_class = try Class.init(a, "TarFile", &.{}, d);
}

// ===== Module build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "tarfile");

    if (interp.tarfile_info_class == null) try buildTarInfoClass(interp);
    if (interp.tarfile_error_class == null) try buildTarErrorClass(interp);
    if (interp.tarfile_read_error_class == null) try buildReadErrorClass(interp);
    if (interp.tarfile_class == null) try buildTarFileClass(interp);

    try m.attrs.setStr(a, "TarFile", Value{ .class = interp.tarfile_class.? });
    try m.attrs.setStr(a, "TarInfo", Value{ .class = interp.tarfile_info_class.? });
    try m.attrs.setStr(a, "TarError", Value{ .class = interp.tarfile_error_class.? });
    try m.attrs.setStr(a, "ReadError", Value{ .class = interp.tarfile_read_error_class.? });
    try regKw(a, m, "open", tfOpenFn, tfOpenKw);
    try reg(a, m, "is_tarfile", isTarfileFn);
    try m.attrs.setStr(a, "REGTYPE", Value{ .small_int = REGTYPE });
    try m.attrs.setStr(a, "DIRTYPE", Value{ .small_int = DIRTYPE });

    return m;
}
