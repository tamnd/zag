//! `contextvars` module — ContextVar, Token, Context, copy_context().
//!
//! Context storage: a *Dict where each pair is (cv_ptr_int, cv_value).
//! cv_ptr_int = small_int(@intFromPtr(cv_instance)) used as unique key.
//! A parallel `_cvs` list stores the ContextVar instances for iteration.

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

// ===== Context storage helpers =====
// Contexts are stored as a Dict mapping small_int(cv_ptr) -> stored_value.
// A parallel _cvs list keeps track of which ContextVar instances are present.

const CtxStore = struct { data: *Dict, cvs: *List };

fn getContextStore(interp: *Interp) !CtxStore {
    if (interp.cv_context_data) |d| {
        const cvs = if (interp.cv_context_cvs) |l| l else blk: {
            const l = try List.init(interp.allocator);
            interp.cv_context_cvs = l;
            break :blk l;
        };
        return .{ .data = d, .cvs = cvs };
    }
    const d = try Dict.init(interp.allocator);
    const cvs = try List.init(interp.allocator);
    interp.cv_context_data = d;
    interp.cv_context_cvs = cvs;
    return .{ .data = d, .cvs = cvs };
}

fn cvPtrKey(cv: *Instance) i64 {
    return @intCast(@as(i64, @bitCast(@intFromPtr(cv) & 0x7fffffffffffffff)));
}

fn ctxStoreGet(store: CtxStore, cv: *Instance) ?Value {
    const key = Value{ .small_int = cvPtrKey(cv) };
    for (store.data.pairs.items) |pair| {
        if (pair.key == .small_int and pair.key.small_int == key.small_int) return pair.value;
    }
    return null;
}

fn ctxStoreSet(a: std.mem.Allocator, store: CtxStore, cv: *Instance, val: Value) !void {
    const key = Value{ .small_int = cvPtrKey(cv) };
    // Check if already present
    for (store.data.pairs.items) |*pair| {
        if (pair.key == .small_int and pair.key.small_int == key.small_int) {
            pair.value = val;
            return;
        }
    }
    // New entry
    try store.data.pairs.append(a, .{ .key = key, .value = val });
    try store.cvs.items.append(a, Value{ .instance = cv });
}

fn ctxStoreDelete(store: CtxStore, cv: *Instance) void {
    const key = cvPtrKey(cv);
    for (store.data.pairs.items, 0..) |pair, i| {
        if (pair.key == .small_int and pair.key.small_int == key) {
            _ = store.data.pairs.orderedRemove(i);
            break;
        }
    }
    for (store.cvs.items.items, 0..) |item, i| {
        if (item == .instance and item.instance == cv) {
            _ = store.cvs.items.orderedRemove(i);
            break;
        }
    }
}

fn cloneCtxStore(a: std.mem.Allocator, src_data: *Dict, src_cvs: *List) !CtxStore {
    const dst_data = try Dict.init(a);
    const dst_cvs = try List.init(a);
    for (src_data.pairs.items) |pair| try dst_data.pairs.append(a, pair);
    for (src_cvs.items.items) |item| try dst_cvs.items.append(a, item);
    return .{ .data = dst_data, .cvs = dst_cvs };
}

// ===== ContextVar constructor =====

fn cvCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    return cvCtorKw(p, args, &.{}, &.{});
}

fn cvCtorKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);

    const name_v: Value = if (args.len >= 2) args[1] else try sv(a, "");
    try inst.dict.setStr(a, "name", name_v);

    var has_default = false;
    var default_val: Value = Value.none;
    for (kn, kv) |nm, vl| {
        if (nm == .str and std.mem.eql(u8, nm.str.bytes, "default")) {
            has_default = true;
            default_val = vl;
        }
    }
    if (has_default) {
        try inst.dict.setStr(a, "_has_default", Value{ .boolean = true });
        try inst.dict.setStr(a, "_default", default_val);
    } else {
        try inst.dict.setStr(a, "_has_default", Value{ .boolean = false });
    }

    return Value.none;
}

