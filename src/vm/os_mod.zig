//! Pinhole `os` + `os.path`: enough surface for the fixtures.
//! Most of the path helpers are pure string transforms; the
//! filesystem-touching ones go through `interp.io`.

const std = @import("std");
const builtin = @import("builtin");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Tuple = @import("../object/tuple.zig").Tuple;
const List = @import("../object/list.zig").List;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Bytes = @import("../object/bytes.zig").Bytes;
const interp_mod = @import("interp.zig");
const Interp = interp_mod.Interp;
const OsFd = interp_mod.OsFd;
const OsFdPos = interp_mod.OsFdPos;

// Platform O_ flags.
const O_RDONLY: i64 = 0;
const O_WRONLY: i64 = 1;
const O_RDWR: i64 = 2;
const O_CREAT: i64 = if (builtin.os.tag == .macos) 0o200 else 64;
const O_TRUNC: i64 = if (builtin.os.tag == .macos) 0o1000 else 512;
const O_APPEND: i64 = if (builtin.os.tag == .macos) 0o10 else 1024;
const SEEK_SET: i64 = 0;
const SEEK_CUR: i64 = 1;
const SEEK_END: i64 = 2;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "os");

    try reg(interp, m, "remove", removeFn);
    try reg(interp, m, "unlink", removeFn);
    try reg(interp, m, "getcwd", getcwdFn);
    try reg(interp, m, "symlink", symlinkFn);
    try reg(interp, m, "stat", statFn);
    try reg(interp, m, "lstat", lstatFn);
    try reg(interp, m, "fstat", fstatFn);
    try reg(interp, m, "fspath", fspathFn);
    try reg(interp, m, "mkdir", mkdirFn);
    try reg(interp, m, "rmdir", rmdirFn);
    try regKw(interp, m, "makedirs", makedirsFn, makedirsKwFn);
    try reg(interp, m, "chdir", chdirFn);
    try reg(interp, m, "listdir", listdirFn);
    try reg(interp, m, "close", closeFn);
    try reg(interp, m, "chmod", chmodFn);
    try reg(interp, m, "rename", renameFn);
    try reg(interp, m, "replace", replaceFn);
    try reg(interp, m, "link", linkFn);
    try reg(interp, m, "truncate", truncateFn);
    try reg(interp, m, "access", accessFn);
    try reg(interp, m, "umask", umaskFn);
    try reg(interp, m, "getgid", getgidFn);
    try reg(interp, m, "getegid", getegidFn);
    try reg(interp, m, "geteuid", getEuidFn);
    try reg(interp, m, "getuid", getuidFn);
    try reg(interp, m, "getppid", getppidFn);
    try reg(interp, m, "cpu_count", cpuCountFn);
    try reg(interp, m, "strerror", strerrorFn);
    try reg(interp, m, "urandom", urandomFn);
    try reg(interp, m, "fsencode", fsencodeFn);
    try reg(interp, m, "fsdecode", fsdecodeFn);
    try reg(interp, m, "get_exec_path", getExecPathFn);
    try reg(interp, m, "walk", walkFn);
    try reg(interp, m, "scandir", scandirFn);
    // low-level fd ops
    try reg(interp, m, "open", osOpenFn);
    try reg(interp, m, "read", osReadFn);
    try reg(interp, m, "write", osWriteFn);
    try reg(interp, m, "lseek", osLseekFn);
    try reg(interp, m, "dup", osDupFn);

    // constants
    try m.attrs.setStr(a, "F_OK", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "R_OK", Value{ .small_int = 4 });
    try m.attrs.setStr(a, "W_OK", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "X_OK", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "O_RDONLY", Value{ .small_int = O_RDONLY });
    try m.attrs.setStr(a, "O_WRONLY", Value{ .small_int = O_WRONLY });
    try m.attrs.setStr(a, "O_RDWR", Value{ .small_int = O_RDWR });
    try m.attrs.setStr(a, "O_CREAT", Value{ .small_int = O_CREAT });
    try m.attrs.setStr(a, "O_TRUNC", Value{ .small_int = O_TRUNC });
    try m.attrs.setStr(a, "O_APPEND", Value{ .small_int = O_APPEND });
    try m.attrs.setStr(a, "SEEK_SET", Value{ .small_int = SEEK_SET });
    try m.attrs.setStr(a, "SEEK_CUR", Value{ .small_int = SEEK_CUR });
    try m.attrs.setStr(a, "SEEK_END", Value{ .small_int = SEEK_END });
    try m.attrs.setStr(a, "sep", Value{ .str = try Str.init(a, "/") });
    try m.attrs.setStr(a, "linesep", Value{ .str = try Str.init(a, "\n") });
    try m.attrs.setStr(a, "curdir", Value{ .str = try Str.init(a, ".") });
    try m.attrs.setStr(a, "pardir", Value{ .str = try Str.init(a, "..") });
    try m.attrs.setStr(a, "extsep", Value{ .str = try Str.init(a, ".") });
    try m.attrs.setStr(a, "pathsep", Value{ .str = try Str.init(a, ":") });
    try m.attrs.setStr(a, "devnull", Value{ .str = try Str.init(a, "/dev/null") });
    try m.attrs.setStr(a, "name", Value{ .str = try Str.init(a, "posix") });

    // os.environ: a regular dict, seeded from the host env once.
    const env = try Dict.init(a);
    if (interp.env_map) |em| {
        var it = em.iterator();
        while (it.next()) |entry| {
            const k = try Str.init(a, entry.key_ptr.*);
            const v = try Str.init(a, entry.value_ptr.*);
            try env.setKey(a, Value{ .str = k }, Value{ .str = v });
        }
    } else if (builtin.os.tag != .windows) {
        // Fallback: read the C environ pointer directly when no env_map is provided.
        const CEnv = struct {
            extern var environ: [*:null]?[*:0]u8;
        };
        var i: usize = 0;
        while (CEnv.environ[i]) |entry| : (i += 1) {
            const s = std.mem.span(entry);
            if (std.mem.indexOf(u8, s, "=")) |eq| {
                const k = try Str.init(a, s[0..eq]);
                const v = try Str.init(a, s[eq + 1 ..]);
                try env.setKey(a, Value{ .str = k }, Value{ .str = v });
            }
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

fn regKw(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
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

fn mkdirFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("os.mkdir expects a path");
        return error.TypeError;
    }
    std.Io.Dir.cwd().createDir(interp.io, args[0].str.bytes, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try interp.raisePy("FileExistsError", args[0].str.bytes);
            return error.PyException;
        },
        else => return err,
    };
    return Value.none;
}

