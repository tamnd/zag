//! `queue` module — Queue, LifoQueue, PriorityQueue, SimpleQueue.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

fn gi(p: *anyopaque) *Interp {
    return @ptrCast(@alignCast(p));
}

fn instArg(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

fn sv(a: std.mem.Allocator, s: []const u8) !Value {
    return Value{ .str = try Str.init(a, s) };
}

fn regKwD(a: std.mem.Allocator, d: *Dict, name: []const u8, f: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f, .kw_func = kw };
    try d.setStr(a, name, Value{ .builtin_fn = bf });
}

fn regD(a: std.mem.Allocator, d: *Dict, name: []const u8, f: BuiltinFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f };
    try d.setStr(a, name, Value{ .builtin_fn = bf });
}

// ===== Queue state stored on instance =====
// _items: list, _maxsize: int, _unfinished: int, _shutdown: bool, _shutdown_immediate: bool

fn getItems(inst: *Instance) ?*List {
    const v = inst.dict.getStr("_items") orelse return null;
    if (v != .list) return null;
    return v.list;
}

fn getMaxsize(inst: *Instance) i64 {
    const v = inst.dict.getStr("_maxsize") orelse return 0;
    if (v != .small_int) return 0;
    return v.small_int;
}

fn getUnfinished(inst: *Instance) i64 {
    const v = inst.dict.getStr("_unfinished") orelse return 0;
    if (v != .small_int) return 0;
    return v.small_int;
}

fn isShutdown(inst: *Instance) bool {
    const v = inst.dict.getStr("_shutdown") orelse return false;
    return v == .boolean and v.boolean;
}

fn isShutdownImmediate(inst: *Instance) bool {
    const v = inst.dict.getStr("_shutdown_immediate") orelse return false;
    return v == .boolean and v.boolean;
}

// ===== Queue type tags =====
const QueueType = enum { fifo, lifo, priority, simple };

fn getQType(inst: *Instance) QueueType {
    const v = inst.dict.getStr("_qtype") orelse return .fifo;
    if (v != .small_int) return .fifo;
    return @enumFromInt(v.small_int);
}

// ===== Heap for PriorityQueue =====
// Stored as list; heapify/push/pop implemented here.

fn cmpLess(a_v: Value, b_v: Value) bool {
    return switch (a_v) {
        .small_int => |a| switch (b_v) {
            .small_int => |b| a < b,
            .float => |b| @as(f64, @floatFromInt(a)) < b,
            else => true,
        },
        .float => |a| switch (b_v) {
            .small_int => |b| a < @as(f64, @floatFromInt(b)),
            .float => |b| a < b,
            else => true,
        },
        .tuple => |ta| switch (b_v) {
            .tuple => |tb| blk: {
                const n = @min(ta.items.len, tb.items.len);
                for (0..n) |i| {
                    if (cmpLess(ta.items[i], tb.items[i])) break :blk true;
                    if (cmpLess(tb.items[i], ta.items[i])) break :blk false;
                }
                break :blk ta.items.len < tb.items.len;
            },
            else => true,
        },
        .str => |sa| switch (b_v) {
            .str => |sb| std.mem.lessThan(u8, sa.bytes, sb.bytes),
            else => true,
        },
        else => false,
    };
}

fn heapPush(a: std.mem.Allocator, items: *List, val: Value) !void {
    try items.items.append(a, val);
    var i = items.items.items.len - 1;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (cmpLess(items.items.items[i], items.items.items[parent])) {
            const tmp = items.items.items[i];
            items.items.items[i] = items.items.items[parent];
            items.items.items[parent] = tmp;
            i = parent;
        } else break;
    }
}

fn heapPop(items: *List) ?Value {
    if (items.items.items.len == 0) return null;
    const result = items.items.items[0];
    const last = items.items.pop() orelse return result;
    if (items.items.items.len == 0) return result;
    items.items.items[0] = last;
    // Sift down
    var i: usize = 0;
    const n = items.items.items.len;
    while (true) {
        var smallest = i;
        const l = 2 * i + 1;
        const r = 2 * i + 2;
        if (l < n and cmpLess(items.items.items[l], items.items.items[smallest])) smallest = l;
        if (r < n and cmpLess(items.items.items[r], items.items.items[smallest])) smallest = r;
        if (smallest == i) break;
        const tmp = items.items.items[i];
        items.items.items[i] = items.items.items[smallest];
        items.items.items[smallest] = tmp;
        i = smallest;
    }
    return result;
}

// ===== Generic init =====

