//! `gzip` module. Real gzip compress/decompress using std.compress.flate
//! (wbits=31). GzipFile supports read/write/seek/tell/readline/peek in
//! both binary and text modes.

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
const Interp = @import("interp.zig").Interp;
const zlib_mod = @import("zlib_mod.zig");

const GzipState = struct {
    path: []u8,
    mode_write: bool,
    text_mode: bool,
    buf: std.ArrayList(u8),
    pos: usize,
    level: i64,
    closed: bool,
    allocator: std.mem.Allocator,

    fn deinit(s: *GzipState) void {
        s.allocator.free(s.path);
        s.buf.deinit(s.allocator);
    }
};

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "gzip");

    if (interp.gzip_bad_class == null) try buildBadGzipClass(interp);
    if (interp.gzip_file_class == null) try buildGzipFileClass(interp);

    try m.attrs.setStr(a, "BadGzipFile", Value{ .class = interp.gzip_bad_class.? });

    const read_str = try Str.init(a, "rb");
    const write_str = try Str.init(a, "wb");
    try m.attrs.setStr(a, "READ", Value{ .str = read_str });
    try m.attrs.setStr(a, "WRITE", Value{ .str = write_str });
    try m.attrs.setStr(a, "READ_BUFFER_SIZE", Value{ .small_int = 131072 });
    try m.attrs.setStr(a, "FTEXT", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "FHCRC", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "FEXTRA", Value{ .small_int = 4 });
    try m.attrs.setStr(a, "FNAME", Value{ .small_int = 8 });
    try m.attrs.setStr(a, "FCOMMENT", Value{ .small_int = 16 });

    try regKw(a, m, "compress", gzCompressFn, gzCompressKw);
    try reg(a, m, "decompress", gzDecompressFn);
    try m.attrs.setStr(a, "GzipFile", Value{ .class = interp.gzip_file_class.? });
    try regKw(a, m, "open", gzOpenFn, gzOpenKw);

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

// ===== File helpers =====

fn readFileToBytes(interp: *Interp, path: []const u8) ![]u8 {
    const a = interp.allocator;
    var file = std.Io.Dir.cwd().openFile(interp.io, path, .{}) catch return error.FileNotFound;
    defer file.close(interp.io);
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(a);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(interp.io, &read_buf);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const got = reader.interface.readSliceShort(chunk[0..]) catch break;
        if (got == 0) break;
        try data.appendSlice(a, chunk[0..got]);
    }
    return try data.toOwnedSlice(a);
}

fn writeBytesToFile(interp: *Interp, path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(interp.io, path, .{ .truncate = true });
    defer file.close(interp.io);
    var write_buf: [4096]u8 = undefined;
    var w = file.writer(interp.io, &write_buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

// ===== BadGzipFile exception =====

fn buildBadGzipClass(interp: *Interp) !void {
    const a = interp.allocator;
    const oserr_v = interp.builtins.getStr("OSError") orelse return error.NameError;
    if (oserr_v != .class) return error.TypeError;
    const d = try Dict.init(a);
    interp.gzip_bad_class = try Class.init(a, "BadGzipFile", &.{oserr_v.class}, d);
}

fn raiseBadGzip(interp: *Interp, msg: []const u8) !void {
    const cls = interp.gzip_bad_class orelse {
        try interp.raisePy("OSError", msg);
        return;
    };
    const inst = try Instance.init(interp.allocator, cls);
    const t = try Tuple.init(interp.allocator, 1);
    t.items[0] = Value{ .str = try Str.init(interp.allocator, msg) };
    try inst.dict.setStr(interp.allocator, "args", Value{ .tuple = t });
    interp.current_exc = Value{ .instance = inst };
}

// ===== compress / decompress =====

fn gzCompressImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.raisePy("TypeError", "compress requires data");
        return error.PyException;
    }
    const data = argBytes(args[0]) catch {
        try interp.raisePy("TypeError", "data must be bytes-like");
        return error.PyException;
    };
    var level: i64 = -1;
    if (args.len >= 2 and args[1] == .small_int) level = args[1].small_int;
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "compresslevel") and v == .small_int)
            level = v.small_int;
    }
    const out = zlib_mod.zlibCompress(a, data, level, 31) catch {
        try raiseBadGzip(interp, "gzip compress failed");
        return error.PyException;
    };
    defer a.free(out);
    return Value{ .bytes = try Bytes.init(a, out) };
}

fn gzCompressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return gzCompressImpl(interp, args, &.{}, &.{});
}
fn gzCompressKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return gzCompressImpl(interp, args, kn, kv);
}

