//! Pinhole `collections` classes: `ChainMap`, `UserDict`, `UserList`,
//! `UserString`. Modeled as `Class`+`Instance` pairs that hold the
//! actual data on the instance dict (`maps` for ChainMap, `data` for
//! the User* trio). Method bodies extract the data, do the work, and
//! return either a plain Python value or a fresh instance of the
//! same class.

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
const Interp = @import("interp.zig").Interp;
const builtins = @import("builtins.zig");
const dispatch = @import("dispatch.zig");

pub fn ensureClasses(interp: *Interp) !void {
    if (interp.collections_chainmap_class != null) return;
    const a = interp.allocator;

    // ChainMap
    {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", cmInitKw);
        try reg(a, d, "__getitem__", cmGetitem);
        try reg(a, d, "__setitem__", cmSetitem);
        try reg(a, d, "__delitem__", cmDelitem);
        try reg(a, d, "__contains__", cmContains);
        try reg(a, d, "__len__", cmLen);
        try reg(a, d, "__iter__", cmIter);
        try reg(a, d, "keys", cmKeys);
        try reg(a, d, "values", cmValues);
        try reg(a, d, "items", cmItems);
        try reg(a, d, "get", cmGet);
        try reg(a, d, "new_child", cmNewChild);
        // parents: property -> ChainMap of self.maps[1:]
        const Descriptor = @import("../object/descriptor.zig").Descriptor;
        const parents_fn = try a.create(BuiltinFn);
        parents_fn.* = .{ .name = "parents", .func = cmParents };
        const parents_desc = try Descriptor.init(a, .property, Value{ .builtin_fn = parents_fn });
        try d.setStr(a, "parents", Value{ .descriptor = parents_desc });
        interp.collections_chainmap_class = try Class.init(a, "ChainMap", &.{}, d);
    }

    // UserDict
    {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", udInit);
        try reg(a, d, "__getitem__", udGetitem);
        try reg(a, d, "__setitem__", udSetitem);
        try reg(a, d, "__delitem__", udDelitem);
        try reg(a, d, "__contains__", udContains);
        try reg(a, d, "__len__", udLen);
        try reg(a, d, "__iter__", udIter);
        try reg(a, d, "keys", udKeys);
        try reg(a, d, "values", udValues);
        try reg(a, d, "items", udItems);
        try reg(a, d, "copy", udCopy);
        try reg(a, d, "get", udGet);
        try reg(a, d, "pop", udPop);
        try reg(a, d, "setdefault", udSetdefault);
        try reg(a, d, "update", udUpdate);
        try reg(a, d, "clear", udClear);
        interp.collections_userdict_class = try Class.init(a, "UserDict", &.{}, d);
    }

    // UserList
    {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", ulInit);
        try reg(a, d, "__getitem__", ulGetitem);
        try reg(a, d, "__setitem__", ulSetitem);
        try reg(a, d, "__delitem__", ulDelitem);
        try reg(a, d, "__contains__", ulContains);
        try reg(a, d, "__len__", ulLen);
        try reg(a, d, "__iter__", ulIter);
        try reg(a, d, "__add__", ulAdd);
        try reg(a, d, "append", ulAppend);
        try reg(a, d, "sort", ulSort);
        try reg(a, d, "count", ulCount);
        try reg(a, d, "index", ulIndex);
        try reg(a, d, "reverse", ulReverse);
        try reg(a, d, "insert", ulInsert);
        try reg(a, d, "remove", ulRemove);
        try reg(a, d, "copy", ulCopy);
        try reg(a, d, "extend", ulExtend);
        try reg(a, d, "pop", ulPop);
        try reg(a, d, "clear", ulClear);
        interp.collections_userlist_class = try Class.init(a, "UserList", &.{}, d);
    }

    // UserString
    {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", usInit);
        try reg(a, d, "__str__", usStr);
        try reg(a, d, "__repr__", usStr);
        try reg(a, d, "__getitem__", usGetitem);
        try reg(a, d, "__len__", usLen);
        try reg(a, d, "__contains__", usContains);
        try reg(a, d, "__add__", usAdd);
        try reg(a, d, "__lt__", usLt);
        try reg(a, d, "__eq__", usEq);
        try reg(a, d, "upper", usUpper);
        try reg(a, d, "lower", usLower);
        try reg(a, d, "strip", usStrip);
        try reg(a, d, "replace", usReplace);
        try reg(a, d, "startswith", usStartswith);
        try reg(a, d, "endswith", usEndswith);
        try reg(a, d, "find", usFind);
        try reg(a, d, "split", usSplit);
        try reg(a, d, "join", usJoin);
        interp.collections_userstring_class = try Class.init(a, "UserString", &.{}, d);
    }
}

