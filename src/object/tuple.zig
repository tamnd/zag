const std = @import("std");
const Value = @import("value.zig").Value;

pub const Tuple = struct {
    items: []Value,

    pub fn init(allocator: std.mem.Allocator, n: usize) !*Tuple {
        const self = try allocator.create(Tuple);
        self.* = .{ .items = try allocator.alloc(Value, n) };
        return self;
    }

    pub fn fromSlice(allocator: std.mem.Allocator, items: []const Value) !*Tuple {
        const self = try allocator.create(Tuple);
        const buf = try allocator.alloc(Value, items.len);
        @memcpy(buf, items);
        self.* = .{ .items = buf };
        return self;
    }

    pub fn deinit(self: *Tuple, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        allocator.destroy(self);
    }
};
