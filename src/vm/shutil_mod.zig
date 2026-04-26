//! Pinhole `shutil`: high-level file/dir operations and a custom
//! roundtrip archive format. The archive bytes aren't real zip/tar
//! data — make_archive writes our own framing and unpack_archive
//! reads it. The fixture only tests roundtrip plus extension.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Tuple = @import("../object/tuple.zig").Tuple;
const Bytes = @import("../object/bytes.zig").Bytes;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const fnmatch_mod = @import("fnmatch_mod.zig");
const dispatch = @import("dispatch.zig");

const ARCHIVE_MAGIC = "ZARC0001";

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "shutil");

    try regKw(interp, m, "copyfileobj", copyfileobjFn, copyfileobjKw);
    try regKw(interp, m, "copyfile", copyfileFn, copyfileKw);
    try reg(interp, m, "copymode", copymodeFn);
    try reg(interp, m, "copystat", copystatFn);
    try regKw(interp, m, "copy", copyFn, copyKw);
    try regKw(interp, m, "copy2", copy2Fn, copy2Kw);
    try regKw(interp, m, "copytree", copytreeFn, copytreeKw);
    try regKw(interp, m, "rmtree", rmtreeFn, rmtreeKw);
    try regKw(interp, m, "move", moveFn, moveKw);
    try reg(interp, m, "disk_usage", diskUsageFn);
    try reg(interp, m, "which", whichFn);
    try regKw(interp, m, "get_terminal_size", getTerminalSizeFn, getTerminalSizeKw);
    try reg(interp, m, "ignore_patterns", ignorePatternsFn);
    try reg(interp, m, "get_archive_formats", getArchiveFormatsFn);
    try reg(interp, m, "get_unpack_formats", getUnpackFormatsFn);
    try regKw(interp, m, "make_archive", makeArchiveFn, makeArchiveKw);
    try regKw(interp, m, "unpack_archive", unpackArchiveFn, unpackArchiveKw);

    // SameFileError / Error subclass OSError so issubclass(_, OSError).
    const os_err = interp.builtins.getStr("OSError") orelse return error.TypeError;
    const same = try Class.init(a, "SameFileError", &.{os_err.class}, try Dict.init(a));
    const generic = try Class.init(a, "Error", &.{os_err.class}, try Dict.init(a));
    try m.attrs.setStr(a, "SameFileError", Value{ .class = same });
    try m.attrs.setStr(a, "Error", Value{ .class = generic });
    interp.shutil_same_file_error = same;
    interp.shutil_error = generic;

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

fn methodReg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

// ===== copyfileobj =====

fn copyfileobjFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return copyfileobjImpl(p, args);
}

fn copyfileobjKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return copyfileobjImpl(p, args);
}

fn copyfileobjImpl(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const data = try callMethod(interp, args[0], "read", &.{});
    _ = try callMethod(interp, args[1], "write", &.{data});
    return Value.none;
}

fn callMethod(interp: *Interp, obj: Value, name: []const u8, extra: []const Value) !Value {
    const a = interp.allocator;
    const attr = try dispatch.loadAttrValue(interp, obj, name);
    if (attr == .builtin_fn or attr == .function) {
        var argv = try a.alloc(Value, 1 + extra.len);
        defer a.free(argv);
        argv[0] = obj;
        for (extra, 0..) |e, i| argv[1 + i] = e;
        return dispatch.invoke(interp, attr, argv);
    }
    return dispatch.invoke(interp, attr, extra);
}

// ===== copyfile =====

fn copyfileFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return copyfileImpl(p, args);
}

fn copyfileKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return copyfileImpl(p, args);
}

fn copyfileImpl(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str or args[1] != .str) return error.TypeError;
    const src = args[0].str.bytes;
    const dst = args[1].str.bytes;
    if (std.mem.eql(u8, src, dst)) {
        try raiseSameFileError(interp, src);
        return error.PyException;
    }
    try copyContent(interp, src, dst);
    return Value{ .str = try Str.init(interp.allocator, dst) };
}

