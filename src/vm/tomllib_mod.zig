const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const datetime_mod = @import("datetime_mod.zig");
const Tuple = @import("../object/tuple.zig").Tuple;
const dispatch = @import("dispatch.zig");

const ParseError = error{TOMLError} || std.mem.Allocator.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError;

const Parser = struct {
    input: []const u8,
    pos: usize,
    interp: *Interp,

    fn init(interp: *Interp, input: []const u8) Parser {
        return .{ .input = input, .pos = 0, .interp = interp };
    }

    fn atEnd(self: *Parser) bool {
        return self.pos >= self.input.len;
    }

    fn expect(self: *Parser, c: u8) ParseError!void {
        if (self.pos >= self.input.len or self.input[self.pos] != c) return error.TOMLError;
        self.pos += 1;
    }

    fn skipToEndOfLine(self: *Parser) void {
        while (self.pos < self.input.len and self.input[self.pos] != '\n') self.pos += 1;
    }

    fn skipNewline(self: *Parser) void {
        if (self.pos < self.input.len and self.input[self.pos] == '\r') self.pos += 1;
        if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
    }

    fn skipWhitespaceAndNewlines(self: *Parser) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (c == '#') {
                self.skipToEndOfLine();
            } else break;
        }
    }

    fn skipLineWS(self: *Parser) void {
        while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t'))
            self.pos += 1;
    }

    // ===== Key =====

    fn parseKey(self: *Parser) ParseError![]const u8 {
        const a = self.interp.allocator;
        if (self.atEnd()) return error.TOMLError;
        const c = self.input[self.pos];
        if (c == '"') return self.parseBasicString();
        if (c == '\'') return self.parseLiteralString();
        const start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') self.pos += 1 else break;
        }
        if (self.pos == start) return error.TOMLError;
        return a.dupe(u8, self.input[start..self.pos]);
    }

    fn parseDottedKey(self: *Parser) ParseError![][]const u8 {
        const a = self.interp.allocator;
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        const first = try self.parseKey();
        try parts.append(a, first);
        self.skipLineWS();
        while (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            self.skipLineWS();
            const part = try self.parseKey();
            try parts.append(a, part);
            self.skipLineWS();
        }
        return parts.toOwnedSlice(a);
    }

    // ===== Strings =====

    fn parseBasicString(self: *Parser) ParseError![]const u8 {
        const a = self.interp.allocator;
        if (self.pos + 2 < self.input.len and
            self.input[self.pos] == '"' and self.input[self.pos + 1] == '"' and self.input[self.pos + 2] == '"')
        {
            self.pos += 3;
            return self.parseMultilineBasic();
        }
        self.pos += 1;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '"') { self.pos += 1; return buf.toOwnedSlice(a); }
            if (c == '\\') {
                self.pos += 1;
                const cp = try self.parseEscape();
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch return error.TOMLError;
                try buf.appendSlice(a, tmp[0..n]);
            } else {
                try buf.append(a, c);
                self.pos += 1;
            }
        }
        return error.TOMLError;
    }

    fn parseMultilineBasic(self: *Parser) ParseError![]const u8 {
        const a = self.interp.allocator;
        if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1
        else if (self.pos + 1 < self.input.len and self.input[self.pos] == '\r' and self.input[self.pos + 1] == '\n') self.pos += 2;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        while (self.pos < self.input.len) {
            if (self.pos + 2 < self.input.len and
                self.input[self.pos] == '"' and self.input[self.pos + 1] == '"' and self.input[self.pos + 2] == '"')
            {
                self.pos += 3;
                return buf.toOwnedSlice(a);
            }
            const c = self.input[self.pos];
            if (c == '\\') {
                self.pos += 1;
                const next = if (self.pos < self.input.len) self.input[self.pos] else 0;
                if (next == '\n' or next == '\r' or next == ' ' or next == '\t') {
                    while (self.pos < self.input.len) {
                        const ws = self.input[self.pos];
                        if (ws == ' ' or ws == '\t' or ws == '\n' or ws == '\r') self.pos += 1 else break;
                    }
                } else {
                    const cp = try self.parseEscape();
                    var tmp: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch return error.TOMLError;
                    try buf.appendSlice(a, tmp[0..n]);
                }
            } else {
                if (c == '\r' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\n') self.pos += 1;
                try buf.append(a, self.input[self.pos]);
                self.pos += 1;
            }
        }
        return error.TOMLError;
    }

    fn parseEscape(self: *Parser) ParseError!u21 {
        if (self.pos >= self.input.len) return error.TOMLError;
        const c = self.input[self.pos]; self.pos += 1;
        return switch (c) {
            'b' => 0x08, 't' => '\t', 'n' => '\n', 'f' => 0x0C, 'r' => '\r',
            '"' => '"', '\\' => '\\',
            'u' => blk: {
                if (self.pos + 4 > self.input.len) return error.TOMLError;
                const hex = self.input[self.pos .. self.pos + 4]; self.pos += 4;
                break :blk @intCast(try std.fmt.parseInt(u21, hex, 16));
            },
            'U' => blk: {
                if (self.pos + 8 > self.input.len) return error.TOMLError;
                const hex = self.input[self.pos .. self.pos + 8]; self.pos += 8;
                break :blk @intCast(try std.fmt.parseInt(u21, hex, 16));
            },
            else => error.TOMLError,
        };
    }

    fn parseLiteralString(self: *Parser) ParseError![]const u8 {
        const a = self.interp.allocator;
        if (self.pos + 2 < self.input.len and
            self.input[self.pos] == '\'' and self.input[self.pos + 1] == '\'' and self.input[self.pos + 2] == '\'')
        {
            self.pos += 3;
            return self.parseMultilineLiteral();
        }
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == '\'') {
                const s = self.input[start..self.pos]; self.pos += 1;
                return a.dupe(u8, s);
            }
            self.pos += 1;
        }
        return error.TOMLError;
    }

    fn parseMultilineLiteral(self: *Parser) ParseError![]const u8 {
        const a = self.interp.allocator;
        if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1
        else if (self.pos + 1 < self.input.len and self.input[self.pos] == '\r' and self.input[self.pos + 1] == '\n') self.pos += 2;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        while (self.pos < self.input.len) {
            if (self.pos + 2 < self.input.len and
                self.input[self.pos] == '\'' and self.input[self.pos + 1] == '\'' and self.input[self.pos + 2] == '\'')
            {
                self.pos += 3;
                return buf.toOwnedSlice(a);
            }
            const c = self.input[self.pos];
            if (c == '\r' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\n') self.pos += 1;
            try buf.append(a, self.input[self.pos]);
            self.pos += 1;
        }
        return error.TOMLError;
    }

    // ===== Numbers =====

    fn parseNumber(self: *Parser) ParseError!Value {
        const a = self.interp.allocator;
        // inf/nan without sign
        if (self.input.len - self.pos >= 3) {
            const w = self.input[self.pos .. self.pos + 3];
            if (std.mem.eql(u8, w, "inf")) { self.pos += 3; return Value{ .float = std.math.inf(f64) }; }
            if (std.mem.eql(u8, w, "nan")) { self.pos += 3; return Value{ .float = std.math.nan(f64) }; }
        }
        const sign: i64 = blk: {
            if (self.pos < self.input.len and self.input[self.pos] == '+') { self.pos += 1; break :blk 1; }
            if (self.pos < self.input.len and self.input[self.pos] == '-') { self.pos += 1; break :blk -1; }
            break :blk 1;
        };
        // inf/nan after sign
        if (self.input.len - self.pos >= 3) {
            const w = self.input[self.pos .. self.pos + 3];
            if (std.mem.eql(u8, w, "inf")) { self.pos += 3; return Value{ .float = if (sign < 0) -std.math.inf(f64) else std.math.inf(f64) }; }
            if (std.mem.eql(u8, w, "nan")) { self.pos += 3; return Value{ .float = std.math.nan(f64) }; }
        }
        // 0x / 0o / 0b
        if (self.pos < self.input.len and self.input[self.pos] == '0' and self.pos + 1 < self.input.len) {
            const nx = self.input[self.pos + 1];
            if (nx == 'x' or nx == 'X') {
                self.pos += 2;
                const s = self.parseDigitSpan("0123456789abcdefABCDEF_");
                const clean = try removeUnderscores(a, s);
                return Value{ .small_int = sign * try std.fmt.parseInt(i64, clean, 16) };
            }
            if (nx == 'o' or nx == 'O') {
                self.pos += 2;
                const s = self.parseDigitSpan("01234567_");
                const clean = try removeUnderscores(a, s);
                return Value{ .small_int = sign * try std.fmt.parseInt(i64, clean, 8) };
            }
            if (nx == 'b' or nx == 'B') {
                self.pos += 2;
                const s = self.parseDigitSpan("01_");
                const clean = try removeUnderscores(a, s);
                return Value{ .small_int = sign * try std.fmt.parseInt(i64, clean, 2) };
            }
        }
        // decimal int or float (sign already consumed)
        const nstart = self.pos;
        while (self.pos < self.input.len and (std.ascii.isDigit(self.input[self.pos]) or self.input[self.pos] == '_'))
            self.pos += 1;
        var is_float = false;
        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            is_float = true; self.pos += 1;
            while (self.pos < self.input.len and (std.ascii.isDigit(self.input[self.pos]) or self.input[self.pos] == '_'))
                self.pos += 1;
        }
        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            is_float = true; self.pos += 1;
            if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) self.pos += 1;
            while (self.pos < self.input.len and (std.ascii.isDigit(self.input[self.pos]) or self.input[self.pos] == '_'))
                self.pos += 1;
        }
        const raw = self.input[nstart..self.pos];
        const clean = try removeUnderscores(a, raw);
        if (is_float) {
            // sign prefix
            if (sign < 0) {
                var tmp: std.ArrayListUnmanaged(u8) = .empty;
                try tmp.append(a, '-');
                try tmp.appendSlice(a, clean);
                const f = try std.fmt.parseFloat(f64, try tmp.toOwnedSlice(a));
                return Value{ .float = f };
            }
            return Value{ .float = try std.fmt.parseFloat(f64, clean) };
        } else {
            const n = try std.fmt.parseInt(i64, clean, 10);
            return Value{ .small_int = sign * n };
        }
    }

    fn parseDigitSpan(self: *Parser, allowed: []const u8) []const u8 {
        const start = self.pos;
        while (self.pos < self.input.len and std.mem.indexOfScalar(u8, allowed, self.input[self.pos]) != null)
            self.pos += 1;
        return self.input[start..self.pos];
    }

    // ===== Datetime =====

    fn tryParseDatetime(self: *Parser) ParseError!?Value {
        const rest = self.input[self.pos..];
        if (rest.len < 10) return null;
        if (!std.ascii.isDigit(rest[0]) or !std.ascii.isDigit(rest[1]) or
            !std.ascii.isDigit(rest[2]) or !std.ascii.isDigit(rest[3]) or rest[4] != '-' or
            !std.ascii.isDigit(rest[5]) or !std.ascii.isDigit(rest[6]) or rest[7] != '-' or
            !std.ascii.isDigit(rest[8]) or !std.ascii.isDigit(rest[9])) return null;
        const year = try std.fmt.parseInt(i64, rest[0..4], 10);
        const month = try std.fmt.parseInt(i64, rest[5..7], 10);
        const day = try std.fmt.parseInt(i64, rest[8..10], 10);
        self.pos += 10;
        const interp = self.interp;
        if (self.pos >= self.input.len or
            (self.input[self.pos] != 'T' and self.input[self.pos] != 't' and self.input[self.pos] != ' '))
        {
            try datetime_mod.ensureClasses(interp);
            return try datetime_mod.newDatePub(interp, year, month, day);
        }
        self.pos += 1;
        const tc = try self.parseTimeComp();
        try datetime_mod.ensureClasses(interp);
        if (tc.tz_offset) |off| {
            const tz = try makeTz(interp, off);
            return try datetime_mod.newDatetimePub(interp, year, month, day, tc.h, tc.m, tc.s, tc.us, tz, 0);
        }
        return try datetime_mod.newDatetimePub(interp, year, month, day, tc.h, tc.m, tc.s, tc.us, Value.none, 0);
    }

    const TimeComp = struct { h: i64, m: i64, s: i64, us: i64, tz_offset: ?i64 };

    fn parseTimeComp(self: *Parser) ParseError!TimeComp {
        const rest = self.input[self.pos..];
        if (rest.len < 5) return error.TOMLError;
        if (!std.ascii.isDigit(rest[0]) or !std.ascii.isDigit(rest[1]) or rest[2] != ':' or
            !std.ascii.isDigit(rest[3]) or !std.ascii.isDigit(rest[4])) return error.TOMLError;
        const hh = try std.fmt.parseInt(i64, rest[0..2], 10);
        const mm = try std.fmt.parseInt(i64, rest[3..5], 10);
        self.pos += 5;
        var ss: i64 = 0;
        var us: i64 = 0;
        if (self.pos < self.input.len and self.input[self.pos] == ':') {
            self.pos += 1;
            if (self.pos + 2 > self.input.len) return error.TOMLError;
            ss = try std.fmt.parseInt(i64, self.input[self.pos .. self.pos + 2], 10);
            self.pos += 2;
            if (self.pos < self.input.len and self.input[self.pos] == '.') {
                self.pos += 1;
                const fstart = self.pos;
                while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
                const frac = self.input[fstart..self.pos];
                var us_str: [6]u8 = [_]u8{'0'} ** 6;
                const clen = @min(frac.len, 6);
                @memcpy(us_str[0..clen], frac[0..clen]);
                us = try std.fmt.parseInt(i64, &us_str, 10);
            }
        }
        var tz_offset: ?i64 = null;
        if (self.pos < self.input.len) {
            const tz = self.input[self.pos];
            if (tz == 'Z' or tz == 'z') { self.pos += 1; tz_offset = 0; }
            else if (tz == '+' or tz == '-') {
                const sign: i64 = if (tz == '+') 1 else -1;
                self.pos += 1;
                if (self.pos + 5 > self.input.len) return error.TOMLError;
                const tzh = try std.fmt.parseInt(i64, self.input[self.pos .. self.pos + 2], 10);
                self.pos += 2;
                if (self.input[self.pos] != ':') return error.TOMLError;
                self.pos += 1;
                const tzm = try std.fmt.parseInt(i64, self.input[self.pos .. self.pos + 2], 10);
                self.pos += 2;
                tz_offset = sign * (tzh * 3600 + tzm * 60);
            }
        }
        return .{ .h = hh, .m = mm, .s = ss, .us = us, .tz_offset = tz_offset };
    }

    fn tryParseTime(self: *Parser) ParseError!?Value {
        const rest = self.input[self.pos..];
        if (rest.len < 5) return null;
        if (!std.ascii.isDigit(rest[0]) or !std.ascii.isDigit(rest[1]) or rest[2] != ':' or
            !std.ascii.isDigit(rest[3]) or !std.ascii.isDigit(rest[4])) return null;
        if (rest.len > 5 and rest[5] != ':' and rest[5] != '.') return null;
        const tc = try self.parseTimeComp();
        const interp = self.interp;
        try datetime_mod.ensureClasses(interp);
        return try datetime_mod.newTimePub(interp, tc.h, tc.m, tc.s, tc.us, Value.none, 0);
    }

    // ===== Value =====

    fn parseValue(self: *Parser) ParseError!Value {
        const a = self.interp.allocator;
        if (self.atEnd()) return error.TOMLError;
        const c = self.input[self.pos];
        if (c == '"') { const s = try self.parseBasicString(); return Value{ .str = try Str.init(a, s) }; }
        if (c == '\'') { const s = try self.parseLiteralString(); return Value{ .str = try Str.init(a, s) }; }
        if (c == '[') return self.parseArray();
        if (c == '{') return self.parseInlineTable();
        if (self.input.len - self.pos >= 4 and std.mem.eql(u8, self.input[self.pos .. self.pos + 4], "true")) { self.pos += 4; return Value{ .boolean = true }; }
        if (self.input.len - self.pos >= 5 and std.mem.eql(u8, self.input[self.pos .. self.pos + 5], "false")) { self.pos += 5; return Value{ .boolean = false }; }
        if (std.ascii.isDigit(c)) {
            // Time: HH:MM
            if (self.input.len - self.pos >= 5 and std.ascii.isDigit(self.input[self.pos + 1]) and self.input[self.pos + 2] == ':') {
                if (try self.tryParseTime()) |v| return v;
            }
            // Date: YYYY-MM
            if (self.input.len - self.pos >= 10 and self.input[self.pos + 4] == '-') {
                if (try self.tryParseDatetime()) |v| return v;
            }
        }
        if (c == '+' or c == '-' or std.ascii.isDigit(c) or c == 'i' or c == 'n') return self.parseNumber();
        return error.TOMLError;
    }

    fn parseArray(self: *Parser) ParseError!Value {
        const a = self.interp.allocator;
        self.pos += 1;
        const list = try List.init(a);
        self.skipWhitespaceAndNewlines();
        while (self.pos < self.input.len and self.input[self.pos] != ']') {
            const v = try self.parseValue();
            try list.items.append(a, v);
            self.skipWhitespaceAndNewlines();
            if (self.pos < self.input.len and self.input[self.pos] == ',') {
                self.pos += 1;
                self.skipWhitespaceAndNewlines();
            }
        }
        if (self.pos >= self.input.len) return error.TOMLError;
        self.pos += 1;
        return Value{ .list = list };
    }

    fn parseInlineTable(self: *Parser) ParseError!Value {
        const a = self.interp.allocator;
        self.pos += 1;
        const d = try Dict.init(a);
        self.skipLineWS();
        while (self.pos < self.input.len and self.input[self.pos] != '}') {
            const parts = try self.parseDottedKey();
            self.skipLineWS();
            try self.expect('=');
            self.skipLineWS();
            const v = try self.parseValue();
            try setNestedKey(a, d, parts, v);
            self.skipLineWS();
            if (self.pos < self.input.len and self.input[self.pos] == ',') { self.pos += 1; self.skipLineWS(); }
        }
        if (self.pos >= self.input.len) return error.TOMLError;
        self.pos += 1;
        return Value{ .dict = d };
    }
};

