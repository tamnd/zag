//! Methods on `dict`. Same name-keyed lookup pattern as
//! `strmethods` / `listmethods`. The fixture only forces `items()`.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Interp = @import("interp.zig").Interp;
const Dict = @import("../object/dict.zig").Dict;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const List = @import("../object/list.zig").List;

/// Materialize a list of `(key, value)` 2-tuples in insertion
/// order. CPython returns a `dict_items` view object, but for the
/// fixture consumers (`sorted(kw.items())`, `for k, v in d.items()`)
/// a plain list is indistinguishable.
pub fn itemsImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1 or args[0] != .dict) {
        try interp.typeError("dict.items() takes no arguments");
        return error.TypeError;
    }
    const d = args[0].dict;
    const out = try List.init(interp.allocator);
    for (d.pairs.items) |p| {
        const pair = try Tuple.init(interp.allocator, 2);
        pair.items[0] = p.key;
        pair.items[1] = p.value;
        try out.append(interp.allocator, Value{ .tuple = pair });
    }
    return Value{ .list = out };
}

/// `dict.keys()` -- list of keys in insertion order. Materializes a
/// list rather than a `dict_keys` view.
pub fn keysImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1 or args[0] != .dict) {
        try interp.typeError("dict.keys() takes no arguments");
        return error.TypeError;
    }
    const d = args[0].dict;
    const out = try List.init(interp.allocator);
    for (d.pairs.items) |p| try out.append(interp.allocator, p.key);
    return Value{ .list = out };
}

pub fn valuesImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1 or args[0] != .dict) {
        try interp.typeError("dict.values() takes no arguments");
        return error.TypeError;
    }
    const d = args[0].dict;
    const out = try List.init(interp.allocator);
    for (d.pairs.items) |p| try out.append(interp.allocator, p.value);
    return Value{ .list = out };
}

/// `dict.get(key)` returns None if missing; `dict.get(key, default)`
/// returns the default. Routes through `getKey` so any hashable
/// (today: ints, strs, tuples) works.
pub fn getImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 2 or args.len > 3 or args[0] != .dict) {
        try interp.typeError("dict.get() takes 1 or 2 arguments");
        return error.TypeError;
    }
    if (args[0].dict.getKey(args[1])) |v| return v;
    return if (args.len == 3) args[2] else Value.none;
}

/// `dict.pop(key)` removes and returns the value, raising `KeyError`
/// if missing. `dict.pop(key, default)` returns the default instead
/// of raising.
pub fn popImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 2 or args.len > 3 or args[0] != .dict) {
        try interp.typeError("dict.pop() takes 1 or 2 arguments");
        return error.TypeError;
    }
    const d = args[0].dict;
    for (d.pairs.items, 0..) |p, i| {
        if (p.key.equals(args[1])) {
            const v = p.value;
            _ = d.pairs.orderedRemove(i);
            if (p.key == .str) {
                for (d.keys.items, 0..) |k, j| {
                    if (std.mem.eql(u8, k, p.key.str.bytes)) {
                        _ = d.keys.orderedRemove(j);
                        break;
                    }
                }
            }
            return v;
        }
    }
    if (args.len == 3) return args[2];
    try interp.raisePy("KeyError", "key not found");
    return error.PyException;
}

pub fn updateImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1 or args[0] != .dict) {
        try interp.typeError("dict.update() requires a dict self");
        return error.TypeError;
    }
    const d = args[0].dict;
    if (args.len >= 2) {
        switch (args[1]) {
            .dict => |s| for (s.pairs.items) |p| try d.setKey(interp.allocator, p.key, p.value),
            .list => |l| for (l.items.items) |it| {
                if (it != .tuple or it.tuple.items.len != 2) {
                    try interp.typeError("dict.update() iterable items must be 2-tuples");
                    return error.TypeError;
                }
                try d.setKey(interp.allocator, it.tuple.items[0], it.tuple.items[1]);
            },
            else => {
                try interp.typeError("dict.update() argument must be a dict or iterable of pairs");
                return error.TypeError;
            },
        }
    }
    return Value.none;
}

pub fn updateKwImpl(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    _ = try updateImpl(interp_opaque, args);
    const d = args[0].dict;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        try d.setStr(interp.allocator, kn.str.bytes, kv);
    }
    return Value.none;
}

pub fn setdefaultImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const d = args[0].dict;
    if (d.getKey(args[1])) |v| return v;
    const default = if (args.len >= 3) args[2] else Value.none;
    try d.setKey(interp.allocator, args[1], default);
    return default;
}

pub fn clearImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const d = args[0].dict;
    d.pairs.clearRetainingCapacity();
    d.keys.clearRetainingCapacity();
    return Value.none;
}

pub fn copyImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const out = try Dict.init(interp.allocator);
    for (args[0].dict.pairs.items) |p| try out.setKey(interp.allocator, p.key, p.value);
    return Value{ .dict = out };
}

pub fn popitemImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const d = args[0].dict;
    if (d.pairs.items.len == 0) {
        try interp.raisePy("KeyError", "dictionary is empty");
        return error.PyException;
    }
    const last = d.pairs.items[d.pairs.items.len - 1];
    _ = d.pairs.pop();
    const t = try Tuple.init(interp.allocator, 2);
    t.items[0] = last.key;
    t.items[1] = last.value;
    return Value{ .tuple = t };
}

pub fn fromkeysImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1) {
        try interp.typeError("dict.fromkeys() missing iterable");
        return error.TypeError;
    }
    const fill: Value = if (args.len >= 2) args[1] else Value.none;
    const d = try Dict.init(interp.allocator);
    const lst = try @import("builtins.zig").materialize(interp, args[0]);
    for (lst.items.items) |k| try d.setKey(interp.allocator, k, fill);
    return Value{ .dict = d };
}

pub var popitem_entry = BuiltinFn{ .name = "popitem", .func = popitemImpl };
pub var fromkeys_entry = BuiltinFn{ .name = "fromkeys", .func = fromkeysImpl };

var items_entry = BuiltinFn{ .name = "items", .func = itemsImpl };
var keys_entry = BuiltinFn{ .name = "keys", .func = keysImpl };
var values_entry = BuiltinFn{ .name = "values", .func = valuesImpl };
var get_entry = BuiltinFn{ .name = "get", .func = getImpl };
var pop_entry = BuiltinFn{ .name = "pop", .func = popImpl };
var update_entry = BuiltinFn{ .name = "update", .func = updateImpl, .kw_func = updateKwImpl };
var setdefault_entry = BuiltinFn{ .name = "setdefault", .func = setdefaultImpl };
var clear_entry = BuiltinFn{ .name = "clear", .func = clearImpl };
var copy_entry = BuiltinFn{ .name = "copy", .func = copyImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "items")) return &items_entry;
    if (std.mem.eql(u8, name, "keys")) return &keys_entry;
    if (std.mem.eql(u8, name, "values")) return &values_entry;
    if (std.mem.eql(u8, name, "get")) return &get_entry;
    if (std.mem.eql(u8, name, "pop")) return &pop_entry;
    if (std.mem.eql(u8, name, "update")) return &update_entry;
    if (std.mem.eql(u8, name, "setdefault")) return &setdefault_entry;
    if (std.mem.eql(u8, name, "clear")) return &clear_entry;
    if (std.mem.eql(u8, name, "copy")) return &copy_entry;
    if (std.mem.eql(u8, name, "popitem")) return &popitem_entry;
    return null;
}
