//! Method table for `range` (Iter with .range kind).

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Iter = @import("../object/iter.zig").Iter;
const Interp = @import("interp.zig").Interp;

fn asInt(v: Value) ?i64 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| if (b) @as(i64, 1) else @as(i64, 0),
        else => null,
    };
}

fn countImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args[0] != .iter) return Value{ .small_int = 0 };
    const r = switch (args[0].iter.kind) {
        .range => |r| r,
        else => return Value{ .small_int = 0 },
    };
    const target = asInt(args[1]) orelse return Value{ .small_int = 0 };
    if (Iter.rangeContains(r, target)) return Value{ .small_int = 1 };
    return Value{ .small_int = 0 };
}

fn indexImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args[0] != .iter) {
        try interp.raisePy("ValueError", "not in range");
        return error.PyException;
    }
    const r = switch (args[0].iter.kind) {
        .range => |rr| rr,
        else => {
            try interp.raisePy("ValueError", "not in range");
            return error.PyException;
        },
    };
    const target = asInt(args[1]) orelse {
        try interp.raisePy("ValueError", "not in range");
        return error.PyException;
    };
    if (!Iter.rangeContains(r, target)) {
        try interp.raisePy("ValueError", "not in range");
        return error.PyException;
    }
    const idx = if (r.step > 0)
        @divTrunc(target - r.start, r.step)
    else
        @divTrunc(r.start - target, -r.step);
    return Value{ .small_int = idx };
}

var count_entry: BuiltinFn = .{ .name = "count", .func = countImpl };
var index_entry: BuiltinFn = .{ .name = "index", .func = indexImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "count")) return &count_entry;
    if (std.mem.eql(u8, name, "index")) return &index_entry;
    return null;
}
