//! Pattern parser: produces an AST. The bytecode emitter lives in
//! `compile.zig` so pc patching is a single linear walk.

const std = @import("std");
const ast = @import("ast.zig");
const program = @import("program.zig");

const Node = ast.Node;
const Flags = program.Flags;

pub const Error = error{
    UnsupportedRegex,
    BadPattern,
    OutOfMemory,
};

pub const Parsed = struct {
    root: *Node,
    group_count: u32,
    /// Names indexed by 1-based group id; index 0 is "" placeholder for
    /// the implicit whole match.
    group_names: [][]const u8,

    pub fn deinit(self: *Parsed, a: std.mem.Allocator) void {
        ast.freeNode(a, self.root);
        a.destroy(self.root);
        for (self.group_names) |n| if (n.len > 0) a.free(n);
        a.free(self.group_names);
    }
};

pub fn parse(a: std.mem.Allocator, src: []const u8, flags: Flags) Error!Parsed {
    var p = Parser{
        .a = a,
        .src = src,
        .pos = 0,
        .flags = flags,
        .group_count = 0,
        .group_names = .empty,
    };
    errdefer {
        for (p.group_names.items) |n| if (n.len > 0) a.free(n);
        p.group_names.deinit(a);
    }
    try p.group_names.append(a, "");

    const root_ptr = try a.create(Node);
    errdefer a.destroy(root_ptr);
    root_ptr.* = try p.parseAlt();
    errdefer ast.freeNode(a, root_ptr);

    if (p.pos != src.len) return error.BadPattern;

    return .{
        .root = root_ptr,
        .group_count = p.group_count,
        .group_names = try p.group_names.toOwnedSlice(a),
    };
}

