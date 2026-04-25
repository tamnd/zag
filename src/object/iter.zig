const std = @import("std");
const Value = @import("value.zig").Value;
const List = @import("list.zig").List;
const Tuple = @import("tuple.zig").Tuple;

/// Iterator over the sequence types fixtures need today. Tag carries
/// the source kind; `index` is a forward cursor. `next()` returns
/// null on exhaustion.
pub const Iter = struct {
    kind: Kind,
    index: usize = 0,

    pub const Kind = union(enum) {
        list: *List,
        tuple: *Tuple,
    };

    pub fn init(allocator: std.mem.Allocator, kind: Kind) !*Iter {
        const self = try allocator.create(Iter);
        self.* = .{ .kind = kind };
        return self;
    }

    pub fn next(self: *Iter) ?Value {
        switch (self.kind) {
            .list => |l| {
                if (self.index >= l.items.items.len) return null;
                const v = l.items.items[self.index];
                self.index += 1;
                return v;
            },
            .tuple => |t| {
                if (self.index >= t.items.len) return null;
                const v = t.items[self.index];
                self.index += 1;
                return v;
            },
        }
    }
};
