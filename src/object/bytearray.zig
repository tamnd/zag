const std = @import("std");

/// Mutable byte buffer. Distinct value type from `Bytes` because bytes
/// are immutable shared-buffer; bytearray gets in-place item assignment,
/// `append`, `extend`, and `pop`. Equality with `bytes` is content-only.
pub const Bytearray = struct {
    data: std.ArrayList(u8),
    view_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !*Bytearray {
        const self = try allocator.create(Bytearray);
        self.* = .{ .data = .empty };
        return self;
    }

    pub fn fromSlice(allocator: std.mem.Allocator, src: []const u8) !*Bytearray {
        const self = try allocator.create(Bytearray);
        self.* = .{ .data = .empty };
        try self.data.appendSlice(allocator, src);
        return self;
    }

    pub fn zeroes(allocator: std.mem.Allocator, n: usize) !*Bytearray {
        const self = try allocator.create(Bytearray);
        self.* = .{ .data = .empty };
        try self.data.appendNTimes(allocator, 0, n);
        return self;
    }
};
