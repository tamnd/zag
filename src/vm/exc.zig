//! CPython 3.14 exception-table decoding. The table on the code
//! object is a sequence of entries, each four varints:
//! `start`, `length`, `target` (in code units, *2 for byte offset)
//! and `depth_lasti` (`depth = >> 1`, `lasti = & 1`).
//!
//! The varint format: low 6 bits of each byte carry data, bit 0x40
//! is "more bytes follow". The 0x80 bit on an entry's first byte is
//! a structural sanity marker -- masked off by `& 0x3F` along with
//! the continuation bit.

const std = @import("std");

pub const Entry = struct {
    /// First byte offset covered by this handler, inclusive.
    start: u32,
    /// One past the last byte offset covered.
    end: u32,
    /// Byte offset of the handler.
    target: u32,
    /// Stack depth the handler expects (sp truncates to this before
    /// the exception is pushed).
    depth: u32,
    /// If set, push the lasti (caller IP) underneath the exception.
    lasti: bool,
};

fn parseVarint(table: []const u8, pos: *usize) u32 {
    var b = table[pos.*];
    pos.* += 1;
    var val: u32 = b & 0x3F;
    while (b & 0x40 != 0) {
        b = table[pos.*];
        pos.* += 1;
        val = (val << 6) | (b & 0x3F);
    }
    return val;
}

/// Find the handler covering byte offset `ip`. First match wins;
/// CPython lays them out so that's the innermost.
pub fn findHandler(table: []const u8, ip: u32) ?Entry {
    var pos: usize = 0;
    while (pos < table.len) {
        const start = parseVarint(table, &pos) * 2;
        const length = parseVarint(table, &pos) * 2;
        const target = parseVarint(table, &pos) * 2;
        const dl = parseVarint(table, &pos);
        if (ip >= start and ip < start + length) {
            return .{
                .start = start,
                .end = start + length,
                .target = target,
                .depth = dl >> 1,
                .lasti = (dl & 1) != 0,
            };
        }
    }
    return null;
}