fn reg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(a: std.mem.Allocator, d: *Dict, name: []const u8, comptime kw_func: BuiltinKwFnPtr) !void {
    const Wrap = struct {
        fn call(p: *anyopaque, args: []const Value) anyerror!Value {
            return kw_func(p, args, &.{}, &.{});
        }
    };
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = Wrap.call, .kw_func = kw_func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn instSelf(opaque_interp: *anyopaque, args: []const Value) !*Instance {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .instance) {
        try interp.typeError("expected instance self");
        return error.TypeError;
    }
    return args[0].instance;
}

// ============== ChainMap ==============

fn cmMaps(self: *Instance) ?*List {
    const v = self.dict.getStr("maps") orelse return null;
    if (v != .list) return null;
    return v.list;
}

fn cmInitKw(
    opaque_interp: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    _ = kw_names;
    _ = kw_values;
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const maps = try List.init(interp.allocator);
    if (args.len <= 1) {
        try maps.append(interp.allocator, Value{ .dict = try Dict.init(interp.allocator) });
    } else {
        for (args[1..]) |m| try maps.append(interp.allocator, m);
    }
    try self.dict.setStr(interp.allocator, "maps", Value{ .list = maps });
    return Value.none;
}

fn dictLikeGet(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .dict => |d| d.getStr(key),
        .ordered_dict => |od| od.data.getStr(key),
        .defaultdict => |dd| dd.data.getStr(key),
        .counter => |c| c.data.getStr(key),
        else => null,
    };
}

fn dictLikeContains(v: Value, key: []const u8) bool {
    return dictLikeGet(v, key) != null;
}

fn dictLikePairs(v: Value) ?[]const @import("../object/dict.zig").Dict.Pair {
    return switch (v) {
        .dict => |d| d.pairs.items,
        .ordered_dict => |od| od.data.pairs.items,
        .defaultdict => |dd| dd.data.pairs.items,
        .counter => |c| c.data.pairs.items,
        else => null,
    };
}

fn cmGetitem(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2 or args[1] != .str) return error.TypeError;
    const key = args[1].str.bytes;
    const maps = cmMaps(self) orelse return error.TypeError;
    for (maps.items.items) |m| {
        if (dictLikeGet(m, key)) |v| return v;
    }
    try interp.raisePy("KeyError", key);
    return error.PyException;
}

fn cmSetitem(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 3 or args[1] != .str) return error.TypeError;
    const maps = cmMaps(self) orelse return error.TypeError;
    if (maps.items.items.len == 0) return error.TypeError;
    const first = maps.items.items[0];
    if (first != .dict) {
        try interp.typeError("ChainMap.__setitem__: first map must be a dict");
        return error.TypeError;
    }
    try first.dict.setStr(interp.allocator, args[1].str.bytes, args[2]);
    return Value.none;
}

fn cmDelitem(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2 or args[1] != .str) return error.TypeError;
    const maps = cmMaps(self) orelse return error.TypeError;
    if (maps.items.items.len == 0) return error.TypeError;
    const first = maps.items.items[0];
    if (first != .dict) return error.TypeError;
    if (!first.dict.delete(args[1].str.bytes)) {
        try interp.raisePy("KeyError", args[1].str.bytes);
        return error.PyException;
    }
    return Value.none;
}

fn cmContains(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2 or args[1] != .str) return error.TypeError;
    const key = args[1].str.bytes;
    const maps = cmMaps(self) orelse return error.TypeError;
    for (maps.items.items) |m| {
        if (dictLikeContains(m, key)) return Value{ .boolean = true };
    }
    return Value{ .boolean = false };
}

