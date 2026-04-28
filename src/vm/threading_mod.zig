//! Pinhole `threading`. zag is single-threaded, so threads run their
//! target inline on `start()`. Locks/semaphores/events still track
//! state because Python code reads `locked()`, `is_set()`, etc. The
//! shape covers the patterns from the Python 3.13+ thread safety docs.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;

const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Str = @import("../object/string.zig").Str;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;

const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "threading");
    try ensureClasses(interp);
    try regCtor(interp, m, "Lock", lockCtor);
    try regCtor(interp, m, "RLock", rlockCtor);
    try regCtorKw(interp, m, "Thread", threadCtorPos, threadCtorKw);
    try regCtor(interp, m, "Event", eventCtor);
    try regCtor(interp, m, "Semaphore", semCtor);
    try regCtor(interp, m, "BoundedSemaphore", boundedSemCtor);
    try regCtor(interp, m, "Condition", condCtor);
    try regCtor(interp, m, "Barrier", barrierCtor);
    try regCtor(interp, m, "local", localCtor);
    try reg(interp, m, "current_thread", currentThreadFn);
    try reg(interp, m, "main_thread", mainThreadFn);
    try reg(interp, m, "active_count", activeCountFn);
    try reg(interp, m, "enumerate", enumerateFn);
    try reg(interp, m, "get_ident", getIdentFn);
    try reg(interp, m, "get_native_id", getIdentFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regCtor(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    try reg(interp, m, name, func);
}

fn regCtorKw(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn methodRegKw(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn argInst(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;
    if (interp.threading_lock_class == null) {
        const d = try Dict.init(a);
        try methodRegKw(a, d, "acquire", lockAcquire, lockAcquireKw);
        try methodReg(a, d, "release", lockRelease);
        try methodReg(a, d, "locked", lockLocked);
        try methodReg(a, d, "__enter__", lockEnter);
        try methodReg(a, d, "__exit__", lockExit);
        interp.threading_lock_class = try Class.init(a, "lock", &.{}, d);
    }
    if (interp.threading_rlock_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "acquire", rlockAcquire);
        try methodReg(a, d, "release", rlockRelease);
        try methodReg(a, d, "__enter__", rlockEnter);
        try methodReg(a, d, "__exit__", rlockExit);
        interp.threading_rlock_class = try Class.init(a, "RLock", &.{}, d);
    }
    if (interp.threading_thread_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "start", threadStart);
        try methodReg(a, d, "join", threadJoin);
        try methodReg(a, d, "is_alive", threadIsAlive);
        try methodReg(a, d, "run", threadRun);
        interp.threading_thread_class = try Class.init(a, "Thread", &.{}, d);
    }
    if (interp.threading_main_thread_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "start", threadStart);
        try methodReg(a, d, "join", threadJoin);
        try methodReg(a, d, "is_alive", threadIsAlive);
        try methodReg(a, d, "run", threadRun);
        interp.threading_main_thread_class = try Class.init(a, "_MainThread", &.{}, d);
    }
    if (interp.threading_event_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "set", eventSet);
        try methodReg(a, d, "clear", eventClear);
        try methodReg(a, d, "is_set", eventIsSet);
        try methodReg(a, d, "wait", eventWait);
        interp.threading_event_class = try Class.init(a, "Event", &.{}, d);
    }
    if (interp.threading_sem_class == null) {
        const d = try Dict.init(a);
        try methodRegKw(a, d, "acquire", semAcquire, semAcquireKw);
        try methodReg(a, d, "release", semRelease);
        try methodReg(a, d, "__enter__", semEnter);
        try methodReg(a, d, "__exit__", semExit);
        interp.threading_sem_class = try Class.init(a, "Semaphore", &.{}, d);
    }
    if (interp.threading_cond_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "acquire", condAcquire);
        try methodReg(a, d, "release", condRelease);
        try methodReg(a, d, "notify", condNotify);
        try methodReg(a, d, "notify_all", condNotify);
        try methodReg(a, d, "wait", condWait);
        try methodReg(a, d, "__enter__", condEnter);
        try methodReg(a, d, "__exit__", condExit);
        interp.threading_cond_class = try Class.init(a, "Condition", &.{}, d);
    }
    if (interp.threading_barrier_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "wait", barrierWait);
        try methodReg(a, d, "reset", barrierReset);
        try methodReg(a, d, "abort", barrierAbort);
        interp.threading_barrier_class = try Class.init(a, "Barrier", &.{}, d);
    }
    if (interp.threading_local_class == null) {
        const d = try Dict.init(a);
        interp.threading_local_class = try Class.init(a, "local", &.{}, d);
    }
    if (interp.threading_bounded_sem_class == null) {
        const d = try Dict.init(a);
        try methodRegKw(a, d, "acquire", semAcquire, semAcquireKw);
        try methodReg(a, d, "release", boundedSemRelease);
        try methodReg(a, d, "__enter__", semEnter);
        try methodReg(a, d, "__exit__", semExit);
        interp.threading_bounded_sem_class = try Class.init(a, "BoundedSemaphore", &.{}, d);
    }
}

