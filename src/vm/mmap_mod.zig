//! `mmap` module — memory-mapped file I/O for fixture 205.

const std = @import("std");
const c = std.c;
const builtin = @import("builtin");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Dict = @import("../object/dict.zig").Dict;
const Bytes = @import("../object/bytes.zig").Bytes;
const Interp = @import("interp.zig").Interp;

// POSIX mmap functions — conditional to avoid linker errors on Windows
const posix_mmap = if (builtin.os.tag != .windows) struct {
    pub extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) ?*anyopaque;
    pub extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
    pub extern "c" fn msync(addr: *anyopaque, len: usize, flags: c_int) c_int;
    pub extern "c" fn madvise(addr: *anyopaque, len: usize, advice: c_int) c_int;
    pub extern "c" fn getpagesize() c_int;
} else struct {
    pub fn mmap(_: ?*anyopaque, _: usize, _: c_int, _: c_int, _: c_int, _: i64) ?*anyopaque { return null; }
    pub fn munmap(_: *anyopaque, _: usize) c_int { return -1; }
    pub fn msync(_: *anyopaque, _: usize, _: c_int) c_int { return -1; }
    pub fn madvise(_: *anyopaque, _: usize, _: c_int) c_int { return -1; }
    pub fn getpagesize() c_int { return 4096; }
};

// macOS constants
const PROT_READ: c_int = 1;
const PROT_WRITE: c_int = 2;
const MAP_SHARED: c_int = 1;
const MAP_PRIVATE: c_int = 2;
const MAP_ANON: c_int = 0x1000;
const MS_SYNC: c_int = 0x10;
const MAP_FAILED: usize = std.math.maxInt(usize);

fn gi(p: *anyopaque) *Interp {
    return @ptrCast(@alignCast(p));
}

fn regD(a: std.mem.Allocator, d: *Dict, name: []const u8, f: BuiltinFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f };
    try d.setStr(a, name, Value{ .builtin_fn = bf });
}

fn regKwD(a: std.mem.Allocator, d: *Dict, name: []const u8, f: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f, .kw_func = kw };
    try d.setStr(a, name, Value{ .builtin_fn = bf });
}

fn regM(a: std.mem.Allocator, m: *Module, name: []const u8, f: BuiltinFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = bf });
}

fn regKwM(a: std.mem.Allocator, m: *Module, name: []const u8, f: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = bf });
}

// ===== Instance helpers =====

fn getPtr(inst: *Instance) ?[*]u8 {
    const v = inst.dict.getStr("_ptr") orelse return null;
    const n: i64 = switch (v) { .small_int => |i| i, else => return null };
    if (n == 0 or n == -1) return null;
    return @ptrFromInt(@as(usize, @bitCast(n)));
}

fn getSize(inst: *Instance) usize {
    const v = inst.dict.getStr("_size") orelse return 0;
    return switch (v) { .small_int => |i| if (i > 0) @intCast(i) else 0, else => 0 };
}

fn getPos(inst: *Instance) usize {
    const v = inst.dict.getStr("_pos") orelse return 0;
    return switch (v) { .small_int => |i| if (i > 0) @intCast(i) else 0, else => 0 };
}

fn getAccess(inst: *Instance) i64 {
    const v = inst.dict.getStr("_access") orelse return 0;
    return switch (v) { .small_int => |i| i, else => 0 };
}

fn isClosed(inst: *Instance) bool {
    const v = inst.dict.getStr("closed") orelse return false;
    return v == .boolean and v.boolean;
}

// ===== mmap.__init__ =====

fn mmapInit(p: *anyopaque, args: []const Value) anyerror!Value {
    return mmapInitKw(p, args, &.{}, &.{});
}

