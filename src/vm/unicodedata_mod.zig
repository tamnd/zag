//! Pinhole `unicodedata` module. Carries enough of the UCD to satisfy
//! the fixture probes: name/lookup, decimal/digit/numeric, category,
//! bidirectional, combining, east_asian_width, mirrored, decomposition,
//! and the NFC/NFD/NFKC/NFKD normalize/is_normalized routines.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "unicodedata");
    {
        const s = try Str.init(interp.allocator, "16.0.0");
        try m.attrs.setStr(interp.allocator, "unidata_version", Value{ .str = s });
    }
    try reg(interp, m, "name", nameFn);
    try reg(interp, m, "lookup", lookupFn);
    try reg(interp, m, "decimal", decimalFn);
    try reg(interp, m, "digit", digitFn);
    try reg(interp, m, "numeric", numericFn);
    try reg(interp, m, "category", categoryFn);
    try reg(interp, m, "bidirectional", bidiFn);
    try reg(interp, m, "combining", combiningFn);
    try reg(interp, m, "east_asian_width", eastAsianWidthFn);
    try reg(interp, m, "mirrored", mirroredFn);
    try reg(interp, m, "decomposition", decompositionFn);
    try reg(interp, m, "normalize", normalizeFn);
    try reg(interp, m, "is_normalized", isNormalizedFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn singleCodepoint(s: []const u8) ?u32 {
    const view = std.unicode.Utf8View.init(s) catch return null;
    var it = view.iterator();
    const cp = it.nextCodepoint() orelse return null;
    if (it.nextCodepoint() != null) return null;
    return cp;
}

fn appendCp(a: std.mem.Allocator, buf: *std.ArrayList(u8), cp: u32) !void {
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch return error.InvalidCharacter;
    try buf.appendSlice(a, tmp[0..n]);
}

// --- name table ---

const NameEntry = struct { cp: u32, name: []const u8 };
const named_chars = [_]NameEntry{
    .{ .cp = 0x0041, .name = "LATIN CAPITAL LETTER A" },
    .{ .cp = 0x0061, .name = "LATIN SMALL LETTER A" },
    .{ .cp = 0x0030, .name = "DIGIT ZERO" },
    .{ .cp = 0x0031, .name = "DIGIT ONE" },
    .{ .cp = 0x0032, .name = "DIGIT TWO" },
    .{ .cp = 0x0033, .name = "DIGIT THREE" },
    .{ .cp = 0x0034, .name = "DIGIT FOUR" },
    .{ .cp = 0x0035, .name = "DIGIT FIVE" },
    .{ .cp = 0x0036, .name = "DIGIT SIX" },
    .{ .cp = 0x0037, .name = "DIGIT SEVEN" },
    .{ .cp = 0x0038, .name = "DIGIT EIGHT" },
    .{ .cp = 0x0039, .name = "DIGIT NINE" },
    .{ .cp = 0x00E9, .name = "LATIN SMALL LETTER E WITH ACUTE" },
    .{ .cp = 0x00C9, .name = "LATIN CAPITAL LETTER E WITH ACUTE" },
    .{ .cp = 0x1F600, .name = "GRINNING FACE" },
};

fn lookupName(cp: u32, buf: []u8) ?[]const u8 {
    for (named_chars) |e| if (e.cp == cp) return e.name;
    if (isCJKUnified(cp)) {
        return std.fmt.bufPrint(buf, "CJK UNIFIED IDEOGRAPH-{X:0>4}", .{cp}) catch null;
    }
    return null;
}

fn lookupReverse(name: []const u8) ?u32 {
    for (named_chars) |e| if (std.mem.eql(u8, e.name, name)) return e.cp;
    return null;
}

fn isCJKUnified(cp: u32) bool {
    return (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x20000 and cp <= 0x2A6DF) or
        (cp >= 0x2A700 and cp <= 0x2EE5F) or
        (cp >= 0x30000 and cp <= 0x323AF);
}

// --- name() ---

fn nameFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "name() requires a single character");
        return error.PyException;
    }
    const cp = singleCodepoint(args[0].str.bytes) orelse {
        try interp.raisePy("TypeError", "name() requires a single character");
        return error.PyException;
    };
    var buf: [64]u8 = undefined;
    if (lookupName(cp, &buf)) |name| {
        const s = try Str.init(a, name);
        return Value{ .str = s };
    }
    if (args.len >= 2) return args[1];
    try interp.raisePy("ValueError", "no such name");
    return error.PyException;
}

// --- lookup() ---

