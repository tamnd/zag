//! Pinhole `os` + `os.path`: enough surface for the fixtures.
//! Most of the path helpers are pure string transforms; the
//! filesystem-touching ones go through `interp.io`.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Tuple = @import("../object/tuple.zig").Tuple;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "os");

    try reg(interp, m, "remove", removeFn);
    try reg(interp, m, "unlink", removeFn);
    try reg(interp, m, "getcwd", getcwdFn);
    try reg(interp, m, "symlink", symlinkFn);
    try reg(interp, m, "stat", statFn);
    try reg(interp, m, "lstat", lstatFn);
    try reg(interp, m, "fspath", fspathFn);

    // os.environ: a regular dict, seeded from the host env once.
    const env = try Dict.init(a);
    if (interp.env_map) |em| {
        var it = em.iterator();
        while (it.next()) |entry| {
            const k = try Str.init(a, entry.key_ptr.*);
            const v = try Str.init(a, entry.value_ptr.*);
            try env.setKey(a, Value{ .str = k }, Value{ .str = v });
        }
    }
    try m.attrs.setStr(a, "environ", Value{ .dict = env });

    const path = try buildPath(interp);
    interp.os_path_module = path;
    try m.attrs.setStr(a, "path", Value{ .module = path });

    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

// ===== os.* =====

fn removeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("os.remove expects a path");
        return error.TypeError;
    }
    std.Io.Dir.cwd().deleteFile(interp.io, args[0].str.bytes) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", args[0].str.bytes);
            return error.PyException;
        },
        else => return err,
    };
    return Value.none;
}

fn getcwdFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    var buf: [4096]u8 = undefined;
    const n = try std.process.currentPath(interp.io, &buf);
    return Value{ .str = try Str.init(interp.allocator, buf[0..n]) };
}

fn symlinkFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str or args[1] != .str) {
        try interp.typeError("os.symlink expects (src, dst)");
        return error.TypeError;
    }
    try std.Io.Dir.cwd().symLink(interp.io, args[0].str.bytes, args[1].str.bytes, .{});
    return Value.none;
}

fn statFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return doStat(p, args, true);
}

fn lstatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return doStat(p, args, false);
}

fn doStat(p: *anyopaque, args: []const Value, follow: bool) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("os.stat expects a path");
        return error.TypeError;
    }
    const a = interp.allocator;
    const path = args[0].str.bytes;
    const opts: std.Io.Dir.StatFileOptions = .{ .follow_symlinks = follow };
    const st = std.Io.Dir.cwd().statFile(interp.io, path, opts) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", path);
            return error.PyException;
        },
        else => return err,
    };
    try ensureStatResultClass(interp);
    const inst = try Instance.init(a, interp.os_stat_result_class.?);
    var mode: i64 = 0o644;
    switch (st.kind) {
        .directory => mode |= 0o040000,
        .sym_link => mode |= 0o120000,
        else => mode |= 0o100000,
    }
    try inst.dict.setStr(a, "st_mode", Value{ .small_int = mode });
    try inst.dict.setStr(a, "st_size", Value{ .small_int = @intCast(st.size) });
    try inst.dict.setStr(a, "st_ino", Value{ .small_int = inodeToInt(st.inode) });
    try inst.dict.setStr(a, "st_nlink", Value{ .small_int = @intCast(st.nlink) });
    try inst.dict.setStr(a, "st_uid", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "st_gid", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "st_dev", Value{ .small_int = 0 });
    const mtime_s: f64 = @floatFromInt(st.mtime.toSeconds());
    const atime_s: f64 = if (st.atime) |t| @floatFromInt(t.toSeconds()) else mtime_s;
    const ctime_s: f64 = @floatFromInt(st.ctime.toSeconds());
    try inst.dict.setStr(a, "st_atime", Value{ .float = atime_s });
    try inst.dict.setStr(a, "st_mtime", Value{ .float = mtime_s });
    try inst.dict.setStr(a, "st_ctime", Value{ .float = ctime_s });
    return Value{ .instance = inst };
}

fn inodeToInt(ino: anytype) i64 {
    // INode varies by platform (u64 on Linux, signed on Windows).
    // Mask to small_int's positive range so the value round-trips.
    const T = @TypeOf(ino);
    if (@typeInfo(T).int.signedness == .unsigned) {
        const u: u64 = @intCast(ino);
        return @intCast(u & ((@as(u64, 1) << 62) - 1));
    } else {
        const i: i64 = @intCast(ino);
        return if (i < 0) -i else i;
    }
}

