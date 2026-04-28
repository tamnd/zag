//! `html`, `html.entities`, `html.parser` modules — fixture 213.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

fn gi(p: *anyopaque) *Interp { return @ptrCast(@alignCast(p)); }

fn reg(a: std.mem.Allocator, m: *Module, name: []const u8, f: BuiltinFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = bf });
}

fn regKw(a: std.mem.Allocator, m: *Module, name: []const u8, f: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = bf });
}

fn regD(a: std.mem.Allocator, d: *Dict, name: []const u8, f: BuiltinFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f };
    try d.setStr(a, name, Value{ .builtin_fn = bf });
}

fn regKwD(a: std.mem.Allocator, d: *Dict, name: []const u8, f: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f, .kw_func = kw };
    try d.setStr(a, name, Value{ .builtin_fn = bf });
}

fn makeStr(a: std.mem.Allocator, s: []const u8) !Value {
    return Value{ .str = try Str.init(a, s) };
}

// ── HTML entity table (HTML4 named entities + extras) ────────────────────────

const Entity = struct { name: []const u8, cp: u21 };

const html4_entities = [_]Entity{
    .{ .name = "AElig", .cp = 198 },
    .{ .name = "Aacute", .cp = 193 },
    .{ .name = "Acirc", .cp = 194 },
    .{ .name = "Agrave", .cp = 192 },
    .{ .name = "Alpha", .cp = 913 },
    .{ .name = "Aring", .cp = 197 },
    .{ .name = "Atilde", .cp = 195 },
    .{ .name = "Auml", .cp = 196 },
    .{ .name = "Beta", .cp = 914 },
    .{ .name = "Ccedil", .cp = 199 },
    .{ .name = "Chi", .cp = 935 },
    .{ .name = "Dagger", .cp = 8225 },
    .{ .name = "Delta", .cp = 916 },
    .{ .name = "ETH", .cp = 208 },
    .{ .name = "Eacute", .cp = 201 },
    .{ .name = "Ecirc", .cp = 202 },
    .{ .name = "Egrave", .cp = 200 },
    .{ .name = "Epsilon", .cp = 917 },
    .{ .name = "Eta", .cp = 919 },
    .{ .name = "Euml", .cp = 203 },
    .{ .name = "Gamma", .cp = 915 },
    .{ .name = "Iacute", .cp = 205 },
    .{ .name = "Icirc", .cp = 206 },
    .{ .name = "Igrave", .cp = 204 },
    .{ .name = "Iota", .cp = 921 },
    .{ .name = "Iuml", .cp = 207 },
    .{ .name = "Kappa", .cp = 922 },
    .{ .name = "Lambda", .cp = 923 },
    .{ .name = "Mu", .cp = 924 },
    .{ .name = "Ntilde", .cp = 209 },
    .{ .name = "Nu", .cp = 925 },
    .{ .name = "OElig", .cp = 338 },
    .{ .name = "Oacute", .cp = 211 },
    .{ .name = "Ocirc", .cp = 212 },
    .{ .name = "Ograve", .cp = 210 },
    .{ .name = "Omega", .cp = 937 },
    .{ .name = "Omicron", .cp = 927 },
    .{ .name = "Oslash", .cp = 216 },
    .{ .name = "Otilde", .cp = 213 },
    .{ .name = "Ouml", .cp = 214 },
    .{ .name = "Phi", .cp = 934 },
    .{ .name = "Pi", .cp = 928 },
    .{ .name = "Prime", .cp = 8243 },
    .{ .name = "Psi", .cp = 936 },
    .{ .name = "Rho", .cp = 929 },
    .{ .name = "Scaron", .cp = 352 },
    .{ .name = "Sigma", .cp = 931 },
    .{ .name = "THORN", .cp = 222 },
    .{ .name = "Tau", .cp = 932 },
    .{ .name = "Theta", .cp = 920 },
    .{ .name = "Uacute", .cp = 218 },
    .{ .name = "Ucirc", .cp = 219 },
    .{ .name = "Ugrave", .cp = 217 },
    .{ .name = "Upsilon", .cp = 933 },
    .{ .name = "Uuml", .cp = 220 },
    .{ .name = "Xi", .cp = 926 },
    .{ .name = "Yacute", .cp = 221 },
    .{ .name = "Yuml", .cp = 376 },
    .{ .name = "Zeta", .cp = 918 },
    .{ .name = "aacute", .cp = 225 },
    .{ .name = "acirc", .cp = 226 },
    .{ .name = "acute", .cp = 180 },
    .{ .name = "aelig", .cp = 230 },
    .{ .name = "agrave", .cp = 224 },
    .{ .name = "alefsym", .cp = 8501 },
    .{ .name = "alpha", .cp = 945 },
    .{ .name = "amp", .cp = 38 },
    .{ .name = "and", .cp = 8743 },
    .{ .name = "ang", .cp = 8736 },
    .{ .name = "apos", .cp = 39 },
    .{ .name = "aring", .cp = 229 },
    .{ .name = "asymp", .cp = 8776 },
    .{ .name = "atilde", .cp = 227 },
    .{ .name = "auml", .cp = 228 },
    .{ .name = "bdquo", .cp = 8222 },
    .{ .name = "beta", .cp = 946 },
    .{ .name = "brvbar", .cp = 166 },
    .{ .name = "bull", .cp = 8226 },
    .{ .name = "cap", .cp = 8745 },
    .{ .name = "ccedil", .cp = 231 },
    .{ .name = "cedil", .cp = 184 },
    .{ .name = "cent", .cp = 162 },
    .{ .name = "chi", .cp = 967 },
    .{ .name = "circ", .cp = 710 },
    .{ .name = "clubs", .cp = 9827 },
    .{ .name = "cong", .cp = 8773 },
    .{ .name = "copy", .cp = 169 },
    .{ .name = "crarr", .cp = 8629 },
    .{ .name = "cup", .cp = 8746 },
    .{ .name = "curren", .cp = 164 },
    .{ .name = "dArr", .cp = 8659 },
    .{ .name = "dagger", .cp = 8224 },
    .{ .name = "darr", .cp = 8595 },
    .{ .name = "deg", .cp = 176 },
    .{ .name = "delta", .cp = 948 },
    .{ .name = "diams", .cp = 9830 },
    .{ .name = "divide", .cp = 247 },
    .{ .name = "eacute", .cp = 233 },
    .{ .name = "ecirc", .cp = 234 },
    .{ .name = "egrave", .cp = 232 },
    .{ .name = "empty", .cp = 8709 },
    .{ .name = "emsp", .cp = 8195 },
    .{ .name = "ensp", .cp = 8194 },
    .{ .name = "epsilon", .cp = 949 },
    .{ .name = "equiv", .cp = 8801 },
    .{ .name = "eta", .cp = 951 },
    .{ .name = "eth", .cp = 240 },
    .{ .name = "euml", .cp = 235 },
    .{ .name = "euro", .cp = 8364 },
    .{ .name = "exist", .cp = 8707 },
    .{ .name = "fnof", .cp = 402 },
    .{ .name = "forall", .cp = 8704 },
    .{ .name = "frac12", .cp = 189 },
    .{ .name = "frac14", .cp = 188 },
    .{ .name = "frac34", .cp = 190 },
    .{ .name = "frasl", .cp = 8260 },
    .{ .name = "gamma", .cp = 947 },
    .{ .name = "ge", .cp = 8805 },
    .{ .name = "gt", .cp = 62 },
    .{ .name = "hArr", .cp = 8660 },
    .{ .name = "harr", .cp = 8596 },
    .{ .name = "hearts", .cp = 9829 },
    .{ .name = "hellip", .cp = 8230 },
    .{ .name = "iacute", .cp = 237 },
    .{ .name = "icirc", .cp = 238 },
    .{ .name = "iexcl", .cp = 161 },
    .{ .name = "igrave", .cp = 236 },
    .{ .name = "image", .cp = 8465 },
    .{ .name = "infin", .cp = 8734 },
    .{ .name = "int", .cp = 8747 },
    .{ .name = "iota", .cp = 953 },
    .{ .name = "iquest", .cp = 191 },
    .{ .name = "isin", .cp = 8712 },
    .{ .name = "iuml", .cp = 239 },
    .{ .name = "kappa", .cp = 954 },
    .{ .name = "lArr", .cp = 8656 },
    .{ .name = "lambda", .cp = 955 },
    .{ .name = "lang", .cp = 9001 },
    .{ .name = "laquo", .cp = 171 },
    .{ .name = "larr", .cp = 8592 },
    .{ .name = "lceil", .cp = 8968 },
    .{ .name = "ldquo", .cp = 8220 },
    .{ .name = "le", .cp = 8804 },
    .{ .name = "lfloor", .cp = 8970 },
    .{ .name = "lowast", .cp = 8727 },
    .{ .name = "loz", .cp = 9674 },
    .{ .name = "lrm", .cp = 8206 },
    .{ .name = "lsaquo", .cp = 8249 },
    .{ .name = "lsquo", .cp = 8216 },
    .{ .name = "lt", .cp = 60 },
    .{ .name = "macr", .cp = 175 },
    .{ .name = "mdash", .cp = 8212 },
    .{ .name = "micro", .cp = 181 },
    .{ .name = "middot", .cp = 183 },
    .{ .name = "minus", .cp = 8722 },
    .{ .name = "mu", .cp = 956 },
    .{ .name = "nabla", .cp = 8711 },
    .{ .name = "nbsp", .cp = 160 },
    .{ .name = "ndash", .cp = 8211 },
    .{ .name = "ne", .cp = 8800 },
    .{ .name = "ni", .cp = 8715 },
    .{ .name = "not", .cp = 172 },
    .{ .name = "notin", .cp = 8713 },
    .{ .name = "nsub", .cp = 8836 },
    .{ .name = "ntilde", .cp = 241 },
    .{ .name = "nu", .cp = 957 },
    .{ .name = "oacute", .cp = 243 },
    .{ .name = "ocirc", .cp = 244 },
    .{ .name = "oelig", .cp = 339 },
    .{ .name = "ograve", .cp = 242 },
    .{ .name = "oline", .cp = 8254 },
    .{ .name = "omega", .cp = 969 },
    .{ .name = "omicron", .cp = 959 },
    .{ .name = "oplus", .cp = 8853 },
    .{ .name = "or", .cp = 8744 },
    .{ .name = "ordf", .cp = 170 },
    .{ .name = "ordm", .cp = 186 },
    .{ .name = "oslash", .cp = 248 },
    .{ .name = "otilde", .cp = 245 },
    .{ .name = "otimes", .cp = 8855 },
    .{ .name = "ouml", .cp = 246 },
    .{ .name = "para", .cp = 182 },
    .{ .name = "part", .cp = 8706 },
    .{ .name = "permil", .cp = 8240 },
    .{ .name = "perp", .cp = 8869 },
    .{ .name = "phi", .cp = 966 },
    .{ .name = "pi", .cp = 960 },
    .{ .name = "piv", .cp = 982 },
    .{ .name = "plusmn", .cp = 177 },
    .{ .name = "pound", .cp = 163 },
    .{ .name = "prime", .cp = 8242 },
    .{ .name = "prod", .cp = 8719 },
    .{ .name = "prop", .cp = 8733 },
    .{ .name = "psi", .cp = 968 },
    .{ .name = "quot", .cp = 34 },
    .{ .name = "rArr", .cp = 8658 },
    .{ .name = "rang", .cp = 9002 },
    .{ .name = "raquo", .cp = 187 },
    .{ .name = "rarr", .cp = 8594 },
    .{ .name = "rceil", .cp = 8969 },
    .{ .name = "rdquo", .cp = 8221 },
    .{ .name = "real", .cp = 8476 },
    .{ .name = "reg", .cp = 174 },
    .{ .name = "rfloor", .cp = 8971 },
    .{ .name = "rho", .cp = 961 },
    .{ .name = "rlm", .cp = 8207 },
    .{ .name = "rsaquo", .cp = 8250 },
    .{ .name = "rsquo", .cp = 8217 },
    .{ .name = "sbquo", .cp = 8218 },
    .{ .name = "scaron", .cp = 353 },
    .{ .name = "sdot", .cp = 8901 },
    .{ .name = "sect", .cp = 167 },
    .{ .name = "shy", .cp = 173 },
    .{ .name = "sigma", .cp = 963 },
    .{ .name = "sigmaf", .cp = 962 },
    .{ .name = "sim", .cp = 8764 },
    .{ .name = "spades", .cp = 9824 },
    .{ .name = "sub", .cp = 8834 },
    .{ .name = "sube", .cp = 8838 },
    .{ .name = "sum", .cp = 8721 },
    .{ .name = "sup", .cp = 8835 },
    .{ .name = "sup1", .cp = 185 },
    .{ .name = "sup2", .cp = 178 },
    .{ .name = "sup3", .cp = 179 },
    .{ .name = "supe", .cp = 8839 },
    .{ .name = "szlig", .cp = 223 },
    .{ .name = "tau", .cp = 964 },
    .{ .name = "there4", .cp = 8756 },
    .{ .name = "theta", .cp = 952 },
    .{ .name = "thetasym", .cp = 977 },
    .{ .name = "thinsp", .cp = 8201 },
    .{ .name = "thorn", .cp = 254 },
    .{ .name = "tilde", .cp = 732 },
    .{ .name = "times", .cp = 215 },
    .{ .name = "trade", .cp = 8482 },
    .{ .name = "uArr", .cp = 8657 },
    .{ .name = "uacute", .cp = 250 },
    .{ .name = "uarr", .cp = 8593 },
    .{ .name = "ucirc", .cp = 251 },
    .{ .name = "ugrave", .cp = 249 },
    .{ .name = "uml", .cp = 168 },
    .{ .name = "upsih", .cp = 978 },
    .{ .name = "upsilon", .cp = 965 },
    .{ .name = "uuml", .cp = 252 },
    .{ .name = "weierp", .cp = 8472 },
    .{ .name = "xi", .cp = 958 },
    .{ .name = "yacute", .cp = 253 },
    .{ .name = "yen", .cp = 165 },
    .{ .name = "yuml", .cp = 255 },
    .{ .name = "zeta", .cp = 950 },
    .{ .name = "zwj", .cp = 8205 },
    .{ .name = "zwnj", .cp = 8204 },
};

