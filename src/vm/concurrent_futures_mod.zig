//! `concurrent.futures` — ThreadPoolExecutor, ProcessPoolExecutor,
//! Future, wait(), as_completed(). Deferred-execution model: submit()
//! queues work; result()/shutdown()/__exit__ drain synchronously.

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

fn strVal(a: std.mem.Allocator, s: []const u8) !Value {
    return Value{ .str = try Str.init(a, s) };
}

fn stateIs(inst: *Instance, s: []const u8) bool {
    const sv = inst.dict.getStr("_state") orelse return false;
    if (sv != .str) return false;
    return std.mem.eql(u8, sv.str.bytes, s);
}

// ===== callbacks =====

fn fireCallbacks(interp: *Interp, fut: *Instance) !void {
    const cb_v = fut.dict.getStr("_callbacks") orelse return;
    if (cb_v != .list) return;
    const items = cb_v.list.items.items;
    for (items) |cb| {
        const call_args = [_]Value{Value{ .instance = fut }};
        _ = dispatch.invoke(interp, cb, &call_args) catch {};
    }
    cb_v.list.items = .empty;
}

// ===== drain executor =====

fn drainExecutor(interp: *Interp, ex: *Instance) !void {
    const a = interp.allocator;

    // Run initializer once per executor
    const init_done_v = ex.dict.getStr("_init_done") orelse Value{ .boolean = false };
    const init_done = init_done_v == .boolean and init_done_v.boolean;
    if (!init_done) {
        const init_fn = ex.dict.getStr("_initializer") orelse Value.none;
        if (init_fn != .none) {
            var init_call_args: []const Value = &.{};
            if (ex.dict.getStr("_initargs")) |ia| {
                if (ia == .tuple) init_call_args = ia.tuple.items;
                if (ia == .list) init_call_args = ia.list.items.items;
            }
            _ = dispatch.invoke(interp, init_fn, init_call_args) catch {};
        }
        try ex.dict.setStr(a, "_init_done", Value{ .boolean = true });
    }

    // Drain pending list
    const pend_v = ex.dict.getStr("_pending") orelse return;
    if (pend_v != .list) return;

    while (pend_v.list.items.items.len > 0) {
        const entry = pend_v.list.items.orderedRemove(0);
        // entry is a tuple: [future_inst, fn_val, args_list]
        if (entry != .tuple) continue;
        const t = entry.tuple.items;
        if (t.len < 3) continue;
        const fut_v = t[0];
        const fn_v = t[1];
        const args_v = t[2];
        if (fut_v != .instance) continue;
        const fut = fut_v.instance;

        if (stateIs(fut, "CANCELLED")) continue;

        try fut.dict.setStr(a, "_state", try strVal(a, "RUNNING"));

        var call_args: []const Value = &.{};
        if (args_v == .list) call_args = args_v.list.items.items;
        if (args_v == .tuple) call_args = args_v.tuple.items;

        const result = dispatch.invoke(interp, fn_v, call_args) catch |e| blk: {
            if (e == error.PyException) {
                if (interp.current_exc) |exc| {
                    try fut.dict.setStr(a, "_exc", exc);
                    interp.current_exc = null;
                }
                try fut.dict.setStr(a, "_state", try strVal(a, "FINISHED"));
                try fireCallbacks(interp, fut);
                break :blk Value.none;
            }
            try fut.dict.setStr(a, "_state", try strVal(a, "FINISHED"));
            try fireCallbacks(interp, fut);
            return e;
        };

        if (!stateIs(fut, "FINISHED")) {
            try fut.dict.setStr(a, "_result", result);
            try fut.dict.setStr(a, "_state", try strVal(a, "FINISHED"));
            try fireCallbacks(interp, fut);
        }
    }
}

// ===== Future methods =====

fn futureResult(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);

    if (stateIs(inst, "PENDING") or stateIs(inst, "RUNNING")) {
        if (inst.dict.getStr("_executor")) |ex_v| {
            if (ex_v == .instance) try drainExecutor(interp, ex_v.instance);
        }
    }

    if (stateIs(inst, "CANCELLED")) {
        try interp.raisePy("CancelledError", "Future was cancelled");
        return error.PyException;
    }

    if (inst.dict.getStr("_exc")) |exc_v| {
        if (exc_v != .none) {
            interp.current_exc = exc_v;
            return error.PyException;
        }
    }

    return inst.dict.getStr("_result") orelse Value.none;
}

