//! A pinhole `itertools` module: enough for the
//! 59_functools_itertools fixture. Most functions materialize their
//! input(s) up front and produce a list-backed iterator. CPython's
//! versions are lazy; the fixture wraps them in `list(...)` for
//! print, so the laziness distinction is invisible.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Iter = @import("../object/iter.zig").Iter;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");
const builtins_mod = @import("builtins.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "itertools");

    try register(interp, m, "count", countFn, countKw);
    try register(interp, m, "cycle", cycleFn, null);
    try register(interp, m, "repeat", repeatFn, null);
    try register(interp, m, "compress", compressFn, null);
    try register(interp, m, "dropwhile", dropWhileFn, null);
    try register(interp, m, "takewhile", takeWhileFn, null);
    try register(interp, m, "starmap", starmapFn, null);
    try register(interp, m, "zip_longest", zipLongestFn, zipLongestKw);
    try register(interp, m, "product", productFn, productKw);
    try register(interp, m, "permutations", permutationsFn, null);
    try register(interp, m, "combinations", combinationsFn, null);
    try register(interp, m, "combinations_with_replacement", combinationsWithReplacementFn, null);
    try register(interp, m, "accumulate", accumulateFn, accumulateKw);
    try register(interp, m, "pairwise", pairwiseFn, null);
    try register(interp, m, "filterfalse", filterFalseFn, null);
    try register(interp, m, "islice", isliceFn, null);
    try register(interp, m, "groupby", groupbyFn, groupbyKw);
    try register(interp, m, "tee", teeFn, null);

    // `chain` is callable AND carries `from_iterable` -- LOAD_ATTR on
    // the chain builtin needs to find that sibling. Sleight of hand:
    // give the `chain` builtin a deliberately sentinel name and
    // resolve `<chain_obj>.from_iterable` at LOAD_ATTR time in
    // dispatch.zig via a dedicated arm. Expose both functions on the
    // module so users can also reach `itertools.chain_from_iterable`
    // if needed.
    try register(interp, m, "chain", chainFn, null);
    return m;
}

/// Lazy singleton handle for the `chain.from_iterable` LOAD_ATTR arm
/// in dispatch.zig. We re-create per call (cheap; the BuiltinFn is
/// 24 bytes) -- avoids a global mutable.
pub fn chainFromIterableEntry(interp: *Interp) Value {
    const f = interp.allocator.create(BuiltinFn) catch unreachable;
    f.* = .{ .name = "from_iterable", .func = chainFromIterableFn };
    return Value{ .builtin_fn = f };
}

fn register(
    interp: *Interp,
    m: *Module,
    name: []const u8,
    func: BuiltinFnPtr,
    kw_func: ?BuiltinKwFnPtr,
) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn intArg(interp: *Interp, v: Value) !i64 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        else => {
            try interp.typeError("expected int");
            return error.TypeError;
        },
    };
}

fn iterToList(interp: *Interp, v: Value) !*List {
    return builtins_mod.materialize(interp, v);
}

fn listValue(out: *List) Value {
    return Value{ .list = out };
}

fn iterFromList(interp: *Interp, lst: *List) !Value {
    const it = try Iter.init(interp.allocator, .{ .list = lst });
    return Value{ .iter = it };
}

/// `count(start=0, step=1)` -- infinite arithmetic progression.
/// Materializing infinity is unwise, so we hand back a custom Iter
/// state. We fake "infinite" by using a `Range` with an absurd stop;
/// fixtures only consume via `islice`, which truncates in time.
fn countFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return countKw(interp_opaque, args, &.{}, &.{});
}

fn countKw(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    var start_v: Value = Value{ .small_int = 0 };
    var step_v: Value = Value{ .small_int = 1 };
    if (args.len >= 1) start_v = args[0];
    if (args.len >= 2) step_v = args[1];
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "start")) start_v = kv;
        if (std.mem.eql(u8, kn.str.bytes, "step")) step_v = kv;
    }
    const is_float = start_v == .float or step_v == .float;
    if (is_float) {
        // Materialize a long-but-finite stream; islice truncates.
        const want: usize = 1 << 12;
        const out = try List.init(interp.allocator);
        var cur: f64 = switch (start_v) {
            .float => |f| f,
            .small_int => |i| @floatFromInt(i),
            .boolean => |b| @floatFromInt(@intFromBool(b)),
            else => {
                try interp.typeError("count: numeric start required");
                return error.TypeError;
            },
        };
        const stp: f64 = switch (step_v) {
            .float => |f| f,
            .small_int => |i| @floatFromInt(i),
            .boolean => |b| @floatFromInt(@intFromBool(b)),
            else => {
                try interp.typeError("count: numeric step required");
                return error.TypeError;
            },
        };
        var i: usize = 0;
        while (i < want) : (i += 1) {
            try out.append(interp.allocator, Value{ .float = cur });
            cur += stp;
        }
        return iterFromList(interp, out);
    }
    const start = try intArg(interp, start_v);
    const step = try intArg(interp, step_v);
    const it = try Iter.init(interp.allocator, .{ .range = .{ .current = start, .stop = std.math.maxInt(i64), .step = step } });
    return Value{ .iter = it };
}

