const std = @import("std");

/// Heap-allocated arbitrary-precision integer. Wraps
/// `std.math.big.int.Managed` so callers don't have to thread the
/// allocator through every cmp/repr; the value owns its limbs and is
/// dropped together with its arena.
pub const BigInt = struct {
    inner: std.math.big.int.Managed,

    pub fn fromI64(allocator: std.mem.Allocator, v: i64) !*BigInt {
        const self = try allocator.create(BigInt);
        self.inner = try std.math.big.int.Managed.initSet(allocator, v);
        return self;
    }

    pub fn fromManaged(allocator: std.mem.Allocator, m: std.math.big.int.Managed) !*BigInt {
        const self = try allocator.create(BigInt);
        self.inner = m;
        return self;
    }

    pub fn toString10(self: *const BigInt, allocator: std.mem.Allocator) ![]u8 {
        return self.inner.toString(allocator, 10, .lower);
    }
};
