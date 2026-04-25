//! Pinhole `copy` module. `copy.copy` does a shallow clone of the
//! container; `copy.deepcopy` recurses through containers. Immutables
//! (str, int, float, tuple-of-immutables, ...) short-circuit to
//! identity, which CPython also does for atomic types.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Dict = @import("../object/dict.zig").Dict;
const Set = @import("../object/set.zig").Set;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "copy");
    try reg(interp, m, "copy", copyFn);
    try reg(interp, m, "deepcopy", deepcopyFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn copyFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return shallow(interp, args[0]);
}

fn deepcopyFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return deep(interp, args[0]);
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
        .tuple => v,
        else => v,
    };
}

fn deep(interp: *Interp, v: Value) anyerror!Value {
    return switch (v) {
        .list => |l| blk: {
            const out = try List.init(interp.allocator);
            for (l.items.items) |x| try out.append(interp.allocator, try deep(interp, x));
            break :blk Value{ .list = out };
        },
        .dict => |d| blk: {
            const out = try Dict.init(interp.allocator);
            for (d.pairs.items) |pair| {
                try out.setKey(interp.allocator, try deep(interp, pair.key), try deep(interp, pair.value));
            }
            break :blk Value{ .dict = out };
        },
        .tuple => |t| blk: {
            const out = try Tuple.init(interp.allocator, t.items.len);
            for (t.items, 0..) |x, i| out.items[i] = try deep(interp, x);
            break :blk Value{ .tuple = out };
        },
        .set => |s| blk: {
            const out = if (s.frozen) try Set.initFrozen(interp.allocator) else try Set.init(interp.allocator);
            for (s.items.items) |x| try out.add(interp.allocator, try deep(interp, x));
            break :blk Value{ .set = out };
        },
        else => v,
    };
}
