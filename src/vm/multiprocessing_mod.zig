//! Pinhole `multiprocessing` module.
//! Processes run synchronously (deferred queue, same model as threading).

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

// ===== helpers =====

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

fn instArg(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

fn getInterp(p: *anyopaque) *Interp {
    return @ptrCast(@alignCast(p));
}

// ===== pending process queue =====

fn runPendingProcs(interp: *Interp) !void {
    while (interp.mp_pending_procs.items.len > 0) {
        const proc_v = interp.mp_pending_procs.orderedRemove(0);
        if (proc_v != .instance) continue;
        const inst = proc_v.instance;
        const target = inst.dict.getStr("_target") orelse Value.none;
        if (target == .none) continue;
        const args_v = inst.dict.getStr("_args") orelse Value.none;
        const passed: []const Value = switch (args_v) {
            .tuple => |t| t.items,
            .list => |l| l.items.items,
            else => &.{},
        };
        _ = try dispatch.invoke(interp, target, passed);
    }
}

// ===== Process =====

fn procStart(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    const a = interp.allocator;
    try inst.dict.setStr(a, "_alive", Value{ .boolean = true });
    try inst.dict.setStr(a, "pid", Value{ .small_int = 1234 });
    try interp.mp_live_procs.append(a, Value{ .instance = inst });
    try interp.mp_pending_procs.append(a, Value{ .instance = inst });
    return Value.none;
}

fn procJoin(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    try runPendingProcs(interp);
    try inst.dict.setStr(interp.allocator, "_alive", Value{ .boolean = false });
    var i: usize = 0;
    while (i < interp.mp_live_procs.items.len) : (i += 1) {
        const item = interp.mp_live_procs.items[i];
        if (item == .instance and item.instance == inst) {
            _ = interp.mp_live_procs.orderedRemove(i);
            break;
        }
    }
    return Value.none;
}

fn procIsAlive(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return inst.dict.getStr("_alive") orelse Value{ .boolean = false };
}

fn procKill(p: *anyopaque, args: []const Value) anyerror!Value {
    return procJoin(p, args);
}

fn procTerminate(p: *anyopaque, args: []const Value) anyerror!Value {
    return procJoin(p, args);
}

fn procEnter(_: *anyopaque, args: []const Value) anyerror!Value {
    return args[0];
}

fn procExit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try procJoin(p, args[0..1]);
    return Value{ .boolean = false };
}

fn processCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    return processCtorImpl(p, args, &.{}, &.{});
}

fn processCtorKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return processCtorImpl(p, args, kn, kv);
}

fn processCtorImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    var target: Value = if (args.len >= 1) args[0] else Value.none;
    var proc_args: Value = Value.none;
    var name: Value = Value{ .str = try Str.init(a, "Process") };
    var daemon: Value = Value{ .boolean = false };
    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        const k = nm.str.bytes;
        if (std.mem.eql(u8, k, "target")) target = vl;
        if (std.mem.eql(u8, k, "args")) proc_args = vl;
        if (std.mem.eql(u8, k, "name")) name = vl;
        if (std.mem.eql(u8, k, "daemon")) daemon = vl;
    }
    if (proc_args == .none) {
        const t = try Tuple.init(a, 0);
        proc_args = Value{ .tuple = t };
    }
    const inst = try Instance.init(a, interp.mp_process_class.?);
    try inst.dict.setStr(a, "_target", target);
    try inst.dict.setStr(a, "_args", proc_args);
    try inst.dict.setStr(a, "name", name);
    try inst.dict.setStr(a, "daemon", daemon);
    try inst.dict.setStr(a, "_alive", Value{ .boolean = false });
    try inst.dict.setStr(a, "pid", Value.none);
    return Value{ .instance = inst };
}

// ===== Queue =====

fn queueCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    return queueCtorImpl(p, args, &.{}, &.{});
}

fn queueCtorKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return queueCtorImpl(p, args, kn, kv);
}

