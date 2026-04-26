//! Pinhole `tempfile`: gettempdir/gettempdirb/gettempprefix(/b),
//! mktemp/mkstemp/mkdtemp, plus TemporaryFile/NamedTemporaryFile/
//! SpooledTemporaryFile/TemporaryDirectory. The three temp-file
//! shapes share one buffer-backed file class; only NamedTemporaryFile
//! actually creates an on-disk file (so `os.path.isfile(f.name)`
//! works) and only NamedTemporaryFile honors `delete=`.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Bytes = @import("../object/bytes.zig").Bytes;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Tuple = @import("../object/tuple.zig").Tuple;
const Interp = @import("interp.zig").Interp;

var temp_seed: u64 = 0xCAFEBABEDEADBEEF;
var fake_fd_counter: u64 = 1000;

const FileState = struct {
    data: std.ArrayList(u8),
    pos: usize = 0,
    closed: bool = false,
    binary: bool,
    path: ?[]u8 = null,
    delete_on_close: bool = false,
};

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);
    const m = try Module.init(a, "tempfile");

    try m.attrs.setStr(a, "tempdir", Value.none);
    try m.attrs.setStr(a, "TemporaryDirectory", Value{ .class = interp.tempfile_temp_dir_class.? });

    try regKw(interp, m, "TemporaryFile", temporaryFileFn, temporaryFileKwFn);
    try regKw(interp, m, "NamedTemporaryFile", namedTemporaryFileFn, namedTemporaryFileKwFn);
    try regKw(interp, m, "SpooledTemporaryFile", spooledTemporaryFileFn, spooledTemporaryFileKwFn);

    try reg(interp, m, "gettempdir", gettempdirFn);
    try reg(interp, m, "gettempdirb", gettempdirbFn);
    try reg(interp, m, "gettempprefix", gettempprefixFn);
    try reg(interp, m, "gettempprefixb", gettempprefixbFn);
    try regKw(interp, m, "mktemp", mktempFn, mktempKwFn);
    try regKw(interp, m, "mkstemp", mkstempFn, mkstempKwFn);
    try regKw(interp, m, "mkdtemp", mkdtempFn, mkdtempKwFn);

    interp.tempfile_module = m;
    return m;
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

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;
    if (interp.tempfile_temp_dir_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "__init__", tdInitFn);
        try methodRegKw(a, d, "__init__", tdInitFn, tdInitKwFn);
        try methodReg(a, d, "__enter__", tdEnterFn);
        try methodReg(a, d, "__exit__", tdExitFn);
        try methodReg(a, d, "cleanup", tdCleanupFn);
        try methodReg(a, d, "__repr__", tdReprFn);
        interp.tempfile_temp_dir_class = try Class.init(a, "TemporaryDirectory", &.{}, d);
    }
    if (interp.tempfile_file_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "read", fileRead);
        try methodReg(a, d, "write", fileWrite);
        try methodReg(a, d, "seek", fileSeek);
        try methodReg(a, d, "tell", fileTell);
        try methodReg(a, d, "close", fileClose);
        try methodReg(a, d, "writable", fileWritable);
        try methodReg(a, d, "readable", fileReadable);
        try methodReg(a, d, "seekable", fileSeekable);
        try methodReg(a, d, "rollover", fileRollover);
        try methodReg(a, d, "__enter__", fileEnter);
        try methodReg(a, d, "__exit__", fileExit);
        interp.tempfile_file_class = try Class.init(a, "_TempFile", &.{}, d);
    }
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

// ===== gettemp* =====

fn gettempdirFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const v = Value{ .str = try Str.init(interp.allocator, interp.tmp_dir) };
    if (interp.tempfile_module) |m| {
        try m.attrs.setStr(interp.allocator, "tempdir", v);
    }
    return v;
}

fn gettempdirbFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .bytes = try Bytes.init(interp.allocator, interp.tmp_dir) };
}

fn gettempprefixFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, "tmp") };
}

fn gettempprefixbFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .bytes = try Bytes.init(interp.allocator, "tmp") };
}

// ===== mktemp / mkstemp / mkdtemp =====

