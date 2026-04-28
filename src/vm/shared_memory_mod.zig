//! `multiprocessing.shared_memory` — SharedMemory and ShareableList.
//! Uses an interp-level name→data registry so named attach and
//! cross-process writes work within the same interpreter run.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

fn reg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regM(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn regMKw(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn gi(p: *anyopaque) *Interp {
    return @ptrCast(@alignCast(p));
}

fn instArg(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

// ===== registry helpers =====

fn getRegistry(interp: *Interp) !*Dict {
    if (interp.sm_registry) |d| return d;
    const d = try Dict.init(interp.allocator);
    interp.sm_registry = d;
    return d;
}

var name_counter: u32 = 0;

fn genName(a: std.mem.Allocator) ![]u8 {
    name_counter +%= 1;
    return std.fmt.allocPrint(a, "psm_{d:08}", .{name_counter});
}

// ===== buf proxy =====

fn bufGetItem(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    if (args.len < 2) return Value.none;
    const idx_v = args[1];
    const data_v = inst.dict.getStr("_data") orelse return Value.none;
    if (data_v != .list) return Value.none;
    const items = data_v.list.items.items;
    var idx: i64 = if (idx_v == .small_int) idx_v.small_int else return Value.none;
    if (idx < 0) idx += @intCast(items.len);
    if (idx < 0 or idx >= @as(i64, @intCast(items.len))) return Value.none;
    return items[@intCast(idx)];
}

fn bufSetItem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);
    if (args.len < 3) return Value.none;
    const idx_v = args[1];
    const val = args[2];
    const data_v = inst.dict.getStr("_data") orelse return Value.none;
    if (data_v != .list) return Value.none;
    const items = data_v.list.items.items;
    var idx: i64 = if (idx_v == .small_int) idx_v.small_int else return Value.none;
    if (idx < 0) idx += @intCast(items.len);
    if (idx < 0 or idx >= @as(i64, @intCast(items.len))) return Value.none;
    data_v.list.items.items[@intCast(idx)] = val;
    _ = interp;
    return Value.none;
}

// ===== SharedMemory =====

fn shmCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    return shmCtorImpl(p, args, &.{}, &.{});
}

fn shmCtorKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return shmCtorImpl(p, args, kn, kv);
}

fn shmCtorImpl(p: *anyopaque, _args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    _ = _args;
    const interp = gi(p);
    const a = interp.allocator;

    var create = false;
    var size: i64 = 0;
    var name_opt: ?[]const u8 = null;

    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        const k = nm.str.bytes;
        if (std.mem.eql(u8, k, "create")) create = vl == .boolean and vl.boolean;
        if (std.mem.eql(u8, k, "size") and vl == .small_int) size = vl.small_int;
        if (std.mem.eql(u8, k, "name") and vl == .str) name_opt = vl.str.bytes;
    }

    const registry = try getRegistry(interp);

    if (create) {
        if (size <= 0) {
            try interp.raisePy("ValueError", "size must be positive");
            return error.PyException;
        }
        const name = if (name_opt) |n| try a.dupe(u8, n) else try genName(a);
        const data = try List.init(a);
        var i: usize = 0;
        while (i < @as(usize, @intCast(size))) : (i += 1) {
            try data.append(a, Value{ .small_int = 0 });
        }
        const data_v = Value{ .list = data };
        try registry.setStr(a, name, data_v);

        const inst = try Instance.init(a, interp.sm_shm_class.?);
        try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, name) });
        try inst.dict.setStr(a, "size", Value{ .small_int = size });
        try inst.dict.setStr(a, "_data", data_v);
        // Create buf proxy
        const buf_inst = try Instance.init(a, interp.sm_buf_class.?);
        try buf_inst.dict.setStr(a, "_data", data_v);
        try inst.dict.setStr(a, "buf", Value{ .instance = buf_inst });
        return Value{ .instance = inst };
    } else {
        // Attach to existing
        const name = name_opt orelse {
            try interp.raisePy("FileNotFoundError", "no name given");
            return error.PyException;
        };
        const data_v = registry.getStr(name) orelse {
            try interp.raisePy("FileNotFoundError", name);
            return error.PyException;
        };
        const sz: i64 = if (data_v == .list) @intCast(data_v.list.items.items.len) else 0;

        const inst = try Instance.init(a, interp.sm_shm_class.?);
        try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, name) });
        try inst.dict.setStr(a, "size", Value{ .small_int = sz });
        try inst.dict.setStr(a, "_data", data_v);
        const buf_inst = try Instance.init(a, interp.sm_buf_class.?);
        try buf_inst.dict.setStr(a, "_data", data_v);
        try inst.dict.setStr(a, "buf", Value{ .instance = buf_inst });
        return Value{ .instance = inst };
    }
}