// --- Lock ---

fn lockCtor(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.threading_lock_class.?);
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
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const blocking = if (args.len >= 2 and args[1] == .boolean) args[1].boolean else true;
    return lockAcquireCore(interp, inst, blocking);
}

fn lockAcquireKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    var blocking = if (args.len >= 2 and args[1] == .boolean) args[1].boolean else true;
    for (kw_names, kw_values) |n, v| {
        if (n != .str) continue;
        if (std.mem.eql(u8, n.str.bytes, "blocking") and v == .boolean) blocking = v.boolean;
    }
    return lockAcquireCore(interp, inst, blocking);
}

fn lockRelease(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    try inst.dict.setStr(interp.allocator, "_locked", Value{ .boolean = false });
    return Value.none;
}

fn lockLocked(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try argInst(args);
    return inst.dict.getStr("_locked") orelse Value{ .boolean = false };
}

fn lockEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try lockAcquire(p, args);
    const inst = try argInst(args);
    return Value{ .instance = inst };
}

fn lockExit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try lockRelease(p, args[0..1]);
    return Value{ .boolean = false };
}

// --- RLock ---

fn rlockCtor(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.threading_rlock_class.?);
    try inst.dict.setStr(a, "_count", Value{ .small_int = 0 });
    return Value{ .instance = inst };
}

fn rlockAcquire(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const cur = (inst.dict.getStr("_count") orelse Value{ .small_int = 0 }).small_int;
    try inst.dict.setStr(interp.allocator, "_count", Value{ .small_int = cur + 1 });
    return Value{ .boolean = true };
}

fn rlockRelease(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const cur = (inst.dict.getStr("_count") orelse Value{ .small_int = 0 }).small_int;
    if (cur > 0) {
        try inst.dict.setStr(interp.allocator, "_count", Value{ .small_int = cur - 1 });
    }
    return Value.none;
}

fn rlockEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try rlockAcquire(p, args);
    const inst = try argInst(args);
    return Value{ .instance = inst };
}

fn rlockExit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try rlockRelease(p, args[0..1]);
    return Value{ .boolean = false };
}

// --- Thread ---

fn buildThread(interp: *Interp, target: Value, args_v: Value, name: Value) anyerror!Value {
    try ensureClasses(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.threading_thread_class.?);
    try inst.dict.setStr(a, "_target", target);
    try inst.dict.setStr(a, "_args", args_v);
    try inst.dict.setStr(a, "_alive", Value{ .boolean = false });
    const name_v: Value = if (name == .none) blk: {
        const s = try Str.init(a, "Thread");
        break :blk Value{ .str = s };
    } else name;
    try inst.dict.setStr(a, "name", name_v);
    return Value{ .instance = inst };
}

fn threadCtorPos(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const target: Value = if (args.len >= 1) args[0] else Value.none;
    const args_v: Value = if (args.len >= 2) args[1] else blk: {
        const t = try Tuple.init(interp.allocator, 0);
        break :blk Value{ .tuple = t };
    };
    return buildThread(interp, target, args_v, Value.none);
}

fn threadCtorKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var target: Value = if (args.len >= 1) args[0] else Value.none;
    var args_v: Value = if (args.len >= 2) args[1] else blk: {
        const t = try Tuple.init(interp.allocator, 0);
        break :blk Value{ .tuple = t };
    };
    var name: Value = Value.none;
    for (kw_names, kw_values) |n, v| {
        if (n != .str) continue;
        const k = n.str.bytes;
        if (std.mem.eql(u8, k, "target")) target = v;
        if (std.mem.eql(u8, k, "args")) args_v = v;
        if (std.mem.eql(u8, k, "name")) name = v;
    }
    return buildThread(interp, target, args_v, name);
}

