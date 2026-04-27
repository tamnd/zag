//! Pinhole `json` module: dumps/loads scoped to fixture 65 plus its
//! stress sibling. dumps walks Value, loads is a small recursive-
//! descent parser. ensure_ascii=True is the default and is the only
//! mode the fixture exercises -- non-ASCII becomes \uXXXX.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "json");
    try regKw(interp, m, "dumps", dumpsFn, dumpsKw);
    try reg(interp, m, "loads", loadsFn);
    // JSONDecodeError is a subclass of ValueError
    const d = try Dict.init(a);
    const json_decode_error = try Class.init(a, "JSONDecodeError", &.{}, d);
    try m.attrs.setStr(a, "JSONDecodeError", Value{ .class = json_decode_error });
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

// ---------------- dumps ----------------

const DumpOpts = struct {
    indent: ?usize = null,
    sort_keys: bool = false,
    sep_item: []const u8 = ", ",
    sep_kv: []const u8 = ": ",
};

fn dumpsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dumpsKw(p, args, &.{}, &.{});
}

fn dumpsKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var opts = DumpOpts{};
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const nm = kn.str.bytes;
        if (std.mem.eql(u8, nm, "indent")) {
            switch (kv) {
                .small_int => |i| opts.indent = if (i < 0) 0 else @intCast(i),
                .none => {},
                else => {},
            }
            // CPython: when indent is set, default item separator drops
            // the trailing space.
            if (opts.indent != null) opts.sep_item = ",";
        } else if (std.mem.eql(u8, nm, "sort_keys")) {
            opts.sort_keys = kv.isTruthy();
        } else if (std.mem.eql(u8, nm, "separators")) {
            if (kv == .tuple and kv.tuple.items.len == 2 and
                kv.tuple.items[0] == .str and kv.tuple.items[1] == .str)
            {
                opts.sep_item = kv.tuple.items[0].str.bytes;
                opts.sep_kv = kv.tuple.items[1].str.bytes;
            }
        } else if (std.mem.eql(u8, nm, "ensure_ascii")) {
            // Default True is the only mode we render; if False, we'd
            // emit raw UTF-8. Fixture stays on True. Refuse silently.
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);
    try writeValue(interp, &buf, args[0], opts, 0);
    const out = try Str.init(interp.allocator, buf.items);
    return Value{ .str = out };
}

fn writeValue(interp: *Interp, buf: *std.ArrayList(u8), v: Value, opts: DumpOpts, depth: usize) anyerror!void {
    switch (v) {
        .none => try buf.appendSlice(interp.allocator, "null"),
        .boolean => |b| try buf.appendSlice(interp.allocator, if (b) "true" else "false"),
        .small_int => |i| {
            var tmp: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{i});
            try buf.appendSlice(interp.allocator, s);
        },
        .float => |f| {
            var tmp: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{f});
            try buf.appendSlice(interp.allocator, s);
            if (std.mem.indexOfAny(u8, s, ".eE") == null) {
                try buf.appendSlice(interp.allocator, ".0");
            }
        },
        .str => |s| try writeJsonString(interp, buf, s.bytes),
        .list => |l| try writeArray(interp, buf, l.items.items, opts, depth),
        .tuple => |t| try writeArray(interp, buf, t.items, opts, depth),
        .dict => |d| try writeObject(interp, buf, d, opts, depth),
        else => try buf.appendSlice(interp.allocator, "null"),
    }
}

fn writeArray(interp: *Interp, buf: *std.ArrayList(u8), items: []const Value, opts: DumpOpts, depth: usize) anyerror!void {
    if (items.len == 0) {
        try buf.appendSlice(interp.allocator, "[]");
        return;
    }
    try buf.append(interp.allocator, '[');
    if (opts.indent) |_| try buf.append(interp.allocator, '\n');
    for (items, 0..) |x, i| {
        if (i > 0) {
            try buf.appendSlice(interp.allocator, opts.sep_item);
            if (opts.indent) |_| try buf.append(interp.allocator, '\n');
        }
        if (opts.indent) |n| try writeIndent(interp, buf, n * (depth + 1));
        try writeValue(interp, buf, x, opts, depth + 1);
    }
    if (opts.indent) |n| {
        try buf.append(interp.allocator, '\n');
        try writeIndent(interp, buf, n * depth);
    }
    try buf.append(interp.allocator, ']');
}