fn shmClose(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn shmUnlink(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);
    const registry = try getRegistry(interp);
    const name_v = inst.dict.getStr("name") orelse return Value.none;
    if (name_v == .str) _ = registry.delete(name_v.str.bytes);
    return Value.none;
}

fn shmEnter(_: *anyopaque, args: []const Value) anyerror!Value {
    return args[0];
}

fn shmExit(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .boolean = false };
}

// ===== ShareableList =====

fn slCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    return slCtorImpl(p, args, &.{}, &.{});
}

fn slCtorKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return slCtorImpl(p, args, kn, kv);
}

fn slCtorImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;

    var items_val: ?Value = null;
    var name_opt: ?[]const u8 = null;

    // First positional arg can be the sequence
    if (args.len >= 1 and args[0] != .none) items_val = args[0];

    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        const k = nm.str.bytes;
        if (std.mem.eql(u8, k, "sequence")) items_val = vl;
        if (std.mem.eql(u8, k, "name") and vl == .str) name_opt = vl.str.bytes;
    }

    const registry = try getRegistry(interp);
    const inst = try Instance.init(a, interp.sm_sl_class.?);

    if (name_opt) |name| {
        // Attach to existing SharedMemory by name
        const data_v = registry.getStr(name) orelse {
            try interp.raisePy("FileNotFoundError", name);
            return error.PyException;
        };
        // data_v is the list of items stored previously
        try inst.dict.setStr(a, "_items", data_v);

        // Create shm proxy
        const shm_inst = try Instance.init(a, interp.sm_shm_class.?);
        try shm_inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, name) });
        const sz: i64 = if (data_v == .list) @intCast(data_v.list.items.items.len) else 0;
        try shm_inst.dict.setStr(a, "size", Value{ .small_int = @max(sz, 1) });
        try shm_inst.dict.setStr(a, "_data", data_v);
        const buf_inst = try Instance.init(a, interp.sm_buf_class.?);
        try buf_inst.dict.setStr(a, "_data", data_v);
        try shm_inst.dict.setStr(a, "buf", Value{ .instance = buf_inst });
        try inst.dict.setStr(a, "shm", Value{ .instance = shm_inst });
        return Value{ .instance = inst };
    }

    // Create new
    const items_list = try List.init(a);
    if (items_val) |iv| {
        const src: []const Value = switch (iv) {
            .list => |l| l.items.items,
            .tuple => |t| t.items,
            else => &.{},
        };
        for (src) |v| try items_list.append(a, v);
    }
    const items_v = Value{ .list = items_list };

    // Generate a name and register
    const name = try genName(a);
    try registry.setStr(a, name, items_v);

    try inst.dict.setStr(a, "_items", items_v);

    // Build shm attribute
    const shm_inst = try Instance.init(a, interp.sm_shm_class.?);
    try shm_inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, name) });
    const sz = @max(@as(i64, @intCast(items_list.items.items.len)), 1);
    try shm_inst.dict.setStr(a, "size", Value{ .small_int = sz });
    try shm_inst.dict.setStr(a, "_data", items_v);
    const buf_inst = try Instance.init(a, interp.sm_buf_class.?);
    try buf_inst.dict.setStr(a, "_data", items_v);
    try shm_inst.dict.setStr(a, "buf", Value{ .instance = buf_inst });
    try inst.dict.setStr(a, "shm", Value{ .instance = shm_inst });

    return Value{ .instance = inst };
}

fn slGetItem(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    if (args.len < 2) return Value.none;
    const items_v = inst.dict.getStr("_items") orelse return Value.none;
    if (items_v != .list) return Value.none;
    const items = items_v.list.items.items;
    var idx: i64 = if (args[1] == .small_int) args[1].small_int else return Value.none;
    if (idx < 0) idx += @intCast(items.len);
    if (idx < 0 or idx >= @as(i64, @intCast(items.len))) return Value.none;
    return items[@intCast(idx)];
}

fn slSetItem(p: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    if (args.len < 3) return Value.none;
    const items_v = inst.dict.getStr("_items") orelse return Value.none;
    if (items_v != .list) return Value.none;
    const items = items_v.list.items.items;
    var idx: i64 = if (args[1] == .small_int) args[1].small_int else return Value.none;
    if (idx < 0) idx += @intCast(items.len);
    if (idx < 0 or idx >= @as(i64, @intCast(items.len))) return Value.none;
    items_v.list.items.items[@intCast(idx)] = args[2];
    _ = gi(p);
    return Value.none;
}