fn findEntity(name: []const u8) ?u21 {
    for (html4_entities) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.cp;
    }
    return null;
}

fn appendCodepoint(out: *std.ArrayList(u8), a: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.append(a, '?');
        return;
    };
    try out.appendSlice(a, buf[0..n]);
}

// ── html.escape ──────────────────────────────────────────────────────────────

fn escapeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return escapeKw(p, args, &.{}, &.{});
}

fn escapeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    var quote: bool = true;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "quote")) {
            quote = switch (kv) { .boolean => |b| b, .small_int => |i| i != 0, else => true };
        }
    }
    // Check positional quote arg
    if (kw_names.len == 0 and args.len >= 2) {
        quote = switch (args[1]) { .boolean => |b| b, .small_int => |i| i != 0, else => true };
    }
    const src = args[0].str.bytes;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for (src) |ch| {
        switch (ch) {
            '&'  => try out.appendSlice(a, "&amp;"),
            '<'  => try out.appendSlice(a, "&lt;"),
            '>'  => try out.appendSlice(a, "&gt;"),
            '"'  => if (quote) try out.appendSlice(a, "&quot;") else try out.append(a, ch),
            '\'' => if (quote) try out.appendSlice(a, "&#x27;") else try out.append(a, ch),
            else => try out.append(a, ch),
        }
    }
    return makeStr(a, out.items);
}

