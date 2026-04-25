const std = @import("std");
const Value = @import("value.zig").Value;
const Dict = @import("dict.zig").Dict;

/// `collections.OrderedDict`. zag's `Dict` already preserves
/// insertion order; OrderedDict only differs in the methods it
/// exposes (`move_to_end`, `popitem(last=...)`).
pub const OrderedDict = struct {
    data: *Dict,

    pub fn init(allocator: std.mem.Allocator) !*OrderedDict {
        const self = try allocator.create(OrderedDict);
        self.* = .{ .data = try Dict.init(allocator) };
        return self;
    }
};
