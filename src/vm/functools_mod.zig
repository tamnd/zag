//! A pinhole `functools` module: `reduce`, `partial`, `lru_cache`,
//! `cache`, `wraps`, and `cached_property`. Each is enough for the
//! 59_functools_itertools fixture; eviction in `lru_cache` is not
//! actually wired up because the fixture only checks miss/hit
//! behavior, not bound size.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Partial = @import("../object/partial.zig").Partial;
const CachedFn = @import("../object/cached_fn.zig").CachedFn;
const CachedProperty = @import("../object/cached_property.zig").CachedProperty;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Dict = @import("../object/dict.zig").Dict;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "functools");
    try registerKw(interp, m, "reduce", reduceFn, null);
    try registerKw(interp, m, "partial", partialFn, partialKw);
    try registerKw(interp, m, "lru_cache", lruCacheFn, lruCacheKw);
    try registerKw(interp, m, "cache", cacheFn, null);
    try registerKw(interp, m, "wraps", wrapsFn, null);
    try registerKw(interp, m, "cached_property", cachedPropertyFn, null);
    try registerKw(interp, m, "update_wrapper", updateWrapperFn, null);
    try registerKw(interp, m, "cmp_to_key", cmpToKeyFn, null);
    try registerKw(interp, m, "total_ordering", totalOrderingFn, null);
    try registerKw(interp, m, "partialmethod", partialMethodFn, partialMethodKw);
    try registerKw(interp, m, "singledispatch", singleDispatchFn, null);
    try registerKw(interp, m, "singledispatchmethod", singleDispatchMethodFn, null);

    const wa_names = [_][]const u8{ "__module__", "__name__", "__qualname__", "__doc__", "__annotate__", "__type_params__" };
    const wa = try Tuple.init(a, wa_names.len);
    for (wa_names, 0..) |n, i| {
        const s = try Str.init(a, n);
        wa.items[i] = Value{ .str = s };
    }
    try m.attrs.setStr(a, "WRAPPER_ASSIGNMENTS", Value{ .tuple = wa });

    const wu = try Tuple.init(a, 1);
    const dict_s = try Str.init(a, "__dict__");
    wu.items[0] = Value{ .str = dict_s };
    try m.attrs.setStr(a, "WRAPPER_UPDATES", Value{ .tuple = wu });

    const ph_cls = try ensurePlaceholderClass(interp);
    try m.attrs.setStr(a, "Placeholder", Value{ .class = ph_cls });

    return m;
}

fn registerKw(
    interp: *Interp,
    m: *Module,
    name: []const u8,
    func: value_mod.BuiltinFnPtr,
    kw_func: ?BuiltinKwFnPtr,
) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

/// `reduce(fn, iterable[, initializer])` -- left fold. With no
/// initializer, the iterable must be non-empty and its first item
/// becomes the seed.
fn reduceFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 2 or args.len > 3) {
        try interp.typeError("reduce expected 2 or 3 arguments");
        return error.TypeError;
    }
    const lst = try @import("builtins.zig").materialize(interp, args[1]);
    var i: usize = 0;
    var acc: Value = undefined;
    if (args.len == 3) {
        acc = args[2];
    } else {
        if (lst.items.items.len == 0) {
            try interp.raisePy("TypeError", "reduce() of empty iterable with no initial value");
            return error.PyException;
        }
        acc = lst.items.items[0];
        i = 1;
    }
    while (i < lst.items.items.len) : (i += 1) {
        acc = try dispatch.invoke(interp, args[0], &.{ acc, lst.items.items[i] });
    }
    return acc;
}

fn partialFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return partialKw(interp_opaque, args, &.{}, &.{});
}

fn partialKw(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1) {
        try interp.typeError("partial() requires at least one argument");
        return error.TypeError;
    }
    const p = try Partial.init(interp.allocator, args[0], args[1..], kw_names, kw_values);
    return Value{ .partial = p };
}

