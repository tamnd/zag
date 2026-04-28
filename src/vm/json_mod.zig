//! `json` module — dumps/loads for fixtures 65 and 207.

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
const Instance = @import("../object/instance.zig").Instance;
const Bytes = @import("../object/bytes.zig").Bytes;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

var g_json_decode_error_class: ?*Class = null;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "json");
    try regKw(interp, m, "dumps", dumpsFn, dumpsKw);
    try regKw(interp, m, "dump", dumpFn, dumpKw);
    try regKw(interp, m, "loads", loadsFn, loadsKw);
    try reg(interp, m, "load", loadFn);

    // JSONDecodeError is a subclass of ValueError
    const d = try Dict.init(a);
    var value_error_bases: [1]*Class = undefined;
    var jde_bases: []const *Class = &.{};
    if (interp.builtins.getStr("ValueError")) |ve| {
        if (ve == .class) {
            value_error_bases[0] = ve.class;
            jde_bases = value_error_bases[0..1];
        }
    }
    const jde = try Class.init(a, "JSONDecodeError", jde_bases, d);
    g_json_decode_error_class = jde;
    try m.attrs.setStr(a, "JSONDecodeError", Value{ .class = jde });

    // JSONEncoder class
    const enc_d = try Dict.init(a);
    try regDKw(a, enc_d, "__init__", encoderInitFn, encoderInitKw);
    try regD(a, enc_d, "encode", encoderEncode);
    const enc_cls = try Class.init(a, "JSONEncoder", &.{}, enc_d);
    try m.attrs.setStr(a, "JSONEncoder", Value{ .class = enc_cls });

    // JSONDecoder class
    const dec_d = try Dict.init(a);
    try regDKw(a, dec_d, "__init__", decoderInitFn, decoderInitKw);
    try regD(a, dec_d, "decode", decoderDecode);
    try regD(a, dec_d, "raw_decode", decoderRawDecode);
    const dec_cls = try Class.init(a, "JSONDecoder", &.{}, dec_d);
    try m.attrs.setStr(a, "JSONDecoder", Value{ .class = dec_cls });

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

fn regD(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regDKw(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn gi(p: *anyopaque) *Interp {
    return @ptrCast(@alignCast(p));
}

// ─── DumpOpts ────────────────────────────────────────────────────────────────

const DumpOpts = struct {
    indent: ?usize = null,
    sort_keys: bool = false,
    sep_item: []const u8 = ", ",
    sep_kv: []const u8 = ": ",
    ensure_ascii: bool = true,
    allow_nan: bool = true,
    skip_keys: bool = false,
    default_fn: Value = Value.none,
};

fn parseDumpOpts(opts: *DumpOpts, kw_names: []const Value, kw_values: []const Value) void {
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const nm = kn.str.bytes;
        if (std.mem.eql(u8, nm, "indent")) {
            switch (kv) {
                .small_int => |i| opts.indent = if (i < 0) 0 else @intCast(i),
                .none => {},
                else => {},
            }
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
            opts.ensure_ascii = kv.isTruthy();
        } else if (std.mem.eql(u8, nm, "allow_nan")) {
            opts.allow_nan = kv.isTruthy();
        } else if (std.mem.eql(u8, nm, "skipkeys")) {
            opts.skip_keys = kv.isTruthy();
        } else if (std.mem.eql(u8, nm, "default")) {
            opts.default_fn = kv;
        }
    }
}

// ─── dumps ───────────────────────────────────────────────────────────────────

fn dumpsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dumpsKw(p, args, &.{}, &.{});
}

fn dumpsKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    var opts = DumpOpts{};
    parseDumpOpts(&opts, kw_names, kw_values);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);
    try writeValue(interp, &buf, args[0], opts, 0);
    const out = try Str.init(interp.allocator, buf.items);
    return Value{ .str = out };
}

// ─── dump (to file) ──────────────────────────────────────────────────────────

fn dumpFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dumpKw(p, args, &.{}, &.{});
}

fn dumpKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    if (args.len < 2) return Value.none;
    var opts = DumpOpts{};
    parseDumpOpts(&opts, kw_names, kw_values);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);
    try writeValue(interp, &buf, args[0], opts, 0);
    // Write to file-like object (args[1]) via .write method
    const fp = args[1];
    const s = try Str.init(interp.allocator, buf.items);
    const write_fn = try dispatch.loadAttrValue(interp, fp, "write");
    _ = try dispatch.invoke(interp, write_fn, &.{Value{ .str = s }});
    return Value.none;
}