fn mmapInitKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 3) return Value.none;
    const inst = switch (args[0]) { .instance => |i| i, else => return Value.none };
    const fd: c_int = switch (args[1]) { .small_int => |i| @intCast(i), else => -1 };
    const length: usize = switch (args[2]) { .small_int => |i| @intCast(i), else => 0 };

    // Parse optional args / kwargs
    var access: i64 = 0;
    var offset: i64 = 0;
    // positional: mmap(fd, length[, tagname[, access[, offset]]])
    if (args.len >= 4) {
        // Could be tagname (None) or access (int)
        switch (args[3]) {
            .small_int => |i| access = i,
            .none => {},
            else => {},
        }
    }
    if (args.len >= 5) {
        switch (args[4]) {
            .small_int => |i| access = i,
            else => {},
        }
    }
    if (args.len >= 6) {
        switch (args[5]) {
            .small_int => |i| offset = i,
            else => {},
        }
    }
    for (kw_names, kw_values) |kn, kv| {
        const kname = switch (kn) { .str => |s| s.bytes, else => continue };
        if (std.mem.eql(u8, kname, "access")) access = switch (kv) { .small_int => |i| i, else => 0 };
        if (std.mem.eql(u8, kname, "offset")) offset = switch (kv) { .small_int => |i| i, else => 0 };
    }

    // Determine prot and flags
    const prot: c_int = if (access == 1) PROT_READ else PROT_READ | PROT_WRITE;
    const flags: c_int = if (fd == -1) MAP_PRIVATE | MAP_ANON else MAP_SHARED;

    // Resolve virtual fd → real OS fd
    const real_fd: c_int = if (fd == -1) -1 else blk: {
        const entry = interp.os_fd_table.getPtr(fd) orelse {
            try interp.raisePy("OSError", "Bad file descriptor");
            return error.PyException;
        };
        // On Windows, file.handle is *anyopaque (HANDLE), not c_int; mmap is POSIX-only anyway
        break :blk if (comptime builtin.os.tag == .windows) -1 else entry.file.handle;
    };

    const raw = posix_mmap.mmap(null, length, prot, flags, real_fd, offset);
    const ptr_int: usize = if (raw) |r| @intFromPtr(r) else MAP_FAILED;
    if (ptr_int == MAP_FAILED) {
        try interp.raisePy("OSError", "mmap failed");
        return error.PyException;
    }

    try inst.dict.setStr(a, "_ptr", Value{ .small_int = @bitCast(ptr_int) });
    try inst.dict.setStr(a, "_size", Value{ .small_int = @intCast(length) });
    try inst.dict.setStr(a, "_pos", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "closed", Value{ .boolean = false });
    try inst.dict.setStr(a, "_access", Value{ .small_int = access });
    return Value.none;
}

// ===== read(n=-1) =====

fn mmapRead(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const ptr = getPtr(inst) orelse return makeBytes(a, "");
    const sz = getSize(inst);
    const pos = getPos(inst);
    if (pos >= sz) return makeBytes(a, "");
    const n: usize = if (args.len >= 2) switch (args[1]) {
        .small_int => |i| if (i < 0) sz - pos else @min(@as(usize, @intCast(i)), sz - pos),
        else => sz - pos,
    } else sz - pos;
    const data = ptr[pos .. pos + n];
    const bv = try Bytes.init(a, data);
    try inst.dict.setStr(a, "_pos", Value{ .small_int = @intCast(pos + n) });
    return Value{ .bytes = bv };
}

fn makeBytes(a: std.mem.Allocator, data: []const u8) !Value {
    const b = try Bytes.init(a, data);
    return Value{ .bytes = b };
}

// ===== write(data) =====

fn mmapWrite(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    if (getAccess(inst) == 1) {
        try interp.raisePy("TypeError", "mmap can't modify a readonly memory map.");
        return error.PyException;
    }
    const ptr = getPtr(inst) orelse return Value.none;
    const sz = getSize(inst);
    var pos = getPos(inst);
    const data: []const u8 = switch (args[1]) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const n = @min(data.len, sz - pos);
    @memcpy(ptr[pos .. pos + n], data[0..n]);
    pos += n;
    try inst.dict.setStr(a, "_pos", Value{ .small_int = @intCast(pos) });
    return Value.none;
}

// ===== write_byte(byte) =====

fn mmapWriteByte(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    if (getAccess(inst) == 1) {
        try interp.raisePy("TypeError", "mmap can't modify a readonly memory map.");
        return error.PyException;
    }
    const ptr = getPtr(inst) orelse return Value.none;
    const sz = getSize(inst);
    const pos = getPos(inst);
    if (pos >= sz) return Value.none;
    const byte: u8 = switch (args[1]) {
        .small_int => |i| @intCast(i & 0xff),
        else => return Value.none,
    };
    ptr[pos] = byte;
    try inst.dict.setStr(a, "_pos", Value{ .small_int = @intCast(pos + 1) });
    return Value.none;
}

// ===== seek(pos[, whence=0]) =====

