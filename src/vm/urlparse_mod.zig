//! Pinhole `urllib.parse`. ParseResult is an instance whose attrs
//! cover `scheme/netloc/path/params/query/fragment` plus the derived
//! `hostname`/`port`, with `__getitem__` dispatching to the tuple
//! stored in `_items`.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const List = @import("../object/list.zig").List;
const Dict = @import("../object/dict.zig").Dict;
const Tuple = @import("../object/tuple.zig").Tuple;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "urllib.parse");
    try ensureClass(interp);
    try reg(interp, m, "urlparse", urlparseFn);
    try reg(interp, m, "urlunparse", urlunparseFn);
    try reg(interp, m, "urljoin", urljoinFn);
    try regKw(interp, m, "quote", quoteFn, quoteKw);
    try reg(interp, m, "unquote", unquoteFn);
    try regKw(interp, m, "quote_plus", quotePlusFn, quotePlusKw);
    try reg(interp, m, "unquote_plus", unquotePlusFn);
    try reg(interp, m, "urlencode", urlencodeFn);
    try reg(interp, m, "parse_qs", parseQsFn);
    try reg(interp, m, "parse_qsl", parseQslFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn ensureClass(interp: *Interp) !void {
    if (interp.urlparse_result_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "__getitem__", parseGetItem);
    interp.urlparse_result_class = try Class.init(a, "ParseResult", &.{}, d);
}

fn parseGetItem(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const items = inst.dict.getStr("_items").?.tuple.items;
    if (args[1] != .small_int) return error.TypeError;
    const i = args[1].small_int;
    const idx: usize = if (i < 0) @intCast(@as(i64, @intCast(items.len)) + i) else @intCast(i);
    if (idx >= items.len) return error.IndexError;
    return items[idx];
}

// --- url splitting ---

const Parts = struct {
    scheme: []const u8 = "",
    netloc: []const u8 = "",
    path: []const u8 = "",
    params: []const u8 = "",
    query: []const u8 = "",
    fragment: []const u8 = "",
};

fn isSchemeChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.';
}

fn splitUrl(url: []const u8) Parts {
    var p: Parts = .{};
    var rest = url;

    if (std.mem.indexOfScalar(u8, rest, '#')) |hi| {
        p.fragment = rest[hi + 1 ..];
        rest = rest[0..hi];
    }
    if (std.mem.indexOfScalar(u8, rest, '?')) |qi| {
        p.query = rest[qi + 1 ..];
        rest = rest[0..qi];
    }
    // scheme: starts with alpha then alnum/+-.
    if (rest.len > 0 and std.ascii.isAlphabetic(rest[0])) {
        var i: usize = 1;
        while (i < rest.len and isSchemeChar(rest[i])) : (i += 1) {}
        if (i < rest.len and rest[i] == ':') {
            p.scheme = rest[0..i];
            rest = rest[i + 1 ..];
        }
    }
    if (rest.len >= 2 and rest[0] == '/' and rest[1] == '/') {
        rest = rest[2..];
        const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        p.netloc = rest[0..end];
        rest = rest[end..];
    }
    p.path = rest;
    return p;
}

fn newParseResult(interp: *Interp, parts: Parts) !Value {
    try ensureClass(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.urlparse_result_class.?);

    const fields = [_]struct { name: []const u8, val: []const u8 }{
        .{ .name = "scheme", .val = parts.scheme },
        .{ .name = "netloc", .val = parts.netloc },
        .{ .name = "path", .val = parts.path },
        .{ .name = "params", .val = parts.params },
        .{ .name = "query", .val = parts.query },
        .{ .name = "fragment", .val = parts.fragment },
    };

    const tup = try Tuple.init(a, fields.len);
    for (fields, 0..) |f, i| {
        const s = try Str.init(a, f.val);
        const v = Value{ .str = s };
        try inst.dict.setStr(a, f.name, v);
        tup.items[i] = v;
    }
    try inst.dict.setStr(a, "_items", Value{ .tuple = tup });

    // hostname / port — from netloc[after @]
    var host_part = parts.netloc;
    if (std.mem.lastIndexOfScalar(u8, host_part, '@')) |at| host_part = host_part[at + 1 ..];
    var hostname: []const u8 = host_part;
    var port_val: Value = Value.none;
    if (std.mem.lastIndexOfScalar(u8, host_part, ':')) |ci| {
        hostname = host_part[0..ci];
        const ps = host_part[ci + 1 ..];
        if (ps.len > 0) {
            const port = std.fmt.parseInt(i64, ps, 10) catch 0;
            port_val = Value{ .small_int = port };
        }
    }
    const lower = try std.ascii.allocLowerString(a, hostname);
    try inst.dict.setStr(a, "hostname", Value{ .str = try Str.fromOwnedSlice(a, lower) });
    try inst.dict.setStr(a, "port", port_val);

    return Value{ .instance = inst };
}

