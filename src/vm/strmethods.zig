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

    var ctx: FmtCtx = .{
        .interp = interp,
        .positional = positional,
        .kw_names = kw_names,
        .kw_values = kw_values,
        .auto_idx = 0,
    };
    try renderTemplate(&ctx, self, &buf);
    const owned = try buf.toOwnedSlice(interp.allocator);
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, owned) };
}

pub fn formatTemplate(
    interp: *Interp,
    template: []const u8,
    positional: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) !Value {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);
    var ctx: FmtCtx = .{
        .interp = interp,
        .positional = positional,
        .kw_names = kw_names,
        .kw_values = kw_values,
        .auto_idx = 0,
    };
    try renderTemplate(&ctx, template, &buf);
    const owned = try buf.toOwnedSlice(interp.allocator);
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, owned) };
}

pub fn formatOne(interp: *Interp, v: Value, spec_raw: []const u8) !Value {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);
    try formatValueWithSpec(interp, v, spec_raw, &buf);
    const owned = try buf.toOwnedSlice(interp.allocator);
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, owned) };
}

pub fn convertField(interp: *Interp, v: Value, conv: u8) !Value {
    return applyConversion(interp, v, conv);
}

const FmtCtx = struct {
    interp: *Interp,
    positional: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
    auto_idx: usize,
};

fn renderTemplate(ctx: *FmtCtx, template: []const u8, buf: *std.ArrayList(u8)) anyerror!void {
    const a = ctx.interp.allocator;
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c == '{') {
            if (i + 1 < template.len and template[i + 1] == '{') {
                try buf.append(a, '{');
                i += 2;
                continue;
            }
            const end = try findFieldEnd(ctx.interp, template, i + 1);
            try renderField(ctx, template[i + 1 .. end], buf);
            i = end + 1;
        } else if (c == '}') {
            if (i + 1 < template.len and template[i + 1] == '}') {
                try buf.append(a, '}');
                i += 2;
                continue;
            }
            try ctx.interp.typeError("single '}' in format");
            return error.TypeError;
        } else {
            try buf.append(a, c);
            i += 1;
        }
    }
}

fn findFieldEnd(interp: *Interp, template: []const u8, start: usize) !usize {
    var depth: usize = 0;
    var i = start;
    while (i < template.len) : (i += 1) {
        const c = template[i];
        if (c == '{') depth += 1
        else if (c == '}') {
            if (depth == 0) return i;
            depth -= 1;
        }
    }
    try interp.typeError("unmatched '{' in format");
    return error.TypeError;
}

fn renderField(ctx: *FmtCtx, field: []const u8, buf: *std.ArrayList(u8)) !void {
    // Parse: field_name[!conv][:format_spec]
    var name_end = field.len;
    var conv_end: ?usize = null;
    var spec_start: ?usize = null;
    {
        var depth: usize = 0;
        var i: usize = 0;
        while (i < field.len) : (i += 1) {
            const c = field[i];
            if (c == '{') depth += 1
            else if (c == '}') depth -= 1
            else if (depth == 0) {
                if (c == '!' and conv_end == null and spec_start == null) {
                    name_end = i;
                    conv_end = i + 2;
                } else if (c == ':' and spec_start == null) {
                    if (conv_end == null) name_end = i;
                    spec_start = i + 1;
                }
            }
        }
    }
    const name = field[0..name_end];
    const conv: ?u8 = if (conv_end) |ce| (if (ce >= 1 and ce - 1 < field.len) field[ce - 1] else null) else null;
    const spec_raw: []const u8 = if (spec_start) |s| field[s..] else "";

    // Resolve field_name to a value.
    var v = try resolveField(ctx, name);
    if (conv) |cn| v = try applyConversion(ctx.interp, v, cn);

    // Format spec may itself contain nested {...}; expand.
    var spec_buf: std.ArrayList(u8) = .empty;
    defer spec_buf.deinit(ctx.interp.allocator);
    try renderTemplate(ctx, spec_raw, &spec_buf);

    try formatValueWithSpec(ctx.interp, v, spec_buf.items, buf);
}

