//! Pinhole `stat`: constants + `S_IFMT`/`S_IMODE`/`S_IS*` predicates
//! and `filemode()`. All values match CPython 3.14's POSIX defaults.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "stat");

    // ST_* tuple indices.
    try setInt(a, m, "ST_MODE", 0);
    try setInt(a, m, "ST_INO", 1);
    try setInt(a, m, "ST_DEV", 2);
    try setInt(a, m, "ST_NLINK", 3);
    try setInt(a, m, "ST_UID", 4);
    try setInt(a, m, "ST_GID", 5);
    try setInt(a, m, "ST_SIZE", 6);
    try setInt(a, m, "ST_ATIME", 7);
    try setInt(a, m, "ST_MTIME", 8);
    try setInt(a, m, "ST_CTIME", 9);

    // S_IF* file type bits.
    try setInt(a, m, "S_IFDIR", 0o040000);
    try setInt(a, m, "S_IFCHR", 0o020000);
    try setInt(a, m, "S_IFBLK", 0o060000);
    try setInt(a, m, "S_IFREG", 0o100000);
    try setInt(a, m, "S_IFIFO", 0o010000);
    try setInt(a, m, "S_IFLNK", 0o120000);
    try setInt(a, m, "S_IFSOCK", 0o140000);
    try setInt(a, m, "S_IFDOOR", 0);
    try setInt(a, m, "S_IFPORT", 0);
    try setInt(a, m, "S_IFWHT", 0o160000);

    // Permission constants.
    try setInt(a, m, "S_ISUID", 0o4000);
    try setInt(a, m, "S_ISGID", 0o2000);
    try setInt(a, m, "S_ISVTX", 0o1000);

    try setInt(a, m, "S_IRWXU", 0o700);
    try setInt(a, m, "S_IRUSR", 0o400);
    try setInt(a, m, "S_IWUSR", 0o200);
    try setInt(a, m, "S_IXUSR", 0o100);

    try setInt(a, m, "S_IRWXG", 0o70);
    try setInt(a, m, "S_IRGRP", 0o40);
    try setInt(a, m, "S_IWGRP", 0o20);
    try setInt(a, m, "S_IXGRP", 0o10);

    try setInt(a, m, "S_IRWXO", 0o7);
    try setInt(a, m, "S_IROTH", 0o4);
    try setInt(a, m, "S_IWOTH", 0o2);
    try setInt(a, m, "S_IXOTH", 0o1);

    // Legacy aliases.
    try setInt(a, m, "S_IREAD", 0o400);
    try setInt(a, m, "S_IWRITE", 0o200);
    try setInt(a, m, "S_IEXEC", 0o100);
    try setInt(a, m, "S_ENFMT", 0o2000);

    // BSD/macOS user flags.
    try setInt(a, m, "UF_NODUMP", 0x00000001);
    try setInt(a, m, "UF_IMMUTABLE", 0x00000002);
    try setInt(a, m, "UF_APPEND", 0x00000004);
    try setInt(a, m, "UF_OPAQUE", 0x00000008);
    try setInt(a, m, "UF_NOUNLINK", 0x00000010);
    try setInt(a, m, "UF_COMPRESSED", 0x00000020);
    try setInt(a, m, "UF_TRACKED", 0x00000040);
    try setInt(a, m, "UF_DATAVAULT", 0x00000080);
    try setInt(a, m, "UF_HIDDEN", 0x00008000);
    try setInt(a, m, "UF_SETTABLE", 0x0000ffff);

    // BSD/macOS superuser flags.
    try setInt(a, m, "SF_ARCHIVED", 0x00010000);
    try setInt(a, m, "SF_IMMUTABLE", 0x00020000);
    try setInt(a, m, "SF_APPEND", 0x00040000);
    try setInt(a, m, "SF_RESTRICTED", 0x00080000);
    try setInt(a, m, "SF_NOUNLINK", 0x00100000);
    try setInt(a, m, "SF_SNAPSHOT", 0x00200000);
    try setInt(a, m, "SF_FIRMLINK", 0x00800000);
    try setInt(a, m, "SF_DATALESS", 0x40000000);
    try setInt(a, m, "SF_SUPPORTED", 0x009f0000);
    try setInt(a, m, "SF_SETTABLE", 0x3fff0000);
    try setInt(a, m, "SF_SYNTHETIC", 0xc0000000);

    // FILE_ATTRIBUTE_* (Windows; CPython exposes them on every platform).
    try setInt(a, m, "FILE_ATTRIBUTE_ARCHIVE", 32);
    try setInt(a, m, "FILE_ATTRIBUTE_COMPRESSED", 2048);
    try setInt(a, m, "FILE_ATTRIBUTE_DEVICE", 64);
    try setInt(a, m, "FILE_ATTRIBUTE_DIRECTORY", 16);
    try setInt(a, m, "FILE_ATTRIBUTE_ENCRYPTED", 16384);
    try setInt(a, m, "FILE_ATTRIBUTE_HIDDEN", 2);
    try setInt(a, m, "FILE_ATTRIBUTE_INTEGRITY_STREAM", 32768);
    try setInt(a, m, "FILE_ATTRIBUTE_NORMAL", 128);
    try setInt(a, m, "FILE_ATTRIBUTE_NOT_CONTENT_INDEXED", 8192);
    try setInt(a, m, "FILE_ATTRIBUTE_NO_SCRUB_DATA", 131072);
    try setInt(a, m, "FILE_ATTRIBUTE_OFFLINE", 4096);
    try setInt(a, m, "FILE_ATTRIBUTE_READONLY", 1);
    try setInt(a, m, "FILE_ATTRIBUTE_REPARSE_POINT", 1024);
    try setInt(a, m, "FILE_ATTRIBUTE_SPARSE_FILE", 512);
    try setInt(a, m, "FILE_ATTRIBUTE_SYSTEM", 4);
    try setInt(a, m, "FILE_ATTRIBUTE_TEMPORARY", 256);
    try setInt(a, m, "FILE_ATTRIBUTE_VIRTUAL", 65536);

    try reg(interp, m, "S_IFMT", sIfmtFn);
    try reg(interp, m, "S_IMODE", sImodeFn);
    try reg(interp, m, "S_ISDIR", makeIsFn(0o040000));
    try reg(interp, m, "S_ISCHR", makeIsFn(0o020000));
    try reg(interp, m, "S_ISBLK", makeIsFn(0o060000));
    try reg(interp, m, "S_ISREG", makeIsFn(0o100000));
    try reg(interp, m, "S_ISFIFO", makeIsFn(0o010000));
    try reg(interp, m, "S_ISLNK", makeIsFn(0o120000));
    try reg(interp, m, "S_ISSOCK", makeIsFn(0o140000));
    try reg(interp, m, "S_ISDOOR", isAlwaysFalseFn);
    try reg(interp, m, "S_ISPORT", isAlwaysFalseFn);
    try reg(interp, m, "S_ISWHT", makeIsFn(0o160000));
    try reg(interp, m, "filemode", filemodeFn);

    return m;
}

