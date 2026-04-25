//! Method table for `str`. LOAD_ATTR's method-form path looks up
//! the name here and pushes `(method, self)` so CALL's existing
//! bound-method branch threads `self` in as `args[0]`.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Str = @import("../object/string.zig").Str;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Dict = @import("../object/dict.zig").Dict;
const Bytes = @import("../object/bytes.zig").Bytes;
const Interp = @import("interp.zig").Interp;

pub const Entry = struct { name: []const u8, fn_ptr: *BuiltinFn };

fn ascii_upper(allocator: std.mem.Allocator, in: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, in.len);
    for (in, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}

fn ascii_lower(allocator: std.mem.Allocator, in: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, in.len);
    for (in, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn upperImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const out = try ascii_upper(interp.allocator, args[0].str.bytes);
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, out) };
}

fn lowerImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const out = try ascii_lower(interp.allocator, args[0].str.bytes);
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, out) };
}

fn titleImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const in = args[0].str.bytes;
    const out = try interp.allocator.alloc(u8, in.len);
    var prev_alpha = false;
    for (in, 0..) |c, i| {
        if (std.ascii.isAlphabetic(c)) {
            out[i] = if (prev_alpha) std.ascii.toLower(c) else std.ascii.toUpper(c);
            prev_alpha = true;
        } else {
            out[i] = c;
            prev_alpha = false;
        }
    }
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, out) };
}

fn swapcaseImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const in = args[0].str.bytes;
    const out = try interp.allocator.alloc(u8, in.len);
    for (in, 0..) |c, i| {
        if (std.ascii.isLower(c)) out[i] = std.ascii.toUpper(c)
        else if (std.ascii.isUpper(c)) out[i] = std.ascii.toLower(c)
        else out[i] = c;
    }
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, out) };
}

fn capitalizeImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const in = args[0].str.bytes;
    const out = try interp.allocator.alloc(u8, in.len);
    for (in, 0..) |c, i| {
        out[i] = if (i == 0) std.ascii.toUpper(c) else std.ascii.toLower(c);
    }
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, out) };
}

// Predicates
fn isalphaImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const s = args[0].str.bytes;
    if (s.len == 0) return Value{ .boolean = false };
    for (s) |c| if (!std.ascii.isAlphabetic(c)) return Value{ .boolean = false };
    return Value{ .boolean = true };
}

fn isdigitImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const s = args[0].str.bytes;
    if (s.len == 0) return Value{ .boolean = false };
    for (s) |c| if (!std.ascii.isDigit(c)) return Value{ .boolean = false };
    return Value{ .boolean = true };
}

fn isalnumImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const s = args[0].str.bytes;
    if (s.len == 0) return Value{ .boolean = false };
    for (s) |c| if (!std.ascii.isAlphanumeric(c)) return Value{ .boolean = false };
    return Value{ .boolean = true };
}

fn isspaceImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const s = args[0].str.bytes;
    if (s.len == 0) return Value{ .boolean = false };
    for (s) |c| if (!std.ascii.isWhitespace(c)) return Value{ .boolean = false };
    return Value{ .boolean = true };
}

fn isupperImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const s = args[0].str.bytes;
    var any = false;
    for (s) |c| {
        if (std.ascii.isLower(c)) return Value{ .boolean = false };
        if (std.ascii.isUpper(c)) any = true;
    }
    return Value{ .boolean = any };
}

fn islowerImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const s = args[0].str.bytes;
    var any = false;
    for (s) |c| {
        if (std.ascii.isUpper(c)) return Value{ .boolean = false };
        if (std.ascii.isLower(c)) any = true;
    }
    return Value{ .boolean = any };
}