fn resolveField(ctx: *FmtCtx, name: []const u8) !Value {
    // Initial atom: number (positional), bare name (kwargs), or empty (auto).
    var i: usize = 0;
    var v: Value = undefined;
    if (name.len == 0) {
        if (ctx.auto_idx >= ctx.positional.len) {
            try ctx.interp.typeError("not enough format arguments");
            return error.TypeError;
        }
        v = ctx.positional[ctx.auto_idx];
        ctx.auto_idx += 1;
    } else if (std.ascii.isDigit(name[0])) {
        var j: usize = 0;
        while (j < name.len and std.ascii.isDigit(name[j])) : (j += 1) {}
        const idx = try std.fmt.parseInt(usize, name[0..j], 10);
        if (idx >= ctx.positional.len) {
            try ctx.interp.typeError("format index out of range");
            return error.TypeError;
        }
        v = ctx.positional[idx];
        i = j;
    } else {
        var j: usize = 0;
        while (j < name.len and name[j] != '.' and name[j] != '[') : (j += 1) {}
        const key = name[0..j];
        var found = false;
        for (ctx.kw_names, ctx.kw_values) |kn, kv| {
            if (kn == .str and std.mem.eql(u8, kn.str.bytes, key)) {
                v = kv;
                found = true;
                break;
            }
        }
        if (!found) {
            try ctx.interp.raisePy("KeyError", key);
            return error.PyException;
        }
        i = j;
    }

    // Walk .attr / [item] suffixes.
    while (i < name.len) {
        if (name[i] == '.') {
            i += 1;
            const start = i;
            while (i < name.len and name[i] != '.' and name[i] != '[') : (i += 1) {}
            v = try getAttr(ctx.interp, v, name[start..i]);
        } else if (name[i] == '[') {
            i += 1;
            const start = i;
            while (i < name.len and name[i] != ']') : (i += 1) {}
            const key = name[start..i];
            if (i < name.len) i += 1;
            v = try getItem(ctx.interp, v, key);
        } else {
            break;
        }
    }

    return v;
}

fn getAttr(interp: *Interp, v: Value, attr: []const u8) !Value {
    if (v == .complex_num) {
        if (std.mem.eql(u8, attr, "real")) return Value{ .float = v.complex_num.re };
        if (std.mem.eql(u8, attr, "imag")) return Value{ .float = v.complex_num.im };
    }
    if (v == .float) {
        if (std.mem.eql(u8, attr, "real")) return v;
        if (std.mem.eql(u8, attr, "imag")) return Value{ .float = 0 };
    }
    if (v == .small_int or v == .boolean) {
        if (std.mem.eql(u8, attr, "real")) return v;
        if (std.mem.eql(u8, attr, "imag")) return Value{ .small_int = 0 };
    }
    if (v == .instance) {
        if (v.instance.dict.getStr(attr)) |x| return x;
    }
    try interp.attributeError(@tagName(v), attr);
    return error.AttributeError;
}

fn getItem(interp: *Interp, v: Value, key: []const u8) !Value {
    // Numeric indexing for tuple/list/str; dict lookup uses string key.
    if (std.ascii.isDigit(key[0]) or (key.len > 1 and key[0] == '-')) {
        const idx = std.fmt.parseInt(i64, key, 10) catch {
            try interp.typeError("invalid format index");
            return error.TypeError;
        };
        switch (v) {
            .tuple => |t| {
                var ix = idx;
                if (ix < 0) ix += @intCast(t.items.len);
                if (ix < 0 or ix >= @as(i64, @intCast(t.items.len))) {
                    try interp.indexError("tuple index out of range");
                    return error.IndexError;
                }
                return t.items[@intCast(ix)];
            },
            .list => |l| {
                var ix = idx;
                if (ix < 0) ix += @intCast(l.items.items.len);
                if (ix < 0 or ix >= @as(i64, @intCast(l.items.items.len))) {
                    try interp.indexError("list index out of range");
                    return error.IndexError;
                }
                return l.items.items[@intCast(ix)];
            },
            else => {},
        }
    }
    if (v == .dict) {
        if (v.dict.getStr(key)) |x| return x;
        try interp.raisePy("KeyError", key);
        return error.PyException;
    }
    try interp.typeError("unsupported indexing in format spec");
    return error.TypeError;
}

