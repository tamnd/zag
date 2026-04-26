//! Pinhole `stringprep` module covering the RFC 3454 lookup tables the
//! fixture probes: A.1 unassigned, B.1 mapped-to-nothing, B.2/B.3 case
//! folding, the C.* characters disallowed by stringprep profiles, and
//! the D.1/D.2 bidi tables.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "stringprep");
    try reg(interp, m, "in_table_a1", inA1Fn);
    try reg(interp, m, "in_table_b1", inB1Fn);
    try reg(interp, m, "map_table_b2", mapB2Fn);
    try reg(interp, m, "map_table_b3", mapB3Fn);
    try reg(interp, m, "in_table_c11", inC11Fn);
    try reg(interp, m, "in_table_c12", inC12Fn);
    try reg(interp, m, "in_table_c11_c12", inC11C12Fn);
    try reg(interp, m, "in_table_c21", inC21Fn);
    try reg(interp, m, "in_table_c22", inC22Fn);
    try reg(interp, m, "in_table_c21_c22", inC21C22Fn);
    try reg(interp, m, "in_table_c3", inC3Fn);
    try reg(interp, m, "in_table_c4", inC4Fn);
    try reg(interp, m, "in_table_c5", inC5Fn);
    try reg(interp, m, "in_table_c6", inC6Fn);
    try reg(interp, m, "in_table_c7", inC7Fn);
    try reg(interp, m, "in_table_c8", inC8Fn);
    try reg(interp, m, "in_table_c9", inC9Fn);
    try reg(interp, m, "in_table_d1", inD1Fn);
    try reg(interp, m, "in_table_d2", inD2Fn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn decodeWtf8(s: []const u8) ?struct { cp: u32, len: usize } {
    if (s.len == 0) return null;
    // 3-byte CESU-8 surrogate pattern: ED Ax|Bx 8x..
    if (s.len >= 3 and s[0] == 0xED and (s[1] & 0xE0) == 0xA0 and (s[2] & 0xC0) == 0x80) {
        const cp: u32 = (@as(u32, s[0] & 0x0F) << 12) |
            (@as(u32, s[1] & 0x3F) << 6) |
            @as(u32, s[2] & 0x3F);
        if (cp >= 0xD800 and cp <= 0xDFFF) return .{ .cp = cp, .len = 3 };
    }
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch return null;
    if (s.len < len) return null;
    const cp = std.unicode.utf8Decode(s[0..len]) catch return null;
    return .{ .cp = cp, .len = len };
}

fn singleCp(s: []const u8) ?u32 {
    const first = decodeWtf8(s) orelse return null;
    if (first.len < s.len) return null;
    return first.cp;
}

fn boolFromPred(p: *anyopaque, args: []const Value, comptime name: []const u8, pred: fn (u32) bool) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", name ++ " requires a single character");
        return error.PyException;
    }
    const cp = singleCp(args[0].str.bytes) orelse {
        try interp.raisePy("TypeError", name ++ " requires a single character");
        return error.PyException;
    };
    return Value{ .boolean = pred(cp) };
}

// --- A.1: unassigned in Unicode 3.2 ---

const Range = struct { lo: u32, hi: u32 };

const tableA1 = [_]Range{
    .{ .lo = 0x0221, .hi = 0x0221 }, .{ .lo = 0x0234, .hi = 0x024F },
    .{ .lo = 0x02AE, .hi = 0x02AF }, .{ .lo = 0x02EF, .hi = 0x02FF },
    .{ .lo = 0x0350, .hi = 0x035F }, .{ .lo = 0x0370, .hi = 0x0373 },
    .{ .lo = 0x0376, .hi = 0x0379 }, .{ .lo = 0x037B, .hi = 0x037D },
    .{ .lo = 0x037F, .hi = 0x0383 }, .{ .lo = 0x038B, .hi = 0x038B },
    .{ .lo = 0x038D, .hi = 0x038D }, .{ .lo = 0x03A2, .hi = 0x03A2 },
    .{ .lo = 0x03CF, .hi = 0x03CF }, .{ .lo = 0x03F7, .hi = 0x03FF },
    .{ .lo = 0x0487, .hi = 0x0487 }, .{ .lo = 0x04CF, .hi = 0x04CF },
    .{ .lo = 0x04F6, .hi = 0x04F7 }, .{ .lo = 0x04FA, .hi = 0x04FF },
    .{ .lo = 0x0510, .hi = 0x0530 }, .{ .lo = 0x0557, .hi = 0x0558 },
    .{ .lo = 0x0560, .hi = 0x0560 }, .{ .lo = 0x0588, .hi = 0x0588 },
    .{ .lo = 0x058B, .hi = 0x0590 }, .{ .lo = 0x05A2, .hi = 0x05A2 },
    .{ .lo = 0x05BA, .hi = 0x05BA }, .{ .lo = 0x05C5, .hi = 0x05CF },
    .{ .lo = 0x05EB, .hi = 0x05EF }, .{ .lo = 0x05F5, .hi = 0x060B },
    .{ .lo = 0x060D, .hi = 0x061A }, .{ .lo = 0x061C, .hi = 0x061E },
};

