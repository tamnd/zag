//! `collections.namedtuple` runtime support.
//!
//! The factory returned by `namedtuple("Point", ["x", "y"])` is a
//! `Value{ .named_tuple_factory = ... }`. Calling it builds a
//! `Value{ .named_tuple = ... }` instance bound to the same factory
//! (so all instances share the field-name table and `_fields`).
//!
//! Field access, indexing, iteration, length, equality, repr, and
//! `_asdict` / `_replace` / `_fields` are handled in dispatch.zig.

const std = @import("std");
const Value = @import("value.zig").Value;

pub const NamedTupleFactory = struct {
    type_name: []const u8,
    fields: []const []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        type_name: []const u8,
        fields: []const []const u8,
    ) !*NamedTupleFactory {
        const self = try allocator.create(NamedTupleFactory);
        self.* = .{ .type_name = type_name, .fields = fields };
        return self;
    }
};

pub const NamedTuple = struct {
    factory: *NamedTupleFactory,
    items: []Value,

    pub fn init(
        allocator: std.mem.Allocator,
        factory: *NamedTupleFactory,
        items: []const Value,
    ) !*NamedTuple {
        const self = try allocator.create(NamedTuple);
        const buf = try allocator.alloc(Value, items.len);
        @memcpy(buf, items);
        self.* = .{ .factory = factory, .items = buf };
        return self;
    }
};