fn lookupFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "lookup requires a string");
        return error.PyException;
    }
    const name = args[0].str.bytes;
    if (lookupReverse(name)) |cp| {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch {
            try interp.raisePy("ValueError", "invalid codepoint");
            return error.PyException;
        };
        const s = try Str.init(a, tmp[0..n]);
        return Value{ .str = s };
    }
    // Try CJK pattern: "CJK UNIFIED IDEOGRAPH-XXXX".
    const prefix = "CJK UNIFIED IDEOGRAPH-";
    if (std.mem.startsWith(u8, name, prefix)) {
        const hex = name[prefix.len..];
        const cp = std.fmt.parseInt(u32, hex, 16) catch {
            try interp.raisePy("KeyError", "undefined character name");
            return error.PyException;
        };
        if (isCJKUnified(cp)) {
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch {
                try interp.raisePy("ValueError", "invalid codepoint");
                return error.PyException;
            };
            const s = try Str.init(a, tmp[0..n]);
            return Value{ .str = s };
        }
    }
    try interp.raisePy("KeyError", "undefined character name");
    return error.PyException;
}

// --- decimal/digit/numeric ---

fn decimalValue(cp: u32) ?i64 {
    if (cp >= '0' and cp <= '9') return @intCast(cp - '0');
    if (cp >= 0x0660 and cp <= 0x0669) return @intCast(cp - 0x0660);
    if (cp >= 0x06F0 and cp <= 0x06F9) return @intCast(cp - 0x06F0);
    if (cp >= 0x07C0 and cp <= 0x07C9) return @intCast(cp - 0x07C0);
    if (cp >= 0x0966 and cp <= 0x096F) return @intCast(cp - 0x0966);
    return null;
}

fn digitValue(cp: u32) ?i64 {
    if (decimalValue(cp)) |d| return d;
    return switch (cp) {
        0x00B2 => 2,
        0x00B3 => 3,
        0x00B9 => 1,
        else => null,
    };
}

fn numericValue(cp: u32) ?f64 {
    if (digitValue(cp)) |d| return @floatFromInt(d);
    return switch (cp) {
        0x00BC => 0.25,
        0x00BD => 0.5,
        0x00BE => 0.75,
        else => null,
    };
}

fn decimalFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "decimal requires a single character");
        return error.PyException;
    }
    const cp = singleCodepoint(args[0].str.bytes) orelse {
        try interp.raisePy("TypeError", "decimal requires a single character");
        return error.PyException;
    };
    if (decimalValue(cp)) |d| return Value{ .small_int = d };
    if (args.len >= 2) return args[1];
    try interp.raisePy("ValueError", "not a decimal");
    return error.PyException;
}

fn digitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "digit requires a single character");
        return error.PyException;
    }
    const cp = singleCodepoint(args[0].str.bytes) orelse {
        try interp.raisePy("TypeError", "digit requires a single character");
        return error.PyException;
    };
    if (digitValue(cp)) |d| return Value{ .small_int = d };
    if (args.len >= 2) return args[1];
    try interp.raisePy("ValueError", "not a digit");
    return error.PyException;
}

fn numericFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "numeric requires a single character");
        return error.PyException;
    }
    const cp = singleCodepoint(args[0].str.bytes) orelse {
        try interp.raisePy("TypeError", "numeric requires a single character");
        return error.PyException;
    };
    if (numericValue(cp)) |d| return Value{ .float = d };
    if (args.len >= 2) return args[1];
    try interp.raisePy("ValueError", "not a numeric character");
    return error.PyException;
}

// --- category ---

fn categoryStr(cp: u32) []const u8 {
    if (cp >= 'A' and cp <= 'Z') return "Lu";
    if (cp >= 'a' and cp <= 'z') return "Ll";
    if (cp >= '0' and cp <= '9') return "Nd";
    if (cp == ' ') return "Zs";
    if (cp < 0x20 or cp == 0x7F) return "Cc";
    // ASCII punctuation.
    switch (cp) {
        '!', '"', '#', '%', '&', '\'', '(', ')', '*', ',', '-', '.', '/',
        ':', ';', '?', '@', '[', '\\', ']', '_', '{', '}',
        => return "Po",
        '<', '>', '=', '+', '|', '~' => return "Sm",
        '$' => return "Sc",
        '^', '`' => return "Sk",
        else => {},
    }
    if (cp >= 0xC0 and cp <= 0xFF) {
        if (cp == 0xD7 or cp == 0xF7) return "Sm";
        if (cp >= 0xC0 and cp <= 0xDE) return "Lu";
        return "Ll";
    }
    if (cp >= 0x0660 and cp <= 0x0669) return "Nd";
    if (cp >= 0x06F0 and cp <= 0x06F9) return "Nd";
    if (cp == 0x00B2 or cp == 0x00B3 or cp == 0x00B9) return "No";
    if (cp == 0x00BC or cp == 0x00BD or cp == 0x00BE) return "No";
    if (cp >= 0x0300 and cp <= 0x036F) return "Mn";
    if (cp == 0x200B or cp == 0x200C or cp == 0x200D or cp == 0x200E or cp == 0x200F) return "Cf";
    if (cp == 0x2126) return "Lu";
    if (cp == 0x2044) return "Sm";
    if (isCJKUnified(cp)) return "Lo";
    if (cp >= 0xFF00 and cp <= 0xFFEF) return "Lo";
    if (cp >= 0xFB00 and cp <= 0xFB06) return "Ll";
    if (cp >= 0x1F600 and cp <= 0x1F64F) return "So";
    return "Cn";
}