fn applyConversion(interp: *Interp, v: Value, conv: u8) !Value {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);
    const adapter = fmtWriterAdapter(interp, &buf);
    switch (conv) {
        's' => try v.writeStr(&adapter.w),
        'r', 'a' => try v.writeRepr(&adapter.w),
        else => {
            try interp.typeError("unknown conversion specifier");
            return error.TypeError;
        },
    }
    const owned = try buf.toOwnedSlice(interp.allocator);
    return Value{ .str = try Str.fromOwnedSlice(interp.allocator, owned) };
}

const FmtSpec = struct {
    fill: u8 = ' ',
    alignment: ?u8 = null, // '<', '>', '=', '^'
    sign: u8 = '-', // '+', '-', ' '
    alt: bool = false,
    zero_pad: bool = false,
    width: usize = 0,
    grouping: ?u8 = null, // ',', '_'
    precision: ?usize = null,
    type: ?u8 = null,
};

fn parseSpec(interp: *Interp, raw: []const u8) !FmtSpec {
    var s = FmtSpec{};
    var i: usize = 0;

    // [[fill]align]: fill is any non-{}/non-spec char if char at i+1 is align char.
    if (raw.len >= 2) {
        const a1 = raw[1];
        if (a1 == '<' or a1 == '>' or a1 == '=' or a1 == '^') {
            s.fill = raw[0];
            s.alignment = a1;
            i = 2;
        }
    }
    if (s.alignment == null and i < raw.len) {
        const c = raw[i];
        if (c == '<' or c == '>' or c == '=' or c == '^') {
            s.alignment = c;
            i += 1;
        }
    }
    if (i < raw.len and (raw[i] == '+' or raw[i] == '-' or raw[i] == ' ')) {
        s.sign = raw[i];
        i += 1;
    }
    if (i < raw.len and raw[i] == '#') {
        s.alt = true;
        i += 1;
    }
    if (i < raw.len and raw[i] == '0') {
        s.zero_pad = true;
        if (s.alignment == null) s.alignment = '=';
        s.fill = '0';
        i += 1;
    }
    while (i < raw.len and std.ascii.isDigit(raw[i])) : (i += 1) {
        s.width = s.width * 10 + (raw[i] - '0');
    }
    if (i < raw.len and (raw[i] == ',' or raw[i] == '_')) {
        s.grouping = raw[i];
        i += 1;
    }
    if (i < raw.len and raw[i] == '.') {
        i += 1;
        var p: usize = 0;
        while (i < raw.len and std.ascii.isDigit(raw[i])) : (i += 1) {
            p = p * 10 + (raw[i] - '0');
        }
        s.precision = p;
    }
    if (i < raw.len) {
        s.type = raw[i];
        i += 1;
    }
    if (i != raw.len) {
        try interp.typeError("invalid format spec");
        return error.TypeError;
    }
    return s;
}

fn formatValueWithSpec(interp: *Interp, v: Value, raw: []const u8, out: *std.ArrayList(u8)) !void {
    const a = interp.allocator;

    // Empty spec: default str() conversion.
    if (raw.len == 0) {
        try v.writeStr(&fmtWriterAdapter(interp, out).w);
        return;
    }

    const spec = try parseSpec(interp, raw);

    // Dispatch by type.
    const t: u8 = spec.type orelse blk: {
        switch (v) {
            .small_int, .boolean, .big_int => break :blk 'd',
            .float => break :blk 'g',
            else => break :blk 's',
        }
    };
    if (t == 'c') {
        const cp: u32 = switch (v) {
            .small_int => @intCast(v.small_int),
            .boolean => @intFromBool(v.boolean),
            else => {
                try interp.typeError("'c' requires int");
                return error.TypeError;
            },
        };
        var ubuf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &ubuf) catch {
            try interp.raisePy("ValueError", "chr() argument out of range");
            return error.PyException;
        };
        try padAndAppend(a, ubuf[0..n], spec, out, false);
        return;
    }
    if (t == 's') {
        var s_buf: std.ArrayList(u8) = .empty;
        defer s_buf.deinit(a);
        try v.writeStr(&fmtWriterAdapter(interp, &s_buf).w);
        var slice: []const u8 = s_buf.items;
        if (spec.precision) |p| {
            if (slice.len > p) slice = slice[0..p];
        }
        try padAndAppend(a, slice, spec, out, false);
        return;
    }
    if (t == 'd' or t == 'b' or t == 'o' or t == 'x' or t == 'X') {
        const i: i64 = switch (v) {
            .small_int => v.small_int,
            .boolean => @intFromBool(v.boolean),
            else => {
                try interp.typeError("integer format requires int");
                return error.TypeError;
            },
        };
        try formatInt(a, i, t, spec, out);
        return;
    }
    if (t == 'f' or t == 'F' or t == 'e' or t == 'E' or t == 'g' or t == 'G' or t == '%') {
        const f: f64 = switch (v) {
            .float => v.float,
            .small_int => @floatFromInt(v.small_int),
            .boolean => @floatFromInt(@as(i64, @intFromBool(v.boolean))),
            else => {
                try interp.typeError("float format requires int/float");
                return error.TypeError;
            },
        };
        try formatFloat(a, f, t, spec, out);
        return;
    }
    try interp.typeError("unsupported format type");
    return error.TypeError;
}

