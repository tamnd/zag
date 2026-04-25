//! zag library root. External consumers import `@import("zag")` and
//! reach the marshal / object / vm namespaces through here.

pub const op = @import("op/opcode.zig");
pub const object = struct {
    pub const value = @import("object/value.zig");
    pub const code = @import("object/code.zig");
    pub const dict = @import("object/dict.zig");
    pub const string = @import("object/string.zig");
    pub const tuple = @import("object/tuple.zig");
};
pub const marshal = struct {
    pub const pyc = @import("marshal/pyc.zig");
    pub const reader = @import("marshal/reader.zig");
};
pub const vm = struct {
    pub const interp = @import("vm/interp.zig");
    pub const frame = @import("vm/frame.zig");
    pub const dispatch = @import("vm/dispatch.zig");
    pub const builtins = @import("vm/builtins.zig");
};
