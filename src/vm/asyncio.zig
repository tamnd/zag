//! `asyncio` module — synchronous stub sufficient for fixture 199.
//! There is no event loop and no real concurrency.  Everything runs
//! inline; Tasks/Futures complete when first awaited.

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
const Set = @import("../object/set.zig").Set;
const Generator = @import("../object/generator.zig").Generator;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

fn gi(p: *anyopaque) *Interp {
    return @ptrCast(@alignCast(p));
}

fn instArg(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
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

fn finGen(a: std.mem.Allocator, val: Value) !Value {
    const g = try a.create(Generator);
    g.* = .{ .frame = undefined, .finished = true, .started = true, .return_value = val };
    return Value{ .generator = g };
}

fn boolField(inst: *Instance, name: []const u8) bool {
    const v = inst.dict.getStr(name) orelse return false;
    return v == .boolean and v.boolean;
}

fn runCallbacks(interp: *Interp, inst: *Instance, self_val: Value) !void {
    const cbs = inst.dict.getStr("_callbacks") orelse return;
    if (cbs != .list) return;
    for (cbs.list.items.items) |cb| {
        _ = dispatch.invoke(interp, cb, &[_]Value{self_val}) catch {};
    }
}

fn driveTask(interp: *Interp, inst: *Instance) anyerror!void {
    const a = interp.allocator;
    if (boolField(inst, "_done")) return;
    if (boolField(inst, "_cancelled")) {
        try inst.dict.setStr(a, "_done", Value{ .boolean = true });
        try runCallbacks(interp, inst, Value{ .instance = inst });
        try interp.raiseDecimal(interp.asyncio_cancelled_error_class.?, "");
        return error.PyException;
    }
    const coro_v = inst.dict.getStr("_coro") orelse return;
    if (coro_v != .generator) return;
    const coro = coro_v.generator;

    var py_err = false;
    var stored_exc: Value = Value.none;
    driveLoop: while (true) {
        const yv = dispatch.genResume(interp, coro, Value.none) catch |err| {
            if (err != error.PyException) return err;
            stored_exc = interp.current_exc orelse Value.none;
            interp.current_exc = null;
            py_err = true;
            break :driveLoop;
        };
        if (yv == null) break :driveLoop;
    }

    if (py_err) {
        try inst.dict.setStr(a, "_exception", stored_exc);
        try inst.dict.setStr(a, "_done", Value{ .boolean = true });
        try runCallbacks(interp, inst, Value{ .instance = inst });
        interp.current_exc = stored_exc;
        return error.PyException;
    }
    try inst.dict.setStr(a, "_result", coro.return_value);
    try inst.dict.setStr(a, "_done", Value{ .boolean = true });
    try runCallbacks(interp, inst, Value{ .instance = inst });
}

// ===== Future =====

fn futureInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    try inst.dict.setStr(a, "_done", Value{ .boolean = false });
    try inst.dict.setStr(a, "_cancelled", Value{ .boolean = false });
    try inst.dict.setStr(a, "_result", Value.none);
    try inst.dict.setStr(a, "_exception", Value.none);
    const cbs = try List.init(a);
    try inst.dict.setStr(a, "_callbacks", Value{ .list = cbs });
    return Value.none;
}

fn futureDone(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return Value{ .boolean = boolField(inst, "_done") };
}

fn futureCancelled(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return Value{ .boolean = boolField(inst, "_cancelled") };
}

fn futureResult(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);
    if (!boolField(inst, "_done")) {
        try interp.raiseDecimal(interp.asyncio_invalid_state_class.?, "result is not ready");
        return error.PyException;
    }
    if (boolField(inst, "_cancelled")) {
        try interp.raiseDecimal(interp.asyncio_cancelled_error_class.?, "");
        return error.PyException;
    }
    const exc = inst.dict.getStr("_exception") orelse Value.none;
    if (exc != .none) {
        interp.current_exc = exc;
        return error.PyException;
    }
    return inst.dict.getStr("_result") orelse Value.none;
}

fn futureException(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);
    if (!boolField(inst, "_done")) {
        try interp.raiseDecimal(interp.asyncio_invalid_state_class.?, "result is not ready");
        return error.PyException;
    }
    if (boolField(inst, "_cancelled")) {
        try interp.raiseDecimal(interp.asyncio_cancelled_error_class.?, "");
        return error.PyException;
    }
    return inst.dict.getStr("_exception") orelse Value.none;
}

fn futureSetResult(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const val = if (args.len >= 2) args[1] else Value.none;
    try inst.dict.setStr(a, "_result", val);
    try inst.dict.setStr(a, "_done", Value{ .boolean = true });
    try runCallbacks(interp, inst, Value{ .instance = inst });
    return Value.none;
}

