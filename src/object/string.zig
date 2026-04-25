const std = @import("std");

/// Immutable UTF-8 string. `bytes` is owned by `allocator` passed at
/// creation. CPython's PEP 393 kind-tagged storage is not emulated;
/// length-in-codepoints is computed lazily on first call to `len()`.
pub const Str = struct {
    bytes: []const u8,
    /// -1 means "not computed yet".
    cached_codepoint_len: i64 = -1,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !*Str {
        const self = try allocator.create(Str);
        const owned = try allocator.dupe(u8, bytes);
        self.* = .{ .bytes = owned };
        return self;
    }

    /// Take ownership of an already-allocated slice.
    pub fn fromOwnedSlice(allocator: std.mem.Allocator, bytes: []const u8) !*Str {
        const self = try allocator.create(Str);
        self.* = .{ .bytes = bytes };
        return self;
    }

    pub fn deinit(self: *Str, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.destroy(self);
    }

    pub fn len(self: *Str) usize {
        if (self.cached_codepoint_len < 0) {
            const n = std.unicode.utf8CountCodepoints(self.bytes) catch self.bytes.len;
            self.cached_codepoint_len = @intCast(n);
        }
        return @intCast(self.cached_codepoint_len);
    }
};