fn cmCollectKeys(interp: *Interp, self: *Instance) !*List {
    const out = try List.init(interp.allocator);
    var seen: std.StringHashMap(void) = .init(interp.allocator);
    defer seen.deinit();
    const maps = cmMaps(self) orelse return out;
    for (maps.items.items) |m| {
        const pairs = dictLikePairs(m) orelse continue;
        for (pairs) |p| {
            if (p.key != .str) continue;
            const key = p.key.str.bytes;
            if (seen.contains(key)) continue;
            try seen.put(key, {});
            try out.append(interp.allocator, p.key);
        }
    }
    return out;
}

fn cmLen(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const keys = try cmCollectKeys(interp, self);
    return Value{ .small_int = @intCast(keys.items.items.len) };
}

fn cmIter(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const keys = try cmCollectKeys(interp, self);
    const Iter = @import("../object/iter.zig").Iter;
    const it = try Iter.init(interp.allocator, .{ .list = keys });
    return Value{ .iter = it };
}

fn cmKeys(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const keys = try cmCollectKeys(interp, self);
    return Value{ .list = keys };
}

fn cmValues(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const out = try List.init(interp.allocator);
    const maps = cmMaps(self) orelse return Value{ .list = out };
    var seen: std.StringHashMap(void) = .init(interp.allocator);
    defer seen.deinit();
    for (maps.items.items) |m| {
        const pairs = dictLikePairs(m) orelse continue;
        for (pairs) |p| {
            if (p.key != .str) continue;
            const key = p.key.str.bytes;
            if (seen.contains(key)) continue;
            try seen.put(key, {});
            try out.append(interp.allocator, p.value);
        }
    }
    return Value{ .list = out };
}

fn cmItems(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const out = try List.init(interp.allocator);
    const maps = cmMaps(self) orelse return Value{ .list = out };
    var seen: std.StringHashMap(void) = .init(interp.allocator);
    defer seen.deinit();
    for (maps.items.items) |m| {
        const pairs = dictLikePairs(m) orelse continue;
        for (pairs) |p| {
            if (p.key != .str) continue;
            const key = p.key.str.bytes;
            if (seen.contains(key)) continue;
            try seen.put(key, {});
            const t = try Tuple.init(interp.allocator, 2);
            t.items[0] = p.key;
            t.items[1] = p.value;
            try out.append(interp.allocator, Value{ .tuple = t });
        }
    }
    return Value{ .list = out };
}

fn cmGet(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    if (args.len < 2 or args[1] != .str) return error.TypeError;
    const key = args[1].str.bytes;
    const default_v: Value = if (args.len >= 3) args[2] else Value.none;
    const maps = cmMaps(self) orelse return default_v;
    for (maps.items.items) |m| {
        if (dictLikeGet(m, key)) |v| return v;
    }
    return default_v;
}

fn cmParents(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const maps = cmMaps(self) orelse return error.TypeError;
    const new_maps = try List.init(interp.allocator);
    if (maps.items.items.len > 1) {
        for (maps.items.items[1..]) |m| try new_maps.append(interp.allocator, m);
    }
    if (new_maps.items.items.len == 0) {
        try new_maps.append(interp.allocator, Value{ .dict = try Dict.init(interp.allocator) });
    }
    const new_inst = try Instance.init(interp.allocator, interp.collections_chainmap_class.?);
    try new_inst.dict.setStr(interp.allocator, "maps", Value{ .list = new_maps });
    return Value{ .instance = new_inst };
}

fn cmNewChild(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const maps = cmMaps(self) orelse return error.TypeError;
    const head: Value = if (args.len >= 2) args[1] else Value{ .dict = try Dict.init(interp.allocator) };
    const child = try Instance.init(interp.allocator, interp.collections_chainmap_class.?);
    const new_maps = try List.init(interp.allocator);
    try new_maps.append(interp.allocator, head);
    for (maps.items.items) |m| try new_maps.append(interp.allocator, m);
    try child.dict.setStr(interp.allocator, "maps", Value{ .list = new_maps });
    return Value{ .instance = child };
}

// ============== UserDict ==============

fn udData(self: *Instance) ?*Dict {
    const v = self.dict.getStr("data") orelse return null;
    if (v != .dict) return null;
    return v.dict;
}

fn udInit(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const d = try Dict.init(interp.allocator);
    if (args.len >= 2) {
        const src = args[1];
        switch (src) {
            .dict => |sd| for (sd.pairs.items) |p| try d.setKey(interp.allocator, p.key, p.value),
            else => {
                try interp.typeError("UserDict expects a dict");
                return error.TypeError;
            },
        }
    }
    try self.dict.setStr(interp.allocator, "data", Value{ .dict = d });
    return Value.none;
}

