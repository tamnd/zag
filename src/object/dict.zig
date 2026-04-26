const std = @import("std");
const Value = @import("value.zig").Value;

/// Insertion-ordered dict keyed by arbitrary Value. Backing store
/// is a flat array of (key, value) pairs; lookups are linear. The
/// fixtures don't push enough entries for that to matter, and going
/// through `Value.equals` keeps int / bool / str keys interchangeable
/// with no special cases.
pub const Dict = struct {
    pairs: std.ArrayList(Pair),
    /// Insertion-order shadow of just the string keys -- preserved so
    /// `globals`, `builtins`, and class-namespace consumers can still
    /// iterate names without filtering.
    keys: std.ArrayList([]const u8),

    pub const Pair = struct { key: Value, value: Value };

    pub fn init(allocator: std.mem.Allocator) !*Dict {
        const self = try allocator.create(Dict);
        self.* = .{
            .pairs = .empty,
            .keys = .empty,
        };
        return self;
    }

    pub fn deinit(self: *Dict, allocator: std.mem.Allocator) void {
        self.pairs.deinit(allocator);
        self.keys.deinit(allocator);
        allocator.destroy(self);
    }

    fn findStr(self: *const Dict, key: []const u8) ?usize {
        for (self.pairs.items, 0..) |p, i| {
            if (p.key == .str and std.mem.eql(u8, p.key.str.bytes, key)) return i;
        }
        return null;
    }

    fn findKey(self: *const Dict, key: Value) ?usize {
        for (self.pairs.items, 0..) |p, i| {
            if (p.key.equals(key)) return i;
        }
        return null;
    }

    pub fn setStr(self: *Dict, allocator: std.mem.Allocator, key: []const u8, v: Value) !void {
        if (self.findStr(key)) |idx| {
            self.pairs.items[idx].value = v;
            return;
        }
        const Str = @import("string.zig").Str;
        const s = try Str.init(allocator, key);
        try self.pairs.append(allocator, .{ .key = Value{ .str = s }, .value = v });
        try self.keys.append(allocator, s.bytes);
    }

    pub fn getStr(self: *const Dict, key: []const u8) ?Value {
        if (self.findStr(key)) |idx| return self.pairs.items[idx].value;
        return null;
    }

    pub fn setKey(self: *Dict, allocator: std.mem.Allocator, key: Value, v: Value) !void {
        if (self.findKey(key)) |idx| {
            self.pairs.items[idx].value = v;
            return;
        }
        try self.pairs.append(allocator, .{ .key = key, .value = v });
        if (key == .str) try self.keys.append(allocator, key.str.bytes);
    }

    pub fn getKey(self: *const Dict, key: Value) ?Value {
        if (self.findKey(key)) |idx| return self.pairs.items[idx].value;
        return null;
    }

    pub fn count(self: *const Dict) usize {
        return self.pairs.items.len;
    }

    pub fn contains(self: *const Dict, key: []const u8) bool {
        return self.findStr(key) != null;
    }

    pub fn delete(self: *Dict, key: []const u8) bool {
        const idx = self.findStr(key) orelse return false;
        _ = self.pairs.orderedRemove(idx);
        for (self.keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                _ = self.keys.orderedRemove(i);
                break;
            }
        }
        return true;
    }

    /// `key in dict` for arbitrary keys.
    pub fn findKeyWrap(self: *const Dict, key: Value) bool {
        return self.findKey(key) != null;
    }

    /// Remove a pair keyed by an arbitrary Value. Returns whether the
    /// key was found.
    pub fn removeKeyWrap(self: *Dict, key: Value) bool {
        const idx = self.findKey(key) orelse return false;
        const removed = self.pairs.orderedRemove(idx);
        if (removed.key == .str) {
            for (self.keys.items, 0..) |k, i| {
                if (std.mem.eql(u8, k, removed.key.str.bytes)) {
                    _ = self.keys.orderedRemove(i);
                    break;
                }
            }
        }
        return true;
    }
};