// ===== Helpers =====

fn removeUnderscores(a: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '_') == null) return s;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| if (c != '_') try buf.append(a, c);
    return buf.toOwnedSlice(a);
}

fn setNestedKey(a: Allocator, d: *Dict, parts: []const []const u8, v: Value) !void {
    if (parts.len == 0) return error.TOMLError;
    if (parts.len == 1) { try d.setStr(a, parts[0], v); return; }
    const existing = d.getStr(parts[0]);
    if (existing) |ev| {
        if (ev != .dict) return error.TOMLError;
        try setNestedKey(a, ev.dict, parts[1..], v);
    } else {
        const sub = try Dict.init(a);
        try setNestedKey(a, sub, parts[1..], v);
        try d.setStr(a, parts[0], Value{ .dict = sub });
    }
}

fn resolveTable(a: Allocator, root: *Dict, parts: []const []const u8) !*Dict {
    var cur = root;
    for (parts) |part| {
        if (cur.getStr(part)) |ev| {
            switch (ev) {
                .dict => cur = ev.dict,
                .list => {
                    const lst = ev.list;
                    if (lst.items.items.len == 0) return error.TOMLError;
                    const last = lst.items.items[lst.items.items.len - 1];
                    if (last != .dict) return error.TOMLError;
                    cur = last.dict;
                },
                else => return error.TOMLError,
            }
        } else {
            const sub = try Dict.init(a);
            try cur.setStr(a, part, Value{ .dict = sub });
            cur = sub;
        }
    }
    return cur;
}

