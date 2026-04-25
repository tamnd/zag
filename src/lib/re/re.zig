//! Public façade for the regex engine.

const std = @import("std");

pub const program = @import("program.zig");
pub const ast = @import("ast.zig");
pub const parse = @import("parse.zig");
pub const compile_mod = @import("compile.zig");
pub const exec = @import("exec.zig");
pub const replace_mod = @import("replace.zig");

test {
    _ = @import("tests.zig");
}

pub const Pattern = program.Program;
pub const Flags = program.Flags;
pub const Match = exec.Match;
pub const Span = exec.Span;
pub const NPOS = exec.NPOS;
pub const Error = parse.Error;

pub fn compile(a: std.mem.Allocator, pattern: []const u8, flags: Flags) Error!*Pattern {
    return try compile_mod.compile(a, pattern, flags);
}

pub fn deinit(p: *Pattern, a: std.mem.Allocator) void {
    p.deinit(a);
}

pub fn match(a: std.mem.Allocator, p: *const Pattern, input: []const u8) !?Match {
    return try exec.match(a, p, input);
}

pub fn fullmatch(a: std.mem.Allocator, p: *const Pattern, input: []const u8) !?Match {
    return try exec.fullmatch(a, p, input);
}

pub fn search(a: std.mem.Allocator, p: *const Pattern, input: []const u8, start: usize) !?Match {
    return try exec.search(a, p, input, start);
}

pub fn groupName(p: *const Pattern, idx: usize) ?[]const u8 {
    if (idx >= p.group_names.len) return null;
    const n = p.group_names[idx];
    if (n.len == 0) return null;
    return n;
}

pub fn groupIndex(p: *const Pattern, name: []const u8) ?usize {
    for (p.group_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

pub fn groupCount(p: *const Pattern) usize {
    return p.group_count;
}