fn padAndAppend(
    a: std.mem.Allocator,
    body: []const u8,
    spec: FmtSpec,
    out: *std.ArrayList(u8),
    is_numeric: bool,
) !void {
    const align_c: u8 = spec.alignment orelse if (is_numeric) '>' else '<';
    if (body.len >= spec.width) {
        try out.appendSlice(a, body);
        return;
    }
    const pad = spec.width - body.len;
    switch (align_c) {
        '<' => {
            try out.appendSlice(a, body);
            try out.appendNTimes(a, spec.fill, pad);
        },
        '>' => {
            try out.appendNTimes(a, spec.fill, pad);
            try out.appendSlice(a, body);
        },
        '^' => {
            const left = pad / 2;
            const right = pad - left;
            try out.appendNTimes(a, spec.fill, left);
            try out.appendSlice(a, body);
            try out.appendNTimes(a, spec.fill, right);
        },
        '=' => {
            // sign-aware: caller does sign+prefix, then pads, then digits.
            // Here we treat body as already a number; caller handles split.
            try out.appendNTimes(a, spec.fill, pad);
            try out.appendSlice(a, body);
        },
        else => try out.appendSlice(a, body),
    }
}

fn intToBase(a: std.mem.Allocator, n: u64, base: u8, upper: bool) ![]u8 {
    if (n == 0) return try a.dupe(u8, "0");
    var tmp: [64]u8 = undefined;
    var k: usize = tmp.len;
    var x = n;
    const lower_digits = "0123456789abcdef";
    const upper_digits = "0123456789ABCDEF";
    const digits = if (upper) upper_digits else lower_digits;
    while (x > 0) : (x /= base) {
        k -= 1;
        tmp[k] = digits[@intCast(x % base)];
    }
    return try a.dupe(u8, tmp[k..]);
}

fn applyGrouping(a: std.mem.Allocator, digits: []const u8, group_sep: u8, group_size: usize) ![]u8 {
    if (digits.len <= group_size) return try a.dupe(u8, digits);
    const num_seps = (digits.len - 1) / group_size;
    const out = try a.alloc(u8, digits.len + num_seps);
    var src = digits.len;
    var dst = out.len;
    var count: usize = 0;
    while (src > 0) {
        if (count == group_size) {
            dst -= 1;
            out[dst] = group_sep;
            count = 0;
        }
        src -= 1;
        dst -= 1;
        out[dst] = digits[src];
        count += 1;
    }
    return out;
}

