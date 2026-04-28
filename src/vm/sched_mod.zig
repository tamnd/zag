//! `sched` module — event scheduler.

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

// ===== Event struct (stored as Instance) =====
// Fields: time (float), priority (int), action (callable), argument (tuple), kwargs (dict), sequence (int for FIFO)

fn makeEvent(a: std.mem.Allocator, interp: *Interp, t: f64, priority: i64, action: Value, argument: Value, kwargs: Value, seq: i64) !*Instance {
    const inst = try Instance.init(a, interp.sched_event_class.?);
    try inst.dict.setStr(a, "time", Value{ .float = t });
    try inst.dict.setStr(a, "priority", Value{ .small_int = priority });
    try inst.dict.setStr(a, "action", action);
    try inst.dict.setStr(a, "argument", argument);
    try inst.dict.setStr(a, "kwargs", kwargs);
    try inst.dict.setStr(a, "_seq", Value{ .small_int = seq });
    return inst;
}

fn eventKey(ev: *Instance) struct { t: f64, p: i64, s: i64 } {
    const t_v = ev.dict.getStr("time") orelse Value{ .float = 0 };
    const p_v = ev.dict.getStr("priority") orelse Value{ .small_int = 0 };
    const s_v = ev.dict.getStr("_seq") orelse Value{ .small_int = 0 };
    const t: f64 = switch (t_v) {
        .float => |f| f,
        .small_int => |i| @floatFromInt(i),
        else => 0,
    };
    const p: i64 = if (p_v == .small_int) p_v.small_int else 0;
    const s: i64 = if (s_v == .small_int) s_v.small_int else 0;
    return .{ .t = t, .p = p, .s = s };
}

fn evLess(a: *Instance, b: *Instance) bool {
    const ka = eventKey(a);
    const kb = eventKey(b);
    if (ka.t < kb.t) return true;
    if (ka.t > kb.t) return false;
    if (ka.p < kb.p) return true;
    if (ka.p > kb.p) return false;
    return ka.s < kb.s;
}

// ===== Scheduler state stored on instance =====
// inst.dict: _timefunc, _delayfunc, _events (list of event instances), _seq (next sequence)

fn getSchedulerEvents(inst: *Instance) ?*List {
    const v = inst.dict.getStr("_events") orelse return null;
    if (v != .list) return null;
    return v.list;
}

fn getSchedulerSeq(inst: *Instance) i64 {
    const v = inst.dict.getStr("_seq") orelse return 0;
    if (v != .small_int) return 0;
    return v.small_int;
}

fn incSchedulerSeq(a: std.mem.Allocator, inst: *Instance) !i64 {
    const s = getSchedulerSeq(inst);
    try inst.dict.setStr(a, "_seq", Value{ .small_int = s + 1 });
    return s;
}

fn callTimefunc(interp: *Interp, inst: *Instance) !f64 {
    const tf = inst.dict.getStr("_timefunc") orelse return 0;
    const result = @import("dispatch.zig").invoke(interp, tf, &.{}) catch return 0;
    return switch (result) {
        .float => |f| f,
        .small_int => |i| @floatFromInt(i),
        else => 0,
    };
}

fn callDelayfunc(interp: *Interp, inst: *Instance, secs: f64) !void {
    const df = inst.dict.getStr("_delayfunc") orelse return;
    const arg = Value{ .float = secs };
    _ = @import("dispatch.zig").invoke(interp, df, &.{arg}) catch {};
}

// ===== sorted insert =====

fn insertSorted(a: std.mem.Allocator, events: *List, ev: *Instance) !void {
    // Binary search insertion to keep list sorted
    var lo: usize = 0;
    var hi: usize = events.items.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const mid_ev = events.items.items[mid];
        if (mid_ev != .instance) {
            lo = mid + 1;
            continue;
        }
        if (evLess(ev, mid_ev.instance)) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    try events.items.insert(a, lo, Value{ .instance = ev });
}

// ===== scheduler() constructor =====

fn schedulerCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    return schedulerCtorKw(p, args, &.{}, &.{});
}

// Module-level scheduler() function (not a class method)
fn schedulerNew(p: *anyopaque, args: []const Value) anyerror!Value {
    return schedulerNewKw(p, args, &.{}, &.{});
}

