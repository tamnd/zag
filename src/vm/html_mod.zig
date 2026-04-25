//! Pinhole `html`: escape/unescape with the named entities the fixtures probe.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "html");
    try regKw(interp, m, "escape", escapeFn, escapeKw);
    try reg(interp, m, "unescape", unescapeFn);
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

fn escapeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return escapeKw(p, args, &.{}, &.{});
}

fn escapeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    var quote: bool = true;
    if (args.len >= 2 and args[1] == .boolean) quote = args[1].boolean;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "quote") and kv == .boolean) {
            quote = kv.boolean;
        }
    }
    const src = args[0].str.bytes;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for (src) |c| {
        switch (c) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '"' => if (quote) try out.appendSlice(a, "&quot;") else try out.append(a, c),
            '\'' => if (quote) try out.appendSlice(a, "&#x27;") else try out.append(a, c),
            else => try out.append(a, c),
        }
    }
    const s = try Str.init(a, out.items);
    return Value{ .str = s };
}

const NamedEntity = struct { name: []const u8, replacement: []const u8 };

const named_entities = [_]NamedEntity{
    .{ .name = "lt", .replacement = "<" },
    .{ .name = "gt", .replacement = ">" },
    .{ .name = "amp", .replacement = "&" },
    .{ .name = "quot", .replacement = "\"" },
    .{ .name = "apos", .replacement = "'" },
    .{ .name = "nbsp", .replacement = "\u{00A0}" },
    .{ .name = "copy", .replacement = "\u{00A9}" },
    .{ .name = "reg", .replacement = "\u{00AE}" },
    .{ .name = "hellip", .replacement = "\u{2026}" },
    .{ .name = "mdash", .replacement = "\u{2014}" },
    .{ .name = "ndash", .replacement = "\u{2013}" },
    .{ .name = "trade", .replacement = "\u{2122}" },
    .{ .name = "laquo", .replacement = "\u{00AB}" },
    .{ .name = "raquo", .replacement = "\u{00BB}" },
};

fn appendCodepoint(out: *std.ArrayList(u8), a: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.append(a, '?');
        return;
    };
    try out.appendSlice(a, buf[0..n]);
}

fn unescapeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const src = args[0].str.bytes;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] != '&') {
            try out.append(a, src[i]);
            i += 1;
            continue;
        }
        // Find ';'
        var j: usize = i + 1;
        while (j < src.len and j - i < 32 and src[j] != ';') j += 1;
        if (j >= src.len or src[j] != ';') {
            try out.append(a, src[i]);
            i += 1;
            continue;
        }
        const body = src[i + 1 .. j];
        if (body.len == 0) {
            try out.appendSlice(a, src[i .. j + 1]);
            i = j + 1;
            continue;
        }
        if (body[0] == '#') {
            // Numeric.
            var cp: u32 = 0;
            if (body.len >= 2 and (body[1] == 'x' or body[1] == 'X')) {
                cp = std.fmt.parseInt(u32, body[2..], 16) catch {
                    try out.appendSlice(a, src[i .. j + 1]);
                    i = j + 1;
                    continue;
                };
            } else {
                cp = std.fmt.parseInt(u32, body[1..], 10) catch {
                    try out.appendSlice(a, src[i .. j + 1]);
                    i = j + 1;
                    continue;
                };
            }
            try appendCodepoint(&out, a, @intCast(cp));
            i = j + 1;
            continue;
        }
        // Named.
        var matched = false;
        for (named_entities) |e| {
            if (std.mem.eql(u8, e.name, body)) {
                try out.appendSlice(a, e.replacement);
                matched = true;
                break;
            }
        }
        if (!matched) {
            try out.appendSlice(a, src[i .. j + 1]);
        }
        i = j + 1;
    }
    const s = try Str.init(a, out.items);
    return Value{ .str = s };
}