// ── html.unescape ────────────────────────────────────────────────────────────

fn unescapeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const src = args[0].str.bytes;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] != '&') { try out.append(a, src[i]); i += 1; continue; }
        var j: usize = i + 1;
        while (j < src.len and j - i < 50 and src[j] != ';') j += 1;
        if (j >= src.len or src[j] != ';') { try out.append(a, '&'); i += 1; continue; }
        const body = src[i + 1 .. j];
        if (body.len == 0) { try out.appendSlice(a, src[i .. j + 1]); i = j + 1; continue; }
        if (body[0] == '#') {
            var cp: u32 = 0;
            if (body.len >= 2 and (body[1] == 'x' or body[1] == 'X')) {
                cp = std.fmt.parseInt(u32, body[2..], 16) catch { try out.appendSlice(a, src[i .. j + 1]); i = j + 1; continue; };
            } else {
                cp = std.fmt.parseInt(u32, body[1..], 10) catch { try out.appendSlice(a, src[i .. j + 1]); i = j + 1; continue; };
            }
            try appendCodepoint(&out, a, @intCast(cp));
            i = j + 1;
            continue;
        }
        // Named entity — check full HTML4 table
        if (findEntity(body)) |cp| {
            try appendCodepoint(&out, a, cp);
        } else {
            try out.appendSlice(a, src[i .. j + 1]);
        }
        i = j + 1;
    }
    return makeStr(a, out.items);
}