fn cloneContextForThread(a: std.mem.Allocator, interp: *Interp) !void {
    const CVDict = @import("../object/dict.zig").Dict;
    const CVList = @import("../object/list.zig").List;
    const src_data = interp.cv_context_data orelse {
        interp.cv_context_data = try CVDict.init(a);
        interp.cv_context_cvs = try CVList.init(a);
        return;
    };
    const new_data = try CVDict.init(a);
    for (src_data.pairs.items) |pair| try new_data.pairs.append(a, pair);
    const src_cvs = interp.cv_context_cvs orelse try CVList.init(a);
    const new_cvs = try CVList.init(a);
    for (src_cvs.items.items) |item| try new_cvs.items.append(a, item);
    interp.cv_context_data = new_data;
    interp.cv_context_cvs = new_cvs;
}

fn runPendingThreads(interp: *Interp) !void {
    const a = interp.allocator;
    while (interp.threading_pending_threads.items.len > 0) {
        const thread_v = interp.threading_pending_threads.orderedRemove(0);
        if (thread_v != .instance) continue;
        const inst = thread_v.instance;
        const target = inst.dict.getStr("_target") orelse Value.none;
        if (target == .none) continue;
        const args_v = inst.dict.getStr("_args") orelse Value.none;
        const prev_thread = interp.threading_current_thread;
        interp.threading_current_thread = inst;

        // Save and clone context for thread isolation
        const saved_ctx_data = interp.cv_context_data;
        const saved_ctx_cvs = interp.cv_context_cvs;
        try cloneContextForThread(a, interp);

        const passed: []const Value = switch (args_v) {
            .tuple => |t| t.items,
            .list => |l| l.items.items,
            else => &.{},
        };
        _ = dispatch.invoke(interp, target, passed) catch {};
        interp.threading_current_thread = prev_thread;

        // Restore outer context
        interp.cv_context_data = saved_ctx_data;
        interp.cv_context_cvs = saved_ctx_cvs;
    }
}

fn threadStart(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const a = interp.allocator;
    try inst.dict.setStr(a, "_alive", Value{ .boolean = true });
    try interp.threading_live_threads.append(a, Value{ .instance = inst });
    try interp.threading_pending_threads.append(a, Value{ .instance = inst });
    return Value.none;
}

fn threadJoin(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    try runPendingThreads(interp);
    try inst.dict.setStr(interp.allocator, "_alive", Value{ .boolean = false });
    var i: usize = 0;
    while (i < interp.threading_live_threads.items.len) : (i += 1) {
        const item = interp.threading_live_threads.items[i];
        if (item == .instance and item.instance == inst) {
            _ = interp.threading_live_threads.orderedRemove(i);
            break;
        }
    }
    return Value.none;
}

fn threadIsAlive(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try argInst(args);
    return inst.dict.getStr("_alive") orelse Value{ .boolean = false };
}

fn threadRun(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

// --- Event ---

fn eventCtor(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.threading_event_class.?);
    try inst.dict.setStr(a, "_set", Value{ .boolean = false });
    return Value{ .instance = inst };
}

fn eventSet(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    try inst.dict.setStr(interp.allocator, "_set", Value{ .boolean = true });
    return Value.none;
}

fn eventClear(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    try inst.dict.setStr(interp.allocator, "_set", Value{ .boolean = false });
    return Value.none;
}

fn eventIsSet(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try argInst(args);
    return inst.dict.getStr("_set") orelse Value{ .boolean = false };
}

fn eventWait(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try argInst(args);
    return inst.dict.getStr("_set") orelse Value{ .boolean = false };
}

// --- Semaphore ---

fn semCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.threading_sem_class.?);
    const initial: i64 = if (args.len >= 1) switch (args[0]) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        else => 1,
    } else 1;
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
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const blocking = if (args.len >= 2 and args[1] == .boolean) args[1].boolean else true;
    return semAcquireCore(interp, inst, blocking);
}

fn semAcquireKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    var blocking = true;
    for (kw_names, kw_values) |n, v| {
        if (n != .str) continue;
        if (std.mem.eql(u8, n.str.bytes, "blocking") and v == .boolean) blocking = v.boolean;
    }
    return semAcquireCore(interp, inst, blocking);
}

fn semRelease(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const cur = (inst.dict.getStr("_count") orelse Value{ .small_int = 0 }).small_int;
    try inst.dict.setStr(interp.allocator, "_count", Value{ .small_int = cur + 1 });
    return Value.none;
}

