//! Pinhole `tempfile`: just enough `TemporaryDirectory` for fixtures.
//! `__enter__` makes a fresh directory under `$TMPDIR` (or `/tmp`) and
//! returns the path as a `str`. `__exit__` walks it depth-first and
//! removes contents, then the dir itself.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

var temp_dir_seed: u64 = 0xCAFEBABEDEADBEEF;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);
    const m = try Module.init(a, "tempfile");
    try m.attrs.setStr(a, "TemporaryDirectory", Value{ .class = interp.tempfile_temp_dir_class.? });

    // gettempdir() helper.
    const gtd = try a.create(BuiltinFn);
    gtd.* = .{ .name = "gettempdir", .func = gettempdirFn };
    try m.attrs.setStr(a, "gettempdir", Value{ .builtin_fn = gtd });

    return m;
}

fn ensureClasses(interp: *Interp) !void {
    if (interp.tempfile_temp_dir_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "__init__", initFn);
    try methodReg(a, d, "__enter__", enterFn);
    try methodReg(a, d, "__exit__", exitFn);
    try methodReg(a, d, "cleanup", cleanupFn);
    try methodReg(a, d, "__repr__", reprFn);
    interp.tempfile_temp_dir_class = try Class.init(a, "TemporaryDirectory", &.{}, d);
}

fn methodReg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn gettempdirFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, interp.tmp_dir) };
}

fn initFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;

    const root = interp.tmp_dir;

    var counter: u32 = 0;
    while (counter < 1000) : (counter += 1) {
        const seed = @atomicRmw(u64, &temp_dir_seed, .Add, 1, .seq_cst);
        var buf: [64]u8 = undefined;
        const candidate = try std.fmt.bufPrint(&buf, "tmp{x}_{x}", .{ seed, counter });
        var path_buf: std.ArrayList(u8) = .empty;
        defer path_buf.deinit(a);
        try path_buf.appendSlice(a, root);
        if (root.len > 0 and root[root.len - 1] != '/') try path_buf.append(a, '/');
        try path_buf.appendSlice(a, candidate);
        std.Io.Dir.cwd().createDir(interp.io, path_buf.items, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        const dup = try a.dupe(u8, path_buf.items);
        const s = try Str.fromOwnedSlice(a, dup);
        try self.dict.setStr(a, "name", Value{ .str = s });
        return Value.none;
    }
    try interp.raisePy("OSError", "could not create temp dir");
    return error.PyException;
}

fn enterFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    return self.dict.getStr("name") orelse Value.none;
}

fn exitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try cleanupFn(p, args[0..1]);
    return Value{ .boolean = false };
}

fn cleanupFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const name_v = self.dict.getStr("name") orelse return Value.none;
    if (name_v != .str) return Value.none;
    rmTreeBest(interp, name_v.str.bytes);
    return Value.none;
}

fn reprFn(p: *anyopaque, args: []const Value) anyerror!Value {
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
    var symlinks: std.ArrayList(bool) = .empty;
    defer symlinks.deinit(a);

    var it = dir.iterate();
    while (it.next(interp.io) catch null) |entry| {
        const name_dup = a.dupe(u8, entry.name) catch continue;
        entries.append(a, name_dup) catch {
            a.free(name_dup);
            continue;
        };
        subdirs.append(a, entry.kind == .directory) catch {};
        symlinks.append(a, entry.kind == .sym_link) catch {};
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
