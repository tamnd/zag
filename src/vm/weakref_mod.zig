//! Pinhole `weakref` module. We don't run a GC, so weak references
//! are simulated as strong references that just expose the weakref
//! API surface (`r() is obj`, callbacks, isinstance checks).
//!
//! The module exposes:
//!  * `ref` / `ReferenceType` -- a class. Calling a ref returns the
//!    target. No-callback refs to the same target are deduped via
//!    `cachedRefInstantiate` (the same identity-equality CPython
//!    guarantees).
//!  * `proxy` -- a function returning a ProxyType or
//!    CallableProxyType instance that delegates attribute access via
//!    `__getattr__`.
//!  * `WeakValueDictionary`, `WeakKeyDictionary`, `WeakSet` --
//!    classes backed by an internal Dict / List, each with the dunder
//!    surface their fixture lines exercise.
//!  * `finalize`, `WeakMethod` -- thin wrappers exposing the right
//!    `alive` / `__call__` semantics.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Iter = @import("../object/iter.zig").Iter;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);

    const m = try Module.init(a, "weakref");
    try m.attrs.setStr(a, "ref", Value{ .class = interp.weakref_ref_class.? });
    try m.attrs.setStr(a, "ReferenceType", Value{ .class = interp.weakref_ref_class.? });
    try m.attrs.setStr(a, "ProxyType", Value{ .class = interp.weakref_proxy_class.? });
    try m.attrs.setStr(a, "CallableProxyType", Value{ .class = interp.weakref_callable_proxy_class.? });
    try m.attrs.setStr(a, "WeakValueDictionary", Value{ .class = interp.weakref_wvd_class.? });
    try m.attrs.setStr(a, "WeakKeyDictionary", Value{ .class = interp.weakref_wkd_class.? });
    try m.attrs.setStr(a, "WeakSet", Value{ .class = interp.weakref_ws_class.? });
    try m.attrs.setStr(a, "finalize", Value{ .class = interp.weakref_finalize_class.? });
    try m.attrs.setStr(a, "WeakMethod", Value{ .class = interp.weakref_weakmethod_class.? });

    // ProxyTypes -- 2-tuple of (ProxyType, CallableProxyType).
    const pt = try Tuple.init(a, 2);
    pt.items[0] = Value{ .class = interp.weakref_proxy_class.? };
    pt.items[1] = Value{ .class = interp.weakref_callable_proxy_class.? };
    try m.attrs.setStr(a, "ProxyTypes", Value{ .tuple = pt });

    try regModFn(interp, m, "proxy", proxyFn);
    try regModFn(interp, m, "getweakrefcount", getweakrefcountFn);
    try regModFn(interp, m, "getweakrefs", getweakrefsFn);
    return m;
}