fn istitleImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const s = args[0].str.bytes;
    var any_letter = false;
    var prev_alpha = false;
    for (s) |c| {
        if (std.ascii.isAlphabetic(c)) {
            any_letter = true;
            if (prev_alpha) {
                if (std.ascii.isUpper(c)) return Value{ .boolean = false };
            } else {
                if (std.ascii.isLower(c)) return Value{ .boolean = false };
            }
            prev_alpha = true;
        } else prev_alpha = false;
    }
    return Value{ .boolean = any_letter };
}

fn isidentifierImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const s = args[0].str.bytes;
    if (s.len == 0) return Value{ .boolean = false };
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return Value{ .boolean = false };
    for (s[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return Value{ .boolean = false };
    }
    return Value{ .boolean = true };
}

fn isprintableImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const s = args[0].str.bytes;
    for (s) |c| if (!std.ascii.isPrint(c)) return Value{ .boolean = false };
    return Value{ .boolean = true };
}

fn isasciiImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const s = args[0].str.bytes;
    for (s) |c| if (c >= 0x80) return Value{ .boolean = false };
    return Value{ .boolean = true };
}

fn isdecimalImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    return isdigitImpl(undefined, args);
}

fn isnumericImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    return isdigitImpl(undefined, args);
}

fn isStripChar(c: u8, chars: ?[]const u8) bool {
    if (chars) |cs| return std.mem.indexOfScalar(u8, cs, c) != null;
    return std.ascii.isWhitespace(c);
}

fn stripImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str;
    const chars: ?[]const u8 = if (args.len >= 2 and args[1] == .str) args[1].str.bytes else null;
    var lo: usize = 0;
    var hi: usize = self.bytes.len;
    while (lo < hi and isStripChar(self.bytes[lo], chars)) lo += 1;
    while (hi > lo and isStripChar(self.bytes[hi - 1], chars)) hi -= 1;
    return Value{ .str = try Str.init(interp.allocator, self.bytes[lo..hi]) };
}

fn lstripImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str;
    const chars: ?[]const u8 = if (args.len >= 2 and args[1] == .str) args[1].str.bytes else null;
    var lo: usize = 0;
    while (lo < self.bytes.len and isStripChar(self.bytes[lo], chars)) lo += 1;
    return Value{ .str = try Str.init(interp.allocator, self.bytes[lo..]) };
}

fn rstripImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str;
    const chars: ?[]const u8 = if (args.len >= 2 and args[1] == .str) args[1].str.bytes else null;
    var hi: usize = self.bytes.len;
    while (hi > 0 and isStripChar(self.bytes[hi - 1], chars)) hi -= 1;
    return Value{ .str = try Str.init(interp.allocator, self.bytes[0..hi]) };
}