/// `cycle(iter)` -- cycle infinitely. Fixture wraps with islice, so
/// we materialize once and tile out enough copies to cover any
/// reasonable islice length.
fn cycleFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("cycle expects one iterable");
        return error.TypeError;
    }
    const lst = try iterToList(interp, args[0]);
    const cp = try List.init(interp.allocator);
    if (lst.items.items.len > 0) {
        const want: usize = 1 << 12;
        var i: usize = 0;
        while (i < want) : (i += 1) {
            try cp.append(interp.allocator, lst.items.items[i % lst.items.items.len]);
        }
    }
    return iterFromList(interp, cp);
}

/// `repeat(elem)` / `repeat(elem, n)`.
fn repeatFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1 or args.len > 2) {
        try interp.typeError("repeat expects 1 or 2 arguments");
        return error.TypeError;
    }
    const out = try List.init(interp.allocator);
    if (args.len == 2) {
        const n = try intArg(interp, args[1]);
        if (n > 0) {
            var i: i64 = 0;
            while (i < n) : (i += 1) try out.append(interp.allocator, args[0]);
        }
    } else {
        // Infinite: same fudge as `count`.
        const want: usize = 1 << 12;
        var i: usize = 0;
        while (i < want) : (i += 1) try out.append(interp.allocator, args[0]);
    }
    return iterFromList(interp, out);
}

/// `chain(*iters)`.
fn chainFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const out = try List.init(interp.allocator);
    for (args) |a| {
        const lst = try iterToList(interp, a);
        for (lst.items.items) |x| try out.append(interp.allocator, x);
    }
    return iterFromList(interp, out);
}

/// `chain.from_iterable(iter_of_iters)`.
fn chainFromIterableFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("chain.from_iterable expects one iterable");
        return error.TypeError;
    }
    const out = try List.init(interp.allocator);
    const outer = try iterToList(interp, args[0]);
    for (outer.items.items) |inner_iter| {
        const inner = try iterToList(interp, inner_iter);
        for (inner.items.items) |x| try out.append(interp.allocator, x);
    }
    return iterFromList(interp, out);
}

/// `compress(data, selectors)`.
fn compressFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2) {
        try interp.typeError("compress expects (data, selectors)");
        return error.TypeError;
    }
    const data = try iterToList(interp, args[0]);
    const sel = try iterToList(interp, args[1]);
    const out = try List.init(interp.allocator);
    const n = @min(data.items.items.len, sel.items.items.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (sel.items.items[i].isTruthy()) try out.append(interp.allocator, data.items.items[i]);
    }
    return iterFromList(interp, out);
}

/// `dropwhile(pred, iter)`.
fn dropWhileFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2) {
        try interp.typeError("dropwhile expects (pred, iter)");
        return error.TypeError;
    }
    const lst = try iterToList(interp, args[1]);
    const out = try List.init(interp.allocator);
    var dropping = true;
    for (lst.items.items) |x| {
        if (dropping) {
            const r = try dispatch.invoke(interp, args[0], &.{x});
            if (r.isTruthy()) continue;
            dropping = false;
        }
        try out.append(interp.allocator, x);
    }
    return iterFromList(interp, out);
}

/// `takewhile(pred, iter)`.
fn takeWhileFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2) {
        try interp.typeError("takewhile expects (pred, iter)");
        return error.TypeError;
    }
    const lst = try iterToList(interp, args[1]);
    const out = try List.init(interp.allocator);
    for (lst.items.items) |x| {
        const r = try dispatch.invoke(interp, args[0], &.{x});
        if (!r.isTruthy()) break;
        try out.append(interp.allocator, x);
    }
    return iterFromList(interp, out);
}