fn ensureStatResultClass(interp: *Interp) !void {
    if (interp.os_stat_result_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const cls = try Class.init(a, "stat_result", &.{}, d);
    interp.os_stat_result_class = cls;
}

fn fspathFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) {
        try interp.typeError("os.fspath expects 1 arg");
        return error.TypeError;
    }
    if (args[0] == .str) return args[0];
    if (args[0] == .instance) {
        if (args[0].instance.cls.dict.getStr("__fspath__")) |fn_v| {
            const r = try @import("dispatch.zig").invoke(interp, fn_v, args[0..1]);
            return r;
        }
    }
    try interp.typeError("os.fspath: argument must be str or path-like");
    return error.TypeError;
}

// ===== os.path =====

fn buildPath(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "os.path");

    // String constants.
    try setStrAttr(a, m, "sep", "/");
    try m.attrs.setStr(a, "altsep", Value.none);
    try setStrAttr(a, m, "curdir", ".");
    try setStrAttr(a, m, "pardir", "..");
    try setStrAttr(a, m, "extsep", ".");
    try setStrAttr(a, m, "pathsep", ":");
    try setStrAttr(a, m, "defpath", "/bin:/usr/bin");
    try setStrAttr(a, m, "devnull", "/dev/null");
    try m.attrs.setStr(a, "supports_unicode_filenames", Value{ .boolean = true });

    try reg(interp, m, "isabs", isabsFn);
    try reg(interp, m, "abspath", abspathFn);
    try reg(interp, m, "basename", basenameFn);
    try reg(interp, m, "dirname", dirnameFn);
    try reg(interp, m, "split", splitFn);
    try reg(interp, m, "splitext", splitextFn);
    try reg(interp, m, "splitdrive", splitdriveFn);
    try reg(interp, m, "splitroot", splitrootFn);
    try reg(interp, m, "join", joinFn);
    try reg(interp, m, "normpath", normpathFn);
    try reg(interp, m, "normcase", normcaseFn);
    try reg(interp, m, "commonprefix", commonprefixFn);
    try reg(interp, m, "commonpath", commonpathFn);
    try reg(interp, m, "relpath", relpathFn);
    try reg(interp, m, "expandvars", expandvarsFn);
    try reg(interp, m, "expanduser", expanduserFn);
    try reg(interp, m, "exists", existsFn);
    try reg(interp, m, "lexists", lexistsFn);
    try reg(interp, m, "isfile", isfileFn);
    try reg(interp, m, "isdir", isdirFn);
    try reg(interp, m, "islink", islinkFn);
    try reg(interp, m, "ismount", ismountFn);
    try reg(interp, m, "isjunction", isjunctionFn);
    try reg(interp, m, "getsize", getsizeFn);
    try reg(interp, m, "getmtime", getmtimeFn);
    try reg(interp, m, "getatime", getatimeFn);
    try reg(interp, m, "getctime", getctimeFn);
    try reg(interp, m, "samefile", samefileFn);
    try reg(interp, m, "samestat", samestatFn);
    try reg(interp, m, "realpath", realpathFn);

    return m;
}

fn setStrAttr(a: std.mem.Allocator, m: *Module, name: []const u8, val: []const u8) !void {
    const s = try Str.init(a, val);
    try m.attrs.setStr(a, name, Value{ .str = s });
}

fn argStr(interp: *Interp, args: []const Value, idx: usize, fname: []const u8) ![]const u8 {
    if (args.len <= idx or args[idx] != .str) {
        try interp.typeError(fname);
        return error.TypeError;
    }
    return args[idx].str.bytes;
}

// --- pure string ops ---

fn isabsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try argStr(interp, args, 0, "os.path.isabs: str");
    return Value{ .boolean = s.len > 0 and s[0] == '/' };
}

fn abspathFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const s = try argStr(interp, args, 0, "os.path.abspath: str");
    if (s.len > 0 and s[0] == '/') {
        const norm = try normalizePath(a, s);
        return Value{ .str = try Str.fromOwnedSlice(a, norm) };
    }
    var cwd_buf: [4096]u8 = undefined;
    const n = try std.process.currentPath(interp.io, &cwd_buf);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, cwd_buf[0..n]);
    if (out.items.len == 0 or out.items[out.items.len - 1] != '/') try out.append(a, '/');
    try out.appendSlice(a, s);
    const norm = try normalizePath(a, out.items);
    return Value{ .str = try Str.fromOwnedSlice(a, norm) };
}

