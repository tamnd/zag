//! Replacement-string parser + applier. The bridge calls `apply` per
//! match with the source input and the match's span vector.

const std = @import("std");
const exec = @import("exec.zig");
const program = @import("program.zig");

const Span = exec.Span;
const NPOS = exec.NPOS;

pub const Piece = union(enum) {
    literal: []const u8,
    /// Group reference by id (1-based).
    group: u32,
};

pub const Template = struct {
    pieces: []Piece,
    /// Owns the literal byte buffer; group pieces point into it.
    buf: []u8,

    pub fn deinit(self: *Template, a: std.mem.Allocator) void {
        a.free(self.pieces);
        a.free(self.buf);
    }
};

pub const ParseError = error{ BadTemplate, OutOfMemory };

pub fn parseTemplate(
    a: std.mem.Allocator,
    repl: []const u8,
    pattern: *const program.Program,
) ParseError!Template {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    var i: usize = 0;
    var lit_start: usize = 0;

    // Stage pieces with `literal` carrying (offset,len) into a staging
    // vec, because `buf` may grow and invalidate slices mid-parse.
    const StagedLiteral = struct { off: usize, len: usize };
    const Staged = union(enum) { lit: StagedLiteral, grp: u32 };
    var staged: std.ArrayList(Staged) = .empty;
    defer staged.deinit(a);

    while (i < repl.len) {
        if (repl[i] != '\\') {
            if (i == lit_start) {} // begin literal
            i += 1;
            continue;
        }
        // flush literal up to i
        if (i > lit_start) {
            const off = buf.items.len;
            try buf.appendSlice(a, repl[lit_start..i]);
            try staged.append(a, .{ .lit = .{ .off = off, .len = i - lit_start } });
        }
        i += 1;
        if (i >= repl.len) return error.BadTemplate;
        const c = repl[i];
        i += 1;
        switch (c) {
            '\\' => {
                const off = buf.items.len;
                try buf.append(a, '\\');
                try staged.append(a, .{ .lit = .{ .off = off, .len = 1 } });
            },
            'n' => {
                const off = buf.items.len;
                try buf.append(a, '\n');
                try staged.append(a, .{ .lit = .{ .off = off, .len = 1 } });
            },
            't' => {
                const off = buf.items.len;
                try buf.append(a, '\t');
                try staged.append(a, .{ .lit = .{ .off = off, .len = 1 } });
            },
            'r' => {
                const off = buf.items.len;
                try buf.append(a, '\r');
                try staged.append(a, .{ .lit = .{ .off = off, .len = 1 } });
            },
            '0'...'9' => {
                try staged.append(a, .{ .grp = c - '0' });
            },
            'g' => {
                if (i >= repl.len or repl[i] != '<') return error.BadTemplate;
                i += 1;
                const ns = i;
                while (i < repl.len and repl[i] != '>') i += 1;
                if (i >= repl.len) return error.BadTemplate;
                const name = repl[ns..i];
                i += 1; // skip '>'
                if (name.len == 0) return error.BadTemplate;
                if (isAllDigits(name)) {
                    var v: u32 = 0;
                    for (name) |d| v = v * 10 + (d - '0');
                    try staged.append(a, .{ .grp = v });
                } else {
                    var found: ?u32 = null;
                    for (pattern.group_names, 0..) |gn, idx| {
                        if (std.mem.eql(u8, gn, name)) {
                            found = @intCast(idx);
                            break;
                        }
                    }
                    if (found) |g| try staged.append(a, .{ .grp = g }) else return error.BadTemplate;
                }
            },
            else => {
                // Unknown escape -> literal `\<c>` (CPython-ish for the
                // safe subset).
                const off = buf.items.len;
                try buf.append(a, '\\');
                try buf.append(a, c);
                try staged.append(a, .{ .lit = .{ .off = off, .len = 2 } });
            },
        }
        lit_start = i;
    }
    if (repl.len > lit_start) {
        const off = buf.items.len;
        try buf.appendSlice(a, repl[lit_start..]);
        try staged.append(a, .{ .lit = .{ .off = off, .len = repl.len - lit_start } });
    }

    const owned_buf = try buf.toOwnedSlice(a);
    errdefer a.free(owned_buf);

    var pieces_arr: std.ArrayList(Piece) = .empty;
    errdefer pieces_arr.deinit(a);
    for (staged.items) |s| switch (s) {
        .lit => |l| try pieces_arr.append(a, .{ .literal = owned_buf[l.off .. l.off + l.len] }),
        .grp => |g| try pieces_arr.append(a, .{ .group = g }),
    };

    return .{
        .pieces = try pieces_arr.toOwnedSlice(a),
        .buf = owned_buf,
    };
}

pub fn apply(a: std.mem.Allocator, t: Template, input: []const u8, spans: []const Span) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (t.pieces) |p| switch (p) {
        .literal => |s| try out.appendSlice(a, s),
        .group => |g| {
            if (g < spans.len) {
                const sp = spans[g];
                if (sp.start != NPOS and sp.end != NPOS) {
                    try out.appendSlice(a, input[sp.start..sp.end]);
                }
            }
        },
    };
    return try out.toOwnedSlice(a);
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}
