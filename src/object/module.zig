const std = @import("std");
const Dict = @import("dict.zig").Dict;

/// A minimal module object: name plus a dict of attributes. Used for
/// builtin modules (e.g. `asyncio`), top-level user `.pyc` modules,
/// and packages — distinguished by `is_package`, which only affects
/// how `IMPORT_NAME` treats a non-empty fromlist.
pub const Module = struct {
    /// Fully-qualified dotted name (e.g. `"_39pkg.sub.leaf"`).
    name: []const u8,
    attrs: *Dict,
    /// True for `__init__.py` modules — packages can host submodule
    /// attributes, and `from pkg import sub` knows to eagerly load
    /// `pkg.sub` if it isn't already bound.
    is_package: bool = false,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !*Module {
        const self = try allocator.create(Module);
        self.* = .{ .name = name, .attrs = try Dict.init(allocator) };
        return self;
    }
};