fn futureSetException(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const exc = if (args.len >= 2) args[1] else Value.none;
    // If exc is a class, instantiate it
    const exc_inst: Value = switch (exc) {
        .class => |cls| blk: {
            const ei = try Instance.init(a, cls);
            break :blk Value{ .instance = ei };
        },
        else => exc,
    };
    try inst.dict.setStr(a, "_exception", exc_inst);
    try inst.dict.setStr(a, "_done", Value{ .boolean = true });
    try runCallbacks(interp, inst, Value{ .instance = inst });
    return Value.none;
}

fn futureCancel(p: *anyopaque, args: []const Value) anyerror!Value {
    return futureCancelKw(p, args, &.{}, &.{});
}

fn futureCancelKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    if (boolField(inst, "_done")) return Value{ .boolean = false };
    try inst.dict.setStr(a, "_cancelled", Value{ .boolean = true });
    try inst.dict.setStr(a, "_done", Value{ .boolean = true });
    try runCallbacks(interp, inst, Value{ .instance = inst });
    return Value{ .boolean = true };
}

fn futureAddDoneCallback(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const cb = if (args.len >= 2) args[1] else return Value.none;
    const cbs_v = inst.dict.getStr("_callbacks") orelse blk: {
        const l = try List.init(a);
        try inst.dict.setStr(a, "_callbacks", Value{ .list = l });
        break :blk Value{ .list = l };
    };
    if (cbs_v == .list) {
        if (boolField(inst, "_done")) {
            // Already done, call immediately
            _ = dispatch.invoke(interp, cb, &[_]Value{args[0]}) catch {};
        } else {
            try cbs_v.list.items.append(a, cb);
        }
    }
    return Value.none;
}

fn futureAwait(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    if (!boolField(inst, "_done")) {
        try interp.raiseDecimal(interp.asyncio_invalid_state_class.?, "await on unresolved Future");
        return error.PyException;
    }
    if (boolField(inst, "_cancelled")) {
        try interp.raiseDecimal(interp.asyncio_cancelled_error_class.?, "");
        return error.PyException;
    }
    const exc = inst.dict.getStr("_exception") orelse Value.none;
    if (exc != .none) {
        interp.current_exc = exc;
        return error.PyException;
    }
    const result = inst.dict.getStr("_result") orelse Value.none;
    return finGen(a, result);
}

// ===== Task =====

fn taskInit(p: *anyopaque, args: []const Value) anyerror!Value {
    return taskInitKw(p, args, &.{}, &.{});
}

fn taskInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const coro = if (args.len >= 2) args[1] else Value.none;
    try inst.dict.setStr(a, "_coro", coro);
    try inst.dict.setStr(a, "_done", Value{ .boolean = false });
    try inst.dict.setStr(a, "_cancelled", Value{ .boolean = false });
    try inst.dict.setStr(a, "_result", Value.none);
    try inst.dict.setStr(a, "_exception", Value.none);
    const cbs = try List.init(a);
    try inst.dict.setStr(a, "_callbacks", Value{ .list = cbs });
    // name
    var name: []const u8 = "Task";
    for (kn, kv) |k, v| {
        if (k == .str and std.mem.eql(u8, k.str.bytes, "name") and v == .str)
            name = v.str.bytes;
    }
    const ns = try Str.init(a, name);
    try inst.dict.setStr(a, "_name", Value{ .str = ns });
    return Value.none;
}

fn taskDone(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return Value{ .boolean = boolField(inst, "_done") };
}

fn taskCancelled(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return Value{ .boolean = boolField(inst, "_cancelled") };
}

fn taskResult(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);
    if (!boolField(inst, "_done")) {
        try interp.raiseDecimal(interp.asyncio_invalid_state_class.?, "result is not ready");
        return error.PyException;
    }
    if (boolField(inst, "_cancelled")) {
        try interp.raiseDecimal(interp.asyncio_cancelled_error_class.?, "");
        return error.PyException;
    }
    const exc = inst.dict.getStr("_exception") orelse Value.none;
    if (exc != .none) {
        interp.current_exc = exc;
        return error.PyException;
    }
    return inst.dict.getStr("_result") orelse Value.none;
}

fn taskException(p: *anyopaque, args: []const Value) anyerror!Value {
    return futureException(p, args);
}

fn taskCancel(p: *anyopaque, args: []const Value) anyerror!Value {
    return taskCancelKw(p, args, &.{}, &.{});
}

fn taskCancelKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    if (boolField(inst, "_done")) return Value{ .boolean = false };
    try inst.dict.setStr(a, "_cancelled", Value{ .boolean = true });
    try inst.dict.setStr(a, "_done", Value{ .boolean = true });
    try runCallbacks(interp, inst, Value{ .instance = inst });
    return Value{ .boolean = true };
}

fn taskAddDoneCallback(p: *anyopaque, args: []const Value) anyerror!Value {
    return futureAddDoneCallback(p, args);
}

fn taskGetName(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return inst.dict.getStr("_name") orelse Value{ .str = try Str.init(std.heap.page_allocator, "Task") };
}