// ── html module build ────────────────────────────────────────────────────────

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "html");
    try regKw(a, m, "escape", escapeFn, escapeKw);
    try reg(a, m, "unescape", unescapeFn);
    return m;
}

// ── html5 entity table (full CPython html.entities.html5, 2231 entries) ──────
// Generated from CPython Lib/html/entities.py
const html5_table = @import("html5_table.zig").html5_table;

// ── html.entities module ─────────────────────────────────────────────────────

pub fn buildEntities(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "html.entities");

    // name2codepoint: {name: int}
    const n2c = try Dict.init(a);
    for (html4_entities) |e| {
        try n2c.setStr(a, e.name, Value{ .small_int = @as(i64, e.cp) });
    }
    try m.attrs.setStr(a, "name2codepoint", Value{ .dict = n2c });

    // codepoint2name: {int: name}
    const c2n = try Dict.init(a);
    for (html4_entities) |e| {
        const key = Value{ .small_int = @as(i64, e.cp) };
        if (c2n.getKey(key) == null) {
            try c2n.setKey(a, key, try makeStr(a, e.name));
        }
    }
    try m.attrs.setStr(a, "codepoint2name", Value{ .dict = c2n });

    // html5: full CPython html.entities.html5 table (2231 entries)
    const html5 = try Dict.init(a);
    for (html5_table) |e| {
        try html5.setStr(a, e.name, try makeStr(a, e.val));
    }
    try m.attrs.setStr(a, "html5", Value{ .dict = html5 });

    return m;
}

