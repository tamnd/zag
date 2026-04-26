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
    .{ .name = "copy", .func = dequeCopy },
    .{ .name = "insert", .func = dequeInsert },
    .{ .name = "remove", .func = dequeRemove },
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
    if (args.len < 2 or args.len > 4) return error.TypeError;
    const buf = d.items.items.items;
    const n: i64 = @intCast(buf.len);
    var start: i64 = 0;
    var stop: i64 = n;
    if (args.len >= 3) {
        if (args[2] != .small_int) return error.TypeError;
        start = args[2].small_int;
    }
    if (args.len >= 4) {
        if (args[3] != .small_int) return error.TypeError;
        stop = args[3].small_int;
    }
    if (start < 0) start += n;
    if (start < 0) start = 0;
    if (stop < 0) stop += n;
    if (stop > n) stop = n;
    var i: i64 = start;
    while (i < stop) : (i += 1) {
        if (Value.equals(buf[@intCast(i)], args[1])) return Value{ .small_int = i };
    }
    try interp.raisePy("ValueError", "deque.index(x): x not in deque");
    return error.PyException;
}

fn dequeClear(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const d = try dequeSelf(opaque_interp, args);
    d.items.items.clearRetainingCapacity();
    return Value.none;
}

fn dequeCopy(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const d = try dequeSelf(opaque_interp, args);
    const new_items = try List.init(interp.allocator);
    for (d.items.items.items) |x| try new_items.append(interp.allocator, x);
    const Deque = @import("../object/deque.zig").Deque;
    const nd = try Deque.init(interp.allocator, new_items, d.maxlen);
    return Value{ .deque = nd };
}

fn dequeInsert(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const d = try dequeSelf(opaque_interp, args);
    if (args.len != 3 or args[1] != .small_int) return error.TypeError;
    var idx = args[1].small_int;
    const n: i64 = @intCast(d.items.items.items.len);
    if (idx < 0) idx += n;
    if (idx < 0) idx = 0;
    if (idx > n) idx = n;
    try d.items.items.insert(interp.allocator, @intCast(idx), args[2]);
    if (d.maxlen) |ml| {
        while (d.items.items.items.len > ml) _ = d.items.items.pop();
    }
    return Value.none;
}

fn dequeRemove(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const d = try dequeSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    for (d.items.items.items, 0..) |x, i| {
        if (Value.equals(x, args[1])) {
            _ = d.items.items.orderedRemove(i);
            return Value.none;
        }
    }
    try interp.raisePy("ValueError", "deque.remove(x): x not in deque");
    return error.PyException;
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
    .{ .name = "copy", .func = counterCopy },
};

fn counterCopy(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const c = try counterSelf(opaque_interp, args);
    const nc = try Counter.init(interp.allocator);
    for (c.data.pairs.items) |p| {
        try nc.data.setStr(interp.allocator, p.key.str.bytes, p.value);
    }
    return Value{ .counter = nc };
}

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
    .{ .name = "copy", .func = odCopy },
};

pub var od_fromkeys_entry: BuiltinFn = .{ .name = "fromkeys", .func = odFromkeys };

fn odCopy(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const od = try odSelf(opaque_interp, args);
    const OrderedDict = @import("../object/ordered_dict.zig").OrderedDict;
    const out = try OrderedDict.init(interp.allocator);
    for (od.data.pairs.items) |p| try out.data.setKey(interp.allocator, p.key, p.value);
    return Value{ .ordered_dict = out };
}

fn odFromkeys(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args.len > 2) {
        try interp.typeError("OrderedDict.fromkeys takes 1 or 2 args");
        return error.TypeError;
    }
    const default_v: Value = if (args.len == 2) args[1] else Value.none;
    const lst = try builtins.materialize(interp, args[0]);
    const OrderedDict = @import("../object/ordered_dict.zig").OrderedDict;
    const out = try OrderedDict.init(interp.allocator);
    for (lst.items.items) |k| try out.data.setKey(interp.allocator, k, default_v);
    return Value{ .ordered_dict = out };
}

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
    .{ .name = "count", .func = ntCount },
    .{ .name = "index", .func = ntIndex },
};

pub var nt_make_entry: BuiltinFn = .{ .name = "_make", .func = ntMake };

pub var counter_fromkeys_entry: BuiltinFn = .{ .name = "fromkeys", .func = counterFromkeys };

fn counterFromkeys(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    _ = args;
    try interp.raisePy("NotImplementedError", "Counter.fromkeys() is undefined.  Use Counter(iterable) instead.");
    return error.PyException;
}

fn ntMake(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 2 or args[0] != .named_tuple_factory) {
        try interp.typeError("_make: expected (factory, iterable)");
        return error.TypeError;
    }
    const factory = args[0].named_tuple_factory;
    const lst = try builtins.materialize(interp, args[1]);
    if (lst.items.items.len != factory.fields.len) {
        try interp.raisePy("TypeError", "_make: wrong number of items");
        return error.PyException;
    }
    const items = try interp.allocator.alloc(Value, factory.fields.len);
    @memcpy(items, lst.items.items);
    const nt = try NamedTuple.init(interp.allocator, factory, items);
    return Value{ .named_tuple = nt };
}

fn ntCount(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const nt = try ntSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    var n: i64 = 0;
    for (nt.items) |x| if (Value.equals(x, args[1])) {
        n += 1;
    };
    return Value{ .small_int = n };
}

fn ntIndex(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const nt = try ntSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    for (nt.items, 0..) |x, i| {
        if (Value.equals(x, args[1])) return Value{ .small_int = @intCast(i) };
    }
    try interp.raisePy("ValueError", "tuple.index(x): x not in tuple");
    return error.PyException;
}

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

// --- defaultdict ---

pub fn defaultDictLookup(name: []const u8) ?*BuiltinFn {
    inline for (&dd_methods) |*m| {
        if (std.mem.eql(u8, m.name, name)) return @constCast(m);
    }
    return null;
}

var dd_methods = [_]BuiltinFn{
    .{ .name = "copy", .func = ddCopy },
};

fn ddCopy(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .defaultdict) {
        try interp.typeError("expected defaultdict self");
        return error.TypeError;
    }
    const DefaultDict = @import("../object/defaultdict.zig").DefaultDict;
    const dd = args[0].defaultdict;
    const nd = try DefaultDict.init(interp.allocator, dd.factory);
    for (dd.data.pairs.items) |p| try nd.data.setKey(interp.allocator, p.key, p.value);
    return Value{ .defaultdict = nd };
}