fn basenameFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try argStr(interp, args, 0, "os.path.basename: str");
    const i = lastSlash(s);
    const tail = if (i) |k| s[k + 1 ..] else s;
    return Value{ .str = try Str.init(interp.allocator, tail) };
}

fn dirnameFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try argStr(interp, args, 0, "os.path.dirname: str");
    const i = lastSlash(s) orelse return Value{ .str = try Str.init(interp.allocator, "") };
    // Strip trailing slashes from head, but keep root '/' as '/'.
    var end = i;
    while (end > 0 and s[end - 1] == '/') end -= 1;
    if (end == 0 and s.len > 0 and s[0] == '/') end = 1;
    return Value{ .str = try Str.init(interp.allocator, s[0..end]) };
}

fn splitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const s = try argStr(interp, args, 0, "os.path.split: str");
    var head: []const u8 = "";
    var tail: []const u8 = s;
    if (lastSlash(s)) |i| {
        tail = s[i + 1 ..];
        var end = i;
        while (end > 0 and s[end - 1] == '/') end -= 1;
        if (end == 0 and s.len > 0 and s[0] == '/') end = 1;
        head = s[0..end];
    }
    const t = try Tuple.init(a, 2);
    t.items[0] = Value{ .str = try Str.init(a, head) };
    t.items[1] = Value{ .str = try Str.init(a, tail) };
    return Value{ .tuple = t };
}

fn splitextFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const s = try argStr(interp, args, 0, "os.path.splitext: str");
    // Find last '/'; ext search restricted to basename. Skip leading
    // dots (so '.bar' has no extension).
    const slash = lastSlash(s);
    const base_start: usize = if (slash) |k| k + 1 else 0;
    var i: usize = base_start;
    while (i < s.len and s[i] == '.') i += 1; // skip leading dots
    var dot: ?usize = null;
    var k: usize = i;
    while (k < s.len) : (k += 1) {
        if (s[k] == '.') dot = k;
    }
    var head: []const u8 = s;
    var ext: []const u8 = "";
    if (dot) |d| {
        head = s[0..d];
        ext = s[d..];
    }
    const t = try Tuple.init(a, 2);
    t.items[0] = Value{ .str = try Str.init(a, head) };
    t.items[1] = Value{ .str = try Str.init(a, ext) };
    return Value{ .tuple = t };
}

fn splitdriveFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const s = try argStr(interp, args, 0, "os.path.splitdrive: str");
    const t = try Tuple.init(a, 2);
    t.items[0] = Value{ .str = try Str.init(a, "") };
    t.items[1] = Value{ .str = try Str.init(a, s) };
    return Value{ .tuple = t };
}

fn splitrootFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const s = try argStr(interp, args, 0, "os.path.splitroot: str");
    var root: []const u8 = "";
    var rest: []const u8 = s;
    if (s.len >= 2 and s[0] == '/' and s[1] == '/' and (s.len < 3 or s[2] != '/')) {
        // POSIX double-slash special root.
        root = s[0..2];
        rest = s[2..];
    } else if (s.len > 0 and s[0] == '/') {
        root = "/";
        rest = s[1..];
        while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    }
    const t = try Tuple.init(a, 3);
    t.items[0] = Value{ .str = try Str.init(a, "") };
    t.items[1] = Value{ .str = try Str.init(a, root) };
    t.items[2] = Value{ .str = try Str.init(a, rest) };
    return Value{ .tuple = t };
}

fn joinFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for (args) |arg| {
        if (arg != .str) continue;
        const s = arg.str.bytes;
        if (s.len > 0 and s[0] == '/') {
            out.clearRetainingCapacity();
            try out.appendSlice(a, s);
        } else if (s.len == 0) {
            // CPython: empty trailing component leaves a trailing slash
            // if there isn't one already.
            if (out.items.len > 0 and out.items[out.items.len - 1] != '/') {
                try out.append(a, '/');
            }
        } else if (out.items.len == 0 or out.items[out.items.len - 1] == '/') {
            try out.appendSlice(a, s);
        } else {
            try out.append(a, '/');
            try out.appendSlice(a, s);
        }
    }
    return Value{ .str = try Str.init(a, out.items) };
}

fn normpathFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const s = try argStr(interp, args, 0, "os.path.normpath: str");
    const norm = try normalizePath(a, s);
    return Value{ .str = try Str.fromOwnedSlice(a, norm) };
}