fn udGetitem(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2 or args[1] != .str) return error.TypeError;
    const d = udData(self) orelse return error.TypeError;
    if (d.getStr(args[1].str.bytes)) |v| return v;
    try interp.raisePy("KeyError", args[1].str.bytes);
    return error.PyException;
}

fn udSetitem(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 3 or args[1] != .str) return error.TypeError;
    const d = udData(self) orelse return error.TypeError;
    try d.setStr(interp.allocator, args[1].str.bytes, args[2]);
    return Value.none;
}

fn udDelitem(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2 or args[1] != .str) return error.TypeError;
    const d = udData(self) orelse return error.TypeError;
    if (!d.delete(args[1].str.bytes)) {
        try interp.raisePy("KeyError", args[1].str.bytes);
        return error.PyException;
    }
    return Value.none;
}

fn udContains(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2 or args[1] != .str) return error.TypeError;
    const d = udData(self) orelse return error.TypeError;
    return Value{ .boolean = d.getStr(args[1].str.bytes) != null };
}

fn udLen(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    const d = udData(self) orelse return error.TypeError;
    return Value{ .small_int = @intCast(d.pairs.items.len) };
}

fn udIter(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const d = udData(self) orelse return error.TypeError;
    const lst = try List.init(interp.allocator);
    for (d.pairs.items) |p| try lst.append(interp.allocator, p.key);
    const Iter = @import("../object/iter.zig").Iter;
    const it = try Iter.init(interp.allocator, .{ .list = lst });
    return Value{ .iter = it };
}

fn udKeys(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const d = udData(self) orelse return error.TypeError;
    const out = try List.init(interp.allocator);
    for (d.pairs.items) |p| try out.append(interp.allocator, p.key);
    return Value{ .list = out };
}

fn udValues(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const d = udData(self) orelse return error.TypeError;
    const out = try List.init(interp.allocator);
    for (d.pairs.items) |p| try out.append(interp.allocator, p.value);
    return Value{ .list = out };
}

fn udItems(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const d = udData(self) orelse return error.TypeError;
    const out = try List.init(interp.allocator);
    for (d.pairs.items) |p| {
        const t = try Tuple.init(interp.allocator, 2);
        t.items[0] = p.key;
        t.items[1] = p.value;
        try out.append(interp.allocator, Value{ .tuple = t });
    }
    return Value{ .list = out };
}

fn udCopy(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const d = udData(self) orelse return error.TypeError;
    const new_inst = try Instance.init(interp.allocator, interp.collections_userdict_class.?);
    const nd = try Dict.init(interp.allocator);
    for (d.pairs.items) |p| try nd.setKey(interp.allocator, p.key, p.value);
    try new_inst.dict.setStr(interp.allocator, "data", Value{ .dict = nd });
    return Value{ .instance = new_inst };
}

fn udGet(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    if (args.len < 2 or args[1] != .str) return error.TypeError;
    const default_v: Value = if (args.len >= 3) args[2] else Value.none;
    const d = udData(self) orelse return error.TypeError;
    return d.getStr(args[1].str.bytes) orelse default_v;
}

fn udPop(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len < 2 or args[1] != .str) return error.TypeError;
    const d = udData(self) orelse return error.TypeError;
    const key = args[1].str.bytes;
    if (d.getStr(key)) |v| {
        _ = d.delete(key);
        return v;
    }
    if (args.len >= 3) return args[2];
    try interp.raisePy("KeyError", key);
    return error.PyException;
}

fn udSetdefault(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len < 2 or args[1] != .str) return error.TypeError;
    const default_v: Value = if (args.len >= 3) args[2] else Value.none;
    const d = udData(self) orelse return error.TypeError;
    if (d.getStr(args[1].str.bytes)) |v| return v;
    try d.setStr(interp.allocator, args[1].str.bytes, default_v);
    return default_v;
}

fn udUpdate(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const d = udData(self) orelse return error.TypeError;
    if (args[1] != .dict) {
        try interp.typeError("UserDict.update expects dict");
        return error.TypeError;
    }
    for (args[1].dict.pairs.items) |p| try d.setKey(interp.allocator, p.key, p.value);
    return Value.none;
}