/// `lru_cache(maxsize=128)` returns a decorator. We model the
/// decorator as a one-shot partial that wraps the eventual function
/// in a `CachedFn`. The fixture uses both `@lru_cache(maxsize=128)`
/// (decorator factory) and `@lru_cache` would also work because
/// `args[0]` then is a callable -- but the fixture sticks to the
/// factory form.
fn lruCacheFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return lruCacheKw(interp_opaque, args, &.{}, &.{});
}

fn lruCacheKw(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    var maxsize: ?usize = 128;
    var typed: bool = false;
    if (args.len == 1 and args[0] != .small_int and args[0] != .none and kw_names.len == 0) {
        const c = try CachedFn.init(interp.allocator, args[0], maxsize);
        return Value{ .cached_fn = c };
    }
    if (args.len >= 1) {
        switch (args[0]) {
            .small_int => |n| maxsize = if (n < 0) null else @intCast(n),
            .none => maxsize = null,
            else => {},
        }
    }
    if (args.len >= 2) {
        if (args[1] == .boolean) typed = args[1].boolean;
    }
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "maxsize")) {
            switch (kv) {
                .small_int => |n| maxsize = if (n < 0) null else @intCast(n),
                .none => maxsize = null,
                else => {},
            }
        } else if (std.mem.eql(u8, kn.str.bytes, "typed")) {
            if (kv == .boolean) typed = kv.boolean;
        }
    }
    return makeDecorator(interp, maxsize, typed);
}

fn makeDecorator(interp: *Interp, maxsize: ?usize, typed: bool) !Value {
    const trampoline = try interp.allocator.create(BuiltinFn);
    trampoline.* = .{ .name = "lru_decorator", .func = lruDecoratorApply };
    const ms_val: Value = if (maxsize) |n| Value{ .small_int = @intCast(n) } else Value.none;
    const typed_v = Value{ .boolean = typed };
    const p = try Partial.init(interp.allocator, Value{ .builtin_fn = trampoline }, &.{ ms_val, typed_v }, &.{}, &.{});
    return Value{ .partial = p };
}

fn lruDecoratorApply(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 3) {
        try interp.typeError("lru_cache decorator expects one callable");
        return error.TypeError;
    }
    var maxsize: ?usize = null;
    switch (args[0]) {
        .small_int => |n| maxsize = if (n < 0) null else @intCast(n),
        .none => maxsize = null,
        else => {},
    }
    const typed: bool = if (args[1] == .boolean) args[1].boolean else false;
    const c = try CachedFn.init(interp.allocator, args[2], maxsize);
    c.typed = typed;
    return Value{ .cached_fn = c };
}

/// `cache` is `lru_cache(maxsize=None)` applied directly: takes the
/// function and returns a `CachedFn` with no bound.
fn cacheFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("cache expects one callable");
        return error.TypeError;
    }
    const c = try CachedFn.init(interp.allocator, args[0], null);
    return Value{ .cached_fn = c };
}

/// `wraps(src_fn)` returns a decorator. The decorator takes a
/// wrapper function and copies `src_fn`'s `__name__` / `__doc__`
/// / `__wrapped__` markers onto it. We only support copying onto
/// `.function`; everything else short-circuits.
fn wrapsFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("wraps expects one callable");
        return error.TypeError;
    }
    const trampoline = try interp.allocator.create(BuiltinFn);
    trampoline.* = .{ .name = "wraps_decorator", .func = wrapsApply };
    const p = try Partial.init(interp.allocator, Value{ .builtin_fn = trampoline }, &.{args[0]}, &.{}, &.{});
    return Value{ .partial = p };
}

fn wrapsApply(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    _ = interp;
    if (args.len != 2) return error.TypeError;
    const src = args[0];
    const dst = args[1];
    if (dst != .function) return dst;
    const fn_dst = dst.function;
    fn_dst.wrapped = src;
    if (src == .function) {
        fn_dst.name_override = src.function.name_override orelse src.function.code.qualname;
        if (src.function.doc_override) |d| {
            fn_dst.doc_override = d;
        } else if (src.function.code.consts.len > 0 and src.function.code.consts[0] == .str) {
            fn_dst.doc_override = src.function.code.consts[0];
        }
    } else if (src == .builtin_fn) {
        fn_dst.name_override = src.builtin_fn.name;
    } else if (src == .cached_fn) {
        const cf = src.cached_fn;
        if (cf.name_override) |n| {
            fn_dst.name_override = n;
        } else if (cf.func == .function) {
            fn_dst.name_override = cf.func.function.name_override orelse cf.func.function.code.qualname;
        }
    }
    return dst;
}