fn taskSetName(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const name = if (args.len >= 2) args[1] else Value.none;
    const ns: Value = switch (name) {
        .str => name,
        else => blk: {
            const s = try Str.init(a, "Task");
            break :blk Value{ .str = s };
        },
    };
    try inst.dict.setStr(a, "_name", ns);
    return Value.none;
}

fn taskAwait(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    try driveTask(interp, inst);
    if (boolField(inst, "_cancelled")) {
        try interp.raiseDecimal(interp.asyncio_cancelled_error_class.?, "");
        return error.PyException;
    }
    const exc = inst.dict.getStr("_exception") orelse Value.none;
    if (exc != .none) {
        interp.current_exc = exc;
        return error.PyException;
    }
    const result = inst.dict.getStr("_result") orelse Value.none;
    return finGen(a, result);
}

// ===== Lock =====

fn lockInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    try inst.dict.setStr(a, "_locked", Value{ .boolean = false });
    return Value.none;
}

fn lockLocked(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return inst.dict.getStr("_locked") orelse Value{ .boolean = false };
}

fn lockAcquire(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    try inst.dict.setStr(a, "_locked", Value{ .boolean = true });
    return finGen(a, Value{ .boolean = true });
}

fn lockRelease(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    try inst.dict.setStr(a, "_locked", Value{ .boolean = false });
    return Value.none;
}

fn lockAenter(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    try inst.dict.setStr(a, "_locked", Value{ .boolean = true });
    return finGen(a, args[0]);
}

fn lockAexit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    try inst.dict.setStr(a, "_locked", Value{ .boolean = false });
    return finGen(a, Value{ .boolean = false });
}

// ===== Event =====

fn eventInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    try inst.dict.setStr(a, "_set", Value{ .boolean = false });
    return Value.none;
}

fn eventIsSet(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return inst.dict.getStr("_set") orelse Value{ .boolean = false };
}

fn eventSet(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    try inst.dict.setStr(a, "_set", Value{ .boolean = true });
    return Value.none;
}

fn eventClear(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    try inst.dict.setStr(a, "_set", Value{ .boolean = false });
    return Value.none;
}

fn eventWait(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp = gi(p);
    return finGen(interp.allocator, Value{ .boolean = true });
}

// ===== Condition =====

fn conditionInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    try inst.dict.setStr(a, "_locked", Value{ .boolean = false });
    return Value.none;
}

fn conditionAenter(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    try inst.dict.setStr(a, "_locked", Value{ .boolean = true });
    return finGen(a, args[0]);
}

fn conditionAexit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    try inst.dict.setStr(a, "_locked", Value{ .boolean = false });
    return finGen(a, Value{ .boolean = false });
}

fn conditionNotifyAll(_: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    return Value.none;
}

fn conditionNotify(_: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    return Value.none;
}

fn conditionWait(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp = gi(p);
    return finGen(interp.allocator, Value{ .boolean = true });
}

// ===== Semaphore =====

fn semaphoreInit(p: *anyopaque, args: []const Value) anyerror!Value {
    return semaphoreInitKw(p, args, &.{}, &.{});
}

fn semaphoreInitKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const val: i64 = if (args.len >= 2) switch (args[1]) {
        .small_int => |i| i,
        .float => |f| @intFromFloat(f),
        else => 1,
    } else 1;
    try inst.dict.setStr(a, "_value", Value{ .small_int = val });
    try inst.dict.setStr(a, "_initial", Value{ .small_int = val });
    return Value.none;
}

fn semaphoreLocked(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const v = inst.dict.getStr("_value") orelse Value{ .small_int = 1 };
    const count: i64 = if (v == .small_int) v.small_int else 1;
    return Value{ .boolean = count <= 0 };
}

fn semaphoreAcquire(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const v = inst.dict.getStr("_value") orelse Value{ .small_int = 1 };
    const count: i64 = if (v == .small_int) v.small_int else 1;
    try inst.dict.setStr(a, "_value", Value{ .small_int = count - 1 });
    return finGen(a, Value{ .boolean = true });
}

fn semaphoreRelease(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const v = inst.dict.getStr("_value") orelse Value{ .small_int = 0 };
    const count: i64 = if (v == .small_int) v.small_int else 0;
    try inst.dict.setStr(a, "_value", Value{ .small_int = count + 1 });
    return Value.none;
}

fn semaphoreAenter(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const v = inst.dict.getStr("_value") orelse Value{ .small_int = 1 };
    const count: i64 = if (v == .small_int) v.small_int else 1;
    try inst.dict.setStr(a, "_value", Value{ .small_int = count - 1 });
    return finGen(a, args[0]);
}

fn semaphoreAexit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const v = inst.dict.getStr("_value") orelse Value{ .small_int = 0 };
    const count: i64 = if (v == .small_int) v.small_int else 0;
    try inst.dict.setStr(a, "_value", Value{ .small_int = count + 1 });
    return finGen(a, Value{ .boolean = false });
}

// BoundedSemaphore release raises ValueError if count exceeds initial