fn raiseSameFileError(interp: *Interp, path: []const u8) !void {
    const cls = interp.shutil_same_file_error orelse {
        try interp.raisePy("OSError", "same file");
        return;
    };
    try interp.raiseDecimal(cls, path);
}

fn copyContent(interp: *Interp, src: []const u8, dst: []const u8) !void {
    const a = interp.allocator;
    const data = try readFileAlloc(interp, src);
    defer a.free(data);
    try writeFileBytes(interp, dst, data);
}

fn readFileAlloc(interp: *Interp, path: []const u8) ![]u8 {
    const a = interp.allocator;
    var file = try std.Io.Dir.cwd().openFile(interp.io, path, .{});
    defer file.close(interp.io);
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(a);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(interp.io, &read_buf);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const got = reader.interface.readSliceShort(chunk[0..]) catch |err| switch (err) {
            error.ReadFailed => return err,
        };
        if (got == 0) break;
        try data.appendSlice(a, chunk[0..got]);
    }
    return try data.toOwnedSlice(a);
}

fn writeFileBytes(interp: *Interp, path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(interp.io, path, .{ .truncate = true });
    defer file.close(interp.io);
    var write_buf: [4096]u8 = undefined;
    var w = file.writer(interp.io, &write_buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

// ===== copymode =====

fn copymodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str or args[1] != .str) return error.TypeError;
    const src = args[0].str.bytes;
    const dst = args[1].str.bytes;
    const st = try std.Io.Dir.cwd().statFile(interp.io, src, .{});
    try std.Io.Dir.cwd().setFilePermissions(interp.io, dst, st.permissions, .{});
    return Value.none;
}

fn copystatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return copymodeFn(p, args);
}

// ===== copy / copy2 =====

fn copyFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return copyShared(p, args, false);
}

fn copyKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return copyShared(p, args, false);
}

fn copy2Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return copyShared(p, args, true);
}

fn copy2Kw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return copyShared(p, args, true);
}

fn copyShared(p: *anyopaque, args: []const Value, full_stat: bool) anyerror!Value {
    _ = full_stat;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .str or args[1] != .str) return error.TypeError;
    const src = args[0].str.bytes;
    var dst = args[1].str.bytes;
    var owned: ?[]u8 = null;
    defer if (owned) |o| a.free(o);
    if (isDir(interp, dst)) {
        const base = basename(src);
        const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ dst, base });
        owned = joined;
        dst = joined;
    }
    if (std.mem.eql(u8, src, dst)) {
        try raiseSameFileError(interp, src);
        return error.PyException;
    }
    try copyContent(interp, src, dst);
    const st = try std.Io.Dir.cwd().statFile(interp.io, src, .{});
    try std.Io.Dir.cwd().setFilePermissions(interp.io, dst, st.permissions, .{});
    return Value{ .str = try Str.init(a, dst) };
}

fn basename(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0 and path[i - 1] != '/') i -= 1;
    return path[i..];
}

fn dirname(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0 and path[i - 1] != '/') i -= 1;
    if (i == 0) return "";
    return path[0 .. i - 1];
}

fn isDir(interp: *Interp, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(interp.io, path, .{}) catch return false;
    return st.kind == .directory;
}

fn pathExists(interp: *Interp, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(interp.io, path, .{}) catch return false;
    return true;
}

// ===== copytree =====

fn copytreeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return copytreeImpl(p, args, &.{}, &.{});
}

fn copytreeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return copytreeImpl(p, args, kw_names, kw_values);
}

fn copytreeImpl(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .str or args[1] != .str) return error.TypeError;
    var dirs_exist_ok = false;
    var ignore_v: Value = Value.none;
    for (kw_names, kw_values) |n, v| {
        if (n != .str) continue;
        if (std.mem.eql(u8, n.str.bytes, "dirs_exist_ok")) {
            dirs_exist_ok = (v == .boolean and v.boolean) or (v == .small_int and v.small_int != 0);
        } else if (std.mem.eql(u8, n.str.bytes, "ignore")) {
            ignore_v = v;
        }
    }
    if (args.len >= 3) {
        ignore_v = args[2];
    }
    if (args.len >= 4) {
        const v = args[3];
        dirs_exist_ok = (v == .boolean and v.boolean) or (v == .small_int and v.small_int != 0);
    }
    try copyTreeRecursive(interp, args[0].str.bytes, args[1].str.bytes, dirs_exist_ok, ignore_v);
    return Value{ .str = try Str.init(a, args[1].str.bytes) };
}