// ===== ContextVar.get =====

fn cvGet(p: *anyopaque, args: []const Value) anyerror!Value {
    return cvGetKw(p, args, &.{}, &.{});
}

fn cvGetKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);
    const store = try getContextStore(interp);

    if (ctxStoreGet(store, inst)) |val| return val;

    // Not in context — check arg default (args[1]) or var default
    if (args.len >= 2 and args[1] != .none) return args[1];

    const has_def = inst.dict.getStr("_has_default") orelse Value{ .boolean = false };
    if (has_def == .boolean and has_def.boolean) {
        return inst.dict.getStr("_default") orelse Value.none;
    }

    try interp.raisePy("LookupError", "ContextVar has no value");
    return error.PyException;
}

// ===== ContextVar.set =====

fn cvSet(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const val: Value = if (args.len >= 2) args[1] else Value.none;
    const store = try getContextStore(interp);

    // Get old value before setting
    const old_val: Value = ctxStoreGet(store, inst) orelse
        (interp.cv_missing orelse Value.none);

    try ctxStoreSet(a, store, inst, val);

    // Create Token
    const tok = try Instance.init(a, interp.cv_token_class.?);
    try tok.dict.setStr(a, "var", Value{ .instance = inst });
    try tok.dict.setStr(a, "old_value", old_val);
    try tok.dict.setStr(a, "_used", Value{ .boolean = false });
    return Value{ .instance = tok };
}

// ===== ContextVar.reset =====

fn cvReset(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    if (args.len < 2 or args[1] != .instance) return Value.none;
    const tok = args[1].instance;
    const store = try getContextStore(interp);

    const old_v = tok.dict.getStr("old_value") orelse return Value.none;

    // If old_value is MISSING, delete from context
    const is_missing = if (interp.cv_missing) |m| blk: {
        break :blk old_v == .instance and m == .instance and old_v.instance == m.instance;
    } else false;

    if (is_missing) {
        ctxStoreDelete(store, inst);
    } else {
        try ctxStoreSet(a, store, inst, old_v);
    }
    return Value.none;
}

// ===== Token as context manager =====

fn tokEnter(_: *anyopaque, args: []const Value) anyerror!Value {
    return if (args.len >= 1) args[0] else Value.none;
}

fn tokExit(p: *anyopaque, args: []const Value) anyerror!Value {
    // args[0] = token
    const tok = try instArg(args);
    const cv_v = tok.dict.getStr("var") orelse return Value{ .boolean = false };
    if (cv_v != .instance) return Value{ .boolean = false };
    // reset: pass cv_inst and tok to cvReset
    const reset_args = [_]Value{ cv_v, args[0] };
    _ = try cvReset(p, &reset_args);
    return Value{ .boolean = false };
}

// ===== copy_context() =====

fn copyContextFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp = gi(p);
    const a = interp.allocator;

    const store = try getContextStore(interp);
    const snap = try cloneCtxStore(a, store.data, store.cvs);

    const ctx = try Instance.init(a, interp.cv_context_class.?);
    try ctx.dict.setStr(a, "_data", Value{ .dict = snap.data });
    try ctx.dict.setStr(a, "_cvs", Value{ .list = snap.cvs });
    return Value{ .instance = ctx };
}

// ===== Context.run =====

fn ctxRun(p: *anyopaque, args: []const Value) anyerror!Value {
    return ctxRunKw(p, args, &.{}, &.{});
}