fn setInt(a: std.mem.Allocator, m: *Module, name: []const u8, v: i64) !void {
    try m.attrs.setStr(a, name, Value{ .small_int = v });
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn argInt(args: []const Value) ?i64 {
    if (args.len < 1) return null;
    return switch (args[0]) {
        .small_int => |i| i,
        .boolean => |b| if (b) 1 else 0,
        else => null,
    };
}

fn sIfmtFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const m = argInt(args) orelse return error.TypeError;
    return Value{ .small_int = m & 0o170000 };
}

fn sImodeFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const m = argInt(args) orelse return error.TypeError;
    return Value{ .small_int = m & 0o7777 };
}

fn makeIsFn(comptime kind: i64) BuiltinFnPtr {
    const Closure = struct {
        fn call(_: *anyopaque, args: []const Value) anyerror!Value {
            const m = argInt(args) orelse return error.TypeError;
            return Value{ .boolean = (m & 0o170000) == kind };
        }
    };
    return Closure.call;
}

fn isAlwaysFalseFn(_: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    return Value{ .boolean = false };
}

fn filemodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const m = argInt(args) orelse return error.TypeError;
    var buf: [10]u8 = undefined;

    // [0]: file type.
    buf[0] = switch (m & 0o170000) {
        0o040000 => 'd',
        0o020000 => 'c',
        0o060000 => 'b',
        0o100000 => '-',
        0o010000 => 'p',
        0o120000 => 'l',
        0o140000 => 's',
        0o160000 => '-', // whiteout — CPython renders as '-'
        else => '?',
    };

    // Owner rwx, with setuid in the x slot.
    buf[1] = if (m & 0o400 != 0) 'r' else '-';
    buf[2] = if (m & 0o200 != 0) 'w' else '-';
    const x_user = m & 0o100 != 0;
    const setuid = m & 0o4000 != 0;
    buf[3] = if (setuid and x_user) 's' else if (setuid) 'S' else if (x_user) 'x' else '-';

    // Group rwx, with setgid in the x slot.
    buf[4] = if (m & 0o40 != 0) 'r' else '-';
    buf[5] = if (m & 0o20 != 0) 'w' else '-';
    const x_grp = m & 0o10 != 0;
    const setgid = m & 0o2000 != 0;
    buf[6] = if (setgid and x_grp) 's' else if (setgid) 'S' else if (x_grp) 'x' else '-';

    // Other rwx, with sticky in the x slot.
    buf[7] = if (m & 0o4 != 0) 'r' else '-';
    buf[8] = if (m & 0o2 != 0) 'w' else '-';
    const x_oth = m & 0o1 != 0;
    const sticky = m & 0o1000 != 0;
    buf[9] = if (sticky and x_oth) 't' else if (sticky) 'T' else if (x_oth) 'x' else '-';

    return Value{ .str = try Str.init(interp.allocator, buf[0..]) };
}