fn makedirsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return makedirsImpl(p, args, false);
}

fn makedirsKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    var exist_ok = false;
    for (kw_names, kw_values) |k, v| {
        if (k == .str and std.mem.eql(u8, k.str.bytes, "exist_ok")) {
            exist_ok = v == .boolean and v.boolean;
        }
    }
    return makedirsImpl(p, args, exist_ok);
}

fn makedirsImpl(p: *anyopaque, args: []const Value, exist_ok: bool) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("os.makedirs expects a path");
        return error.TypeError;
    }
    const path = args[0].str.bytes;
    const status = std.Io.Dir.cwd().createDirPathStatus(interp.io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            if (!exist_ok) {
                try interp.raisePy("FileExistsError", path);
                return error.PyException;
            }
            return Value.none;
        },
        else => return err,
    };
    if (status == .existed and !exist_ok) {
        try interp.raisePy("FileExistsError", path);
        return error.PyException;
    }
    return Value.none;
}

fn chdirFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("os.chdir expects a path");
        return error.TypeError;
    }
    try std.process.setCurrentPath(interp.io, args[0].str.bytes);
    return Value.none;
}

fn listdirFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const path: []const u8 = if (args.len >= 1 and args[0] == .str) args[0].str.bytes else ".";
    var dir = std.Io.Dir.cwd().openDir(interp.io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", path);
            return error.PyException;
        },
        else => return err,
    };
    defer dir.close(interp.io);
    const list_mod = @import("../object/list.zig");
    const list = try list_mod.List.init(a);
    var it = dir.iterate();
    while (try it.next(interp.io)) |entry| {
        const name = try a.dupe(u8, entry.name);
        try list.items.append(a, Value{ .str = try Str.fromOwnedSlice(a, name) });
    }
    return Value{ .list = list };
}