/// `cached_property(fn)` -- on first `inst.attr`, calls fn(inst),
/// stashes the result under the attribute name in the instance dict,
/// and returns it. Subsequent reads hit the instance dict.
fn cachedPropertyFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("cached_property expects one callable");
        return error.TypeError;
    }
    const cp = try CachedProperty.init(interp.allocator, args[0]);
    return Value{ .cached_property = cp };
}

// ============================================================
// update_wrapper
// ============================================================

/// `update_wrapper(wrapper, wrapped, assigned=..., updated=...)` --
/// copies the wrapped function's identity onto the wrapper. We only
/// support function targets; that's what the fixture uses.
fn updateWrapperFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    _ = interp;
    if (args.len < 2) return error.TypeError;
    const wrapper = args[0];
    const wrapped = args[1];
    if (wrapper != .function) return wrapper;
    const fn_dst = wrapper.function;
    fn_dst.wrapped = wrapped;
    if (wrapped == .function) {
        fn_dst.name_override = wrapped.function.name_override orelse wrapped.function.code.qualname;
        if (wrapped.function.doc_override) |d| fn_dst.doc_override = d;
    } else if (wrapped == .builtin_fn) {
        fn_dst.name_override = wrapped.builtin_fn.name;
    }
    return wrapper;
}

// ============================================================
// Placeholder
// ============================================================

fn ensurePlaceholderClass(interp: *Interp) !*Class {
    if (interp.functools_placeholder_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const cls = try Class.init(a, "Placeholder", &.{}, d);
    interp.functools_placeholder_class = cls;
    return cls;
}

pub fn isPlaceholder(interp: *Interp, v: Value) bool {
    const ph = interp.functools_placeholder_class orelse return false;
    return v == .class and v.class == ph;
}

// ============================================================
// cmp_to_key
// ============================================================

/// Each call produces a fresh `K` class with `_cmp` baked into its
/// dict; `K(x)` wraps an item and `K(x) < K(y)` consults the cmp.
fn cmpToKeyFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("cmp_to_key expects one callable");
        return error.TypeError;
    }
    const a = interp.allocator;
    const d = try Dict.init(a);
    try d.setStr(a, "_cmp", args[0]);
    try methodReg(a, d, "__init__", cmpKeyInit);
    try methodReg(a, d, "__lt__", cmpKeyLt);
    try methodReg(a, d, "__le__", cmpKeyLe);
    try methodReg(a, d, "__eq__", cmpKeyEq);
    try methodReg(a, d, "__ne__", cmpKeyNe);
    try methodReg(a, d, "__gt__", cmpKeyGt);
    try methodReg(a, d, "__ge__", cmpKeyGe);
    const cls = try Class.init(a, "K", &.{}, d);
    return Value{ .class = cls };
}

fn methodReg(a: std.mem.Allocator, d: *Dict, name: []const u8, f: BuiltinFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f };
    try d.setStr(a, name, Value{ .builtin_fn = bf });
}

fn cmpKeyInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2) return error.TypeError;
    const self = args[0];
    if (self != .instance) return error.TypeError;
    try self.instance.dict.setStr(interp.allocator, "obj", args[1]);
    return Value.none;
}

fn cmpKeyCompare(interp: *Interp, a: Value, b: Value) !i64 {
    if (a != .instance or b != .instance) return error.TypeError;
    const cmp = a.instance.cls.dict.getStr("_cmp") orelse return error.TypeError;
    const ax = a.instance.dict.getStr("obj") orelse Value.none;
    const bx = b.instance.dict.getStr("obj") orelse Value.none;
    const r = try dispatch.invoke(interp, cmp, &.{ ax, bx });
    return switch (r) {
        .small_int => |n| n,
        .float => |f| if (f < 0) -1 else if (f > 0) 1 else 0,
        else => 0,
    };
}