const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    pos: usize,
    flags: Flags,
    group_count: u32,
    group_names: std.ArrayList([]const u8),

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn advance(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.pos += 1;
        return c;
    }

    fn parseAlt(self: *Parser) Error!Node {
        const first = try self.parseConcat();
        if (self.peek() != @as(?u8, '|')) return first;
        var branches: std.ArrayList(Node) = .empty;
        errdefer {
            for (branches.items) |*b| ast.freeNode(self.a, b);
            branches.deinit(self.a);
        }
        try branches.append(self.a, first);
        while (self.peek() == @as(?u8, '|')) {
            _ = self.advance();
            try branches.append(self.a, try self.parseConcat());
        }
        return Node{ .alt = try branches.toOwnedSlice(self.a) };
    }

    fn parseConcat(self: *Parser) Error!Node {
        var parts: std.ArrayList(Node) = .empty;
        errdefer {
            for (parts.items) |*p| ast.freeNode(self.a, p);
            parts.deinit(self.a);
        }
        while (true) {
            const c = self.peek() orelse break;
            if (c == '|' or c == ')') break;
            try parts.append(self.a, try self.parseRepeat());
        }
        if (parts.items.len == 1) {
            const only = parts.items[0];
            parts.deinit(self.a);
            return only;
        }
        return Node{ .concat = try parts.toOwnedSlice(self.a) };
    }

    fn parseRepeat(self: *Parser) Error!Node {
        const atom = try self.parseAtom();
        const c = self.peek() orelse return atom;
        switch (c) {
            '*', '+', '?' => {
                _ = self.advance();
                const lazy = self.peek() == @as(?u8, '?');
                if (lazy) _ = self.advance();
                const min: u32 = if (c == '+') 1 else 0;
                const max: ?u32 = if (c == '?') @as(?u32, 1) else null;
                const inner = try self.a.create(Node);
                inner.* = atom;
                return Node{ .repeat = .{ .inner = inner, .min = min, .max = max, .lazy = lazy } };
            },
            '{' => {
                const save = self.pos;
                if (try self.tryRange()) |range| {
                    const inner = try self.a.create(Node);
                    inner.* = atom;
                    return Node{ .repeat = .{ .inner = inner, .min = range.min, .max = range.max, .lazy = range.lazy } };
                }
                self.pos = save;
                return atom;
            },
            else => return atom,
        }
    }

    const Range = struct { min: u32, max: ?u32, lazy: bool };

    fn tryRange(self: *Parser) Error!?Range {
        if (self.peek() != @as(?u8, '{')) return null;
        const save = self.pos;
        self.pos += 1;
        const n = self.parseUInt() orelse {
            self.pos = save;
            return null;
        };
        var max: ?u32 = @intCast(n);
        if (self.peek() == @as(?u8, ',')) {
            self.pos += 1;
            if (self.peek() == @as(?u8, '}')) {
                max = null;
            } else if (self.parseUInt()) |m| {
                max = @intCast(m);
            } else {
                self.pos = save;
                return null;
            }
        }
        if (self.peek() != @as(?u8, '}')) {
            self.pos = save;
            return null;
        }
        self.pos += 1;
        const lazy = self.peek() == @as(?u8, '?');
        if (lazy) _ = self.advance();
        return Range{ .min = @intCast(n), .max = max, .lazy = lazy };
    }

    fn parseUInt(self: *Parser) ?usize {
        var v: usize = 0;
        var any = false;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c < '0' or c > '9') break;
            v = v * 10 + (c - '0');
            self.pos += 1;
            any = true;
        }
        return if (any) v else null;
    }

    fn parseAtom(self: *Parser) Error!Node {
        const c = self.peek() orelse return error.BadPattern;
        switch (c) {
            '.' => {
                _ = self.advance();
                return Node.any;
            },
            '^' => {
                _ = self.advance();
                return Node.bol;
            },
            '$' => {
                _ = self.advance();
                return Node.eol;
            },
            '[' => return try self.parseClass(),
            '(' => return try self.parseGroup(),
            '\\' => return try self.parseEscape(),
            '*', '+', '?', '{', '|', ')' => return error.BadPattern,
            else => {
                _ = self.advance();
                return Node{ .literal = c };
            },
        }
    }

    fn parseGroup(self: *Parser) Error!Node {
        _ = self.advance(); // '('
        var capturing = true;
        var name: []const u8 = "";

        if (self.peek() == @as(?u8, '?')) {
            _ = self.advance();
            const c = self.advance() orelse return error.BadPattern;
            switch (c) {
                ':' => capturing = false,
                'P' => {
                    if (self.advance() != @as(?u8, '<')) return error.BadPattern;
                    const start = self.pos;
                    while (self.pos < self.src.len and self.src[self.pos] != '>') self.pos += 1;
                    if (self.pos >= self.src.len) return error.BadPattern;
                    name = try self.a.dupe(u8, self.src[start..self.pos]);
                    self.pos += 1; // '>'
                },
                else => return error.UnsupportedRegex,
            }
        }

        var gid: u32 = 0;
        if (capturing) {
            self.group_count += 1;
            gid = self.group_count;
            try self.group_names.append(self.a, name);
        } else if (name.len > 0) {
            self.a.free(name);
        }

        const inner_ptr = try self.a.create(Node);
        errdefer self.a.destroy(inner_ptr);
        inner_ptr.* = try self.parseAlt();
        errdefer ast.freeNode(self.a, inner_ptr);

        if (self.peek() != @as(?u8, ')')) return error.BadPattern;
        _ = self.advance();

        return Node{ .group = .{ .id = gid, .inner = inner_ptr } };
    }

    fn parseClass(self: *Parser) Error!Node {
        _ = self.advance(); // '['
        var set: [4]u64 = .{ 0, 0, 0, 0 };
        var negate = false;
        if (self.peek() == @as(?u8, '^')) {
            negate = true;
            _ = self.advance();
        }
        if (self.peek() == @as(?u8, ']')) {
            program.classSet(&set, ']');
            _ = self.advance();
        }
        while (true) {
            const c = self.peek() orelse return error.BadPattern;
            if (c == ']') {
                _ = self.advance();
                break;
            }
            const start_byte = try self.parseClassByte(&set);
            if (self.peek() == @as(?u8, '-')) {
                const lookahead_pos = self.pos + 1;
                if (lookahead_pos < self.src.len and self.src[lookahead_pos] != ']') {
                    _ = self.advance(); // '-'
                    const end_byte = try self.parseClassByte(&set);
                    if (start_byte) |sb| if (end_byte) |eb| {
                        var b: u16 = sb;
                        while (b <= eb) : (b += 1) program.classSet(&set, @intCast(b));
                    };
                }
            }
        }
        if (negate) {
            for (&set) |*w| w.* = ~w.*;
        }
        if (self.flags.ignore_case) foldClass(&set);
        return Node{ .class = .{ .set = set } };
    }

    fn parseClassByte(self: *Parser, set: *[4]u64) Error!?u8 {
        const c = self.advance() orelse return error.BadPattern;
        if (c == '\\') {
            const e = self.advance() orelse return error.BadPattern;
            switch (e) {
                'd' => {
                    fillDigit(set);
                    return null;
                },
                'D' => {
                    var tmp: [4]u64 = .{ 0, 0, 0, 0 };
                    fillDigit(&tmp);
                    var b: u16 = 0;
                    while (b < 256) : (b += 1) {
                        const cc: u8 = @intCast(b);
                        if (!program.classContains(tmp, cc)) program.classSet(set, cc);
                    }
                    return null;
                },
                'w' => {
                    fillWord(set);
                    return null;
                },
                'W' => {
                    var tmp: [4]u64 = .{ 0, 0, 0, 0 };
                    fillWord(&tmp);
                    var b: u16 = 0;
                    while (b < 256) : (b += 1) {
                        const cc: u8 = @intCast(b);
                        if (!program.classContains(tmp, cc)) program.classSet(set, cc);
                    }
                    return null;
                },
                's' => {
                    fillSpace(set);
                    return null;
                },
                'S' => {
                    var tmp: [4]u64 = .{ 0, 0, 0, 0 };
                    fillSpace(&tmp);
                    var b: u16 = 0;
                    while (b < 256) : (b += 1) {
                        const cc: u8 = @intCast(b);
                        if (!program.classContains(tmp, cc)) program.classSet(set, cc);
                    }
                    return null;
                },
                'n' => {
                    program.classSet(set, '\n');
                    return '\n';
                },
                't' => {
                    program.classSet(set, '\t');
                    return '\t';
                },
                'r' => {
                    program.classSet(set, '\r');
                    return '\r';
                },
                else => {
                    program.classSet(set, e);
                    return e;
                },
            }
        }
        program.classSet(set, c);
        return c;
    }

    fn parseEscape(self: *Parser) Error!Node {
        _ = self.advance(); // backslash
        const c = self.advance() orelse return error.BadPattern;
        switch (c) {
            'd' => {
                var s: [4]u64 = .{ 0, 0, 0, 0 };
                fillDigit(&s);
                return Node{ .class = .{ .set = s } };
            },
            'D' => {
                var s: [4]u64 = .{ 0, 0, 0, 0 };
                fillDigit(&s);
                for (&s) |*w| w.* = ~w.*;
                return Node{ .class = .{ .set = s } };
            },
            'w' => {
                var s: [4]u64 = .{ 0, 0, 0, 0 };
                fillWord(&s);
                return Node{ .class = .{ .set = s } };
            },
            'W' => {
                var s: [4]u64 = .{ 0, 0, 0, 0 };
                fillWord(&s);
                for (&s) |*w| w.* = ~w.*;
                return Node{ .class = .{ .set = s } };
            },
            's' => {
                var s: [4]u64 = .{ 0, 0, 0, 0 };
                fillSpace(&s);
                return Node{ .class = .{ .set = s } };
            },
            'S' => {
                var s: [4]u64 = .{ 0, 0, 0, 0 };
                fillSpace(&s);
                for (&s) |*w| w.* = ~w.*;
                return Node{ .class = .{ .set = s } };
            },
            'n' => return Node{ .literal = '\n' },
            't' => return Node{ .literal = '\t' },
            'r' => return Node{ .literal = '\r' },
            'b' => return Node.wb,
            'B' => return Node.nwb,
            'A', 'Z' => return error.UnsupportedRegex,
            '1'...'9' => return Node{ .backref = c - '0' },
            else => return Node{ .literal = c },
        }
    }
};

fn fillDigit(set: *[4]u64) void {
    var b: u16 = '0';
    while (b <= '9') : (b += 1) program.classSet(set, @intCast(b));
}

fn fillWord(set: *[4]u64) void {
    var b: u16 = 'a';
    while (b <= 'z') : (b += 1) program.classSet(set, @intCast(b));
    b = 'A';
    while (b <= 'Z') : (b += 1) program.classSet(set, @intCast(b));
    b = '0';
    while (b <= '9') : (b += 1) program.classSet(set, @intCast(b));
    program.classSet(set, '_');
}

fn fillSpace(set: *[4]u64) void {
    program.classSet(set, ' ');
    program.classSet(set, '\t');
    program.classSet(set, '\n');
    program.classSet(set, '\r');
    program.classSet(set, 0x0B);
    program.classSet(set, 0x0C);
}

fn foldClass(set: *[4]u64) void {
    var b: u16 = 'A';
    while (b <= 'Z') : (b += 1) {
        const upper: u8 = @intCast(b);
        const lower: u8 = upper + 32;
        if (program.classContains(set.*, upper)) program.classSet(set, lower);
        if (program.classContains(set.*, lower)) program.classSet(set, upper);
    }
}