// ── html.parser module ───────────────────────────────────────────────────────

// HTMLParser instance state — stored as pointer in _state field
const ParserState = struct {
    buf: std.ArrayList(u8),
    convert_charrefs: bool = true,
    line: usize = 1,
    col: usize = 0,
};

fn parserStatePtr(inst: *Instance) ?*ParserState {
    const v = inst.dict.getStr("_state") orelse return null;
    const n: i64 = switch (v) { .small_int => |i| i, else => return null };
    if (n == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(n)));
}

fn parserGetposFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const state = parserStatePtr(inst) orelse {
        const t = try Tuple.init(a, 2);
        t.items[0] = Value{ .small_int = 1 };
        t.items[1] = Value{ .small_int = 0 };
        return Value{ .tuple = t };
    };
    const t = try Tuple.init(a, 2);
    t.items[0] = Value{ .small_int = @intCast(state.line) };
    t.items[1] = Value{ .small_int = @intCast(state.col) };
    return Value{ .tuple = t };
}

fn parserInit(p: *anyopaque, args: []const Value) anyerror!Value {
    return parserInitKw(p, args, &.{}, &.{});
}

fn parserInitKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;

    var convert_charrefs: bool = true;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "convert_charrefs")) {
            convert_charrefs = switch (kv) { .boolean => |b| b, .small_int => |i| i != 0, else => true };
        }
    }

    const state = try a.create(ParserState);
    state.* = .{ .buf = .empty, .convert_charrefs = convert_charrefs };
    try inst.dict.setStr(a, "_state", Value{ .small_int = @bitCast(@intFromPtr(state)) });
    return Value.none;
}

// Parse a tag opening after '<', returns (tag_name, attrs, is_self_close, end_pos)
fn parseTag(src: []const u8) struct { tag: []const u8, attrs: []const u8, self_close: bool, end: usize } {
    var i: usize = 0;
    // Skip tag name
    const tag_start = i;
    while (i < src.len and src[i] != ' ' and src[i] != '>' and src[i] != '/' and src[i] != '\t' and src[i] != '\n') i += 1;
    const tag_end = i;
    // Skip whitespace
    while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\n')) i += 1;
    // Find attrs and end
    const attrs_start = i;
    var self_close = false;
    while (i < src.len) {
        if (src[i] == '>') break;
        if (src[i] == '/' and i + 1 < src.len and src[i + 1] == '>') {
            self_close = true;
            break;
        }
        if (src[i] == '"') { i += 1; while (i < src.len and src[i] != '"') i += 1; }
        else if (src[i] == '\'') { i += 1; while (i < src.len and src[i] != '\'') i += 1; }
        if (i < src.len) i += 1;
    }
    const attrs_end = if (self_close) i else i;
    _ = attrs_end;
    const attrs_str = std.mem.trimEnd(u8, src[attrs_start..i], " \t\n/");
    const end = if (i < src.len) i + 1 else i;
    return .{ .tag = src[tag_start..tag_end], .attrs = attrs_str, .self_close = self_close, .end = end };
}