fn ctxRunKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const ctx_inst = try instArg(args);
    const fn_v: Value = if (args.len >= 2) args[1] else return Value.none;
    const fn_args = if (args.len > 2) args[2..] else &[_]Value{};

    // Snapshot current context
    const cur_store = try getContextStore(interp);
    const saved = try cloneCtxStore(a, cur_store.data, cur_store.cvs);

    // Install context's data as the active context
    const data_v = ctx_inst.dict.getStr("_data") orelse Value{ .dict = try Dict.init(a) };
    const cvs_v = ctx_inst.dict.getStr("_cvs") orelse Value{ .list = try List.init(a) };
    const ctx_data: *Dict = if (data_v == .dict) data_v.dict else try Dict.init(a);
    const ctx_cvs: *List = if (cvs_v == .list) cvs_v.list else try List.init(a);
    const snap = try cloneCtxStore(a, ctx_data, ctx_cvs);
    interp.cv_context_data = snap.data;
    interp.cv_context_cvs = snap.cvs;

    const result = dispatch.invokeKw(interp, fn_v, fn_args, kn, kv) catch |e| {
        interp.cv_context_data = saved.data;
        interp.cv_context_cvs = saved.cvs;
        return e;
    };

    interp.cv_context_data = saved.data;
    interp.cv_context_cvs = saved.cvs;
    return result;
}

// ===== Context mapping =====

fn ctxContains(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2) return Value{ .boolean = false };
    const ctx_inst = try instArg(args);
    const data_v = ctx_inst.dict.getStr("_data") orelse return Value{ .boolean = false };
    if (data_v != .dict) return Value{ .boolean = false };
    if (args[1] != .instance) return Value{ .boolean = false };
    const cv = args[1].instance;
    const key = cvPtrKey(cv);
    for (data_v.dict.pairs.items) |pair| {
        if (pair.key == .small_int and pair.key.small_int == key) return Value{ .boolean = true };
    }
    return Value{ .boolean = false };
}

fn ctxGetItem(_: *anyopaque, args: []const Value) anyerror!Value {
    const ctx_inst = try instArg(args);
    const data_v = ctx_inst.dict.getStr("_data") orelse return Value.none;
    if (data_v != .dict) return Value.none;
    if (args.len < 2 or args[1] != .instance) return Value.none;
    const cv = args[1].instance;
    const key = cvPtrKey(cv);
    for (data_v.dict.pairs.items) |pair| {
        if (pair.key == .small_int and pair.key.small_int == key) return pair.value;
    }
    return Value.none;
}

fn ctxGetMethod(p: *anyopaque, args: []const Value) anyerror!Value {
    return ctxGetMethodKw(p, args, &.{}, &.{});
}

fn ctxGetMethodKw(_: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const ctx_inst = try instArg(args);
    const default_v: Value = if (args.len >= 3) args[2] else Value.none;
    const data_v = ctx_inst.dict.getStr("_data") orelse return default_v;
    if (data_v != .dict) return default_v;
    if (args.len < 2 or args[1] != .instance) return default_v;
    const cv = args[1].instance;
    const key = cvPtrKey(cv);
    for (data_v.dict.pairs.items) |pair| {
        if (pair.key == .small_int and pair.key.small_int == key) return pair.value;
    }
    return default_v;
}

fn ctxLen(_: *anyopaque, args: []const Value) anyerror!Value {
    const ctx_inst = try instArg(args);
    const cvs_v = ctx_inst.dict.getStr("_cvs") orelse return Value{ .small_int = 0 };
    if (cvs_v != .list) return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(cvs_v.list.items.items.len) };
}

fn ctxKeys(_: *anyopaque, args: []const Value) anyerror!Value {
    const ctx_inst = try instArg(args);
    const cvs_v = ctx_inst.dict.getStr("_cvs") orelse return Value.none;
    return cvs_v;
}

fn ctxValues(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const ctx_inst = try instArg(args);
    const data_v = ctx_inst.dict.getStr("_data") orelse return Value{ .list = try List.init(a) };
    if (data_v != .dict) return Value{ .list = try List.init(a) };
    const lst = try List.init(a);
    for (data_v.dict.pairs.items) |pair| try lst.items.append(a, pair.value);
    return Value{ .list = lst };
}

