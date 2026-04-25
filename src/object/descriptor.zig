const std = @import("std");
const Value = @import("value.zig").Value;

/// Wrapper for the three descriptor builtins the fixtures need:
/// `property`, `classmethod`, `staticmethod`. Each just decorates an
/// underlying callable; `loadAttr` reads `kind` and decides how to
/// bind the callable when the attribute is fetched.
///
/// Properties additionally carry `fset` / `fdel` so `@x.setter` and
/// `@x.deleter` can attach the matching callable. Both default to
/// `Value.none` (no setter / deleter installed).
pub const Descriptor = struct {
    kind: Kind,
    func: Value,
    fset: Value = .none,
    fdel: Value = .none,

    pub const Kind = enum { property, classmethod, staticmethod };

    pub fn init(allocator: std.mem.Allocator, kind: Kind, func: Value) !*Descriptor {
        const self = try allocator.create(Descriptor);
        self.* = .{ .kind = kind, .func = func };
        return self;
    }
};
