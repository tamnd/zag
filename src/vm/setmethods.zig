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

var issubset_entry: BuiltinFn = .{ .name = "issubset", .func = issubsetImpl };
var issuperset_entry: BuiltinFn = .{ .name = "issuperset", .func = issupersetImpl };
var isdisjoint_entry: BuiltinFn = .{ .name = "isdisjoint", .func = isdisjointImpl };
var union_entry: BuiltinFn = .{ .name = "union", .func = unionImpl };
var intersection_entry: BuiltinFn = .{ .name = "intersection", .func = intersectionImpl };
var difference_entry: BuiltinFn = .{ .name = "difference", .func = differenceImpl };
var symdifference_entry: BuiltinFn = .{ .name = "symmetric_difference", .func = symdifferenceImpl };
var copy_entry: BuiltinFn = .{ .name = "copy", .func = copyImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "issubset")) return &issubset_entry;
    if (std.mem.eql(u8, name, "issuperset")) return &issuperset_entry;
    if (std.mem.eql(u8, name, "isdisjoint")) return &isdisjoint_entry;
    if (std.mem.eql(u8, name, "union")) return &union_entry;
    if (std.mem.eql(u8, name, "intersection")) return &intersection_entry;
    if (std.mem.eql(u8, name, "difference")) return &difference_entry;
    if (std.mem.eql(u8, name, "symmetric_difference")) return &symdifference_entry;
    if (std.mem.eql(u8, name, "copy")) return &copy_entry;
    return null;
}