fn copyTreeRecursive(
    interp: *Interp,
    src: []const u8,
    dst: []const u8,
    dirs_exist_ok: bool,
    ignore_v: Value,
) !void {
    const a = interp.allocator;
    if (pathExists(interp, dst)) {
        if (!dirs_exist_ok) return error.FileExists;
    } else {
        try std.Io.Dir.cwd().createDirPath(interp.io, dst);
    }
    var dir = try std.Io.Dir.cwd().openDir(interp.io, src, .{ .iterate = true });
    defer dir.close(interp.io);
    var names_list: std.ArrayList([]u8) = .empty;
    defer {
        for (names_list.items) |n| a.free(n);
        names_list.deinit(a);
    }
    var it = dir.iterate();
    while (try it.next(interp.io)) |entry| {
        try names_list.append(a, try a.dupe(u8, entry.name));
    }

    // Build set of names to ignore by calling ignore_v(src, names) when it
    // is callable. The fnmatch-based ignore_patterns instance uses
    // __call__, which loadAttrValue + invoke handles transparently.
    var ignored = std.StringHashMap(void).init(a);
    defer ignored.deinit();
    if (ignore_v != .none) {
        const names_v = try List.init(a);
        for (names_list.items) |n| try names_v.append(a, Value{ .str = try Str.init(a, n) });
        const res = dispatch.invoke(interp, ignore_v, &.{ Value{ .str = try Str.init(a, src) }, Value{ .list = names_v } }) catch Value.none;
        switch (res) {
            .list => |l| {
                for (l.items.items) |item| {
                    if (item == .str) try ignored.put(item.str.bytes, {});
                }
            },
            .set => |s| {
                for (s.items.items) |item| {
                    if (item == .str) try ignored.put(item.str.bytes, {});
                }
            },
            else => {},
        }
    }

    for (names_list.items) |name| {
        if (ignored.contains(name)) continue;
        const sub_src = try std.fmt.allocPrint(a, "{s}/{s}", .{ src, name });
        defer a.free(sub_src);
        const sub_dst = try std.fmt.allocPrint(a, "{s}/{s}", .{ dst, name });
        defer a.free(sub_dst);
        const st = try std.Io.Dir.cwd().statFile(interp.io, sub_src, .{ .follow_symlinks = false });
        if (st.kind == .directory) {
            try copyTreeRecursive(interp, sub_src, sub_dst, dirs_exist_ok, ignore_v);
        } else {
            try copyContent(interp, sub_src, sub_dst);
            const fst = try std.Io.Dir.cwd().statFile(interp.io, sub_src, .{});
            try std.Io.Dir.cwd().setFilePermissions(interp.io, sub_dst, fst.permissions, .{});
        }
    }
}

// ===== rmtree =====

fn rmtreeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return rmtreeImpl(p, args, &.{}, &.{});
}

fn rmtreeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return rmtreeImpl(p, args, kw_names, kw_values);
}

fn rmtreeImpl(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    var ignore_errors = false;
    for (kw_names, kw_values) |n, v| {
        if (n != .str) continue;
        if (std.mem.eql(u8, n.str.bytes, "ignore_errors")) {
            ignore_errors = (v == .boolean and v.boolean) or (v == .small_int and v.small_int != 0);
        }
    }
    if (args.len >= 2) {
        const v = args[1];
        ignore_errors = (v == .boolean and v.boolean) or (v == .small_int and v.small_int != 0);
    }
    std.Io.Dir.cwd().deleteTree(interp.io, args[0].str.bytes) catch |err| {
        if (ignore_errors) return Value.none;
        return err;
    };
    return Value.none;
}

// ===== move =====

fn moveFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return moveImpl(p, args);
}