fn slLen(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const items_v = inst.dict.getStr("_items") orelse return Value{ .small_int = 0 };
    if (items_v != .list) return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(items_v.list.items.items.len) };
}

fn slCount(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    if (args.len < 2) return Value{ .small_int = 0 };
    const target = args[1];
    const items_v = inst.dict.getStr("_items") orelse return Value{ .small_int = 0 };
    if (items_v != .list) return Value{ .small_int = 0 };
    var count: i64 = 0;
    for (items_v.list.items.items) |item| {
        if (valuesEqual(item, target)) count += 1;
    }
    return Value{ .small_int = count };
}

fn slIndex(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);
    if (args.len < 2) return Value.none;
    const target = args[1];
    const items_v = inst.dict.getStr("_items") orelse return Value.none;
    if (items_v != .list) return Value.none;
    for (items_v.list.items.items, 0..) |item, i| {
        if (valuesEqual(item, target)) return Value{ .small_int = @intCast(i) };
    }
    try interp.raisePy("ValueError", "value not in ShareableList");
    return error.PyException;
}

fn slIter(p: *anyopaque, args: []const Value) anyerror!Value {
    // Return self; __next__ uses _iter_idx
    const interp = gi(p);
    const inst = try instArg(args);
    try inst.dict.setStr(interp.allocator, "_iter_idx", Value{ .small_int = 0 });
    return args[0];
}

fn slNext(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);
    const items_v = inst.dict.getStr("_items") orelse {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    };
    if (items_v != .list) {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    }
    const items = items_v.list.items.items;
    const idx_v = inst.dict.getStr("_iter_idx") orelse Value{ .small_int = 0 };
    const idx: usize = if (idx_v == .small_int and idx_v.small_int >= 0) @intCast(idx_v.small_int) else 0;
    if (idx >= items.len) {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    }
    try inst.dict.setStr(interp.allocator, "_iter_idx", Value{ .small_int = @intCast(idx + 1) });
    return items[idx];
}

fn valuesEqual(a: Value, b: Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;
    return switch (a) {
        .none => true,
        .boolean => |va| va == b.boolean,
        .small_int => |va| va == b.small_int,
        .float => |va| va == b.float,
        .str => |va| std.mem.eql(u8, va.bytes, b.str.bytes),
        else => false,
    };
}

// ===== ensureClasses =====

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;
    if (interp.sm_shm_class == null) {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", shmCtor, shmCtorKw);
        try reg(a, d, "close", shmClose);
        try reg(a, d, "unlink", shmUnlink);
        try reg(a, d, "__enter__", shmEnter);
        try reg(a, d, "__exit__", shmExit);
        interp.sm_shm_class = try Class.init(a, "SharedMemory", &.{}, d);
    }
    if (interp.sm_buf_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "__getitem__", bufGetItem);
        try reg(a, d, "__setitem__", bufSetItem);
        interp.sm_buf_class = try Class.init(a, "_ShmBuf", &.{}, d);
    }
    if (interp.sm_sl_class == null) {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", slCtor, slCtorKw);
        try reg(a, d, "__getitem__", slGetItem);
        try reg(a, d, "__setitem__", slSetItem);
        try reg(a, d, "__len__", slLen);
        try reg(a, d, "__iter__", slIter);
        try reg(a, d, "__next__", slNext);
        try reg(a, d, "count", slCount);
        try reg(a, d, "index", slIndex);
        interp.sm_sl_class = try Class.init(a, "ShareableList", &.{}, d);
    }
}

fn shmCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    try ensureClasses(interp);
    return shmCtor(p, args);
}

fn shmCtorKwWrap(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    try ensureClasses(interp);
    return shmCtorKw(p, args, kn, kv);
}

fn slCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    try ensureClasses(interp);
    return slCtor(p, args);
}

fn slCtorKwWrap(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    try ensureClasses(interp);
    return slCtorKw(p, args, kn, kv);
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "multiprocessing.shared_memory");

    interp.sm_registry = null;
    interp.sm_shm_class = null;
    interp.sm_buf_class = null;
    interp.sm_sl_class = null;
    name_counter = 0;

    try ensureClasses(interp);

    try regMKw(a, m, "SharedMemory", shmCtorWrap, shmCtorKwWrap);
    try regMKw(a, m, "ShareableList", slCtorWrap, slCtorKwWrap);

    return m;
}