fn replaceImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const old = args[1].str.bytes;
    const new = args[2].str.bytes;
    const max_count: i64 = if (args.len >= 4 and args[3] == .small_int) args[3].small_int else -1;

    if (old.len == 0) {
        return Value{ .str = try Str.init(interp.allocator, self) };
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);

    var i: usize = 0;
    var done: i64 = 0;
    while (i < self.len) {
        if ((max_count < 0 or done < max_count) and i + old.len <= self.len and std.mem.eql(u8, self[i .. i + old.len], old)) {
            try buf.appendSlice(interp.allocator, new);
            i += old.len;
            done += 1;
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

    if (args.len >= 2 and args[1] == .str) {
        const sep = args[1].str.bytes;
        const max_split: i64 = if (args.len >= 3 and args[2] == .small_int) args[2].small_int else -1;
        if (sep.len == 0) {
            try interp.typeError("empty separator");
            return error.TypeError;
        }
        var i: usize = 0;
        var splits: i64 = 0;
        while (i <= self.len) {
            if (max_split >= 0 and splits >= max_split) {
                const piece = try Str.init(interp.allocator, self[i..]);
                try list.append(interp.allocator, Value{ .str = piece });
                break;
            }
            const idx = std.mem.indexOfPos(u8, self, i, sep) orelse {
                const piece = try Str.init(interp.allocator, self[i..]);
                try list.append(interp.allocator, Value{ .str = piece });
                break;
            };
            const piece = try Str.init(interp.allocator, self[i..idx]);
            try list.append(interp.allocator, Value{ .str = piece });
            i = idx + sep.len;
            splits += 1;
        }
        return Value{ .list = list };
    }

    const max_split: i64 = if (args.len >= 3 and args[2] == .small_int) args[2].small_int else -1;
    var i: usize = 0;
    var splits: i64 = 0;
    while (i < self.len) {
        while (i < self.len and std.ascii.isWhitespace(self[i])) : (i += 1) {}
        if (i >= self.len) break;
        if (max_split >= 0 and splits >= max_split) {
            const piece = try Str.init(interp.allocator, self[i..]);
            try list.append(interp.allocator, Value{ .str = piece });
            break;
        }
        const start = i;
        while (i < self.len and !std.ascii.isWhitespace(self[i])) : (i += 1) {}
        if (i > start) {
            const piece = try Str.init(interp.allocator, self[start..i]);
            try list.append(interp.allocator, Value{ .str = piece });
            splits += 1;
        }
    }
    return Value{ .list = list };
}

fn rsplitImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const list = try List.init(interp.allocator);

    if (args.len >= 2 and args[1] == .str) {
        const sep = args[1].str.bytes;
        const max_split: i64 = if (args.len >= 3 and args[2] == .small_int) args[2].small_int else -1;
        if (sep.len == 0) {
            try interp.typeError("empty separator");
            return error.TypeError;
        }
        // Collect right-to-left, then reverse.
        var pieces: std.ArrayList([]const u8) = .empty;
        defer pieces.deinit(interp.allocator);
        var end: usize = self.len;
        var splits: i64 = 0;
        while (true) {
            if (max_split >= 0 and splits >= max_split) {
                try pieces.append(interp.allocator, self[0..end]);
                break;
            }
            const idx = std.mem.lastIndexOf(u8, self[0..end], sep) orelse {
                try pieces.append(interp.allocator, self[0..end]);
                break;
            };
            try pieces.append(interp.allocator, self[idx + sep.len .. end]);
            end = idx;
            splits += 1;
        }
        var i: usize = pieces.items.len;
        while (i > 0) : (i -= 1) {
            const piece = try Str.init(interp.allocator, pieces.items[i - 1]);
            try list.append(interp.allocator, Value{ .str = piece });
        }
        return Value{ .list = list };
    }

    return splitImpl(interp_opaque, args);
}

fn splitlinesImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const list = try List.init(interp.allocator);
    var i: usize = 0;
    while (i < self.len) {
        const start = i;
        while (i < self.len and self[i] != '\n' and self[i] != '\r') : (i += 1) {}
        const piece = try Str.init(interp.allocator, self[start..i]);
        try list.append(interp.allocator, Value{ .str = piece });
        if (i < self.len) {
            if (self[i] == '\r' and i + 1 < self.len and self[i + 1] == '\n') i += 2
            else i += 1;
        }
    }
    return Value{ .list = list };
}

fn partitionImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const sep = args[1].str.bytes;
    const t = try Tuple.init(interp.allocator, 3);
    if (std.mem.indexOf(u8, self, sep)) |idx| {
        t.items[0] = Value{ .str = try Str.init(interp.allocator, self[0..idx]) };
        t.items[1] = Value{ .str = try Str.init(interp.allocator, sep) };
        t.items[2] = Value{ .str = try Str.init(interp.allocator, self[idx + sep.len ..]) };
    } else {
        t.items[0] = Value{ .str = try Str.init(interp.allocator, self) };
        t.items[1] = Value{ .str = try Str.init(interp.allocator, "") };
        t.items[2] = Value{ .str = try Str.init(interp.allocator, "") };
    }
    return Value{ .tuple = t };
}