fn futureException(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);

    if (stateIs(inst, "PENDING") or stateIs(inst, "RUNNING")) {
        if (inst.dict.getStr("_executor")) |ex_v| {
            if (ex_v == .instance) try drainExecutor(interp, ex_v.instance);
        }
    }

    if (stateIs(inst, "CANCELLED")) {
        try interp.raisePy("CancelledError", "Future was cancelled");
        return error.PyException;
    }

    return inst.dict.getStr("_exc") orelse Value.none;
}

fn futureCancel(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    if (stateIs(inst, "PENDING")) {
        try inst.dict.setStr(a, "_state", try strVal(a, "CANCELLED"));
        return Value{ .boolean = true };
    }
    return Value{ .boolean = false };
}

fn futureDone(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return Value{ .boolean = stateIs(inst, "FINISHED") or stateIs(inst, "CANCELLED") };
}

fn futureCancelled(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return Value{ .boolean = stateIs(inst, "CANCELLED") };
}

fn futureRunning(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return Value{ .boolean = stateIs(inst, "RUNNING") };
}

fn futureAddCallback(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    if (args.len < 2) return Value.none;
    const cb = args[1];

    if (stateIs(inst, "FINISHED") or stateIs(inst, "CANCELLED")) {
        const call_args = [_]Value{Value{ .instance = inst }};
        _ = dispatch.invoke(interp, cb, &call_args) catch {};
        return Value.none;
    }

    const cb_v = inst.dict.getStr("_callbacks") orelse blk: {
        const l = try List.init(a);
        const lv = Value{ .list = l };
        try inst.dict.setStr(a, "_callbacks", lv);
        break :blk lv;
    };
    if (cb_v == .list) try cb_v.list.append(a, cb);
    return Value.none;
}

// ===== make future =====

fn makeFuture(interp: *Interp, ex_inst: *Instance) !*Instance {
    const a = interp.allocator;
    const fut = try Instance.init(a, interp.cf_future_class.?);
    try fut.dict.setStr(a, "_state", try strVal(a, "PENDING"));
    try fut.dict.setStr(a, "_result", Value.none);
    try fut.dict.setStr(a, "_exc", Value.none);
    const cb_list = try List.init(a);
    try fut.dict.setStr(a, "_callbacks", Value{ .list = cb_list });
    try fut.dict.setStr(a, "_executor", Value{ .instance = ex_inst });
    return fut;
}

// ===== Executor submit =====

fn exSubmit(p: *anyopaque, args: []const Value) anyerror!Value {
    return exSubmitImpl(p, args, &.{}, &.{});
}

fn exSubmitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return exSubmitImpl(p, args, kn, kv);
}

fn exSubmitImpl(p: *anyopaque, args: []const Value, _kn: []const Value, _kv: []const Value) anyerror!Value {
    _ = _kn;
    _ = _kv;
    const interp = gi(p);
    const a = interp.allocator;
    const ex = try instArg(args);

    if (ex.dict.getStr("_shutdown")) |sv| {
        if (sv == .boolean and sv.boolean) {
            try interp.raisePy("RuntimeError", "cannot schedule new futures after shutdown");
            return error.PyException;
        }
    }

    if (args.len < 2) return Value.none;
    const fn_v = args[1];

    const call_args_list = try List.init(a);
    if (args.len > 2) {
        for (args[2..]) |arg| try call_args_list.append(a, arg);
    }

    const fut = try makeFuture(interp, ex);

    const entry_items = try a.alloc(Value, 3);
    entry_items[0] = Value{ .instance = fut };
    entry_items[1] = fn_v;
    entry_items[2] = Value{ .list = call_args_list };
    const entry = try Tuple.fromSlice(a, entry_items);

    const pend_v = ex.dict.getStr("_pending") orelse blk: {
        const l = try List.init(a);
        const lv = Value{ .list = l };
        try ex.dict.setStr(a, "_pending", lv);
        break :blk lv;
    };
    if (pend_v == .list) try pend_v.list.append(a, Value{ .tuple = entry });

    return Value{ .instance = fut };
}

// ===== Executor map =====