fn queueCtorImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    var maxsize: i64 = 0;
    if (args.len >= 1 and args[0] == .small_int) maxsize = args[0].small_int;
    for (kn, kv) |nm, vl| {
        if (nm == .str and std.mem.eql(u8, nm.str.bytes, "maxsize") and vl == .small_int) maxsize = vl.small_int;
    }
    const inst = try Instance.init(a, interp.mp_queue_class.?);
    const items = try List.init(a);
    try inst.dict.setStr(a, "_items", Value{ .list = items });
    try inst.dict.setStr(a, "_maxsize", Value{ .small_int = maxsize });
    return Value{ .instance = inst };
}

fn queuePut(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    const a = interp.allocator;
    const items_v = inst.dict.getStr("_items") orelse return Value.none;
    if (items_v != .list) return Value.none;
    const maxsize = (inst.dict.getStr("_maxsize") orelse Value{ .small_int = 0 }).small_int;
    if (maxsize > 0 and @as(i64, @intCast(items_v.list.items.items.len)) >= maxsize) {
        try interp.raisePy("OverflowError", "Queue is full");
        return error.PyException;
    }
    const val = if (args.len >= 2) args[1] else Value.none;
    try items_v.list.append(a, val);
    return Value.none;
}

fn queuePutNowait(p: *anyopaque, args: []const Value) anyerror!Value {
    return queuePut(p, args);
}

fn queueGet(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    const items_v = inst.dict.getStr("_items") orelse return Value.none;
    if (items_v != .list) return Value.none;
    const lst = items_v.list;
    if (lst.items.items.len == 0) {
        try interp.raisePy("IndexError", "Queue is empty");
        return error.PyException;
    }
    return lst.items.orderedRemove(0);
}

fn queueGetNowait(p: *anyopaque, args: []const Value) anyerror!Value {
    return queueGet(p, args);
}

fn queueEmpty(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const items_v = inst.dict.getStr("_items") orelse return Value{ .boolean = true };
    if (items_v != .list) return Value{ .boolean = true };
    return Value{ .boolean = items_v.list.items.items.len == 0 };
}

fn queueQsize(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const items_v = inst.dict.getStr("_items") orelse return Value{ .small_int = 0 };
    if (items_v != .list) return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(items_v.list.items.items.len) };
}

fn queueClose(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

// ===== Pipe =====

fn pipeCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    return pipeCtorImpl(p, args, &.{}, &.{});
}

fn pipeCtorKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return pipeCtorImpl(p, args, kn, kv);
}

fn pipeCtorImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    var duplex = true;
    if (args.len >= 1 and args[0] == .boolean) duplex = args[0].boolean;
    for (kn, kv) |nm, vl| {
        if (nm == .str and std.mem.eql(u8, nm.str.bytes, "duplex") and vl == .boolean) duplex = vl.boolean;
    }
    // Create shared buffer list
    const shared = try List.init(a);
    const shared_v = Value{ .list = shared };
    // If duplex, both connections share the same buffer (ping-pong)
    // We use two buffers: a->b and b->a
    const buf_ab = try List.init(a);
    const buf_ba = try List.init(a);
    if (!duplex) {} // simplex: same buffer layout, connections just can't recv from own send

    const ca = try Instance.init(a, interp.mp_conn_class.?);
    const cb = try Instance.init(a, interp.mp_conn_class.?);
    try ca.dict.setStr(a, "_send_buf", Value{ .list = buf_ab });
    try ca.dict.setStr(a, "_recv_buf", Value{ .list = buf_ba });
    try cb.dict.setStr(a, "_send_buf", Value{ .list = buf_ba });
    try cb.dict.setStr(a, "_recv_buf", Value{ .list = buf_ab });
    _ = shared_v;

    const t = try Tuple.init(a, 2);
    t.items[0] = Value{ .instance = ca };
    t.items[1] = Value{ .instance = cb };
    return Value{ .tuple = t };
}

fn connSend(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    const buf_v = inst.dict.getStr("_send_buf") orelse return Value.none;
    if (buf_v != .list) return Value.none;
    const val = if (args.len >= 2) args[1] else Value.none;
    try buf_v.list.append(interp.allocator, val);
    return Value.none;
}

