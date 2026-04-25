//! Method table for `memoryview`. Same shape as bytearraymethods.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const Bytes = @import("../object/bytes.zig").Bytes;
const List = @import("../object/list.zig").List;

const Interp = @import("interp.zig").Interp;

fn tobytesImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const out = try Bytes.init(interp.allocator, args[0].memoryview.data());
    return Value{ .bytes = out };
}

fn tolistImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const out = try List.init(interp.allocator);
    for (args[0].memoryview.data()) |b| {
        try out.append(interp.allocator, Value{ .small_int = @intCast(b) });
    }
    return Value{ .list = out };
}

fn releaseImpl(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

var tobytes_entry: BuiltinFn = .{ .name = "tobytes", .func = tobytesImpl };
var tolist_entry: BuiltinFn = .{ .name = "tolist", .func = tolistImpl };
var release_entry: BuiltinFn = .{ .name = "release", .func = releaseImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "tobytes")) return &tobytes_entry;
    if (std.mem.eql(u8, name, "tolist")) return &tolist_entry;
    if (std.mem.eql(u8, name, "release")) return &release_entry;
    return null;
}
