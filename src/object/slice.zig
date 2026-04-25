const std = @import("std");
const Value = @import("value.zig").Value;

/// CPython `slice(start, stop, step)` value. Each field is either
/// `Value.none` (Python's "default") or `.small_int`. Other shapes
/// aren't emitted by `py_compile` for the fixtures M4 covers.
pub const Slice = struct {
    start: Value,
    stop: Value,
    step: Value,

    pub fn init(allocator: std.mem.Allocator, start: Value, stop: Value, step: Value) !*Slice {
        const self = try allocator.create(Slice);
        self.* = .{ .start = start, .stop = stop, .step = step };
        return self;
    }
};