fn queueInitKwHelper(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value, qtype: QueueType) !Value {
    const a = gi(p).allocator;
    const inst = try instArg(args);

    var maxsize: i64 = if (args.len >= 2 and args[1] == .small_int) args[1].small_int else 0;
    for (kn, kv) |nm, vl| {
        if (nm == .str and std.mem.eql(u8, nm.str.bytes, "maxsize") and vl == .small_int)
            maxsize = vl.small_int;
    }
    const items = try List.init(a);
    try inst.dict.setStr(a, "_items", Value{ .list = items });
    try inst.dict.setStr(a, "_maxsize", Value{ .small_int = maxsize });
    try inst.dict.setStr(a, "_unfinished", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "_shutdown", Value{ .boolean = false });
    try inst.dict.setStr(a, "_shutdown_immediate", Value{ .boolean = false });
    try inst.dict.setStr(a, "_qtype", Value{ .small_int = @intFromEnum(qtype) });
    return Value.none;
}

fn queueInitFifo(p: *anyopaque, args: []const Value) anyerror!Value {
    return queueInitKwHelper(p, args, &.{}, &.{}, .fifo);
}

fn queueInitFifoKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return queueInitKwHelper(p, args, kn, kv, .fifo);
}

fn queueInitLifo(p: *anyopaque, args: []const Value) anyerror!Value {
    return queueInitKwHelper(p, args, &.{}, &.{}, .lifo);
}

fn queueInitLifoKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return queueInitKwHelper(p, args, kn, kv, .lifo);
}

fn queueInitPriority(p: *anyopaque, args: []const Value) anyerror!Value {
    return queueInitKwHelper(p, args, &.{}, &.{}, .priority);
}

fn queueInitPriorityKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return queueInitKwHelper(p, args, kn, kv, .priority);
}

fn queueInitSimple(p: *anyopaque, args: []const Value) anyerror!Value {
    return queueInitKwHelper(p, args, &.{}, &.{}, .simple);
}

fn queueInitSimpleKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return queueInitKwHelper(p, args, kn, kv, .simple);
}

// ===== put =====

fn queuePut(p: *anyopaque, args: []const Value) anyerror!Value {
    return queuePutKw(p, args, &.{}, &.{});
}

fn queuePutKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);

    if (isShutdown(inst)) {
        try interp.raisePy("ShutDown", "");
        return error.PyException;
    }

    const item: Value = if (args.len >= 2) args[1] else Value.none;
    var block = true;
    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        if (std.mem.eql(u8, nm.str.bytes, "block")) block = vl == .boolean and vl.boolean;
        // timeout: we ignore and treat as immediate
    }
    if (args.len >= 3) block = args[2] == .boolean and args[2].boolean;

    const items = getItems(inst) orelse return Value.none;
    const maxsize = getMaxsize(inst);

    if (maxsize > 0 and @as(i64, @intCast(items.items.items.len)) >= maxsize) {
        if (!block) {
            try interp.raisePy("Full", "");
            return error.PyException;
        }
        // Check timeout kwarg — if specified and maxsize reached, raise Full
        var has_timeout = false;
        for (kn) |nm| {
            if (nm == .str and std.mem.eql(u8, nm.str.bytes, "timeout")) has_timeout = true;
        }
        if (has_timeout) {
            try interp.raisePy("Full", "");
            return error.PyException;
        }
        // No real blocking in single-threaded mode
        try interp.raisePy("Full", "");
        return error.PyException;
    }

    switch (getQType(inst)) {
        .priority => try heapPush(a, items, item),
        else => try items.items.append(a, item),
    }

    // Increment unfinished tasks
    const uf = getUnfinished(inst);
    try inst.dict.setStr(a, "_unfinished", Value{ .small_int = uf + 1 });

    return Value.none;
}

// ===== get =====

fn queueGet(p: *anyopaque, args: []const Value) anyerror!Value {
    return queueGetKw(p, args, &.{}, &.{});
}

fn queueGetKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);

    if (isShutdownImmediate(inst)) {
        try interp.raisePy("ShutDown", "");
        return error.PyException;
    }

    var block = true;
    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        if (std.mem.eql(u8, nm.str.bytes, "block")) block = vl == .boolean and vl.boolean;
    }
    if (args.len >= 2) block = args[1] == .boolean and args[1].boolean;

    const items = getItems(inst) orelse {
        try interp.raisePy("Empty", "");
        return error.PyException;
    };

    if (items.items.items.len == 0) {
        if (!block) {
            try interp.raisePy("Empty", "");
            return error.PyException;
        }
        // Check timeout
        var has_timeout = false;
        for (kn) |nm| {
            if (nm == .str and std.mem.eql(u8, nm.str.bytes, "timeout")) has_timeout = true;
        }
        if (has_timeout) {
            try interp.raisePy("Empty", "");
            return error.PyException;
        }
        // No real blocking
        try interp.raisePy("Empty", "");
        return error.PyException;
    }

    return switch (getQType(inst)) {
        .lifo => items.items.pop() orelse Value.none,
        .priority => heapPop(items) orelse Value.none,
        else => items.items.orderedRemove(0),
    };
}