fn udClear(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const d = udData(self) orelse return error.TypeError;
    d.pairs.clearRetainingCapacity();
    d.keys.clearRetainingCapacity();
    _ = interp;
    return Value.none;
}

// ============== UserList ==============

fn ulData(self: *Instance) ?*List {
    const v = self.dict.getStr("data") orelse return null;
    if (v != .list) return null;
    return v.list;
}

fn ulInit(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const lst = try List.init(interp.allocator);
    if (args.len >= 2) {
        const seed = try builtins.materialize(interp, args[1]);
        for (seed.items.items) |x| try lst.append(interp.allocator, x);
    }
    try self.dict.setStr(interp.allocator, "data", Value{ .list = lst });
    return Value.none;
}

fn ulGetitem(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const lst = ulData(self) orelse return error.TypeError;
    return dispatch.subscript(interp, Value{ .list = lst }, args[1]);
}

fn ulSetitem(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 3 or args[1] != .small_int) return error.TypeError;
    const lst = ulData(self) orelse return error.TypeError;
    var idx = args[1].small_int;
    const n: i64 = @intCast(lst.items.items.len);
    if (idx < 0) idx += n;
    if (idx < 0 or idx >= n) {
        try interp.indexError("list assignment index out of range");
        return error.IndexError;
    }
    lst.items.items[@intCast(idx)] = args[2];
    return Value.none;
}

fn ulDelitem(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2 or args[1] != .small_int) return error.TypeError;
    const lst = ulData(self) orelse return error.TypeError;
    var idx = args[1].small_int;
    const n: i64 = @intCast(lst.items.items.len);
    if (idx < 0) idx += n;
    if (idx < 0 or idx >= n) {
        try interp.indexError("list deletion index out of range");
        return error.IndexError;
    }
    _ = lst.items.orderedRemove(@intCast(idx));
    return Value.none;
}

fn ulContains(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const lst = ulData(self) orelse return error.TypeError;
    for (lst.items.items) |x| if (Value.equals(x, args[1])) return Value{ .boolean = true };
    return Value{ .boolean = false };
}

fn ulLen(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    const lst = ulData(self) orelse return error.TypeError;
    return Value{ .small_int = @intCast(lst.items.items.len) };
}

fn ulIter(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const lst = ulData(self) orelse return error.TypeError;
    const Iter = @import("../object/iter.zig").Iter;
    const it = try Iter.init(interp.allocator, .{ .list = lst });
    return Value{ .iter = it };
}

fn ulAdd(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const lst = ulData(self) orelse return error.TypeError;
    const seed = try builtins.materialize(interp, args[1]);
    const out = try List.init(interp.allocator);
    for (lst.items.items) |x| try out.append(interp.allocator, x);
    for (seed.items.items) |x| try out.append(interp.allocator, x);
    const new_inst = try Instance.init(interp.allocator, interp.collections_userlist_class.?);
    try new_inst.dict.setStr(interp.allocator, "data", Value{ .list = out });
    return Value{ .instance = new_inst };
}

fn ulAppend(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const lst = ulData(self) orelse return error.TypeError;
    try lst.append(interp.allocator, args[1]);
    return Value.none;
}

fn ulSort(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    const lst = ulData(self) orelse return error.TypeError;
    std.sort.block(Value, lst.items.items, {}, struct {
        fn lt(_: void, a: Value, b: Value) bool {
            const o = a.order(b) orelse return false;
            return o == .lt;
        }
    }.lt);
    return Value.none;
}

fn ulCount(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const lst = ulData(self) orelse return error.TypeError;
    var n: i64 = 0;
    for (lst.items.items) |x| if (Value.equals(x, args[1])) {
        n += 1;
    };
    return Value{ .small_int = n };
}

fn ulIndex(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const lst = ulData(self) orelse return error.TypeError;
    for (lst.items.items, 0..) |x, i| {
        if (Value.equals(x, args[1])) return Value{ .small_int = @intCast(i) };
    }
    try interp.raisePy("ValueError", "list.index(x): x not in list");
    return error.PyException;
}

fn ulReverse(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    const lst = ulData(self) orelse return error.TypeError;
    std.mem.reverse(Value, lst.items.items);
    return Value.none;
}