fn replaceFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str or args[1] != .str) {
        try interp.typeError("os.replace expects (src, dst)");
        return error.TypeError;
    }
    const cwd = std.Io.Dir.cwd();
    cwd.rename(args[0].str.bytes, cwd, args[1].str.bytes, interp.io) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", args[0].str.bytes);
            return error.PyException;
        },
        else => return err,
    };
    return Value.none;
}

fn linkFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str or args[1] != .str) {
        try interp.typeError("os.link expects (src, dst)");
        return error.TypeError;
    }
    const cwd = std.Io.Dir.cwd();
    try cwd.hardLink(args[0].str.bytes, cwd, args[1].str.bytes, interp.io, .{});
    return Value.none;
}

fn truncateFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str or args[1] != .small_int) {
        try interp.typeError("os.truncate expects (path, length)");
        return error.TypeError;
    }
    const path = args[0].str.bytes;
    const size: u64 = @intCast(args[1].small_int);
    var f = try std.Io.Dir.cwd().openFile(interp.io, path, .{ .mode = .read_write });
    defer f.close(interp.io);
    try f.setLength(interp.io, size);
    return Value.none;
}

fn posixUmask(mask: u32) u32 {
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.syscall1(.umask, mask));
    } else {
        return @intCast(std.c.umask(@intCast(mask)));
    }
}

fn posixGetuid() u32 {
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getuid());
    } else {
        return @intCast(std.c.getuid());
    }
}

fn posixGetgid() u32 {
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getgid());
    } else {
        return @intCast(std.c.getgid());
    }
}

fn posixGeteuid() u32 {
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.geteuid());
    } else {
        return @intCast(std.c.geteuid());
    }
}

fn posixGetegid() u32 {
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getegid());
    } else {
        return @intCast(std.c.getegid());
    }
}

fn umaskFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = interp;
    if (args.len < 1 or args[0] != .small_int) return Value{ .small_int = 0 };
    if (builtin.os.tag == .windows) return Value{ .small_int = 0 };
    const mask: u32 = @intCast(args[0].small_int & 0o777);
    const old = posixUmask(mask);
    return Value{ .small_int = @intCast(old) };
}

fn getgidFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    if (builtin.os.tag == .windows) return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(posixGetgid()) };
}

fn getegidFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    if (builtin.os.tag == .windows) return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(posixGetegid()) };
}

fn getEuidFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    if (builtin.os.tag == .windows) return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(posixGeteuid()) };
}

fn getuidFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    if (builtin.os.tag == .windows) return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(posixGetuid()) };
}

fn getppidFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    if (builtin.os.tag == .windows) return Value{ .small_int = 1 };
    return Value{ .small_int = @intCast(std.posix.getppid()) };
}

fn cpuCountFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    const n = std.Thread.getCpuCount() catch return Value.none;
    return Value{ .small_int = @intCast(n) };
}

fn strerrorMsg(n: i64) []const u8 {
    // Common POSIX errno values (Linux/macOS compatible).
    return switch (n) {
        1 => "Operation not permitted",
        2 => "No such file or directory",
        3 => "No such process",
        4 => "Interrupted system call",
        5 => "Input/output error",
        6 => "No such device or address",
        7 => "Argument list too long",
        8 => "Exec format error",
        9 => "Bad file descriptor",
        10 => "No child processes",
        11 => "Resource temporarily unavailable",
        12 => "Cannot allocate memory",
        13 => "Permission denied",
        14 => "Bad address",
        16 => "Device or resource busy",
        17 => "File exists",
        18 => "Invalid cross-device link",
        19 => "No such device",
        20 => "Not a directory",
        21 => "Is a directory",
        22 => "Invalid argument",
        23 => "Too many open files in system",
        24 => "Too many open files",
        25 => "Inappropriate ioctl for device",
        26 => "Text file busy",
        27 => "File too large",
        28 => "No space left on device",
        29 => "Illegal seek",
        30 => "Read-only file system",
        31 => "Too many links",
        32 => "Broken pipe",
        33 => "Numerical argument out of domain",
        34 => "Numerical result out of range",
        35 => "Resource deadlock avoided",
        36 => "File name too long",
        37 => "No locks available",
        38 => "Function not implemented",
        39 => "Directory not empty",
        40 => "Too many levels of symbolic links",
        else => "Unknown error",
    };
}

