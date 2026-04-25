const std = @import("std");
const Value = @import("value.zig").Value;

/// Lazy `enumerate(iterable, start=…)`. Holds the underlying source as
/// a `Value` (so a generator can keep yielding without being drained
/// up front) and the running counter. Stepping happens in dispatch's
/// `iterStep`, which knows how to advance any iterable.
pub const EnumIter = struct {
    source: Value,
    count: i64,

    pub fn init(allocator: std.mem.Allocator, source: Value, start: i64) !*EnumIter {
        const self = try allocator.create(EnumIter);
        self.* = .{ .source = source, .count = start };
        return self;
    }
};
