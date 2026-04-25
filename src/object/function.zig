const std = @import("std");
const Value = @import("value.zig").Value;
const Code = @import("code.zig").Code;
const Dict = @import("dict.zig").Dict;
const Tuple = @import("tuple.zig").Tuple;

/// User-defined Python function. `defaults` is the trailing slice
/// that fills positional args from the right; `closure` is a tuple
/// of `*Cell` (still typed as Value here because the Tuple stores
/// Values uniformly) and lands in the inner frame via
/// `COPY_FREE_VARS`. Both are optional and start null.
pub const Function = struct {
    code: *Code,
    globals: *Dict,
    defaults: ?*Tuple = null,
    closure: ?*Tuple = null,
    kw_defaults: ?*Dict = null,

    pub fn init(allocator: std.mem.Allocator, code: *Code, globals: *Dict) !*Function {
        const self = try allocator.create(Function);
        self.* = .{ .code = code, .globals = globals };
        return self;
    }
};