fn makeTz(interp: *Interp, offset_secs: i64) !Value {
    const a = interp.allocator;
    const td = try datetime_mod.newTimedeltaPub(interp, 0, @intCast(offset_secs), 0);
    const inst = try Instance.init(a, interp.dt_timezone_class.?);
    try inst.dict.setStr(a, "_offset", td);
    return Value{ .instance = inst };
}

fn raiseTomlError(interp: *Interp, msg: []const u8) !void {
    const a = interp.allocator;
    const cls = interp.toml_decode_error_class orelse {
        try interp.raisePy("ValueError", msg);
        return;
    };
    const inst = try Instance.init(a, cls);
    const t = try Tuple.init(a, 1);
    t.items[0] = Value{ .str = try Str.init(a, msg) };
    try inst.dict.setStr(a, "args", Value{ .tuple = t });
    interp.current_exc = Value{ .instance = inst };
}

// ===== Document parser =====

const DocumentParser = struct {
    p: Parser,
    root: *Dict,
    a: Allocator,
    opened: std.ArrayListUnmanaged([]const u8),
    aot_headers: std.ArrayListUnmanaged([]const u8),
    current: *Dict,

    fn init(interp: *Interp, input: []const u8) !DocumentParser {
        const a = interp.allocator;
        const root = try Dict.init(a);
        return .{
            .p = Parser.init(interp, input),
            .root = root,
            .a = a,
            .opened = .empty,
            .aot_headers = .empty,
            .current = root,
        };
    }

    fn flatKey(self: *DocumentParser, parts: []const []const u8) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (parts, 0..) |p, i| {
            if (i > 0) try buf.append(self.a, 0);
            try buf.appendSlice(self.a, p);
        }
        return buf.toOwnedSlice(self.a);
    }

    fn isOpened(self: *DocumentParser, key: []const u8) bool {
        for (self.opened.items) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }

    fn isAot(self: *DocumentParser, key: []const u8) bool {
        for (self.aot_headers.items) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }

    fn parse(self: *DocumentParser) ParseError!Value {
        const a = self.a;
        while (true) {
            self.p.skipWhitespaceAndNewlines();
            if (self.p.atEnd()) break;
            const c = self.p.input[self.p.pos];

            if (c == '[') {
                self.p.pos += 1;
                const is_array = self.p.pos < self.p.input.len and self.p.input[self.p.pos] == '[';
                if (is_array) self.p.pos += 1;
                self.p.skipLineWS();
                const parts = try self.p.parseDottedKey();
                self.p.skipLineWS();
                if (is_array) { try self.p.expect(']'); try self.p.expect(']'); }
                else try self.p.expect(']');
                self.p.skipLineWS();
                if (self.p.pos < self.p.input.len and self.p.input[self.p.pos] == '#') self.p.skipToEndOfLine();
                self.p.skipNewline();

                const flat = try self.flatKey(parts);
                if (is_array) {
                    try self.aot_headers.append(a, flat);
                    const parent = if (parts.len > 1) try resolveTable(a, self.root, parts[0 .. parts.len - 1]) else self.root;
                    const last_key = parts[parts.len - 1];
                    const new_table = try Dict.init(a);
                    if (parent.getStr(last_key)) |ev| {
                        if (ev != .list) return error.TOMLError;
                        try ev.list.items.append(a, Value{ .dict = new_table });
                    } else {
                        const list = try List.init(a);
                        try list.items.append(a, Value{ .dict = new_table });
                        try parent.setStr(a, last_key, Value{ .list = list });
                    }
                    self.current = new_table;
                } else {
                    if (self.isAot(flat)) return error.TOMLError;
                    if (self.isOpened(flat)) return error.TOMLError;
                    try self.opened.append(a, flat);
                    self.current = try resolveTable(a, self.root, parts);
                }
            } else if (c == '#') {
                self.p.skipToEndOfLine();
                self.p.skipNewline();
            } else {
                const parts = try self.p.parseDottedKey();
                self.p.skipLineWS();
                try self.p.expect('=');
                self.p.skipLineWS();
                const v = try self.p.parseValue();
                self.p.skipLineWS();
                if (self.p.pos < self.p.input.len and self.p.input[self.p.pos] == '#') self.p.skipToEndOfLine();
                self.p.skipNewline();
                if (parts.len == 1 and self.current.getStr(parts[0]) != null) return error.TOMLError;
                try setNestedKey(a, self.current, parts, v);
            }
        }
        return Value{ .dict = self.root };
    }
};