fn ctxItems(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const ctx_inst = try instArg(args);
    const cvs_v = ctx_inst.dict.getStr("_cvs") orelse return Value{ .list = try List.init(a) };
    const data_v = ctx_inst.dict.getStr("_data") orelse return Value{ .list = try List.init(a) };
    if (cvs_v != .list or data_v != .dict) return Value{ .list = try List.init(a) };
    const lst = try List.init(a);
    for (cvs_v.list.items.items) |cv_val| {
        if (cv_val != .instance) continue;
        const cv = cv_val.instance;
        const key = cvPtrKey(cv);
        for (data_v.dict.pairs.items) |pair| {
            if (pair.key == .small_int and pair.key.small_int == key) {
                const tup = try Tuple.init(a, 2);
                tup.items[0] = cv_val;
                tup.items[1] = pair.value;
                try lst.items.append(a, Value{ .tuple = tup });
                break;
            }
        }
    }
    return Value{ .list = lst };
}

fn ctxIter(p: *anyopaque, args: []const Value) anyerror!Value {
    return ctxKeys(p, args);
}

fn ctxCopy(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const ctx_inst = try instArg(args);
    const data_v = ctx_inst.dict.getStr("_data") orelse return Value{ .instance = ctx_inst };
    const cvs_v = ctx_inst.dict.getStr("_cvs") orelse return Value{ .instance = ctx_inst };
    if (data_v != .dict or cvs_v != .list) return Value{ .instance = ctx_inst };
    const snap = try cloneCtxStore(a, data_v.dict, cvs_v.list);
    const new_ctx = try Instance.init(a, interp.cv_context_class.?);
    try new_ctx.dict.setStr(a, "_data", Value{ .dict = snap.data });
    try new_ctx.dict.setStr(a, "_cvs", Value{ .list = snap.cvs });
    return Value{ .instance = new_ctx };
}

pub fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;

    // MISSING sentinel
    if (interp.cv_missing == null) {
        const d = try Dict.init(a);
        const missing_class = try Class.init(a, "_MISSING", &.{}, d);
        const missing_inst = try Instance.init(a, missing_class);
        interp.cv_missing = Value{ .instance = missing_inst };
    }

    if (interp.cv_token_class == null) {
        const d = try Dict.init(a);
        try regD(a, d, "__enter__", tokEnter);
        try regD(a, d, "__exit__", tokExit);
        interp.cv_token_class = try Class.init(a, "Token", &.{}, d);
        try interp.cv_token_class.?.dict.setStr(a, "MISSING", interp.cv_missing.?);
    }

    if (interp.cv_context_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "run", ctxRun, ctxRunKw);
        try regD(a, d, "__contains__", ctxContains);
        try regD(a, d, "__getitem__", ctxGetItem);
        try regKwD(a, d, "get", ctxGetMethod, ctxGetMethodKw);
        try regD(a, d, "__len__", ctxLen);
        try regD(a, d, "keys", ctxKeys);
        try regD(a, d, "values", ctxValues);
        try regD(a, d, "items", ctxItems);
        try regD(a, d, "__iter__", ctxIter);
        try regD(a, d, "copy", ctxCopy);
        interp.cv_context_class = try Class.init(a, "Context", &.{}, d);
    }

    if (interp.cv_var_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "__init__", cvCtor, cvCtorKw);
        try regKwD(a, d, "get", cvGet, cvGetKw);
        try regD(a, d, "set", cvSet);
        try regD(a, d, "reset", cvReset);
        interp.cv_var_class = try Class.init(a, "ContextVar", &.{}, d);
    }
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);

    const m = try Module.init(a, "contextvars");
    try m.attrs.setStr(a, "ContextVar", Value{ .class = interp.cv_var_class.? });
    try m.attrs.setStr(a, "Token", Value{ .class = interp.cv_token_class.? });
    try m.attrs.setStr(a, "Context", Value{ .class = interp.cv_context_class.? });
    try regM(a, m, "copy_context", copyContextFn);

    return m;
}