fn ulInsert(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 3 or args[1] != .small_int) return error.TypeError;
    const lst = ulData(self) orelse return error.TypeError;
    var idx = args[1].small_int;
    const n: i64 = @intCast(lst.items.items.len);
    if (idx < 0) idx += n;
    if (idx < 0) idx = 0;
    if (idx > n) idx = n;
    try lst.items.insert(interp.allocator, @intCast(idx), args[2]);
    return Value.none;
}

fn ulRemove(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const lst = ulData(self) orelse return error.TypeError;
    for (lst.items.items, 0..) |x, i| {
        if (Value.equals(x, args[1])) {
            _ = lst.items.orderedRemove(i);
            return Value.none;
        }
    }
    try interp.raisePy("ValueError", "list.remove(x): x not in list");
    return error.PyException;
}

fn ulCopy(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const lst = ulData(self) orelse return error.TypeError;
    const new_inst = try Instance.init(interp.allocator, interp.collections_userlist_class.?);
    const nl = try List.init(interp.allocator);
    for (lst.items.items) |x| try nl.append(interp.allocator, x);
    try new_inst.dict.setStr(interp.allocator, "data", Value{ .list = nl });
    return Value{ .instance = new_inst };
}

fn ulExtend(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const lst = ulData(self) orelse return error.TypeError;
    const seed = try builtins.materialize(interp, args[1]);
    for (seed.items.items) |x| try lst.append(interp.allocator, x);
    return Value.none;
}

fn ulPop(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const lst = ulData(self) orelse return error.TypeError;
    var idx: i64 = -1;
    if (args.len >= 2 and args[1] == .small_int) idx = args[1].small_int;
    const n: i64 = @intCast(lst.items.items.len);
    if (n == 0) {
        try interp.raisePy("IndexError", "pop from empty list");
        return error.PyException;
    }
    if (idx < 0) idx += n;
    if (idx < 0 or idx >= n) {
        try interp.indexError("pop index out of range");
        return error.IndexError;
    }
    return lst.items.orderedRemove(@intCast(idx));
}

fn ulClear(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    const lst = ulData(self) orelse return error.TypeError;
    lst.items.clearRetainingCapacity();
    return Value.none;
}

// ============== UserString ==============

fn usData(self: *Instance) ?[]const u8 {
    const v = self.dict.getStr("data") orelse return null;
    if (v != .str) return null;
    return v.str.bytes;
}

fn usOther(v: Value) ?[]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        .instance => |inst| blk: {
            const dv = inst.dict.getStr("data") orelse break :blk null;
            if (dv != .str) break :blk null;
            break :blk dv.str.bytes;
        },
        else => null,
    };
}

fn usMakeNew(interp: *Interp, bytes: []const u8) !Value {
    const inst = try Instance.init(interp.allocator, interp.collections_userstring_class.?);
    const s = try Str.init(interp.allocator, bytes);
    try inst.dict.setStr(interp.allocator, "data", Value{ .str = s });
    return Value{ .instance = inst };
}

fn usInit(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len < 2) {
        const s = try Str.init(interp.allocator, "");
        try self.dict.setStr(interp.allocator, "data", Value{ .str = s });
        return Value.none;
    }
    const bytes = usOther(args[1]) orelse {
        try interp.typeError("UserString expects str");
        return error.TypeError;
    };
    const s = try Str.init(interp.allocator, bytes);
    try self.dict.setStr(interp.allocator, "data", Value{ .str = s });
    return Value.none;
}

fn usStr(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const data = usData(self) orelse return error.TypeError;
    const s = try Str.init(interp.allocator, data);
    return Value{ .str = s };
}

fn usGetitem(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const data = usData(self) orelse return error.TypeError;
    return dispatch.subscript(interp, Value{ .str = try Str.init(interp.allocator, data) }, args[1]);
}

fn usLen(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    const data = usData(self) orelse return error.TypeError;
    return Value{ .small_int = @intCast(data.len) };
}

fn usContains(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const data = usData(self) orelse return error.TypeError;
    const needle = usOther(args[1]) orelse {
        if (args[1] != .str) return error.TypeError;
        return Value{ .boolean = std.mem.indexOf(u8, data, args[1].str.bytes) != null };
    };
    return Value{ .boolean = std.mem.indexOf(u8, data, needle) != null };
}

