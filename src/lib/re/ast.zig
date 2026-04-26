//! Regex AST. The parser produces this; the compiler walks it to
//! emit bytecode. Keeping the two passes separate makes pc bookkeeping
//! straightforward — every quantifier knows the size of its body
//! before any pcs are baked in.

const std = @import("std");

pub const Node = union(enum) {
    literal: u8,
    any,
    bol,
    eol,
    bos,
    eos,
    wb,
    nwb,
    class: ClassRef,
    backref: u32,
    concat: []Node,
    alt: []Node,
    repeat: Repeat,
    group: Group,
};

pub const ClassRef = struct {
    set: [4]u64,
};

pub const Repeat = struct {
    inner: *Node,
    min: u32,
    /// `null` means open-ended.
    max: ?u32,
    lazy: bool,
};

pub const Group = struct {
    /// 0 means non-capturing.
    id: u32,
    inner: *Node,
};

pub fn freeNode(a: std.mem.Allocator, n: *Node) void {
    switch (n.*) {
        .concat => |xs| {
            for (xs) |*c| freeNode(a, c);
            a.free(xs);
        },
        .alt => |xs| {
            for (xs) |*c| freeNode(a, c);
            a.free(xs);
        },
        .repeat => |r| {
            freeNode(a, r.inner);
            a.destroy(r.inner);
        },
        .group => |g| {
            freeNode(a, g.inner);
            a.destroy(g.inner);
        },
        else => {},
    }
}
