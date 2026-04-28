//! Pinhole `curses.ascii` module.
//! ASCII character classification functions and constants.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

fn regM(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

// convert arg to ordinal value
fn toOrd(arg: Value) ?i64 {
    switch (arg) {
        .small_int => |n| return n,
        .str => |s| {
            if (s.bytes.len == 0) return null;
            return @intCast(s.bytes[0]);
        },
        .bytes => |b| {
            if (b.data.len == 0) return null;
            return @intCast(b.data[0]);
        },
        else => return null,
    }
}

fn getArg(args: []const Value) ?i64 {
    if (args.len < 1) return null;
    // skip self if instance
    const start: usize = if (args[0] == .instance) 1 else 0;
    if (start >= args.len) return null;
    return toOrd(args[start]);
}

fn isasciiFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .boolean = false };
    return Value{ .boolean = c >= 0 and c <= 127 };
}

fn isdigitFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .boolean = false };
    return Value{ .boolean = c >= '0' and c <= '9' };
}

fn isalphaFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .boolean = false };
    return Value{ .boolean = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') };
}

fn isupperFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .boolean = false };
    return Value{ .boolean = c >= 'A' and c <= 'Z' };
}

fn islowerFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .boolean = false };
    return Value{ .boolean = c >= 'a' and c <= 'z' };
}

fn isalnumFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .boolean = false };
    return Value{ .boolean = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') };
}

fn isspaceFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .boolean = false };
    return Value{ .boolean = c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c };
}

fn isblankFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .boolean = false };
    return Value{ .boolean = c == ' ' or c == '\t' };
}

fn iscntrlFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .boolean = false };
    return Value{ .boolean = (c >= 0 and c < 32) or c == 127 };
}

fn isprintFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .boolean = false };
    return Value{ .boolean = c >= 32 and c < 127 };
}

fn ispunctFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .boolean = false };
    const is_alnum = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
    return Value{ .boolean = c >= 33 and c <= 126 and !is_alnum };
}

fn isgraphFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .boolean = false };
    return Value{ .boolean = c > 32 and c < 127 };
}

fn isxdigitFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .boolean = false };
    return Value{ .boolean = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') };
}

fn asciiOrdFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .small_int = 0 };
    return Value{ .small_int = c };
}

fn toupperFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const c = getArg(args) orelse return Value{ .small_int = 0 };
    if (c >= 'a' and c <= 'z') return Value{ .small_int = c - 32 };
    // return as chr string
    _ = interp;
    return Value{ .small_int = c };
}

fn tolowerFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .small_int = 0 };
    if (c >= 'A' and c <= 'Z') return Value{ .small_int = c + 32 };
    return Value{ .small_int = c };
}

fn ctrlFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .small_int = 0 };
    return Value{ .small_int = c & 0x1f };
}

fn altFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .small_int = 0 };
    return Value{ .small_int = c | 0x80 };
}

fn toasciiFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const c = getArg(args) orelse return Value{ .small_int = 0 };
    return Value{ .small_int = c & 0x7f };
}

fn unctrlFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *@import("interp.zig").Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const c = getArg(args) orelse return Value{ .str = try @import("../object/string.zig").Str.init(a, "") };
    if (c >= 32 and c < 127) {
        var buf: [1]u8 = .{@intCast(c)};
        return Value{ .str = try @import("../object/string.zig").Str.init(a, &buf) };
    }
    if (c == 127) return Value{ .str = try @import("../object/string.zig").Str.init(a, "^?") };
    if (c < 32) {
        var buf: [2]u8 = .{ '^', @intCast(c + 64) };
        return Value{ .str = try @import("../object/string.zig").Str.init(a, &buf) };
    }
    return Value{ .str = try @import("../object/string.zig").Str.init(a, "") };
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "curses.ascii");

    // constants
    const consts = &[_]struct { []const u8, i64 }{
        .{ "NUL", 0 },  .{ "SOH", 1 },   .{ "STX", 2 },  .{ "ETX", 3 },
        .{ "EOT", 4 },  .{ "ENQ", 5 },   .{ "ACK", 6 },  .{ "BEL", 7 },
        .{ "BS", 8 },   .{ "TAB", 9 },   .{ "HT", 9 },   .{ "LF", 10 },
        .{ "NL", 10 },  .{ "VT", 11 },   .{ "FF", 12 },  .{ "CR", 13 },
        .{ "SO", 14 },  .{ "SI", 15 },   .{ "DLE", 16 }, .{ "DC1", 17 },
        .{ "DC2", 18 }, .{ "DC3", 19 },  .{ "DC4", 20 }, .{ "NAK", 21 },
        .{ "SYN", 22 }, .{ "ETB", 23 },  .{ "CAN", 24 }, .{ "EM", 25 },
        .{ "SUB", 26 }, .{ "ESC", 27 },  .{ "FS", 28 },  .{ "GS", 29 },
        .{ "RS", 30 },  .{ "US", 31 },   .{ "SP", 32 },  .{ "DEL", 127 },
        .{ "EOF", -1 },
    };
    for (consts) |pr| try m.attrs.setStr(a, pr[0], Value{ .small_int = pr[1] });

    try regM(a, m, "isascii", isasciiFn);
    try regM(a, m, "isdigit", isdigitFn);
    try regM(a, m, "isalpha", isalphaFn);
    try regM(a, m, "isupper", isupperFn);
    try regM(a, m, "islower", islowerFn);
    try regM(a, m, "isalnum", isalnumFn);
    try regM(a, m, "isspace", isspaceFn);
    try regM(a, m, "isblank", isblankFn);
    try regM(a, m, "iscntrl", iscntrlFn);
    try regM(a, m, "isprint", isprintFn);
    try regM(a, m, "ispunct", ispunctFn);
    try regM(a, m, "isgraph", isgraphFn);
    try regM(a, m, "isxdigit", isxdigitFn);
    try regM(a, m, "ascii", asciiOrdFn);
    try regM(a, m, "toupper", toupperFn);
    try regM(a, m, "tolower", tolowerFn);
    try regM(a, m, "ctrl", ctrlFn);
    try regM(a, m, "alt", altFn);
    try regM(a, m, "toascii", toasciiFn);
    try regM(a, m, "unctrl", unctrlFn);

    return m;
}

/// Build a stub `curses` package module that hosts `ascii` as a submodule.
pub fn buildCursesPackage(interp: *Interp) !*@import("../object/module.zig").Module {
    const a = interp.allocator;
    const m = try @import("../object/module.zig").Module.init(a, "curses");
    m.is_package = true;
    // build ascii submodule and attach
    const ascii_m = try build(interp);
    try m.attrs.setStr(a, "ascii", Value{ .module = ascii_m });
    return m;
}