fn bsemaphoreRelease(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const v = inst.dict.getStr("_value") orelse Value{ .small_int = 0 };
    const init_v = inst.dict.getStr("_initial") orelse Value{ .small_int = 1 };
    const count: i64 = if (v == .small_int) v.small_int else 0;
    const initial: i64 = if (init_v == .small_int) init_v.small_int else 1;
    if (count >= initial) {
        try interp.raisePy("ValueError", "BoundedSemaphore released too many times");
        return error.PyException;
    }
    try inst.dict.setStr(a, "_value", Value{ .small_int = count + 1 });
    return Value.none;
}

// ===== Async Queue =====

fn asyncQueueInit(p: *anyopaque, args: []const Value) anyerror!Value {
    return asyncQueueInitKw(p, args, &.{}, &.{});
}

fn asyncQueueInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    var maxsize: i64 = 0;
    for (kn, kv) |k, v| {
        if (k == .str and std.mem.eql(u8, k.str.bytes, "maxsize")) {
            maxsize = switch (v) {
                .small_int => |i| i,
                .float => |f| @intFromFloat(f),
                else => 0,
            };
        }
    }
    if (args.len >= 2) {
        maxsize = switch (args[1]) {
            .small_int => |i| i,
            .float => |f| @intFromFloat(f),
            else => maxsize,
        };
    }
    try inst.dict.setStr(a, "_maxsize", Value{ .small_int = maxsize });
    const items = try List.init(a);
    try inst.dict.setStr(a, "_items", Value{ .list = items });
    try inst.dict.setStr(a, "_qtype", Value{ .small_int = 0 }); // 0=fifo, 1=lifo, 2=priority
    return Value.none;
}

fn asyncLifoQueueInit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try asyncQueueInitKw(p, args, &.{}, &.{});
    const interp = gi(p);
    const inst = try instArg(args);
    try inst.dict.setStr(interp.allocator, "_qtype", Value{ .small_int = 1 });
    return Value.none;
}

fn asyncPriorityQueueInit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try asyncQueueInitKw(p, args, &.{}, &.{});
    const interp = gi(p);
    const inst = try instArg(args);
    try inst.dict.setStr(interp.allocator, "_qtype", Value{ .small_int = 2 });
    return Value.none;
}

fn asyncQueueEmpty(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const items_v = inst.dict.getStr("_items") orelse return Value{ .boolean = true };
    if (items_v != .list) return Value{ .boolean = true };
    return Value{ .boolean = items_v.list.items.items.len == 0 };
}

fn asyncQueueQsize(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const items_v = inst.dict.getStr("_items") orelse return Value{ .small_int = 0 };
    if (items_v != .list) return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(items_v.list.items.items.len) };
}

fn asyncQueuePut(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const item = if (args.len >= 2) args[1] else Value.none;
    const items_v = inst.dict.getStr("_items") orelse return error.TypeError;
    if (items_v != .list) return error.TypeError;
    const qtype_v = inst.dict.getStr("_qtype") orelse Value{ .small_int = 0 };
    const qtype: i64 = if (qtype_v == .small_int) qtype_v.small_int else 0;
    if (qtype == 2) {
        try heapPushQ(a, items_v.list, item);
    } else {
        try items_v.list.items.append(a, item);
    }
    return finGen(a, Value.none);
}

fn asyncQueueGet(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const items_v = inst.dict.getStr("_items") orelse return error.TypeError;
    if (items_v != .list) return error.TypeError;
    const qtype_v = inst.dict.getStr("_qtype") orelse Value{ .small_int = 0 };
    const qtype: i64 = if (qtype_v == .small_int) qtype_v.small_int else 0;
    const result: Value = switch (qtype) {
        1 => items_v.list.items.pop() orelse Value.none, // LIFO
        2 => heapPopQ(items_v.list) orelse Value.none, // priority
        else => blk: { // FIFO
            if (items_v.list.items.items.len == 0) break :blk Value.none;
            break :blk items_v.list.items.orderedRemove(0);
        },
    };
    return finGen(a, result);
}

// Heap helpers for priority queue (same as queue_mod.zig)
fn qcmpLess(a_v: Value, b_v: Value) bool {
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
                    if (qcmpLess(ta.items[i], tb.items[i])) break :blk true;
                    if (qcmpLess(tb.items[i], ta.items[i])) break :blk false;
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

fn heapPushQ(a: std.mem.Allocator, items: *List, val: Value) !void {
    try items.items.append(a, val);
    var i = items.items.items.len - 1;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (qcmpLess(items.items.items[i], items.items.items[parent])) {
            const tmp = items.items.items[i];
            items.items.items[i] = items.items.items[parent];
            items.items.items[parent] = tmp;
            i = parent;
        } else break;
    }
}