// ===== Module functions =====

fn tomlLoads(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "loads() argument must be str");
        return error.PyException;
    }
    var dp = try DocumentParser.init(interp, args[0].str.bytes);
    const result = dp.parse() catch |err| switch (err) {
        error.TOMLError, error.InvalidCharacter, error.Overflow => {
            try raiseTomlError(interp, "TOML decode error");
            return error.PyException;
        },
        else => return err,
    };
    return result;
}

fn tomlLoad(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) {
        try interp.raisePy("TypeError", "load() requires a file-like object");
        return error.PyException;
    }
    const fp = args[0];
    const read_attr = try dispatch.loadAttrValue(interp, fp, "read");
    const data = try dispatch.invoke(interp, read_attr, &.{});
    const bytes_slice: []const u8 = switch (data) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        else => {
            try interp.raisePy("TypeError", "file must be opened in binary mode");
            return error.PyException;
        },
    };
    const a = interp.allocator;
    const str_val = Value{ .str = try Str.init(a, bytes_slice) };
    return tomlLoads(p, &.{str_val});
}

fn regModFn(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "tomllib");

    if (interp.toml_decode_error_class == null) {
        const d = try Dict.init(a);
        if (interp.builtins.getStr("ValueError")) |exc_val| {
            interp.toml_decode_error_class = try Class.init(a, "TOMLDecodeError", &.{exc_val.class}, d);
        } else {
            interp.toml_decode_error_class = try Class.init(a, "TOMLDecodeError", &.{}, d);
        }
    }
    try m.attrs.setStr(a, "TOMLDecodeError", Value{ .class = interp.toml_decode_error_class.? });

    try regModFn(interp, m, "loads", tomlLoads);
    try regModFn(interp, m, "load", tomlLoad);

    return m;
}