fn gzDecompressFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.raisePy("TypeError", "decompress requires data");
        return error.PyException;
    }
    const data = argBytes(args[0]) catch {
        try interp.raisePy("TypeError", "data must be bytes-like");
        return error.PyException;
    };
    // Multi-member: loop until all input consumed.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var remaining = data;
    while (remaining.len > 0) {
        const r = zlib_mod.zlibDecompress(a, remaining, 31) catch {
            try raiseBadGzip(interp, "not a gzip file");
            return error.PyException;
        };
        defer a.free(r.out);
        try out.appendSlice(a, r.out);
        if (r.consumed == 0 or r.consumed > remaining.len) break;
        remaining = remaining[r.consumed..];
    }
    return Value{ .bytes = try Bytes.init(a, out.items) };
}

// ===== GzipFile class =====

fn buildGzipFileClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodRegKw(a, d, "__init__", gzfInitFn, gzfInitKw);
    try methodReg(a, d, "write", gzfWriteFn);
    try methodRegKw(a, d, "read", gzfReadFn, gzfReadKw);
    try methodReg(a, d, "readline", gzfReadlineFn);
    try methodReg(a, d, "peek", gzfPeekFn);
    try methodReg(a, d, "tell", gzfTellFn);
    try methodRegKw(a, d, "seek", gzfSeekFn, gzfSeekKw);
    try methodReg(a, d, "close", gzfCloseFn);
    try methodReg(a, d, "flush", gzfFlushFn);
    try methodReg(a, d, "readable", gzfReadableFn);
    try methodReg(a, d, "writable", gzfWritableFn);
    try methodReg(a, d, "seekable", gzfSeekableFn);
    try methodReg(a, d, "__enter__", gzfEnterFn);
    try methodReg(a, d, "__exit__", gzfExitFn);
    interp.gzip_file_class = try Class.init(a, "GzipFile", &.{}, d);
}

fn gzStateFromInst(inst: *Instance) *GzipState {
    const v = inst.dict.getStr("_gz").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn gzfInitImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) anyerror!Value {
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;

    var path_str: []const u8 = "";
    var mode_str: []const u8 = "rb";
    var level: i64 = 9;

    if (args.len >= 2) {
        if (args[1] != .none) {
            if (argStr(args[1])) |s| path_str = s;
            if (args[1] == .bytes) path_str = args[1].bytes.data;
        }
    }
    if (args.len >= 3) {
        if (args[2] != .none) {
            if (argStr(args[2])) |s| mode_str = s;
        }
    }
    if (args.len >= 4 and args[3] == .small_int) level = args[3].small_int;

    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str) {
            const kns = kn.str.bytes;
            if (std.mem.eql(u8, kns, "filename") or std.mem.eql(u8, kns, "name")) {
                if (argStr(v)) |s| path_str = s;
            } else if (std.mem.eql(u8, kns, "mode")) {
                if (argStr(v)) |s| mode_str = s;
            } else if (std.mem.eql(u8, kns, "compresslevel") and v == .small_int) {
                level = v.small_int;
            }
        }
    }

    const is_write = std.mem.startsWith(u8, mode_str, "w") or std.mem.startsWith(u8, mode_str, "a");
    const is_text = std.mem.endsWith(u8, mode_str, "t");

    const state = try a.create(GzipState);
    state.* = .{
        .path = try a.dupe(u8, path_str),
        .mode_write = is_write,
        .text_mode = is_text,
        .buf = .empty,
        .pos = 0,
        .level = level,
        .closed = false,
        .allocator = a,
    };

    // For read mode: load and decompress the file now.
    if (!is_write and path_str.len > 0) {
        const file_data = readFileToBytes(interp, path_str) catch {
            state.deinit();
            a.destroy(state);
            try raiseBadGzip(interp, "cannot open gzip file");
            return error.PyException;
        };
        defer a.free(file_data);
        var remaining = file_data;
        while (remaining.len > 0) {
            const r = zlib_mod.zlibDecompress(a, remaining, 31) catch {
                state.deinit();
                a.destroy(state);
                try raiseBadGzip(interp, "not a gzip file");
                return error.PyException;
            };
            try state.buf.appendSlice(a, r.out);
            a.free(r.out);
            if (r.consumed == 0 or r.consumed > remaining.len) break;
            remaining = remaining[r.consumed..];
        }
    }

    try inst.dict.setStr(a, "_gz", Value{ .small_int = @intCast(@intFromPtr(state)) });
    const mode_display = if (is_write) "wb" else "rb";
    try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, path_str) });
    try inst.dict.setStr(a, "mode", Value{ .str = try Str.init(a, mode_display) });
    try inst.dict.setStr(a, "closed", Value{ .boolean = false });
    return Value{ .none = {} };
}