fn heapPopQ(items: *List) ?Value {
    if (items.items.items.len == 0) return null;
    const result = items.items.items[0];
    const last = items.items.pop() orelse return result;
    if (items.items.items.len == 0) return result;
    items.items.items[0] = last;
    var i: usize = 0;
    const n = items.items.items.len;
    while (true) {
        var smallest = i;
        const l = 2 * i + 1;
        const r = 2 * i + 2;
        if (l < n and qcmpLess(items.items.items[l], items.items.items[smallest])) smallest = l;
        if (r < n and qcmpLess(items.items.items[r], items.items.items[smallest])) smallest = r;
        if (smallest == i) break;
        const tmp = items.items.items[i];
        items.items.items[i] = items.items.items[smallest];
        items.items.items[smallest] = tmp;
        i = smallest;
    }
    return result;
}

// ===== TaskGroup =====

fn tgInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const tasks = try List.init(a);
    try inst.dict.setStr(a, "_tasks", Value{ .list = tasks });
    return Value.none;
}

fn tgCreateTask(p: *anyopaque, args: []const Value) anyerror!Value {
    return tgCreateTaskKw(p, args, &.{}, &.{});
}

fn tgCreateTaskKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const tg_inst = try instArg(args);
    const coro = if (args.len >= 2) args[1] else Value.none;
    // Create task
    const task = try Instance.init(a, interp.asyncio_task_class.?);
    const task_args = [_]Value{ Value{ .instance = task }, coro };
    _ = try taskInitKw(interp, &task_args, kn, kv);
    const tasks_v = tg_inst.dict.getStr("_tasks") orelse return Value{ .instance = task };
    if (tasks_v == .list) {
        try tasks_v.list.items.append(a, Value{ .instance = task });
    }
    return Value{ .instance = task };
}

fn tgAenter(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    return finGen(interp.allocator, args[0]);
}

fn tgAexit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const tasks_v = inst.dict.getStr("_tasks") orelse return finGen(a, Value{ .boolean = false });
    if (tasks_v == .list) {
        for (tasks_v.list.items.items) |tv| {
            if (tv != .instance) continue;
            driveTask(interp, tv.instance) catch {};
        }
    }
    return finGen(a, Value{ .boolean = false });
}

// ===== EventLoop =====

fn eventLoopInit(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn eventLoopRunUntilComplete(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    if (args.len < 2) return Value.none;
    const coro = switch (args[1]) {
        .generator => |g| g,
        .instance => {
            // Task
            const inst = args[1].instance;
            try driveTask(interp, inst);
            return inst.dict.getStr("_result") orelse Value.none;
        },
        else => return Value.none,
    };
    while (try dispatch.genResume(interp, coro, Value.none)) |_| {}
    return coro.return_value;
}

fn eventLoopClose(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

// ===== timeout context manager =====

fn timeoutCmInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const delay = if (args.len >= 2) args[1] else Value.none;
    try inst.dict.setStr(a, "_delay", delay);
    return Value.none;
}

fn timeoutCmAenter(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    return finGen(interp.allocator, args[0]);
}

fn timeoutCmAexit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp = gi(p);
    return finGen(interp.allocator, Value{ .boolean = false });
}

// ===== Module-level functions =====

fn sleepFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const result: Value = if (args.len >= 2) args[1] else Value.none;
    return finGen(interp.allocator, result);
}

fn runFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("asyncio.run() takes exactly one argument");
        return error.TypeError;
    }
    const coro = switch (args[0]) {
        .generator => |g| g,
        else => {
            try interp.typeError("asyncio.run() argument must be a coroutine");
            return error.TypeError;
        },
    };
    while (try dispatch.genResume(interp, coro, Value.none)) |_| {}
    return coro.return_value;
}

fn gatherFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const a = interp.allocator;
    const out = try List.init(a);
    for (args) |arg| {
        switch (arg) {
            .generator => |g| {
                while (try dispatch.genResume(interp, g, Value.none)) |_| {}
                try out.append(a, g.return_value);
            },
            .instance => |inst| {
                try driveTask(interp, inst);
                const result = inst.dict.getStr("_result") orelse Value.none;
                try out.append(a, result);
            },
            else => {
                try interp.typeError("asyncio.gather: argument is not awaitable");
                return error.TypeError;
            },
        }
    }
    return finGen(a, Value{ .list = out });
}

fn createTask(p: *anyopaque, args: []const Value) anyerror!Value {
    return createTaskKw(p, args, &.{}, &.{});
}

fn createTaskKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const coro = if (args.len >= 1) args[0] else Value.none;
    const task = try Instance.init(a, interp.asyncio_task_class.?);
    const task_args = [_]Value{ Value{ .instance = task }, coro };
    _ = try taskInitKw(interp, &task_args, kn, kv);
    return Value{ .instance = task };
}

fn ensureFuture(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    if (args.len < 1) return Value.none;
    switch (args[0]) {
        .generator => return createTask(p, args),
        .instance => |inst| {
            // If it's already a Future/Task, return as-is
            if (inst.cls == interp.asyncio_future_class or
                inst.cls == interp.asyncio_task_class)
                return args[0];
            return createTask(p, args);
        },
        else => return createTask(p, args),
    }
}