fn strerrorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .small_int) {
        try interp.typeError("os.strerror expects an int");
        return error.TypeError;
    }
    return Value{ .str = try Str.init(a, strerrorMsg(args[0].small_int)) };
}

fn fillRandom(buf: []u8) void {
    if (builtin.os.tag == .linux) {
        var offset: usize = 0;
        while (offset < buf.len) {
            const n = std.os.linux.getrandom(buf.ptr + offset, buf.len - offset, 0);
            if (n > 0) offset += n;
        }
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

fn urandomFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .small_int) {
        try interp.typeError("os.urandom expects an int");
        return error.TypeError;
    }
    const n: usize = @intCast(args[0].small_int);
    const buf = try a.alloc(u8, n);
    fillRandom(buf);
    const b = try Bytes.fromOwnedSlice(a, buf);
    return Value{ .bytes = b };
}

fn fsencodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.typeError("os.fsencode expects a str or bytes");
        return error.TypeError;
    }
    if (args[0] == .bytes) return args[0];
    if (args[0] == .bytearray) {
        const data = try a.dupe(u8, args[0].bytearray.data.items);
        const b = try Bytes.fromOwnedSlice(a, data);
        return Value{ .bytes = b };
    }
    if (args[0] != .str) {
        try interp.typeError("os.fsencode expects str or bytes");
        return error.TypeError;
    }
    const data = try a.dupe(u8, args[0].str.bytes);
    const b = try Bytes.fromOwnedSlice(a, data);
    return Value{ .bytes = b };
}

fn fsdecodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.typeError("os.fsdecode expects bytes or str");
        return error.TypeError;
    }
    if (args[0] == .str) return args[0];
    const data: []const u8 = switch (args[0]) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        else => {
            try interp.typeError("os.fsdecode expects bytes or str");
            return error.TypeError;
        },
    };
    return Value{ .str = try Str.init(a, data) };
}

fn getExecPathFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = args;
    const list = try List.init(a);
    // Read PATH from os.environ or host env.
    const path_env: ?[]const u8 = blk: {
        if (interp.os_module) |m| {
            if (m.attrs.getStr("environ")) |env_v| {
                if (env_v == .dict) {
                    if (env_v.dict.getStr("PATH")) |v| {
                        if (v == .str) break :blk v.str.bytes;
                    }
                }
            }
        }
        if (interp.env_map) |em| {
            if (em.get("PATH")) |v| break :blk v;
        }
        break :blk null;
    };
    const pe = path_env orelse "/bin:/usr/bin";
    var it = std.mem.splitScalar(u8, pe, ':');
    while (it.next()) |part| {
        if (part.len > 0) {
            try list.items.append(a, Value{ .str = try Str.init(a, part) });
        }
    }
    return Value{ .list = list };
}

fn walkFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("os.walk expects a path");
        return error.TypeError;
    }
    const top = args[0].str.bytes;
    // Return a list of (root, dirs, files) tuples (eager walk).
    const result = try List.init(a);
    try walkDir(interp, result, top);
    return Value{ .list = result };
}

fn walkDir(interp: *Interp, result: *List, dir_path: []const u8) !void {
    const a = interp.allocator;
    var dir = std.Io.Dir.cwd().openDir(interp.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(interp.io);
    const sub_dirs = try List.init(a);
    const files = try List.init(a);
    var it = dir.iterate();
    while (try it.next(interp.io)) |entry| {
        const name_dup = try a.dupe(u8, entry.name);
        const name_val = Value{ .str = try Str.fromOwnedSlice(a, name_dup) };
        if (entry.kind == .directory) {
            try sub_dirs.items.append(a, name_val);
        } else {
            try files.items.append(a, name_val);
        }
    }
    const tup = try Tuple.init(a, 3);
    tup.items[0] = Value{ .str = try Str.init(a, dir_path) };
    tup.items[1] = Value{ .list = sub_dirs };
    tup.items[2] = Value{ .list = files };
    try result.items.append(a, Value{ .tuple = tup });
    for (sub_dirs.items.items) |sd| {
        if (sd != .str) continue;
        const child = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, sd.str.bytes });
        defer a.free(child);
        try walkDir(interp, result, child);
    }
}