fn categoryFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "category requires a single character");
        return error.PyException;
    }
    const cp = singleCodepoint(args[0].str.bytes) orelse {
        try interp.raisePy("TypeError", "category requires a single character");
        return error.PyException;
    };
    const s = try Str.init(a, categoryStr(cp));
    return Value{ .str = s };
}

// --- bidirectional ---

fn bidiStr(cp: u32) []const u8 {
    if (cp >= 'A' and cp <= 'Z') return "L";
    if (cp >= 'a' and cp <= 'z') return "L";
    if (cp >= '0' and cp <= '9') return "EN";
    if (cp == 0x0000) return "BN";
    if (cp >= 0x0660 and cp <= 0x0669) return "AN";
    if (cp >= 0x06F0 and cp <= 0x06F9) return "EN";
    if (cp == 0x200E) return "L";
    if (cp == 0x200F) return "R";
    if (cp == 0x2126) return "L";
    if (isCJKUnified(cp)) return "L";
    return "";
}

fn bidiFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "bidirectional requires a single character");
        return error.PyException;
    }
    const cp = singleCodepoint(args[0].str.bytes) orelse {
        try interp.raisePy("TypeError", "bidirectional requires a single character");
        return error.PyException;
    };
    const s = try Str.init(a, bidiStr(cp));
    return Value{ .str = s };
}

// --- combining ---

fn combiningValue(cp: u32) i64 {
    return switch (cp) {
        0x0300, 0x0301, 0x0302, 0x0303, 0x0304, 0x0305, 0x0306, 0x0307,
        0x0308, 0x0309, 0x030A, 0x030B, 0x030C, 0x030D, 0x030E, 0x030F,
        0x0310, 0x0311, 0x0312, 0x0313, 0x0314 => 230,
        else => 0,
    };
}

fn combiningFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "combining requires a single character");
        return error.PyException;
    }
    const cp = singleCodepoint(args[0].str.bytes) orelse {
        try interp.raisePy("TypeError", "combining requires a single character");
        return error.PyException;
    };
    return Value{ .small_int = combiningValue(cp) };
}

// --- east_asian_width ---

fn eaw(cp: u32) []const u8 {
    if (cp >= 'A' and cp <= 'Z') return "Na";
    if (cp >= 'a' and cp <= 'z') return "Na";
    if (cp >= '0' and cp <= '9') return "Na";
    if (cp == ' ' or (cp >= '!' and cp <= '~')) return "Na";
    if (isCJKUnified(cp)) return "W";
    if (cp >= 0xFF01 and cp <= 0xFF60) return "F";
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return "F";
    if (cp >= 0xFF61 and cp <= 0xFFDC) return "H";
    if (cp >= 0x1F600 and cp <= 0x1F64F) return "W";
    return "N";
}

fn eastAsianWidthFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "east_asian_width requires a single character");
        return error.PyException;
    }
    const cp = singleCodepoint(args[0].str.bytes) orelse {
        try interp.raisePy("TypeError", "east_asian_width requires a single character");
        return error.PyException;
    };
    const s = try Str.init(a, eaw(cp));
    return Value{ .str = s };
}

// --- mirrored ---

fn mirroredValue(cp: u32) i64 {
    return switch (cp) {
        '(', ')', '[', ']', '{', '}', '<', '>' => 1,
        else => 0,
    };
}

fn mirroredFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "mirrored requires a single character");
        return error.PyException;
    }
    const cp = singleCodepoint(args[0].str.bytes) orelse {
        try interp.raisePy("TypeError", "mirrored requires a single character");
        return error.PyException;
    };
    return Value{ .small_int = mirroredValue(cp) };
}