fn waitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return waitFnKw(p, args, &.{}, &.{});
}

fn waitFnKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    // args[0] is a list/set of tasks
    const tasks_v = if (args.len >= 1) args[0] else return Value.none;
    const done_set = try Set.init(a);
    const pending_set = try Set.init(a);
    const task_list: []const Value = switch (tasks_v) {
        .list => |l| l.items.items,
        .set => |s| s.items.items,
        else => &.{},
    };
    for (task_list) |tv| {
        switch (tv) {
            .instance => |inst| {
                driveTask(interp, inst) catch {};
                try done_set.add(a, tv);
            },
            .generator => |g| {
                while (dispatch.genResume(interp, g, Value.none) catch null) |_| {}
                try done_set.add(a, tv);
            },
            else => try done_set.add(a, tv),
        }
    }
    const t = try Tuple.init(a, 2);
    t.items[0] = Value{ .set = done_set };
    t.items[1] = Value{ .set = pending_set };
    return finGen(a, Value{ .tuple = t });
}

fn waitForFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return waitForFnKw(p, args, &.{}, &.{});
}

fn waitForFnKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return finGen(a, Value.none);
    switch (args[0]) {
        .generator => |g| {
            while (try dispatch.genResume(interp, g, Value.none)) |_| {}
            return finGen(a, g.return_value);
        },
        .instance => |inst| {
            try driveTask(interp, inst);
            const result = inst.dict.getStr("_result") orelse Value.none;
            return finGen(a, result);
        },
        else => return finGen(a, Value.none),
    }
}

fn asCompleted(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return Value{ .list = try List.init(a) };
    const tasks_v = args[0];
    const task_list: []const Value = switch (tasks_v) {
        .list => |l| l.items.items,
        .set => |s| s.items.items,
        else => &.{},
    };
    const out = try List.init(a);
    for (task_list) |tv| {
        switch (tv) {
            .instance => |inst| {
                driveTask(interp, inst) catch {};
                const result = inst.dict.getStr("_result") orelse Value.none;
                const g = try finGen(a, result);
                try out.append(a, g);
            },
            .generator => |g| {
                while (dispatch.genResume(interp, g, Value.none) catch null) |_| {}
                const gen_v = try finGen(a, g.return_value);
                try out.append(a, gen_v);
            },
            else => {
                const gen_v = try finGen(a, tv);
                try out.append(a, gen_v);
            },
        }
    }
    return Value{ .list = out };
}

fn currentTask(p: *anyopaque, _: []const Value) anyerror!Value {
    _ = p;
    return Value.none;
}

fn allTasks(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const s = try Set.init(interp.allocator);
    return Value{ .set = s };
}

fn newEventLoop(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.asyncio_event_loop_class.?);
    return Value{ .instance = inst };
}

fn shieldFn(p: *anyopaque, args: []const Value) anyerror!Value {
    // In our sync impl, shield is identity — just return a task wrapping the same coro
    if (args.len < 1) return Value.none;
    switch (args[0]) {
        .instance => return args[0],
        .generator => return createTask(p, args),
        else => return args[0],
    }
}

fn toThread(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return finGen(a, Value.none);
    const func = args[0];
    const func_args = if (args.len > 1) args[1..] else &[_]Value{};
    const result = dispatch.invoke(interp, func, func_args) catch Value.none;
    return finGen(a, result);
}

fn timeoutFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.asyncio_timeout_cm_class.?);
    const cm_args = [_]Value{ Value{ .instance = inst }, if (args.len >= 1) args[0] else Value.none };
    _ = try timeoutCmInit(interp, &cm_args);
    return Value{ .instance = inst };
}

// ===== Class construction =====

