//! Pinhole `collections` module: `deque`, `Counter`, `defaultdict`,
//! `OrderedDict`, and `namedtuple`. Each is enough for fixture 61 to
//! match CPython byte-for-byte; no inheritance, no copy/pickle, no
//! Counter arithmetic.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Deque = @import("../object/deque.zig").Deque;
const Counter = @import("../object/counter.zig").Counter;
const DefaultDict = @import("../object/defaultdict.zig").DefaultDict;
const OrderedDict = @import("../object/ordered_dict.zig").OrderedDict;
const NamedTuple = @import("../object/named_tuple.zig").NamedTuple;
const NamedTupleFactory = @import("../object/named_tuple.zig").NamedTupleFactory;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");
const builtins = @import("builtins.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "collections");
    try registerKw(interp, m, "deque", dequeFn, dequeKw);
    try registerKw(interp, m, "Counter", counterFn, counterKw);
    try registerKw(interp, m, "defaultdict", defaultdictFn, null);
    try registerKw(interp, m, "OrderedDict", orderedDictFn, null);
    try registerKw(interp, m, "namedtuple", namedtupleFn, namedtupleKw);
    return m;
}

fn registerKw(
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

// --- deque ---

fn dequeFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    return dequeKw(opaque_interp, args, &.{}, &.{});
}

fn dequeKw(
    opaque_interp: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    var maxlen: ?usize = null;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "maxlen")) {
            if (kv != .none) {
                const v = switch (kv) {
                    .small_int => |i| i,
                    else => return error.TypeError,
                };
                if (v < 0) return error.TypeError;
                maxlen = @intCast(v);
            }
        }
    }
    const items = try List.init(interp.allocator);
    if (args.len >= 1) {
        const seed = try builtins.materialize(interp, args[0]);
        for (seed.items.items) |x| try items.append(interp.allocator, x);
    }
    const d = try Deque.init(interp.allocator, items, maxlen);
    if (maxlen) |ml| {
        // Trim from the front if seed exceeded maxlen.
        while (d.items.items.items.len > ml) {
            _ = d.items.items.orderedRemove(0);
        }
    }
    return Value{ .deque = d };
}

// --- Counter ---

fn counterFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    return counterKw(opaque_interp, args, &.{}, &.{});
}

fn counterKw(
    opaque_interp: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const c = try Counter.init(interp.allocator);
    if (args.len == 1) try counterUpdate(interp, c, args[0]);
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const cur = c.data.getStr(kn.str.bytes) orelse Value{ .small_int = 0 };
        const cur_n: i64 = if (cur == .small_int) cur.small_int else 0;
        const inc_n: i64 = if (kv == .small_int) kv.small_int else 0;
        try c.data.setStr(interp.allocator, kn.str.bytes, Value{ .small_int = cur_n + inc_n });
    }
    return Value{ .counter = c };
}

pub fn counterUpdate(interp: *Interp, c: *Counter, v: Value) !void {
    const lst = try builtins.materialize(interp, v);
    for (lst.items.items) |x| {
        const key_str = try valueAsKey(interp, x);
        const cur = c.data.getStr(key_str) orelse Value{ .small_int = 0 };
        const cur_n: i64 = if (cur == .small_int) cur.small_int else 0;
        try c.data.setStr(interp.allocator, key_str, Value{ .small_int = cur_n + 1 });
    }
}

pub fn counterSubtract(interp: *Interp, c: *Counter, v: Value) !void {
    const lst = try builtins.materialize(interp, v);
    for (lst.items.items) |x| {
        const key_str = try valueAsKey(interp, x);
        const cur = c.data.getStr(key_str) orelse Value{ .small_int = 0 };
        const cur_n: i64 = if (cur == .small_int) cur.small_int else 0;
        try c.data.setStr(interp.allocator, key_str, Value{ .small_int = cur_n - 1 });
    }
}

fn valueAsKey(interp: *Interp, v: Value) ![]const u8 {
    if (v == .str) return v.str.bytes;
    // For chars from str iteration we get Str values; bytes etc. unsupported.
    try interp.typeError("Counter only supports str keys");
    return error.TypeError;
}

// --- defaultdict ---

fn defaultdictFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const factory: Value = if (args.len >= 1) args[0] else Value.none;
    const d = try DefaultDict.init(interp.allocator, factory);
    return Value{ .defaultdict = d };
}

// --- OrderedDict ---

fn orderedDictFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const od = try OrderedDict.init(interp.allocator);
    if (args.len == 1) {
        // From iterable of (k, v) pairs or from a dict.
        const lst = try builtins.materialize(interp, args[0]);
        for (lst.items.items) |x| {
            if (x != .tuple or x.tuple.items.len != 2) {
                try interp.typeError("OrderedDict update sequence element is not a 2-tuple");
                return error.TypeError;
            }
            const k = x.tuple.items[0];
            const v = x.tuple.items[1];
            if (k != .str) {
                try interp.typeError("OrderedDict only supports str keys");
                return error.TypeError;
            }
            try od.data.setStr(interp.allocator, k.str.bytes, v);
        }
    }
    return Value{ .ordered_dict = od };
}

// --- namedtuple ---

fn namedtupleFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    return namedtupleKw(opaque_interp, args, &.{}, &.{});
}

fn namedtupleKw(
    opaque_interp: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    _ = kw_names;
    _ = kw_values;
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 2 or args[0] != .str) {
        try interp.typeError("namedtuple expects (typename, fields)");
        return error.TypeError;
    }
    const type_name = args[0].str.bytes;
    var fields: std.ArrayList([]const u8) = .empty;
    if (args[1] == .str) {
        // Space- or comma-separated string.
        var it = std.mem.tokenizeAny(u8, args[1].str.bytes, " ,");
        while (it.next()) |seg| {
            const dup = try interp.allocator.dupe(u8, seg);
            try fields.append(interp.allocator, dup);
        }
    } else {
        const lst = try builtins.materialize(interp, args[1]);
        for (lst.items.items) |x| {
            if (x != .str) {
                try interp.typeError("namedtuple field names must be strings");
                return error.TypeError;
            }
            const dup = try interp.allocator.dupe(u8, x.str.bytes);
            try fields.append(interp.allocator, dup);
        }
    }
    const owned = try fields.toOwnedSlice(interp.allocator);
    const owned_name = try interp.allocator.dupe(u8, type_name);
    const factory = try NamedTupleFactory.init(interp.allocator, owned_name, owned);
    return Value{ .named_tuple_factory = factory };
}