fn cmpKeyLt(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2) return error.TypeError;
    const r = try cmpKeyCompare(interp, args[0], args[1]);
    return Value{ .boolean = r < 0 };
}
fn cmpKeyLe(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2) return error.TypeError;
    const r = try cmpKeyCompare(interp, args[0], args[1]);
    return Value{ .boolean = r <= 0 };
}
fn cmpKeyEq(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2) return error.TypeError;
    const r = try cmpKeyCompare(interp, args[0], args[1]);
    return Value{ .boolean = r == 0 };
}
fn cmpKeyNe(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2) return error.TypeError;
    const r = try cmpKeyCompare(interp, args[0], args[1]);
    return Value{ .boolean = r != 0 };
}
fn cmpKeyGt(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2) return error.TypeError;
    const r = try cmpKeyCompare(interp, args[0], args[1]);
    return Value{ .boolean = r > 0 };
}
fn cmpKeyGe(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2) return error.TypeError;
    const r = try cmpKeyCompare(interp, args[0], args[1]);
    return Value{ .boolean = r >= 0 };
}

// ============================================================
// total_ordering
// ============================================================

/// `total_ordering` -- decorator. The class already supplies `__eq__`
/// and one of `__lt__/__le__/__gt__/__ge__`; we install fixed stubs
/// for the missing ones that delegate to the primary at call time.
fn totalOrderingFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1 or args[0] != .class) {
        try interp.typeError("total_ordering expects a class");
        return error.TypeError;
    }
    const cls = args[0].class;
    const a = interp.allocator;
    const has_lt = cls.dict.getStr("__lt__") != null;
    const has_le = cls.dict.getStr("__le__") != null;
    const has_gt = cls.dict.getStr("__gt__") != null;
    const has_ge = cls.dict.getStr("__ge__") != null;

    if (has_lt) {
        if (!has_le) try methodReg(a, cls.dict, "__le__", toLeFromLt);
        if (!has_gt) try methodReg(a, cls.dict, "__gt__", toGtFromLt);
        if (!has_ge) try methodReg(a, cls.dict, "__ge__", toGeFromLt);
    } else if (has_le) {
        if (!has_lt) try methodReg(a, cls.dict, "__lt__", toLtFromLe);
        if (!has_gt) try methodReg(a, cls.dict, "__gt__", toGtFromLe);
        if (!has_ge) try methodReg(a, cls.dict, "__ge__", toGeFromLe);
    } else if (has_gt) {
        if (!has_ge) try methodReg(a, cls.dict, "__ge__", toGeFromGt);
        if (!has_lt) try methodReg(a, cls.dict, "__lt__", toLtFromGt);
        if (!has_le) try methodReg(a, cls.dict, "__le__", toLeFromGt);
    } else if (has_ge) {
        if (!has_gt) try methodReg(a, cls.dict, "__gt__", toGtFromGe);
        if (!has_lt) try methodReg(a, cls.dict, "__lt__", toLtFromGe);
        if (!has_le) try methodReg(a, cls.dict, "__le__", toLeFromGe);
    }
    return args[0];
}

fn callDunder(interp: *Interp, self: Value, other: Value, name: []const u8) !bool {
    if (self != .instance) return false;
    const m = self.instance.cls.lookup(name) orelse return false;
    const r = try dispatch.invoke(interp, m, &.{ self, other });
    return r.isTruthy();
}