fn connRecv(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    const buf_v = inst.dict.getStr("_recv_buf") orelse return Value.none;
    if (buf_v != .list) return Value.none;
    const lst = buf_v.list;
    if (lst.items.items.len == 0) {
        // Drain pending processes first
        try runPendingProcs(interp);
        if (lst.items.items.len == 0) return Value.none;
    }
    return lst.items.orderedRemove(0);
}

fn connClose(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

// ===== Pool =====

fn poolCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    return poolCtorImpl(p, args, &.{}, &.{});
}

fn poolCtorKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return poolCtorImpl(p, args, kn, kv);
}

fn poolCtorImpl(p: *anyopaque, _args: []const Value, _kn: []const Value, _kv: []const Value) anyerror!Value {
    _ = _args;
    _ = _kn;
    _ = _kv;
    const interp = getInterp(p);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.mp_pool_class.?);
    return Value{ .instance = inst };
}

fn poolApply(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    if (args.len < 2) return Value.none;
    const func = args[1];
    const fargs: []const Value = if (args.len >= 3 and args[2] == .tuple) args[2].tuple.items else &.{};
    return dispatch.invoke(interp, func, fargs);
}

fn poolMap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    if (args.len < 3) return Value.none;
    const func = args[1];
    const iterable: []const Value = switch (args[2]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => &.{},
    };
    const result = try List.init(a);
    for (iterable) |item| {
        const r = try dispatch.invoke(interp, func, &.{item});
        try result.append(a, r);
    }
    return Value{ .list = result };
}

fn poolStarmap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    if (args.len < 3) return Value.none;
    const func = args[1];
    const iterable: []const Value = switch (args[2]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => &.{},
    };
    const result = try List.init(a);
    for (iterable) |item| {
        const call_args: []const Value = switch (item) {
            .tuple => |t| t.items,
            .list => |l| l.items.items,
            else => &.{item},
        };
        const r = try dispatch.invoke(interp, func, call_args);
        try result.append(a, r);
    }
    return Value{ .list = result };
}

fn poolApplyAsync(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const func = args[1];
    const fargs: []const Value = if (args.len >= 3 and args[2] == .tuple) args[2].tuple.items else &.{};
    const result = try dispatch.invoke(interp, func, fargs);
    const inst = try Instance.init(a, interp.mp_async_result_class.?);
    try inst.dict.setStr(a, "_value", result);
    try inst.dict.setStr(a, "_success", Value{ .boolean = true });
    return Value{ .instance = inst };
}

fn poolMapAsync(p: *anyopaque, args: []const Value) anyerror!Value {
    const map_result = try poolMap(p, args);
    const interp = getInterp(p);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.mp_async_result_class.?);
    try inst.dict.setStr(a, "_value", map_result);
    try inst.dict.setStr(a, "_success", Value{ .boolean = true });
    return Value{ .instance = inst };
}

fn asyncResultGet(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return inst.dict.getStr("_value") orelse Value.none;
}

fn asyncResultSuccessful(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return inst.dict.getStr("_success") orelse Value{ .boolean = false };
}

fn asyncResultReady(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .boolean = true };
}