fn ensureClasses(interp: *Interp) !void {
    if (interp.weakref_ref_class != null) return;
    const a = interp.allocator;

    {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", refInitKw);
        try reg(a, d, "__call__", refCallFn);
        const c = try Class.init(a, "ReferenceType", &.{}, d);
        c.qualname = "weakref.ReferenceType";
        interp.weakref_ref_class = c;
    }
    {
        const d = try Dict.init(a);
        try reg(a, d, "__getattr__", proxyGetattrFn);
        const c = try Class.init(a, "ProxyType", &.{}, d);
        c.qualname = "weakref.ProxyType";
        interp.weakref_proxy_class = c;
    }
    {
        const d = try Dict.init(a);
        try reg(a, d, "__getattr__", proxyGetattrFn);
        try reg(a, d, "__call__", callableProxyCallFn);
        const c = try Class.init(a, "CallableProxyType", &.{}, d);
        c.qualname = "weakref.CallableProxyType";
        interp.weakref_callable_proxy_class = c;
    }
    {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", finalizeInitKw);
        try reg(a, d, "__call__", finalizeCallFn);
        const c = try Class.init(a, "finalize", &.{}, d);
        c.qualname = "weakref.finalize";
        interp.weakref_finalize_class = c;
    }
    {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", weakmethodInitFn);
        try reg(a, d, "__call__", weakmethodCallFn);
        const c = try Class.init(a, "WeakMethod", &.{}, d);
        c.qualname = "weakref.WeakMethod";
        interp.weakref_weakmethod_class = c;
    }
    {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", wvdInitKw);
        try reg(a, d, "__len__", wvdLenFn);
        try reg(a, d, "__contains__", wvdContainsFn);
        try reg(a, d, "__iter__", wvdIterFn);
        try reg(a, d, "__getitem__", wvdGetitemFn);
        try reg(a, d, "__setitem__", wvdSetitemFn);
        try reg(a, d, "__delitem__", wvdDelitemFn);
        try reg(a, d, "get", wvdGetFn);
        try reg(a, d, "pop", wvdPopFn);
        try reg(a, d, "setdefault", wvdSetdefaultFn);
        try reg(a, d, "update", wvdUpdateFn);
        try reg(a, d, "clear", wvdClearFn);
        try reg(a, d, "keys", wvdKeysFn);
        try reg(a, d, "values", wvdValuesFn);
        try reg(a, d, "items", wvdItemsFn);
        const c = try Class.init(a, "WeakValueDictionary", &.{}, d);
        c.qualname = "weakref.WeakValueDictionary";
        interp.weakref_wvd_class = c;
    }
    {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", wkdInitKw);
        try reg(a, d, "__len__", wvdLenFn);
        try reg(a, d, "__contains__", wkdContainsFn);
        try reg(a, d, "__iter__", wvdIterFn);
        try reg(a, d, "__getitem__", wkdGetitemFn);
        try reg(a, d, "__setitem__", wkdSetitemFn);
        try reg(a, d, "__delitem__", wkdDelitemFn);
        try reg(a, d, "get", wkdGetFn);
        try reg(a, d, "pop", wkdPopFn);
        try reg(a, d, "setdefault", wkdSetdefaultFn);
        try reg(a, d, "update", wkdUpdateFn);
        try reg(a, d, "clear", wvdClearFn);
        try reg(a, d, "keys", wvdKeysFn);
        try reg(a, d, "values", wvdValuesFn);
        try reg(a, d, "items", wvdItemsFn);
        const c = try Class.init(a, "WeakKeyDictionary", &.{}, d);
        c.qualname = "weakref.WeakKeyDictionary";
        interp.weakref_wkd_class = c;
    }
    {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", wsInitFn);
        try reg(a, d, "__len__", wsLenFn);
        try reg(a, d, "__contains__", wsContainsFn);
        try reg(a, d, "__iter__", wsIterFn);
        try reg(a, d, "add", wsAddFn);
        try reg(a, d, "discard", wsDiscardFn);
        try reg(a, d, "remove", wsRemoveFn);
        try reg(a, d, "pop", wsPopFn);
        try reg(a, d, "clear", wsClearFn);
        const c = try Class.init(a, "WeakSet", &.{}, d);
        c.qualname = "weakref.WeakSet";
        interp.weakref_ws_class = c;
    }
}

fn reg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(a: std.mem.Allocator, d: *Dict, name: []const u8, comptime kw_func: BuiltinKwFnPtr) !void {
    const Wrap = struct {
        fn call(p: *anyopaque, args: []const Value) anyerror!Value {
            return kw_func(p, args, &.{}, &.{});
        }
    };
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = Wrap.call, .kw_func = kw_func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regModFn(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

// ===== weakref-able types =====

fn isWeakreffable(v: Value) bool {
    return v == .instance;
}

fn ensureWeakreffable(interp: *Interp, v: Value) !void {
    if (!isWeakreffable(v)) {
        try interp.raisePy("TypeError", "cannot create weak reference");
        return error.PyException;
    }
}

// ===== ref =====

fn refInitKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    _ = kw_names;
    _ = kw_values;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) {
        try interp.typeError("ref() missing target");
        return error.TypeError;
    }
    const self = args[0].instance;
    const target = args[1];
    try ensureWeakreffable(interp, target);
    const callback: Value = if (args.len >= 3) args[2] else Value.none;

    try self.dict.setStr(a, "_obj", target);
    try self.dict.setStr(a, "__callback__", callback);
    try registerRef(interp, target.instance, self);
    return Value.none;
}