// Parse attribute string into list of (name, value) tuples
fn parseAttrs(a: std.mem.Allocator, src: []const u8) !*List {
    const lst = try List.init(a);
    var i: usize = 0;
    while (i < src.len) {
        // Skip whitespace
        while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\n')) i += 1;
        if (i >= src.len) break;
        // Attr name
        const name_start = i;
        while (i < src.len and src[i] != '=' and src[i] != ' ' and src[i] != '\t' and src[i] != '\n' and src[i] != '>') i += 1;
        const name = src[name_start..i];
        if (name.len == 0) { i += 1; continue; }
        // Skip whitespace
        while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
        if (i >= src.len or src[i] != '=') {
            // Boolean attr
            const t = try Tuple.init(a, 2);
            t.items[0] = try makeStr(a, name);
            t.items[1] = Value.none;
            try lst.items.append(a, Value{ .tuple = t });
            continue;
        }
        i += 1; // skip '='
        while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
        // Value
        var val: []const u8 = "";
        if (i < src.len and (src[i] == '"' or src[i] == '\'')) {
            const q = src[i];
            i += 1;
            const val_start = i;
            while (i < src.len and src[i] != q) i += 1;
            val = src[val_start..i];
            if (i < src.len) i += 1;
        } else {
            const val_start = i;
            while (i < src.len and src[i] != ' ' and src[i] != '\t' and src[i] != '>') i += 1;
            val = src[val_start..i];
        }
        const t = try Tuple.init(a, 2);
        t.items[0] = try makeStr(a, name);
        t.items[1] = try makeStr(a, val);
        try lst.items.append(a, Value{ .tuple = t });
    }
    return lst;
}

// Invoke a method on self if it exists, ignoring errors
fn callMethod(interp: *Interp, self_v: Value, method: []const u8, args: []const Value) void {
    const mv = @import("dispatch.zig").loadAttrValue(interp, self_v, method) catch return;
    _ = @import("dispatch.zig").invoke(interp, mv, args) catch return;
}

// Emit a text chunk: either unescape (convert_charrefs=true) or raw
fn emitText(interp: *Interp, a: std.mem.Allocator, self_v: Value, text: []const u8, convert_charrefs: bool) !void {
    if (text.len == 0) return;
    if (convert_charrefs) {
        // Unescape entity/char refs in text before calling handle_data
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(a);
        var j: usize = 0;
        while (j < text.len) {
            if (text[j] == '&') {
                const amp = j;
                j += 1;
                var k = j;
                while (k < text.len and text[k] != ';' and text[k] != ' ' and k - amp < 32) k += 1;
                if (k < text.len and text[k] == ';') {
                    const ref = text[j..k];
                    j = k + 1;
                    if (ref.len > 0 and ref[0] == '#') {
                        const num_str = ref[1..];
                        const cp: u21 = if (num_str.len > 1 and (num_str[0] == 'x' or num_str[0] == 'X'))
                            std.fmt.parseInt(u21, num_str[1..], 16) catch 0xFFFD
                        else
                            std.fmt.parseInt(u21, num_str, 10) catch 0xFFFD;
                        try appendCodepoint(&out, a, cp);
                    } else if (findEntity(ref)) |cp| {
                        try appendCodepoint(&out, a, cp);
                    } else {
                        try out.appendSlice(a, text[amp..j]);
                    }
                } else {
                    try out.appendSlice(a, text[amp..j]);
                }
            } else {
                try out.append(a, text[j]);
                j += 1;
            }
        }
        if (out.items.len > 0) {
            const tv = try makeStr(a, out.items);
            callMethod(interp, self_v, "handle_data", &.{tv});
        }
    } else {
        // convert_charrefs=False: scan for &refs; and call entity/char ref callbacks
        var j: usize = 0;
        var text_start: usize = 0;
        while (j < text.len) {
            if (text[j] == '&') {
                if (j > text_start) {
                    const tv = try makeStr(a, text[text_start..j]);
                    callMethod(interp, self_v, "handle_data", &.{tv});
                }
                j += 1;
                const ref_start = j;
                while (j < text.len and text[j] != ';' and text[j] != ' ' and text[j] != '<' and j - ref_start < 32) j += 1;
                if (j < text.len and text[j] == ';') {
                    const ref = text[ref_start..j];
                    j += 1;
                    if (ref.len > 0 and ref[0] == '#') {
                        const cv = try makeStr(a, ref[1..]);
                        callMethod(interp, self_v, "handle_charref", &.{cv});
                    } else {
                        const ev2 = try makeStr(a, ref);
                        callMethod(interp, self_v, "handle_entityref", &.{ev2});
                    }
                    text_start = j;
                } else {
                    text_start = ref_start - 1;
                }
            } else {
                j += 1;
            }
        }
        if (text_start < text.len) {
            const tv = try makeStr(a, text[text_start..]);
            callMethod(interp, self_v, "handle_data", &.{tv});
        }
    }
}

