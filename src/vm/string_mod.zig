//! Pinhole `string` module: just the constants the fixture prints.
//! `string.Formatter` / `Template` etc. wait for a fixture.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "string");
    const a = interp.allocator;
    try setStr(a, m, "ascii_lowercase", "abcdefghijklmnopqrstuvwxyz");
    try setStr(a, m, "ascii_uppercase", "ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    try setStr(a, m, "ascii_letters", "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ");
    try setStr(a, m, "digits", "0123456789");
    try setStr(a, m, "hexdigits", "0123456789abcdefABCDEF");
    try setStr(a, m, "octdigits", "01234567");
    try setStr(a, m, "punctuation", "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~");
    try setStr(a, m, "whitespace", " \t\n\r\x0b\x0c");
    // CPython: digits + letters + punctuation + whitespace.
    try setStr(a, m, "printable", "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~ \t\n\r\x0b\x0c");
    try reg(interp, m, "capwords", capwordsFn);
    return m;
}

fn setStr(a: std.mem.Allocator, m: *Module, name: []const u8, val: []const u8) !void {
    const s = try Str.init(a, val);
    try m.attrs.setStr(a, name, Value{ .str = s });
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn isAsciiSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 11 or c == 12;
}

fn capitalize(out: *std.ArrayList(u8), a: std.mem.Allocator, word: []const u8) !void {
    if (word.len == 0) return;
    const first = word[0];
    const upper: u8 = if (first >= 'a' and first <= 'z') first - 32 else first;
    try out.append(a, upper);
    for (word[1..]) |c| {
        const lower: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
        try out.append(a, lower);
    }
}

fn capwordsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("capwords expects a string");
        return error.TypeError;
    }
    const s = args[0].str.bytes;
    const sep_opt: ?[]const u8 = if (args.len >= 2 and args[1] == .str) args[1].str.bytes else null;
    const a = interp.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    if (sep_opt) |sep| {
        // Split on `sep` exactly, capitalize each part, join with same `sep`.
        var first = true;
        var i: usize = 0;
        while (i <= s.len) {
            const at = if (sep.len == 0)
                s.len
            else
                std.mem.indexOfPos(u8, s, i, sep) orelse s.len;
            const word = s[i..at];
            if (!first) try out.appendSlice(a, sep);
            try capitalize(&out, a, word);
            first = false;
            if (at == s.len) break;
            i = at + sep.len;
        }
    } else {
        // sep=None: split on runs of ASCII whitespace, drop leading/
        // trailing empties, join with single space.
        var first = true;
        var i: usize = 0;
        while (i < s.len) {
            while (i < s.len and isAsciiSpace(s[i])) i += 1;
            if (i >= s.len) break;
            const start = i;
            while (i < s.len and !isAsciiSpace(s[i])) i += 1;
            if (!first) try out.append(a, ' ');
            try capitalize(&out, a, s[start..i]);
            first = false;
        }
    }

    const owned = try out.toOwnedSlice(a);
    const new_s = try Str.fromOwnedSlice(a, owned);
    return Value{ .str = new_s };
}
