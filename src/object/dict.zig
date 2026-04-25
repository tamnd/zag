const std = @import("std");
const Value = @import("value.zig").Value;

/// String-keyed dict. Enough for globals, builtins, and module
/// namespaces, which is every dict the hello fixture touches.
/// General (arbitrary-key) dicts land in a later milestone with
/// the rest of the collections work.
///
/// Iteration order is the insertion order a consumer cares about
/// for `dict.__iter__`; the `StringHashMap` backing does not preserve
/// order, so we also keep a parallel `keys` list. Value lookup still
/// goes through the hash map.
pub const Dict = struct {
    map: std.StringHashMapUnmanaged(Value),
    keys: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) !*Dict {
        const self = try allocator.create(Dict);
        self.* = .{
            .map = .empty,
            .keys = .empty,
        };
        return self;
    }

    pub fn deinit(self: *Dict, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.keys.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setStr(self: *Dict, allocator: std.mem.Allocator, key: []const u8, v: Value) !void {
        const gop = try self.map.getOrPut(allocator, key);
        if (!gop.found_existing) {
            try self.keys.append(allocator, key);
        }
        gop.value_ptr.* = v;
    }

    pub fn getStr(self: *const Dict, key: []const u8) ?Value {
        return self.map.get(key);
    }

    pub fn count(self: *const Dict) usize {
        return self.map.count();
    }

    pub fn contains(self: *const Dict, key: []const u8) bool {
        return self.map.contains(key);
    }

    /// Remove `key` if present. Returns true if a key was removed.
    /// O(n) on the keys list because we keep insertion order;
    /// fixtures don't yet stress this.
    pub fn delete(self: *Dict, key: []const u8) bool {
        if (!self.map.remove(key)) return false;
        for (self.keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                _ = self.keys.orderedRemove(i);
                return true;
            }
        }
        return true;
    }
};