// ===== put_nowait / get_nowait =====

fn queuePutNowait(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const kn = &[_]Value{Value{ .str = try Str.init(a, "block") }};
    const kv = &[_]Value{Value{ .boolean = false }};
    return queuePutKw(p, args, kn, kv);
}

fn queueGetNowait(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const kn = &[_]Value{Value{ .str = try Str.init(a, "block") }};
    const kv = &[_]Value{Value{ .boolean = false }};
    return queueGetKw(p, args, kn, kv);
}

// ===== qsize / empty / full =====

fn queueQsize(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const items = getItems(inst) orelse return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(items.items.items.len) };
}

fn queueEmpty(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const items = getItems(inst) orelse return Value{ .boolean = true };
    return Value{ .boolean = items.items.items.len == 0 };
}

fn queueFull(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const items = getItems(inst) orelse return Value{ .boolean = false };
    const maxsize = getMaxsize(inst);
    if (maxsize <= 0) return Value{ .boolean = false };
    return Value{ .boolean = @as(i64, @intCast(items.items.items.len)) >= maxsize };
}

// ===== task_done =====

fn queueTaskDone(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const uf = getUnfinished(inst);
    if (uf <= 0) {
        try interp.raisePy("ValueError", "task_done() called too many times");
        return error.PyException;
    }
    try inst.dict.setStr(a, "_unfinished", Value{ .small_int = uf - 1 });
    return Value.none;
}

// ===== join =====

fn queueJoin(_: *anyopaque, args: []const Value) anyerror!Value {
    // In single-threaded mode, join() is a no-op once all tasks are done.
    // Since we run threads synchronously, all task_done() calls happen before join().
    _ = try instArg(args);
    return Value.none;
}

// ===== shutdown =====

fn queueShutdown(p: *anyopaque, args: []const Value) anyerror!Value {
    return queueShutdownKw(p, args, &.{}, &.{});
}

fn queueShutdownKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);

    var immediate = false;
    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        if (std.mem.eql(u8, nm.str.bytes, "immediate")) immediate = vl == .boolean and vl.boolean;
    }
    if (args.len >= 2) immediate = args[1] == .boolean and args[1].boolean;

    try inst.dict.setStr(a, "_shutdown", Value{ .boolean = true });
    if (immediate) {
        try inst.dict.setStr(a, "_shutdown_immediate", Value{ .boolean = true });
    }
    return Value.none;
}

// ===== Simple Queue put (no task tracking) =====

fn simplePut(p: *anyopaque, args: []const Value) anyerror!Value {
    return simplePutKw(p, args, &.{}, &.{});
}

fn simplePutKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const item: Value = if (args.len >= 2) args[1] else Value.none;
    const items = getItems(inst) orelse return Value.none;
    try items.items.append(a, item);
    return Value.none;
}

fn simpleGet(p: *anyopaque, args: []const Value) anyerror!Value {
    return simpleGetKw(p, args, &.{}, &.{});
}

fn simpleGetKw(p: *anyopaque, args: []const Value, kn: []const Value, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);
    var block = true;
    for (kn) |nm| {
        if (nm == .str and std.mem.eql(u8, nm.str.bytes, "block")) block = false;
    }
    const items = getItems(inst) orelse {
        try interp.raisePy("Empty", "");
        return error.PyException;
    };
    if (items.items.items.len == 0) {
        if (!block) {
            try interp.raisePy("Empty", "");
            return error.PyException;
        }
        try interp.raisePy("Empty", "");
        return error.PyException;
    }
    return items.items.orderedRemove(0);
}

fn simpleGetNowait(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const kn = &[_]Value{Value{ .str = try Str.init(a, "block") }};
    return simpleGetKw(p, args, kn, &.{});
}

