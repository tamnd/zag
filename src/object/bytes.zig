const std = @import("std");

pub const Bytes = struct {
    data: []const u8,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) !*Bytes {
        const self = try allocator.create(Bytes);
        const owned = try allocator.dupe(u8, data);
        self.* = .{ .data = owned };
        return self;
    }

    pub fn fromOwnedSlice(allocator: std.mem.Allocator, data: []const u8) !*Bytes {
        const self = try allocator.create(Bytes);
        self.* = .{ .data = data };
        return self;
    }

    pub fn deinit(self: *Bytes, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.destroy(self);
    }
};
