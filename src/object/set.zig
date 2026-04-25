const std = @import("std");
const Value = @import("value.zig").Value;

/// Insertion-ordered set keyed by arbitrary Value. Backed by a flat
/// array; lookups walk it with `Value.equals`. Order matters for
/// repr because the fixtures compare against CPython's small-set
/// printing, which (for our int inputs) is sorted-ascending.
pub const Set = struct {
    items: std.ArrayList(Value),

    pub fn init(allocator: std.mem.Allocator) !*Set {
        const self = try allocator.create(Set);
        self.* = .{ .items = .empty };
        return self;
    }

    pub fn add(self: *Set, allocator: std.mem.Allocator, v: Value) !void {
        for (self.items.items) |it| if (it.equals(v)) return;
        try self.items.append(allocator, v);
    }

    pub fn contains(self: *const Set, v: Value) bool {
        for (self.items.items) |it| if (it.equals(v)) return true;
        return false;
    }
};