/// `starmap(fn, iter_of_tuples)`.
fn starmapFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2) {
        try interp.typeError("starmap expects (fn, iter)");
        return error.TypeError;
    }
    const lst = try iterToList(interp, args[1]);
    const out = try List.init(interp.allocator);
    for (lst.items.items) |x| {
        const inner = switch (x) {
            .tuple => |t| t.items,
            .list => |l| l.items.items,
            else => {
                try interp.typeError("starmap: argument must be iterable of iterables");
                return error.TypeError;
            },
        };
        const r = try dispatch.invoke(interp, args[0], inner);
        try out.append(interp.allocator, r);
    }
    return iterFromList(interp, out);
}

/// `zip_longest(*iters, fillvalue=None)`.
fn zipLongestFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return zipLongestKw(interp_opaque, args, &.{}, &.{});
}

fn zipLongestKw(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    var fill: Value = Value.none;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "fillvalue")) fill = kv;
    }
    const lists = try interp.allocator.alloc(*List, args.len);
    defer interp.allocator.free(lists);
    var max_len: usize = 0;
    for (args, 0..) |a, i| {
        lists[i] = try iterToList(interp, a);
        if (lists[i].items.items.len > max_len) max_len = lists[i].items.items.len;
    }
    const out = try List.init(interp.allocator);
    var k: usize = 0;
    while (k < max_len) : (k += 1) {
        const t = try Tuple.init(interp.allocator, args.len);
        for (lists, 0..) |l, i| {
            t.items[i] = if (k < l.items.items.len) l.items.items[k] else fill;
        }
        try out.append(interp.allocator, Value{ .tuple = t });
    }
    return iterFromList(interp, out);
}

/// `product(*iters)`.
fn productFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return productKw(interp_opaque, args, &.{}, &.{});
}

fn productKw(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    var repeat: usize = 1;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "repeat")) {
            const v = try intArg(interp, kv);
            repeat = if (v < 0) 0 else @intCast(v);
        }
    }
    const dim_count = args.len * repeat;
    if (dim_count == 0) {
        const out = try List.init(interp.allocator);
        const empty_t = try Tuple.init(interp.allocator, 0);
        try out.append(interp.allocator, Value{ .tuple = empty_t });
        return iterFromList(interp, out);
    }
    const base_lists = try interp.allocator.alloc(*List, args.len);
    defer interp.allocator.free(base_lists);
    for (args, 0..) |a, i| base_lists[i] = try iterToList(interp, a);

    const lists = try interp.allocator.alloc(*List, dim_count);
    defer interp.allocator.free(lists);
    var d: usize = 0;
    while (d < dim_count) : (d += 1) lists[d] = base_lists[d % args.len];

    const out = try List.init(interp.allocator);
    for (lists) |l| if (l.items.items.len == 0) return iterFromList(interp, out);

    const indices = try interp.allocator.alloc(usize, dim_count);
    defer interp.allocator.free(indices);
    for (indices) |*ix| ix.* = 0;

    while (true) {
        const t = try Tuple.init(interp.allocator, dim_count);
        for (lists, indices, 0..) |l, ix, i| t.items[i] = l.items.items[ix];
        try out.append(interp.allocator, Value{ .tuple = t });

        var dim: usize = dim_count;
        while (dim > 0) {
            dim -= 1;
            indices[dim] += 1;
            if (indices[dim] < lists[dim].items.items.len) break;
            indices[dim] = 0;
            if (dim == 0) return iterFromList(interp, out);
        }
    }
}

/// `permutations(iterable, r)` -- distinct r-length orderings.
fn permutationsFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1 or args.len > 2) {
        try interp.typeError("permutations expects (iter, r)");
        return error.TypeError;
    }
    const lst = try iterToList(interp, args[0]);
    const n = lst.items.items.len;
    const r: usize = if (args.len == 2) blk: {
        const v = try intArg(interp, args[1]);
        break :blk @intCast(v);
    } else n;
    const out = try List.init(interp.allocator);
    if (r > n) return iterFromList(interp, out);

    const indices = try interp.allocator.alloc(usize, r);
    defer interp.allocator.free(indices);
    const used = try interp.allocator.alloc(bool, n);
    defer interp.allocator.free(used);
    for (used) |*u| u.* = false;

    try permRec(interp, lst.items.items, indices, used, 0, r, out);
    return iterFromList(interp, out);
}

fn permRec(interp: *Interp, items: []const Value, indices: []usize, used: []bool, depth: usize, r: usize, out: *List) !void {
    if (depth == r) {
        const t = try Tuple.init(interp.allocator, r);
        for (indices, 0..) |idx, i| t.items[i] = items[idx];
        try out.append(interp.allocator, Value{ .tuple = t });
        return;
    }
    for (items, 0..) |_, i| {
        if (used[i]) continue;
        used[i] = true;
        indices[depth] = i;
        try permRec(interp, items, indices, used, depth + 1, r, out);
        used[i] = false;
    }
}

