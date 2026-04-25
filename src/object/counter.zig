const std = @import("std");
const Value = @import("value.zig").Value;
const Dict = @import("dict.zig").Dict;

/// `collections.Counter` is a dict that returns 0 for missing keys
/// and tracks integer counts. We keep counts as `small_int` Values
/// inside a `*Dict`; arithmetic is done in the module callers.
pub const Counter = struct {
    data: *Dict,

    pub fn init(allocator: std.mem.Allocator) !*Counter {
        const self = try allocator.create(Counter);
        self.* = .{ .data = try Dict.init(allocator) };
        return self;
    }

    pub fn total(self: *Counter) i64 {
        var sum: i64 = 0;
        for (self.data.pairs.items) |p| {
            if (p.value == .small_int) sum += p.value.small_int;
        }
        return sum;
    }
};
