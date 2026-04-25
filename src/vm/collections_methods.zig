//! Method tables for `collections` runtime values (deque, Counter,
//! defaultdict, OrderedDict, NamedTuple). Each `lookup` returns a
//! `*BuiltinFn` whose impl reads `args[0]` as the typed self.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const Tuple = @import("../object/tuple.zig").Tuple;
const List = @import("../object/list.zig").List;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;
const Iter = @import("../object/iter.zig").Iter;
const builtins = @import("builtins.zig");
const collections_mod = @import("collections_mod.zig");
const NamedTuple = @import("../object/named_tuple.zig").NamedTuple;
const Counter = @import("../object/counter.zig").Counter;

// --- deque ---

pub fn dequeLookup(name: []const u8) ?*BuiltinFn {
    inline for (&deque_methods) |*m| {
        if (std.mem.eql(u8, m.name, name)) return @constCast(m);
    }
    return null;
}

var deque_methods = [_]BuiltinFn{
    .{ .name = "append", .func = dequeAppend },
    .{ .name = "appendleft", .func = dequeAppendLeft },
    .{ .name = "pop", .func = dequePop },
    .{ .name = "popleft", .func = dequePopLeft },
    .{ .name = "extend", .func = dequeExtend },
    .{ .name = "extendleft", .func = dequeExtendLeft },
    .{ .name = "rotate", .func = dequeRotate },
    .{ .name = "reverse", .func = dequeReverse },
    .{ .name = "count", .func = dequeCount },
    .{ .name = "index", .func = dequeIndex },
    .{ .name = "clear", .func = dequeClear },
};

fn dequeSelf(opaque_interp: *anyopaque, args: []const Value) !*@import("../object/deque.zig").Deque {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .deque) {
        try interp.typeError("expected deque self");
        return error.TypeError;
    }
    return args[0].deque;
}

fn dequeAppend(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const d = try dequeSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    try d.append(interp.allocator, args[1]);
    return Value.none;
}

fn dequeAppendLeft(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const d = try dequeSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    try d.appendLeft(interp.allocator, args[1]);
    return Value.none;
}

fn dequePop(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const d = try dequeSelf(opaque_interp, args);
    return d.pop() orelse {
        try interp.raisePy("IndexError", "pop from an empty deque");
        return error.PyException;
    };
}

fn dequePopLeft(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const d = try dequeSelf(opaque_interp, args);
    return d.popLeft() orelse {
        try interp.raisePy("IndexError", "pop from an empty deque");
        return error.PyException;
    };
}

fn dequeExtend(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const d = try dequeSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const lst = try builtins.materialize(interp, args[1]);
    for (lst.items.items) |x| try d.append(interp.allocator, x);
    return Value.none;
}

fn dequeExtendLeft(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const d = try dequeSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const lst = try builtins.materialize(interp, args[1]);
    for (lst.items.items) |x| try d.appendLeft(interp.allocator, x);
    return Value.none;
}

fn dequeRotate(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const d = try dequeSelf(opaque_interp, args);
    var n: i64 = 1;
    if (args.len >= 2) {
        if (args[1] != .small_int) return error.TypeError;
        n = args[1].small_int;
    }
    d.rotate(n);
    return Value.none;
}

fn dequeReverse(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const d = try dequeSelf(opaque_interp, args);
    d.reverse();
    return Value.none;
}

fn dequeCount(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const d = try dequeSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    var n: i64 = 0;
    for (d.items.items.items) |x| if (Value.equals(x, args[1])) {
        n += 1;
    };
    return Value{ .small_int = n };
}

fn dequeIndex(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const d = try dequeSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    for (d.items.items.items, 0..) |x, i| {
        if (Value.equals(x, args[1])) return Value{ .small_int = @intCast(i) };
    }
    try interp.raisePy("ValueError", "deque.index(x): x not in deque");
    return error.PyException;
}

fn dequeClear(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const d = try dequeSelf(opaque_interp, args);
    d.items.items.clearRetainingCapacity();
    return Value.none;
}

// --- Counter ---

pub fn counterLookup(name: []const u8) ?*BuiltinFn {
    inline for (&counter_methods) |*m| {
        if (std.mem.eql(u8, m.name, name)) return @constCast(m);
    }
    return null;
}

