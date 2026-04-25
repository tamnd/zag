const std = @import("std");
const Value = @import("value.zig").Value;
const Dict = @import("dict.zig").Dict;

/// A user-defined Python class. `mro` is the linearized parent
/// chain starting with `self` -- single-inheritance for now (the
/// fixtures don't yet force C3). `dict` is the class namespace
/// produced by running the class body function under
/// `__build_class__`.
pub const Class = struct {
    name: []const u8,
    bases: []*Class,
    dict: *Dict,
    mro: []*Class,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        bases: []const *Class,
        dict: *Dict,
    ) !*Class {
        const self = try allocator.create(Class);
        const bases_buf = try allocator.alloc(*Class, bases.len);
        @memcpy(bases_buf, bases);
        self.* = .{
            .name = name,
            .bases = bases_buf,
            .dict = dict,
            .mro = undefined,
        };
        // Single-inheritance MRO: self, then bases[0]'s MRO, ...
        // For multi-inheritance the day a fixture needs it.
        var list: std.ArrayList(*Class) = .empty;
        defer list.deinit(allocator);
        try list.append(allocator, self);
        for (bases) |b| {
            for (b.mro) |c| {
                var seen = false;
                for (list.items) |x| if (x == c) {
                    seen = true;
                    break;
                };
                if (!seen) try list.append(allocator, c);
            }
        }
        self.mro = try allocator.dupe(*Class, list.items);
        return self;
    }

    /// Walk the MRO looking for `name`. Returns the resolving
    /// class and the value, or null if not found.
    pub fn lookup(self: *Class, name: []const u8) ?Value {
        for (self.mro) |cls| {
            if (cls.dict.getStr(name)) |v| return v;
        }
        return null;
    }
};