fn poolClose(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn poolTerminate(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn poolJoin(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn poolEnter(_: *anyopaque, args: []const Value) anyerror!Value {
    return args[0];
}

fn poolExit(p: *anyopaque, _: []const Value) anyerror!Value {
    _ = p;
    return Value{ .boolean = false };
}

// ===== Value / Array =====

fn sharedValueCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    const val = if (args.len >= 2) args[1] else Value{ .small_int = 0 };
    const inst = try Instance.init(a, interp.mp_value_class.?);
    try inst.dict.setStr(a, "value", val);
    return Value{ .instance = inst };
}

fn sharedValueGetLock(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    _ = args;
    const inst = try Instance.init(a, interp.mp_lock_class.?);
    try inst.dict.setStr(a, "_locked", Value{ .boolean = false });
    return Value{ .instance = inst };
}

fn sharedArrayCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    const seq = if (args.len >= 2) args[1] else Value.none;
    const inst = try Instance.init(a, interp.mp_array_class.?);
    const items = try List.init(a);
    switch (seq) {
        .list => |l| for (l.items.items) |v| try items.append(a, v),
        .tuple => |t| for (t.items) |v| try items.append(a, v),
        else => {},
    }
    try inst.dict.setStr(a, "_items", Value{ .list = items });
    return Value{ .instance = inst };
}

fn arrayGetItem(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const idx_v = if (args.len >= 2) args[1] else return Value.none;
    const idx: usize = if (idx_v == .small_int) @intCast(idx_v.small_int) else return Value.none;
    const items_v = inst.dict.getStr("_items") orelse return Value.none;
    if (items_v != .list) return Value.none;
    const lst = items_v.list.items.items;
    if (idx >= lst.len) return Value.none;
    return lst[idx];
}

fn arraySetItem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    if (args.len < 3) return Value.none;
    const idx_v = args[1];
    const val = args[2];
    const idx: usize = if (idx_v == .small_int) @intCast(idx_v.small_int) else return Value.none;
    const items_v = inst.dict.getStr("_items") orelse return Value.none;
    if (items_v != .list) return Value.none;
    const lst = items_v.list.items.items;
    if (idx >= lst.len) return Value.none;
    items_v.list.items.items[idx] = val;
    _ = interp;
    return Value.none;
}

fn arrayLen(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const items_v = inst.dict.getStr("_items") orelse return Value{ .small_int = 0 };
    if (items_v != .list) return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(items_v.list.items.items.len) };
}

fn arrayGetLock(p: *anyopaque, args: []const Value) anyerror!Value {
    return sharedValueGetLock(p, args);
}

// ===== Manager =====

fn managerCtor(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.mp_manager_class.?);
    return Value{ .instance = inst };
}

fn managerStart(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn managerShutdown(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn managerEnter(_: *anyopaque, args: []const Value) anyerror!Value {
    return args[0];
}

fn managerExit(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .boolean = false };
}

fn managerDict(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    const d = try Dict.init(a);
    return Value{ .dict = d };
}

fn managerList(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    const l = try List.init(a);
    return Value{ .list = l };
}

fn managerQueue(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.mp_queue_class.?);
    const items = try List.init(a);
    try inst.dict.setStr(a, "_items", Value{ .list = items });
    try inst.dict.setStr(a, "_maxsize", Value{ .small_int = 0 });
    return Value{ .instance = inst };
}

// ===== Lock =====

fn lockCtor(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.mp_lock_class.?);
    try inst.dict.setStr(a, "_locked", Value{ .boolean = false });
    return Value{ .instance = inst };
}

fn lockAcquireCore(interp: *Interp, inst: *Instance, blocking: bool) !Value {
    const already = (inst.dict.getStr("_locked") orelse Value{ .boolean = false }).boolean;
    if (already and !blocking) return Value{ .boolean = false };
    try inst.dict.setStr(interp.allocator, "_locked", Value{ .boolean = true });
    return Value{ .boolean = true };
}

fn lockAcquire(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    const blocking = if (args.len >= 2 and args[1] == .boolean) args[1].boolean else true;
    return lockAcquireCore(interp, inst, blocking);
}

fn lockAcquireKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    var blocking = true;
    for (kn, kv) |nm, vl| {
        if (nm == .str and std.mem.eql(u8, nm.str.bytes, "blocking") and vl == .boolean) blocking = vl.boolean;
    }
    return lockAcquireCore(interp, inst, blocking);
}

fn lockRelease(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    try inst.dict.setStr(interp.allocator, "_locked", Value{ .boolean = false });
    return Value.none;
}

fn lockLocked(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return inst.dict.getStr("_locked") orelse Value{ .boolean = false };
}

fn lockEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try lockAcquire(p, args);
    return args[0];
}

fn lockExit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try lockRelease(p, args[0..1]);
    return Value{ .boolean = false };
}

// ===== Event =====