const NameOpts = struct {
    suffix: []const u8 = "",
    prefix: []const u8 = "tmp",
    dir: ?[]const u8 = null,
};

fn parseNameOpts(args: []const Value, kw_names: []const Value, kw_values: []const Value) NameOpts {
    var opts: NameOpts = .{};
    if (args.len >= 1 and args[0] == .str) opts.suffix = args[0].str.bytes;
    if (args.len >= 2 and args[1] == .str) opts.prefix = args[1].str.bytes;
    if (args.len >= 3 and args[2] == .str) opts.dir = args[2].str.bytes;
    for (kw_names, kw_values) |k, v| {
        if (k != .str) continue;
        if (std.mem.eql(u8, k.str.bytes, "suffix") and v == .str) opts.suffix = v.str.bytes;
        if (std.mem.eql(u8, k.str.bytes, "prefix") and v == .str) opts.prefix = v.str.bytes;
        if (std.mem.eql(u8, k.str.bytes, "dir") and v == .str) opts.dir = v.str.bytes;
    }
    return opts;
}

fn buildCandidatePath(a: std.mem.Allocator, root: []const u8, prefix: []const u8, suffix: []const u8) ![]u8 {
    const seed = @atomicRmw(u64, &temp_seed, .Add, 1, .seq_cst);
    var name_buf: [64]u8 = undefined;
    const rand_part = try std.fmt.bufPrint(&name_buf, "{x}", .{seed});
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, root);
    if (root.len > 0 and root[root.len - 1] != '/') try out.append(a, '/');
    try out.appendSlice(a, prefix);
    try out.appendSlice(a, rand_part);
    try out.appendSlice(a, suffix);
    return try out.toOwnedSlice(a);
}

fn mktempFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return mktempCommon(p, args, &.{}, &.{});
}

fn mktempKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return mktempCommon(p, args, kw_names, kw_values);
}

fn mktempCommon(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const opts = parseNameOpts(args, kw_names, kw_values);
    const root = opts.dir orelse interp.tmp_dir;
    const path = try buildCandidatePath(a, root, opts.prefix, opts.suffix);
    return Value{ .str = try Str.fromOwnedSlice(a, path) };
}

fn mkstempFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return mkstempCommon(p, args, &.{}, &.{});
}

fn mkstempKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return mkstempCommon(p, args, kw_names, kw_values);
}

fn mkstempCommon(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const opts = parseNameOpts(args, kw_names, kw_values);
    const root = opts.dir orelse interp.tmp_dir;
    var attempt: u32 = 0;
    while (attempt < 1000) : (attempt += 1) {
        const path = try buildCandidatePath(a, root, opts.prefix, opts.suffix);
        var file = std.Io.Dir.cwd().createFile(interp.io, path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                a.free(path);
                continue;
            },
            else => {
                a.free(path);
                try interp.raisePy("OSError", "mkstemp: createFile failed");
                return error.PyException;
            },
        };
        file.close(interp.io);
        const fd = @atomicRmw(u64, &fake_fd_counter, .Add, 1, .seq_cst);
        const t = try Tuple.init(a, 2);
        t.items[0] = Value{ .small_int = @intCast(fd) };
        t.items[1] = Value{ .str = try Str.fromOwnedSlice(a, path) };
        return Value{ .tuple = t };
    }
    try interp.raisePy("OSError", "mkstemp: too many attempts");
    return error.PyException;
}

fn mkdtempFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return mkdtempCommon(p, args, &.{}, &.{});
}

fn mkdtempKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return mkdtempCommon(p, args, kw_names, kw_values);
}

fn mkdtempCommon(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const opts = parseNameOpts(args, kw_names, kw_values);
    const root = opts.dir orelse interp.tmp_dir;
    var attempt: u32 = 0;
    while (attempt < 1000) : (attempt += 1) {
        const path = try buildCandidatePath(a, root, opts.prefix, opts.suffix);
        std.Io.Dir.cwd().createDir(interp.io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                a.free(path);
                continue;
            },
            else => {
                a.free(path);
                try interp.raisePy("OSError", "mkdtemp: createDir failed");
                return error.PyException;
            },
        };
        return Value{ .str = try Str.fromOwnedSlice(a, path) };
    }
    try interp.raisePy("OSError", "mkdtemp: too many attempts");
    return error.PyException;
}

