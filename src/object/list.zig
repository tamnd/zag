const std = @import("std");
const Value = @import("value.zig").Value;

pub const List = struct {
    items: std.ArrayList(Value),

    pub fn init(allocator: std.mem.Allocator) !*List {
        const self = try allocator.create(List);
        self.* = .{ .items = .empty };
        return self;
    }

    pub fn append(self: *List, allocator: std.mem.Allocator, v: Value) !void {
        try self.items.append(allocator, v);
    }

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        allocator.destroy(self);
    }
};