fn eventCtor(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.mp_event_class.?);
    try inst.dict.setStr(a, "_set", Value{ .boolean = false });
    return Value{ .instance = inst };
}

fn eventSet(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    try inst.dict.setStr(interp.allocator, "_set", Value{ .boolean = true });
    return Value.none;
}

fn eventClear(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    try inst.dict.setStr(interp.allocator, "_set", Value{ .boolean = false });
    return Value.none;
}

fn eventIsSet(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return inst.dict.getStr("_set") orelse Value{ .boolean = false };
}

fn eventWait(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    // If not set, drain pending procs first
    const inst = try instArg(args);
    const is_set = (inst.dict.getStr("_set") orelse Value{ .boolean = false }).boolean;
    if (!is_set) try runPendingProcs(interp);
    return inst.dict.getStr("_set") orelse Value{ .boolean = false };
}

// ===== Semaphore =====

fn semCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    const initial: i64 = if (args.len >= 1 and args[0] == .small_int) args[0].small_int else 1;
    const inst = try Instance.init(a, interp.mp_sem_class.?);
    try inst.dict.setStr(a, "_count", Value{ .small_int = initial });
    return Value{ .instance = inst };
}

fn semAcquireCore(interp: *Interp, inst: *Instance, blocking: bool) !Value {
    const cur = (inst.dict.getStr("_count") orelse Value{ .small_int = 0 }).small_int;
    if (cur > 0) {
        try inst.dict.setStr(interp.allocator, "_count", Value{ .small_int = cur - 1 });
        return Value{ .boolean = true };
    }
    if (!blocking) return Value{ .boolean = false };
    return Value{ .boolean = false };
}

fn semAcquire(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    const blocking = if (args.len >= 2 and args[1] == .boolean) args[1].boolean else true;
    return semAcquireCore(interp, inst, blocking);
}

fn semRelease(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    const cur = (inst.dict.getStr("_count") orelse Value{ .small_int = 0 }).small_int;
    try inst.dict.setStr(interp.allocator, "_count", Value{ .small_int = cur + 1 });
    return Value.none;
}

fn semEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try semAcquireCore(getInterp(p), try instArg(args), true);
    return args[0];
}

fn semExit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try semRelease(p, args[0..1]);
    return Value{ .boolean = false };
}

// ===== BoundedSemaphore =====

fn boundedSemCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    const initial: i64 = if (args.len >= 1 and args[0] == .small_int) args[0].small_int else 1;
    const inst = try Instance.init(a, interp.mp_bounded_sem_class.?);
    try inst.dict.setStr(a, "_count", Value{ .small_int = initial });
    try inst.dict.setStr(a, "_max", Value{ .small_int = initial });
    return Value{ .instance = inst };
}

fn boundedSemRelease(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    const cur = (inst.dict.getStr("_count") orelse Value{ .small_int = 0 }).small_int;
    const max = (inst.dict.getStr("_max") orelse Value{ .small_int = 1 }).small_int;
    if (cur + 1 > max) {
        try interp.raisePy("ValueError", "Semaphore released too many times");
        return error.PyException;
    }
    try inst.dict.setStr(interp.allocator, "_count", Value{ .small_int = cur + 1 });
    return Value.none;
}

// ===== Condition =====

fn condCtor(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.mp_cond_class.?);
    try inst.dict.setStr(a, "_locked", Value{ .boolean = false });
    return Value{ .instance = inst };
}

fn condAcquire(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    try inst.dict.setStr(interp.allocator, "_locked", Value{ .boolean = true });
    return Value{ .boolean = true };
}

fn condRelease(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    try inst.dict.setStr(interp.allocator, "_locked", Value{ .boolean = false });
    return Value.none;
}