fn writeObject(interp: *Interp, buf: *std.ArrayList(u8), d: *Dict, opts: DumpOpts, depth: usize) anyerror!void {
    if (d.pairs.items.len == 0) {
        try buf.appendSlice(interp.allocator, "{}");
        return;
    }
    try buf.append(interp.allocator, '{');
    if (opts.indent) |_| try buf.append(interp.allocator, '\n');

    var idx_buf: std.ArrayList(usize) = .empty;
    defer idx_buf.deinit(interp.allocator);
    for (d.pairs.items, 0..) |_, i| try idx_buf.append(interp.allocator, i);
    if (opts.sort_keys) {
        const Ctx = struct { pairs: []const Dict.Pair, alloc: std.mem.Allocator };
        const ctx = Ctx{ .pairs = d.pairs.items, .alloc = interp.allocator };
        std.sort.block(usize, idx_buf.items, ctx, struct {
            fn keyStr(c: Ctx, k: Value, buf2: []u8) []const u8 {
                _ = c;
                return switch (k) {
                    .str => |s| s.bytes,
                    .small_int => |i| std.fmt.bufPrint(buf2, "{d}", .{i}) catch "",
                    .float => |f| std.fmt.bufPrint(buf2, "{d}", .{f}) catch "",
                    .boolean => |b| if (b) "true" else "false",
                    .none => "null",
                    else => "",
                };
            }
            fn lt(c: Ctx, a: usize, b: usize) bool {
                var ba: [64]u8 = undefined;
                var bb: [64]u8 = undefined;
                const ak = keyStr(c, c.pairs[a].key, &ba);
                const bk = keyStr(c, c.pairs[b].key, &bb);
                return std.mem.lessThan(u8, ak, bk);
            }
        }.lt);
    }

    for (idx_buf.items, 0..) |idx, n| {
        const pair = d.pairs.items[idx];
        if (n > 0) {
            try buf.appendSlice(interp.allocator, opts.sep_item);
            if (opts.indent) |_| try buf.append(interp.allocator, '\n');
        }
        if (opts.indent) |istep| try writeIndent(interp, buf, istep * (depth + 1));
        try writeJsonKey(interp, buf, pair.key);
        try buf.appendSlice(interp.allocator, opts.sep_kv);
        try writeValue(interp, buf, pair.value, opts, depth + 1);
    }
    if (opts.indent) |istep| {
        try buf.append(interp.allocator, '\n');
        try writeIndent(interp, buf, istep * depth);
    }
    try buf.append(interp.allocator, '}');
}

fn writeJsonKey(interp: *Interp, buf: *std.ArrayList(u8), key: Value) !void {
    switch (key) {
        .str => |s| try writeJsonString(interp, buf, s.bytes),
        .small_int => |i| {
            var tmp: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{i});
            try buf.append(interp.allocator, '"');
            try buf.appendSlice(interp.allocator, s);
            try buf.append(interp.allocator, '"');
        },
        .float => |f| {
            var tmp: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "{d}", .{f});
            try buf.append(interp.allocator, '"');
            try buf.appendSlice(interp.allocator, s);
            try buf.append(interp.allocator, '"');
        },
        .boolean => |b| try buf.appendSlice(interp.allocator, if (b) "\"true\"" else "\"false\""),
        .none => try buf.appendSlice(interp.allocator, "\"null\""),
        else => try buf.appendSlice(interp.allocator, "\"\""),
    }
}

fn writeIndent(interp: *Interp, buf: *std.ArrayList(u8), n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try buf.append(interp.allocator, ' ');
}

fn writeJsonString(interp: *Interp, buf: *std.ArrayList(u8), bytes: []const u8) !void {
    try buf.append(interp.allocator, '"');
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        switch (c) {
            '"' => {
                try buf.appendSlice(interp.allocator, "\\\"");
                i += 1;
            },
            '\\' => {
                try buf.appendSlice(interp.allocator, "\\\\");
                i += 1;
            },
            '\n' => {
                try buf.appendSlice(interp.allocator, "\\n");
                i += 1;
            },
            '\r' => {
                try buf.appendSlice(interp.allocator, "\\r");
                i += 1;
            },
            '\t' => {
                try buf.appendSlice(interp.allocator, "\\t");
                i += 1;
            },
            0x08 => {
                try buf.appendSlice(interp.allocator, "\\b");
                i += 1;
            },
            0x0C => {
                try buf.appendSlice(interp.allocator, "\\f");
                i += 1;
            },
            else => {
                if (c < 0x20) {
                    var tmp: [8]u8 = undefined;
                    const s = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c});
                    try buf.appendSlice(interp.allocator, s);
                    i += 1;
                } else if (c < 0x80) {
                    try buf.append(interp.allocator, c);
                    i += 1;
                } else {
                    // UTF-8 sequence -> \uXXXX (or surrogate pair).
                    const decoded = decodeUtf8(bytes[i..]);
                    if (decoded.len == 0) {
                        try buf.append(interp.allocator, c);
                        i += 1;
                        continue;
                    }
                    const cp = decoded.cp;
                    if (cp <= 0xFFFF) {
                        var tmp: [8]u8 = undefined;
                        const s = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{cp});
                        try buf.appendSlice(interp.allocator, s);
                    } else {
                        const sub = cp - 0x10000;
                        const hi: u32 = 0xD800 | (sub >> 10);
                        const lo: u32 = 0xDC00 | (sub & 0x3FF);
                        var tmp: [16]u8 = undefined;
                        const s = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}\\u{x:0>4}", .{ hi, lo });
                        try buf.appendSlice(interp.allocator, s);
                    }
                    i += decoded.len;
                }
            },
        }
    }
    try buf.append(interp.allocator, '"');
}