fn simplePutNowait(p: *anyopaque, args: []const Value) anyerror!Value {
    return simplePut(p, args);
}

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;

    const exc_base: ?*Class = blk: {
        const v = interp.builtins.getStr("Exception") orelse break :blk null;
        if (v != .class) break :blk null;
        break :blk v.class;
    };
    const exc_bases: []const *Class = if (exc_base) |b| &[_]*Class{b} else &.{};

    if (interp.queue_empty_class == null) {
        const d = try Dict.init(a);
        interp.queue_empty_class = try Class.init(a, "Empty", exc_bases, d);
        try interp.builtins.setStr(a, "Empty", Value{ .class = interp.queue_empty_class.? });
    }
    if (interp.queue_full_class == null) {
        const d = try Dict.init(a);
        interp.queue_full_class = try Class.init(a, "Full", exc_bases, d);
        try interp.builtins.setStr(a, "Full", Value{ .class = interp.queue_full_class.? });
    }
    if (interp.queue_shutdown_class == null) {
        const d = try Dict.init(a);
        interp.queue_shutdown_class = try Class.init(a, "ShutDown", exc_bases, d);
        try interp.builtins.setStr(a, "ShutDown", Value{ .class = interp.queue_shutdown_class.? });
    }

    if (interp.queue_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "__init__", queueInitFifo, queueInitFifoKw);
        try regKwD(a, d, "put", queuePut, queuePutKw);
        try regKwD(a, d, "get", queueGet, queueGetKw);
        try regD(a, d, "put_nowait", queuePutNowait);
        try regD(a, d, "get_nowait", queueGetNowait);
        try regD(a, d, "qsize", queueQsize);
        try regD(a, d, "empty", queueEmpty);
        try regD(a, d, "full", queueFull);
        try regD(a, d, "task_done", queueTaskDone);
        try regD(a, d, "join", queueJoin);
        try regKwD(a, d, "shutdown", queueShutdown, queueShutdownKw);
        interp.queue_class = try Class.init(a, "Queue", &.{}, d);
    }

    if (interp.lifo_queue_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "__init__", queueInitLifo, queueInitLifoKw);
        try regKwD(a, d, "put", queuePut, queuePutKw);
        try regKwD(a, d, "get", queueGet, queueGetKw);
        try regD(a, d, "put_nowait", queuePutNowait);
        try regD(a, d, "get_nowait", queueGetNowait);
        try regD(a, d, "qsize", queueQsize);
        try regD(a, d, "empty", queueEmpty);
        try regD(a, d, "full", queueFull);
        try regD(a, d, "task_done", queueTaskDone);
        try regD(a, d, "join", queueJoin);
        try regKwD(a, d, "shutdown", queueShutdown, queueShutdownKw);
        interp.lifo_queue_class = try Class.init(a, "LifoQueue", &.{}, d);
    }

    if (interp.priority_queue_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "__init__", queueInitPriority, queueInitPriorityKw);
        try regKwD(a, d, "put", queuePut, queuePutKw);
        try regKwD(a, d, "get", queueGet, queueGetKw);
        try regD(a, d, "put_nowait", queuePutNowait);
        try regD(a, d, "get_nowait", queueGetNowait);
        try regD(a, d, "qsize", queueQsize);
        try regD(a, d, "empty", queueEmpty);
        try regD(a, d, "full", queueFull);
        try regD(a, d, "task_done", queueTaskDone);
        try regD(a, d, "join", queueJoin);
        try regKwD(a, d, "shutdown", queueShutdown, queueShutdownKw);
        interp.priority_queue_class = try Class.init(a, "PriorityQueue", &.{}, d);
    }

    if (interp.simple_queue_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "__init__", queueInitSimple, queueInitSimpleKw);
        try regKwD(a, d, "put", simplePut, simplePutKw);
        try regKwD(a, d, "get", simpleGet, simpleGetKw);
        try regD(a, d, "put_nowait", simplePutNowait);
        try regD(a, d, "get_nowait", simpleGetNowait);
        try regD(a, d, "qsize", queueQsize);
        try regD(a, d, "empty", queueEmpty);
        interp.simple_queue_class = try Class.init(a, "SimpleQueue", &.{}, d);
    }
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);

    const m = try Module.init(a, "queue");
    try m.attrs.setStr(a, "Queue", Value{ .class = interp.queue_class.? });
    try m.attrs.setStr(a, "LifoQueue", Value{ .class = interp.lifo_queue_class.? });
    try m.attrs.setStr(a, "PriorityQueue", Value{ .class = interp.priority_queue_class.? });
    try m.attrs.setStr(a, "SimpleQueue", Value{ .class = interp.simple_queue_class.? });
    try m.attrs.setStr(a, "Empty", Value{ .class = interp.queue_empty_class.? });
    try m.attrs.setStr(a, "Full", Value{ .class = interp.queue_full_class.? });
    try m.attrs.setStr(a, "ShutDown", Value{ .class = interp.queue_shutdown_class.? });

    return m;
}
