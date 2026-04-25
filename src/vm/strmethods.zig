//! Method table for `str`. LOAD_ATTR's method-form path looks up
//! the name here and pushes `(method, self)` so CALL's existing
//! bound-method branch threads `self` in as `args[0]`.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Str = @import("../object/string.zig").Str;
const List = @import("../object/list.zig").List;
const Interp = @import("interp.zig").Interp;

pub const Entry = struct { name: []const u8, fn_ptr: *BuiltinFn };

fn ascii_upper(allocator: std.mem.Allocator, in: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, in.len);
    for (in, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}

fn upperImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str;
    const upper = try ascii_upper(interp.allocator, self.bytes);
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, upper) };
}

fn replaceImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const old = args[1].str.bytes;
    const new = args[2].str.bytes;

    if (old.len == 0) {
        return Value{ .str = try Str.init(interp.allocator, self) };
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);

    var i: usize = 0;
    while (i < self.len) {
        if (i + old.len <= self.len and std.mem.eql(u8, self[i .. i + old.len], old)) {
            try buf.appendSlice(interp.allocator, new);
            i += old.len;
        } else {
            try buf.append(interp.allocator, self[i]);
            i += 1;
        }
    }

    const owned = try buf.toOwnedSlice(interp.allocator);
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, owned) };
}

fn splitImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    // No-arg form only: split on runs of ASCII whitespace, drop empties.
    const self = args[0].str.bytes;
    const list = try List.init(interp.allocator);

    var i: usize = 0;
    while (i < self.len) {
        while (i < self.len and std.ascii.isWhitespace(self[i])) : (i += 1) {}
        const start = i;
        while (i < self.len and !std.ascii.isWhitespace(self[i])) : (i += 1) {}
        if (i > start) {
            const piece = try Str.init(interp.allocator, self[start..i]);
            try list.append(interp.allocator, Value{ .str = piece });
        }
    }
    return Value{ .list = list };
}

fn joinImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const sep = args[0].str.bytes;
    const items = switch (args[1]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => {
            try interp.typeError("can only join an iterable of strings");
            return error.TypeError;
        },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);
    for (items, 0..) |it, idx| {
        if (idx != 0) try buf.appendSlice(interp.allocator, sep);
        switch (it) {
            .str => |s| try buf.appendSlice(interp.allocator, s.bytes),
            else => {
                try interp.typeError("sequence item: expected str");
                return error.TypeError;
            },
        }
    }
    const owned = try buf.toOwnedSlice(interp.allocator);
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, owned) };
}

fn startsWithImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const self = args[0].str.bytes;
    const prefix = args[1].str.bytes;
    return Value{ .boolean = std.mem.startsWith(u8, self, prefix) };
}

fn endsWithImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const self = args[0].str.bytes;
    const suffix = args[1].str.bytes;
    return Value{ .boolean = std.mem.endsWith(u8, self, suffix) };
}

var upper_entry: BuiltinFn = .{ .name = "upper", .func = upperImpl };
var replace_entry: BuiltinFn = .{ .name = "replace", .func = replaceImpl };
var split_entry: BuiltinFn = .{ .name = "split", .func = splitImpl };
var join_entry: BuiltinFn = .{ .name = "join", .func = joinImpl };
var startswith_entry: BuiltinFn = .{ .name = "startswith", .func = startsWithImpl };
var endswith_entry: BuiltinFn = .{ .name = "endswith", .func = endsWithImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "upper")) return &upper_entry;
    if (std.mem.eql(u8, name, "replace")) return &replace_entry;
    if (std.mem.eql(u8, name, "split")) return &split_entry;
    if (std.mem.eql(u8, name, "join")) return &join_entry;
    if (std.mem.eql(u8, name, "startswith")) return &startswith_entry;
    if (std.mem.eql(u8, name, "endswith")) return &endswith_entry;
    return null;
}
