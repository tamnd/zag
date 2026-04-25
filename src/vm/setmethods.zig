//! Method table for `set` / `frozenset`. Same shape as listmethods:
//! each function takes (interp, args) with args[0] as self. The
//! algebra methods accept arbitrary iterables (CPython does too) and
//! preserve self's `frozen` flag in the result.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Interp = @import("interp.zig").Interp;
const Set = @import("../object/set.zig").Set;

fn materialize(interp: *Interp, v: Value) !*@import("../object/list.zig").List {
    return @import("builtins.zig").materialize(interp, v);
}

fn newLike(interp: *Interp, frozen: bool) !*Set {
    return if (frozen) Set.initFrozen(interp.allocator) else Set.init(interp.allocator);
}

fn issubsetImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].set;
    const other = try materialize(interp, args[1]);
    outer: for (self.items.items) |x| {
        for (other.items.items) |y| if (x.equals(y)) continue :outer;
        return Value{ .boolean = false };
    }
    return Value{ .boolean = true };
}

fn issupersetImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].set;
    const other = try materialize(interp, args[1]);
    outer: for (other.items.items) |x| {
        for (self.items.items) |y| if (x.equals(y)) continue :outer;
        return Value{ .boolean = false };
    }
    return Value{ .boolean = true };
}

fn isdisjointImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].set;
    const other = try materialize(interp, args[1]);
    for (self.items.items) |x| {
        for (other.items.items) |y| if (x.equals(y)) return Value{ .boolean = false };
    }
    return Value{ .boolean = true };
}

fn unionImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].set;
    const out = try newLike(interp, self.frozen);
    for (self.items.items) |x| try out.add(interp.allocator, x);
    for (args[1..]) |a| {
        const lst = try materialize(interp, a);
        for (lst.items.items) |x| try out.add(interp.allocator, x);
    }
    return Value{ .set = out };
}

fn intersectionImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].set;
    const out = try newLike(interp, self.frozen);
    for (self.items.items) |x| {
        var keep = true;
        for (args[1..]) |a| {
            const lst = try materialize(interp, a);
            var found = false;
            for (lst.items.items) |y| if (x.equals(y)) {
                found = true;
                break;
            };
            if (!found) {
                keep = false;
                break;
            }
        }
        if (keep) try out.add(interp.allocator, x);
    }
    return Value{ .set = out };
}

fn differenceImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].set;
    const out = try newLike(interp, self.frozen);
    for (self.items.items) |x| {
        var drop = false;
        for (args[1..]) |a| {
            const lst = try materialize(interp, a);
            for (lst.items.items) |y| if (x.equals(y)) {
                drop = true;
                break;
            };
            if (drop) break;
        }
        if (!drop) try out.add(interp.allocator, x);
    }
    return Value{ .set = out };
}

fn symdifferenceImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].set;
    const other = try materialize(interp, args[1]);
    const out = try newLike(interp, self.frozen);
    for (self.items.items) |x| {
        var found = false;
        for (other.items.items) |y| if (x.equals(y)) {
            found = true;
            break;
        };
        if (!found) try out.add(interp.allocator, x);
    }
    for (other.items.items) |x| {
        var found = false;
        for (self.items.items) |y| if (x.equals(y)) {
            found = true;
            break;
        };
        if (!found) try out.add(interp.allocator, x);
    }
    return Value{ .set = out };
}

fn addImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2 or args[0] != .set) {
        try interp.typeError("set.add() takes 1 argument");
        return error.TypeError;
    }
    if (args[0].set.frozen) {
        try interp.typeError("'frozenset' object has no attribute 'add'");
        return error.TypeError;
    }
    try args[0].set.add(interp.allocator, args[1]);
    return Value.none;
}

fn discardImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2 or args[0] != .set) {
        try interp.typeError("set.discard() takes 1 argument");
        return error.TypeError;
    }
    if (args[0].set.frozen) {
        try interp.typeError("'frozenset' object has no attribute 'discard'");
        return error.TypeError;
    }
    const s = args[0].set;
    for (s.items.items, 0..) |x, i| {
        if (x.equals(args[1])) {
            _ = s.items.orderedRemove(i);
            break;
        }
    }
    return Value.none;
}

fn removeImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2 or args[0] != .set) {
        try interp.typeError("set.remove() takes 1 argument");
        return error.TypeError;
    }
    if (args[0].set.frozen) {
        try interp.typeError("'frozenset' object has no attribute 'remove'");
        return error.TypeError;
    }
    const s = args[0].set;
    for (s.items.items, 0..) |x, i| {
        if (x.equals(args[1])) {
            _ = s.items.orderedRemove(i);
            return Value.none;
        }
    }
    try interp.raisePy("KeyError", "value not in set");
    return error.PyException;
}

fn copyImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].set;
    // CPython: frozenset.copy() returns self (immutable, so identity
    // is fine); set.copy() returns a fresh set. The fixture asserts
    // both via `is`.
    if (self.frozen) return args[0];
    const out = try Set.init(interp.allocator);
    for (self.items.items) |x| try out.add(interp.allocator, x);
    return Value{ .set = out };
}

fn popImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args[0].set.frozen) {
        try interp.typeError("'frozenset' object has no attribute 'pop'");
        return error.TypeError;
    }
    const s = args[0].set;
    if (s.items.items.len == 0) {
        try interp.raisePy("KeyError", "pop from an empty set");
        return error.PyException;
    }
    return s.items.orderedRemove(0);
}