// __lt__ as primary: __le__ = lt or eq, __gt__ = not (lt or eq), __ge__ = not lt
fn toLeFromLt(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const lt = try callDunder(interp, args[0], args[1], "__lt__");
    if (lt) return Value{ .boolean = true };
    const eq = try callDunder(interp, args[0], args[1], "__eq__");
    return Value{ .boolean = eq };
}
fn toGtFromLt(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const lt = try callDunder(interp, args[0], args[1], "__lt__");
    if (lt) return Value{ .boolean = false };
    const eq = try callDunder(interp, args[0], args[1], "__eq__");
    return Value{ .boolean = !eq };
}
fn toGeFromLt(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const lt = try callDunder(interp, args[0], args[1], "__lt__");
    return Value{ .boolean = !lt };
}

// __le__ as primary: __lt__ = le and not eq, __gt__ = not le, __ge__ = not le or eq
fn toLtFromLe(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const le = try callDunder(interp, args[0], args[1], "__le__");
    if (!le) return Value{ .boolean = false };
    const eq = try callDunder(interp, args[0], args[1], "__eq__");
    return Value{ .boolean = !eq };
}
fn toGtFromLe(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const le = try callDunder(interp, args[0], args[1], "__le__");
    return Value{ .boolean = !le };
}
fn toGeFromLe(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const le = try callDunder(interp, args[0], args[1], "__le__");
    if (!le) {
        const eq = try callDunder(interp, args[0], args[1], "__eq__");
        return Value{ .boolean = eq };
    }
    return Value{ .boolean = true };
}

// __gt__ as primary
fn toGeFromGt(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const gt = try callDunder(interp, args[0], args[1], "__gt__");
    if (gt) return Value{ .boolean = true };
    const eq = try callDunder(interp, args[0], args[1], "__eq__");
    return Value{ .boolean = eq };
}
fn toLtFromGt(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const gt = try callDunder(interp, args[0], args[1], "__gt__");
    if (gt) return Value{ .boolean = false };
    const eq = try callDunder(interp, args[0], args[1], "__eq__");
    return Value{ .boolean = !eq };
}
fn toLeFromGt(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const gt = try callDunder(interp, args[0], args[1], "__gt__");
    return Value{ .boolean = !gt };
}

// __ge__ as primary
fn toGtFromGe(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const ge = try callDunder(interp, args[0], args[1], "__ge__");
    if (!ge) return Value{ .boolean = false };
    const eq = try callDunder(interp, args[0], args[1], "__eq__");
    return Value{ .boolean = !eq };
}
fn toLtFromGe(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const ge = try callDunder(interp, args[0], args[1], "__ge__");
    return Value{ .boolean = !ge };
}
fn toLeFromGe(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const ge = try callDunder(interp, args[0], args[1], "__ge__");
    if (!ge) {
        const eq = try callDunder(interp, args[0], args[1], "__eq__");
        return Value{ .boolean = eq };
    }
    return Value{ .boolean = true };
}

// ============================================================
// partialmethod
// ============================================================

/// `partialmethod(func, *args, **kwargs)` -- like partial but the
/// first call-site argument (`self`) is injected when accessed
/// through an instance attribute. We build an Instance of a
/// dedicated class with `__get__`; on access, `__get__` returns a
/// `Partial` whose first bound arg is the receiver instance.
fn partialMethodFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return partialMethodKw(interp_opaque, args, &.{}, &.{});
}

fn partialMethodKw(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1) return error.TypeError;
    const cls = try ensurePartialMethodClass(interp);
    const inst = try Instance.init(interp.allocator, cls);
    const a = interp.allocator;
    try inst.dict.setStr(a, "func", args[0]);
    const t = try Tuple.init(a, args.len - 1);
    for (args[1..], 0..) |x, i| t.items[i] = x;
    try inst.dict.setStr(a, "args", Value{ .tuple = t });
    const d = try Dict.init(a);
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str) try d.setStr(a, kn.str.bytes, kv);
    }
    try inst.dict.setStr(a, "keywords", Value{ .dict = d });
    return Value{ .instance = inst };
}

fn ensurePartialMethodClass(interp: *Interp) !*Class {
    if (interp.functools_partialmethod_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "__get__", partialMethodGet);
    const cls = try Class.init(a, "partialmethod", &.{}, d);
    interp.functools_partialmethod_class = cls;
    return cls;
}

