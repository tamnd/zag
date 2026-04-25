const std = @import("std");
const Value = @import("value.zig").Value;
const Dict = @import("dict.zig").Dict;

/// `collections.defaultdict(factory)`. Reads of a missing key call
/// `factory()` and insert the result; explicit `dd[k] = v` writes go
/// straight in. Stores ordered key/value pairs in `data` so
/// `dict(dd)` preserves insertion order.
pub const DefaultDict = struct {
    data: *Dict,
    factory: Value,

    pub fn init(allocator: std.mem.Allocator, factory: Value) !*DefaultDict {
        const self = try allocator.create(DefaultDict);
        self.* = .{ .data = try Dict.init(allocator), .factory = factory };
        return self;
    }
};