fn usAdd(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const data = usData(self) orelse return error.TypeError;
    const other = usOther(args[1]) orelse return error.TypeError;
    const buf = try interp.allocator.alloc(u8, data.len + other.len);
    @memcpy(buf[0..data.len], data);
    @memcpy(buf[data.len..], other);
    const inst = try Instance.init(interp.allocator, interp.collections_userstring_class.?);
    const s = try Str.fromOwnedSlice(interp.allocator, buf);
    try inst.dict.setStr(interp.allocator, "data", Value{ .str = s });
    return Value{ .instance = inst };
}

fn usLt(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const data = usData(self) orelse return error.TypeError;
    const other = usOther(args[1]) orelse return Value.not_implemented;
    return Value{ .boolean = std.mem.order(u8, data, other) == .lt };
}

fn usEq(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const data = usData(self) orelse return error.TypeError;
    const other = usOther(args[1]) orelse return Value{ .boolean = false };
    return Value{ .boolean = std.mem.eql(u8, data, other) };
}

fn usUpper(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const data = usData(self) orelse return error.TypeError;
    const buf = try interp.allocator.alloc(u8, data.len);
    for (data, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return usMakeNew(interp, buf);
}

fn usLower(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const data = usData(self) orelse return error.TypeError;
    const buf = try interp.allocator.alloc(u8, data.len);
    for (data, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return usMakeNew(interp, buf);
}

fn usStrip(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const data = usData(self) orelse return error.TypeError;
    const trimmed = std.mem.trim(u8, data, " \t\n\r\x0b\x0c");
    return usMakeNew(interp, trimmed);
}

fn usReplace(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 3) return error.TypeError;
    const data = usData(self) orelse return error.TypeError;
    const old_b = usOther(args[1]) orelse return error.TypeError;
    const new_b = usOther(args[2]) orelse return error.TypeError;
    if (old_b.len == 0) return usMakeNew(interp, data);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < data.len) {
        if (i + old_b.len <= data.len and std.mem.eql(u8, data[i .. i + old_b.len], old_b)) {
            try out.appendSlice(interp.allocator, new_b);
            i += old_b.len;
        } else {
            try out.append(interp.allocator, data[i]);
            i += 1;
        }
    }
    return usMakeNew(interp, out.items);
}

fn usStartswith(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const data = usData(self) orelse return error.TypeError;
    const prefix = usOther(args[1]) orelse return error.TypeError;
    return Value{ .boolean = std.mem.startsWith(u8, data, prefix) };
}

fn usEndswith(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const data = usData(self) orelse return error.TypeError;
    const suffix = usOther(args[1]) orelse return error.TypeError;
    return Value{ .boolean = std.mem.endsWith(u8, data, suffix) };
}

fn usFind(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const data = usData(self) orelse return error.TypeError;
    const needle = usOther(args[1]) orelse return error.TypeError;
    if (std.mem.indexOf(u8, data, needle)) |i| return Value{ .small_int = @intCast(i) };
    return Value{ .small_int = -1 };
}

fn usSplit(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    const data = usData(self) orelse return error.TypeError;
    const out = try List.init(interp.allocator);
    if (args.len < 2) {
        var it = std.mem.tokenizeAny(u8, data, " \t\n\r\x0b\x0c");
        while (it.next()) |seg| {
            const s = try Str.init(interp.allocator, seg);
            try out.append(interp.allocator, Value{ .str = s });
        }
    } else {
        const sep = usOther(args[1]) orelse return error.TypeError;
        var it = std.mem.splitSequence(u8, data, sep);
        while (it.next()) |seg| {
            const s = try Str.init(interp.allocator, seg);
            try out.append(interp.allocator, Value{ .str = s });
        }
    }
    return Value{ .list = out };
}

fn usJoin(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = try instSelf(opaque_interp, args);
    if (args.len != 2) return error.TypeError;
    const data = usData(self) orelse return error.TypeError;
    const lst = try builtins.materialize(interp, args[1]);
    var out: std.ArrayList(u8) = .empty;
    for (lst.items.items, 0..) |x, i| {
        if (i != 0) try out.appendSlice(interp.allocator, data);
        const piece = usOther(x) orelse return error.TypeError;
        try out.appendSlice(interp.allocator, piece);
    }
    return usMakeNew(interp, out.items);
}