fn clearImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args[0].set.frozen) {
        try interp.typeError("'frozenset' object has no attribute 'clear'");
        return error.TypeError;
    }
    args[0].set.items.clearRetainingCapacity();
    return Value.none;
}

fn updateImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].set;
    if (self.frozen) {
        try interp.typeError("'frozenset' object has no attribute 'update'");
        return error.TypeError;
    }
    for (args[1..]) |a| {
        const lst = try materialize(interp, a);
        for (lst.items.items) |x| try self.add(interp.allocator, x);
    }
    return Value.none;
}

fn intersectionUpdateImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].set;
    if (self.frozen) {
        try interp.typeError("'frozenset' object has no attribute 'intersection_update'");
        return error.TypeError;
    }
    var i: usize = 0;
    while (i < self.items.items.len) {
        const x = self.items.items[i];
        var keep = true;
        for (args[1..]) |a| {
            const lst = try materialize(interp, a);
            var found = false;
            for (lst.items.items) |y| if (x.equals(y)) {
                found = true;
                break;
            };
            if (!found) {
                keep = false;
                break;
            }
        }
        if (keep) i += 1 else _ = self.items.orderedRemove(i);
    }
    return Value.none;
}

fn differenceUpdateImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].set;
    if (self.frozen) {
        try interp.typeError("'frozenset' object has no attribute 'difference_update'");
        return error.TypeError;
    }
    for (args[1..]) |a| {
        const lst = try materialize(interp, a);
        for (lst.items.items) |x| {
            var i: usize = 0;
            while (i < self.items.items.len) {
                if (self.items.items[i].equals(x)) {
                    _ = self.items.orderedRemove(i);
                } else i += 1;
            }
        }
    }
    return Value.none;
}

fn symdifferenceUpdateImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].set;
    if (self.frozen) {
        try interp.typeError("'frozenset' object has no attribute 'symmetric_difference_update'");
        return error.TypeError;
    }
    const lst = try materialize(interp, args[1]);
    for (lst.items.items) |x| {
        var found_at: ?usize = null;
        for (self.items.items, 0..) |y, i| if (y.equals(x)) {
            found_at = i;
            break;
        };
        if (found_at) |idx| {
            _ = self.items.orderedRemove(idx);
        } else try self.add(interp.allocator, x);
    }
    return Value.none;
}

var issubset_entry: BuiltinFn = .{ .name = "issubset", .func = issubsetImpl };
var issuperset_entry: BuiltinFn = .{ .name = "issuperset", .func = issupersetImpl };
var isdisjoint_entry: BuiltinFn = .{ .name = "isdisjoint", .func = isdisjointImpl };
var union_entry: BuiltinFn = .{ .name = "union", .func = unionImpl };
var intersection_entry: BuiltinFn = .{ .name = "intersection", .func = intersectionImpl };
var difference_entry: BuiltinFn = .{ .name = "difference", .func = differenceImpl };
var symdifference_entry: BuiltinFn = .{ .name = "symmetric_difference", .func = symdifferenceImpl };
var copy_entry: BuiltinFn = .{ .name = "copy", .func = copyImpl };
var add_entry: BuiltinFn = .{ .name = "add", .func = addImpl };
var discard_entry: BuiltinFn = .{ .name = "discard", .func = discardImpl };
var remove_entry: BuiltinFn = .{ .name = "remove", .func = removeImpl };
var pop_entry: BuiltinFn = .{ .name = "pop", .func = popImpl };
var clear_entry: BuiltinFn = .{ .name = "clear", .func = clearImpl };
var update_entry: BuiltinFn = .{ .name = "update", .func = updateImpl };
var intersection_update_entry: BuiltinFn = .{ .name = "intersection_update", .func = intersectionUpdateImpl };
var difference_update_entry: BuiltinFn = .{ .name = "difference_update", .func = differenceUpdateImpl };
var symdifference_update_entry: BuiltinFn = .{ .name = "symmetric_difference_update", .func = symdifferenceUpdateImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "issubset")) return &issubset_entry;
    if (std.mem.eql(u8, name, "issuperset")) return &issuperset_entry;
    if (std.mem.eql(u8, name, "isdisjoint")) return &isdisjoint_entry;
    if (std.mem.eql(u8, name, "union")) return &union_entry;
    if (std.mem.eql(u8, name, "intersection")) return &intersection_entry;
    if (std.mem.eql(u8, name, "difference")) return &difference_entry;
    if (std.mem.eql(u8, name, "symmetric_difference")) return &symdifference_entry;
    if (std.mem.eql(u8, name, "copy")) return &copy_entry;
    if (std.mem.eql(u8, name, "add")) return &add_entry;
    if (std.mem.eql(u8, name, "discard")) return &discard_entry;
    if (std.mem.eql(u8, name, "remove")) return &remove_entry;
    if (std.mem.eql(u8, name, "pop")) return &pop_entry;
    if (std.mem.eql(u8, name, "clear")) return &clear_entry;
    if (std.mem.eql(u8, name, "update")) return &update_entry;
    if (std.mem.eql(u8, name, "intersection_update")) return &intersection_update_entry;
    if (std.mem.eql(u8, name, "difference_update")) return &difference_update_entry;
    if (std.mem.eql(u8, name, "symmetric_difference_update")) return &symdifference_update_entry;
    return null;
}