fn schedulerNewKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    _ = kn;
    _ = kv;
    const interp = gi(p);
    const a = interp.allocator;

    const inst = try Instance.init(a, interp.sched_scheduler_class.?);
    const events = try List.init(a);
    try inst.dict.setStr(a, "_events", Value{ .list = events });
    try inst.dict.setStr(a, "_seq", Value{ .small_int = 0 });

    const timefunc: Value = if (args.len >= 1 and args[0] != .none) args[0] else blk: {
        const time_mod = interp.getBuiltinModule("time") orelse break :blk Value.none;
        break :blk time_mod.attrs.getStr("monotonic") orelse Value.none;
    };
    const delayfunc: Value = if (args.len >= 2 and args[1] != .none) args[1] else blk: {
        const time_mod = interp.getBuiltinModule("time") orelse break :blk Value.none;
        break :blk time_mod.attrs.getStr("sleep") orelse Value.none;
    };

    try inst.dict.setStr(a, "_timefunc", timefunc);
    try inst.dict.setStr(a, "_delayfunc", delayfunc);

    return Value{ .instance = inst };
}

fn schedulerCtorKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    _ = kn;
    _ = kv;
    const interp = gi(p);
    const a = interp.allocator;

    // args[0] = self (already-created instance from class dispatch)
    const inst = try instArg(args);
    const events = try List.init(a);
    try inst.dict.setStr(a, "_events", Value{ .list = events });
    try inst.dict.setStr(a, "queue", Value{ .list = events });
    try inst.dict.setStr(a, "_seq", Value{ .small_int = 0 });

    // timefunc is args[1]; defaults to time.monotonic
    const timefunc: Value = if (args.len >= 2 and args[1] != .none) args[1] else blk: {
        const time_mod = interp.getBuiltinModule("time") orelse break :blk Value.none;
        break :blk time_mod.attrs.getStr("monotonic") orelse Value.none;
    };
    // delayfunc is args[2]; defaults to time.sleep
    const delayfunc: Value = if (args.len >= 3 and args[2] != .none) args[2] else blk: {
        const time_mod = interp.getBuiltinModule("time") orelse break :blk Value.none;
        break :blk time_mod.attrs.getStr("sleep") orelse Value.none;
    };

    try inst.dict.setStr(a, "_timefunc", timefunc);
    try inst.dict.setStr(a, "_delayfunc", delayfunc);

    return Value.none;
}

// ===== enter() =====

fn schedEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    return schedEnterKw(p, args, &.{}, &.{});
}

fn schedEnterKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);

    const delay: f64 = if (args.len >= 2) switch (args[1]) {
        .float => |f| f,
        .small_int => |i| @floatFromInt(i),
        else => 0,
    } else 0;
    const priority: i64 = if (args.len >= 3 and args[2] == .small_int) args[2].small_int else 0;
    const action: Value = if (args.len >= 4) args[3] else Value.none;

    var argument: Value = Value{ .tuple = try Tuple.init(a, 0) };
    var kwargs: Value = Value{ .dict = try Dict.init(a) };

    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        if (std.mem.eql(u8, nm.str.bytes, "argument")) argument = vl;
        if (std.mem.eql(u8, nm.str.bytes, "kwargs")) kwargs = vl;
    }
    if (args.len >= 5) argument = args[4];
    if (args.len >= 6) kwargs = args[5];

    const now = try callTimefunc(interp, inst);
    const abs_time = now + delay;
    const seq = try incSchedulerSeq(a, inst);
    const ev = try makeEvent(a, interp, abs_time, priority, action, argument, kwargs, seq);

    const events = getSchedulerEvents(inst) orelse return error.TypeError;
    try insertSorted(a, events, ev);

    return Value{ .instance = ev };
}

// ===== enterabs() =====

fn schedEnterabs(p: *anyopaque, args: []const Value) anyerror!Value {
    return schedEnterabsKw(p, args, &.{}, &.{});
}

fn schedEnterabsKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);

    const abs_time: f64 = if (args.len >= 2) switch (args[1]) {
        .float => |f| f,
        .small_int => |i| @floatFromInt(i),
        else => 0,
    } else 0;
    const priority: i64 = if (args.len >= 3 and args[2] == .small_int) args[2].small_int else 0;
    const action: Value = if (args.len >= 4) args[3] else Value.none;

    var argument: Value = Value{ .tuple = try Tuple.init(a, 0) };
    var kwargs: Value = Value{ .dict = try Dict.init(a) };

    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        if (std.mem.eql(u8, nm.str.bytes, "argument")) argument = vl;
        if (std.mem.eql(u8, nm.str.bytes, "kwargs")) kwargs = vl;
    }
    if (args.len >= 5) argument = args[4];
    if (args.len >= 6) kwargs = args[5];

    const seq = try incSchedulerSeq(a, inst);
    const ev = try makeEvent(a, interp, abs_time, priority, action, argument, kwargs, seq);

    const events = getSchedulerEvents(inst) orelse return error.TypeError;
    try insertSorted(a, events, ev);

    return Value{ .instance = ev };
}