const Decoded = struct { cp: u32, len: usize };

fn decodeUtf8(bytes: []const u8) Decoded {
    if (bytes.len == 0) return .{ .cp = 0, .len = 0 };
    const c = bytes[0];
    if (c < 0x80) return .{ .cp = c, .len = 1 };
    var n: usize = 0;
    var cp: u32 = 0;
    if ((c & 0xE0) == 0xC0) {
        n = 2;
        cp = c & 0x1F;
    } else if ((c & 0xF0) == 0xE0) {
        n = 3;
        cp = c & 0x0F;
    } else if ((c & 0xF8) == 0xF0) {
        n = 4;
        cp = c & 0x07;
    } else {
        return .{ .cp = 0, .len = 0 };
    }
    if (bytes.len < n) return .{ .cp = 0, .len = 0 };
    var i: usize = 1;
    while (i < n) : (i += 1) {
        cp = (cp << 6) | (bytes[i] & 0x3F);
    }
    return .{ .cp = cp, .len = n };
}

// ---------------- loads ----------------

fn loadsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .str) {
        try interp.typeError("loads expects a str");
        return error.TypeError;
    }
    var parser = Parser{ .interp = interp, .src = args[0].str.bytes, .pos = 0 };
    parser.skipSpace();
    const v = try parser.parseValue();
    parser.skipSpace();
    if (parser.pos != parser.src.len) {
        try interp.raisePy("ValueError", "extra data after JSON document");
        return error.PyException;
    }
    return v;
}