fn normcaseFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try argStr(interp, args, 0, "os.path.normcase: str");
    return Value{ .str = try Str.init(interp.allocator, s) };
}

fn commonprefixFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return Value{ .str = try Str.init(a, "") };
    const items: []const Value = switch (args[0]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return Value{ .str = try Str.init(a, "") },
    };
    if (items.len == 0) return Value{ .str = try Str.init(a, "") };
    if (items[0] != .str) return Value{ .str = try Str.init(a, "") };
    var prefix: []const u8 = items[0].str.bytes;
    for (items[1..]) |it| {
        if (it != .str) {
            prefix = "";
            break;
        }
        const s = it.str.bytes;
        var i: usize = 0;
        while (i < prefix.len and i < s.len and prefix[i] == s[i]) : (i += 1) {}
        prefix = prefix[0..i];
    }
    return Value{ .str = try Str.init(a, prefix) };
}

fn commonpathFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.raisePy("ValueError", "commonpath() arg is an empty sequence");
        return error.PyException;
    }
    const items: []const Value = switch (args[0]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => {
            try interp.typeError("commonpath: expected list/tuple of str");
            return error.TypeError;
        },
    };
    if (items.len == 0) {
        try interp.raisePy("ValueError", "commonpath() arg is an empty sequence");
        return error.PyException;
    }
    var first_abs: ?bool = null;
    var split_lists: std.ArrayList([][]const u8) = .empty;
    defer {
        for (split_lists.items) |sl| a.free(sl);
        split_lists.deinit(a);
    }
    for (items) |it| {
        if (it != .str) {
            try interp.typeError("commonpath: items must be str");
            return error.TypeError;
        }
        const s = it.str.bytes;
        const abs = s.len > 0 and s[0] == '/';
        if (first_abs == null) first_abs = abs else if (first_abs.? != abs) {
            try interp.raisePy("ValueError", "Can't mix absolute and relative paths");
            return error.PyException;
        }
        const parts = try splitParts(a, s);
        try split_lists.append(a, parts);
    }
    var common: usize = std.math.maxInt(usize);
    for (split_lists.items) |sl| common = @min(common, sl.len);
    var prefix_len: usize = 0;
    while (prefix_len < common) : (prefix_len += 1) {
        const ref = split_lists.items[0][prefix_len];
        var ok = true;
        for (split_lists.items[1..]) |sl| {
            if (!std.mem.eql(u8, sl[prefix_len], ref)) {
                ok = false;
                break;
            }
        }
        if (!ok) break;
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    if (first_abs orelse false) try out.append(a, '/');
    var i: usize = 0;
    while (i < prefix_len) : (i += 1) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '/') try out.append(a, '/');
        try out.appendSlice(a, split_lists.items[0][i]);
    }
    if (out.items.len == 0) try out.append(a, '.');
    return Value{ .str = try Str.init(a, out.items) };
}

fn relpathFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const path = try argStr(interp, args, 0, "os.path.relpath: str");
    const start: []const u8 = if (args.len >= 2 and args[1] == .str) args[1].str.bytes else ".";
    const path_abs = try absolutize(interp, path);
    defer a.free(path_abs);
    const start_abs = try absolutize(interp, start);
    defer a.free(start_abs);
    const path_parts = try splitParts(a, path_abs);
    defer a.free(path_parts);
    const start_parts = try splitParts(a, start_abs);
    defer a.free(start_parts);
    var common: usize = 0;
    while (common < path_parts.len and common < start_parts.len and
        std.mem.eql(u8, path_parts[common], start_parts[common])) : (common += 1)
    {}
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var up: usize = start_parts.len - common;
    while (up > 0) : (up -= 1) {
        if (out.items.len > 0) try out.append(a, '/');
        try out.appendSlice(a, "..");
    }
    var k: usize = common;
    while (k < path_parts.len) : (k += 1) {
        if (out.items.len > 0) try out.append(a, '/');
        try out.appendSlice(a, path_parts[k]);
    }
    if (out.items.len == 0) try out.append(a, '.');
    return Value{ .str = try Str.init(a, out.items) };
}

