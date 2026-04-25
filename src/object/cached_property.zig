const std = @import("std");
const Value = @import("value.zig").Value;

/// `functools.cached_property`. On instance attribute access, looks
/// up `name` in the instance dict; if absent, calls `func(instance)`
/// once, stores the result, and returns it. Subsequent reads hit the
/// instance dict directly (no descriptor invocation).
pub const CachedProperty = struct {
    func: Value,
    name: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, func: Value) !*CachedProperty {
        const self = try allocator.create(CachedProperty);
        self.* = .{ .func = func };
        return self;
    }
};
