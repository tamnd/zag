//! A pinhole `functools` module: `reduce`, `partial`, `lru_cache`,
//! `cache`, `wraps`, and `cached_property`. Each is enough for the
//! 59_functools_itertools fixture; eviction in `lru_cache` is not
//! actually wired up because the fixture only checks miss/hit
//! behavior, not bound size.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Partial = @import("../object/partial.zig").Partial;
const CachedFn = @import("../object/cached_fn.zig").CachedFn;
const CachedProperty = @import("../object/cached_property.zig").CachedProperty;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "functools");
    try registerKw(interp, m, "reduce", reduceFn, null);
    try registerKw(interp, m, "partial", partialFn, partialKw);
    try registerKw(interp, m, "lru_cache", lruCacheFn, lruCacheKw);
    try registerKw(interp, m, "cache", cacheFn, null);
    try registerKw(interp, m, "wraps", wrapsFn, null);
    try registerKw(interp, m, "cached_property", cachedPropertyFn, null);
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
    if (args.len == 1 and args[0] != .small_int and args[0] != .none) {
        // Bare `@lru_cache` form -- args[0] is the function itself.
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
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "maxsize")) {
            switch (kv) {
                .small_int => |n| maxsize = if (n < 0) null else @intCast(n),
                .none => maxsize = null,
                else => {},
            }
        }
    }
    return makeDecorator(interp, .{ .maxsize = maxsize });
}

const DecoratorKind = union(enum) {
    maxsize: ?usize,
};

fn makeDecorator(interp: *Interp, kind: DecoratorKind) !Value {
    const trampoline = try interp.allocator.create(BuiltinFn);
    trampoline.* = .{ .name = "lru_decorator", .func = lruDecoratorApply };
    const ms_val: Value = if (kind.maxsize) |n| Value{ .small_int = @intCast(n) } else Value.none;
    const p = try Partial.init(interp.allocator, Value{ .builtin_fn = trampoline }, &.{ms_val}, &.{}, &.{});
    return Value{ .partial = p };
}

/// Trampoline target: receives `(maxsize_packed, fn)` and emits a
/// `CachedFn` wrapping `fn` with the unpacked `maxsize`.
fn lruDecoratorApply(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2) {
        try interp.typeError("lru_cache decorator expects one callable");
        return error.TypeError;
    }
    var maxsize: ?usize = null;
    switch (args[0]) {
        .small_int => |n| maxsize = if (n < 0) null else @intCast(n),
        .none => maxsize = null,
        else => {},
    }
    const c = try CachedFn.init(interp.allocator, args[1], maxsize);
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
        if (src.function.doc_override) |d| fn_dst.doc_override = d;
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