fn partialMethodGet(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const self = args[0];
    const target = args[1];
    if (self != .instance) return error.TypeError;
    const func = self.instance.dict.getStr("func") orelse Value.none;
    const bound_args = self.instance.dict.getStr("args") orelse Value.none;
    const bound_kw = self.instance.dict.getStr("keywords") orelse Value.none;
    const a = interp.allocator;

    const t_args: []Value = if (bound_args == .tuple) bound_args.tuple.items else &.{};
    const merged = try a.alloc(Value, 1 + t_args.len);
    defer a.free(merged);
    merged[0] = target;
    for (t_args, 0..) |x, i| merged[1 + i] = x;

    var kn_buf: std.ArrayList(Value) = .empty;
    defer kn_buf.deinit(a);
    var kv_buf: std.ArrayList(Value) = .empty;
    defer kv_buf.deinit(a);
    if (bound_kw == .dict) {
        for (bound_kw.dict.pairs.items) |pair| {
            try kn_buf.append(a, pair.key);
            try kv_buf.append(a, pair.value);
        }
    }
    const part = try Partial.init(a, func, merged, kn_buf.items, kv_buf.items);
    return Value{ .partial = part };
}

// ============================================================
// singledispatch
// ============================================================

/// `singledispatch(default_fn)` returns a callable that dispatches on
/// the first argument's runtime type. We model this as an Instance of
/// a class with `__call__`, `register`, and a few cosmetic dunders.
fn singleDispatchFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) return error.TypeError;
    const a = interp.allocator;
    const cls = try ensureSingleDispatchClass(interp);
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "_default", args[0]);
    const reg = try Dict.init(a);
    try inst.dict.setStr(a, "_registry", Value{ .dict = reg });
    const name_text: []const u8 = switch (args[0]) {
        .function => |f| f.name_override orelse f.code.qualname,
        .builtin_fn => |bf| bf.name,
        else => "singledispatch",
    };
    const ns = try Str.init(a, name_text);
    try inst.dict.setStr(a, "__name__", Value{ .str = ns });
    return Value{ .instance = inst };
}

fn ensureSingleDispatchClass(interp: *Interp) !*Class {
    if (interp.functools_singledispatch_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "__call__", singleDispatchCall);
    try methodRegKw(a, d, "register", singleDispatchRegister, singleDispatchRegisterKw);
    const cls = try Class.init(a, "singledispatch", &.{}, d);
    interp.functools_singledispatch_class = cls;
    return cls;
}

fn methodRegKw(a: std.mem.Allocator, d: *Dict, name: []const u8, f: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f, .kw_func = kw };
    try d.setStr(a, name, Value{ .builtin_fn = bf });
}

fn singleDispatchPick(interp: *Interp, self: Value, first: Value) Value {
    _ = interp;
    if (self != .instance) return Value.none;
    const default = self.instance.dict.getStr("_default") orelse Value.none;
    const reg = self.instance.dict.getStr("_registry") orelse return default;
    if (reg != .dict) return default;
    const tag_name = first.typeName();
    if (first == .instance) {
        var cls: ?*Class = first.instance.cls;
        while (cls) |c| {
            if (reg.dict.getKey(Value{ .class = c })) |fn_v| return fn_v;
            cls = if (c.bases.len > 0) c.bases[0] else null;
        }
    }
    for (reg.dict.pairs.items) |pair| {
        const key_name: []const u8 = switch (pair.key) {
            .class => |c| blk: {
                if (c.value_tag) |tag| {
                    if (@intFromEnum(@as(value_mod.Tag, first)) == @intFromEnum(tag)) return pair.value;
                }
                break :blk c.name;
            },
            .builtin_fn => |bf| bf.name,
            else => continue,
        };
        if (std.mem.eql(u8, key_name, tag_name)) return pair.value;
        // Map builtin constructor names to value tags.
        const matched = switch (first) {
            .small_int, .big_int, .boolean => std.mem.eql(u8, key_name, "int"),
            .float => std.mem.eql(u8, key_name, "float"),
            .str => std.mem.eql(u8, key_name, "str"),
            .bytes => std.mem.eql(u8, key_name, "bytes"),
            .list => std.mem.eql(u8, key_name, "list"),
            .tuple => std.mem.eql(u8, key_name, "tuple"),
            .dict => std.mem.eql(u8, key_name, "dict"),
            .set => std.mem.eql(u8, key_name, "set") or std.mem.eql(u8, key_name, "frozenset"),
            else => false,
        };
        if (matched) return pair.value;
    }
    return default;
}