fn mmapSeek(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const sz: i64 = @intCast(getSize(inst));
    const cur: i64 = @intCast(getPos(inst));
    const offset: i64 = switch (args[1]) { .small_int => |i| i, else => 0 };
    const whence: i64 = if (args.len >= 3) switch (args[2]) { .small_int => |i| i, else => 0 } else 0;
    const new_pos: i64 = switch (whence) {
        0 => offset,                  // SEEK_SET
        1 => cur + offset,            // SEEK_CUR
        2 => sz + offset,             // SEEK_END
        else => offset,
    };
    const clamped: i64 = @max(0, @min(new_pos, sz));
    try inst.dict.setStr(a, "_pos", Value{ .small_int = clamped });
    return Value.none;
}

// ===== tell() =====

fn mmapTell(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(getPos(args[0].instance)) };
}

// ===== size() =====

fn mmapSize(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(getSize(args[0].instance)) };
}

// ===== close() =====

fn mmapClose(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    if (isClosed(inst)) return Value.none;
    if (getPtr(inst)) |ptr| {
        _ = posix_mmap.munmap(@ptrCast(ptr), getSize(inst));
    }
    try inst.dict.setStr(a, "closed", Value{ .boolean = true });
    try inst.dict.setStr(a, "_ptr", Value{ .small_int = -1 });
    return Value.none;
}

// ===== flush([offset[, size]]) =====

fn mmapFlush(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const ptr = getPtr(inst) orelse return Value.none;
    const sz = getSize(inst);
    _ = posix_mmap.msync(@ptrCast(ptr), sz, MS_SYNC);
    return Value.none;
}

// ===== find(sub[, start=0]) =====

fn mmapFind(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2 or args[0] != .instance) return Value{ .small_int = -1 };
    const inst = args[0].instance;
    const ptr = getPtr(inst) orelse return Value{ .small_int = -1 };
    const sz = getSize(inst);
    const sub: []const u8 = switch (args[1]) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        else => return Value{ .small_int = -1 },
    };
    const start: usize = if (args.len >= 3) switch (args[2]) {
        .small_int => |i| if (i < 0) 0 else @intCast(i),
        else => 0,
    } else 0;
    const haystack = ptr[start..sz];
    const idx = std.mem.indexOf(u8, haystack, sub) orelse return Value{ .small_int = -1 };
    return Value{ .small_int = @intCast(start + idx) };
}

// ===== rfind(sub[, start=0]) =====

fn mmapRfind(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2 or args[0] != .instance) return Value{ .small_int = -1 };
    const inst = args[0].instance;
    const ptr = getPtr(inst) orelse return Value{ .small_int = -1 };
    const sz = getSize(inst);
    const sub: []const u8 = switch (args[1]) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        else => return Value{ .small_int = -1 },
    };
    const start: usize = if (args.len >= 3) switch (args[2]) {
        .small_int => |i| if (i < 0) 0 else @intCast(i),
        else => 0,
    } else 0;
    const haystack = ptr[start..sz];
    const idx = std.mem.lastIndexOf(u8, haystack, sub) orelse return Value{ .small_int = -1 };
    return Value{ .small_int = @intCast(start + idx) };
}

// ===== readline() =====

fn mmapReadline(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return makeBytes(a, "");
    const inst = args[0].instance;
    const ptr = getPtr(inst) orelse return makeBytes(a, "");
    const sz = getSize(inst);
    const pos = getPos(inst);
    if (pos >= sz) return makeBytes(a, "");
    var end = pos;
    while (end < sz and ptr[end] != '\n') end += 1;
    if (end < sz) end += 1; // include '\n'
    const line = ptr[pos..end];
    try inst.dict.setStr(a, "_pos", Value{ .small_int = @intCast(end) });
    return makeBytes(a, line);
}

// ===== madvise(option[, start[, length]]) =====

fn mmapMadvise(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const ptr = getPtr(inst) orelse return Value.none;
    const sz = getSize(inst);
    const advice: c_int = switch (args[1]) { .small_int => |i| @intCast(i), else => 0 };
    _ = posix_mmap.madvise(@ptrCast(ptr), sz, advice);
    return Value.none;
}

// ===== __getitem__(key) =====

fn mmapGetItem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const ptr = getPtr(inst) orelse return Value.none;
    const sz = getSize(inst);
    switch (args[1]) {
        .small_int => |i| {
            const idx: usize = if (i < 0) @intCast(@as(i64, @intCast(sz)) + i) else @intCast(i);
            if (idx >= sz) return Value{ .small_int = 0 };
            return Value{ .small_int = ptr[idx] };
        },
        .slice => |sl| {
            const start_v = sl.start;
            const stop_v = sl.stop;
            const s: usize = switch (start_v) {
                .small_int => |i| if (i < 0) @intCast(@max(0, @as(i64, @intCast(sz)) + i)) else @intCast(i),
                .none => 0,
                else => 0,
            };
            const e: usize = switch (stop_v) {
                .small_int => |i| if (i < 0) @intCast(@max(0, @as(i64, @intCast(sz)) + i)) else @min(@as(usize, @intCast(i)), sz),
                .none => sz,
                else => sz,
            };
            if (s >= e or s >= sz) return makeBytes(a, "");
            return makeBytes(a, ptr[s..@min(e, sz)]);
        },
        else => {},
    }
    return Value.none;
}