fn expandvarsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const s = try argStr(interp, args, 0, "os.path.expandvars: str");
    const env_v = if (interp.os_module) |m| m.attrs.getStr("environ") else null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '$') {
            try out.append(a, s[i]);
            i += 1;
            continue;
        }
        // $VAR or ${VAR}.
        if (i + 1 < s.len and s[i + 1] == '{') {
            var j: usize = i + 2;
            while (j < s.len and s[j] != '}') : (j += 1) {}
            if (j >= s.len) {
                try out.appendSlice(a, s[i..]);
                break;
            }
            const name = s[i + 2 .. j];
            if (lookupEnv(env_v, name)) |val| {
                try out.appendSlice(a, val);
            } else {
                try out.appendSlice(a, s[i .. j + 1]);
            }
            i = j + 1;
        } else if (i + 1 < s.len and (std.ascii.isAlphabetic(s[i + 1]) or s[i + 1] == '_')) {
            var j: usize = i + 1;
            while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '_')) : (j += 1) {}
            const name = s[i + 1 .. j];
            if (lookupEnv(env_v, name)) |val| {
                try out.appendSlice(a, val);
            } else {
                try out.appendSlice(a, s[i..j]);
            }
            i = j;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return Value{ .str = try Str.init(a, out.items) };
}

fn lookupEnv(env_v: ?Value, name: []const u8) ?[]const u8 {
    const v = env_v orelse return null;
    if (v != .dict) return null;
    const got = v.dict.getStr(name) orelse return null;
    if (got != .str) return null;
    return got.str.bytes;
}

fn expanduserFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const s = try argStr(interp, args, 0, "os.path.expanduser: str");
    if (s.len == 0 or s[0] != '~') return Value{ .str = try Str.init(a, s) };
    if (s.len == 1) return Value{ .str = try Str.init(a, interp.home) };
    if (s[1] == '/') {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try out.appendSlice(a, interp.home);
        try out.appendSlice(a, s[1..]);
        return Value{ .str = try Str.init(a, out.items) };
    }
    return Value{ .str = try Str.init(a, s) };
}

// --- filesystem ops ---

fn existsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try argStr(interp, args, 0, "os.path.exists: str");
    _ = std.Io.Dir.cwd().statFile(interp.io, s, .{}) catch return Value{ .boolean = false };
    return Value{ .boolean = true };
}

fn lexistsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try argStr(interp, args, 0, "os.path.lexists: str");
    _ = std.Io.Dir.cwd().statFile(interp.io, s, .{ .follow_symlinks = false }) catch return Value{ .boolean = false };
    return Value{ .boolean = true };
}

fn isfileFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try argStr(interp, args, 0, "os.path.isfile: str");
    const st = std.Io.Dir.cwd().statFile(interp.io, s, .{}) catch return Value{ .boolean = false };
    return Value{ .boolean = st.kind == .file };
}

fn isdirFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try argStr(interp, args, 0, "os.path.isdir: str");
    const st = std.Io.Dir.cwd().statFile(interp.io, s, .{}) catch return Value{ .boolean = false };
    return Value{ .boolean = st.kind == .directory };
}

fn islinkFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try argStr(interp, args, 0, "os.path.islink: str");
    const st = std.Io.Dir.cwd().statFile(interp.io, s, .{ .follow_symlinks = false }) catch return Value{ .boolean = false };
    return Value{ .boolean = st.kind == .sym_link };
}

fn ismountFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const s = try argStr(interp, args, 0, "os.path.ismount: str");
    if (s.len == 0) return Value{ .boolean = false };
    // Trivial test: '/' (and only '/') is a mount point.
    if (std.mem.eql(u8, s, "/")) return Value{ .boolean = true };
    // Otherwise: dirname after normalization equals path.
    const norm = try normalizePath(a, s);
    defer a.free(norm);
    if (std.mem.eql(u8, norm, "/")) return Value{ .boolean = true };
    return Value{ .boolean = false };
}

fn isjunctionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value{ .boolean = false };
}

fn getsizeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try argStr(interp, args, 0, "os.path.getsize: str");
    const st = std.Io.Dir.cwd().statFile(interp.io, s, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", s);
            return error.PyException;
        },
        else => return err,
    };
    return Value{ .small_int = @intCast(st.size) };
}

fn getmtimeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return getTimeImpl(p, args, .mtime);
}

fn getatimeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return getTimeImpl(p, args, .atime);
}

fn getctimeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return getTimeImpl(p, args, .ctime);
}

const TimeKind = enum { atime, mtime, ctime };

