//! Zig-level smoke tests for the regex engine.

const std = @import("std");
const re = @import("re.zig");

fn matchSpan(a: std.mem.Allocator, pat: []const u8, input: []const u8, flags: re.Flags) !?[]const u8 {
    const p = try re.compile(a, pat, flags);
    defer p.deinit(a);
    if (try re.match(a, p, input)) |m| {
        var mm = m;
        defer mm.deinit(a);
        return try a.dupe(u8, input[mm.spans[0].start..mm.spans[0].end]);
    }
    return null;
}

fn searchSpan(a: std.mem.Allocator, pat: []const u8, input: []const u8, flags: re.Flags) !?[]const u8 {
    const p = try re.compile(a, pat, flags);
    defer p.deinit(a);
    if (try re.search(a, p, input, 0)) |m| {
        var mm = m;
        defer mm.deinit(a);
        return try a.dupe(u8, input[mm.spans[0].start..mm.spans[0].end]);
    }
    return null;
}

test "literal anchored match" {
    const a = std.testing.allocator;
    const got = try matchSpan(a, "abc", "abcdef", .{});
    defer if (got) |g| a.free(g);
    try std.testing.expectEqualStrings("abc", got.?);
}

test "digit class search" {
    const a = std.testing.allocator;
    const got = try searchSpan(a, "\\d+", "abc123def", .{});
    defer if (got) |g| a.free(g);
    try std.testing.expectEqualStrings("123", got.?);
}

test "no match returns null" {
    const a = std.testing.allocator;
    const got = try matchSpan(a, "\\d+", "abc", .{});
    try std.testing.expect(got == null);
}

test "alternation" {
    const a = std.testing.allocator;
    {
        const got = try searchSpan(a, "cat|dog|fish", "I have a dog and a fish", .{});
        defer if (got) |g| a.free(g);
        try std.testing.expectEqualStrings("dog", got.?);
    }
    {
        const got = try searchSpan(a, "cat|dog|fish", "fishy", .{});
        defer if (got) |g| a.free(g);
        try std.testing.expectEqualStrings("fish", got.?);
    }
}

test "groups capture" {
    const a = std.testing.allocator;
    const p = try re.compile(a, "(\\w+)=(\\d+)", .{});
    defer p.deinit(a);
    var m = (try re.search(a, p, "foo=42", 0)).?;
    defer m.deinit(a);
    const sp1 = m.spans[1];
    const sp2 = m.spans[2];
    try std.testing.expectEqualStrings("foo", "foo=42"[sp1.start..sp1.end]);
    try std.testing.expectEqualStrings("42", "foo=42"[sp2.start..sp2.end]);
}

test "ignore case" {
    const a = std.testing.allocator;
    const got = try searchSpan(a, "cat", "CAT", .{ .ignore_case = true });
    defer if (got) |g| a.free(g);
    try std.testing.expectEqualStrings("CAT", got.?);
}

test "fullmatch" {
    const a = std.testing.allocator;
    const p = try re.compile(a, "\\d+", .{});
    defer p.deinit(a);
    try std.testing.expect((try re.fullmatch(a, p, "123")) != null);
    try std.testing.expect((try re.fullmatch(a, p, "123abc")) == null);
}

test "lazy star" {
    const a = std.testing.allocator;
    const p = try re.compile(a, "<.*?>", .{});
    defer p.deinit(a);
    var m = (try re.search(a, p, "<a><b>", 0)).?;
    defer m.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.spans[0].start);
    try std.testing.expectEqual(@as(usize, 3), m.spans[0].end);
}

test "repetition range" {
    const a = std.testing.allocator;
    const p = try re.compile(a, "a{2,4}", .{});
    defer p.deinit(a);
    var m = (try re.search(a, p, "aaaaa", 0)).?;
    defer m.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), m.spans[0].end - m.spans[0].start);
}

test "backref" {
    const a = std.testing.allocator;
    const p = try re.compile(a, "(\\w+)\\s+\\1", .{});
    defer p.deinit(a);
    try std.testing.expect((try re.search(a, p, "hello hello", 0)) != null);
    try std.testing.expect((try re.search(a, p, "hello world", 0)) == null);
}

test "anchors" {
    const a = std.testing.allocator;
    const p = try re.compile(a, "^abc$", .{});
    defer p.deinit(a);
    try std.testing.expect((try re.fullmatch(a, p, "abc")) != null);
}

test "multiline" {
    const a = std.testing.allocator;
    const p = try re.compile(a, "^\\w", .{ .multiline = true });
    defer p.deinit(a);
    var m = (try re.search(a, p, "abc\ndef", 4)).?;
    defer m.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), m.spans[0].start);
}
