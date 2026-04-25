const std = @import("std");
const Value = @import("value.zig").Value;

/// `functools.partial(func, *args, **kwargs)`. Captures bound
/// positional and keyword arguments; later calls thread the bound
/// args first, then the call-site args, with bound kwargs merged in.
pub const Partial = struct {
    func: Value,
    args: []Value,
    kw_names: []Value,
    kw_values: []Value,

    pub fn init(
        allocator: std.mem.Allocator,
        func: Value,
        args: []const Value,
        kw_names: []const Value,
        kw_values: []const Value,
    ) !*Partial {
        const self = try allocator.create(Partial);
        const a_buf = try allocator.alloc(Value, args.len);
        @memcpy(a_buf, args);
        const kn_buf = try allocator.alloc(Value, kw_names.len);
        @memcpy(kn_buf, kw_names);
        const kv_buf = try allocator.alloc(Value, kw_values.len);
        @memcpy(kv_buf, kw_values);
        self.* = .{ .func = func, .args = a_buf, .kw_names = kn_buf, .kw_values = kv_buf };
        return self;
    }
};