fn refCallFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len != 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    return self.dict.getStr("_obj") orelse Value.none;
}

fn registerRef(interp: *Interp, target: *Instance, ref_inst: *Instance) !void {
    const a = interp.allocator;
    const gop = try interp.weakref_registry.getOrPut(a, target);
    if (!gop.found_existing) {
        gop.value_ptr.* = .empty;
    }
    try gop.value_ptr.append(a, ref_inst);
}

/// Called from `instantiate` before allocating a fresh ref. Returns
/// the canonical no-callback ref for `target` if one already exists.
pub fn cachedRefInstantiate(interp: *Interp, positional: []const Value) !?Value {
    if (positional.len != 1) return null; // only no-callback dedup
    if (positional[0] != .instance) return null;
    const target = positional[0].instance;
    const existing = interp.weakref_registry.get(target) orelse return null;
    for (existing.items) |r| {
        const cb = r.dict.getStr("__callback__") orelse continue;
        if (cb == .none) return Value{ .instance = r };
    }
    return null;
}

// ===== proxy =====

fn isCallable(v: Value) bool {
    return switch (v) {
        .function, .builtin_fn, .bound_method, .class, .partial, .cached_fn => true,
        .instance => |inst| inst.cls.lookup("__call__") != null,
        else => false,
    };
}

fn proxyFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.typeError("proxy() requires target");
        return error.TypeError;
    }
    const target = args[0];
    try ensureWeakreffable(interp, target);
    const callback: Value = if (args.len >= 2) args[1] else Value.none;

    const cls = if (isCallable(target))
        interp.weakref_callable_proxy_class.?
    else
        interp.weakref_proxy_class.?;
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "_obj", target);
    try inst.dict.setStr(a, "__callback__", callback);
    return Value{ .instance = inst };
}

fn proxyGetattrFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const self = args[0].instance;
    const name = args[1].str.bytes;
    const target = self.dict.getStr("_obj") orelse return error.TypeError;
    return try dispatch.loadAttrValue(interp, target, name);
}

fn callableProxyCallFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const target = self.dict.getStr("_obj") orelse return error.TypeError;
    return try dispatch.invoke(interp, target, args[1..]);
}

// ===== getweakrefcount / getweakrefs =====

fn getweakrefcountFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1) return error.TypeError;
    if (args[0] != .instance) return Value{ .small_int = 0 };
    const list = interp.weakref_registry.get(args[0].instance) orelse {
        return Value{ .small_int = 0 };
    };
    return Value{ .small_int = @intCast(list.items.len) };
}

fn getweakrefsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len != 1) return error.TypeError;
    const out = try List.init(a);
    if (args[0] != .instance) return Value{ .list = out };
    if (interp.weakref_registry.get(args[0].instance)) |list| {
        for (list.items) |r| try out.append(a, Value{ .instance = r });
    }
    return Value{ .list = out };
}

// ===== WeakValueDictionary =====
//
// Backed by an instance attr "_d" that holds a regular Dict. We use
// it directly: the fixture's tests don't exercise strict weak-value
// semantics, so the strong-ref dict is byte-equivalent.

fn instSelf(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

fn dictOf(self: *Instance) !*Dict {
    const v = self.dict.getStr("_d") orelse return error.TypeError;
    if (v != .dict) return error.TypeError;
    return v.dict;
}

fn wvdInitKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    _ = kw_names;
    _ = kw_values;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instSelf(args);
    const d = try Dict.init(a);
    try self.dict.setStr(a, "_d", Value{ .dict = d });
    if (args.len >= 2 and args[1] == .dict) {
        for (args[1].dict.pairs.items) |pair| {
            try d.setKey(a, pair.key, pair.value);
        }
    }
    return Value.none;
}

fn wvdLenFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const self = try instSelf(args);
    const d = try dictOf(self);
    return Value{ .small_int = @intCast(d.count()) };
}

fn wvdContainsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len != 2) return error.TypeError;
    const self = try instSelf(args);
    const d = try dictOf(self);
    return Value{ .boolean = d.findKeyWrap(args[1]) };
}

fn wvdIterFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instSelf(args);
    const d = try dictOf(self);
    const list = try List.init(a);
    for (d.pairs.items) |pair| try list.append(a, pair.key);
    return Value{ .iter = try Iter.init(a, .{ .list = list }) };
}