fn scandirFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const path: []const u8 = if (args.len >= 1 and args[0] == .str) args[0].str.bytes else ".";
    try ensureDirEntryClass(interp);
    var dir = std.Io.Dir.cwd().openDir(interp.io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", path);
            return error.PyException;
        },
        else => return err,
    };
    defer dir.close(interp.io);
    const list = try List.init(a);
    var it = dir.iterate();
    while (try it.next(interp.io)) |entry| {
        const inst = try Instance.init(a, interp.os_direntry_class.?);
        const name_dup = try a.dupe(u8, entry.name);
        try inst.dict.setStr(a, "name", Value{ .str = try Str.fromOwnedSlice(a, name_dup) });
        const is_dir = entry.kind == .directory;
        try inst.dict.setStr(a, "_is_dir", Value{ .boolean = is_dir });
        try inst.dict.setStr(a, "_is_file", Value{ .boolean = entry.kind == .file });
        // Build full path for stat.
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ path, entry.name });
        try inst.dict.setStr(a, "_path", Value{ .str = try Str.fromOwnedSlice(a, full) });
        try list.items.append(a, Value{ .instance = inst });
    }
    return Value{ .list = list };
}

fn ensureDirEntryClass(interp: *Interp) !void {
    if (interp.os_direntry_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const is_dir_fn = try a.create(BuiltinFn);
    is_dir_fn.* = .{ .name = "is_dir", .func = direntryIsDirFn };
    try d.setStr(a, "is_dir", Value{ .builtin_fn = is_dir_fn });
    const is_file_fn = try a.create(BuiltinFn);
    is_file_fn.* = .{ .name = "is_file", .func = direntryIsFileFn };
    try d.setStr(a, "is_file", Value{ .builtin_fn = is_file_fn });
    interp.os_direntry_class = try Class.init(a, "DirEntry", &.{}, d);
}

fn direntryIsDirFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return Value{ .boolean = false };
    const v = args[0].instance.dict.getStr("_is_dir") orelse return Value{ .boolean = false };
    return v;
}

fn direntryIsFileFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return Value{ .boolean = false };
    const v = args[0].instance.dict.getStr("_is_file") orelse return Value{ .boolean = false };
    return v;
}

// --- low-level fd ops ---

fn osOpenFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("os.open expects (path, flags[, mode])");
        return error.TypeError;
    }
    const path = args[0].str.bytes;
    const flags: i64 = if (args.len >= 2 and args[1] == .small_int) args[1].small_int else 0;
    const writable = (flags & O_WRONLY) != 0 or (flags & O_RDWR) != 0;
    const create = (flags & O_CREAT) != 0;
    const trunc = (flags & O_TRUNC) != 0;
    const file = if (writable and create) blk: {
        break :blk try std.Io.Dir.cwd().createFile(interp.io, path, .{ .truncate = trunc });
    } else if (writable) blk: {
        break :blk try std.Io.Dir.cwd().openFile(interp.io, path, .{ .mode = .read_write });
    } else blk: {
        break :blk try std.Io.Dir.cwd().openFile(interp.io, path, .{});
    };
    const path_dup = try a.dupe(u8, path);
    const sp = try a.create(OsFdPos);
    sp.* = .{};
    const fd = interp.os_next_fd;
    interp.os_next_fd += 1;
    try interp.os_fd_table.put(a, fd, OsFd{ .file = file, .path = path_dup, .writable = writable, .shared_pos = sp });
    return Value{ .small_int = @intCast(fd) };
}

fn osReadFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .small_int or args[1] != .small_int) {
        try interp.typeError("os.read expects (fd, n)");
        return error.TypeError;
    }
    const fd: i32 = @intCast(args[0].small_int);
    const n: usize = @intCast(args[1].small_int);
    const entry = interp.os_fd_table.getPtr(fd) orelse {
        try interp.raisePy("OSError", "Bad file descriptor");
        return error.PyException;
    };
    const buf = try a.alloc(u8, n);
    const nread = try entry.file.readPositionalAll(interp.io, buf, entry.shared_pos.pos);
    entry.shared_pos.pos += nread;
    const owned = try a.realloc(buf, nread);
    const b = try Bytes.fromOwnedSlice(a, owned);
    return Value{ .bytes = b };
}