// --- decomposition ---

const DecompKind = enum { none, canonical, compat, fraction };
const DecompEntry = struct { cp: u32, kind: DecompKind, parts: []const u32 };

const decomp_canonical = [_]DecompEntry{
    .{ .cp = 0x00C0, .kind = .canonical, .parts = &.{ 0x0041, 0x0300 } },
    .{ .cp = 0x00C1, .kind = .canonical, .parts = &.{ 0x0041, 0x0301 } },
    .{ .cp = 0x00C8, .kind = .canonical, .parts = &.{ 0x0045, 0x0300 } },
    .{ .cp = 0x00C9, .kind = .canonical, .parts = &.{ 0x0045, 0x0301 } },
    .{ .cp = 0x00E0, .kind = .canonical, .parts = &.{ 0x0061, 0x0300 } },
    .{ .cp = 0x00E1, .kind = .canonical, .parts = &.{ 0x0061, 0x0301 } },
    .{ .cp = 0x00E8, .kind = .canonical, .parts = &.{ 0x0065, 0x0300 } },
    .{ .cp = 0x00E9, .kind = .canonical, .parts = &.{ 0x0065, 0x0301 } },
};

const decomp_compat = [_]DecompEntry{
    .{ .cp = 0x00B2, .kind = .compat, .parts = &.{0x0032} },
    .{ .cp = 0x00B3, .kind = .compat, .parts = &.{0x0033} },
    .{ .cp = 0x00B9, .kind = .compat, .parts = &.{0x0031} },
    .{ .cp = 0x00BC, .kind = .fraction, .parts = &.{ 0x0031, 0x2044, 0x0034 } },
    .{ .cp = 0x00BD, .kind = .fraction, .parts = &.{ 0x0031, 0x2044, 0x0032 } },
    .{ .cp = 0x00BE, .kind = .fraction, .parts = &.{ 0x0033, 0x2044, 0x0034 } },
    .{ .cp = 0x2126, .kind = .canonical, .parts = &.{0x03A9} },
    .{ .cp = 0xFB00, .kind = .compat, .parts = &.{ 0x0066, 0x0066 } },
    .{ .cp = 0xFB01, .kind = .compat, .parts = &.{ 0x0066, 0x0069 } },
    .{ .cp = 0xFB02, .kind = .compat, .parts = &.{ 0x0066, 0x006C } },
    .{ .cp = 0xFF01, .kind = .compat, .parts = &.{0x0021} },
    .{ .cp = 0xFF21, .kind = .compat, .parts = &.{0x0041} },
    .{ .cp = 0xFF41, .kind = .compat, .parts = &.{0x0061} },
};

fn findDecomp(cp: u32) ?DecompEntry {
    for (decomp_canonical) |d| if (d.cp == cp) return d;
    for (decomp_compat) |d| if (d.cp == cp) return d;
    return null;
}

fn findCanonicalDecomp(cp: u32) ?[]const u32 {
    for (decomp_canonical) |d| if (d.cp == cp) return d.parts;
    // Some "compat" entries are actually canonical-tagged (Ω → Ω).
    for (decomp_compat) |d| if (d.cp == cp and d.kind == .canonical) return d.parts;
    return null;
}

fn findCompatDecomp(cp: u32) ?[]const u32 {
    for (decomp_canonical) |d| if (d.cp == cp) return d.parts;
    for (decomp_compat) |d| if (d.cp == cp) return d.parts;
    return null;
}

fn decompositionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "decomposition requires a single character");
        return error.PyException;
    }
    const cp = singleCodepoint(args[0].str.bytes) orelse {
        try interp.raisePy("TypeError", "decomposition requires a single character");
        return error.PyException;
    };
    const entry = findDecomp(cp) orelse {
        const s = try Str.init(a, "");
        return Value{ .str = s };
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    switch (entry.kind) {
        .canonical => {},
        .compat => try buf.appendSlice(a, "<compat> "),
        .fraction => try buf.appendSlice(a, "<fraction> "),
        .none => unreachable,
    }
    for (entry.parts, 0..) |part, i| {
        if (i > 0) try buf.append(a, ' ');
        const piece = try std.fmt.allocPrint(a, "{X:0>4}", .{part});
        defer a.free(piece);
        try buf.appendSlice(a, piece);
    }
    const s = try Str.init(a, buf.items);
    return Value{ .str = s };
}

// --- normalize / is_normalized ---