// ─── write helpers ───────────────────────────────────────────────────────────

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
            if (std.math.isNan(f)) {
                if (!opts.allow_nan) {
                    try interp.raisePy("ValueError", "Out of range float values are not JSON compliant");
                    return error.PyException;
                }
                try buf.appendSlice(interp.allocator, "NaN");
            } else if (std.math.isPositiveInf(f)) {
                if (!opts.allow_nan) {
                    try interp.raisePy("ValueError", "Out of range float values are not JSON compliant");
                    return error.PyException;
                }
                try buf.appendSlice(interp.allocator, "Infinity");
            } else if (std.math.isNegativeInf(f)) {
                if (!opts.allow_nan) {
                    try interp.raisePy("ValueError", "Out of range float values are not JSON compliant");
                    return error.PyException;
                }
                try buf.appendSlice(interp.allocator, "-Infinity");
            } else {
                var tmp: [64]u8 = undefined;
                const s = try std.fmt.bufPrint(&tmp, "{d}", .{f});
                try buf.appendSlice(interp.allocator, s);
                if (std.mem.indexOfAny(u8, s, ".eE") == null) {
                    try buf.appendSlice(interp.allocator, ".0");
                }
            }
        },
        .str => |s| try writeJsonString(interp, buf, s.bytes, opts.ensure_ascii),
        .list => |l| try writeArray(interp, buf, l.items.items, opts, depth),
        .tuple => |t| try writeArray(interp, buf, t.items, opts, depth),
        .dict => |d| try writeObject(interp, buf, d, opts, depth),
        else => {
            // Try default_fn
            if (opts.default_fn != .none) {
                const result = try dispatch.invoke(interp, opts.default_fn, &.{v});
                try writeValue(interp, buf, result, opts, depth);
            } else {
                try interp.raisePy("TypeError", "Object of unknown type is not JSON serializable");
                return error.PyException;
            }
        },
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
    // Build index list, optionally filtering non-string keys (skipkeys)
    var idx_buf: std.ArrayList(usize) = .empty;
    defer idx_buf.deinit(interp.allocator);
    for (d.pairs.items, 0..) |pair, i| {
        if (opts.skip_keys and pair.key != .str) continue;
        try idx_buf.append(interp.allocator, i);
    }
    if (idx_buf.items.len == 0) {
        try buf.appendSlice(interp.allocator, "{}");
        return;
    }
    if (opts.sort_keys) {
        const Ctx = struct { pairs: []const Dict.Pair };
        const ctx = Ctx{ .pairs = d.pairs.items };
        std.sort.block(usize, idx_buf.items, ctx, struct {
            fn keyStr(_: Ctx, k: Value, b: []u8) []const u8 {
                return switch (k) {
                    .str => |s| s.bytes,
                    .small_int => |i| std.fmt.bufPrint(b, "{d}", .{i}) catch "",
                    .float => |f| std.fmt.bufPrint(b, "{d}", .{f}) catch "",
                    .boolean => |bv| if (bv) "true" else "false",
                    .none => "null",
                    else => "",
                };
            }
            fn lt(c: Ctx, a: usize, bv: usize) bool {
                var ba: [64]u8 = undefined;
                var bb: [64]u8 = undefined;
                const ak = keyStr(c, c.pairs[a].key, &ba);
                const bk = keyStr(c, c.pairs[bv].key, &bb);
                return std.mem.lessThan(u8, ak, bk);
            }
        }.lt);
    }
    try buf.append(interp.allocator, '{');
    if (opts.indent) |_| try buf.append(interp.allocator, '\n');
    for (idx_buf.items, 0..) |idx, n| {
        const pair = d.pairs.items[idx];
        if (n > 0) {
            try buf.appendSlice(interp.allocator, opts.sep_item);
            if (opts.indent) |_| try buf.append(interp.allocator, '\n');
        }
        if (opts.indent) |istep| try writeIndent(interp, buf, istep * (depth + 1));
        try writeJsonKey(interp, buf, pair.key, opts.ensure_ascii);
        try buf.appendSlice(interp.allocator, opts.sep_kv);
        try writeValue(interp, buf, pair.value, opts, depth + 1);
    }
    if (opts.indent) |istep| {
        try buf.append(interp.allocator, '\n');
        try writeIndent(interp, buf, istep * depth);
    }
    try buf.append(interp.allocator, '}');
}