fn gzfInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return gzfInitImpl(interp, args, &.{}, &.{});
}
fn gzfInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return gzfInitImpl(interp, args, kn, kv);
}

fn gzfWriteFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state = gzStateFromInst(inst);
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

fn gzfReadImpl(interp: *Interp, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state = gzStateFromInst(inst);
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

    if (state.text_mode) {
        return Value{ .str = try Str.init(a, chunk) };
    }
    return Value{ .bytes = try Bytes.init(a, chunk) };
}

fn gzfReadFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return gzfReadImpl(interp, args, &.{}, &.{});
}
fn gzfReadKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return gzfReadImpl(interp, args, kn, kv);
}

fn gzfReadlineFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state = gzStateFromInst(inst);
    const avail = state.buf.items[state.pos..];
    if (avail.len == 0) {
        if (state.text_mode) return Value{ .str = try Str.init(a, "") };
        return Value{ .bytes = try Bytes.init(a, &.{}) };
    }
    const nl = std.mem.indexOfScalar(u8, avail, '\n');
    const n = if (nl) |idx| idx + 1 else avail.len;
    const chunk = avail[0..n];
    state.pos += n;
    if (state.text_mode) {
        return Value{ .str = try Str.init(a, chunk) };
    }
    return Value{ .bytes = try Bytes.init(a, chunk) };
}

fn gzfPeekFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state = gzStateFromInst(inst);
    const avail = state.buf.items[state.pos..];
    var n: usize = avail.len;
    if (args.len >= 2 and args[1] == .small_int) {
        const req: usize = @intCast(@max(0, args[1].small_int));
        if (req < n) n = req;
    }
    return Value{ .bytes = try Bytes.init(a, avail[0..n]) };
}

fn gzfTellFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state = gzStateFromInst(inst);
    if (state.mode_write) {
        return Value{ .small_int = @intCast(state.buf.items.len) };
    }
    return Value{ .small_int = @intCast(state.pos) };
}

fn gzfSeekImpl(_: *Interp, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state = gzStateFromInst(inst);
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

fn gzfSeekFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return gzfSeekImpl(interp, args, &.{}, &.{});
}
fn gzfSeekKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return gzfSeekImpl(interp, args, kn, kv);
}

fn gzfCloseFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state = gzStateFromInst(inst);
    if (state.closed) return Value{ .none = {} };
    if (state.mode_write and state.path.len > 0) {
        const out = zlib_mod.zlibCompress(a, state.buf.items, state.level, 31) catch {
            try raiseBadGzip(interp, "gzip compress failed on close");
            return error.PyException;
        };
        defer a.free(out);
        writeBytesToFile(interp, state.path, out) catch {
            try interp.raisePy("OSError", "cannot write gzip file");
            return error.PyException;
        };
    }
    state.closed = true;
    try inst.dict.setStr(a, "closed", Value{ .boolean = true });
    return Value{ .none = {} };
}

fn gzfFlushFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .none = {} };
}

fn gzfReadableFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const state = gzStateFromInst(args[0].instance);
    return Value{ .boolean = !state.mode_write };
}

fn gzfWritableFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const state = gzStateFromInst(args[0].instance);
    return Value{ .boolean = state.mode_write };
}

fn gzfSeekableFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .boolean = true };
}

fn gzfEnterFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    return args[0];
}

fn gzfExitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return gzfCloseFn(p, args[0..1]);
}

// ===== gzip.open =====

fn gzOpenImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    if (interp.gzip_file_class == null) try buildGzipFileClass(interp);
    const a = interp.allocator;
    const cls = interp.gzip_file_class.?;
    const inst = try Instance.init(a, cls);
    const self = Value{ .instance = inst };

    var init_args_buf: [4]Value = undefined;
    init_args_buf[0] = self;
    var n: usize = 1;
    if (args.len >= 1) { init_args_buf[1] = args[0]; n = 2; }
    if (args.len >= 2) { init_args_buf[2] = args[1]; n = 3; }
    if (args.len >= 3) { init_args_buf[3] = args[2]; n = 4; }

    _ = try gzfInitImpl(interp, init_args_buf[0..n], kw_names, kw_vals);
    return self;
}

fn gzOpenFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return gzOpenImpl(interp, args, &.{}, &.{});
}
fn gzOpenKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return gzOpenImpl(interp, args, kn, kv);
}