fn condNotify(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn condNotifyAll(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn condWait(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    if (args.len >= 1 and args[0] == .instance) {
        try args[0].instance.dict.setStr(interp.allocator, "_locked", Value{ .boolean = false });
    }
    try runPendingProcs(interp);
    if (args.len >= 1 and args[0] == .instance) {
        try args[0].instance.dict.setStr(interp.allocator, "_locked", Value{ .boolean = true });
    }
    return Value{ .boolean = true };
}

fn condWaitFor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    // args: [self, predicate]
    if (args.len >= 2) {
        // Try running the predicate; if false, drain pending procs
        const pred = args[1];
        const r = try dispatch.invoke(interp, pred, &.{});
        if (r == .boolean and r.boolean) return r;
        // Drain pending to allow other processes to produce
        if (args[0] == .instance) {
            try args[0].instance.dict.setStr(interp.allocator, "_locked", Value{ .boolean = false });
        }
        try runPendingProcs(interp);
        if (args[0] == .instance) {
            try args[0].instance.dict.setStr(interp.allocator, "_locked", Value{ .boolean = true });
        }
    }
    return Value{ .boolean = true };
}

fn condEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try condAcquire(p, args);
    return args[0];
}

fn condExit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try condRelease(p, args[0..1]);
    return Value{ .boolean = false };
}

// ===== Barrier =====

fn barrierCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    const parties: i64 = if (args.len >= 1 and args[0] == .small_int) args[0].small_int else 1;
    const inst = try Instance.init(a, interp.mp_barrier_class.?);
    try inst.dict.setStr(a, "parties", Value{ .small_int = parties });
    try inst.dict.setStr(a, "n_waiting", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "broken", Value{ .boolean = false });
    return Value{ .instance = inst };
}

fn barrierWait(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    const parties = (inst.dict.getStr("parties") orelse Value{ .small_int = 1 }).small_int;
    const waiting = (inst.dict.getStr("n_waiting") orelse Value{ .small_int = 0 }).small_int;
    const new_waiting = waiting + 1;
    if (new_waiting >= parties) {
        // All parties arrived; reset
        try inst.dict.setStr(interp.allocator, "n_waiting", Value{ .small_int = 0 });
    } else {
        try inst.dict.setStr(interp.allocator, "n_waiting", Value{ .small_int = new_waiting });
        // Not all parties yet; drain pending so others can arrive
        try runPendingProcs(interp);
    }
    return Value{ .small_int = 0 };
}

fn barrierReset(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    try inst.dict.setStr(interp.allocator, "broken", Value{ .boolean = false });
    try inst.dict.setStr(interp.allocator, "n_waiting", Value{ .small_int = 0 });
    return Value.none;
}

fn barrierAbort(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const inst = try instArg(args);
    try inst.dict.setStr(interp.allocator, "broken", Value{ .boolean = true });
    return Value.none;
}

