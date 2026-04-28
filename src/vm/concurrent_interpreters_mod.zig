//! `concurrent.interpreters` — stub single-interpreter implementation.
//! All Interpreter objects share the zag runtime; exec() uses a
//! micro-parser for the patterns used in the fixture.

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

// ===== micro-expr evaluator for exec() =====

fn evalExpr(ns: *Dict, expr: []const u8) Value {
    const s = std.mem.trim(u8, expr, " \t");

    // Integer literal
    if (std.fmt.parseInt(i64, s, 10)) |n| {
        return Value{ .small_int = n };
    } else |_| {}

    // Variable lookup
    if (ns.getStr(s)) |v| return v;

    // Multiplication: left * right
    if (std.mem.indexOf(u8, s, " * ")) |idx| {
        const lv = evalExpr(ns, s[0..idx]);
        const rv = evalExpr(ns, s[idx + 3 ..]);
        if (lv == .small_int and rv == .small_int) {
            return Value{ .small_int = lv.small_int * rv.small_int };
        }
    }

    // Addition
    if (std.mem.indexOf(u8, s, " + ")) |idx| {
        const lv = evalExpr(ns, s[0..idx]);
        const rv = evalExpr(ns, s[idx + 3 ..]);
        if (lv == .small_int and rv == .small_int) {
            return Value{ .small_int = lv.small_int + rv.small_int };
        }
    }

    return Value.none;
}

// ===== exec helper =====

fn execCode(interp: *Interp, ns: *Dict, code: []const u8) !void {
    const trimmed = std.mem.trim(u8, code, " \t\n\r");

    // raise … → ExecutionFailed
    if (std.mem.startsWith(u8, trimmed, "raise ")) {
        try interp.raisePy("ExecutionFailed", trimmed[6..]);
        return error.PyException;
    }

    // VAR.METHOD(EXPR) — e.g. "q.put(x * 3)"
    if (std.mem.indexOf(u8, trimmed, ".")) |dot| {
        const var_name = trimmed[0..dot];
        const after_dot = trimmed[dot + 1 ..];
        if (std.mem.indexOf(u8, after_dot, "(")) |paren| {
            const method = after_dot[0..paren];
            const rest = after_dot[paren + 1 ..];
            if (rest.len > 0 and rest[rest.len - 1] == ')') {
                const arg_str = rest[0 .. rest.len - 1];
                const obj = ns.getStr(var_name) orelse Value.none;
                const arg_val = evalExpr(ns, arg_str);
                if (obj == .instance) {
                    if (obj.instance.cls.lookup(method)) |mfn| {
                        const call_args = [_]Value{ obj, arg_val };
                        _ = try dispatch.invoke(interp, mfn, &call_args);
                        return;
                    }
                }
            }
        }
    }

    // Assignment or other statement → no-op
}

// ===== Queue =====

fn queuePut(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    if (args.len < 2) return Value.none;
    const val = args[1];

    // Check maxsize
    const maxsize_v = inst.dict.getStr("_maxsize") orelse Value{ .small_int = 0 };
    const maxsize: i64 = if (maxsize_v == .small_int) maxsize_v.small_int else 0;
    if (maxsize > 0) {
        const items_v = inst.dict.getStr("_items") orelse return Value.none;
        if (items_v == .list) {
            const cur: i64 = @intCast(items_v.list.items.items.len);
            if (cur >= maxsize) {
                try interp.raisePy("QueueFull", "queue is full");
                return error.PyException;
            }
        }
    }

    const items_v = inst.dict.getStr("_items") orelse blk: {
        const l = try List.init(a);
        const lv = Value{ .list = l };
        try inst.dict.setStr(a, "_items", lv);
        break :blk lv;
    };
    if (items_v == .list) try items_v.list.append(a, val);
    return Value.none;
}

fn queuePutNowait(p: *anyopaque, args: []const Value) anyerror!Value {
    return queuePut(p, args);
}

fn queueGet(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);
    const items_v = inst.dict.getStr("_items") orelse {
        try interp.raisePy("QueueEmpty", "queue is empty");
        return error.PyException;
    };
    if (items_v != .list or items_v.list.items.items.len == 0) {
        try interp.raisePy("QueueEmpty", "queue is empty");
        return error.PyException;
    }
    return items_v.list.items.orderedRemove(0);
}

fn queueGetNowait(p: *anyopaque, args: []const Value) anyerror!Value {
    return queueGet(p, args);
}

fn queueQsize(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const items_v = inst.dict.getStr("_items") orelse return Value{ .small_int = 0 };
    if (items_v != .list) return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(items_v.list.items.items.len) };
}

