const std = @import("std");
const Value = @import("value.zig").Value;
const Frame = @import("../vm/frame.zig").Frame;

/// Suspendable wrapper around a Frame. CPython models a generator as
/// a frame whose `f_lasti` and stack contents survive across calls;
/// `send(v)` resumes execution from the saved ip with `v` arriving as
/// the value of the most recent `yield` expression.
pub const Generator = struct {
    frame: *Frame,
    finished: bool = false,
    started: bool = false,

    pub fn init(allocator: std.mem.Allocator, frame: *Frame) !*Generator {
        const self = try allocator.create(Generator);
        self.* = .{ .frame = frame };
        return self;
    }
};