// ===== __setitem__(key, value) =====

fn mmapSetItem(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 3 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const ptr = getPtr(inst) orelse return Value.none;
    const sz = getSize(inst);
    switch (args[1]) {
        .slice => |sl| {
            const s: usize = switch (sl.start) {
                .small_int => |i| @intCast(i),
                .none => 0,
                else => 0,
            };
            const e: usize = switch (sl.stop) {
                .small_int => |i| @min(@as(usize, @intCast(i)), sz),
                .none => sz,
                else => sz,
            };
            const data: []const u8 = switch (args[2]) {
                .bytes => |b| b.data,
                .str => |sv| sv.bytes,
                else => return Value.none,
            };
            const n = @min(data.len, e - s);
            if (s < sz) @memcpy(ptr[s .. s + n], data[0..n]);
        },
        else => {},
    }
    return Value.none;
}

// ===== __enter__ / __exit__ =====

fn mmapEnter(_: *anyopaque, args: []const Value) anyerror!Value {
    return if (args.len >= 1) args[0] else Value.none;
}

fn mmapExit(p: *anyopaque, args: []const Value) anyerror!Value {
    return mmapClose(p, args);
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "mmap");

    const pagesize: i64 = posix_mmap.getpagesize();

    // Constants
    try m.attrs.setStr(a, "ACCESS_DEFAULT", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "ACCESS_READ", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "ACCESS_WRITE", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "ACCESS_COPY", Value{ .small_int = 3 });
    try m.attrs.setStr(a, "PROT_READ", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "PROT_WRITE", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "PROT_EXEC", Value{ .small_int = 4 });
    try m.attrs.setStr(a, "MAP_SHARED", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "MAP_PRIVATE", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "MAP_ANON", Value{ .small_int = 0x1000 });
    try m.attrs.setStr(a, "MAP_ANONYMOUS", Value{ .small_int = 0x1000 });
    try m.attrs.setStr(a, "PAGESIZE", Value{ .small_int = pagesize });
    try m.attrs.setStr(a, "ALLOCATIONGRANULARITY", Value{ .small_int = pagesize });
    try m.attrs.setStr(a, "MADV_NORMAL", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "MADV_RANDOM", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "MADV_SEQUENTIAL", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "MADV_WILLNEED", Value{ .small_int = 3 });
    try m.attrs.setStr(a, "MADV_DONTNEED", Value{ .small_int = 4 });

    // mmap class
    {
        const d = try Dict.init(a);
        interp.mmap_class = try Class.init(a, "mmap", &.{}, d);
        const cls = interp.mmap_class.?;
        try regKwD(a, cls.dict, "__init__", mmapInit, mmapInitKw);
        try regD(a, cls.dict, "read", mmapRead);
        try regD(a, cls.dict, "write", mmapWrite);
        try regD(a, cls.dict, "write_byte", mmapWriteByte);
        try regKwD(a, cls.dict, "seek", mmapSeek, mmapSeekKw);
        try regD(a, cls.dict, "tell", mmapTell);
        try regD(a, cls.dict, "size", mmapSize);
        try regD(a, cls.dict, "close", mmapClose);
        try regD(a, cls.dict, "flush", mmapFlush);
        try regD(a, cls.dict, "find", mmapFind);
        try regD(a, cls.dict, "rfind", mmapRfind);
        try regD(a, cls.dict, "readline", mmapReadline);
        try regD(a, cls.dict, "madvise", mmapMadvise);
        try regD(a, cls.dict, "__getitem__", mmapGetItem);
        try regD(a, cls.dict, "__setitem__", mmapSetItem);
        try regD(a, cls.dict, "__enter__", mmapEnter);
        try regD(a, cls.dict, "__exit__", mmapExit);
        try m.attrs.setStr(a, "mmap", Value{ .class = cls });
    }

    interp.mmap_module = m;
    return m;
}

fn mmapSeekKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return mmapSeek(p, args);
}