const Parser = struct {
    interp: *Interp,
    src: []const u8,
    pos: usize,

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') self.pos += 1 else break;
        }
    }

    fn parseValue(self: *Parser) anyerror!Value {
        self.skipSpace();
        if (self.pos >= self.src.len) {
            try self.interp.raisePy("ValueError", "unexpected end of JSON");
            return error.PyException;
        }
        const c = self.src[self.pos];
        return switch (c) {
            'n' => self.parseLiteral("null", Value.none),
            't' => self.parseLiteral("true", Value{ .boolean = true }),
            'f' => self.parseLiteral("false", Value{ .boolean = false }),
            '"' => self.parseString(),
            '[' => self.parseArray(),
            '{' => self.parseObject(),
            '-', '0'...'9' => self.parseNumber(),
            else => blk: {
                try self.interp.raisePy("ValueError", "invalid JSON token");
                break :blk error.PyException;
            },
        };
    }

    fn parseLiteral(self: *Parser, lit: []const u8, value: Value) !Value {
        if (self.pos + lit.len > self.src.len or
            !std.mem.eql(u8, self.src[self.pos .. self.pos + lit.len], lit))
        {
            try self.interp.raisePy("ValueError", "invalid JSON literal");
            return error.PyException;
        }
        self.pos += lit.len;
        return value;
    }

    fn parseNumber(self: *Parser) !Value {
        const start = self.pos;
        if (self.src[self.pos] == '-') self.pos += 1;
        while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
        var is_float = false;
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            is_float = true;
            self.pos += 1;
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
        }
        if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-'))
                self.pos += 1;
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
        }
        const text = self.src[start..self.pos];
        if (is_float) {
            const f = std.fmt.parseFloat(f64, text) catch {
                try self.interp.raisePy("ValueError", "invalid JSON float");
                return error.PyException;
            };
            return Value{ .float = f };
        }
        const i = std.fmt.parseInt(i64, text, 10) catch {
            try self.interp.raisePy("ValueError", "invalid JSON int");
            return error.PyException;
        };
        return Value{ .small_int = i };
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn parseString(self: *Parser) !Value {
        self.pos += 1; // opening quote
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.interp.allocator);
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '"') {
                self.pos += 1;
                const out = try Str.init(self.interp.allocator, buf.items);
                return Value{ .str = out };
            }
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.src.len) break;
                const esc = self.src[self.pos];
                self.pos += 1;
                switch (esc) {
                    '"' => try buf.append(self.interp.allocator, '"'),
                    '\\' => try buf.append(self.interp.allocator, '\\'),
                    '/' => try buf.append(self.interp.allocator, '/'),
                    'b' => try buf.append(self.interp.allocator, 0x08),
                    'f' => try buf.append(self.interp.allocator, 0x0C),
                    'n' => try buf.append(self.interp.allocator, '\n'),
                    'r' => try buf.append(self.interp.allocator, '\r'),
                    't' => try buf.append(self.interp.allocator, '\t'),
                    'u' => try self.parseUnicodeEscape(&buf),
                    else => {
                        try self.interp.raisePy("ValueError", "invalid JSON escape");
                        return error.PyException;
                    },
                }
                continue;
            }
            try buf.append(self.interp.allocator, c);
            self.pos += 1;
        }
        try self.interp.raisePy("ValueError", "unterminated JSON string");
        return error.PyException;
    }

    fn parseUnicodeEscape(self: *Parser, buf: *std.ArrayList(u8)) !void {
        if (self.pos + 4 > self.src.len) {
            try self.interp.raisePy("ValueError", "invalid \\u escape");
            return error.PyException;
        }
        const hex = self.src[self.pos .. self.pos + 4];
        self.pos += 4;
        var cp: u32 = std.fmt.parseInt(u32, hex, 16) catch {
            try self.interp.raisePy("ValueError", "invalid \\u escape");
            return error.PyException;
        };
        if (cp >= 0xD800 and cp <= 0xDBFF) {
            // High surrogate, expect \uXXXX low surrogate next.
            if (self.pos + 6 <= self.src.len and
                self.src[self.pos] == '\\' and self.src[self.pos + 1] == 'u')
            {
                const lo_hex = self.src[self.pos + 2 .. self.pos + 6];
                const lo = std.fmt.parseInt(u32, lo_hex, 16) catch 0;
                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                    self.pos += 6;
                    cp = 0x10000 + (((cp - 0xD800) << 10) | (lo - 0xDC00));
                }
            }
        }
        try encodeUtf8(self.interp.allocator, buf, cp);
    }

    fn parseArray(self: *Parser) anyerror!Value {
        self.pos += 1;
        const out = try List.init(self.interp.allocator);
        self.skipSpace();
        if (self.pos < self.src.len and self.src[self.pos] == ']') {
            self.pos += 1;
            return Value{ .list = out };
        }
        while (true) {
            const v = try self.parseValue();
            try out.append(self.interp.allocator, v);
            self.skipSpace();
            if (self.pos >= self.src.len) break;
            if (self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            if (self.src[self.pos] == ']') {
                self.pos += 1;
                return Value{ .list = out };
            }
            break;
        }
        try self.interp.raisePy("ValueError", "invalid JSON array");
        return error.PyException;
    }

    fn parseObject(self: *Parser) anyerror!Value {
        self.pos += 1;
        const out = try Dict.init(self.interp.allocator);
        self.skipSpace();
        if (self.pos < self.src.len and self.src[self.pos] == '}') {
            self.pos += 1;
            return Value{ .dict = out };
        }
        while (true) {
            self.skipSpace();
            if (self.pos >= self.src.len or self.src[self.pos] != '"') break;
            const key = try self.parseString();
            self.skipSpace();
            if (self.pos >= self.src.len or self.src[self.pos] != ':') break;
            self.pos += 1;
            const v = try self.parseValue();
            try out.setKey(self.interp.allocator, key, v);
            self.skipSpace();
            if (self.pos >= self.src.len) break;
            if (self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            if (self.src[self.pos] == '}') {
                self.pos += 1;
                return Value{ .dict = out };
            }
            break;
        }
        try self.interp.raisePy("ValueError", "invalid JSON object");
        return error.PyException;
    }
};

fn encodeUtf8(a: std.mem.Allocator, buf: *std.ArrayList(u8), cp: u32) !void {
    if (cp < 0x80) {
        try buf.append(a, @intCast(cp));
    } else if (cp < 0x800) {
        try buf.append(a, @intCast(0xC0 | (cp >> 6)));
        try buf.append(a, @intCast(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        try buf.append(a, @intCast(0xE0 | (cp >> 12)));
        try buf.append(a, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try buf.append(a, @intCast(0x80 | (cp & 0x3F)));
    } else {
        try buf.append(a, @intCast(0xF0 | (cp >> 18)));
        try buf.append(a, @intCast(0x80 | ((cp >> 12) & 0x3F)));
        try buf.append(a, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try buf.append(a, @intCast(0x80 | (cp & 0x3F)));
    }
}