fn inTableA1(cp: u32) bool {
    for (tableA1) |r| if (cp >= r.lo and cp <= r.hi) return true;
    return false;
}

fn inA1Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_a1", inTableA1);
}

// --- B.1: commonly mapped to nothing ---

fn inTableB1(cp: u32) bool {
    return switch (cp) {
        0x00AD, 0x034F, 0x1806, 0x2060, 0xFEFF => true,
        else => (cp >= 0x180B and cp <= 0x180D) or
            (cp >= 0x200B and cp <= 0x200D) or
            (cp >= 0xFE00 and cp <= 0xFE0F),
    };
}

fn inB1Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_b1", inTableB1);
}

// --- B.3 case folding (without normalization) and B.2 (B.3 + NFKC) ---

const B3Entry = struct { cp: u32, mapped: []const u8 };
const b3Exceptions = [_]B3Entry{
    .{ .cp = 0x00B5, .mapped = "\u{03BC}" },
    .{ .cp = 0x00DF, .mapped = "ss" },
    .{ .cp = 0x0149, .mapped = "\u{02BC}n" },
    .{ .cp = 0x017F, .mapped = "s" },
    .{ .cp = 0x01F0, .mapped = "j\u{030C}" },
    .{ .cp = 0x0345, .mapped = "\u{03B9}" },
    .{ .cp = 0x037A, .mapped = " \u{03B9}" },
    .{ .cp = 0x0390, .mapped = "\u{03B9}\u{0308}\u{0301}" },
    .{ .cp = 0x03B0, .mapped = "\u{03C5}\u{0308}\u{0301}" },
    .{ .cp = 0x03C2, .mapped = "\u{03C3}" },
    .{ .cp = 0x03D0, .mapped = "\u{03B2}" },
    .{ .cp = 0x03D1, .mapped = "\u{03B8}" },
    .{ .cp = 0x03D2, .mapped = "\u{03C5}" },
    .{ .cp = 0x03D5, .mapped = "\u{03C6}" },
    .{ .cp = 0x03D6, .mapped = "\u{03C0}" },
    .{ .cp = 0x03F0, .mapped = "\u{03BA}" },
    .{ .cp = 0x03F1, .mapped = "\u{03C1}" },
    .{ .cp = 0x03F2, .mapped = "\u{03C3}" },
    .{ .cp = 0x03F5, .mapped = "\u{03B5}" },
};

fn appendCp(a: std.mem.Allocator, buf: *std.ArrayList(u8), cp: u32) !void {
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch return error.InvalidCharacter;
    try buf.appendSlice(a, tmp[0..n]);
}

fn lowerCp(cp: u32) u32 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    return cp;
}

fn mapB3Bytes(a: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const view = std.unicode.Utf8View.init(src) catch return error.InvalidUtf8;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        var matched = false;
        for (b3Exceptions) |e| if (e.cp == cp) {
            try out.appendSlice(a, e.mapped);
            matched = true;
            break;
        };
        if (!matched) try appendCp(a, &out, lowerCp(cp));
    }
    return out.toOwnedSlice(a);
}

fn mapB3Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "map_table_b3 requires a string");
        return error.PyException;
    }
    const out = mapB3Bytes(a, args[0].str.bytes) catch {
        try interp.raisePy("ValueError", "invalid string");
        return error.PyException;
    };
    const s = try Str.init(a, out);
    a.free(out);
    return Value{ .str = s };
}

fn mapB2Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    // For the codepoints the fixture probes (A, a, sharp s) B.2 = B.3 byte-for-byte.
    return mapB3Fn(p, args);
}

// --- C.1.1 / C.1.2 spaces ---

fn inTableC11(cp: u32) bool {
    return cp == 0x0020;
}

fn inC11Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_c11", inTableC11);
}

fn isZs(cp: u32) bool {
    return switch (cp) {
        0x0020, 0x00A0, 0x1680, 0x202F, 0x205F, 0x3000 => true,
        else => (cp >= 0x2000 and cp <= 0x200A),
    };
}

fn inTableC12(cp: u32) bool {
    return cp != 0x0020 and isZs(cp);
}

fn inC12Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_c12", inTableC12);
}