// ===== TemporaryFile / NamedTemporaryFile / SpooledTemporaryFile =====

const FileOpts = struct {
    mode: []const u8 = "w+b",
    suffix: []const u8 = "",
    prefix: []const u8 = "tmp",
    dir: ?[]const u8 = null,
    delete: bool = true,
    max_size: i64 = 0,
};

fn parseFileOpts(args: []const Value, kw_names: []const Value, kw_values: []const Value) FileOpts {
    var opts: FileOpts = .{};
    // No positional args from fixture; everything via kwargs.
    if (args.len >= 1 and args[0] == .str) opts.mode = args[0].str.bytes;
    for (kw_names, kw_values) |k, v| {
        if (k != .str) continue;
        const n = k.str.bytes;
        if (std.mem.eql(u8, n, "mode") and v == .str) opts.mode = v.str.bytes;
        if (std.mem.eql(u8, n, "suffix") and v == .str) opts.suffix = v.str.bytes;
        if (std.mem.eql(u8, n, "prefix") and v == .str) opts.prefix = v.str.bytes;
        if (std.mem.eql(u8, n, "dir") and v == .str) opts.dir = v.str.bytes;
        if (std.mem.eql(u8, n, "delete") and v == .boolean) opts.delete = v.boolean;
        if (std.mem.eql(u8, n, "max_size") and v == .small_int) opts.max_size = v.small_int;
    }
    return opts;
}

fn newFileInstance(interp: *Interp, opts: FileOpts, with_path: bool) !Value {
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.tempfile_file_class.?);
    const state = try a.create(FileState);
    state.* = .{
        .data = .empty,
        .binary = std.mem.indexOfScalar(u8, opts.mode, 'b') != null,
    };
    if (with_path) {
        const root = opts.dir orelse interp.tmp_dir;
        var attempt: u32 = 0;
        while (attempt < 1000) : (attempt += 1) {
            const path = try buildCandidatePath(a, root, opts.prefix, opts.suffix);
            var file = std.Io.Dir.cwd().createFile(interp.io, path, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    a.free(path);
                    continue;
                },
                else => {
                    a.free(path);
                    try interp.raisePy("OSError", "tempfile: createFile failed");
                    return error.PyException;
                },
            };
            file.close(interp.io);
            state.path = path;
            state.delete_on_close = opts.delete;
            try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, path) });
            break;
        }
    }
    try inst.dict.setStr(a, "_state", Value{ .small_int = @intCast(@intFromPtr(state)) });
    try inst.dict.setStr(a, "closed", Value{ .boolean = false });
    return Value{ .instance = inst };
}

fn temporaryFileFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return temporaryFileCommon(p, args, &.{}, &.{});
}

fn temporaryFileKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return temporaryFileCommon(p, args, kw_names, kw_values);
}

fn temporaryFileCommon(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const opts = parseFileOpts(args, kw_names, kw_values);
    return newFileInstance(interp, opts, false);
}

fn namedTemporaryFileFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return namedTemporaryFileCommon(p, args, &.{}, &.{});
}

fn namedTemporaryFileKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return namedTemporaryFileCommon(p, args, kw_names, kw_values);
}

fn namedTemporaryFileCommon(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const opts = parseFileOpts(args, kw_names, kw_values);
    return newFileInstance(interp, opts, true);
}

fn spooledTemporaryFileFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return spooledTemporaryFileCommon(p, args, &.{}, &.{});
}

fn spooledTemporaryFileKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return spooledTemporaryFileCommon(p, args, kw_names, kw_values);
}

fn spooledTemporaryFileCommon(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const opts = parseFileOpts(args, kw_names, kw_values);
    return newFileInstance(interp, opts, false);
}

// ===== file methods =====