fn boundedSemCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.threading_bounded_sem_class.?);
    const initial: i64 = if (args.len >= 1) switch (args[0]) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        else => 1,
    } else 1;
    try inst.dict.setStr(a, "_count", Value{ .small_int = initial });
    try inst.dict.setStr(a, "_max", Value{ .small_int = initial });
    return Value{ .instance = inst };
}

fn boundedSemRelease(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const cur = (inst.dict.getStr("_count") orelse Value{ .small_int = 0 }).small_int;
    const max = (inst.dict.getStr("_max") orelse Value{ .small_int = 1 }).small_int;
    if (cur + 1 > max) {
        try interp.raisePy("ValueError", "Semaphore released too many times");
        return error.PyException;
    }
    try inst.dict.setStr(interp.allocator, "_count", Value{ .small_int = cur + 1 });
    return Value.none;
}

fn semEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try semAcquireCore(@ptrCast(@alignCast(p)), try argInst(args), true);
    const inst = try argInst(args);
    return Value{ .instance = inst };
}

fn semExit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try semRelease(p, args[0..1]);
    return Value{ .boolean = false };
}

// --- Condition ---

fn condCtor(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.threading_cond_class.?);
    try inst.dict.setStr(a, "_locked", Value{ .boolean = false });
    return Value{ .instance = inst };
}

fn condAcquire(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    try inst.dict.setStr(interp.allocator, "_locked", Value{ .boolean = true });
    return Value{ .boolean = true };
}

fn condRelease(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    try inst.dict.setStr(interp.allocator, "_locked", Value{ .boolean = false });
    return Value.none;
}

fn condNotify(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn condWait(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    // Release the condition lock temporarily so pending threads can acquire it.
    if (args.len >= 1 and args[0] == .instance) {
        try args[0].instance.dict.setStr(interp.allocator, "_locked", Value{ .boolean = false });
    }
    try runPendingThreads(interp);
    // Re-acquire
    if (args.len >= 1 and args[0] == .instance) {
        try args[0].instance.dict.setStr(interp.allocator, "_locked", Value{ .boolean = true });
    }
    return Value{ .boolean = true };
}

fn condEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try condAcquire(p, args);
    const inst = try argInst(args);
    return Value{ .instance = inst };
}

fn condExit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try condRelease(p, args[0..1]);
    return Value{ .boolean = false };
}

// --- Barrier ---

fn barrierCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.threading_barrier_class.?);
    const parties: i64 = if (args.len >= 1) switch (args[0]) {
        .small_int => |i| i,
        else => 1,
    } else 1;
    try inst.dict.setStr(a, "parties", Value{ .small_int = parties });
    try inst.dict.setStr(a, "n_waiting", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "broken", Value{ .boolean = false });
    return Value{ .instance = inst };
}

fn barrierWait(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .small_int = 0 };
}

fn barrierReset(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    try inst.dict.setStr(interp.allocator, "broken", Value{ .boolean = false });
    return Value.none;
}

fn barrierAbort(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    try inst.dict.setStr(interp.allocator, "broken", Value{ .boolean = true });
    return Value.none;
}

// --- local ---

fn localCtor(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.threading_local_class.?);
    return Value{ .instance = inst };
}

// --- module-level functions ---

fn getOrCreateMainThread(interp: *Interp) !Value {
    try ensureClasses(interp);
    const a = interp.allocator;
    if (interp.threading_main_thread) |inst| return Value{ .instance = inst };
    const inst = try Instance.init(a, interp.threading_main_thread_class.?);
    try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, "MainThread") });
    try inst.dict.setStr(a, "_alive", Value{ .boolean = true });
    interp.threading_main_thread = inst;
    return Value{ .instance = inst };
}

fn currentThreadFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (interp.threading_current_thread) |inst| return Value{ .instance = inst };
    return getOrCreateMainThread(interp);
}

fn mainThreadFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    return getOrCreateMainThread(interp);
}

fn activeCountFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .small_int = @intCast(interp.threading_live_threads.items.len + 1) };
}

fn enumerateFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const lst = try List.init(a);
    try lst.append(a, try getOrCreateMainThread(interp));
    for (interp.threading_live_threads.items) |v| try lst.append(a, v);
    return Value{ .list = lst };
}

fn getIdentFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .small_int = 1 };
}