// ===== cancel() =====

fn schedCancel(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);
    if (args.len < 2 or args[1] != .instance) {
        try interp.raisePy("ValueError", "event not in queue");
        return error.PyException;
    }
    const target = args[1].instance;
    const events = getSchedulerEvents(inst) orelse return error.TypeError;

    for (events.items.items, 0..) |item, i| {
        if (item == .instance and item.instance == target) {
            _ = events.items.orderedRemove(i);
            return Value.none;
        }
    }
    try interp.raisePy("ValueError", "event not in queue");
    return error.PyException;
}

// ===== empty() =====

fn schedEmpty(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const events = getSchedulerEvents(inst) orelse return Value{ .boolean = true };
    return Value{ .boolean = events.items.items.len == 0 };
}

// ===== queue property =====

fn schedQueue(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const events = getSchedulerEvents(inst) orelse return Value{ .list = undefined };
    return Value{ .list = events };
}

// ===== run() =====

fn schedRun(p: *anyopaque, args: []const Value) anyerror!Value {
    return schedRunKw(p, args, &.{}, &.{});
}

fn schedRunKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);

    var blocking = true;
    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        if (std.mem.eql(u8, nm.str.bytes, "blocking")) {
            blocking = vl == .boolean and vl.boolean;
        }
    }
    if (args.len >= 2) {
        blocking = args[1] == .boolean and args[1].boolean;
    }

    const events = getSchedulerEvents(inst) orelse return Value.none;

    while (events.items.items.len > 0) {
        const first_v = events.items.items[0];
        if (first_v != .instance) {
            _ = events.items.orderedRemove(0);
            continue;
        }
        const first = first_v.instance;
        const key = eventKey(first);
        const now = try callTimefunc(interp, inst);

        if (key.t > now) {
            if (!blocking) {
                // Return time until next event
                return Value{ .float = key.t - now };
            }
            // Sleep until the event time
            try callDelayfunc(interp, inst, key.t - now);
            continue;
        }

        // Event is due — remove and run it
        _ = events.items.orderedRemove(0);

        const action = first.dict.getStr("action") orelse continue;
        const argument = first.dict.getStr("argument") orelse Value{ .tuple = try Tuple.init(a, 0) };
        const kwargs_v = first.dict.getStr("kwargs") orelse Value{ .dict = try Dict.init(a) };

        // Build positional args from argument tuple/list
        var pos: std.ArrayListUnmanaged(Value) = .empty;
        defer pos.deinit(a);
        switch (argument) {
            .tuple => |t| for (t.items) |item| try pos.append(a, item),
            .list => |l| for (l.items.items) |item| try pos.append(a, item),
            else => {},
        }

        // Build kw args from kwargs dict
        var kw_names: std.ArrayListUnmanaged(Value) = .empty;
        defer kw_names.deinit(a);
        var kw_values: std.ArrayListUnmanaged(Value) = .empty;
        defer kw_values.deinit(a);
        if (kwargs_v == .dict) {
            for (kwargs_v.dict.pairs.items) |pair| {
                try kw_names.append(a, pair.key);
                try kw_values.append(a, pair.value);
            }
        }

        _ = @import("dispatch.zig").invokeKw(interp, action, pos.items, kw_names.items, kw_values.items) catch {};

        if (!blocking) {
            // After running due events, if queue not empty return next deadline
            if (events.items.items.len > 0) {
                const next_v = events.items.items[0];
                if (next_v == .instance) {
                    const next_key = eventKey(next_v.instance);
                    const now2 = try callTimefunc(interp, inst);
                    return Value{ .float = next_key.t - now2 };
                }
            }
            return Value.none;
        }
    }

    return Value.none;
}

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;

    if (interp.sched_event_class == null) {
        const d = try Dict.init(a);
        interp.sched_event_class = try Class.init(a, "Event", &.{}, d);
    }

    if (interp.sched_scheduler_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "__init__", schedulerCtor, schedulerCtorKw);
        try regKwD(a, d, "enter", schedEnter, schedEnterKw);
        try regKwD(a, d, "enterabs", schedEnterabs, schedEnterabsKw);
        try regD(a, d, "cancel", schedCancel);
        try regD(a, d, "empty", schedEmpty);
        try regKwD(a, d, "run", schedRun, schedRunKw);
        interp.sched_scheduler_class = try Class.init(a, "scheduler", &.{}, d);
    }
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);

    const m = try Module.init(a, "sched");
    // Expose as a class so `sched.scheduler(timefunc, delayfunc)` works
    try m.attrs.setStr(a, "scheduler", Value{ .class = interp.sched_scheduler_class.? });

    return m;
}