fn getTimeImpl(p: *anyopaque, args: []const Value, k: TimeKind) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try argStr(interp, args, 0, "os.path.getXtime: str");
    const st = std.Io.Dir.cwd().statFile(interp.io, s, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", s);
            return error.PyException;
        },
        else => return err,
    };
    const ts = switch (k) {
        .mtime => st.mtime,
        .atime => st.atime orelse st.mtime,
        .ctime => st.ctime,
    };
    const seconds: f64 = @floatFromInt(ts.toSeconds());
    return Value{ .float = seconds };
}

fn samefileFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a_path = try argStr(interp, args, 0, "os.path.samefile: str, str");
    const b_path = try argStr(interp, args, 1, "os.path.samefile: str, str");
    const sa = std.Io.Dir.cwd().statFile(interp.io, a_path, .{}) catch return Value{ .boolean = false };
    const sb = std.Io.Dir.cwd().statFile(interp.io, b_path, .{}) catch return Value{ .boolean = false };
    return Value{ .boolean = sa.inode == sb.inode };
}

fn samestatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance or args[1] != .instance) {
        try interp.typeError("os.path.samestat: stat_result, stat_result");
        return error.TypeError;
    }
    const ai = args[0].instance.dict.getStr("st_ino") orelse return Value{ .boolean = false };
    const bi = args[1].instance.dict.getStr("st_ino") orelse return Value{ .boolean = false };
    if (ai != .small_int or bi != .small_int) return Value{ .boolean = false };
    return Value{ .boolean = ai.small_int == bi.small_int };
}

fn realpathFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const s = try argStr(interp, args, 0, "os.path.realpath: str");
    var current = try absolutize(interp, s);
    defer a.free(current);
    var hops: usize = 0;
    while (hops < 40) : (hops += 1) {
        const st = std.Io.Dir.cwd().statFile(interp.io, current, .{ .follow_symlinks = false }) catch break;
        if (st.kind != .sym_link) break;
        var buf: [4096]u8 = undefined;
        const n = std.Io.Dir.cwd().readLink(interp.io, current, &buf) catch break;
        const target = buf[0..n];
        if (target.len > 0 and target[0] == '/') {
            const norm = try normalizePath(a, target);
            a.free(current);
            current = norm;
        } else {
            // Resolve relative to dirname(current).
            var combined: std.ArrayList(u8) = .empty;
            defer combined.deinit(a);
            const slash = lastSlash(current);
            const head = if (slash) |k| current[0..k] else "";
            try combined.appendSlice(a, head);
            try combined.append(a, '/');
            try combined.appendSlice(a, target);
            const norm = try normalizePath(a, combined.items);
            a.free(current);
            current = norm;
        }
    }
    return Value{ .str = try Str.init(a, current) };
}

// --- helpers ---

fn lastSlash(s: []const u8) ?usize {
    var i: usize = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] == '/') return i;
    }
    return null;
}

fn splitParts(a: std.mem.Allocator, s: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and s[i] == '/') i += 1;
        if (i >= s.len) break;
        const start = i;
        while (i < s.len and s[i] != '/') i += 1;
        try out.append(a, s[start..i]);
    }
    return try out.toOwnedSlice(a);
}

fn normalizePath(a: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len == 0) return try a.dupe(u8, ".");
    const is_abs = s[0] == '/';
    const parts = try splitParts(a, s);
    defer a.free(parts);
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(a);
    for (parts) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (stack.items.len > 0 and !std.mem.eql(u8, stack.items[stack.items.len - 1], "..")) {
                _ = stack.pop();
            } else if (!is_abs) {
                try stack.append(a, part);
            }
            continue;
        }
        try stack.append(a, part);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    if (is_abs) try out.append(a, '/');
    for (stack.items, 0..) |part, i| {
        if (i > 0) try out.append(a, '/');
        try out.appendSlice(a, part);
    }
    if (out.items.len == 0) try out.append(a, '.');
    return try out.toOwnedSlice(a);
}

fn absolutize(interp: *Interp, s: []const u8) ![]u8 {
    const a = interp.allocator;
    if (s.len > 0 and s[0] == '/') return try normalizePath(a, s);
    var cwd_buf: [4096]u8 = undefined;
    const n = try std.process.currentPath(interp.io, &cwd_buf);
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(a);
    try combined.appendSlice(a, cwd_buf[0..n]);
    if (combined.items.len == 0 or combined.items[combined.items.len - 1] != '/') try combined.append(a, '/');
    try combined.appendSlice(a, s);
    return try normalizePath(a, combined.items);
}