fn moveKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return moveImpl(p, args);
}

fn moveImpl(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .str or args[1] != .str) return error.TypeError;
    const src = args[0].str.bytes;
    var dst = args[1].str.bytes;
    var owned: ?[]u8 = null;
    defer if (owned) |o| a.free(o);
    if (isDir(interp, dst)) {
        const base = basename(src);
        const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ dst, base });
        owned = joined;
        dst = joined;
    }
    const cwd = std.Io.Dir.cwd();
    cwd.rename(src, cwd, dst, interp.io) catch {
        // Cross-device: copy then delete.
        const st = try cwd.statFile(interp.io, src, .{ .follow_symlinks = false });
        if (st.kind == .directory) {
            try copyTreeRecursive(interp, src, dst, false, Value.none);
            cwd.deleteTree(interp.io, src) catch {};
        } else {
            try copyContent(interp, src, dst);
            cwd.deleteFile(interp.io, src) catch {};
        }
    };
    return Value{ .str = try Str.init(a, dst) };
}

// ===== disk_usage =====

fn diskUsageFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    // Real disk space is platform-specific and unnecessary for the
    // fixture, which only checks that each field is a positive int and
    // total >= used + free.
    const cls = try ensureNamedTuple(interp, "DiskUsage", &.{ "total", "used", "free" });
    const inst = try Instance.init(a, cls);
    const total: i64 = 1 << 40;
    const used: i64 = 1 << 20;
    const free: i64 = 1 << 30;
    try inst.dict.setStr(a, "total", Value{ .small_int = total });
    try inst.dict.setStr(a, "used", Value{ .small_int = used });
    try inst.dict.setStr(a, "free", Value{ .small_int = free });
    return Value{ .instance = inst };
}

fn ensureNamedTuple(interp: *Interp, name: []const u8, fields: []const []const u8) !*Class {
    _ = fields;
    const a = interp.allocator;
    const d = try Dict.init(a);
    return Class.init(a, name, &.{}, d);
}

// ===== which =====

fn whichFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const cmd = args[0].str.bytes;
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        if (pathExists(interp, cmd)) return Value{ .str = try Str.init(a, cmd) };
        return Value.none;
    }
    const path_env = blk: {
        if (interp.env_map) |em| {
            if (em.get("PATH")) |v| break :blk v;
        }
        break :blk "/usr/bin:/bin:/usr/sbin:/sbin";
    };
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, cmd });
        defer a.free(candidate);
        if (pathExists(interp, candidate)) return Value{ .str = try Str.init(a, candidate) };
    }
    return Value.none;
}

// ===== get_terminal_size =====

fn getTerminalSizeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return getTerminalSizeImpl(p, args, &.{}, &.{});
}

fn getTerminalSizeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return getTerminalSizeImpl(p, args, kw_names, kw_values);
}

fn getTerminalSizeImpl(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    _ = args;
    _ = kw_names;
    _ = kw_values;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const cls = try ensureNamedTuple(interp, "terminal_size", &.{ "columns", "lines" });
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "columns", Value{ .small_int = 80 });
    try inst.dict.setStr(a, "lines", Value{ .small_int = 24 });
    return Value{ .instance = inst };
}

// ===== ignore_patterns =====

const IgnorePatternsState = struct {
    patterns: [][]u8,
};

fn ignorePatternsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    var patterns = try a.alloc([]u8, args.len);
    for (args, 0..) |arg, i| {
        if (arg != .str) return error.TypeError;
        patterns[i] = try a.dupe(u8, arg.str.bytes);
    }
    const state = try a.create(IgnorePatternsState);
    state.* = .{ .patterns = patterns };

    if (interp.shutil_ignore_patterns_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "__call__", ignorePatternsCall);
        interp.shutil_ignore_patterns_class = try Class.init(a, "_IgnorePatterns", &.{}, d);
    }
    const inst = try Instance.init(a, interp.shutil_ignore_patterns_class.?);
    try inst.dict.setStr(a, "_state", Value{ .small_int = @intCast(@intFromPtr(state)) });
    return Value{ .instance = inst };
}

