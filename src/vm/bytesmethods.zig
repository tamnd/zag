//! Method table for `bytes`. Implementation lives in `bytesops`,
//! shared with `bytearraymethods`.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const ops = @import("bytesops.zig");
const Interp = @import("interp.zig").Interp;

fn bridge(comptime f: fn (*Interp, []const Value) anyerror!Value) fn (*anyopaque, []const Value) anyerror!Value {
    return struct {
        fn call(p: *anyopaque, args: []const Value) anyerror!Value {
            const interp: *Interp = @ptrCast(@alignCast(p));
            return f(interp, args);
        }
    }.call;
}

var hex_entry: BuiltinFn = .{ .name = "hex", .func = bridge(ops.hexImpl) };
var join_entry: BuiltinFn = .{ .name = "join", .func = bridge(ops.joinImpl) };
var strip_entry: BuiltinFn = .{ .name = "strip", .func = bridge(ops.stripImpl) };
var lstrip_entry: BuiltinFn = .{ .name = "lstrip", .func = bridge(ops.lstripImpl) };
var rstrip_entry: BuiltinFn = .{ .name = "rstrip", .func = bridge(ops.rstripImpl) };
var upper_entry: BuiltinFn = .{ .name = "upper", .func = bridge(ops.upperImpl) };
var lower_entry: BuiltinFn = .{ .name = "lower", .func = bridge(ops.lowerImpl) };
var center_entry: BuiltinFn = .{ .name = "center", .func = bridge(ops.centerImpl) };
var ljust_entry: BuiltinFn = .{ .name = "ljust", .func = bridge(ops.ljustImpl) };
var rjust_entry: BuiltinFn = .{ .name = "rjust", .func = bridge(ops.rjustImpl) };
var zfill_entry: BuiltinFn = .{ .name = "zfill", .func = bridge(ops.zfillImpl) };
var count_entry: BuiltinFn = .{ .name = "count", .func = bridge(ops.countImpl) };
var find_entry: BuiltinFn = .{ .name = "find", .func = bridge(ops.findImpl) };
var rfind_entry: BuiltinFn = .{ .name = "rfind", .func = bridge(ops.rfindImpl) };
var index_entry: BuiltinFn = .{ .name = "index", .func = bridge(ops.indexImpl) };
var startswith_entry: BuiltinFn = .{ .name = "startswith", .func = bridge(ops.startswithImpl) };
var endswith_entry: BuiltinFn = .{ .name = "endswith", .func = bridge(ops.endswithImpl) };
var replace_entry: BuiltinFn = .{ .name = "replace", .func = bridge(ops.replaceImpl) };
var split_entry: BuiltinFn = .{ .name = "split", .func = bridge(ops.splitImpl) };
var decode_entry: BuiltinFn = .{ .name = "decode", .func = bridge(ops.decodeImpl) };

pub var fromhex_entry: BuiltinFn = .{ .name = "fromhex", .func = ops.fromhexPos, .kw_func = ops.fromhexImpl };
pub var fromhex_bytearray_entry: BuiltinFn = .{ .name = "fromhex", .func = ops.fromhexBytearrayPos, .kw_func = ops.fromhexBytearrayImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "hex")) return &hex_entry;
    if (std.mem.eql(u8, name, "join")) return &join_entry;
    if (std.mem.eql(u8, name, "strip")) return &strip_entry;
    if (std.mem.eql(u8, name, "lstrip")) return &lstrip_entry;
    if (std.mem.eql(u8, name, "rstrip")) return &rstrip_entry;
    if (std.mem.eql(u8, name, "upper")) return &upper_entry;
    if (std.mem.eql(u8, name, "lower")) return &lower_entry;
    if (std.mem.eql(u8, name, "center")) return &center_entry;
    if (std.mem.eql(u8, name, "ljust")) return &ljust_entry;
    if (std.mem.eql(u8, name, "rjust")) return &rjust_entry;
    if (std.mem.eql(u8, name, "zfill")) return &zfill_entry;
    if (std.mem.eql(u8, name, "count")) return &count_entry;
    if (std.mem.eql(u8, name, "find")) return &find_entry;
    if (std.mem.eql(u8, name, "rfind")) return &rfind_entry;
    if (std.mem.eql(u8, name, "index")) return &index_entry;
    if (std.mem.eql(u8, name, "startswith")) return &startswith_entry;
    if (std.mem.eql(u8, name, "endswith")) return &endswith_entry;
    if (std.mem.eql(u8, name, "replace")) return &replace_entry;
    if (std.mem.eql(u8, name, "split")) return &split_entry;
    if (std.mem.eql(u8, name, "decode")) return &decode_entry;
    return null;
}