fn urlparseFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    return try newParseResult(interp, splitUrl(args[0].str.bytes));
}

fn urlunparseFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const items: []const Value = switch (args[0]) {
        .tuple => |t| t.items,
        .list => |l| l.items.items,
        else => return error.TypeError,
    };
    if (items.len < 6) return error.TypeError;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);

    const scheme = strSlice(items[0]);
    const netloc = strSlice(items[1]);
    const path = strSlice(items[2]);
    const params = strSlice(items[3]);
    const query = strSlice(items[4]);
    const frag = strSlice(items[5]);

    if (scheme.len > 0) {
        try buf.appendSlice(a, scheme);
        try buf.append(a, ':');
    }
    if (netloc.len > 0 or scheme.len > 0) {
        try buf.appendSlice(a, "//");
        try buf.appendSlice(a, netloc);
    }
    try buf.appendSlice(a, path);
    if (params.len > 0) {
        try buf.append(a, ';');
        try buf.appendSlice(a, params);
    }
    if (query.len > 0) {
        try buf.append(a, '?');
        try buf.appendSlice(a, query);
    }
    if (frag.len > 0) {
        try buf.append(a, '#');
        try buf.appendSlice(a, frag);
    }
    const owned = try buf.toOwnedSlice(a);
    return Value{ .str = try Str.fromOwnedSlice(a, owned) };
}

fn strSlice(v: Value) []const u8 {
    return if (v == .str) v.str.bytes else "";
}

fn urljoinFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .str or args[1] != .str) return error.TypeError;
    const base = args[0].str.bytes;
    const ref = args[1].str.bytes;
    if (ref.len == 0) return Value{ .str = try Str.init(a, base) };

    const bp = splitUrl(base);
    const rp = splitUrl(ref);
    if (rp.scheme.len > 0) return Value{ .str = try Str.init(a, ref) };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, bp.scheme);
    try buf.append(a, ':');
    try buf.appendSlice(a, "//");
    try buf.appendSlice(a, bp.netloc);

    if (rp.path.len > 0 and rp.path[0] == '/') {
        try buf.appendSlice(a, rp.path);
    } else if (rp.path.len > 0) {
        // merge with base path: drop last segment of base
        const slash = std.mem.lastIndexOfScalar(u8, bp.path, '/') orelse 0;
        try buf.appendSlice(a, bp.path[0 .. slash + 1]);
        try buf.appendSlice(a, rp.path);
    } else {
        try buf.appendSlice(a, bp.path);
    }
    if (rp.query.len > 0) {
        try buf.append(a, '?');
        try buf.appendSlice(a, rp.query);
    }
    if (rp.fragment.len > 0) {
        try buf.append(a, '#');
        try buf.appendSlice(a, rp.fragment);
    }
    const owned = try buf.toOwnedSlice(a);
    return Value{ .str = try Str.fromOwnedSlice(a, owned) };
}

// --- quote / unquote ---

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-' or c == '~';
}

fn quoteImpl(a: std.mem.Allocator, s: []const u8, safe: []const u8, plus: bool) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (isUnreserved(c) or std.mem.indexOfScalar(u8, safe, c) != null) {
            try buf.append(a, c);
        } else if (plus and c == ' ') {
            try buf.append(a, '+');
        } else {
            try buf.append(a, '%');
            try buf.append(a, hex[c >> 4]);
            try buf.append(a, hex[c & 0x0f]);
        }
    }
    return try buf.toOwnedSlice(a);
}

fn unquoteImpl(a: std.mem.Allocator, s: []const u8, plus: bool) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try buf.append(a, c);
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try buf.append(a, c);
                continue;
            };
            try buf.append(a, (hi << 4) | lo);
            i += 2;
        } else if (plus and c == '+') {
            try buf.append(a, ' ');
        } else {
            try buf.append(a, c);
        }
    }
    return try buf.toOwnedSlice(a);
}

fn quoteFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return quoteKw(p, args, &.{}, &.{});
}

fn quoteKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    var safe: []const u8 = "/";
    if (args.len >= 2 and args[1] == .str) safe = args[1].str.bytes;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "safe") and kv == .str) safe = kv.str.bytes;
    }
    const out = try quoteImpl(a, args[0].str.bytes, safe, false);
    return Value{ .str = try Str.fromOwnedSlice(a, out) };
}

fn unquoteFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const out = try unquoteImpl(a, args[0].str.bytes, false);
    return Value{ .str = try Str.fromOwnedSlice(a, out) };
}