fn parserFeed(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const state = parserStatePtr(inst) orelse return Value.none;
    const new_data: []const u8 = switch (args[1]) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        else => return Value.none,
    };

    // Append new data to the buffer
    try state.buf.appendSlice(a, new_data);
    const data = state.buf.items;
    const self_v = args[0];
    const convert_charrefs = state.convert_charrefs;

    var i: usize = 0;
    while (i < data.len) {
        if (data[i] != '<') {
            // Text data — scan until '<' or end
            const start = i;
            while (i < data.len and data[i] != '<') i += 1;
            try emitText(interp, a, self_v, data[start..i], convert_charrefs);
            // Update line/col
            for (data[start..i]) |ch| {
                if (ch == '\n') { state.line += 1; state.col = 0; }
                else state.col += 1;
            }
            continue;
        }
        // Found '<' — check if we have a complete token
        if (i + 1 >= data.len) break; // incomplete, keep in buffer

        const next = data[i + 1];

        if (next == '!') {
            if (i + 3 < data.len and data[i + 2] == '-' and data[i + 3] == '-') {
                // Comment <!-- ... -->
                const end_opt = std.mem.indexOf(u8, data[i + 4 ..], "-->");
                if (end_opt == null) break; // incomplete
                const comment_start = i + 4;
                const rel = end_opt.?;
                const comment = data[comment_start .. comment_start + rel];
                const c_v = try makeStr(a, comment);
                callMethod(interp, self_v, "handle_comment", &.{c_v});
                i = comment_start + rel + 3;
            } else if (i + 3 < data.len and data[i + 2] == '[') {
                // CDATA / unknown_decl: <![...]>
                // Find ]]> for CDATA or > for other
                const cdata_end = std.mem.indexOf(u8, data[i + 3 ..], "]]>");
                if (cdata_end == null) {
                    // Try plain >
                    const gt = std.mem.indexOfScalar(u8, data[i + 2 ..], '>');
                    if (gt == null) break; // incomplete
                    const decl_start = i + 2;
                    const decl = data[decl_start .. decl_start + gt.?];
                    const d_v = try makeStr(a, decl);
                    callMethod(interp, self_v, "unknown_decl", &.{d_v});
                    i = decl_start + gt.? + 1;
                } else {
                    // CDATA: content is between <![ and ]]>
                    const content_start = i + 3;
                    const content = data[content_start .. content_start + cdata_end.?];
                    // Trim leading [ if present (CDATA[ -> pass CDATA[...] as unknown_decl)
                    const d_v = try makeStr(a, content);
                    callMethod(interp, self_v, "unknown_decl", &.{d_v});
                    i = content_start + cdata_end.? + 3;
                }
            } else {
                // Declaration: <!...>
                const gt = std.mem.indexOfScalar(u8, data[i + 2 ..], '>');
                if (gt == null) break; // incomplete
                const decl_start = i + 2;
                const decl = data[decl_start .. decl_start + gt.?];
                const d_v = try makeStr(a, decl);
                callMethod(interp, self_v, "handle_decl", &.{d_v});
                i = decl_start + gt.? + 1;
            }
            continue;
        }

        if (next == '?') {
            // Processing instruction: <?...?>
            const pi_end = std.mem.indexOf(u8, data[i + 2 ..], "?>");
            if (pi_end == null) break; // incomplete
            const pi_start = i + 2;
            const pi_data = data[pi_start .. pi_start + pi_end.?];
            const pi_v = try makeStr(a, pi_data);
            callMethod(interp, self_v, "handle_pi", &.{pi_v});
            i = pi_start + pi_end.? + 2;
            continue;
        }

        if (next == '/') {
            // End tag </tag>
            const gt = std.mem.indexOfScalar(u8, data[i + 2 ..], '>');
            if (gt == null) break; // incomplete
            const tag_start = i + 2;
            const tag = std.mem.trim(u8, data[tag_start .. tag_start + gt.?], " \t\n\r");
            var tag_lower_buf: [64]u8 = undefined;
            const tag_lower = if (tag.len <= 64) blk: {
                @memcpy(tag_lower_buf[0..tag.len], tag);
                for (tag_lower_buf[0..tag.len]) |*c2| c2.* = std.ascii.toLower(c2.*);
                break :blk tag_lower_buf[0..tag.len];
            } else tag;
            state.col = 0; // approximate
            const tag_v = try makeStr(a, tag_lower);
            callMethod(interp, self_v, "handle_endtag", &.{tag_v});
            i = tag_start + gt.? + 1;
            continue;
        }

        // Start tag (or self-closing) <tag ...>
        // Find matching '>' respecting quoted attrs
        {
            var j = i + 1;
            var in_q: u8 = 0;
            while (j < data.len) {
                if (in_q != 0) {
                    if (data[j] == in_q) in_q = 0;
                } else if (data[j] == '"') {
                    in_q = '"';
                } else if (data[j] == '\'') {
                    in_q = '\'';
                } else if (data[j] == '>') {
                    break;
                }
                j += 1;
            }
            if (j >= data.len) break; // incomplete

            const tag_content = data[i + 1 .. j];
            i = j + 1;

            const parsed = parseTag(tag_content);
            var tag_lower_buf: [64]u8 = undefined;
            const tag_lower = if (parsed.tag.len <= 64) blk: {
                @memcpy(tag_lower_buf[0..parsed.tag.len], parsed.tag);
                for (tag_lower_buf[0..parsed.tag.len]) |*c2| c2.* = std.ascii.toLower(c2.*);
                break :blk tag_lower_buf[0..parsed.tag.len];
            } else parsed.tag;

            state.col = 0;
            const tag_v = try makeStr(a, tag_lower);
            const attrs_list = try parseAttrs(a, parsed.attrs);
            const attrs_v = Value{ .list = attrs_list };

            if (parsed.self_close) {
                callMethod(interp, self_v, "handle_startendtag", &.{ tag_v, attrs_v });
            } else {
                callMethod(interp, self_v, "handle_starttag", &.{ tag_v, attrs_v });
            }
        }
    }

    // Compact buffer: discard processed data
    if (i > 0) {
        const remaining = data[i..];
        const new_len = remaining.len;
        @memcpy(state.buf.items[0..new_len], remaining);
        state.buf.items.len = new_len;
    }

    return Value.none;
}

