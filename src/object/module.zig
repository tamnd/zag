const std = @import("std");
const Dict = @import("dict.zig").Dict;

/// A minimal module object: name plus a dict of attributes. Only the
/// builtin modules (today: `asyncio`) round-trip through here — there's
/// no `.pyc` import path yet.
pub const Module = struct {
    name: []const u8,
    attrs: *Dict,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !*Module {
        const self = try allocator.create(Module);
        self.* = .{ .name = name, .attrs = try Dict.init(allocator) };
        return self;
    }
};