var counter_methods = [_]BuiltinFn{
    .{ .name = "most_common", .func = counterMostCommon },
    .{ .name = "elements", .func = counterElements },
    .{ .name = "update", .func = counterUpdateMethod },
    .{ .name = "subtract", .func = counterSubtractMethod },
    .{ .name = "total", .func = counterTotalMethod },
};

fn counterSelf(opaque_interp: *anyopaque, args: []const Value) !*Counter {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .counter) {
        try interp.typeError("expected Counter self");
        return error.TypeError;
    }
    return args[0].counter;
}

fn counterMostCommon(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const c = try counterSelf(opaque_interp, args);
    var n: ?usize = null;
    if (args.len >= 2 and args[1] != .none) {
        if (args[1] != .small_int) return error.TypeError;
        n = @intCast(args[1].small_int);
    }
    // Sort pairs by count descending, stable for ties (CPython uses
    // insertion order for ties).
    const pairs = c.data.pairs.items;
    const tmp = try interp.allocator.alloc(@TypeOf(pairs[0]), pairs.len);
    @memcpy(tmp, pairs);
    std.sort.block(@TypeOf(pairs[0]), tmp, {}, struct {
        fn lt(_: void, a: @TypeOf(pairs[0]), b: @TypeOf(pairs[0])) bool {
            const av: i64 = if (a.value == .small_int) a.value.small_int else 0;
            const bv: i64 = if (b.value == .small_int) b.value.small_int else 0;
            return av > bv;
        }
    }.lt);
    const out = try List.init(interp.allocator);
    const limit = n orelse tmp.len;
    var i: usize = 0;
    while (i < limit and i < tmp.len) : (i += 1) {
        const t = try Tuple.init(interp.allocator, 2);
        t.items[0] = tmp[i].key;
        t.items[1] = tmp[i].value;
        try out.append(interp.allocator, Value{ .tuple = t });
    }
    return Value{ .list = out };
}

fn counterElements(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const c = try counterSelf(opaque_interp, args);
    const out = try List.init(interp.allocator);
    for (c.data.pairs.items) |p| {
        const cnt: i64 = if (p.value == .small_int) p.value.small_int else 0;
        var k: i64 = 0;
        while (k < cnt) : (k += 1) try out.append(interp.allocator, p.key);
    }
    const it = try Iter.init(interp.allocator, .{ .list = out });
    return Value{ .iter = it };
}

fn counterUpdateMethod(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const c = try counterSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    try collections_mod.counterUpdate(interp, c, args[1]);
    return Value.none;
}

fn counterSubtractMethod(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const c = try counterSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    try collections_mod.counterSubtract(interp, c, args[1]);
    return Value.none;
}

fn counterTotalMethod(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const c = try counterSelf(opaque_interp, args);
    return Value{ .small_int = c.total() };
}

// --- OrderedDict ---

pub fn orderedDictLookup(name: []const u8) ?*BuiltinFn {
    inline for (&od_methods) |*m| {
        if (std.mem.eql(u8, m.name, name)) return @constCast(m);
    }
    return null;
}

var od_methods = [_]BuiltinFn{
    .{ .name = "move_to_end", .func = odMoveToEnd, .kw_func = odMoveToEndKw },
    .{ .name = "popitem", .func = odPopItem, .kw_func = odPopItemKw },
    .{ .name = "keys", .func = odKeys },
    .{ .name = "items", .func = odItems },
    .{ .name = "values", .func = odValues },
};

fn odSelf(opaque_interp: *anyopaque, args: []const Value) !*@import("../object/ordered_dict.zig").OrderedDict {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .ordered_dict) {
        try interp.typeError("expected OrderedDict self");
        return error.TypeError;
    }
    return args[0].ordered_dict;
}

fn odMoveToEnd(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    return odMoveToEndKw(opaque_interp, args, &.{}, &.{});
}

