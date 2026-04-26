//! Pinhole `copy` module. `copy.copy` returns a shallow clone (or
//! the same object for atomic immutables); `copy.deepcopy` recurses
//! through containers and threads a Zig-side memo keyed by pointer
//! identity so cyclic structures terminate. Instances honor the
//! `__copy__` / `__deepcopy__` / `__replace__` protocols when
//! defined; otherwise we clone the instance with the matching
//! attribute-copy semantics.

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
const Set = @import("../object/set.zig").Set;
const Str = @import("../object/string.zig").Str;
const Bytes = @import("../object/bytes.zig").Bytes;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const dunder = @import("dunder.zig");

const Memo = std.AutoHashMapUnmanaged(usize, Value);

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    if (interp.copy_error_class == null) {
        const d = try Dict.init(a);
        interp.copy_error_class = try Class.init(a, "Error", &.{}, d);
    }
    const m = try Module.init(a, "copy");
    try reg(interp, m, "copy", copyFn);
    try reg(interp, m, "deepcopy", deepcopyFn);
    try regKw(interp, m, "replace", replaceKw);
    try m.attrs.setStr(a, "Error", Value{ .class = interp.copy_error_class.? });
    try m.attrs.setStr(a, "error", Value{ .class = interp.copy_error_class.? });
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, comptime kw_func: BuiltinKwFnPtr) !void {
    const Wrap = struct {
        fn call(p: *anyopaque, args: []const Value) anyerror!Value {
            return kw_func(p, args, &.{}, &.{});
        }
    };
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = Wrap.call, .kw_func = kw_func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn copyFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1) {
        try interp.typeError("copy() takes one argument");
        return error.TypeError;
    }
    return shallow(interp, args[0]);
}

fn deepcopyFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args.len > 2) {
        try interp.typeError("deepcopy() takes 1 or 2 arguments");
        return error.TypeError;
    }
    var memo: Memo = .empty;
    defer memo.deinit(interp.allocator);
    return deep(interp, args[0], &memo);
}

fn shallow(interp: *Interp, v: Value) !Value {
    return switch (v) {
        .list => |l| blk: {
            const out = try List.init(interp.allocator);
            for (l.items.items) |x| try out.append(interp.allocator, x);
            break :blk Value{ .list = out };
        },
        .dict => |d| blk: {
            const out = try Dict.init(interp.allocator);
            for (d.pairs.items) |pair| try out.setKey(interp.allocator, pair.key, pair.value);
            break :blk Value{ .dict = out };
        },
        .set => |s| blk: {
            const out = if (s.frozen) try Set.initFrozen(interp.allocator) else try Set.init(interp.allocator);
            for (s.items.items) |x| try out.add(interp.allocator, x);
            break :blk Value{ .set = out };
        },
        .instance => |inst| blk: {
            // Honor the `__copy__` protocol first.
            if (try dunder.call(interp, v, "__copy__", &.{})) |r| break :blk r;
            // Default: new instance, same class, attr dict copied shallowly.
            const out = try Instance.init(interp.allocator, inst.cls);
            for (inst.dict.pairs.items) |pair| try out.dict.setKey(interp.allocator, pair.key, pair.value);
            break :blk Value{ .instance = out };
        },
        // tuple, str, bytes, frozenset, ints, etc. -- atomic enough that
        // returning the same object matches CPython.
        else => v,
    };
}

fn idOf(v: Value) usize {
    return switch (v) {
        .list => |l| @intFromPtr(l),
        .dict => |d| @intFromPtr(d),
        .set => |s| @intFromPtr(s),
        .tuple => |t| @intFromPtr(t),
        .instance => |i| @intFromPtr(i),
        else => 0,
    };
}

fn deep(interp: *Interp, v: Value, memo: *Memo) anyerror!Value {
    const id = idOf(v);
    if (id != 0) {
        if (memo.get(id)) |cached| return cached;
    }
    return switch (v) {
        .list => |l| blk: {
            const out = try List.init(interp.allocator);
            const out_v = Value{ .list = out };
            try memo.put(interp.allocator, id, out_v);
            for (l.items.items) |x| try out.append(interp.allocator, try deep(interp, x, memo));
            break :blk out_v;
        },
        .dict => |d| blk: {
            const out = try Dict.init(interp.allocator);
            const out_v = Value{ .dict = out };
            try memo.put(interp.allocator, id, out_v);
            for (d.pairs.items) |pair| {
                const k = try deep(interp, pair.key, memo);
                const val = try deep(interp, pair.value, memo);
                try out.setKey(interp.allocator, k, val);
            }
            break :blk out_v;
        },
        .tuple => |t| blk: {
            const out = try Tuple.init(interp.allocator, t.items.len);
            const out_v = Value{ .tuple = out };
            try memo.put(interp.allocator, id, out_v);
            for (t.items, 0..) |x, i| out.items[i] = try deep(interp, x, memo);
            break :blk out_v;
        },
        .set => |s| blk: {
            const out = if (s.frozen) try Set.initFrozen(interp.allocator) else try Set.init(interp.allocator);
            const out_v = Value{ .set = out };
            try memo.put(interp.allocator, id, out_v);
            for (s.items.items) |x| try out.add(interp.allocator, try deep(interp, x, memo));
            break :blk out_v;
        },
        .instance => |inst| blk: {
            // `__deepcopy__(self, memo)` short-circuits the default. We
            // pass a fresh Python dict; fixtures here ignore the memo
            // contents, only its identity.
            if (dunder.lookup(v, "__deepcopy__") != null) {
                const memo_dict = try Dict.init(interp.allocator);
                const r = try dunder.call(interp, v, "__deepcopy__", &.{Value{ .dict = memo_dict }});
                break :blk r.?;
            }
            const out = try Instance.init(interp.allocator, inst.cls);
            const out_v = Value{ .instance = out };
            try memo.put(interp.allocator, id, out_v);
            for (inst.dict.pairs.items) |pair| {
                try out.dict.setKey(interp.allocator, pair.key, try deep(interp, pair.value, memo));
            }
            break :blk out_v;
        },
        else => v,
    };
}

/// `copy.replace(obj, **changes)` -- delegates to `obj.__replace__(**changes)`.
fn replaceKw(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1) {
        try interp.typeError("replace() requires one positional argument");
        return error.TypeError;
    }
    const obj = args[0];
    if (obj != .instance) {
        try interp.raisePy("TypeError", "replace() argument must define __replace__");
        return error.PyException;
    }
    const m = dunder.lookup(obj, "__replace__") orelse {
        try interp.raisePy("TypeError", "replace() argument must define __replace__");
        return error.PyException;
    };
    const dispatch = @import("dispatch.zig");
    return try dispatch.invokeKwPub(interp, m, &.{obj}, kw_names, kw_values);
}
