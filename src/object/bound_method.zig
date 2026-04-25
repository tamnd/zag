const std = @import("std");
const Value = @import("value.zig").Value;

/// A `BuiltinFn` paired with a `self` value. Pushed by LOAD_ATTR
/// when a method-shaped builtin is fetched in non-LOAD_METHOD form
/// (the decorator case `@prop.setter`), where there is no chance for
/// a subsequent CALL to inject `self`. The dispatcher prepends
/// `self` to the positional args when invoking.
pub const BoundMethod = struct {
    func: Value,
    self: Value,

    pub fn init(allocator: std.mem.Allocator, func: Value, self: Value) !*BoundMethod {
        const bm = try allocator.create(BoundMethod);
        bm.* = .{ .func = func, .self = self };
        return bm;
    }
};