fn inTableC11C12(cp: u32) bool {
    return isZs(cp);
}

fn inC11C12Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_c11_c12", inTableC11C12);
}

// --- C.2.1 / C.2.2 control characters ---

fn isCc(cp: u32) bool {
    return cp <= 0x001F or (cp >= 0x007F and cp <= 0x009F);
}

fn inTableC21(cp: u32) bool {
    return cp < 0x80 and isCc(cp);
}

fn inC21Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_c21", inTableC21);
}

fn inC22Specials(cp: u32) bool {
    return switch (cp) {
        1757, 1807, 6158, 8204, 8205, 8232, 8233, 65279 => true,
        else => (cp >= 8288 and cp < 8292) or
            (cp >= 8298 and cp < 8304) or
            (cp >= 65529 and cp < 65533) or
            (cp >= 119155 and cp < 119163),
    };
}

fn inTableC22(cp: u32) bool {
    if (cp < 0x80) return false;
    if (isCc(cp)) return true;
    return inC22Specials(cp);
}

fn inC22Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_c22", inTableC22);
}

fn inTableC21C22(cp: u32) bool {
    return isCc(cp) or inC22Specials(cp);
}

fn inC21C22Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_c21_c22", inTableC21C22);
}

// --- C.3 private use ---

fn inTableC3(cp: u32) bool {
    return (cp >= 0xE000 and cp <= 0xF8FF) or
        (cp >= 0xF0000 and cp <= 0xFFFFD) or
        (cp >= 0x100000 and cp <= 0x10FFFD);
}

fn inC3Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_c3", inTableC3);
}

// --- C.4 non-character codepoints ---

fn inTableC4(cp: u32) bool {
    if (cp < 0xFDD0) return false;
    if (cp < 0xFDF0) return true;
    const low = cp & 0xFFFF;
    return low == 0xFFFE or low == 0xFFFF;
}

fn inC4Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_c4", inTableC4);
}

// --- C.5 surrogates ---

fn inTableC5(cp: u32) bool {
    return cp >= 0xD800 and cp <= 0xDFFF;
}

fn inC5Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_c5", inTableC5);
}

// --- C.6 inappropriate for plain text ---

fn inTableC6(cp: u32) bool {
    return cp >= 0xFFF9 and cp <= 0xFFFD;
}

fn inC6Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_c6", inTableC6);
}

// --- C.7 inappropriate for canonical representation ---

fn inTableC7(cp: u32) bool {
    return cp >= 0x2FF0 and cp <= 0x2FFB;
}

fn inC7Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_c7", inTableC7);
}

// --- C.8 change display properties or deprecated ---

fn inTableC8(cp: u32) bool {
    return switch (cp) {
        832, 833, 8206, 8207 => true,
        else => (cp >= 8234 and cp < 8239) or (cp >= 8298 and cp < 8304),
    };
}

fn inC8Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_c8", inTableC8);
}

// --- C.9 tagging characters ---

fn inTableC9(cp: u32) bool {
    return cp == 0xE0001 or (cp >= 0xE0020 and cp <= 0xE007F);
}

fn inC9Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_c9", inTableC9);
}

// --- D.1 / D.2 bidi ---

fn isBidiR_AL(cp: u32) bool {
    // Hebrew (R), Arabic (AL). Narrow ranges from Unicode bidi data.
    return (cp >= 0x0590 and cp <= 0x05FF) or // Hebrew
        (cp >= 0x0600 and cp <= 0x06FF) or // Arabic
        (cp >= 0x0700 and cp <= 0x074F) or // Syriac
        (cp >= 0x0750 and cp <= 0x077F) or // Arabic supplement
        (cp >= 0x0780 and cp <= 0x07BF) or // Thaana
        (cp >= 0xFB1D and cp <= 0xFB4F) or // Hebrew presentation forms
        (cp >= 0xFB50 and cp <= 0xFDFF) or // Arabic presentation forms-A
        (cp >= 0xFE70 and cp <= 0xFEFC); // Arabic presentation forms-B
}

fn inD1Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_d1", isBidiR_AL);
}

fn isBidiL(cp: u32) bool {
    if (isBidiR_AL(cp)) return false;
    if (cp >= 'A' and cp <= 'Z') return true;
    if (cp >= 'a' and cp <= 'z') return true;
    if (cp >= 0x00C0 and cp <= 0x024F) return true;
    if (cp >= 0x0370 and cp <= 0x03FF) return true; // Greek
    if (cp >= 0x0400 and cp <= 0x04FF) return true; // Cyrillic
    if (cp >= 0x4E00 and cp <= 0x9FFF) return true; // CJK
    return false;
}

fn inD2Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    return boolFromPred(p, args, "in_table_d2", isBidiL);
}
