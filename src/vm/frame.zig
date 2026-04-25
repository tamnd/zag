const std = @import("std");
const Value = @import("../object/value.zig").Value;
const Code = @import("../object/code.zig").Code;
const Dict = @import("../object/dict.zig").Dict;

pub const Frame = struct {
    code: *Code,
    globals: *Dict,
    builtins: *Dict,
    locals: *Dict,

    fast: []Value,
    stack: []Value,
    sp: u32 = 0,
    ip: u32 = 0,

    back: ?*Frame = null,

    pub fn init(
        allocator: std.mem.Allocator,
        code: *Code,
        globals: *Dict,
        builtins: *Dict,
        locals: *Dict,
    ) !*Frame {
        const self = try allocator.create(Frame);
        const n_fast = code.localsplusnames.len;
        const fast = try allocator.alloc(Value, n_fast);
        for (fast) |*slot| slot.* = Value.null_sentinel;
        const stack_size: usize = @intCast(if (code.stacksize > 0) code.stacksize + 8 else 32);
        const stack = try allocator.alloc(Value, stack_size);
        self.* = .{
            .code = code,
            .globals = globals,
            .builtins = builtins,
            .locals = locals,
            .fast = fast,
            .stack = stack,
        };
        return self;
    }

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.fast);
        allocator.free(self.stack);
        allocator.destroy(self);
    }

    pub fn push(self: *Frame, v: Value) void {
        self.stack[self.sp] = v;
        self.sp += 1;
    }

    pub fn pop(self: *Frame) Value {
        self.sp -= 1;
        return self.stack[self.sp];
    }

    pub fn top(self: *Frame) Value {
        return self.stack[self.sp - 1];
    }

    pub fn peek(self: *Frame, n: u32) Value {
        return self.stack[self.sp - 1 - n];
    }
};
