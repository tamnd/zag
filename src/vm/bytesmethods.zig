//! Method table for `bytes`. Mirrors strmethods/bytearraymethods.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

fn decodeImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const s = try Str.init(interp.allocator, args[0].bytes.data);
    return Value{ .str = s };
}

var decode_entry: BuiltinFn = .{ .name = "decode", .func = decodeImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "decode")) return &decode_entry;
    return null;
}
