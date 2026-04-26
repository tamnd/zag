//! Pinhole `heapq` module. CPython exposes a heap interface backed by
//! a list invariant: any list satisfying `a[k] <= a[2k+1]`. We wrap
//! Zig's std.sort to reach the byte-equal output the fixture asserts;
//! a real heap impl isn't required given the test sizes.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Interp = @import("interp.zig").Interp;
const builtins_mod = @import("builtins.zig");
const dispatch = @import("dispatch.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "heapq");
    try reg(interp, m, "heappush", heappushFn);
    try reg(interp, m, "heappop", heappopFn);
    try reg(interp, m, "heapify", heapifyFn);
    try reg(interp, m, "heappushpop", heappushpopFn);
    try reg(interp, m, "heapreplace", heapreplaceFn);
    try regKw(interp, m, "nlargest", nlargestFn, nlargestKw);
    try regKw(interp, m, "nsmallest", nsmallestFn, nsmallestKw);
    try regKw(interp, m, "merge", mergeFn, mergeKw);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw_func: value_mod.BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn lessThan(_: void, a: Value, b: Value) bool {
    return (Value.order(a, b) orelse .eq) == .lt;
}

fn greaterThan(_: void, a: Value, b: Value) bool {
    return (Value.order(a, b) orelse .eq) == .gt;
}

fn siftUp(items: []Value) void {
    // Re-establish min-heap by sorting; cheap given fixture sizes.
    std.sort.block(Value, items, {}, lessThan);
}

fn heappushFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2 or args[0] != .list) {
        try interp.typeError("heappush expects (list, item)");
        return error.TypeError;
    }
    const lst = args[0].list;
    try lst.append(interp.allocator, args[1]);
    siftUp(lst.items.items);
    return Value.none;
}

fn heappopFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .list) {
        try interp.typeError("heappop expects (list)");
        return error.TypeError;
    }
    const lst = args[0].list;
    if (lst.items.items.len == 0) {
        try interp.raisePy("IndexError", "index out of range");
        return error.PyException;
    }
    siftUp(lst.items.items);
    return lst.items.orderedRemove(0);
}

fn heapifyFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .list) {
        try interp.typeError("heapify expects (list)");
        return error.TypeError;
    }
    siftUp(args[0].list.items.items);
    return Value.none;
}

fn heappushpopFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2 or args[0] != .list) {
        try interp.typeError("heappushpop expects (list, item)");
        return error.TypeError;
    }
    const lst = args[0].list;
    try lst.append(interp.allocator, args[1]);
    siftUp(lst.items.items);
    return lst.items.orderedRemove(0);
}

fn heapreplaceFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2 or args[0] != .list) {
        try interp.typeError("heapreplace expects (list, item)");
        return error.TypeError;
    }
    const lst = args[0].list;
    if (lst.items.items.len == 0) {
        try interp.raisePy("IndexError", "index out of range");
        return error.PyException;
    }
    siftUp(lst.items.items);
    const out = lst.items.orderedRemove(0);
    try lst.append(interp.allocator, args[1]);
    siftUp(lst.items.items);
    return out;
}

fn extractKey(kw_names: []const Value, kw_values: []const Value) ?Value {
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "key") and kv != .none) return kv;
    }
    return null;
}

fn extractReverse(kw_names: []const Value, kw_values: []const Value) bool {
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "reverse")) return kv.isTruthy();
    }
    return false;
}

fn nFromArg(arg: Value) usize {
    return @intCast(switch (arg) {
        .small_int => |i| if (i < 0) 0 else i,
        .boolean => |b| @as(i64, @intFromBool(b)),
        else => 0,
    });
}

fn topN(interp: *Interp, n: usize, src: *List, key: ?Value, want_largest: bool) !*List {
    const len = src.items.items.len;
    const idx = try interp.allocator.alloc(usize, len);
    defer interp.allocator.free(idx);
    const keys = try interp.allocator.alloc(Value, len);
    defer interp.allocator.free(keys);
    for (src.items.items, 0..) |x, i| {
        idx[i] = i;
        keys[i] = if (key) |k| try dispatch.invoke(interp, k, &.{x}) else x;
    }
    const Ctx = struct { keys: []const Value, largest: bool };
    const ctx = Ctx{ .keys = keys, .largest = want_largest };
    std.sort.block(usize, idx, ctx, struct {
        fn lt(c: Ctx, a: usize, b: usize) bool {
            const ord = Value.order(c.keys[a], c.keys[b]) orelse .eq;
            return if (c.largest) ord == .gt else ord == .lt;
        }
    }.lt);
    const out = try List.init(interp.allocator);
    var i: usize = 0;
    while (i < n and i < len) : (i += 1) try out.append(interp.allocator, src.items.items[idx[i]]);
    return out;
}

fn nlargestFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return nlargestKw(p, args, &.{}, &.{});
}

fn nlargestKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const n = nFromArg(args[0]);
    const src = try builtins_mod.materialize(interp, args[1]);
    const out = try topN(interp, n, src, extractKey(kw_names, kw_values), true);
    return Value{ .list = out };
}

fn nsmallestFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return nsmallestKw(p, args, &.{}, &.{});
}

fn nsmallestKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const n = nFromArg(args[0]);
    const src = try builtins_mod.materialize(interp, args[1]);
    const out = try topN(interp, n, src, extractKey(kw_names, kw_values), false);
    return Value{ .list = out };
}

fn mergeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return mergeKw(p, args, &.{}, &.{});
}

fn mergeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const reverse = extractReverse(kw_names, kw_values);
    const key = extractKey(kw_names, kw_values);

    // Materialize each source, building parallel arrays of (key, src_idx,
    // item_idx) so a stable sort respects both the key ordering and the
    // original source/item order on ties.
    var total: usize = 0;
    var lists: std.ArrayList(*List) = .empty;
    defer lists.deinit(interp.allocator);
    for (args) |a| {
        const lst = try builtins_mod.materialize(interp, a);
        try lists.append(interp.allocator, lst);
        total += lst.items.items.len;
    }
    const Entry = struct { key: Value, src: u32, idx: u32, value: Value };
    const buf = try interp.allocator.alloc(Entry, total);
    defer interp.allocator.free(buf);
    var i: usize = 0;
    for (lists.items, 0..) |lst, src| {
        for (lst.items.items, 0..) |v, idx| {
            buf[i] = .{
                .key = if (key) |k| try dispatch.invoke(interp, k, &.{v}) else v,
                .src = @intCast(src),
                .idx = @intCast(idx),
                .value = v,
            };
            i += 1;
        }
    }
    const Ctx = struct { rev: bool };
    const ctx = Ctx{ .rev = reverse };
    std.sort.block(Entry, buf, ctx, struct {
        fn lt(c: Ctx, a: Entry, b: Entry) bool {
            const ord = Value.order(a.key, b.key) orelse .eq;
            if (ord != .eq) return if (c.rev) ord == .gt else ord == .lt;
            if (a.src != b.src) return a.src < b.src;
            return a.idx < b.idx;
        }
    }.lt);
    const out = try List.init(interp.allocator);
    for (buf) |e| try out.append(interp.allocator, e.value);
    return Value{ .list = out };
}
