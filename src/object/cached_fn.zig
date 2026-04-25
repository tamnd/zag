const std = @import("std");
const Value = @import("value.zig").Value;
const Dict = @import("dict.zig").Dict;
const Tuple = @import("tuple.zig").Tuple;

/// `functools.lru_cache` / `functools.cache` wrapper. The cache is
/// a `Dict` keyed by an args tuple; `Dict.setKey/getKey` already use
/// `Value.equals`, so any hashable mix of ints / strs / tuples / etc.
/// works as a key. `maxsize` is recorded but not actually enforced;
/// the fixture only checks miss/hit behavior, not eviction.
pub const CachedFn = struct {
    func: Value,
    cache: *Dict,
    /// `null` means unbounded (`functools.cache`).
    maxsize: ?usize,
    /// Override for `__name__`, used by `wraps` flow when the wrapper
    /// is itself decorated.
    name_override: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, func: Value, maxsize: ?usize) !*CachedFn {
        const self = try allocator.create(CachedFn);
        self.* = .{ .func = func, .cache = try Dict.init(allocator), .maxsize = maxsize };
        return self;
    }

    /// Build the cache key for a call. Two-or-more arg calls become a
    /// tuple; a single arg keys directly so `square(3)` doesn't
    /// allocate a 1-tuple wrapper for every call.
    pub fn keyFor(allocator: std.mem.Allocator, args: []const Value) !Value {
        if (args.len == 1) return args[0];
        const t = try Tuple.init(allocator, args.len);
        for (args, 0..) |a, i| t.items[i] = a;
        return Value{ .tuple = t };
    }
};