fn getExcBase(interp: *Interp, name: []const u8) ?*Class {
    const v = interp.builtins.getStr(name) orelse return null;
    return if (v == .class) v.class else null;
}

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;

    // CancelledError subclasses BaseException
    if (interp.asyncio_cancelled_error_class == null) {
        const base = getExcBase(interp, "BaseException");
        const bases: []const *Class = if (base) |b| &[_]*Class{b} else &.{};
        const d = try Dict.init(a);
        interp.asyncio_cancelled_error_class = try Class.init(a, "CancelledError", bases, d);
    }

    // TimeoutError subclasses Exception (note: asyncio.TimeoutError wraps builtins.TimeoutError)
    if (interp.asyncio_timeout_error_class == null) {
        const base = getExcBase(interp, "Exception");
        const bases: []const *Class = if (base) |b| &[_]*Class{b} else &.{};
        const d = try Dict.init(a);
        interp.asyncio_timeout_error_class = try Class.init(a, "TimeoutError", bases, d);
    }

    // InvalidStateError subclasses Exception
    if (interp.asyncio_invalid_state_class == null) {
        const base = getExcBase(interp, "Exception");
        const bases: []const *Class = if (base) |b| &[_]*Class{b} else &.{};
        const d = try Dict.init(a);
        interp.asyncio_invalid_state_class = try Class.init(a, "InvalidStateError", bases, d);
    }

    // Future
    if (interp.asyncio_future_class == null) {
        const d = try Dict.init(a);
        try regD(a, d, "__init__", futureInit);
        try regD(a, d, "done", futureDone);
        try regD(a, d, "cancelled", futureCancelled);
        try regD(a, d, "result", futureResult);
        try regD(a, d, "exception", futureException);
        try regD(a, d, "set_result", futureSetResult);
        try regD(a, d, "set_exception", futureSetException);
        try regKwD(a, d, "cancel", futureCancel, futureCancelKw);
        try regD(a, d, "add_done_callback", futureAddDoneCallback);
        try regD(a, d, "__await__", futureAwait);
        interp.asyncio_future_class = try Class.init(a, "Future", &.{}, d);
    }

    // Task
    if (interp.asyncio_task_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "__init__", taskInit, taskInitKw);
        try regD(a, d, "done", taskDone);
        try regD(a, d, "cancelled", taskCancelled);
        try regD(a, d, "result", taskResult);
        try regD(a, d, "exception", taskException);
        try regKwD(a, d, "cancel", taskCancel, taskCancelKw);
        try regD(a, d, "add_done_callback", taskAddDoneCallback);
        try regD(a, d, "get_name", taskGetName);
        try regD(a, d, "set_name", taskSetName);
        try regD(a, d, "__await__", taskAwait);
        interp.asyncio_task_class = try Class.init(a, "Task", &.{}, d);
    }

    // Lock
    if (interp.asyncio_lock_class == null) {
        const d = try Dict.init(a);
        try regD(a, d, "__init__", lockInit);
        try regD(a, d, "locked", lockLocked);
        try regD(a, d, "acquire", lockAcquire);
        try regD(a, d, "release", lockRelease);
        try regD(a, d, "__aenter__", lockAenter);
        try regD(a, d, "__aexit__", lockAexit);
        interp.asyncio_lock_class = try Class.init(a, "Lock", &.{}, d);
    }

    // Event
    if (interp.asyncio_event_class == null) {
        const d = try Dict.init(a);
        try regD(a, d, "__init__", eventInit);
        try regD(a, d, "is_set", eventIsSet);
        try regD(a, d, "set", eventSet);
        try regD(a, d, "clear", eventClear);
        try regD(a, d, "wait", eventWait);
        interp.asyncio_event_class = try Class.init(a, "Event", &.{}, d);
    }

    // Condition
    if (interp.asyncio_condition_class == null) {
        const d = try Dict.init(a);
        try regD(a, d, "__init__", conditionInit);
        try regD(a, d, "__aenter__", conditionAenter);
        try regD(a, d, "__aexit__", conditionAexit);
        try regD(a, d, "notify_all", conditionNotifyAll);
        try regD(a, d, "notify", conditionNotify);
        try regD(a, d, "wait", conditionWait);
        interp.asyncio_condition_class = try Class.init(a, "Condition", &.{}, d);
    }

    // Semaphore
    if (interp.asyncio_semaphore_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "__init__", semaphoreInit, semaphoreInitKw);
        try regD(a, d, "locked", semaphoreLocked);
        try regD(a, d, "acquire", semaphoreAcquire);
        try regD(a, d, "release", semaphoreRelease);
        try regD(a, d, "__aenter__", semaphoreAenter);
        try regD(a, d, "__aexit__", semaphoreAexit);
        interp.asyncio_semaphore_class = try Class.init(a, "Semaphore", &.{}, d);
    }

    // BoundedSemaphore
    if (interp.asyncio_bounded_semaphore_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "__init__", semaphoreInit, semaphoreInitKw);
        try regD(a, d, "locked", semaphoreLocked);
        try regD(a, d, "acquire", semaphoreAcquire);
        try regD(a, d, "release", bsemaphoreRelease);
        try regD(a, d, "__aenter__", semaphoreAenter);
        try regD(a, d, "__aexit__", semaphoreAexit);
        interp.asyncio_bounded_semaphore_class = try Class.init(a, "BoundedSemaphore", &.{}, d);
    }

    // Queue
    if (interp.asyncio_queue_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "__init__", asyncQueueInit, asyncQueueInitKw);
        try regD(a, d, "empty", asyncQueueEmpty);
        try regD(a, d, "qsize", asyncQueueQsize);
        try regD(a, d, "put", asyncQueuePut);
        try regD(a, d, "get", asyncQueueGet);
        interp.asyncio_queue_class = try Class.init(a, "Queue", &.{}, d);
    }

    // LifoQueue
    if (interp.asyncio_lifo_queue_class == null) {
        const d = try Dict.init(a);
        try regD(a, d, "__init__", asyncLifoQueueInit);
        try regD(a, d, "empty", asyncQueueEmpty);
        try regD(a, d, "qsize", asyncQueueQsize);
        try regD(a, d, "put", asyncQueuePut);
        try regD(a, d, "get", asyncQueueGet);
        interp.asyncio_lifo_queue_class = try Class.init(a, "LifoQueue", &.{}, d);
    }

    // PriorityQueue
    if (interp.asyncio_priority_queue_class == null) {
        const d = try Dict.init(a);
        try regD(a, d, "__init__", asyncPriorityQueueInit);
        try regD(a, d, "empty", asyncQueueEmpty);
        try regD(a, d, "qsize", asyncQueueQsize);
        try regD(a, d, "put", asyncQueuePut);
        try regD(a, d, "get", asyncQueueGet);
        interp.asyncio_priority_queue_class = try Class.init(a, "PriorityQueue", &.{}, d);
    }

    // TaskGroup
    if (interp.asyncio_task_group_class == null) {
        const d = try Dict.init(a);
        try regD(a, d, "__init__", tgInit);
        try regKwD(a, d, "create_task", tgCreateTask, tgCreateTaskKw);
        try regD(a, d, "__aenter__", tgAenter);
        try regD(a, d, "__aexit__", tgAexit);
        interp.asyncio_task_group_class = try Class.init(a, "TaskGroup", &.{}, d);
    }

    // EventLoop
    if (interp.asyncio_event_loop_class == null) {
        const d = try Dict.init(a);
        try regD(a, d, "__init__", eventLoopInit);
        try regD(a, d, "run_until_complete", eventLoopRunUntilComplete);
        try regD(a, d, "close", eventLoopClose);
        interp.asyncio_event_loop_class = try Class.init(a, "EventLoop", &.{}, d);
    }

    // timeout context manager
    if (interp.asyncio_timeout_cm_class == null) {
        const d = try Dict.init(a);
        try regD(a, d, "__init__", timeoutCmInit);
        try regD(a, d, "__aenter__", timeoutCmAenter);
        try regD(a, d, "__aexit__", timeoutCmAexit);
        interp.asyncio_timeout_cm_class = try Class.init(a, "Timeout", &.{}, d);
    }
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);

    const m = try Module.init(a, "asyncio");

    try regM(a, m, "sleep", sleepFn);
    try regM(a, m, "run", runFn);
    try regM(a, m, "gather", gatherFn);
    try regKwM(a, m, "create_task", createTask, createTaskKw);
    try regM(a, m, "ensure_future", ensureFuture);
    try regKwM(a, m, "wait", waitFn, waitFnKw);
    try regKwM(a, m, "wait_for", waitForFn, waitForFnKw);
    try regM(a, m, "as_completed", asCompleted);
    try regM(a, m, "current_task", currentTask);
    try regM(a, m, "all_tasks", allTasks);
    try regM(a, m, "new_event_loop", newEventLoop);
    try regM(a, m, "get_event_loop", newEventLoop);
    try regM(a, m, "shield", shieldFn);
    try regM(a, m, "to_thread", toThread);
    try regM(a, m, "timeout", timeoutFn);

    try m.attrs.setStr(a, "Future", Value{ .class = interp.asyncio_future_class.? });
    try m.attrs.setStr(a, "Task", Value{ .class = interp.asyncio_task_class.? });
    try m.attrs.setStr(a, "Lock", Value{ .class = interp.asyncio_lock_class.? });
    try m.attrs.setStr(a, "Event", Value{ .class = interp.asyncio_event_class.? });
    try m.attrs.setStr(a, "Condition", Value{ .class = interp.asyncio_condition_class.? });
    try m.attrs.setStr(a, "Semaphore", Value{ .class = interp.asyncio_semaphore_class.? });
    try m.attrs.setStr(a, "BoundedSemaphore", Value{ .class = interp.asyncio_bounded_semaphore_class.? });
    try m.attrs.setStr(a, "Queue", Value{ .class = interp.asyncio_queue_class.? });
    try m.attrs.setStr(a, "LifoQueue", Value{ .class = interp.asyncio_lifo_queue_class.? });
    try m.attrs.setStr(a, "PriorityQueue", Value{ .class = interp.asyncio_priority_queue_class.? });
    try m.attrs.setStr(a, "TaskGroup", Value{ .class = interp.asyncio_task_group_class.? });
    try m.attrs.setStr(a, "CancelledError", Value{ .class = interp.asyncio_cancelled_error_class.? });
    try m.attrs.setStr(a, "TimeoutError", Value{ .class = interp.asyncio_timeout_error_class.? });
    try m.attrs.setStr(a, "InvalidStateError", Value{ .class = interp.asyncio_invalid_state_class.? });

    // Constants
    const fc = try Str.init(a, "FIRST_COMPLETED");
    try m.attrs.setStr(a, "FIRST_COMPLETED", Value{ .str = fc });
    const fe = try Str.init(a, "FIRST_EXCEPTION");
    try m.attrs.setStr(a, "FIRST_EXCEPTION", Value{ .str = fe });
    const ac = try Str.init(a, "ALL_COMPLETED");
    try m.attrs.setStr(a, "ALL_COMPLETED", Value{ .str = ac });

    return m;
}