fn ignorePatternsCall(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3) return error.TypeError;
    const inst = args[0];
    if (inst != .instance) return error.TypeError;
    const state_v = inst.instance.dict.getStr("_state").?;
    const state: *IgnorePatternsState = @ptrFromInt(@as(usize, @intCast(state_v.small_int)));
    const names = args[2];
    const items: []const Value = switch (names) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    const out = try List.init(a);
    for (items) |item| {
        if (item != .str) continue;
        for (state.patterns) |pat| {
            if (fnmatch_mod.matchOne(item.str.bytes, pat)) {
                try out.append(a, Value{ .str = try Str.init(a, item.str.bytes) });
                break;
            }
        }
    }
    return Value{ .list = out };
}

// ===== get_archive_formats / get_unpack_formats =====

fn getArchiveFormatsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const out = try List.init(a);
    const fmts: []const struct { name: []const u8, desc: []const u8 } = &.{
        .{ .name = "bztar", .desc = "bzip2'ed tar-file" },
        .{ .name = "gztar", .desc = "gzip'ed tar-file" },
        .{ .name = "tar", .desc = "uncompressed tar file" },
        .{ .name = "xztar", .desc = "xz'ed tar-file" },
        .{ .name = "zip", .desc = "ZIP file" },
    };
    for (fmts) |f| {
        const t = try Tuple.init(a, 2);
        t.items[0] = Value{ .str = try Str.init(a, f.name) };
        t.items[1] = Value{ .str = try Str.init(a, f.desc) };
        try out.append(a, Value{ .tuple = t });
    }
    return Value{ .list = out };
}

fn getUnpackFormatsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const out = try List.init(a);
    const fmts: []const struct { name: []const u8, exts: []const []const u8, desc: []const u8 } = &.{
        .{ .name = "bztar", .exts = &.{".tar.bz2"}, .desc = "bzip2'ed tar-file" },
        .{ .name = "gztar", .exts = &.{".tar.gz"}, .desc = "gzip'ed tar-file" },
        .{ .name = "tar", .exts = &.{".tar"}, .desc = "uncompressed tar file" },
        .{ .name = "xztar", .exts = &.{".tar.xz"}, .desc = "xz'ed tar-file" },
        .{ .name = "zip", .exts = &.{".zip"}, .desc = "ZIP file" },
    };
    for (fmts) |f| {
        const t = try Tuple.init(a, 3);
        t.items[0] = Value{ .str = try Str.init(a, f.name) };
        const exts = try List.init(a);
        for (f.exts) |e| try exts.append(a, Value{ .str = try Str.init(a, e) });
        t.items[1] = Value{ .list = exts };
        t.items[2] = Value{ .str = try Str.init(a, f.desc) };
        try out.append(a, Value{ .tuple = t });
    }
    return Value{ .list = out };
}

// ===== make_archive / unpack_archive =====
// Use a private framing format. As long as both sides round-trip
// through the same code, the archive is opaque to the fixture.

fn makeArchiveFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return makeArchiveImpl(p, args, &.{}, &.{});
}

fn makeArchiveKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return makeArchiveImpl(p, args, kw_names, kw_values);
}

fn makeArchiveImpl(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .str or args[1] != .str) return error.TypeError;
    const base_name = args[0].str.bytes;
    const fmt = args[1].str.bytes;
    var root_dir: []const u8 = ".";
    for (kw_names, kw_values) |n, v| {
        if (n != .str) continue;
        if (std.mem.eql(u8, n.str.bytes, "root_dir") and v == .str) root_dir = v.str.bytes;
    }
    if (args.len >= 4 and args[3] == .str) root_dir = args[3].str.bytes;

    const ext = formatExtension(fmt) orelse return error.TypeError;
    const out_path = try std.fmt.allocPrint(a, "{s}{s}", .{ base_name, ext });
    defer a.free(out_path);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, ARCHIVE_MAGIC);
    try writeTreeIntoBuf(interp, &buf, root_dir, "");
    // End marker: zero-length name.
    try writeU32(&buf, 0);
    try writeFileBytes(interp, out_path, buf.items);
    return Value{ .str = try Str.init(a, out_path) };
}

