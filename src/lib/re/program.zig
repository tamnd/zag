//! Bytecode for the regex VM. See SPEC.md for the high-level design.
//!
//! Each `Inst` is an opcode + a small operand union. Programs are a
//! flat slice of instructions; `pc` indices point into it.

const std = @import("std");

pub const Op = enum {
    char,
    char_ci,
    any,
    class,
    bol,
    eol,
    wb,
    nwb,
    backref,
    save,
    jump,
    split,
    split_lazy,
    match,
};

pub const ClassId = u32;

pub const Inst = struct {
    op: Op,
    /// Per-op operand. Use the named accessor that matches the op.
    a: u32 = 0,
    b: u32 = 0,
};

/// Compiled pattern. `classes` are bitsets of 256 bits encoded as
/// 4 u64s. Group 0 covers the whole match; group_count is the number
/// of explicit capture groups (so total slots = 2 * (group_count + 1)).
pub const Program = struct {
    code: []Inst,
    classes: [][4]u64,
    /// Names of capture groups, indexed by group id (1-based). Empty
    /// string means an anonymous group.
    group_names: [][]const u8,
    group_count: u32,
    flags: Flags,

    pub fn deinit(self: *Program, a: std.mem.Allocator) void {
        a.free(self.code);
        a.free(self.classes);
        for (self.group_names) |n| if (n.len > 0) a.free(n);
        a.free(self.group_names);
        a.destroy(self);
    }
};

pub const Flags = packed struct {
    ignore_case: bool = false,
    multiline: bool = false,
    dotall: bool = false,
    _pad: u5 = 0,
};

/// Test if `c` matches the class bitset.
pub fn classContains(set: [4]u64, c: u8) bool {
    const word = c >> 6;
    const bit = @as(u64, 1) << @intCast(c & 63);
    return (set[word] & bit) != 0;
}

pub fn classSet(set: *[4]u64, c: u8) void {
    const word = c >> 6;
    const bit = @as(u64, 1) << @intCast(c & 63);
    set[word] |= bit;
}