fn rpartitionImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const sep = args[1].str.bytes;
    const t = try Tuple.init(interp.allocator, 3);
    if (std.mem.lastIndexOf(u8, self, sep)) |idx| {
        t.items[0] = Value{ .str = try Str.init(interp.allocator, self[0..idx]) };
        t.items[1] = Value{ .str = try Str.init(interp.allocator, sep) };
        t.items[2] = Value{ .str = try Str.init(interp.allocator, self[idx + sep.len ..]) };
    } else {
        t.items[0] = Value{ .str = try Str.init(interp.allocator, "") };
        t.items[1] = Value{ .str = try Str.init(interp.allocator, "") };
        t.items[2] = Value{ .str = try Str.init(interp.allocator, self) };
    }
    return Value{ .tuple = t };
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

fn matchSeqOrStr(prefix: Value, self: []const u8, comptime starts: bool) bool {
    return switch (prefix) {
        .str => |s| if (starts) std.mem.startsWith(u8, self, s.bytes) else std.mem.endsWith(u8, self, s.bytes),
        .tuple => |t| blk: {
            for (t.items) |it| {
                if (it == .str) {
                    const ok = if (starts) std.mem.startsWith(u8, self, it.str.bytes) else std.mem.endsWith(u8, self, it.str.bytes);
                    if (ok) break :blk true;
                }
            }
            break :blk false;
        },
        else => false,
    };
}

fn startsWithImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    return Value{ .boolean = matchSeqOrStr(args[1], args[0].str.bytes, true) };
}

fn endsWithImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    return Value{ .boolean = matchSeqOrStr(args[1], args[0].str.bytes, false) };
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

fn findImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const self = args[0].str.bytes;
    const sub = args[1].str.bytes;
    if (std.mem.indexOf(u8, self, sub)) |i| return Value{ .small_int = @intCast(i) };
    return Value{ .small_int = -1 };
}

fn rfindImpl(_: *anyopaque, args: []const Value) anyerror!Value {
    const self = args[0].str.bytes;
    const sub = args[1].str.bytes;
    if (std.mem.lastIndexOf(u8, self, sub)) |i| return Value{ .small_int = @intCast(i) };
    return Value{ .small_int = -1 };
}

fn indexImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const sub = args[1].str.bytes;
    if (std.mem.indexOf(u8, self, sub)) |i| return Value{ .small_int = @intCast(i) };
    try interp.raisePy("ValueError", "substring not found");
    return error.PyException;
}

fn rindexImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const sub = args[1].str.bytes;
    if (std.mem.lastIndexOf(u8, self, sub)) |i| return Value{ .small_int = @intCast(i) };
    try interp.raisePy("ValueError", "substring not found");
    return error.PyException;
}

fn removeprefixImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const pfx = args[1].str.bytes;
    const out = if (std.mem.startsWith(u8, self, pfx)) self[pfx.len..] else self;
    return Value{ .str = try Str.init(interp.allocator, out) };
}

fn removesuffixImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const sfx = args[1].str.bytes;
    const out = if (std.mem.endsWith(u8, self, sfx)) self[0 .. self.len - sfx.len] else self;
    return Value{ .str = try Str.init(interp.allocator, out) };
}

fn padHelper(interp: *Interp, self: []const u8, width: i64, fill: u8, mode: enum { center, left, right }) !Value {
    if (width <= @as(i64, @intCast(self.len))) {
        return Value{ .str = try Str.init(interp.allocator, self) };
    }
    const w: usize = @intCast(width);
    const total = w - self.len;
    var out = try interp.allocator.alloc(u8, w);
    switch (mode) {
        .center => {
            const left = total / 2;
            // CPython biases extra char to the right when total is odd.
            const right = total - left;
            @memset(out[0..left], fill);
            @memcpy(out[left .. left + self.len], self);
            @memset(out[left + self.len ..], fill);
            _ = right;
        },
        .left => {
            @memcpy(out[0..self.len], self);
            @memset(out[self.len..], fill);
        },
        .right => {
            @memset(out[0..total], fill);
            @memcpy(out[total..], self);
        },
    }
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, out) };
}