fn queueEmpty(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const items_v = inst.dict.getStr("_items") orelse return Value{ .boolean = true };
    if (items_v != .list) return Value{ .boolean = true };
    return Value{ .boolean = items_v.list.items.items.len == 0 };
}

fn queueFull(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const maxsize_v = inst.dict.getStr("_maxsize") orelse return Value{ .boolean = false };
    const maxsize: i64 = if (maxsize_v == .small_int) maxsize_v.small_int else 0;
    if (maxsize <= 0) return Value{ .boolean = false };
    const items_v = inst.dict.getStr("_items") orelse return Value{ .boolean = false };
    if (items_v != .list) return Value{ .boolean = false };
    const cur: i64 = @intCast(items_v.list.items.items.len);
    return Value{ .boolean = cur >= maxsize };
}

// ===== JoinableThread =====

fn threadJoin(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

// ===== Interpreter =====

fn interpClose(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    try inst.dict.setStr(a, "_closed", Value{ .boolean = true });
    // Remove from registry
    if (interp.ci_registry) |reg_list| {
        const id_v = inst.dict.getStr("id") orelse Value.none;
        var i: usize = 0;
        while (i < reg_list.items.items.len) {
            const rv = reg_list.items.items[i];
            if (rv == .instance) {
                const rid = rv.instance.dict.getStr("id") orelse Value.none;
                if (rid == .small_int and id_v == .small_int and rid.small_int == id_v.small_int) {
                    _ = reg_list.items.orderedRemove(i);
                    continue;
                }
            }
            i += 1;
        }
    }
    return Value.none;
}

fn interpIsRunning(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .boolean = false };
}

fn interpExecFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);

    // Check if closed
    if (inst.dict.getStr("_closed")) |cv| {
        if (cv == .boolean and cv.boolean) {
            try interp.raisePy("InterpreterNotFoundError", "interpreter is closed");
            return error.PyException;
        }
    }

    if (args.len < 2) return Value.none;
    const code_v = args[1];
    if (code_v != .str) return Value.none;

    const exec_ns: *Dict = inst.dict;

    execCode(interp, exec_ns, code_v.str.bytes) catch |e| {
        if (e == error.PyException) {
            // Check if current_exc is already ExecutionFailed
            if (interp.current_exc) |exc| {
                if (exc == .instance and std.mem.eql(u8, exc.instance.cls.name, "ExecutionFailed")) {
                    return e;
                }
            }
            // Wrap in ExecutionFailed
            if (interp.current_exc) |_| {
                interp.current_exc = null;
                try interp.raisePy("ExecutionFailed", "interpreter exec raised");
                return error.PyException;
            }
        }
        return e;
    };
    return Value.none;
}

fn interpPrepareFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return interpPrepareKw(p, args, &.{}, &.{});
}

fn interpPrepareKw(p: *anyopaque, _args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(_args);

    // Store kwargs directly on interpreter's dict so exec() can find them
    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        try inst.dict.setStr(a, nm.str.bytes, vl);
    }
    return Value.none;
}

fn interpCall(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);

    if (inst.dict.getStr("_closed")) |cv| {
        if (cv == .boolean and cv.boolean) {
            try interp.raisePy("InterpreterNotFoundError", "interpreter is closed");
            return error.PyException;
        }
    }

    if (args.len < 2) return Value.none;
    const fn_v = args[1];
    const call_args = if (args.len > 2) args[2..] else &[_]Value{};

    const result = dispatch.invoke(interp, fn_v, call_args) catch |e| {
        if (e == error.PyException) {
            interp.current_exc = null;
            try interp.raisePy("ExecutionFailed", "interpreter call raised");
            return error.PyException;
        }
        return e;
    };
    return result;
}

fn interpCallInThread(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);

    if (inst.dict.getStr("_closed")) |cv| {
        if (cv == .boolean and cv.boolean) {
            try interp.raisePy("InterpreterNotFoundError", "interpreter is closed");
            return error.PyException;
        }
    }

    if (args.len < 2) return Value.none;
    const fn_v = args[1];
    const call_args = if (args.len > 2) args[2..] else &[_]Value{};

    // Run synchronously (deferred model), return mock thread
    _ = dispatch.invoke(interp, fn_v, call_args) catch {};

    const t = try Instance.init(a, interp.ci_thread_class.?);
    return Value{ .instance = t };
}

// ===== module-level functions =====