// ===== ensureClasses =====

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;

    if (interp.mp_process_class == null) {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", processCtor, processCtorKw);
        try reg(a, d, "start", procStart);
        try reg(a, d, "join", procJoin);
        try reg(a, d, "is_alive", procIsAlive);
        try reg(a, d, "kill", procKill);
        try reg(a, d, "terminate", procTerminate);
        try reg(a, d, "__enter__", procEnter);
        try reg(a, d, "__exit__", procExit);
        interp.mp_process_class = try Class.init(a, "Process", &.{}, d);
    }
    if (interp.mp_queue_class == null) {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", queueCtor, queueCtorKw);
        try reg(a, d, "put", queuePut);
        try reg(a, d, "put_nowait", queuePutNowait);
        try reg(a, d, "get", queueGet);
        try reg(a, d, "get_nowait", queueGetNowait);
        try reg(a, d, "empty", queueEmpty);
        try reg(a, d, "qsize", queueQsize);
        try reg(a, d, "close", queueClose);
        interp.mp_queue_class = try Class.init(a, "Queue", &.{}, d);
    }
    if (interp.mp_conn_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "send", connSend);
        try reg(a, d, "recv", connRecv);
        try reg(a, d, "close", connClose);
        interp.mp_conn_class = try Class.init(a, "Connection", &.{}, d);
    }
    if (interp.mp_pool_class == null) {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", poolCtor, poolCtorKw);
        try reg(a, d, "apply", poolApply);
        try reg(a, d, "map", poolMap);
        try reg(a, d, "starmap", poolStarmap);
        try reg(a, d, "apply_async", poolApplyAsync);
        try reg(a, d, "map_async", poolMapAsync);
        try reg(a, d, "close", poolClose);
        try reg(a, d, "terminate", poolTerminate);
        try reg(a, d, "join", poolJoin);
        try reg(a, d, "__enter__", poolEnter);
        try reg(a, d, "__exit__", poolExit);
        interp.mp_pool_class = try Class.init(a, "Pool", &.{}, d);
    }
    if (interp.mp_async_result_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "get", asyncResultGet);
        try reg(a, d, "successful", asyncResultSuccessful);
        try reg(a, d, "ready", asyncResultReady);
        interp.mp_async_result_class = try Class.init(a, "AsyncResult", &.{}, d);
    }
    if (interp.mp_value_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "get_lock", sharedValueGetLock);
        interp.mp_value_class = try Class.init(a, "Value", &.{}, d);
    }
    if (interp.mp_array_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "__getitem__", arrayGetItem);
        try reg(a, d, "__setitem__", arraySetItem);
        try reg(a, d, "__len__", arrayLen);
        try reg(a, d, "get_lock", arrayGetLock);
        interp.mp_array_class = try Class.init(a, "Array", &.{}, d);
    }
    if (interp.mp_manager_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "start", managerStart);
        try reg(a, d, "shutdown", managerShutdown);
        try reg(a, d, "dict", managerDict);
        try reg(a, d, "list", managerList);
        try reg(a, d, "Queue", managerQueue);
        try reg(a, d, "__enter__", managerEnter);
        try reg(a, d, "__exit__", managerExit);
        interp.mp_manager_class = try Class.init(a, "SyncManager", &.{}, d);
    }
    if (interp.mp_lock_class == null) {
        const d = try Dict.init(a);
        try regKw(a, d, "acquire", lockAcquire, lockAcquireKw);
        try reg(a, d, "release", lockRelease);
        try reg(a, d, "locked", lockLocked);
        try reg(a, d, "__enter__", lockEnter);
        try reg(a, d, "__exit__", lockExit);
        interp.mp_lock_class = try Class.init(a, "Lock", &.{}, d);
    }
    if (interp.mp_event_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "set", eventSet);
        try reg(a, d, "clear", eventClear);
        try reg(a, d, "is_set", eventIsSet);
        try reg(a, d, "wait", eventWait);
        interp.mp_event_class = try Class.init(a, "Event", &.{}, d);
    }
    if (interp.mp_sem_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "acquire", semAcquire);
        try reg(a, d, "release", semRelease);
        try reg(a, d, "__enter__", semEnter);
        try reg(a, d, "__exit__", semExit);
        interp.mp_sem_class = try Class.init(a, "Semaphore", &.{}, d);
    }
    if (interp.mp_bounded_sem_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "acquire", semAcquire);
        try reg(a, d, "release", boundedSemRelease);
        try reg(a, d, "__enter__", semEnter);
        try reg(a, d, "__exit__", semExit);
        interp.mp_bounded_sem_class = try Class.init(a, "BoundedSemaphore", &.{}, d);
    }
    if (interp.mp_cond_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "acquire", condAcquire);
        try reg(a, d, "release", condRelease);
        try reg(a, d, "notify", condNotify);
        try reg(a, d, "notify_all", condNotifyAll);
        try reg(a, d, "wait", condWait);
        try reg(a, d, "wait_for", condWaitFor);
        try reg(a, d, "__enter__", condEnter);
        try reg(a, d, "__exit__", condExit);
        interp.mp_cond_class = try Class.init(a, "Condition", &.{}, d);
    }
    if (interp.mp_barrier_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "wait", barrierWait);
        try reg(a, d, "reset", barrierReset);
        try reg(a, d, "abort", barrierAbort);
        interp.mp_barrier_class = try Class.init(a, "Barrier", &.{}, d);
    }
}

// ===== module-level functions =====

fn cpuCountFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .small_int = 1 };
}

