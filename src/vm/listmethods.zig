//! Method table for `list`. Same convention as strmethods: each
//! function takes (interp, args) where args[0] is self.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Interp = @import("interp.zig").Interp;

fn appendImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    try args[0].list.append(interp.allocator, args[1]);
    return Value.none;
}

fn extendImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const dst = args[0].list;
    switch (args[1]) {
        .list => |l| for (l.items.items) |it| try dst.append(interp.allocator, it),
        .tuple => |t| for (t.items) |it| try dst.append(interp.allocator, it),
        else => {
            try interp.typeError("extend() argument must be iterable");
            return error.TypeError;
        },
    }
    return Value.none;
}

fn popImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const lst = args[0].list;
    const n = lst.items.items.len;
    if (n == 0) {
        try interp.indexError("pop from empty list");
        return error.IndexError;
    }
    if (args.len < 2) return lst.items.pop().?;
    if (args[1] != .small_int) {
        try interp.typeError("pop() index must be an integer");
        return error.TypeError;
    }
    var idx = args[1].small_int;
    if (idx < 0) idx += @intCast(n);
    if (idx < 0 or idx >= @as(i64, @intCast(n))) {
        try interp.indexError("pop index out of range");
        return error.IndexError;
    }
    return lst.items.orderedRemove(@intCast(idx));
}

fn reverseImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const items = args[0].list.items.items;
    std.mem.reverse(Value, items);
    return Value.none;
}

fn lessThanForSort(_: void, a: Value, b: Value) bool {
    if (a.order(b)) |o| return o == .lt;
    return false;
}

fn sortInPlace(interp: *Interp, lst_items: []Value, key_fn: ?Value, reverse: bool) !void {
    if (key_fn) |kf| {
        const dispatch = @import("dispatch.zig");
        const idx = try interp.allocator.alloc(usize, lst_items.len);
        defer interp.allocator.free(idx);
        const keys = try interp.allocator.alloc(Value, lst_items.len);
        defer interp.allocator.free(keys);
        for (lst_items, 0..) |x, i| {
            idx[i] = i;
            keys[i] = try dispatch.invoke(interp, kf, &.{x});
        }
        const Ctx = struct { keys: []const Value };
        const ctx: Ctx = .{ .keys = keys };
        std.sort.block(usize, idx, ctx, struct {
            fn lt(c: Ctx, a: usize, b: usize) bool {
                if (c.keys[a].order(c.keys[b])) |o| return o == .lt;
                return false;
            }
        }.lt);
        const buf = try interp.allocator.alloc(Value, lst_items.len);
        defer interp.allocator.free(buf);
        for (idx, 0..) |src_i, i| buf[i] = lst_items[src_i];
        @memcpy(lst_items, buf);
    } else {
        std.sort.pdq(Value, lst_items, {}, lessThanForSort);
    }
    if (reverse) std.mem.reverse(Value, lst_items);
}

fn sortImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    try sortInPlace(interp, args[0].list.items.items, null, false);
    return Value.none;
}

fn sortKwImpl(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    var key_fn: ?Value = null;
    var reverse = false;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "key")) {
            if (kv != .none) key_fn = kv;
        } else if (std.mem.eql(u8, kn.str.bytes, "reverse")) {
            reverse = kv.isTruthy();
        }
    }
    try sortInPlace(interp, args[0].list.items.items, key_fn, reverse);
    return Value.none;
}

fn insertImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const lst = args[0].list;
    if (args[1] != .small_int) {
        try interp.typeError("insert() index must be an integer");
        return error.TypeError;
    }
    const n: i64 = @intCast(lst.items.items.len);
    var idx: i64 = args[1].small_int;
    if (idx < 0) idx += n;
    if (idx < 0) idx = 0;
    if (idx > n) idx = n;
    try lst.items.insert(interp.allocator, @intCast(idx), args[2]);
    return Value.none;
}

fn removeImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const lst = args[0].list;
    for (lst.items.items, 0..) |it, i| {
        if (it.equals(args[1])) {
            _ = lst.items.orderedRemove(i);
            return Value.none;
        }
    }
    try interp.raisePy("ValueError", "list.remove(x): x not in list");
    return error.PyException;
}

fn indexImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const lst = args[0].list;
    for (lst.items.items, 0..) |it, i| {
        if (it.equals(args[1])) return Value{ .small_int = @intCast(i) };
    }
    try interp.raisePy("ValueError", "x not in list");
    return error.PyException;
}

fn countImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const lst = args[0].list;
    var n: i64 = 0;
    for (lst.items.items) |it| if (it.equals(args[1])) {
        n += 1;
    };
    return Value{ .small_int = n };
}

fn clearImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    args[0].list.items.clearRetainingCapacity();
    return Value.none;
}

fn copyImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const List = @import("../object/list.zig").List;
    const out = try List.init(interp.allocator);
    for (args[0].list.items.items) |it| try out.append(interp.allocator, it);
    return Value{ .list = out };
}

var append_entry: BuiltinFn = .{ .name = "append", .func = appendImpl };
var extend_entry: BuiltinFn = .{ .name = "extend", .func = extendImpl };
var pop_entry: BuiltinFn = .{ .name = "pop", .func = popImpl };
var reverse_entry: BuiltinFn = .{ .name = "reverse", .func = reverseImpl };
var sort_entry: BuiltinFn = .{ .name = "sort", .func = sortImpl, .kw_func = sortKwImpl };
var insert_entry: BuiltinFn = .{ .name = "insert", .func = insertImpl };
var remove_entry: BuiltinFn = .{ .name = "remove", .func = removeImpl };
var index_entry: BuiltinFn = .{ .name = "index", .func = indexImpl };
var count_entry: BuiltinFn = .{ .name = "count", .func = countImpl };
var clear_entry: BuiltinFn = .{ .name = "clear", .func = clearImpl };
var copy_entry: BuiltinFn = .{ .name = "copy", .func = copyImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "append")) return &append_entry;
    if (std.mem.eql(u8, name, "extend")) return &extend_entry;
    if (std.mem.eql(u8, name, "pop")) return &pop_entry;
    if (std.mem.eql(u8, name, "reverse")) return &reverse_entry;
    if (std.mem.eql(u8, name, "sort")) return &sort_entry;
    if (std.mem.eql(u8, name, "insert")) return &insert_entry;
    if (std.mem.eql(u8, name, "remove")) return &remove_entry;
    if (std.mem.eql(u8, name, "index")) return &index_entry;
    if (std.mem.eql(u8, name, "count")) return &count_entry;
    if (std.mem.eql(u8, name, "clear")) return &clear_entry;
    if (std.mem.eql(u8, name, "copy")) return &copy_entry;
    return null;
}
