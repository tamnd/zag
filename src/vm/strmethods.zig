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
    const self = args[0].str.bytes;
    const list = try List.init(interp.allocator);

    // 1-arg form: split on the literal separator, keeping empty
    // pieces between consecutive separators (CPython semantics).
    if (args.len >= 2 and args[1] == .str) {
        const sep = args[1].str.bytes;
        if (sep.len == 0) {
            try interp.typeError("empty separator");
            return error.TypeError;
        }
        var i: usize = 0;
        while (i <= self.len) {
            const idx = std.mem.indexOfPos(u8, self, i, sep) orelse {
                const piece = try Str.init(interp.allocator, self[i..]);
                try list.append(interp.allocator, Value{ .str = piece });
                break;
            };
            const piece = try Str.init(interp.allocator, self[i..idx]);
            try list.append(interp.allocator, Value{ .str = piece });
            i = idx + sep.len;
        }
        return Value{ .list = list };
    }

    // No-arg form: split on runs of ASCII whitespace, drop empties.
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
    const dispatch = @import("dispatch.zig");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);

    var first = true;
    const append = struct {
        fn f(allocator: std.mem.Allocator, b: *std.ArrayList(u8), is_first: *bool, sep_b: []const u8, item: Value, interp_ref: *Interp) !void {
            if (item != .str) {
                try interp_ref.typeError("can only join an iterable of strings");
                return error.TypeError;
            }
            if (!is_first.*) try b.appendSlice(allocator, sep_b);
            try b.appendSlice(allocator, item.str.bytes);
            is_first.* = false;
        }
    }.f;

    switch (args[1]) {
        .list => |l| for (l.items.items) |it| try append(interp.allocator, &buf, &first, sep, it, interp),
        .tuple => |t| for (t.items) |it| try append(interp.allocator, &buf, &first, sep, it, interp),
        .set => |s| for (s.items.items) |it| try append(interp.allocator, &buf, &first, sep, it, interp),
        .iter, .generator, .enum_iter, .instance => {
            const iter_val = blk: {
                if (args[1] == .iter or args[1] == .generator) break :blk args[1];
                const it = try dispatch.makeIter(interp, args[1]);
                break :blk Value{ .iter = it };
            };
            while (try dispatch.iterStep(interp, iter_val)) |it| {
                try append(interp.allocator, &buf, &first, sep, it, interp);
            }
        },
        .str => |s| {
            for (s.bytes) |b| {
                if (!first) try buf.appendSlice(interp.allocator, sep);
                try buf.append(interp.allocator, b);
                first = false;
            }
        },
        else => {
            try interp.typeError("can only join an iterable of strings");
            return error.TypeError;
        },
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

fn countImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const self = args[0].str.bytes;
    const sub = args[1].str.bytes;
    if (sub.len == 0) return Value{ .small_int = @intCast(self.len + 1) };
    var n: i64 = 0;
    var i: usize = 0;
    while (i + sub.len <= self.len) {
        if (std.mem.eql(u8, self[i .. i + sub.len], sub)) {
            n += 1;
            i += sub.len;
        } else i += 1;
    }
    return Value{ .small_int = n };
}

var count_entry: BuiltinFn = .{ .name = "count", .func = countImpl };
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
    if (std.mem.eql(u8, name, "count")) return &count_entry;
    return null;
}