fn centerImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const width = args[1].small_int;
    const fill: u8 = if (args.len >= 3 and args[2] == .str and args[2].str.bytes.len >= 1) args[2].str.bytes[0] else ' ';
    return padHelper(interp, self, width, fill, .center);
}

fn ljustImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const width = args[1].small_int;
    const fill: u8 = if (args.len >= 3 and args[2] == .str and args[2].str.bytes.len >= 1) args[2].str.bytes[0] else ' ';
    return padHelper(interp, self, width, fill, .left);
}

fn rjustImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const width = args[1].small_int;
    const fill: u8 = if (args.len >= 3 and args[2] == .str and args[2].str.bytes.len >= 1) args[2].str.bytes[0] else ' ';
    return padHelper(interp, self, width, fill, .right);
}

fn zfillImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const width = args[1].small_int;
    if (width <= @as(i64, @intCast(self.len))) {
        return Value{ .str = try Str.init(interp.allocator, self) };
    }
    const w: usize = @intCast(width);
    const out = try interp.allocator.alloc(u8, w);
    const has_sign = self.len > 0 and (self[0] == '+' or self[0] == '-');
    const pad = w - self.len;
    if (has_sign) {
        out[0] = self[0];
        @memset(out[1 .. 1 + pad], '0');
        @memcpy(out[1 + pad ..], self[1..]);
    } else {
        @memset(out[0..pad], '0');
        @memcpy(out[pad..], self);
    }
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, out) };
}

fn expandtabsImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const tabsize: i64 = if (args.len >= 2 and args[1] == .small_int) args[1].small_int else 8;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);
    var col: usize = 0;
    for (self) |c| {
        if (c == '\t') {
            const n: usize = if (tabsize <= 0) 0 else @as(usize, @intCast(tabsize)) - col % @as(usize, @intCast(tabsize));
            try buf.appendNTimes(interp.allocator, ' ', n);
            col += n;
        } else if (c == '\n' or c == '\r') {
            try buf.append(interp.allocator, c);
            col = 0;
        } else {
            try buf.append(interp.allocator, c);
            col += 1;
        }
    }
    const owned = try buf.toOwnedSlice(interp.allocator);
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, owned) };
}

fn translateImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    if (args[1] != .dict) {
        try interp.typeError("translate() table must be a dict");
        return error.TypeError;
    }
    const tbl = args[1].dict;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);
    for (self) |c| {
        const key = Value{ .small_int = @intCast(c) };
        if (tbl.getKey(key)) |v| {
            switch (v) {
                .none => {},
                .str => |s| try buf.appendSlice(interp.allocator, s.bytes),
                .small_int => |i| try buf.append(interp.allocator, @intCast(i)),
                else => try buf.append(interp.allocator, c),
            }
        } else {
            try buf.append(interp.allocator, c);
        }
    }
    const owned = try buf.toOwnedSlice(interp.allocator);
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, owned) };
}

fn encodeImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const buf = try interp.allocator.dupe(u8, self);
    return Value{ .bytes = try Bytes.fromOwnedSlice(interp.allocator, buf) };
}

