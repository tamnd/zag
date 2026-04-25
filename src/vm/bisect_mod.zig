//! Pinhole `bisect` module: bisect_left/right and insort variants.
//! Supports the optional `lo`, `hi`, `key` arguments (positional and
//! keyword) the way CPython does.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "bisect");
    try regKw(interp, m, "bisect_left", bisectLeftFn, bisectLeftKw);
    try regKw(interp, m, "bisect_right", bisectRightFn, bisectRightKw);
    try regKw(interp, m, "bisect", bisectRightFn, bisectRightKw);
    try regKw(interp, m, "insort", insortRightFn, insortRightKw);
    try regKw(interp, m, "insort_right", insortRightFn, insortRightKw);
    try regKw(interp, m, "insort_left", insortLeftFn, insortLeftKw);
    return m;
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw_func: value_mod.BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

const Args = struct {
    lst: *List,
    target: Value,
    lo: usize,
    hi: usize,
    key: ?Value,
};

fn parseArgs(interp: *Interp, args: []const Value, kw_names: []const Value, kw_values: []const Value) !Args {
    if (args.len < 2 or args[0] != .list) {
        try interp.typeError("bisect expects (list, item[, lo[, hi]])");
        return error.TypeError;
    }
    const lst = args[0].list;
    var lo: usize = 0;
    var hi: usize = lst.items.items.len;
    var key: ?Value = null;
    if (args.len >= 3 and args[2] != .none) lo = @intCast(switch (args[2]) {
        .small_int => |i| if (i < 0) @as(i64, 0) else i,
        else => 0,
    });
    if (args.len >= 4 and args[3] != .none) hi = @intCast(switch (args[3]) {
        .small_int => |i| if (i < 0) @as(i64, 0) else i,
        else => @as(i64, @intCast(lst.items.items.len)),
    });
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const nm = kn.str.bytes;
        if (std.mem.eql(u8, nm, "lo") and kv == .small_int) lo = @intCast(@max(@as(i64, 0), kv.small_int));
        if (std.mem.eql(u8, nm, "hi") and kv == .small_int) hi = @intCast(@max(@as(i64, 0), kv.small_int));
        if (std.mem.eql(u8, nm, "key") and kv != .none) key = kv;
    }
    if (hi > lst.items.items.len) hi = lst.items.items.len;
    if (lo > hi) lo = hi;
    return Args{ .lst = lst, .target = args[1], .lo = lo, .hi = hi, .key = key };
}

fn cmpLT(a: Value, b: Value) bool {
    return (Value.order(a, b) orelse .eq) == .lt;
}

fn keyAt(interp: *Interp, key: ?Value, item: Value) !Value {
    if (key) |k| return try dispatch.invoke(interp, k, &.{item});
    return item;
}

fn searchLeft(interp: *Interp, a: Args) !usize {
    var lo = a.lo;
    var hi = a.hi;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const mid_key = try keyAt(interp, a.key, a.lst.items.items[mid]);
        if (cmpLT(mid_key, a.target)) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn searchRight(interp: *Interp, a: Args) !usize {
    var lo = a.lo;
    var hi = a.hi;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const mid_key = try keyAt(interp, a.key, a.lst.items.items[mid]);
        if (cmpLT(a.target, mid_key)) hi = mid else lo = mid + 1;
    }
    return lo;
}

fn bisectLeftFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return bisectLeftKw(p, args, &.{}, &.{});
}

fn bisectLeftKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = try parseArgs(interp, args, kw_names, kw_values);
    return Value{ .small_int = @intCast(try searchLeft(interp, a)) };
}

fn bisectRightFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return bisectRightKw(p, args, &.{}, &.{});
}

fn bisectRightKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = try parseArgs(interp, args, kw_names, kw_values);
    return Value{ .small_int = @intCast(try searchRight(interp, a)) };
}

fn insortLeftFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return insortLeftKw(p, args, &.{}, &.{});
}

// CPython's insort uses the *raw* item to compute the search key, then
// inserts the item itself at the resulting position. Our parseArgs
// already reads the raw target; for insort we treat `target` as the
// item to insert and look up via key.
fn insortLeftKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var a = try parseArgs(interp, args, kw_names, kw_values);
    // When key is set, the search target is key(item).
    if (a.key) |k| a.target = try dispatch.invoke(interp, k, &.{args[1]});
    const idx = try searchLeft(interp, a);
    try a.lst.items.insert(interp.allocator, idx, args[1]);
    return Value.none;
}

fn insortRightFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return insortRightKw(p, args, &.{}, &.{});
}

fn insortRightKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var a = try parseArgs(interp, args, kw_names, kw_values);
    if (a.key) |k| a.target = try dispatch.invoke(interp, k, &.{args[1]});
    const idx = try searchRight(interp, a);
    try a.lst.items.insert(interp.allocator, idx, args[1]);
    return Value.none;
}