fn osWriteFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .small_int) {
        try interp.typeError("os.write expects (fd, data)");
        return error.TypeError;
    }
    const fd: i32 = @intCast(args[0].small_int);
    const data: []const u8 = switch (args[1]) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        else => {
            try interp.typeError("os.write: data must be bytes");
            return error.TypeError;
        },
    };
    const entry = interp.os_fd_table.getPtr(fd) orelse {
        try interp.raisePy("OSError", "Bad file descriptor");
        return error.PyException;
    };
    try entry.file.writePositionalAll(interp.io, data, entry.shared_pos.pos);
    entry.shared_pos.pos += data.len;
    return Value{ .small_int = @intCast(data.len) };
}

fn osLseekFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 3 or args[0] != .small_int or args[1] != .small_int or args[2] != .small_int) {
        try interp.typeError("os.lseek expects (fd, pos, how)");
        return error.TypeError;
    }
    const fd: i32 = @intCast(args[0].small_int);
    const pos: i64 = args[1].small_int;
    const how: i64 = args[2].small_int;
    const entry = interp.os_fd_table.getPtr(fd) orelse {
        try interp.raisePy("OSError", "Bad file descriptor");
        return error.PyException;
    };
    const new_pos: u64 = switch (how) {
        SEEK_SET => @intCast(pos),
        SEEK_CUR => @intCast(@as(i64, @intCast(entry.shared_pos.pos)) + pos),
        SEEK_END => blk: {
            const flen = try entry.file.length(interp.io);
            break :blk @intCast(@as(i64, @intCast(flen)) + pos);
        },
        else => {
            try interp.raisePy("ValueError", "invalid whence value");
            return error.PyException;
        },
    };
    entry.shared_pos.pos = new_pos;
    return Value{ .small_int = @intCast(new_pos) };
}

fn fstatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .small_int) {
        try interp.typeError("os.fstat expects an fd");
        return error.TypeError;
    }
    const fd: i32 = @intCast(args[0].small_int);
    const entry = interp.os_fd_table.getPtr(fd) orelse {
        try interp.raisePy("OSError", "Bad file descriptor");
        return error.PyException;
    };
    const st = try entry.file.stat(interp.io);
    try ensureStatResultClass(interp);
    const inst = try Instance.init(a, interp.os_stat_result_class.?);
    try inst.dict.setStr(a, "st_size", Value{ .small_int = @intCast(st.size) });
    try inst.dict.setStr(a, "st_mode", Value{ .small_int = 0o100644 });
    try inst.dict.setStr(a, "st_ino", Value{ .small_int = inodeToInt(st.inode) });
    try inst.dict.setStr(a, "st_nlink", Value{ .small_int = @intCast(st.nlink) });
    try inst.dict.setStr(a, "st_uid", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "st_gid", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "st_dev", Value{ .small_int = 0 });
    const mtime_s: f64 = @floatFromInt(st.mtime.toSeconds());
    try inst.dict.setStr(a, "st_atime", Value{ .float = mtime_s });
    try inst.dict.setStr(a, "st_mtime", Value{ .float = mtime_s });
    try inst.dict.setStr(a, "st_ctime", Value{ .float = mtime_s });
    return Value{ .instance = inst };
}

fn osDupFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .small_int) {
        try interp.typeError("os.dup expects an fd");
        return error.TypeError;
    }
    const fd: i32 = @intCast(args[0].small_int);
    const entry_ptr = interp.os_fd_table.getPtr(fd) orelse {
        try interp.raisePy("OSError", "Bad file descriptor");
        return error.PyException;
    };
    // New fd shares position with the original (POSIX semantics).
    const new_file = try std.Io.Dir.cwd().openFile(interp.io, entry_ptr.path, .{});
    const path_dup = try a.dupe(u8, entry_ptr.path);
    entry_ptr.shared_pos.refcount += 1;
    const sp = entry_ptr.shared_pos;
    const writable = entry_ptr.writable;
    const new_fd = interp.os_next_fd;
    interp.os_next_fd += 1;
    try interp.os_fd_table.put(a, new_fd, OsFd{
        .file = new_file,
        .path = path_dup,
        .writable = writable,
        .shared_pos = sp,
    });
    return Value{ .small_int = @intCast(new_fd) };
}