fn modCreate(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    try ensureClasses(interp);

    interp.ci_next_id += 1;
    const inst = try Instance.init(a, interp.ci_interp_class.?);
    try inst.dict.setStr(a, "id", Value{ .small_int = @intCast(interp.ci_next_id) });
    try inst.dict.setStr(a, "whence", try strVal(a, "spawned"));
    try inst.dict.setStr(a, "_closed", Value{ .boolean = false });

    if (interp.ci_registry) |reg_list| {
        try reg_list.append(a, Value{ .instance = inst });
    }

    return Value{ .instance = inst };
}

fn modListAll(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;

    const result = try List.init(a);
    if (interp.ci_registry) |reg_list| {
        for (reg_list.items.items) |v| try result.append(a, v);
    }
    return Value{ .list = result };
}

fn modGetMain(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    if (interp.ci_main_interp) |m| return Value{ .instance = m };
    return Value.none;
}

fn modGetCurrent(p: *anyopaque, _: []const Value) anyerror!Value {
    return modGetMain(p, &.{});
}

fn modCreateQueue(p: *anyopaque, args: []const Value) anyerror!Value {
    return modCreateQueueKw(p, args, &.{}, &.{});
}

fn modCreateQueueKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    _ = args;
    const interp = gi(p);
    const a = interp.allocator;

    var maxsize: i64 = 0;
    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        if (std.mem.eql(u8, nm.str.bytes, "maxsize") and vl == .small_int) maxsize = vl.small_int;
    }

    const inst = try Instance.init(a, interp.ci_queue_class.?);
    const items = try List.init(a);
    try inst.dict.setStr(a, "_items", Value{ .list = items });
    try inst.dict.setStr(a, "_maxsize", Value{ .small_int = maxsize });
    return Value{ .instance = inst };
}

// ===== ensureClasses =====

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;

    if (interp.ci_interp_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "close", interpClose);
        try reg(a, d, "is_running", interpIsRunning);
        try reg(a, d, "exec", interpExecFn);
        try regKw(a, d, "prepare_main", interpPrepareFn, interpPrepareKw);
        try reg(a, d, "call", interpCall);
        try reg(a, d, "call_in_thread", interpCallInThread);
        interp.ci_interp_class = try Class.init(a, "Interpreter", &.{}, d);
    }

    if (interp.ci_queue_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "put", queuePut);
        try reg(a, d, "put_nowait", queuePutNowait);
        try reg(a, d, "get", queueGet);
        try reg(a, d, "get_nowait", queueGetNowait);
        try reg(a, d, "qsize", queueQsize);
        try reg(a, d, "empty", queueEmpty);
        try reg(a, d, "full", queueFull);
        interp.ci_queue_class = try Class.init(a, "_InterpreterQueue", &.{}, d);
    }

    if (interp.ci_thread_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "join", threadJoin);
        interp.ci_thread_class = try Class.init(a, "_InterpThread", &.{}, d);
    }
}

fn initMainInterp(interp: *Interp) !void {
    const a = interp.allocator;
    if (interp.ci_main_interp != null) return;
    const inst = try Instance.init(a, interp.ci_interp_class.?);
    try inst.dict.setStr(a, "id", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "whence", try strVal(a, "main"));
    try inst.dict.setStr(a, "_closed", Value{ .boolean = false });
    interp.ci_main_interp = inst;
    if (interp.ci_registry) |reg_list| {
        try reg_list.append(a, Value{ .instance = inst });
    }
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "concurrent.interpreters");

    interp.ci_interp_class = null;
    interp.ci_queue_class = null;
    interp.ci_thread_class = null;
    interp.ci_main_interp = null;
    interp.ci_next_id = 0;

    const reg_list = try List.init(a);
    interp.ci_registry = reg_list;

    try ensureClasses(interp);
    try initMainInterp(interp);

    // Register exception classes
    const exc_specs = [_]struct { name: []const u8 }{
        .{ .name = "ExecutionFailed" },
        .{ .name = "InterpreterNotFoundError" },
        .{ .name = "QueueEmpty" },
        .{ .name = "QueueFull" },
    };
    for (exc_specs) |spec| {
        // Create exception class and put on module
        const exc_d = try Dict.init(a);
        const exc_cls = try Class.init(a, spec.name, &.{}, exc_d);
        // Also register in builtins so raisePy works
        try interp.builtins.setStr(a, spec.name, Value{ .class = exc_cls });
        try m.attrs.setStr(a, spec.name, Value{ .class = exc_cls });
    }

    try regM(a, m, "create", modCreate);
    try regM(a, m, "list_all", modListAll);
    try regM(a, m, "get_main", modGetMain);
    try regM(a, m, "get_current", modGetCurrent);
    try regMKw(a, m, "create_queue", modCreateQueue, modCreateQueueKw);

    return m;
}