fn wvdGetitemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2) return error.TypeError;
    const self = try instSelf(args);
    const d = try dictOf(self);
    if (d.getKey(args[1])) |v| return v;
    try interp.raisePy("KeyError", "missing key");
    return error.PyException;
}

fn wvdSetitemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len != 3) return error.TypeError;
    const self = try instSelf(args);
    const d = try dictOf(self);
    try d.setKey(a, args[1], args[2]);
    return Value.none;
}

fn wvdDelitemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2) return error.TypeError;
    const self = try instSelf(args);
    const d = try dictOf(self);
    if (!d.removeKeyWrap(args[1])) {
        try interp.raisePy("KeyError", "missing key");
        return error.PyException;
    }
    return Value.none;
}

fn wvdGetFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args.len > 3) return error.TypeError;
    const self = try instSelf(args);
    const d = try dictOf(self);
    if (d.getKey(args[1])) |v| return v;
    return if (args.len == 3) args[2] else Value.none;
}

fn wvdPopFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args.len > 3) return error.TypeError;
    const self = try instSelf(args);
    const d = try dictOf(self);
    if (d.getKey(args[1])) |v| {
        _ = d.removeKeyWrap(args[1]);
        return v;
    }
    if (args.len == 3) return args[2];
    try interp.raisePy("KeyError", "missing key");
    return error.PyException;
}

fn wvdSetdefaultFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const self = try instSelf(args);
    const d = try dictOf(self);
    if (d.getKey(args[1])) |v| return v;
    const v: Value = if (args.len >= 3) args[2] else Value.none;
    try d.setKey(a, args[1], v);
    return v;
}

fn wvdUpdateFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len != 2) return error.TypeError;
    const self = try instSelf(args);
    const d = try dictOf(self);
    const src = args[1];
    if (src == .dict) {
        for (src.dict.pairs.items) |pair| try d.setKey(a, pair.key, pair.value);
    } else {
        try interp.typeError("update expects a mapping");
        return error.TypeError;
    }
    return Value.none;
}

fn wvdClearFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const self = try instSelf(args);
    const d = try dictOf(self);
    d.pairs.clearRetainingCapacity();
    d.keys.clearRetainingCapacity();
    return Value.none;
}

fn wvdKeysFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instSelf(args);
    const d = try dictOf(self);
    const out = try List.init(a);
    for (d.pairs.items) |pair| try out.append(a, pair.key);
    return Value{ .list = out };
}

fn wvdValuesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instSelf(args);
    const d = try dictOf(self);
    const out = try List.init(a);
    for (d.pairs.items) |pair| try out.append(a, pair.value);
    return Value{ .list = out };
}

fn wvdItemsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instSelf(args);
    const d = try dictOf(self);
    const out = try List.init(a);
    for (d.pairs.items) |pair| {
        const t = try Tuple.init(a, 2);
        t.items[0] = pair.key;
        t.items[1] = pair.value;
        try out.append(a, Value{ .tuple = t });
    }
    return Value{ .list = out };
}

// ===== WeakKeyDictionary =====

fn wkdInitKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return wvdInitKw(p, args, kw_names, kw_values);
}

fn wkdContainsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return wvdContainsFn(p, args);
}

fn wkdGetitemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return wvdGetitemFn(p, args);
}

fn wkdSetitemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return wvdSetitemFn(p, args);
}

fn wkdDelitemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return wvdDelitemFn(p, args);
}

fn wkdGetFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return wvdGetFn(p, args);
}

fn wkdPopFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return wvdPopFn(p, args);
}

fn wkdSetdefaultFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return wvdSetdefaultFn(p, args);
}

fn wkdUpdateFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return wvdUpdateFn(p, args);
}

// ===== WeakSet =====

fn listOf(self: *Instance) !*List {
    const v = self.dict.getStr("_items") orelse return error.TypeError;
    if (v != .list) return error.TypeError;
    return v.list;
}

