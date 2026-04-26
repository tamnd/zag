//! Pinhole `linecache`: get/cache lines of text files.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

pub const Entry = struct {
    /// Line text including the trailing `\n` (last line may omit it).
    lines: [][]u8,
    size: u64,
    mtime_ns: i128,
    /// `true` when the entry came from `lazycache` and disk hasn't been
    /// read yet; `getline` will resolve it on first access.
    lazy: bool,
};

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "linecache");
    try reg(interp, m, "getline", getlineFn);
    try reg(interp, m, "getlines", getlinesFn);
    try reg(interp, m, "clearcache", clearcacheFn);
    try reg(interp, m, "checkcache", checkcacheFn);
    try reg(interp, m, "lazycache", lazycacheFn);
    try m.attrs.setStr(interp.allocator, "cache", Value.none);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn freeEntry(a: std.mem.Allocator, e: *Entry) void {
    for (e.lines) |line| a.free(line);
    a.free(e.lines);
}

fn dropFromCache(interp: *Interp, path: []const u8) void {
    const a = interp.allocator;
    if (interp.linecache_cache.fetchRemove(path)) |kv| {
        var e = kv.value;
        freeEntry(a, &e);
        a.free(kv.key);
    }
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

fn splitLines(a: std.mem.Allocator, src: []const u8) ![][]u8 {
    var lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (lines.items) |line| a.free(line);
        lines.deinit(a);
    }
    var i: usize = 0;
    while (i < src.len) {
        var j = i;
        while (j < src.len and src[j] != '\n') j += 1;
        if (j < src.len) {
            const dup = try a.dupe(u8, src[i .. j + 1]);
            try lines.append(a, dup);
            i = j + 1;
        } else {
            // Last line missing the trailing `\n`; append one so the
            // cache always presents `'…\n'` slices, matching CPython.
            const len = j - i;
            const dup = try a.alloc(u8, len + 1);
            @memcpy(dup[0..len], src[i..j]);
            dup[len] = '\n';
            try lines.append(a, dup);
            i = j;
        }
    }
    if (lines.items.len == 0) {
        const dup = try a.dupe(u8, "\n");
        try lines.append(a, dup);
    }
    return try lines.toOwnedSlice(a);
}

fn loadIntoCache(interp: *Interp, path: []const u8) !*Entry {
    const a = interp.allocator;
    const stat = std.Io.Dir.cwd().statFile(interp.io, path, .{}) catch return error.NotFound;
    if (stat.kind != .file) return error.NotFound;
    const data = readFileAlloc(interp, path) catch return error.NotFound;
    defer a.free(data);
    const lines = try splitLines(a, data);
    errdefer {
        for (lines) |line| a.free(line);
        a.free(lines);
    }
    dropFromCache(interp, path);
    const key = try a.dupe(u8, path);
    errdefer a.free(key);
    const entry = Entry{
        .lines = lines,
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
        .lazy = false,
    };
    try interp.linecache_cache.put(a, key, entry);
    return interp.linecache_cache.getPtr(key).?;
}

fn getEntry(interp: *Interp, path: []const u8) ?*Entry {
    const e = interp.linecache_cache.getPtr(path) orelse return null;
    if (e.lazy) {
        const fresh = loadIntoCache(interp, path) catch return null;
        return fresh;
    }
    return e;
}

fn getlineImpl(interp: *Interp, path: []const u8, lineno: i64) !Value {
    const a = interp.allocator;
    if (path.len == 0) return Value{ .str = try Str.init(a, "") };
    var entry_ptr: ?*Entry = interp.linecache_cache.getPtr(path);
    if (entry_ptr) |e| {
        if (e.lazy) entry_ptr = loadIntoCache(interp, path) catch null;
    } else {
        entry_ptr = loadIntoCache(interp, path) catch null;
    }
    const e = entry_ptr orelse return Value{ .str = try Str.init(a, "") };
    if (lineno < 1) return Value{ .str = try Str.init(a, "") };
    const idx: usize = @intCast(lineno - 1);
    if (idx >= e.lines.len) return Value{ .str = try Str.init(a, "") };
    return Value{ .str = try Str.init(a, e.lines[idx]) };
}

fn getlineFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str) return error.TypeError;
    const lineno: i64 = switch (args[1]) {
        .small_int => |n| n,
        else => return error.TypeError,
    };
    return getlineImpl(interp, args[0].str.bytes, lineno);
}

fn getlinesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const path = args[0].str.bytes;
    var entry_ptr: ?*Entry = interp.linecache_cache.getPtr(path);
    if (entry_ptr) |e| {
        if (e.lazy) entry_ptr = loadIntoCache(interp, path) catch null;
    } else {
        entry_ptr = loadIntoCache(interp, path) catch null;
    }
    const out = try List.init(a);
    if (entry_ptr) |e| {
        for (e.lines) |line| {
            try out.append(a, Value{ .str = try Str.init(a, line) });
        }
    }
    return Value{ .list = out };
}

fn clearcacheFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    var it = interp.linecache_cache.iterator();
    while (it.next()) |kv| {
        var e = kv.value_ptr.*;
        freeEntry(a, &e);
        a.free(kv.key_ptr.*);
    }
    interp.linecache_cache.clearAndFree(a);
    return Value.none;
}

fn checkcacheFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len == 0 or args[0] == .none) {
        // Recheck every entry; drop any whose disk state diverges.
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(a);
        var it = interp.linecache_cache.iterator();
        while (it.next()) |kv| {
            const path = kv.key_ptr.*;
            const e = kv.value_ptr;
            if (e.lazy) continue;
            const stat = std.Io.Dir.cwd().statFile(interp.io, path, .{}) catch {
                try stale.append(a, path);
                continue;
            };
            if (stat.size != e.size or stat.mtime.nanoseconds != e.mtime_ns) {
                try stale.append(a, path);
            }
        }
        for (stale.items) |path| dropFromCache(interp, path);
        return Value.none;
    }
    if (args[0] != .str) return error.TypeError;
    const path = args[0].str.bytes;
    const e = interp.linecache_cache.getPtr(path) orelse return Value.none;
    if (e.lazy) return Value.none;
    const stat = std.Io.Dir.cwd().statFile(interp.io, path, .{}) catch {
        dropFromCache(interp, path);
        return Value.none;
    };
    if (stat.size != e.size or stat.mtime.nanoseconds != e.mtime_ns) {
        dropFromCache(interp, path);
    }
    return Value.none;
}

fn lazycacheFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const path = args[0].str.bytes;
    if (interp.linecache_cache.contains(path)) return Value{ .boolean = true };
    const key = try a.dupe(u8, path);
    errdefer a.free(key);
    const entry = Entry{
        .lines = try a.alloc([]u8, 0),
        .size = 0,
        .mtime_ns = 0,
        .lazy = true,
    };
    try interp.linecache_cache.put(a, key, entry);
    return Value{ .boolean = true };
}