fn quotePlusFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return quotePlusKw(p, args, &.{}, &.{});
}

fn quotePlusKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    var safe: []const u8 = "";
    if (args.len >= 2 and args[1] == .str) safe = args[1].str.bytes;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "safe") and kv == .str) safe = kv.str.bytes;
    }
    const out = try quoteImpl(a, args[0].str.bytes, safe, true);
    return Value{ .str = try Str.fromOwnedSlice(a, out) };
}

fn unquotePlusFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const out = try unquoteImpl(a, args[0].str.bytes, true);
    return Value{ .str = try Str.fromOwnedSlice(a, out) };
}

// --- urlencode ---

fn valToStr(a: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .str => |s| try a.dupe(u8, s.bytes),
        .small_int => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        .boolean => |b| try a.dupe(u8, if (b) "True" else "False"),
        else => error.TypeError,
    };
}

fn urlencodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var first = true;

    const writePair = struct {
        fn f(alloc: std.mem.Allocator, b: *std.ArrayList(u8), is_first: *bool, k: Value, v: Value) !void {
            if (!is_first.*) try b.append(alloc, '&');
            const ks = try valToStr(alloc, k);
            defer alloc.free(ks);
            const vs = try valToStr(alloc, v);
            defer alloc.free(vs);
            const ek = try quoteImpl(alloc, ks, "", true);
            defer alloc.free(ek);
            const ev = try quoteImpl(alloc, vs, "", true);
            defer alloc.free(ev);
            try b.appendSlice(alloc, ek);
            try b.append(alloc, '=');
            try b.appendSlice(alloc, ev);
            is_first.* = false;
        }
    }.f;

    switch (args[0]) {
        .dict => |d| for (d.pairs.items) |pair| try writePair(a, &buf, &first, pair.key, pair.value),
        .list => |l| for (l.items.items) |it| {
            if (it != .tuple or it.tuple.items.len < 2) return error.TypeError;
            try writePair(a, &buf, &first, it.tuple.items[0], it.tuple.items[1]);
        },
        .tuple => |t| for (t.items) |it| {
            if (it != .tuple or it.tuple.items.len < 2) return error.TypeError;
            try writePair(a, &buf, &first, it.tuple.items[0], it.tuple.items[1]);
        },
        else => return error.TypeError,
    }
    const owned = try buf.toOwnedSlice(a);
    return Value{ .str = try Str.fromOwnedSlice(a, owned) };
}

// --- parse_qs / parse_qsl ---

const Pair = struct { k: []const u8, v: []const u8 };

fn splitPairs(a: std.mem.Allocator, qs: []const u8) ![]Pair {
    var out: std.ArrayList(Pair) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < qs.len) {
        const amp = std.mem.indexOfScalarPos(u8, qs, i, '&') orelse qs.len;
        const seg = qs[i..amp];
        if (seg.len > 0) {
            if (std.mem.indexOfScalar(u8, seg, '=')) |eq| {
                const dec_k = try unquoteImpl(a, seg[0..eq], true);
                const dec_v = try unquoteImpl(a, seg[eq + 1 ..], true);
                try out.append(a, .{ .k = dec_k, .v = dec_v });
            } else {
                const dec_k = try unquoteImpl(a, seg, true);
                try out.append(a, .{ .k = dec_k, .v = try a.dupe(u8, "") });
            }
        }
        i = amp + 1;
    }
    return try out.toOwnedSlice(a);
}

fn parseQsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const pairs = try splitPairs(a, args[0].str.bytes);
    defer a.free(pairs);
    const d = try Dict.init(a);
    for (pairs) |kv| {
        const sv = try Str.init(a, kv.v);
        const new_item = Value{ .str = sv };
        if (d.getStr(kv.k)) |existing| {
            if (existing == .list) {
                try existing.list.append(a, new_item);
            } else {
                const lst = try List.init(a);
                try lst.append(a, existing);
                try lst.append(a, new_item);
                try d.setStr(a, kv.k, Value{ .list = lst });
            }
        } else {
            const lst = try List.init(a);
            try lst.append(a, new_item);
            try d.setStr(a, kv.k, Value{ .list = lst });
        }
    }
    return Value{ .dict = d };
}

fn parseQslFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const pairs = try splitPairs(a, args[0].str.bytes);
    defer a.free(pairs);
    const lst = try List.init(a);
    for (pairs) |kv| {
        const t = try Tuple.init(a, 2);
        t.items[0] = Value{ .str = try Str.init(a, kv.k) };
        t.items[1] = Value{ .str = try Str.init(a, kv.v) };
        try lst.append(a, Value{ .tuple = t });
    }
    return Value{ .list = lst };
}
