//! `_thread` module — low-level threading primitives.

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
const dispatch = @import("dispatch.zig");

fn gi(p: *anyopaque) *Interp {
    return @ptrCast(@alignCast(p));
}

fn instArg(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
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

// ===== _thread pending queue (separate from threading) =====
// Uses interp.thread_mod_pending (stored as interp._thread_pending list)

fn getOrCreatePending(interp: *Interp) !*List {
    if (interp.thread_mod_pending) |l| return l;
    const l = try List.init(interp.allocator);
    interp.thread_mod_pending = l;
    return l;
}

fn runPendingThreads(interp: *Interp) !void {
    const a = interp.allocator;
    const pending = interp.thread_mod_pending orelse return;
    while (pending.items.items.len > 0) {
        const item = pending.items.orderedRemove(0);
        if (item != .instance) continue;
        const inst = item.instance;
        const fn_v = inst.dict.getStr("_fn") orelse continue;
        const args_v = inst.dict.getStr("_args") orelse Value{ .tuple = try Tuple.init(a, 0) };
        const kn_v = inst.dict.getStr("_kn") orelse Value{ .list = try List.init(a) };
        const kv_v = inst.dict.getStr("_kv") orelse Value{ .list = try List.init(a) };

        const fn_args: []const Value = switch (args_v) {
            .tuple => |t| t.items,
            .list => |l| l.items.items,
            else => &.{},
        };
        const kn_sl: []const Value = if (kn_v == .list) kn_v.list.items.items else &.{};
        const kv_sl: []const Value = if (kv_v == .list) kv_v.list.items.items else &.{};

        // Context isolation: clone context
        // Give thread a unique ID
        const saved_id = interp.thread_mod_current_id;
        interp.thread_mod_next_id += 1;
        interp.thread_mod_current_id = interp.thread_mod_next_id + 100;

        const saved_data = interp.cv_context_data;
        const saved_cvs = interp.cv_context_cvs;
        {
            const CVDict = @import("../object/dict.zig").Dict;
            const CVList = @import("../object/list.zig").List;
            if (interp.cv_context_data) |src| {
                const new_data = try CVDict.init(a);
                for (src.pairs.items) |pair| try new_data.pairs.append(a, pair);
                interp.cv_context_data = new_data;
            }
            if (interp.cv_context_cvs) |src| {
                const new_cvs = try CVList.init(a);
                for (src.items.items) |iv| try new_cvs.items.append(a, iv);
                interp.cv_context_cvs = new_cvs;
            }
        }

        _ = dispatch.invokeKw(interp, fn_v, fn_args, kn_sl, kv_sl) catch {};

        interp.cv_context_data = saved_data;
        interp.cv_context_cvs = saved_cvs;
        interp.thread_mod_current_id = saved_id;
    }
}

// ===== Lock =====

fn lockAcquire(p: *anyopaque, args: []const Value) anyerror!Value {
    return lockAcquireKw(p, args, &.{}, &.{});
}

fn lockAcquireKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);

    var blocking = if (args.len >= 2) switch (args[1]) {
        .boolean => |b| b,
        .small_int => |i| i != 0,
        else => true,
    } else true;

    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        if (std.mem.eql(u8, nm.str.bytes, "blocking")) {
            blocking = vl == .boolean and vl.boolean;
        }
        // timeout: if timeout > 0 and lock is locked, return False
    }

    const locked = (inst.dict.getStr("_locked") orelse Value{ .boolean = false }) == .boolean and
        (inst.dict.getStr("_locked") orelse Value{ .boolean = false }).boolean;

    if (!locked) {
        try inst.dict.setStr(a, "_locked", Value{ .boolean = true });
        return Value{ .boolean = true };
    }

    if (!blocking) return Value{ .boolean = false };

    // Check for timeout kwarg — if timeout specified, return False without blocking
    for (kn) |nm| {
        if (nm == .str and std.mem.eql(u8, nm.str.bytes, "timeout"))
            return Value{ .boolean = false };
    }

    // Run pending threads to give them a chance to release
    try runPendingThreads(interp);

    const still_locked = (inst.dict.getStr("_locked") orelse Value{ .boolean = false }) == .boolean and
        (inst.dict.getStr("_locked") orelse Value{ .boolean = false }).boolean;

    if (!still_locked) {
        try inst.dict.setStr(a, "_locked", Value{ .boolean = true });
        return Value{ .boolean = true };
    }

    // Still locked after running threads — in real threading this would block.
    // In single-threaded mode, we have to return False to avoid deadlock.
    return Value{ .boolean = false };
}

