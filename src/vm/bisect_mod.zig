//! Pinhole `bisect` module: bisect_left/right and insort variants.
//! Comparison goes through Value.order so int/float lists work alike.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "bisect");
    try reg(interp, m, "bisect_left", bisectLeftFn);
    try reg(interp, m, "bisect_right", bisectRightFn);
    try reg(interp, m, "bisect", bisectRightFn);
    try reg(interp, m, "insort", insortRightFn);
    try reg(interp, m, "insort_right", insortRightFn);
    try reg(interp, m, "insort_left", insortLeftFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn cmpLT(a: Value, b: Value) bool {
    return (Value.order(a, b) orelse .eq) == .lt;
}

fn searchLeft(items: []const Value, x: Value) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cmpLT(items[mid], x)) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn searchRight(items: []const Value, x: Value) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cmpLT(x, items[mid])) hi = mid else lo = mid + 1;
    }
    return lo;
}

fn bisectLeftFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .list) {
        try interp.typeError("bisect_left expects (list, item)");
        return error.TypeError;
    }
    return Value{ .small_int = @intCast(searchLeft(args[0].list.items.items, args[1])) };
}

fn bisectRightFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .list) {
        try interp.typeError("bisect_right expects (list, item)");
        return error.TypeError;
    }
    return Value{ .small_int = @intCast(searchRight(args[0].list.items.items, args[1])) };
}

fn insortLeftFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .list) {
        try interp.typeError("insort_left expects (list, item)");
        return error.TypeError;
    }
    const lst = args[0].list;
    const idx = searchLeft(lst.items.items, args[1]);
    try lst.items.insert(interp.allocator, idx, args[1]);
    return Value.none;
}

fn insortRightFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .list) {
        try interp.typeError("insort expects (list, item)");
        return error.TypeError;
    }
    const lst = args[0].list;
    const idx = searchRight(lst.items.items, args[1]);
    try lst.items.insert(interp.allocator, idx, args[1]);
    return Value.none;
}