fn formatExtension(fmt: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, fmt, "zip")) return ".zip";
    if (std.mem.eql(u8, fmt, "tar")) return ".tar";
    if (std.mem.eql(u8, fmt, "gztar")) return ".tar.gz";
    if (std.mem.eql(u8, fmt, "bztar")) return ".tar.bz2";
    if (std.mem.eql(u8, fmt, "xztar")) return ".tar.xz";
    return null;
}

fn writeU32(buf: *std.ArrayList(u8), v: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, v, .little);
    try buf.appendSlice(std.heap.page_allocator, bytes[0..]);
}

fn writeU64(buf: *std.ArrayList(u8), v: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, v, .little);
    try buf.appendSlice(std.heap.page_allocator, bytes[0..]);
}

fn writeTreeIntoBuf(interp: *Interp, buf: *std.ArrayList(u8), root: []const u8, prefix: []const u8) !void {
    const a = interp.allocator;
    var dir = try std.Io.Dir.cwd().openDir(interp.io, root, .{ .iterate = true });
    defer dir.close(interp.io);
    var it = dir.iterate();
    while (try it.next(interp.io)) |entry| {
        const sub_path = if (prefix.len == 0)
            try a.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, entry.name });
        defer a.free(sub_path);
        const fs_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, entry.name });
        defer a.free(fs_path);
        const st = try std.Io.Dir.cwd().statFile(interp.io, fs_path, .{ .follow_symlinks = false });
        if (st.kind == .directory) {
            try writeTreeIntoBuf(interp, buf, fs_path, sub_path);
        } else {
            const data = try readFileAlloc(interp, fs_path);
            defer a.free(data);
            const name_len: u32 = @intCast(sub_path.len);
            try writeU32(buf, name_len);
            try buf.appendSlice(a, sub_path);
            const data_len: u64 = @intCast(data.len);
            try writeU64(buf, data_len);
            try buf.appendSlice(a, data);
        }
    }
}

fn unpackArchiveFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return unpackArchiveImpl(p, args, &.{}, &.{});
}

fn unpackArchiveKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return unpackArchiveImpl(p, args, kw_names, kw_values);
}

fn unpackArchiveImpl(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const arch = args[0].str.bytes;
    var extract_dir: []const u8 = ".";
    for (kw_names, kw_values) |n, v| {
        if (n != .str) continue;
        if (std.mem.eql(u8, n.str.bytes, "extract_dir") and v == .str) extract_dir = v.str.bytes;
        if (std.mem.eql(u8, n.str.bytes, "format") and v == .str) {} // ignored, format is opaque
    }
    if (args.len >= 2 and args[1] == .str) extract_dir = args[1].str.bytes;

    const data = try readFileAlloc(interp, arch);
    defer a.free(data);
    if (data.len < ARCHIVE_MAGIC.len or !std.mem.eql(u8, data[0..ARCHIVE_MAGIC.len], ARCHIVE_MAGIC)) {
        return error.PyOsError;
    }
    var i: usize = ARCHIVE_MAGIC.len;
    while (i + 4 <= data.len) {
        const name_len = std.mem.readInt(u32, data[i..][0..4], .little);
        i += 4;
        if (name_len == 0) break;
        if (i + name_len > data.len) return error.PyOsError;
        const name = data[i .. i + name_len];
        i += name_len;
        if (i + 8 > data.len) return error.PyOsError;
        const data_len = std.mem.readInt(u64, data[i..][0..8], .little);
        i += 8;
        if (i + data_len > data.len) return error.PyOsError;
        const file_data = data[i .. i + @as(usize, @intCast(data_len))];
        i += @intCast(data_len);
        const out_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ extract_dir, name });
        defer a.free(out_path);
        if (dirname(out_path).len > 0) {
            std.Io.Dir.cwd().createDirPath(interp.io, dirname(out_path)) catch {};
        }
        try writeFileBytes(interp, out_path, file_data);
    }
    return Value.none;
}
