const std = @import("std");

const Bytes = @import("bytes.zig").Bytes;
const Bytearray = @import("bytearray.zig").Bytearray;

/// Zero-copy view over a `Bytes` or `Bytearray`. The backing kind is
/// what determines `readonly` -- bytes views can't be assigned to,
/// bytearray views can. Slice-of-slice shares the same source so a
/// write through a sub-view is visible through the parent.
pub const Memoryview = struct {
    backing: Backing,
    start: usize,
    len: usize,

    pub const Backing = union(enum) {
        bytes: *Bytes,
        bytearray: *Bytearray,
    };

    pub fn fromBytes(allocator: std.mem.Allocator, b: *Bytes) !*Memoryview {
        const self = try allocator.create(Memoryview);
        self.* = .{ .backing = .{ .bytes = b }, .start = 0, .len = b.data.len };
        return self;
    }

    pub fn fromBytearray(allocator: std.mem.Allocator, b: *Bytearray) !*Memoryview {
        const self = try allocator.create(Memoryview);
        self.* = .{ .backing = .{ .bytearray = b }, .start = 0, .len = b.data.items.len };
        return self;
    }

    pub fn slice(self: *const Memoryview, allocator: std.mem.Allocator, start: usize, len: usize) !*Memoryview {
        const out = try allocator.create(Memoryview);
        out.* = .{ .backing = self.backing, .start = self.start + start, .len = len };
        return out;
    }

    pub fn data(self: *const Memoryview) []const u8 {
        return switch (self.backing) {
            .bytes => |b| b.data[self.start .. self.start + self.len],
            .bytearray => |b| b.data.items[self.start .. self.start + self.len],
        };
    }

    pub fn writableData(self: *const Memoryview) ?[]u8 {
        return switch (self.backing) {
            .bytes => null,
            .bytearray => |b| b.data.items[self.start .. self.start + self.len],
        };
    }

    pub fn readonly(self: *const Memoryview) bool {
        return self.backing == .bytes;
    }
};
