const std = @import("std");
const Class = @import("class.zig").Class;
const Dict = @import("dict.zig").Dict;

/// A user-defined-class instance: pointer to the class plus an
/// attribute dict. Per-instance `__dict__` is the simplest thing
/// that works; `__slots__` lands the day a fixture needs it.
pub const Instance = struct {
    cls: *Class,
    dict: *Dict,

    pub fn init(allocator: std.mem.Allocator, cls: *Class) !*Instance {
        const self = try allocator.create(Instance);
        self.* = .{ .cls = cls, .dict = try Dict.init(allocator) };
        return self;
    }
};
