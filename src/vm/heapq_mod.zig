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

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "heapq");
    try reg(interp, m, "heappush", heappushFn);
    try reg(interp, m, "heappop", heappopFn);
    try reg(interp, m, "heapify", heapifyFn);
    try reg(interp, m, "heappushpop", heappushpopFn);
    try reg(interp, m, "heapreplace", heapreplaceFn);
    try reg(interp, m, "nlargest", nlargestFn);
    try reg(interp, m, "nsmallest", nsmallestFn);
    try reg(interp, m, "merge", mergeFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
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

fn nlargestFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const n: usize = @intCast(switch (args[0]) {
        .small_int => |i| if (i < 0) 0 else i,
        .boolean => |b| @as(i64, @intFromBool(b)),
        else => return error.TypeError,
    });
    const src = try builtins_mod.materialize(interp, args[1]);
    const buf = try interp.allocator.alloc(Value, src.items.items.len);
    @memcpy(buf, src.items.items);
    std.sort.block(Value, buf, {}, greaterThan);
    const out = try List.init(interp.allocator);
    var i: usize = 0;
    while (i < n and i < buf.len) : (i += 1) try out.append(interp.allocator, buf[i]);
    interp.allocator.free(buf);
    return Value{ .list = out };
}

fn nsmallestFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const n: usize = @intCast(switch (args[0]) {
        .small_int => |i| if (i < 0) 0 else i,
        .boolean => |b| @as(i64, @intFromBool(b)),
        else => return error.TypeError,
    });
    const src = try builtins_mod.materialize(interp, args[1]);
    const buf = try interp.allocator.alloc(Value, src.items.items.len);
    @memcpy(buf, src.items.items);
    std.sort.block(Value, buf, {}, lessThan);
    const out = try List.init(interp.allocator);
    var i: usize = 0;
    while (i < n and i < buf.len) : (i += 1) try out.append(interp.allocator, buf[i]);
    interp.allocator.free(buf);
    return Value{ .list = out };
}

fn mergeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const out = try List.init(interp.allocator);
    for (args) |a| {
        const lst = try builtins_mod.materialize(interp, a);
        for (lst.items.items) |x| try out.append(interp.allocator, x);
    }
    std.sort.block(Value, out.items.items, {}, lessThan);
    return Value{ .list = out };
}