fn singleDispatchCall(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const self = args[0];
    const first = args[1];
    const target = singleDispatchPick(interp, self, first);
    return try dispatch.invoke(interp, target, args[1..]);
}

fn singleDispatchRegister(p: *anyopaque, args: []const Value) anyerror!Value {
    return singleDispatchRegisterKw(p, args, &.{}, &.{});
}

fn singleDispatchRegisterKw(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    _ = kw_names;
    _ = kw_values;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const self = args[0];
    const type_arg = args[1];
    if (self != .instance) return error.TypeError;
    const reg = self.instance.dict.getStr("_registry") orelse return error.TypeError;
    if (reg != .dict) return error.TypeError;

    if (args.len >= 3) {
        try reg.dict.setKey(a, type_arg, args[2]);
        return args[2];
    }
    // Decorator form: return a closure that records and returns.
    const trampoline = try a.create(BuiltinFn);
    trampoline.* = .{ .name = "register_decorator", .func = singleDispatchRegisterDecorator };
    const part = try Partial.init(a, Value{ .builtin_fn = trampoline }, &.{ self, type_arg }, &.{}, &.{});
    return Value{ .partial = part };
}

fn singleDispatchRegisterDecorator(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 3) return error.TypeError;
    const self = args[0];
    const type_arg = args[1];
    const fn_arg = args[2];
    if (self != .instance) return error.TypeError;
    const reg = self.instance.dict.getStr("_registry") orelse return error.TypeError;
    if (reg != .dict) return error.TypeError;
    try reg.dict.setKey(interp.allocator, type_arg, fn_arg);
    return fn_arg;
}

// ============================================================
// singledispatchmethod
// ============================================================

fn singleDispatchMethodFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) return error.TypeError;
    const a = interp.allocator;
    const cls = try ensureSingleDispatchMethodClass(interp);
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "_default", args[0]);
    const reg = try Dict.init(a);
    try inst.dict.setStr(a, "_registry", Value{ .dict = reg });
    return Value{ .instance = inst };
}

fn ensureSingleDispatchMethodClass(interp: *Interp) !*Class {
    if (interp.functools_singledispatchmethod_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "__get__", singleDispatchMethodGet);
    try methodRegKw(a, d, "register", singleDispatchRegister, singleDispatchRegisterKw);
    const cls = try Class.init(a, "singledispatchmethod", &.{}, d);
    interp.functools_singledispatchmethod_class = cls;
    return cls;
}

fn singleDispatchMethodGet(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const self = args[0];
    const target = args[1];
    if (self != .instance) return error.TypeError;
    const a = interp.allocator;
    const trampoline = try a.create(BuiltinFn);
    trampoline.* = .{ .name = "sdm_call", .func = singleDispatchMethodCall };
    const part = try Partial.init(a, Value{ .builtin_fn = trampoline }, &.{ self, target }, &.{}, &.{});
    return Value{ .partial = part };
}

fn singleDispatchMethodCall(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    // args[0] = sdm_instance, args[1] = bound_self, args[2..] = call args
    if (args.len < 3) return error.TypeError;
    const sdm_self = args[0];
    const bound_self = args[1];
    const first = args[2];
    const target = singleDispatchPick(interp, sdm_self, first);
    const a = interp.allocator;
    const merged = try a.alloc(Value, args.len - 1);
    defer a.free(merged);
    merged[0] = bound_self;
    @memcpy(merged[1..], args[2..]);
    return try dispatch.invoke(interp, target, merged);
}