fn writeJsonKey(interp: *Interp, buf: *std.ArrayList(u8), key: Value, ensure_ascii: bool) !void {
    switch (key) {
        .str => |s| try writeJsonString(interp, buf, s.bytes, ensure_ascii),
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

fn writeJsonString(interp: *Interp, buf: *std.ArrayList(u8), bytes: []const u8, ensure_ascii: bool) !void {
    try buf.append(interp.allocator, '"');
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        switch (c) {
            '"' => { try buf.appendSlice(interp.allocator, "\\\""); i += 1; },
            '\\' => { try buf.appendSlice(interp.allocator, "\\\\"); i += 1; },
            '\n' => { try buf.appendSlice(interp.allocator, "\\n"); i += 1; },
            '\r' => { try buf.appendSlice(interp.allocator, "\\r"); i += 1; },
            '\t' => { try buf.appendSlice(interp.allocator, "\\t"); i += 1; },
            0x08 => { try buf.appendSlice(interp.allocator, "\\b"); i += 1; },
            0x0C => { try buf.appendSlice(interp.allocator, "\\f"); i += 1; },
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
                    const decoded = decodeUtf8(bytes[i..]);
                    if (decoded.len == 0) {
                        try buf.append(interp.allocator, c);
                        i += 1;
                        continue;
                    }
                    if (!ensure_ascii) {
                        // Emit raw UTF-8 bytes
                        try buf.appendSlice(interp.allocator, bytes[i .. i + decoded.len]);
                    } else {
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
    if ((c & 0xE0) == 0xC0) { n = 2; cp = c & 0x1F; }
    else if ((c & 0xF0) == 0xE0) { n = 3; cp = c & 0x0F; }
    else if ((c & 0xF8) == 0xF0) { n = 4; cp = c & 0x07; }
    else return .{ .cp = 0, .len = 0 };
    if (bytes.len < n) return .{ .cp = 0, .len = 0 };
    var i: usize = 1;
    while (i < n) : (i += 1) cp = (cp << 6) | (bytes[i] & 0x3F);
    return .{ .cp = cp, .len = n };
}

// ─── loads ───────────────────────────────────────────────────────────────────

const LoadOpts = struct {
    object_hook: Value = Value.none,
    parse_float: Value = Value.none,
    parse_int: Value = Value.none,
};

fn loadsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return loadsKw(p, args, &.{}, &.{});
}

fn loadsKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    if (args.len < 1) {
        try interp.typeError("loads expects a str/bytes argument");
        return error.TypeError;
    }
    const src: []const u8 = switch (args[0]) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        else => {
            try interp.typeError("loads expects str, bytes or bytearray");
            return error.TypeError;
        },
    };
    var opts = LoadOpts{};
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const nm = kn.str.bytes;
        if (std.mem.eql(u8, nm, "object_hook")) opts.object_hook = kv;
        if (std.mem.eql(u8, nm, "parse_float")) opts.parse_float = kv;
        if (std.mem.eql(u8, nm, "parse_int")) opts.parse_int = kv;
    }
    var parser = Parser{ .interp = interp, .src = src, .pos = 0, .opts = opts };
    parser.skipSpace();
    const v = try parser.parseValue();
    parser.skipSpace();
    if (parser.pos != parser.src.len) {
        try raiseJsonDecodeError(interp, src, parser.pos, "Extra data");
        return error.PyException;
    }
    return v;
}

// ─── load (from file) ────────────────────────────────────────────────────────

fn loadFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    if (args.len < 1) return Value.none;
    // Call fp.read() to get the content
    const read_fn = try dispatch.loadAttrValue(interp, args[0], "read");
    const content = try dispatch.invoke(interp, read_fn, &.{});
    const src: []const u8 = switch (content) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        else => return Value.none,
    };
    var parser = Parser{ .interp = interp, .src = src, .pos = 0, .opts = .{} };
    parser.skipSpace();
    const v = try parser.parseValue();
    return v;
}

// ─── JSONDecodeError ─────────────────────────────────────────────────────────