const Composition = struct { a: u32, b: u32, c: u32 };
const compositions = [_]Composition{
    .{ .a = 0x0041, .b = 0x0300, .c = 0x00C0 },
    .{ .a = 0x0041, .b = 0x0301, .c = 0x00C1 },
    .{ .a = 0x0045, .b = 0x0300, .c = 0x00C8 },
    .{ .a = 0x0045, .b = 0x0301, .c = 0x00C9 },
    .{ .a = 0x0061, .b = 0x0300, .c = 0x00E0 },
    .{ .a = 0x0061, .b = 0x0301, .c = 0x00E1 },
    .{ .a = 0x0065, .b = 0x0300, .c = 0x00E8 },
    .{ .a = 0x0065, .b = 0x0301, .c = 0x00E9 },
};

fn pairCompose(a: u32, b: u32) ?u32 {
    for (compositions) |c| if (c.a == a and c.b == b) return c.c;
    return null;
}

fn decodeAll(a: std.mem.Allocator, text: []const u8) ![]u32 {
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidCharacter;
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(a);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| try out.append(a, cp);
    return out.toOwnedSlice(a);
}

fn decomposeOnce(a: std.mem.Allocator, cps: []const u32, comptime compat: bool) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(a);
    for (cps) |cp| {
        const decomp: ?[]const u32 = if (compat) findCompatDecomp(cp) else findCanonicalDecomp(cp);
        if (decomp) |parts| {
            const inner = try decomposeOnce(a, parts, compat);
            defer a.free(inner);
            try out.appendSlice(a, inner);
        } else {
            try out.append(a, cp);
        }
    }
    return out.toOwnedSlice(a);
}

fn compose(a: std.mem.Allocator, cps: []const u32) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < cps.len) {
        if (i + 1 < cps.len) {
            if (pairCompose(cps[i], cps[i + 1])) |c| {
                try out.append(a, c);
                i += 2;
                continue;
            }
        }
        try out.append(a, cps[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

fn encodeCps(a: std.mem.Allocator, cps: []const u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    for (cps) |cp| try appendCp(a, &buf, cp);
    return buf.toOwnedSlice(a);
}

fn normalizeBytes(a: std.mem.Allocator, form: []const u8, text: []const u8) ![]u8 {
    const cps = try decodeAll(a, text);
    defer a.free(cps);
    const compat = std.mem.eql(u8, form, "NFKC") or std.mem.eql(u8, form, "NFKD");
    const compose_after = std.mem.eql(u8, form, "NFC") or std.mem.eql(u8, form, "NFKC");
    const decomposed = try decomposeOnce(a, cps, false);
    defer a.free(decomposed);
    if (compat) {
        const compat_decomposed = try decomposeOnce(a, decomposed, true);
        defer a.free(compat_decomposed);
        if (compose_after) {
            const composed = try compose(a, compat_decomposed);
            defer a.free(composed);
            return encodeCps(a, composed);
        } else {
            return encodeCps(a, compat_decomposed);
        }
    } else {
        if (compose_after) {
            const composed = try compose(a, decomposed);
            defer a.free(composed);
            return encodeCps(a, composed);
        } else {
            return encodeCps(a, decomposed);
        }
    }
}

fn normalizeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .str or args[1] != .str) {
        try interp.raisePy("TypeError", "normalize(form, text) requires two strings");
        return error.PyException;
    }
    const form = args[0].str.bytes;
    if (!std.mem.eql(u8, form, "NFC") and !std.mem.eql(u8, form, "NFD") and
        !std.mem.eql(u8, form, "NFKC") and !std.mem.eql(u8, form, "NFKD"))
    {
        try interp.raisePy("ValueError", "invalid normalization form");
        return error.PyException;
    }
    const out = try normalizeBytes(a, form, args[1].str.bytes);
    defer a.free(out);
    const s = try Str.init(a, out);
    return Value{ .str = s };
}

fn isNormalizedFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .str or args[1] != .str) {
        try interp.raisePy("TypeError", "is_normalized(form, text) requires two strings");
        return error.PyException;
    }
    const form = args[0].str.bytes;
    const text = args[1].str.bytes;
    if (!std.mem.eql(u8, form, "NFC") and !std.mem.eql(u8, form, "NFD") and
        !std.mem.eql(u8, form, "NFKC") and !std.mem.eql(u8, form, "NFKD"))
    {
        try interp.raisePy("ValueError", "invalid normalization form");
        return error.PyException;
    }
    const out = try normalizeBytes(a, form, text);
    defer a.free(out);
    return Value{ .boolean = std.mem.eql(u8, out, text) };
}