fn argInst(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

fn stateFrom(inst: *Instance) *FileState {
    const v = inst.dict.getStr("_state").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn fileWrite(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const st = stateFrom(inst);
    if (args.len < 2) return error.TypeError;
    const a = interp.allocator;
    const data: []const u8 = switch (args[1]) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        else => return error.TypeError,
    };
    if (st.pos == st.data.items.len) {
        try st.data.appendSlice(a, data);
    } else {
        const need = st.pos + data.len;
        if (need > st.data.items.len) try st.data.resize(a, need);
        @memcpy(st.data.items[st.pos..need], data);
    }
    st.pos += data.len;
    return Value{ .small_int = @intCast(data.len) };
}

fn fileRead(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const st = stateFrom(inst);
    const a = interp.allocator;
    const remaining = st.data.items.len - st.pos;
    const want: usize = if (args.len >= 2 and args[1] == .small_int and args[1].small_int >= 0)
        @min(remaining, @as(usize, @intCast(args[1].small_int)))
    else
        remaining;
    const slice = st.data.items[st.pos .. st.pos + want];
    st.pos += want;
    if (st.binary) {
        return Value{ .bytes = try Bytes.init(a, slice) };
    }
    return Value{ .str = try Str.init(a, slice) };
}

fn fileSeek(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const inst = try argInst(args);
    const st = stateFrom(inst);
    if (args.len < 2 or args[1] != .small_int) return error.TypeError;
    const offset = args[1].small_int;
    const whence: i64 = if (args.len >= 3 and args[2] == .small_int) args[2].small_int else 0;
    const new_pos: i64 = switch (whence) {
        0 => offset,
        1 => @as(i64, @intCast(st.pos)) + offset,
        2 => @as(i64, @intCast(st.data.items.len)) + offset,
        else => return error.ValueError,
    };
    if (new_pos < 0) return error.ValueError;
    st.pos = @intCast(new_pos);
    return Value{ .small_int = new_pos };
}

fn fileTell(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const inst = try argInst(args);
    const st = stateFrom(inst);
    return Value{ .small_int = @intCast(st.pos) };
}

fn fileClose(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const st = stateFrom(inst);
    const a = interp.allocator;
    if (st.closed) return Value.none;
    st.closed = true;
    if (st.path) |path| {
        if (st.delete_on_close) {
            std.Io.Dir.cwd().deleteFile(interp.io, path) catch {};
        } else {
            // Flush in-memory buffer to the on-disk file.
            var file = std.Io.Dir.cwd().createFile(interp.io, path, .{}) catch null;
            if (file) |*f_handle| {
                defer f_handle.close(interp.io);
                var write_buf: [4096]u8 = undefined;
                var writer = f_handle.writer(interp.io, &write_buf);
                writer.interface.writeAll(st.data.items) catch {};
                writer.interface.flush() catch {};
            }
        }
    }
    st.data.deinit(a);
    try inst.dict.setStr(a, "closed", Value{ .boolean = true });
    return Value.none;
}

fn fileWritable(_: *anyopaque, args: []const Value) anyerror!Value {
    _ = try argInst(args);
    return Value{ .boolean = true };
}

fn fileReadable(_: *anyopaque, args: []const Value) anyerror!Value {
    _ = try argInst(args);
    return Value{ .boolean = true };
}

fn fileSeekable(_: *anyopaque, args: []const Value) anyerror!Value {
    _ = try argInst(args);
    return Value{ .boolean = true };
}

fn fileRollover(_: *anyopaque, args: []const Value) anyerror!Value {
    _ = try argInst(args);
    return Value.none;
}

fn fileEnter(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try argInst(args);
    return Value{ .instance = inst };
}

fn fileExit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try fileClose(p, args[0..1]);
    return Value{ .boolean = false };
}

// ===== TemporaryDirectory =====

const TdOpts = struct {
    suffix: []const u8 = "",
    prefix: []const u8 = "tmp",
    dir: ?[]const u8 = null,
    delete: bool = true,
};

