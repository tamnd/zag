//! Pinhole `token` module: CPython 3.14 token constants + tok_name + ISEOF.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

const tokens = [_]struct { []const u8, i64 }{
    .{ "ENDMARKER", 0 },
    .{ "NAME", 1 },
    .{ "NUMBER", 2 },
    .{ "STRING", 3 },
    .{ "NEWLINE", 4 },
    .{ "INDENT", 5 },
    .{ "DEDENT", 6 },
    .{ "LPAR", 7 },
    .{ "RPAR", 8 },
    .{ "LSQB", 9 },
    .{ "RSQB", 10 },
    .{ "COLON", 11 },
    .{ "COMMA", 12 },
    .{ "SEMI", 13 },
    .{ "PLUS", 14 },
    .{ "MINUS", 15 },
    .{ "STAR", 16 },
    .{ "SLASH", 17 },
    .{ "VBAR", 18 },
    .{ "AMPER", 19 },
    .{ "LESS", 20 },
    .{ "GREATER", 21 },
    .{ "EQUAL", 22 },
    .{ "DOT", 23 },
    .{ "PERCENT", 24 },
    .{ "LBRACE", 25 },
    .{ "RBRACE", 26 },
    .{ "EQEQUAL", 27 },
    .{ "NOTEQUAL", 28 },
    .{ "LESSEQUAL", 29 },
    .{ "GREATEREQUAL", 30 },
    .{ "TILDE", 31 },
    .{ "CIRCUMFLEX", 32 },
    .{ "LEFTSHIFT", 33 },
    .{ "RIGHTSHIFT", 34 },
    .{ "DOUBLESTAR", 35 },
    .{ "PLUSEQUAL", 36 },
    .{ "MINEQUAL", 37 },
    .{ "STAREQUAL", 38 },
    .{ "SLASHEQUAL", 39 },
    .{ "PERCENTEQUAL", 40 },
    .{ "AMPEREQUAL", 41 },
    .{ "VBAREQUAL", 42 },
    .{ "CIRCUMFLEXEQUAL", 43 },
    .{ "LEFTSHIFTEQUAL", 44 },
    .{ "RIGHTSHIFTEQUAL", 45 },
    .{ "DOUBLESTAREQUAL", 46 },
    .{ "DOUBLESLASH", 47 },
    .{ "DOUBLESLASHEQUAL", 48 },
    .{ "AT", 49 },
    .{ "ATEQUAL", 50 },
    .{ "RARROW", 51 },
    .{ "ELLIPSIS", 52 },
    .{ "COLONEQUAL", 53 },
    .{ "EXCLAMATION", 53 },
    .{ "OP", 54 },
    .{ "AWAIT", 55 },
    .{ "ASYNC", 56 },
    .{ "TYPE_IGNORE", 57 },
    .{ "TYPE_COMMENT", 58 },
    .{ "SOFT_KEYWORD", 59 },
    .{ "FSTRING_START", 60 },
    .{ "FSTRING_MIDDLE", 61 },
    .{ "FSTRING_END", 62 },
    .{ "COMMENT", 60 },
    .{ "NL", 61 },
    .{ "ERRORTOKEN", 59 },
    .{ "ENCODING", 62 },
    .{ "N_TOKENS", 63 },
    .{ "NT_OFFSET", 256 },
};

fn isEOFFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    const n: i64 = switch (args[0]) {
        .small_int => |i| i,
        .boolean => |b| if (b) 1 else 0,
        else => return Value{ .boolean = false },
    };
    return Value{ .boolean = n == 0 }; // ENDMARKER == 0
}
fn isTerminalFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    const n: i64 = switch (args[0]) {
        .small_int => |i| i,
        else => return Value{ .boolean = false },
    };
    return Value{ .boolean = n < 256 };
}
fn isNonterminalFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    const n: i64 = switch (args[0]) {
        .small_int => |i| i,
        else => return Value{ .boolean = false },
    };
    return Value{ .boolean = n >= 256 };
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "token");

    // Build tok_name dict and individual constants
    const tok_name = try Dict.init(a);

    for (tokens) |pair| {
        const name = pair[0];
        const val = pair[1];
        try m.attrs.setStr(a, name, Value{ .small_int = val });
        // tok_name[val] = name (using small_int key)
        const str_val = try Str.init(a, name);
        try tok_name.pairs.append(a, .{
            .key = Value{ .small_int = val },
            .value = Value{ .str = str_val },
        });
    }
    try m.attrs.setStr(a, "tok_name", Value{ .dict = tok_name });

    const f_iseof = try a.create(BuiltinFn);
    f_iseof.* = .{ .name = "ISEOF", .func = isEOFFn };
    try m.attrs.setStr(a, "ISEOF", Value{ .builtin_fn = f_iseof });

    const f_isterm = try a.create(BuiltinFn);
    f_isterm.* = .{ .name = "ISTERMINAL", .func = isTerminalFn };
    try m.attrs.setStr(a, "ISTERMINAL", Value{ .builtin_fn = f_isterm });

    const f_isnonterm = try a.create(BuiltinFn);
    f_isnonterm.* = .{ .name = "ISNONTERMINAL", .func = isNonterminalFn };
    try m.attrs.setStr(a, "ISNONTERMINAL", Value{ .builtin_fn = f_isnonterm });

    return m;
}
