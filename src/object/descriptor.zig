const std = @import("std");
const Value = @import("value.zig").Value;

/// Wrapper for the three descriptor builtins the fixtures need:
/// `property`, `classmethod`, `staticmethod`. Each just decorates an
/// underlying callable; `loadAttr` reads `kind` and decides how to
/// bind the callable when the attribute is fetched.
pub const Descriptor = struct {
    kind: Kind,
    func: Value,

    pub const Kind = enum { property, classmethod, staticmethod };

    pub fn init(allocator: std.mem.Allocator, kind: Kind, func: Value) !*Descriptor {
        const self = try allocator.create(Descriptor);
        self.* = .{ .kind = kind, .func = func };
        return self;
    }
};