fn parseTdOpts(args: []const Value, kw_names: []const Value, kw_values: []const Value) TdOpts {
    var opts: TdOpts = .{};
    if (args.len >= 2 and args[1] == .str) opts.suffix = args[1].str.bytes;
    if (args.len >= 3 and args[2] == .str) opts.prefix = args[2].str.bytes;
    if (args.len >= 4 and args[3] == .str) opts.dir = args[3].str.bytes;
    if (args.len >= 5 and args[4] == .boolean) opts.delete = args[4].boolean;
    for (kw_names, kw_values) |k, v| {
        if (k != .str) continue;
        const n = k.str.bytes;
        if (std.mem.eql(u8, n, "suffix") and v == .str) opts.suffix = v.str.bytes;
        if (std.mem.eql(u8, n, "prefix") and v == .str) opts.prefix = v.str.bytes;
        if (std.mem.eql(u8, n, "dir") and v == .str) opts.dir = v.str.bytes;
        if (std.mem.eql(u8, n, "delete") and v == .boolean) opts.delete = v.boolean;
    }
    return opts;
}

fn tdInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return tdInitCommon(p, args, &.{}, &.{});
}

fn tdInitKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return tdInitCommon(p, args, kw_names, kw_values);
}

fn tdInitCommon(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;
    const opts = parseTdOpts(args, kw_names, kw_values);
    const root = opts.dir orelse interp.tmp_dir;
    var attempt: u32 = 0;
    while (attempt < 1000) : (attempt += 1) {
        const path = try buildCandidatePath(a, root, opts.prefix, opts.suffix);
        std.Io.Dir.cwd().createDir(interp.io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                a.free(path);
                continue;
            },
            else => {
                a.free(path);
                try interp.raisePy("OSError", "TemporaryDirectory: createDir failed");
                return error.PyException;
            },
        };
        try self.dict.setStr(a, "name", Value{ .str = try Str.fromOwnedSlice(a, path) });
        try self.dict.setStr(a, "_delete", Value{ .boolean = opts.delete });
        return Value.none;
    }
    try interp.raisePy("OSError", "TemporaryDirectory: too many attempts");
    return error.PyException;
}

fn tdEnterFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    return self.dict.getStr("name") orelse Value.none;
}

fn tdExitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const delete = blk: {
        const v = self.dict.getStr("_delete") orelse break :blk true;
        if (v == .boolean) break :blk v.boolean;
        break :blk true;
    };
    if (delete) {
        _ = try tdCleanupFn(p, args[0..1]);
    }
    return Value{ .boolean = false };
}

fn tdCleanupFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const name_v = self.dict.getStr("name") orelse return Value.none;
    if (name_v != .str) return Value.none;
    rmTreeBest(interp, name_v.str.bytes);
    return Value.none;
}

fn tdReprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "<TemporaryDirectory '");
    if (self.dict.getStr("name")) |v| {
        if (v == .str) try buf.appendSlice(a, v.str.bytes);
    }
    try buf.appendSlice(a, "'>");
    return Value{ .str = try Str.init(a, buf.items) };
}

fn rmTreeBest(interp: *Interp, path: []const u8) void {
    const a = interp.allocator;
    var dir = std.Io.Dir.cwd().openDir(interp.io, path, .{ .iterate = true }) catch {
        std.Io.Dir.cwd().deleteFile(interp.io, path) catch {};
        return;
    };
    var entries: std.ArrayList([]u8) = .empty;
    defer {
        for (entries.items) |e| a.free(e);
        entries.deinit(a);
    }
    var subdirs: std.ArrayList(bool) = .empty;
    defer subdirs.deinit(a);

    var it = dir.iterate();
    while (it.next(interp.io) catch null) |entry| {
        const name_dup = a.dupe(u8, entry.name) catch continue;
        entries.append(a, name_dup) catch {
            a.free(name_dup);
            continue;
        };
        subdirs.append(a, entry.kind == .directory) catch {};
    }
    dir.close(interp.io);

    for (entries.items, 0..) |name, i| {
        var child_buf: std.ArrayList(u8) = .empty;
        defer child_buf.deinit(a);
        child_buf.appendSlice(a, path) catch continue;
        if (path.len > 0 and path[path.len - 1] != '/') child_buf.append(a, '/') catch continue;
        child_buf.appendSlice(a, name) catch continue;
        const is_dir = i < subdirs.items.len and subdirs.items[i];
        if (is_dir) {
            rmTreeBest(interp, child_buf.items);
        } else {
            std.Io.Dir.cwd().deleteFile(interp.io, child_buf.items) catch {};
        }
    }
    std.Io.Dir.cwd().deleteDir(interp.io, path) catch {};
}