fn raiseJsonDecodeError(interp: *Interp, doc: []const u8, pos: usize, msg: []const u8) !void {
    const a = interp.allocator;
    const cls = g_json_decode_error_class orelse {
        try interp.raisePy("ValueError", msg);
        return;
    };
    const inst = try Instance.init(a, cls);
    const t = try Tuple.init(a, 1);
    t.items[0] = Value{ .str = try Str.init(a, msg) };
    try inst.dict.setStr(a, "args", Value{ .tuple = t });
    try inst.dict.setStr(a, "doc", Value{ .str = try Str.init(a, doc) });
    try inst.dict.setStr(a, "pos", Value{ .small_int = @intCast(pos) });
    // Compute lineno and colno from pos
    var line: usize = 1;
    var col: usize = 1;
    for (doc[0..@min(pos, doc.len)]) |ch| {
        if (ch == '\n') { line += 1; col = 1; } else col += 1;
    }
    try inst.dict.setStr(a, "lineno", Value{ .small_int = @intCast(line) });
    try inst.dict.setStr(a, "colno", Value{ .small_int = @intCast(col) });
    interp.current_exc = Value{ .instance = inst };
}

// ─── Parser ──────────────────────────────────────────────────────────────────

const Parser = struct {
    interp: *Interp,
    src: []const u8,
    pos: usize,
    opts: LoadOpts,

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') self.pos += 1 else break;
        }
    }

    fn parseValue(self: *Parser) anyerror!Value {
        self.skipSpace();
        if (self.pos >= self.src.len) {
            try raiseJsonDecodeError(self.interp, self.src, self.pos, "Expecting value");
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
                try raiseJsonDecodeError(self.interp, self.src, self.pos, "Expecting value");
                break :blk error.PyException;
            },
        };
    }

    fn parseLiteral(self: *Parser, lit: []const u8, value: Value) !Value {
        if (self.pos + lit.len > self.src.len or
            !std.mem.eql(u8, self.src[self.pos .. self.pos + lit.len], lit))
        {
            try raiseJsonDecodeError(self.interp, self.src, self.pos, "Expecting value");
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
            if (self.opts.parse_float != .none) {
                const s = try Str.init(self.interp.allocator, text);
                return dispatch.invoke(self.interp, self.opts.parse_float, &.{Value{ .str = s }});
            }
            const f = std.fmt.parseFloat(f64, text) catch {
                try raiseJsonDecodeError(self.interp, self.src, start, "Invalid float");
                return error.PyException;
            };
            return Value{ .float = f };
        }
        if (self.opts.parse_int != .none) {
            const s = try Str.init(self.interp.allocator, text);
            return dispatch.invoke(self.interp, self.opts.parse_int, &.{Value{ .str = s }});
        }
        const i = std.fmt.parseInt(i64, text, 10) catch {
            try raiseJsonDecodeError(self.interp, self.src, start, "Invalid int");
            return error.PyException;
        };
        return Value{ .small_int = i };
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn parseString(self: *Parser) !Value {
        self.pos += 1;
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
                        try raiseJsonDecodeError(self.interp, self.src, self.pos - 1, "Invalid \\escape");
                        return error.PyException;
                    },
                }
                continue;
            }
            try buf.append(self.interp.allocator, c);
            self.pos += 1;
        }
        try raiseJsonDecodeError(self.interp, self.src, self.pos, "Unterminated string");
        return error.PyException;
    }

    fn parseUnicodeEscape(self: *Parser, buf: *std.ArrayList(u8)) !void {
        if (self.pos + 4 > self.src.len) {
            try raiseJsonDecodeError(self.interp, self.src, self.pos, "Invalid \\u escape");
            return error.PyException;
        }
        const hex = self.src[self.pos .. self.pos + 4];
        self.pos += 4;
        var cp: u32 = std.fmt.parseInt(u32, hex, 16) catch {
            try raiseJsonDecodeError(self.interp, self.src, self.pos - 4, "Invalid \\u escape");
            return error.PyException;
        };
        if (cp >= 0xD800 and cp <= 0xDBFF) {
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
            if (self.src[self.pos] == ',') { self.pos += 1; continue; }
            if (self.src[self.pos] == ']') { self.pos += 1; return Value{ .list = out }; }
            break;
        }
        try raiseJsonDecodeError(self.interp, self.src, self.pos, "Invalid array");
        return error.PyException;
    }

    fn parseObject(self: *Parser) anyerror!Value {
        self.pos += 1;
        const out = try Dict.init(self.interp.allocator);
        self.skipSpace();
        if (self.pos < self.src.len and self.src[self.pos] == '}') {
            self.pos += 1;
            const result = Value{ .dict = out };
            if (self.opts.object_hook != .none) {
                return dispatch.invoke(self.interp, self.opts.object_hook, &.{result});
            }
            return result;
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
            if (self.src[self.pos] == ',') { self.pos += 1; continue; }
            if (self.src[self.pos] == '}') {
                self.pos += 1;
                const result = Value{ .dict = out };
                if (self.opts.object_hook != .none) {
                    return dispatch.invoke(self.interp, self.opts.object_hook, &.{result});
                }
                return result;
            }
            break;
        }
        try raiseJsonDecodeError(self.interp, self.src, self.pos, "Expecting property name");
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

// ─── JSONEncoder class ───────────────────────────────────────────────────────

fn encoderInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return encoderInitKw(p, args, &.{}, &.{});
}