fn formatImpl(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const self = args[0].str.bytes;
    const positional = args[1..];

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);

    var auto_idx: usize = 0;
    var i: usize = 0;
    while (i < self.len) {
        const c = self[i];
        if (c == '{') {
            if (i + 1 < self.len and self[i + 1] == '{') {
                try buf.append(interp.allocator, '{');
                i += 2;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, self, i + 1, '}') orelse {
                try interp.typeError("unmatched '{' in format");
                return error.TypeError;
            };
            const spec = self[i + 1 .. end];
            const v: Value = blk: {
                if (spec.len == 0) {
                    if (auto_idx >= positional.len) {
                        try interp.typeError("not enough format arguments");
                        return error.TypeError;
                    }
                    const r = positional[auto_idx];
                    auto_idx += 1;
                    break :blk r;
                }
                // Numeric: positional index.
                if (std.ascii.isDigit(spec[0])) {
                    const idx = try std.fmt.parseInt(usize, spec, 10);
                    if (idx >= positional.len) {
                        try interp.typeError("format index out of range");
                        return error.TypeError;
                    }
                    break :blk positional[idx];
                }
                // Named: kwargs lookup.
                for (kw_names, kw_values) |kn, kv| {
                    if (kn == .str and std.mem.eql(u8, kn.str.bytes, spec)) break :blk kv;
                }
                try interp.raisePy("KeyError", spec);
                return error.PyException;
            };
            try v.writeStr(&fmtWriterAdapter(interp, &buf).w);
            i = end + 1;
        } else if (c == '}') {
            if (i + 1 < self.len and self[i + 1] == '}') {
                try buf.append(interp.allocator, '}');
                i += 2;
                continue;
            }
            try interp.typeError("single '}' in format");
            return error.TypeError;
        } else {
            try buf.append(interp.allocator, c);
            i += 1;
        }
    }
    const owned = try buf.toOwnedSlice(interp.allocator);
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, owned) };
}

const Adapter = struct {
    w: std.Io.Writer,
    interp: *Interp,
    buf: *std.ArrayList(u8),

    fn drain(io_w: *std.Io.Writer, data: []const []const u8, _: usize) std.Io.Writer.Error!usize {
        const self: *Adapter = @fieldParentPtr("w", io_w);
        var written: usize = 0;
        for (data) |chunk| {
            self.buf.appendSlice(self.interp.allocator, chunk) catch return error.WriteFailed;
            written += chunk.len;
        }
        return written;
    }
};

fn fmtWriterAdapter(interp: *Interp, buf: *std.ArrayList(u8)) *Adapter {
    const a = interp.allocator.create(Adapter) catch unreachable;
    a.* = .{
        .w = .{
            .vtable = &.{ .drain = Adapter.drain },
            .buffer = &.{},
        },
        .interp = interp,
        .buf = buf,
    };
    return a;
}

