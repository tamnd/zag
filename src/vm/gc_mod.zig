//! Stub implementation of Python's `gc` module.
//! Our interpreter uses arena allocation so there is no cycle GC.
//! All functions return sensible defaults.

const std = @import("std");
const Interp = @import("interp.zig").Interp;
const Value = @import("../object/value.zig").Value;
const Module = @import("../object/module.zig").Module;
const BuiltinFn = @import("../object/value.zig").BuiltinFn;
const Tuple = @import("../object/tuple.zig").Tuple;
const List = @import("../object/list.zig").List;

fn reg(a: std.mem.Allocator, m: *Module, name: []const u8, func: *const fn (*anyopaque, []const Value) anyerror!Value) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = bf });
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "gc");

    try reg(a, m, "collect", collectFn);
    try reg(a, m, "enable", enableFn);
    try reg(a, m, "disable", disableFn);
    try reg(a, m, "isenabled", isenabledFn);
    try reg(a, m, "get_count", getCountFn);
    try reg(a, m, "get_threshold", getThresholdFn);
    try reg(a, m, "set_threshold", setThresholdFn);
    try reg(a, m, "get_objects", getObjectsFn);
    try reg(a, m, "is_tracked", isTrackedFn);
    try reg(a, m, "freeze", freezeFn);
    try reg(a, m, "get_freeze_count", getFreezeFn);

    // gc.callbacks = []
    const cb_list = try List.init(a);
    try m.attrs.setStr(a, "callbacks", Value{ .list = cb_list });

    // gc.DEBUG_LEAK etc.
    try m.attrs.setStr(a, "DEBUG_LEAK", Value{ .small_int = 32 });
    try m.attrs.setStr(a, "DEBUG_STATS", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "DEBUG_COLLECTABLE", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "DEBUG_UNCOLLECTABLE", Value{ .small_int = 4 });
    try m.attrs.setStr(a, "DEBUG_SAVEALL", Value{ .small_int = 16 });

    return m;
}

fn collectFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value{ .small_int = 0 };
}

fn enableFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    interp.gc_enabled = true;
    return Value.none;
}

fn disableFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    interp.gc_enabled = false;
    return Value.none;
}

fn isenabledFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    return Value{ .boolean = interp.gc_enabled };
}

fn getCountFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    const t = try Tuple.init(interp.allocator, 3);
    t.items[0] = Value{ .small_int = 0 };
    t.items[1] = Value{ .small_int = 0 };
    t.items[2] = Value{ .small_int = 0 };
    return Value{ .tuple = t };
}

fn getThresholdFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    const t = try Tuple.init(interp.allocator, 3);
    t.items[0] = Value{ .small_int = interp.gc_threshold[0] };
    t.items[1] = Value{ .small_int = interp.gc_threshold[1] };
    t.items[2] = Value{ .small_int = interp.gc_threshold[2] };
    return Value{ .tuple = t };
}

fn setThresholdFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len >= 1 and args[0] == .small_int) interp.gc_threshold[0] = args[0].small_int;
    if (args.len >= 2 and args[1] == .small_int) interp.gc_threshold[1] = args[1].small_int;
    // CPython 3.14 has only 2 generations; third threshold is always 0.
    interp.gc_threshold[2] = 0;
    return Value.none;
}

fn getObjectsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    const lst = try List.init(interp.allocator);
    return Value{ .list = lst };
}

fn isTrackedFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value{ .boolean = false };
}

fn freezeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value.none;
}

fn getFreezeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value{ .small_int = 0 };
}