fn currentProcessFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    if (interp.mp_main_process) |inst| return Value{ .instance = inst };
    try ensureClasses(interp);
    const inst = try Instance.init(a, interp.mp_process_class.?);
    try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, "MainProcess") });
    try inst.dict.setStr(a, "_alive", Value{ .boolean = true });
    try inst.dict.setStr(a, "pid", Value{ .small_int = 1 });
    interp.mp_main_process = inst;
    return Value{ .instance = inst };
}

fn parentProcessFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn activeChildrenFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = getInterp(p);
    const a = interp.allocator;
    const lst = try List.init(a);
    for (interp.mp_live_procs.items) |v| try lst.append(a, v);
    return Value{ .list = lst };
}

fn freezeSupportFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn getStartMethodFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = getInterp(p);
    return Value{ .str = try Str.init(interp.allocator, "fork") };
}

fn processCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return processCtor(p, args);
}

fn processCtorKwWrap(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return processCtorKw(p, args, kn, kv);
}

fn queueCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return queueCtor(p, args);
}

fn queueCtorKwWrap(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return queueCtorKw(p, args, kn, kv);
}

fn pipeCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return pipeCtor(p, args);
}

fn pipeCtorKwWrap(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return pipeCtorKw(p, args, kn, kv);
}

fn poolCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return poolCtor(p, args);
}

fn poolCtorKwWrap(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return poolCtorKw(p, args, kn, kv);
}

fn valueCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return sharedValueCtor(p, args);
}

fn arrayCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return sharedArrayCtor(p, args);
}

fn managerCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return managerCtor(p, args);
}

fn lockCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return lockCtor(p, args);
}

fn eventCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return eventCtor(p, args);
}

fn semCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return semCtor(p, args);
}

fn boundedSemCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return boundedSemCtor(p, args);
}

fn condCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return condCtor(p, args);
}

fn barrierCtorWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = getInterp(p);
    try ensureClasses(interp);
    return barrierCtor(p, args);
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "multiprocessing");

    // Reset per-interpreter state
    interp.mp_main_process = null;
    interp.mp_live_procs = .empty;
    interp.mp_pending_procs = .empty;
    interp.mp_process_class = null;
    interp.mp_queue_class = null;
    interp.mp_conn_class = null;
    interp.mp_pool_class = null;
    interp.mp_async_result_class = null;
    interp.mp_value_class = null;
    interp.mp_array_class = null;
    interp.mp_manager_class = null;
    interp.mp_lock_class = null;
    interp.mp_event_class = null;
    interp.mp_sem_class = null;
    interp.mp_bounded_sem_class = null;
    interp.mp_cond_class = null;
    interp.mp_barrier_class = null;

    try ensureClasses(interp);

    try regM(a, m, "cpu_count", cpuCountFn);
    try regM(a, m, "current_process", currentProcessFn);
    try regM(a, m, "parent_process", parentProcessFn);
    try regM(a, m, "active_children", activeChildrenFn);
    try regM(a, m, "freeze_support", freezeSupportFn);
    try regM(a, m, "get_start_method", getStartMethodFn);
    try regMKw(a, m, "Process", processCtorWrap, processCtorKwWrap);
    try regMKw(a, m, "Queue", queueCtorWrap, queueCtorKwWrap);
    try regMKw(a, m, "Pipe", pipeCtorWrap, pipeCtorKwWrap);
    try regMKw(a, m, "Pool", poolCtorWrap, poolCtorKwWrap);
    try regM(a, m, "Value", valueCtorWrap);
    try regM(a, m, "Array", arrayCtorWrap);
    try regM(a, m, "Manager", managerCtorWrap);
    try regM(a, m, "Lock", lockCtorWrap);
    try regM(a, m, "Event", eventCtorWrap);
    try regM(a, m, "Semaphore", semCtorWrap);
    try regM(a, m, "BoundedSemaphore", boundedSemCtorWrap);
    try regM(a, m, "Condition", condCtorWrap);
    try regM(a, m, "Barrier", barrierCtorWrap);

    return m;
}