fn exMap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const ex = try instArg(args);

    if (args.len < 3) return Value{ .list = try List.init(a) };
    const fn_v = args[1];

    var iters: std.ArrayListUnmanaged([]const Value) = .empty;
    defer iters.deinit(a);
    for (args[2..]) |itv| {
        const slice: []const Value = switch (itv) {
            .list => |l| l.items.items,
            .tuple => |t| t.items,
            else => &.{},
        };
        try iters.append(a, slice);
    }
    if (iters.items.len == 0) return Value{ .list = try List.init(a) };

    const count = iters.items[0].len;
    var future_vals: std.ArrayListUnmanaged(Value) = .empty;
    defer future_vals.deinit(a);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const call_args_list = try List.init(a);
        for (iters.items) |iter_items| {
            if (i < iter_items.len) try call_args_list.append(a, iter_items[i]);
        }
        const fut = try makeFuture(interp, ex);
        const entry_items = try a.alloc(Value, 3);
        entry_items[0] = Value{ .instance = fut };
        entry_items[1] = fn_v;
        entry_items[2] = Value{ .list = call_args_list };
        const entry = try Tuple.fromSlice(a, entry_items);

        const pend_v = ex.dict.getStr("_pending") orelse blk: {
            const l = try List.init(a);
            const lv = Value{ .list = l };
            try ex.dict.setStr(a, "_pending", lv);
            break :blk lv;
        };
        if (pend_v == .list) try pend_v.list.append(a, Value{ .tuple = entry });
        try future_vals.append(a, Value{ .instance = fut });
    }

    // Drain all futures
    try drainExecutor(interp, ex);

    // Collect results
    const result_list = try List.init(a);
    for (future_vals.items) |fv| {
        const r = try futureResult(p, &.{fv});
        try result_list.append(a, r);
    }
    return Value{ .list = result_list };
}

// ===== Executor shutdown =====

fn exShutdown(p: *anyopaque, args: []const Value) anyerror!Value {
    return exShutdownKw(p, args, &.{}, &.{});
}

fn exShutdownKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const ex = try instArg(args);

    var do_wait = true;
    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        if (std.mem.eql(u8, nm.str.bytes, "wait")) do_wait = vl == .boolean and vl.boolean;
    }
    if (args.len >= 2 and args[1] == .boolean) do_wait = args[1].boolean;

    if (do_wait) try drainExecutor(interp, ex);
    try ex.dict.setStr(a, "_shutdown", Value{ .boolean = true });
    return Value.none;
}

fn exEnter(_: *anyopaque, args: []const Value) anyerror!Value {
    return args[0];
}

fn exExit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const ex = try instArg(args);
    try drainExecutor(interp, ex);
    try ex.dict.setStr(a, "_shutdown", Value{ .boolean = true });
    return Value{ .boolean = false };
}

// ===== Executor constructors =====

fn exCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    return exCtorImpl(p, args, &.{}, &.{}, false);
}

fn exCtorKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return exCtorImpl(p, args, kn, kv, false);
}

fn pexCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    return exCtorImpl(p, args, &.{}, &.{}, true);
}

fn pexCtorKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return exCtorImpl(p, args, kn, kv, true);
}

fn exCtorImpl(p: *anyopaque, _args: []const Value, kn: []const Value, kv: []const Value, use_ppe: bool) anyerror!Value {
    _ = _args;
    const interp = gi(p);
    const a = interp.allocator;

    var initializer_v: Value = Value.none;
    var initargs_v: Value = Value.none;

    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        const k = nm.str.bytes;
        if (std.mem.eql(u8, k, "initializer")) initializer_v = vl;
        if (std.mem.eql(u8, k, "initargs")) initargs_v = vl;
    }

    const cls = if (use_ppe) interp.cf_ppe_class.? else interp.cf_tpe_class.?;
    const ex = try Instance.init(a, cls);
    const pend = try List.init(a);
    try ex.dict.setStr(a, "_pending", Value{ .list = pend });
    try ex.dict.setStr(a, "_shutdown", Value{ .boolean = false });
    try ex.dict.setStr(a, "_init_done", Value{ .boolean = false });
    try ex.dict.setStr(a, "_initializer", initializer_v);
    try ex.dict.setStr(a, "_initargs", initargs_v);
    return Value{ .instance = ex };
}

// ===== module-level wait() =====

fn modWait(p: *anyopaque, args: []const Value) anyerror!Value {
    return modWaitKw(p, args, &.{}, &.{});
}