fn wsInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instSelf(args);
    const l = try List.init(a);
    try self.dict.setStr(a, "_items", Value{ .list = l });
    if (args.len >= 2) {
        switch (args[1]) {
            .list => |sl| for (sl.items.items) |it| try wsAddInternal(a, l, it),
            .tuple => |t| for (t.items) |it| try wsAddInternal(a, l, it),
            .set => |s| for (s.items.items) |it| try wsAddInternal(a, l, it),
            else => {},
        }
    }
    return Value.none;
}

fn wsAddInternal(a: std.mem.Allocator, l: *List, v: Value) !void {
    for (l.items.items) |x| if (Value.equals(x, v)) return;
    try l.append(a, v);
}

fn wsLenFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const self = try instSelf(args);
    const l = try listOf(self);
    return Value{ .small_int = @intCast(l.items.items.len) };
}

fn wsContainsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len != 2) return error.TypeError;
    const self = try instSelf(args);
    const l = try listOf(self);
    for (l.items.items) |x| if (Value.equals(x, args[1])) return Value{ .boolean = true };
    return Value{ .boolean = false };
}

fn wsIterFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instSelf(args);
    const l = try listOf(self);
    return Value{ .iter = try Iter.init(a, .{ .list = l }) };
}

fn wsAddFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2) return error.TypeError;
    const self = try instSelf(args);
    const l = try listOf(self);
    try wsAddInternal(interp.allocator, l, args[1]);
    return Value.none;
}

fn wsDiscardFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len != 2) return error.TypeError;
    const self = try instSelf(args);
    const l = try listOf(self);
    var i: usize = 0;
    while (i < l.items.items.len) : (i += 1) {
        if (Value.equals(l.items.items[i], args[1])) {
            _ = l.items.orderedRemove(i);
            return Value.none;
        }
    }
    return Value.none;
}

fn wsRemoveFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2) return error.TypeError;
    const self = try instSelf(args);
    const l = try listOf(self);
    var i: usize = 0;
    while (i < l.items.items.len) : (i += 1) {
        if (Value.equals(l.items.items[i], args[1])) {
            _ = l.items.orderedRemove(i);
            return Value.none;
        }
    }
    try interp.raisePy("KeyError", "not in set");
    return error.PyException;
}

fn wsPopFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const self = try instSelf(args);
    const l = try listOf(self);
    if (l.items.items.len == 0) {
        try interp.raisePy("KeyError", "pop from empty set");
        return error.PyException;
    }
    return l.items.pop().?;
}

fn wsClearFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const self = try instSelf(args);
    const l = try listOf(self);
    l.items.clearRetainingCapacity();
    return Value.none;
}

// ===== finalize =====

fn finalizeInitKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    _ = kw_names;
    _ = kw_values;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3) {
        try interp.typeError("finalize requires (self, target, callback, *args)");
        return error.TypeError;
    }
    const self = args[0].instance;
    try self.dict.setStr(a, "_target", args[1]);
    try self.dict.setStr(a, "_func", args[2]);
    const t = try Tuple.init(a, args.len - 3);
    @memcpy(t.items, args[3..]);
    try self.dict.setStr(a, "_args", Value{ .tuple = t });
    try self.dict.setStr(a, "alive", Value{ .boolean = true });
    try self.dict.setStr(a, "atexit", Value{ .boolean = true });
    return Value.none;
}

fn finalizeCallFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const alive_v = self.dict.getStr("alive") orelse Value{ .boolean = false };
    if (!alive_v.isTruthy()) return Value.none;
    const func = self.dict.getStr("_func") orelse return Value.none;
    const args_t = self.dict.getStr("_args") orelse Value{ .tuple = try Tuple.init(a, 0) };
    const argv: []const Value = if (args_t == .tuple) args_t.tuple.items else &.{};
    const r = try dispatch.invoke(interp, func, argv);
    try self.dict.setStr(a, "alive", Value{ .boolean = false });
    return r;
}

// ===== WeakMethod =====

fn weakmethodInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) {
        try interp.typeError("WeakMethod requires a bound method");
        return error.TypeError;
    }
    const self = args[0].instance;
    try self.dict.setStr(a, "_method", args[1]);
    return Value.none;
}

fn weakmethodCallFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    return self.dict.getStr("_method") orelse Value.none;
}
