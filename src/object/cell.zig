const std = @import("std");
const Value = @import("value.zig").Value;

/// A single mutable Value box -- CPython's `PyCellObject`. Cells
/// back closure free vars: an outer function wraps a fast local in
/// a cell, the inner function's frame receives the same `*Cell`
/// via its closure tuple, and `LOAD_DEREF`/`STORE_DEREF` route
/// through the cell. `null_sentinel` is the empty marker.
pub const Cell = struct {
    value: Value = Value.null_sentinel,

    pub fn init(allocator: std.mem.Allocator, v: Value) !*Cell {
        const self = try allocator.create(Cell);
        self.* = .{ .value = v };
        return self;
    }
};