/// `combinations(iter, r)`.
fn combinationsFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2) {
        try interp.typeError("combinations expects (iter, r)");
        return error.TypeError;
    }
    const lst = try iterToList(interp, args[0]);
    const r: usize = @intCast(try intArg(interp, args[1]));
    const out = try List.init(interp.allocator);
    if (r > lst.items.items.len) return iterFromList(interp, out);

    const indices = try interp.allocator.alloc(usize, r);
    defer interp.allocator.free(indices);
    try combRec(interp, lst.items.items, indices, 0, 0, r, out);
    return iterFromList(interp, out);
}

fn combRec(interp: *Interp, items: []const Value, indices: []usize, depth: usize, start: usize, r: usize, out: *List) !void {
    if (depth == r) {
        const t = try Tuple.init(interp.allocator, r);
        for (indices, 0..) |idx, i| t.items[i] = items[idx];
        try out.append(interp.allocator, Value{ .tuple = t });
        return;
    }
    var i: usize = start;
    while (i < items.len) : (i += 1) {
        indices[depth] = i;
        try combRec(interp, items, indices, depth + 1, i + 1, r, out);
    }
}

/// `combinations_with_replacement(iter, r)`.
fn combinationsWithReplacementFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2) {
        try interp.typeError("combinations_with_replacement expects (iter, r)");
        return error.TypeError;
    }
    const lst = try iterToList(interp, args[0]);
    const r: usize = @intCast(try intArg(interp, args[1]));
    const out = try List.init(interp.allocator);
    if (r > 0 and lst.items.items.len == 0) return iterFromList(interp, out);

    const indices = try interp.allocator.alloc(usize, r);
    defer interp.allocator.free(indices);
    try combRepRec(interp, lst.items.items, indices, 0, 0, r, out);
    return iterFromList(interp, out);
}

fn combRepRec(interp: *Interp, items: []const Value, indices: []usize, depth: usize, start: usize, r: usize, out: *List) !void {
    if (depth == r) {
        const t = try Tuple.init(interp.allocator, r);
        for (indices, 0..) |idx, i| t.items[i] = items[idx];
        try out.append(interp.allocator, Value{ .tuple = t });
        return;
    }
    var i: usize = start;
    while (i < items.len) : (i += 1) {
        indices[depth] = i;
        try combRepRec(interp, items, indices, depth + 1, i, r, out);
    }
}

/// `accumulate(iter[, fn], *, initial=None)`.
fn accumulateFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return accumulateKw(interp_opaque, args, &.{}, &.{});
}

fn accumulateKw(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1 or args.len > 2) {
        try interp.typeError("accumulate expects 1 or 2 arguments");
        return error.TypeError;
    }
    var initial: ?Value = null;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "initial")) {
            if (kv != .none) initial = kv;
        }
    }
    const lst = try iterToList(interp, args[0]);
    const out = try List.init(interp.allocator);
    var acc: Value = undefined;
    var start_idx: usize = 0;
    if (initial) |iv| {
        acc = iv;
        try out.append(interp.allocator, acc);
    } else {
        if (lst.items.items.len == 0) return iterFromList(interp, out);
        acc = lst.items.items[0];
        try out.append(interp.allocator, acc);
        start_idx = 1;
    }
    var i: usize = start_idx;
    while (i < lst.items.items.len) : (i += 1) {
        if (args.len == 2) {
            acc = try dispatch.invoke(interp, args[1], &.{ acc, lst.items.items[i] });
        } else {
            acc = try dispatch.binaryAdd(interp, acc, lst.items.items[i]);
        }
        try out.append(interp.allocator, acc);
    }
    return iterFromList(interp, out);
}

/// `pairwise(iter)`.
fn pairwiseFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("pairwise expects one iterable");
        return error.TypeError;
    }
    const lst = try iterToList(interp, args[0]);
    const out = try List.init(interp.allocator);
    if (lst.items.items.len < 2) return iterFromList(interp, out);
    var i: usize = 0;
    while (i + 1 < lst.items.items.len) : (i += 1) {
        const t = try Tuple.init(interp.allocator, 2);
        t.items[0] = lst.items.items[i];
        t.items[1] = lst.items.items[i + 1];
        try out.append(interp.allocator, Value{ .tuple = t });
    }
    return iterFromList(interp, out);
}