fn lockRelease(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
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
    _ = try lockRelease(p, args);
    return Value{ .boolean = false };
}

// ===== allocate_lock =====

fn allocateLock(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.thread_lock_class.?);
    try inst.dict.setStr(a, "_locked", Value{ .boolean = false });
    return Value{ .instance = inst };
}

// ===== start_new_thread =====

fn startNewThread(p: *anyopaque, args: []const Value) anyerror!Value {
    return startNewThreadKw(p, args, &.{}, &.{});
}

fn startNewThreadKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    _ = kn;
    _ = kv;
    const interp = gi(p);
    const a = interp.allocator;

    const fn_v: Value = if (args.len >= 1) args[0] else return Value{ .small_int = 0 };
    const fn_args: Value = if (args.len >= 2) args[1] else Value{ .tuple = try Tuple.init(a, 0) };
    const fn_kwargs: Value = if (args.len >= 3) args[2] else Value.none;

    // Build kn/kv from kwargs dict
    var kn_list = try List.init(a);
    var kv_list = try List.init(a);
    if (fn_kwargs == .dict) {
        for (fn_kwargs.dict.pairs.items) |pair| {
            try kn_list.items.append(a, pair.key);
            try kv_list.items.append(a, pair.value);
        }
    }

    // Create a pending task record
    const task = try Instance.init(a, interp.thread_lock_class.?); // reuse any class
    try task.dict.setStr(a, "_fn", fn_v);
    try task.dict.setStr(a, "_args", fn_args);
    try task.dict.setStr(a, "_kn", Value{ .list = kn_list });
    try task.dict.setStr(a, "_kv", Value{ .list = kv_list });

    const pending = try getOrCreatePending(interp);
    try pending.items.append(a, Value{ .instance = task });

    // Return a fake thread ID
    interp.thread_mod_next_id += 1;
    return Value{ .small_int = @intCast(interp.thread_mod_next_id) };
}

// ===== get_ident / get_native_id =====

fn getIdent(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    return Value{ .small_int = @intCast(interp.thread_mod_current_id) };
}

fn getNativeId(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    return Value{ .small_int = @intCast(interp.thread_mod_current_id) };
}

// ===== exit =====

fn exitFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    try interp.raisePy("SystemExit", "");
    return error.PyException;
}

// ===== stack_size =====

fn stackSize(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value{ .small_int = 0 };
}

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;

    if (interp.thread_lock_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "acquire", lockAcquire, lockAcquireKw);
        try regD(a, d, "release", lockRelease);
        try regD(a, d, "locked", lockLocked);
        try regD(a, d, "__enter__", lockEnter);
        try regD(a, d, "__exit__", lockExit);
        interp.thread_lock_class = try Class.init(a, "lock", &.{}, d);
    }

    if (interp.thread_error_class == null) {
        const rt_v = interp.builtins.getStr("RuntimeError") orelse Value.none;
        const rt_base: ?*Class = if (rt_v == .class) rt_v.class else null;
        const bases: []const *Class = if (rt_base) |b| &[_]*Class{b} else &.{};
        const d = try Dict.init(a);
        interp.thread_error_class = try Class.init(a, "error", bases, d);
    }
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);

    interp.thread_mod_current_id = 1;

    const m = try Module.init(a, "_thread");
    try regM(a, m, "allocate_lock", allocateLock);
    try regKwM(a, m, "start_new_thread", startNewThread, startNewThreadKw);
    try regM(a, m, "get_ident", getIdent);
    try regM(a, m, "get_native_id", getNativeId);
    try regM(a, m, "exit", exitFn);
    try regM(a, m, "stack_size", stackSize);
    try m.attrs.setStr(a, "LockType", Value{ .class = interp.thread_lock_class.? });
    try m.attrs.setStr(a, "error", Value{ .class = interp.thread_error_class.? });
    try m.attrs.setStr(a, "TIMEOUT_MAX", Value{ .float = 292271023.62 }); // sys.maxsize / 1e9

    return m;
}