fn formatInt(
    a: std.mem.Allocator,
    val: i64,
    t: u8,
    spec: FmtSpec,
    out: *std.ArrayList(u8),
) !void {
    const negative = val < 0;
    const u: u64 = if (negative) @as(u64, @intCast(-(val + 1))) + 1 else @as(u64, @intCast(val));
    const base: u8 = switch (t) {
        'd' => 10,
        'b' => 2,
        'o' => 8,
        'x', 'X' => 16,
        else => 10,
    };
    const upper = t == 'X';
    var digits = try intToBase(a, u, base, upper);
    defer a.free(digits);

    if (spec.grouping) |g| {
        const group_size: usize = if (t == 'd') 3 else 4;
        const grouped = try applyGrouping(a, digits, g, group_size);
        a.free(digits);
        digits = grouped;
    }

    var sign_str: []const u8 = "";
    if (negative) sign_str = "-"
    else if (spec.sign == '+') sign_str = "+"
    else if (spec.sign == ' ') sign_str = " ";

    var prefix_str: []const u8 = "";
    if (spec.alt) {
        prefix_str = switch (t) {
            'b' => "0b",
            'o' => "0o",
            'x' => "0x",
            'X' => "0X",
            else => "",
        };
    }

    // Build body and apply padding. zero-pad uses '=' alignment: sign+prefix
    // first, then '0' fill, then digits.
    if (spec.alignment == '=') {
        const body_len = sign_str.len + prefix_str.len + digits.len;
        if (body_len >= spec.width) {
            try out.appendSlice(a, sign_str);
            try out.appendSlice(a, prefix_str);
            try out.appendSlice(a, digits);
        } else {
            const pad = spec.width - body_len;
            try out.appendSlice(a, sign_str);
            try out.appendSlice(a, prefix_str);
            try out.appendNTimes(a, spec.fill, pad);
            try out.appendSlice(a, digits);
        }
        return;
    }
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try body.appendSlice(a, sign_str);
    try body.appendSlice(a, prefix_str);
    try body.appendSlice(a, digits);
    try padAndAppend(a, body.items, spec, out, true);
}

fn formatFloat(
    a: std.mem.Allocator,
    val_in: f64,
    t: u8,
    spec: FmtSpec,
    out: *std.ArrayList(u8),
) !void {
    var val = val_in;
    var t_actual = t;
    if (t == '%') {
        val *= 100.0;
        t_actual = 'f';
    }
    const negative = val < 0 or (val == 0 and std.math.signbit(val));
    const abs = if (negative) -val else val;

    var digits: []u8 = undefined;
    const precision: usize = spec.precision orelse if (t == 'g' or t == 'G') 6 else 6;

    if (t_actual == 'f' or t_actual == 'F') {
        var buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d:.[1]}", .{ abs, precision });
        digits = try a.dupe(u8, s);
    } else if (t_actual == 'e' or t_actual == 'E') {
        digits = try formatExp(a, abs, precision, t_actual == 'E');
    } else if (t_actual == 'g' or t_actual == 'G') {
        digits = try formatGeneral(a, abs, precision, t_actual == 'G', spec.alt);
    } else {
        digits = try a.dupe(u8, "?");
    }
    defer a.free(digits);

    var grouped: []u8 = digits;
    var grouped_owned = false;
    if (spec.grouping) |g| {
        // Group only the integer part (before '.' or 'e').
        const dot_idx = std.mem.indexOfAny(u8, digits, ".eE") orelse digits.len;
        const int_part = digits[0..dot_idx];
        const rest = digits[dot_idx..];
        const new_int = try applyGrouping(a, int_part, g, 3);
        defer a.free(new_int);
        const combined = try a.alloc(u8, new_int.len + rest.len);
        @memcpy(combined[0..new_int.len], new_int);
        @memcpy(combined[new_int.len..], rest);
        grouped = combined;
        grouped_owned = true;
    }
    defer if (grouped_owned) a.free(grouped);

    var sign_str: []const u8 = "";
    if (negative) sign_str = "-"
    else if (spec.sign == '+') sign_str = "+"
    else if (spec.sign == ' ') sign_str = " ";

    const tail: []const u8 = if (t == '%') "%" else "";

    if (spec.alignment == '=') {
        const body_len = sign_str.len + grouped.len + tail.len;
        if (body_len >= spec.width) {
            try out.appendSlice(a, sign_str);
            try out.appendSlice(a, grouped);
            try out.appendSlice(a, tail);
        } else {
            const pad = spec.width - body_len;
            try out.appendSlice(a, sign_str);
            try out.appendNTimes(a, spec.fill, pad);
            try out.appendSlice(a, grouped);
            try out.appendSlice(a, tail);
        }
        return;
    }
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try body.appendSlice(a, sign_str);
    try body.appendSlice(a, grouped);
    try body.appendSlice(a, tail);
    try padAndAppend(a, body.items, spec, out, true);
}

