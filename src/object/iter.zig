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
        range: Range,
    };

    /// Positive-step half-open range. Negative steps and the full
    /// `range` sequence object aren't in scope until a fixture forces
    /// them.
    pub const Range = struct {
        start: i64 = 0,
        current: i64,
        stop: i64,
        step: i64,
    };

    pub fn rangeLen(r: Range) i64 {
        if (r.step > 0) {
            if (r.start >= r.stop) return 0;
            return @divTrunc(r.stop - r.start - 1, r.step) + 1;
        }
        if (r.step < 0) {
            if (r.start <= r.stop) return 0;
            return @divTrunc(r.start - r.stop - 1, -r.step) + 1;
        }
        return 0;
    }

    pub fn rangeContains(r: Range, n: i64) bool {
        if (r.step > 0) {
            if (n < r.start or n >= r.stop) return false;
            return @mod(n - r.start, r.step) == 0;
        }
        if (r.step < 0) {
            if (n > r.start or n <= r.stop) return false;
            return @mod(r.start - n, -r.step) == 0;
        }
        return false;
    }

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
            .range => |*r| {
                if (r.step > 0) {
                    if (r.current >= r.stop) return null;
                } else if (r.step < 0) {
                    if (r.current <= r.stop) return null;
                } else return null;
                const v = r.current;
                r.current += r.step;
                return Value{ .small_int = v };
            },
        }
    }
};