fn closeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len >= 1 and args[0] == .small_int) {
        const fd: i32 = @intCast(args[0].small_int);
        if (interp.os_fd_table.fetchRemove(fd)) |kv| {
            kv.value.file.close(interp.io);
            interp.allocator.free(kv.value.path);
            kv.value.shared_pos.refcount -= 1;
            if (kv.value.shared_pos.refcount == 0) {
                interp.allocator.destroy(kv.value.shared_pos);
            }
        }
    }
    return Value.none;
}

fn chmodFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str or args[1] != .small_int) {
        try interp.typeError("os.chmod expects (path, mode)");
        return error.TypeError;
    }
    if (@import("builtin").os.tag == .windows) {
        _ = std.Io.Dir.cwd().statFile(interp.io, args[0].str.bytes, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try interp.raisePy("FileNotFoundError", args[0].str.bytes);
                return error.PyException;
            },
            else => return err,
        };
        return Value.none;
    }
    const mode_i: i64 = args[1].small_int;
    const mode: std.posix.mode_t = @intCast(mode_i & 0o7777);
    const perms = std.Io.File.Permissions.fromMode(mode);
    std.Io.Dir.cwd().setFilePermissions(interp.io, args[0].str.bytes, perms, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", args[0].str.bytes);
            return error.PyException;
        },
        else => return err,
    };
    return Value.none;
}

fn renameFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str or args[1] != .str) {
        try interp.typeError("os.rename expects (src, dst)");
        return error.TypeError;
    }
    const cwd = std.Io.Dir.cwd();
    cwd.rename(args[0].str.bytes, cwd, args[1].str.bytes, interp.io) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", args[0].str.bytes);
            return error.PyException;
        },
        else => return err,
    };
    return Value.none;
}

fn accessFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("os.access expects a path");
        return error.TypeError;
    }
    _ = std.Io.Dir.cwd().statFile(interp.io, args[0].str.bytes, .{}) catch return Value{ .boolean = false };
    return Value{ .boolean = true };
}

fn rmdirFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("os.rmdir expects a path");
        return error.TypeError;
    }
    std.Io.Dir.cwd().deleteDir(interp.io, args[0].str.bytes) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", args[0].str.bytes);
            return error.PyException;
        },
        else => return err,
    };
    return Value.none;
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
    var mode: i64 = if (@import("builtin").os.tag == .windows) 0o644 else @intCast(st.permissions.toMode() & 0o7777);
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
    const gi = try a.create(BuiltinFn);
    gi.* = .{ .name = "__getitem__", .func = statResultGetItemFn };
    try d.setStr(a, "__getitem__", Value{ .builtin_fn = gi });
    const cls = try Class.init(a, "stat_result", &.{}, d);
    interp.os_stat_result_class = cls;
}

// stat_result[i]: indices match CPython's struct sequence layout.
// 0=st_mode,1=st_ino,2=st_dev,3=st_nlink,4=st_uid,5=st_gid,
// 6=st_size,7=st_atime,8=st_mtime,9=st_ctime
const STAT_FIELDS = [_][]const u8{
    "st_mode", "st_ino", "st_dev", "st_nlink", "st_uid", "st_gid",
    "st_size", "st_atime", "st_mtime", "st_ctime",
};

fn statResultGetItemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance or args[1] != .small_int) {
        try interp.typeError("stat_result index must be int");
        return error.TypeError;
    }
    const idx = args[1].small_int;
    if (idx < 0 or idx >= STAT_FIELDS.len) {
        try interp.raisePy("IndexError", "stat_result index out of range");
        return error.PyException;
    }
    const field = STAT_FIELDS[@intCast(idx)];
    return args[0].instance.dict.getStr(field) orelse Value.none;
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