var strip_entry: BuiltinFn = .{ .name = "strip", .func = stripImpl };
var lstrip_entry: BuiltinFn = .{ .name = "lstrip", .func = lstripImpl };
var rstrip_entry: BuiltinFn = .{ .name = "rstrip", .func = rstripImpl };
var count_entry: BuiltinFn = .{ .name = "count", .func = countImpl };
var upper_entry: BuiltinFn = .{ .name = "upper", .func = upperImpl };
var lower_entry: BuiltinFn = .{ .name = "lower", .func = lowerImpl };
var title_entry: BuiltinFn = .{ .name = "title", .func = titleImpl };
var swapcase_entry: BuiltinFn = .{ .name = "swapcase", .func = swapcaseImpl };
var casefold_entry: BuiltinFn = .{ .name = "casefold", .func = lowerImpl };
var capitalize_entry: BuiltinFn = .{ .name = "capitalize", .func = capitalizeImpl };
var isalpha_entry: BuiltinFn = .{ .name = "isalpha", .func = isalphaImpl };
var isdigit_entry: BuiltinFn = .{ .name = "isdigit", .func = isdigitImpl };
var isalnum_entry: BuiltinFn = .{ .name = "isalnum", .func = isalnumImpl };
var isspace_entry: BuiltinFn = .{ .name = "isspace", .func = isspaceImpl };
var isupper_entry: BuiltinFn = .{ .name = "isupper", .func = isupperImpl };
var islower_entry: BuiltinFn = .{ .name = "islower", .func = islowerImpl };
var istitle_entry: BuiltinFn = .{ .name = "istitle", .func = istitleImpl };
var isidentifier_entry: BuiltinFn = .{ .name = "isidentifier", .func = isidentifierImpl };
var isprintable_entry: BuiltinFn = .{ .name = "isprintable", .func = isprintableImpl };
var isascii_entry: BuiltinFn = .{ .name = "isascii", .func = isasciiImpl };
var isdecimal_entry: BuiltinFn = .{ .name = "isdecimal", .func = isdecimalImpl };
var isnumeric_entry: BuiltinFn = .{ .name = "isnumeric", .func = isnumericImpl };
var replace_entry: BuiltinFn = .{ .name = "replace", .func = replaceImpl };
var split_entry: BuiltinFn = .{ .name = "split", .func = splitImpl };
var rsplit_entry: BuiltinFn = .{ .name = "rsplit", .func = rsplitImpl };
var splitlines_entry: BuiltinFn = .{ .name = "splitlines", .func = splitlinesImpl };
var partition_entry: BuiltinFn = .{ .name = "partition", .func = partitionImpl };
var rpartition_entry: BuiltinFn = .{ .name = "rpartition", .func = rpartitionImpl };
var join_entry: BuiltinFn = .{ .name = "join", .func = joinImpl };
var startswith_entry: BuiltinFn = .{ .name = "startswith", .func = startsWithImpl };
var endswith_entry: BuiltinFn = .{ .name = "endswith", .func = endsWithImpl };
var find_entry: BuiltinFn = .{ .name = "find", .func = findImpl };
var rfind_entry: BuiltinFn = .{ .name = "rfind", .func = rfindImpl };
var index_entry: BuiltinFn = .{ .name = "index", .func = indexImpl };
var rindex_entry: BuiltinFn = .{ .name = "rindex", .func = rindexImpl };
var removeprefix_entry: BuiltinFn = .{ .name = "removeprefix", .func = removeprefixImpl };
var removesuffix_entry: BuiltinFn = .{ .name = "removesuffix", .func = removesuffixImpl };
var center_entry: BuiltinFn = .{ .name = "center", .func = centerImpl };
var ljust_entry: BuiltinFn = .{ .name = "ljust", .func = ljustImpl };
var rjust_entry: BuiltinFn = .{ .name = "rjust", .func = rjustImpl };
var zfill_entry: BuiltinFn = .{ .name = "zfill", .func = zfillImpl };
var expandtabs_entry: BuiltinFn = .{ .name = "expandtabs", .func = expandtabsImpl };
var translate_entry: BuiltinFn = .{ .name = "translate", .func = translateImpl };
var encode_entry: BuiltinFn = .{ .name = "encode", .func = encodeImpl };
var format_entry: BuiltinFn = .{ .name = "format", .func = formatPosOnly, .kw_func = formatImpl };

fn maketransImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const out = try Dict.init(interp.allocator);
    if (args.len == 1 and args[0] == .dict) {
        for (args[0].dict.pairs.items) |p| {
            const key: Value = switch (p.key) {
                .str => |s| if (s.bytes.len == 1) Value{ .small_int = @intCast(s.bytes[0]) } else p.key,
                .small_int => p.key,
                else => p.key,
            };
            try out.setKey(interp.allocator, key, p.value);
        }
        return Value{ .dict = out };
    }
    if (args.len >= 2 and args[0] == .str and args[1] == .str) {
        const a = args[0].str.bytes;
        const b = args[1].str.bytes;
        if (a.len != b.len) {
            try interp.typeError("maketrans first two args must be same length");
            return error.TypeError;
        }
        for (a, b) |ka, vb| {
            const ks = try Str.init(interp.allocator, &[_]u8{vb});
            try out.setKey(interp.allocator, Value{ .small_int = @intCast(ka) }, Value{ .str = ks });
        }
        if (args.len >= 3 and args[2] == .str) {
            for (args[2].str.bytes) |c| {
                try out.setKey(interp.allocator, Value{ .small_int = @intCast(c) }, Value.none);
            }
        }
        return Value{ .dict = out };
    }
    try interp.typeError("invalid args to str.maketrans");
    return error.TypeError;
}