fn odMoveToEndKw(
    opaque_interp: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const od = try odSelf(opaque_interp, args);
    if (args.len < 2) return error.TypeError;
    if (args[1] != .str) return error.TypeError;
    const key = args[1].str.bytes;
    var last = true;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "last")) last = kv.isTruthy();
    }
    var idx: ?usize = null;
    for (od.data.pairs.items, 0..) |p, i| {
        if (p.key == .str and std.mem.eql(u8, p.key.str.bytes, key)) {
            idx = i;
            break;
        }
    }
    const i = idx orelse {
        try interp.raisePy("KeyError", key);
        return error.PyException;
    };
    const pair = od.data.pairs.items[i];
    _ = od.data.pairs.orderedRemove(i);
    if (last) {
        try od.data.pairs.append(interp.allocator, pair);
    } else {
        try od.data.pairs.insert(interp.allocator, 0, pair);
    }
    return Value.none;
}

fn odPopItem(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    return odPopItemKw(opaque_interp, args, &.{}, &.{});
}

fn odPopItemKw(
    opaque_interp: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const od = try odSelf(opaque_interp, args);
    var last = true;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "last")) last = kv.isTruthy();
    }
    if (od.data.pairs.items.len == 0) {
        try interp.raisePy("KeyError", "dictionary is empty");
        return error.PyException;
    }
    const idx: usize = if (last) od.data.pairs.items.len - 1 else 0;
    const pair = od.data.pairs.items[idx];
    _ = od.data.pairs.orderedRemove(idx);
    const t = try Tuple.init(interp.allocator, 2);
    t.items[0] = pair.key;
    t.items[1] = pair.value;
    return Value{ .tuple = t };
}

fn odKeys(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const od = try odSelf(opaque_interp, args);
    const out = try List.init(interp.allocator);
    for (od.data.pairs.items) |p| try out.append(interp.allocator, p.key);
    return Value{ .list = out };
}

fn odItems(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const od = try odSelf(opaque_interp, args);
    const out = try List.init(interp.allocator);
    for (od.data.pairs.items) |p| {
        const t = try Tuple.init(interp.allocator, 2);
        t.items[0] = p.key;
        t.items[1] = p.value;
        try out.append(interp.allocator, Value{ .tuple = t });
    }
    return Value{ .list = out };
}

fn odValues(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const od = try odSelf(opaque_interp, args);
    const out = try List.init(interp.allocator);
    for (od.data.pairs.items) |p| try out.append(interp.allocator, p.value);
    return Value{ .list = out };
}

// --- NamedTuple ---

pub fn ntLookup(name: []const u8) ?*BuiltinFn {
    inline for (&nt_methods) |*m| {
        if (std.mem.eql(u8, m.name, name)) return @constCast(m);
    }
    return null;
}

var nt_methods = [_]BuiltinFn{
    .{ .name = "_asdict", .func = ntAsDict },
    .{ .name = "_replace", .func = ntReplace, .kw_func = ntReplaceKw },
};

fn ntSelf(opaque_interp: *anyopaque, args: []const Value) !*NamedTuple {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .named_tuple) {
        try interp.typeError("expected NamedTuple self");
        return error.TypeError;
    }
    return args[0].named_tuple;
}

fn ntAsDict(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const nt = try ntSelf(opaque_interp, args);
    const d = try Dict.init(interp.allocator);
    for (nt.factory.fields, nt.items) |fname, item| {
        try d.setStr(interp.allocator, fname, item);
    }
    return Value{ .dict = d };
}

fn ntReplace(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    return ntReplaceKw(opaque_interp, args, &.{}, &.{});
}

fn ntReplaceKw(
    opaque_interp: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const nt = try ntSelf(opaque_interp, args);
    const new_items = try interp.allocator.alloc(Value, nt.items.len);
    @memcpy(new_items, nt.items);
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        var found = false;
        for (nt.factory.fields, 0..) |fname, i| {
            if (std.mem.eql(u8, fname, kn.str.bytes)) {
                new_items[i] = kv;
                found = true;
                break;
            }
        }
        if (!found) {
            try interp.typeError("_replace: unexpected field");
            return error.TypeError;
        }
    }
    const new_nt = try NamedTuple.init(interp.allocator, nt.factory, new_items);
    return Value{ .named_tuple = new_nt };
}

pub fn ntFieldIndex(nt: *NamedTuple, name: []const u8) ?usize {
    for (nt.factory.fields, 0..) |fname, i| {
        if (std.mem.eql(u8, fname, name)) return i;
    }
    return null;
}

// --- defaultdict has no special methods beyond dict ones ---