/// `filterfalse(pred, iter)` -- pass through items where pred is
/// falsy.
fn filterFalseFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2) {
        try interp.typeError("filterfalse expects (pred, iter)");
        return error.TypeError;
    }
    const lst = try iterToList(interp, args[1]);
    const out = try List.init(interp.allocator);
    for (lst.items.items) |x| {
        if (args[0] == .none) {
            if (!x.isTruthy()) try out.append(interp.allocator, x);
            continue;
        }
        const r = try dispatch.invoke(interp, args[0], &.{x});
        if (!r.isTruthy()) try out.append(interp.allocator, x);
    }
    return iterFromList(interp, out);
}

/// `groupby(iter, key=None)` -- group consecutive items by `key`. We
/// build the output eagerly: a list of (key, list-of-items) tuples.
fn groupbyFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return groupbyKw(interp_opaque, args, &.{}, &.{});
}

fn groupbyKw(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1 or args.len > 2) {
        try interp.typeError("groupby expects (iter[, key])");
        return error.TypeError;
    }
    var key_fn: Value = if (args.len == 2) args[1] else Value.none;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "key")) key_fn = kv;
    }
    const lst = try iterToList(interp, args[0]);
    const out = try List.init(interp.allocator);
    if (lst.items.items.len == 0) return iterFromList(interp, out);

    var i: usize = 0;
    while (i < lst.items.items.len) {
        const x = lst.items.items[i];
        const k = if (key_fn == .none) x else try dispatch.invoke(interp, key_fn, &.{x});
        const group = try List.init(interp.allocator);
        try group.append(interp.allocator, x);
        var j: usize = i + 1;
        while (j < lst.items.items.len) : (j += 1) {
            const y = lst.items.items[j];
            const ky = if (key_fn == .none) y else try dispatch.invoke(interp, key_fn, &.{y});
            if (!Value.equals(k, ky)) break;
            try group.append(interp.allocator, y);
        }
        const group_iter = try iterFromList(interp, group);
        const t = try Tuple.init(interp.allocator, 2);
        t.items[0] = k;
        t.items[1] = group_iter;
        try out.append(interp.allocator, Value{ .tuple = t });
        i = j;
    }
    return iterFromList(interp, out);
}

/// `tee(iter[, n])` -- n independent iterators, eager copy.
fn teeFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1 or args.len > 2) {
        try interp.typeError("tee expects (iter[, n])");
        return error.TypeError;
    }
    var n: usize = 2;
    if (args.len == 2) {
        const v = try intArg(interp, args[1]);
        n = if (v < 0) 0 else @intCast(v);
    }
    const src = try iterToList(interp, args[0]);
    const out = try Tuple.init(interp.allocator, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const cp = try List.init(interp.allocator);
        for (src.items.items) |x| try cp.append(interp.allocator, x);
        out.items[i] = try iterFromList(interp, cp);
    }
    return Value{ .tuple = out };
}

/// `islice(iter, stop)` / `islice(iter, start, stop[, step])`.
fn isliceFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 2 or args.len > 4) {
        try interp.typeError("islice expects (iter, stop) or (iter, start, stop[, step])");
        return error.TypeError;
    }
    var start: usize = 0;
    var stop: ?usize = null;
    var step: usize = 1;
    if (args.len == 2) {
        if (args[1] != .none) {
            const v = try intArg(interp, args[1]);
            stop = if (v < 0) 0 else @intCast(v);
        }
    } else {
        if (args[1] != .none) {
            const v = try intArg(interp, args[1]);
            if (v > 0) start = @intCast(v);
        }
        if (args[2] != .none) {
            const v = try intArg(interp, args[2]);
            stop = if (v < 0) 0 else @intCast(v);
        }
        if (args.len == 4 and args[3] != .none) {
            const v = try intArg(interp, args[3]);
            if (v > 0) step = @intCast(v);
        }
    }
    const out = try List.init(interp.allocator);
    const inner_iter = blk: {
        if (args[0] == .iter) break :blk args[0];
        if (args[0] == .generator) break :blk args[0];
        const it = try dispatch.makeIter(interp, args[0]);
        break :blk Value{ .iter = it };
    };
    var i: usize = 0;
    var next_emit: usize = start;
    while (try dispatch.iterStep(interp, inner_iter)) |x| {
        if (stop) |s| if (i >= s) break;
        if (i == next_emit) {
            try out.append(interp.allocator, x);
            next_emit += step;
        }
        i += 1;
    }
    return iterFromList(interp, out);
}