fn encoderInitKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    var opts = DumpOpts{};
    parseDumpOpts(&opts, kw_names, kw_values);
    // Store opts fields as instance attrs
    try inst.dict.setStr(a, "_sort_keys", Value{ .boolean = opts.sort_keys });
    try inst.dict.setStr(a, "_ensure_ascii", Value{ .boolean = opts.ensure_ascii });
    try inst.dict.setStr(a, "_allow_nan", Value{ .boolean = opts.allow_nan });
    try inst.dict.setStr(a, "_skip_keys", Value{ .boolean = opts.skip_keys });
    const sep_item = try Str.init(a, opts.sep_item);
    const sep_kv = try Str.init(a, opts.sep_kv);
    try inst.dict.setStr(a, "_sep_item", Value{ .str = sep_item });
    try inst.dict.setStr(a, "_sep_kv", Value{ .str = sep_kv });
    try inst.dict.setStr(a, "_default_fn", opts.default_fn);
    if (opts.indent) |n| {
        try inst.dict.setStr(a, "_indent", Value{ .small_int = @intCast(n) });
    } else {
        try inst.dict.setStr(a, "_indent", Value.none);
    }
    return Value.none;
}

fn encoderEncode(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    if (args.len < 2 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    var opts = DumpOpts{};
    if (inst.dict.getStr("_sort_keys")) |v| opts.sort_keys = v == .boolean and v.boolean;
    if (inst.dict.getStr("_ensure_ascii")) |v| opts.ensure_ascii = !(v == .boolean and !v.boolean);
    if (inst.dict.getStr("_allow_nan")) |v| opts.allow_nan = !(v == .boolean and !v.boolean);
    if (inst.dict.getStr("_skip_keys")) |v| opts.skip_keys = v == .boolean and v.boolean;
    if (inst.dict.getStr("_sep_item")) |v| { if (v == .str) opts.sep_item = v.str.bytes; }
    if (inst.dict.getStr("_sep_kv")) |v| { if (v == .str) opts.sep_kv = v.str.bytes; }
    if (inst.dict.getStr("_default_fn")) |v| opts.default_fn = v;
    if (inst.dict.getStr("_indent")) |v| {
        switch (v) {
            .small_int => |i| opts.indent = @intCast(i),
            else => {},
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(interp.allocator);
    try writeValue(interp, &buf, args[1], opts, 0);
    const out = try Str.init(interp.allocator, buf.items);
    return Value{ .str = out };
}

// ─── JSONDecoder class ───────────────────────────────────────────────────────

fn decoderInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return decoderInitKw(p, args, &.{}, &.{});
}

fn decoderInitKw(_: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value.none;
    // Just store nothing; decode will use defaults
    _ = kw_names; _ = kw_values;
    return Value.none;
}

fn decoderDecode(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    if (args.len < 2) return Value.none;
    const src: []const u8 = switch (args[1]) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        else => return Value.none,
    };
    var parser = Parser{ .interp = interp, .src = src, .pos = 0, .opts = .{} };
    parser.skipSpace();
    return parser.parseValue();
}

fn decoderRawDecode(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const src: []const u8 = switch (args[1]) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        else => return Value.none,
    };
    var parser = Parser{ .interp = interp, .src = src, .pos = 0, .opts = .{} };
    parser.skipSpace();
    const v = try parser.parseValue();
    const idx = parser.pos;
    const tup = try Tuple.init(a, 2);
    tup.items[0] = v;
    tup.items[1] = Value{ .small_int = @intCast(idx) };
    return Value{ .tuple = tup };
}
