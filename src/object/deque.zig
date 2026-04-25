const std = @import("std");
const Value = @import("value.zig").Value;
const List = @import("list.zig").List;

pub const Deque = struct {
    items: *List,
    maxlen: ?usize,

    pub fn init(allocator: std.mem.Allocator, items: *List, maxlen: ?usize) !*Deque {
        const self = try allocator.create(Deque);
        self.* = .{ .items = items, .maxlen = maxlen };
        return self;
    }

    pub fn append(self: *Deque, allocator: std.mem.Allocator, v: Value) !void {
        try self.items.append(allocator, v);
        if (self.maxlen) |ml| {
            while (self.items.items.items.len > ml) _ = self.items.items.orderedRemove(0);
        }
    }

    pub fn appendLeft(self: *Deque, allocator: std.mem.Allocator, v: Value) !void {
        try self.items.items.insert(allocator, 0, v);
        if (self.maxlen) |ml| {
            while (self.items.items.items.len > ml) _ = self.items.items.pop();
        }
    }

    pub fn pop(self: *Deque) ?Value {
        return self.items.items.pop();
    }

    pub fn popLeft(self: *Deque) ?Value {
        if (self.items.items.items.len == 0) return null;
        return self.items.items.orderedRemove(0);
    }

    pub fn rotate(self: *Deque, n: i64) void {
        const len = self.items.items.items.len;
        if (len == 0) return;
        const ilen: i64 = @intCast(len);
        var k = @mod(n, ilen);
        if (k < 0) k += ilen;
        if (k == 0) return;
        // Right-rotate by k: move last k to the front.
        const buf = self.items.items.items;
        std.mem.reverse(Value, buf);
        std.mem.reverse(Value, buf[0..@intCast(k)]);
        std.mem.reverse(Value, buf[@intCast(k)..]);
    }

    pub fn reverse(self: *Deque) void {
        std.mem.reverse(Value, self.items.items.items);
    }
};