pub var maketrans_entry: BuiltinFn = .{ .name = "maketrans", .func = maketransImpl };

fn formatPosOnly(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return formatImpl(interp_opaque, args, &.{}, &.{});
}

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "upper")) return &upper_entry;
    if (std.mem.eql(u8, name, "lower")) return &lower_entry;
    if (std.mem.eql(u8, name, "title")) return &title_entry;
    if (std.mem.eql(u8, name, "swapcase")) return &swapcase_entry;
    if (std.mem.eql(u8, name, "casefold")) return &casefold_entry;
    if (std.mem.eql(u8, name, "capitalize")) return &capitalize_entry;
    if (std.mem.eql(u8, name, "isalpha")) return &isalpha_entry;
    if (std.mem.eql(u8, name, "isdigit")) return &isdigit_entry;
    if (std.mem.eql(u8, name, "isalnum")) return &isalnum_entry;
    if (std.mem.eql(u8, name, "isspace")) return &isspace_entry;
    if (std.mem.eql(u8, name, "isupper")) return &isupper_entry;
    if (std.mem.eql(u8, name, "islower")) return &islower_entry;
    if (std.mem.eql(u8, name, "istitle")) return &istitle_entry;
    if (std.mem.eql(u8, name, "isidentifier")) return &isidentifier_entry;
    if (std.mem.eql(u8, name, "isprintable")) return &isprintable_entry;
    if (std.mem.eql(u8, name, "isascii")) return &isascii_entry;
    if (std.mem.eql(u8, name, "isdecimal")) return &isdecimal_entry;
    if (std.mem.eql(u8, name, "isnumeric")) return &isnumeric_entry;
    if (std.mem.eql(u8, name, "replace")) return &replace_entry;
    if (std.mem.eql(u8, name, "split")) return &split_entry;
    if (std.mem.eql(u8, name, "rsplit")) return &rsplit_entry;
    if (std.mem.eql(u8, name, "splitlines")) return &splitlines_entry;
    if (std.mem.eql(u8, name, "partition")) return &partition_entry;
    if (std.mem.eql(u8, name, "rpartition")) return &rpartition_entry;
    if (std.mem.eql(u8, name, "join")) return &join_entry;
    if (std.mem.eql(u8, name, "startswith")) return &startswith_entry;
    if (std.mem.eql(u8, name, "endswith")) return &endswith_entry;
    if (std.mem.eql(u8, name, "find")) return &find_entry;
    if (std.mem.eql(u8, name, "rfind")) return &rfind_entry;
    if (std.mem.eql(u8, name, "index")) return &index_entry;
    if (std.mem.eql(u8, name, "rindex")) return &rindex_entry;
    if (std.mem.eql(u8, name, "count")) return &count_entry;
    if (std.mem.eql(u8, name, "strip")) return &strip_entry;
    if (std.mem.eql(u8, name, "lstrip")) return &lstrip_entry;
    if (std.mem.eql(u8, name, "rstrip")) return &rstrip_entry;
    if (std.mem.eql(u8, name, "removeprefix")) return &removeprefix_entry;
    if (std.mem.eql(u8, name, "removesuffix")) return &removesuffix_entry;
    if (std.mem.eql(u8, name, "center")) return &center_entry;
    if (std.mem.eql(u8, name, "ljust")) return &ljust_entry;
    if (std.mem.eql(u8, name, "rjust")) return &rjust_entry;
    if (std.mem.eql(u8, name, "zfill")) return &zfill_entry;
    if (std.mem.eql(u8, name, "expandtabs")) return &expandtabs_entry;
    if (std.mem.eql(u8, name, "translate")) return &translate_entry;
    if (std.mem.eql(u8, name, "encode")) return &encode_entry;
    if (std.mem.eql(u8, name, "format")) return &format_entry;
    return null;
}