fn formatExp(a: std.mem.Allocator, abs: f64, precision: usize, upper: bool) ![]u8 {
    // CPython prints exponent with sign and at least 2 digits ('1.23e+05').
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{e:.[1]}", .{ abs, precision });
    // Zig's default exponent format produces e.g. "1.234568e5"; we need
    // "1.234568e+05". Rewrite the exponent.
    const e_pos = std.mem.indexOfScalar(u8, s, 'e') orelse return try a.dupe(u8, s);
    const mantissa = s[0..e_pos];
    const exp_part = s[e_pos + 1 ..];
    var exp_neg = false;
    var exp_str = exp_part;
    if (exp_part.len > 0 and (exp_part[0] == '+' or exp_part[0] == '-')) {
        exp_neg = exp_part[0] == '-';
        exp_str = exp_part[1..];
    }
    const exp_num = try std.fmt.parseInt(i64, exp_str, 10);
    var exp_buf: [16]u8 = undefined;
    const exp_unsigned: u64 = @intCast(if (exp_num < 0) -exp_num else exp_num);
    const exp_digits = try std.fmt.bufPrint(&exp_buf, "{d}", .{exp_unsigned});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, mantissa);
    try out.append(a, if (upper) 'E' else 'e');
    try out.append(a, if (exp_neg) '-' else '+');
    if (exp_digits.len < 2) try out.append(a, '0');
    try out.appendSlice(a, exp_digits);
    return try out.toOwnedSlice(a);
}

fn formatGeneral(a: std.mem.Allocator, abs: f64, precision_in: usize, upper: bool, alt: bool) ![]u8 {
    // CPython's 'g': use 'e' if exponent < -4 or >= precision, else 'f';
    // strip trailing zeros (and trailing '.') unless alt is set.
    const precision: usize = if (precision_in == 0) 1 else precision_in;

    if (abs == 0) {
        if (alt) {
            const out = try a.alloc(u8, 1 + precision);
            out[0] = '0';
            if (precision > 0) {
                // 0.00...0 with `precision-1` zeros after dot? Actually 'g' alt
                // keeps full precision: "0." padded with zeros to total `precision`.
                // For now: just "0".
            }
            a.free(out);
            return try a.dupe(u8, "0");
        }
        return try a.dupe(u8, "0");
    }

    // Estimate exponent: floor(log10(abs)).
    const log10v = std.math.log10(abs);
    const exp_est: i64 = @intFromFloat(@floor(log10v));

    if (exp_est < -4 or exp_est >= @as(i64, @intCast(precision))) {
        const e_str = try formatExp(a, abs, precision - 1, upper);
        if (alt) return e_str;
        return stripTrailingZerosG(a, e_str);
    }
    const decimals: usize = @intCast(@as(i64, @intCast(precision)) - 1 - exp_est);
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d:.[1]}", .{ abs, decimals });
    const owned = try a.dupe(u8, s);
    if (alt) return owned;
    defer a.free(owned);
    return stripTrailingZerosG(a, owned);
}

fn stripTrailingZerosG(a: std.mem.Allocator, s: []const u8) ![]u8 {
    // 'g' rule: drop trailing zeros in the fractional part; drop the '.'
    // if it ends up trailing. Don't touch anything past 'e'/'E'.
    const e_idx = std.mem.indexOfAny(u8, s, "eE");
    const num_part = if (e_idx) |ei| s[0..ei] else s;
    const tail_part = if (e_idx) |ei| s[ei..] else "";
    const dot = std.mem.indexOfScalar(u8, num_part, '.');
    if (dot == null) {
        return try a.dupe(u8, s);
    }
    var end = num_part.len;
    while (end > 0 and num_part[end - 1] == '0') : (end -= 1) {}
    if (end > 0 and num_part[end - 1] == '.') end -= 1;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, num_part[0..end]);
    try out.appendSlice(a, tail_part);
    return try out.toOwnedSlice(a);
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