fn modWaitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;

    if (args.len < 1) return Value.none;
    const fs_v = args[0];

    var return_when: []const u8 = "ALL_COMPLETED";
    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        if (std.mem.eql(u8, nm.str.bytes, "return_when") and vl == .str)
            return_when = vl.str.bytes;
    }

    var futures: []const Value = &.{};
    if (fs_v == .list) futures = fs_v.list.items.items;
    if (fs_v == .tuple) futures = fs_v.tuple.items;

    // Drain all pending futures
    for (futures) |fv| {
        if (fv != .instance) continue;
        const fut = fv.instance;
        if (!stateIs(fut, "FINISHED") and !stateIs(fut, "CANCELLED")) {
            if (fut.dict.getStr("_executor")) |ex_v| {
                if (ex_v == .instance) try drainExecutor(interp, ex_v.instance);
            }
        }
    }

    const done_set = try List.init(a);
    const not_done_set = try List.init(a);

    if (std.mem.eql(u8, return_when, "FIRST_COMPLETED")) {
        var found = false;
        for (futures) |fv| {
            const is_done = fv == .instance and (stateIs(fv.instance, "FINISHED") or stateIs(fv.instance, "CANCELLED"));
            if (!found and is_done) {
                try done_set.append(a, fv);
                found = true;
            } else {
                try not_done_set.append(a, fv);
            }
        }
    } else if (std.mem.eql(u8, return_when, "FIRST_EXCEPTION")) {
        var found_exc = false;
        for (futures) |fv| {
            const has_exc = blk: {
                if (fv != .instance) break :blk false;
                const ev = fv.instance.dict.getStr("_exc") orelse break :blk false;
                break :blk ev != .none;
            };
            if (has_exc and !found_exc) {
                found_exc = true;
                try done_set.append(a, fv);
            } else if (found_exc) {
                try not_done_set.append(a, fv);
            } else {
                try done_set.append(a, fv);
            }
        }
    } else {
        // ALL_COMPLETED
        for (futures) |fv| try done_set.append(a, fv);
    }

    const result_items = try a.alloc(Value, 2);
    result_items[0] = Value{ .list = done_set };
    result_items[1] = Value{ .list = not_done_set };
    return Value{ .tuple = try Tuple.fromSlice(a, result_items) };
}

// ===== module-level as_completed() =====

fn modAsCompleted(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;

    if (args.len < 1) return Value{ .list = try List.init(a) };
    const fs_v = args[0];

    var futures: []const Value = &.{};
    if (fs_v == .list) futures = fs_v.list.items.items;
    if (fs_v == .tuple) futures = fs_v.tuple.items;

    for (futures) |fv| {
        if (fv != .instance) continue;
        const fut = fv.instance;
        if (!stateIs(fut, "FINISHED") and !stateIs(fut, "CANCELLED")) {
            if (fut.dict.getStr("_executor")) |ex_v| {
                if (ex_v == .instance) try drainExecutor(interp, ex_v.instance);
            }
        }
    }

    const result = try List.init(a);
    for (futures) |fv| try result.append(a, fv);
    return Value{ .list = result };
}

// ===== ensureClasses =====

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;

    if (interp.cf_future_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "result", futureResult);
        try reg(a, d, "exception", futureException);
        try reg(a, d, "cancel", futureCancel);
        try reg(a, d, "done", futureDone);
        try reg(a, d, "cancelled", futureCancelled);
        try reg(a, d, "running", futureRunning);
        try reg(a, d, "add_done_callback", futureAddCallback);
        interp.cf_future_class = try Class.init(a, "Future", &.{}, d);
    }

    if (interp.cf_tpe_class == null) {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", exCtor, exCtorKw);
        try regKw(a, d, "submit", exSubmit, exSubmitKw);
        try reg(a, d, "map", exMap);
        try regKw(a, d, "shutdown", exShutdown, exShutdownKw);
        try reg(a, d, "__enter__", exEnter);
        try reg(a, d, "__exit__", exExit);
        interp.cf_tpe_class = try Class.init(a, "ThreadPoolExecutor", &.{}, d);
    }

    if (interp.cf_ppe_class == null) {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", pexCtor, pexCtorKw);
        try regKw(a, d, "submit", exSubmit, exSubmitKw);
        try reg(a, d, "map", exMap);
        try regKw(a, d, "shutdown", exShutdown, exShutdownKw);
        try reg(a, d, "__enter__", exEnter);
        try reg(a, d, "__exit__", exExit);
        interp.cf_ppe_class = try Class.init(a, "ProcessPoolExecutor", &.{}, d);
    }
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "concurrent.futures");

    interp.cf_future_class = null;
    interp.cf_tpe_class = null;
    interp.cf_ppe_class = null;

    try ensureClasses(interp);

    try regMKw(a, m, "ThreadPoolExecutor", exCtor, exCtorKw);
    try regMKw(a, m, "ProcessPoolExecutor", pexCtor, pexCtorKw);
    try regMKw(a, m, "wait", modWait, modWaitKw);
    try regM(a, m, "as_completed", modAsCompleted);

    try m.attrs.setStr(a, "FIRST_COMPLETED", try strVal(a, "FIRST_COMPLETED"));
    try m.attrs.setStr(a, "FIRST_EXCEPTION", try strVal(a, "FIRST_EXCEPTION"));
    try m.attrs.setStr(a, "ALL_COMPLETED", try strVal(a, "ALL_COMPLETED"));

    // CancelledError from builtins
    if (interp.builtins.getStr("CancelledError")) |cls_v| {
        try m.attrs.setStr(a, "CancelledError", cls_v);
    }

    return m;
}