fn parserHandleStarttag(_: *anyopaque, _: []const Value) anyerror!Value { return Value.none; }
fn parserHandleEndtag(_: *anyopaque, _: []const Value) anyerror!Value { return Value.none; }
fn parserHandlePi(_: *anyopaque, _: []const Value) anyerror!Value { return Value.none; }
fn parserUnknownDecl(_: *anyopaque, _: []const Value) anyerror!Value { return Value.none; }
fn parserHandleEntityref(_: *anyopaque, _: []const Value) anyerror!Value { return Value.none; }
fn parserHandleCharref(_: *anyopaque, _: []const Value) anyerror!Value { return Value.none; }
fn parserHandleStartendtag(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 3) return Value.none;
    const self_v = args[0];
    const tag_v = args[1];
    const attrs_v = args[2];
    // Default: call handle_starttag then handle_endtag
    callMethod(interp, self_v, "handle_starttag", &.{ tag_v, attrs_v });
    callMethod(interp, self_v, "handle_endtag", &.{tag_v});
    _ = a;
    return Value.none;
}
fn parserHandleData(_: *anyopaque, _: []const Value) anyerror!Value { return Value.none; }
fn parserHandleComment(_: *anyopaque, _: []const Value) anyerror!Value { return Value.none; }
fn parserHandleDecl(_: *anyopaque, _: []const Value) anyerror!Value { return Value.none; }
fn parserReset(_: *anyopaque, _: []const Value) anyerror!Value { return Value.none; }
fn parserClose(_: *anyopaque, _: []const Value) anyerror!Value { return Value.none; }
fn parserError(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    if (args.len >= 2) {
        const msg: []const u8 = switch (args[1]) { .str => |s| s.bytes, else => "parser error" };
        try interp.raisePy("HTMLParseError", msg);
    }
    return error.PyException;
}

pub fn buildParser(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "html.parser");

    // HTMLParser class
    if (interp.html_parser_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "__init__", parserInit, parserInitKw);
        try regD(a, d, "feed", parserFeed);
        try regD(a, d, "reset", parserReset);
        try regD(a, d, "close", parserClose);
        try regD(a, d, "error", parserError);
        try regD(a, d, "getpos", parserGetposFn);
        try regD(a, d, "handle_starttag", parserHandleStarttag);
        try regD(a, d, "handle_endtag", parserHandleEndtag);
        try regD(a, d, "handle_startendtag", parserHandleStartendtag);
        try regD(a, d, "handle_data", parserHandleData);
        try regD(a, d, "handle_comment", parserHandleComment);
        try regD(a, d, "handle_decl", parserHandleDecl);
        try regD(a, d, "handle_pi", parserHandlePi);
        try regD(a, d, "unknown_decl", parserUnknownDecl);
        try regD(a, d, "handle_entityref", parserHandleEntityref);
        try regD(a, d, "handle_charref", parserHandleCharref);
        interp.html_parser_class = try Class.init(a, "HTMLParser", &.{}, d);
    }

    try m.attrs.setStr(a, "HTMLParser", Value{ .class = interp.html_parser_class.? });
    return m;
}
