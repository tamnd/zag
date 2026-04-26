//! Pinhole `re` module bridge. Wraps `lib/re/` engine in Python
//! Pattern / Match instance objects with the methods fixture 65
//! exercises.

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
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

const re = @import("../lib/re/re.zig");

const FLAG_IGNORECASE: i64 = 2;
const FLAG_MULTILINE: i64 = 8;
const FLAG_DOTALL: i64 = 16;
const FLAG_UNICODE: i64 = 32;
const FLAG_VERBOSE: i64 = 64;
const FLAG_ASCII: i64 = 256;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "re");
    const a = interp.allocator;

    try m.attrs.setStr(a, "IGNORECASE", Value{ .small_int = FLAG_IGNORECASE });
    try m.attrs.setStr(a, "I", Value{ .small_int = FLAG_IGNORECASE });
    try m.attrs.setStr(a, "MULTILINE", Value{ .small_int = FLAG_MULTILINE });
    try m.attrs.setStr(a, "M", Value{ .small_int = FLAG_MULTILINE });
    try m.attrs.setStr(a, "DOTALL", Value{ .small_int = FLAG_DOTALL });
    try m.attrs.setStr(a, "S", Value{ .small_int = FLAG_DOTALL });
    try m.attrs.setStr(a, "VERBOSE", Value{ .small_int = FLAG_VERBOSE });
    try m.attrs.setStr(a, "X", Value{ .small_int = FLAG_VERBOSE });
    try m.attrs.setStr(a, "ASCII", Value{ .small_int = FLAG_ASCII });
    try m.attrs.setStr(a, "A", Value{ .small_int = FLAG_ASCII });
    try m.attrs.setStr(a, "UNICODE", Value{ .small_int = FLAG_UNICODE });
    try m.attrs.setStr(a, "U", Value{ .small_int = FLAG_UNICODE });
    try m.attrs.setStr(a, "NOFLAG", Value{ .small_int = 0 });

    try ensureClasses(interp);

    try regKw(interp, m, "match", reMatchFn, reMatchKw);
    try regKw(interp, m, "search", reSearchFn, reSearchKw);
    try regKw(interp, m, "fullmatch", reFullmatchFn, reFullmatchKw);
    try regKw(interp, m, "findall", reFindallFn, reFindallKw);
    try regKw(interp, m, "finditer", reFinditerFn, reFinditerKw);
    try regKw(interp, m, "split", reSplitFn, reSplitKw);
    try regKw(interp, m, "sub", reSubFn, reSubKw);
    try regKw(interp, m, "subn", reSubnFn, reSubnKw);
    try regKw(interp, m, "compile", reCompileFn, reCompileKw);
    try reg(interp, m, "escape", reEscapeFn);
    try reg(interp, m, "purge", rePurgeFn);

    // re.error: the exception type that compile() raises on a bad pattern.
    if (interp.re_error_class == null) {
        // Subclass ValueError so existing raise sites (which raise
        // ValueError today) stay catchable, and so `except re.error`
        // catches them too.
        const value_err = interp.builtins.getStr("ValueError") orelse Value.none;
        var bases: []const *Class = &.{};
        var bases_buf: [1]*Class = undefined;
        if (value_err == .class) {
            bases_buf[0] = value_err.class;
            bases = bases_buf[0..1];
        }
        const err_cls = try Class.init(a, "error", bases, try Dict.init(a));
        interp.re_error_class = err_cls;
    }
    try m.attrs.setStr(a, "error", Value{ .class = interp.re_error_class.? });

    return m;
}

fn rePurgeFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
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

fn ensureClasses(interp: *Interp) !void {
    if (interp.re_pattern_class != null) return;
    const a = interp.allocator;
    {
        const d = try Dict.init(a);
        try methodReg(a, d, "match", patternMatch);
        try methodReg(a, d, "search", patternSearch);
        try methodReg(a, d, "fullmatch", patternFullmatch);
        try methodReg(a, d, "findall", patternFindall);
        try methodReg(a, d, "finditer", patternFinditer);
        try methodReg(a, d, "split", patternSplit);
        try methodReg(a, d, "sub", patternSub);
        try methodReg(a, d, "subn", patternSubn);
        const cls = try Class.init(a, "Pattern", &.{}, d);
        interp.re_pattern_class = cls;
    }
    {
        const d = try Dict.init(a);
        try methodReg(a, d, "group", matchGroup);
        try methodReg(a, d, "groups", matchGroups);
        try methodReg(a, d, "groupdict", matchGroupdict);
        try methodReg(a, d, "span", matchSpan);
        try methodReg(a, d, "start", matchStart);
        try methodReg(a, d, "end", matchEnd);
        try methodReg(a, d, "expand", matchExpand);
        const cls = try Class.init(a, "Match", &.{}, d);
        interp.re_match_class = cls;
    }
}

// --- Pattern object plumbing ---

fn flagsFromInt(v: i64) re.Flags {
    return .{
        .ignore_case = (v & FLAG_IGNORECASE) != 0,
        .multiline = (v & FLAG_MULTILINE) != 0,
        .dotall = (v & FLAG_DOTALL) != 0,
    };
}

fn intFromVal(v: Value) i64 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        else => 0,
    };
}

fn ptrToInt(p: anytype) i64 {
    return @intCast(@intFromPtr(p));
}

fn intToPattern(v: i64) *re.Pattern {
    return @ptrFromInt(@as(usize, @intCast(v)));
}

fn buildPatternInstance(interp: *Interp, pattern_src: []const u8, prog: *re.Pattern) !Value {
    try ensureClasses(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.re_pattern_class.?);
    const s = try Str.init(a, pattern_src);
    try inst.dict.setStr(a, "pattern", Value{ .str = s });
    try inst.dict.setStr(a, "_p", Value{ .small_int = ptrToInt(prog) });
    try inst.dict.setStr(a, "_flags", Value{ .small_int = @as(i64, @bitCast(@as(u64, @as(u8, @bitCast(prog.flags))))) });
    return Value{ .instance = inst };
}

fn getProg(inst: *Instance) *re.Pattern {
    const v = inst.dict.getStr("_p").?;
    return intToPattern(v.small_int);
}

fn buildMatchInstance(interp: *Interp, pat: *Instance, input: []const u8, m: re.Match) !Value {
    try ensureClasses(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.re_match_class.?);
    const s = try Str.init(a, input);
    try inst.dict.setStr(a, "string", Value{ .str = s });
    try inst.dict.setStr(a, "re", Value{ .instance = pat });

    // Encode spans as a tuple of tuples, NPOS -> -1.
    const t = try Tuple.init(a, m.spans.len);
    for (m.spans, 0..) |sp, i| {
        const tt = try Tuple.init(a, 2);
        tt.items[0] = if (sp.start == re.NPOS) Value{ .small_int = -1 } else Value{ .small_int = @intCast(sp.start) };
        tt.items[1] = if (sp.end == re.NPOS) Value{ .small_int = -1 } else Value{ .small_int = @intCast(sp.end) };
        t.items[i] = Value{ .tuple = tt };
    }
    try inst.dict.setStr(a, "_spans", Value{ .tuple = t });

    // lastindex: highest 1-based group id that participated.
    var last: i64 = -1;
    var gi: usize = 1;
    while (gi < m.spans.len) : (gi += 1) {
        if (m.spans[gi].start != re.NPOS) last = @intCast(gi);
    }
    try inst.dict.setStr(a, "lastindex", if (last < 0) Value.none else Value{ .small_int = last });
    // lastgroup: name of the highest-numbered participating named group.
    const prog = getProg(pat);
    var last_name: Value = Value.none;
    if (last > 0 and @as(usize, @intCast(last)) < prog.group_names.len) {
        const nm = prog.group_names[@intCast(last)];
        if (nm.len > 0) {
            const ns = try Str.init(a, nm);
            last_name = Value{ .str = ns };
        }
    }
    try inst.dict.setStr(a, "lastgroup", last_name);
    return Value{ .instance = inst };
}

fn matchSpansOf(inst: *Instance) *Tuple {
    return inst.dict.getStr("_spans").?.tuple;
}

fn matchStringOf(inst: *Instance) []const u8 {
    return inst.dict.getStr("string").?.str.bytes;
}

fn matchPatternOf(inst: *Instance) *Instance {
    return inst.dict.getStr("re").?.instance;
}

// --- helpers for parsing kwargs ---

const ParsedArgs = struct {
    pattern_src: []const u8,
    string: []const u8,
    flags: i64 = 0,
    repl_or_count: ?Value = null,
    repl: ?Value = null,
    count: i64 = 0,
};

fn argString(v: Value) ![]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

// --- module-level functions ---

fn compileFromArgs(interp: *Interp, pattern_v: Value, flags: i64) !Value {
    const a = interp.allocator;
    const raw = try argString(pattern_v);
    const stripped: []const u8 = if ((flags & FLAG_VERBOSE) != 0)
        try stripVerbose(a, raw)
    else
        raw;
    const prog = re.compile(a, stripped, flagsFromInt(flags)) catch |err| switch (err) {
        error.BadPattern, error.UnsupportedRegex => {
            // re.error: instantiate directly so the class identity matches.
            if (interp.re_error_class) |cls| {
                const inst = try Instance.init(a, cls);
                const t = try Tuple.init(a, 1);
                t.items[0] = Value{ .str = try Str.init(a, "invalid regex pattern") };
                try inst.dict.setStr(a, "args", Value{ .tuple = t });
                interp.current_exc = Value{ .instance = inst };
                return error.PyException;
            }
            try interp.raisePy("ValueError", "invalid regex pattern");
            return error.PyException;
        },
        else => return err,
    };
    return try buildPatternInstance(interp, raw, prog);
}

/// VERBOSE flag (re.X) strips: ASCII whitespace outside character
/// classes, and `#` comments through end-of-line. Backslash escapes
/// keep the next character (so `\ ` survives as a literal space).
fn stripVerbose(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    var in_class = false;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\\') {
            try out.append(a, c);
            if (i + 1 < raw.len) {
                try out.append(a, raw[i + 1]);
                i += 1;
            }
            continue;
        }
        if (in_class) {
            try out.append(a, c);
            if (c == ']') in_class = false;
            continue;
        }
        if (c == '[') {
            try out.append(a, c);
            in_class = true;
            continue;
        }
        if (c == '#') {
            while (i < raw.len and raw[i] != '\n') i += 1;
            continue;
        }
        switch (c) {
            ' ', '\t', '\n', '\r', 11, 12 => continue,
            else => try out.append(a, c),
        }
    }
    return try out.toOwnedSlice(a);
}

fn reCompileFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const flags: i64 = if (args.len >= 2) intFromVal(args[1]) else 0;
    return try compileFromArgs(interp, args[0], flags);
}

fn reCompileKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var flags: i64 = if (args.len >= 2) intFromVal(args[1]) else 0;
    for (kw_names, kw_values) |n, v| {
        if (std.mem.eql(u8, n.str.bytes, "flags")) flags = intFromVal(v);
    }
    return try compileFromArgs(interp, args[0], flags);
}

fn reMatchFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const flags: i64 = if (args.len >= 3) intFromVal(args[2]) else 0;
    const pat = try compileFromArgs(interp, args[0], flags);
    return try doSingle(interp, pat, args[1], .anchored);
}

fn reMatchKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var flags: i64 = if (args.len >= 3) intFromVal(args[2]) else 0;
    for (kw_names, kw_values) |n, v| {
        if (std.mem.eql(u8, n.str.bytes, "flags")) flags = intFromVal(v);
    }
    const pat = try compileFromArgs(interp, args[0], flags);
    return try doSingle(interp, pat, args[1], .anchored);
}

fn reSearchFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const flags: i64 = if (args.len >= 3) intFromVal(args[2]) else 0;
    const pat = try compileFromArgs(interp, args[0], flags);
    return try doSingle(interp, pat, args[1], .search);
}

fn reSearchKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var flags: i64 = if (args.len >= 3) intFromVal(args[2]) else 0;
    for (kw_names, kw_values) |n, v| {
        if (std.mem.eql(u8, n.str.bytes, "flags")) flags = intFromVal(v);
    }
    const pat = try compileFromArgs(interp, args[0], flags);
    return try doSingle(interp, pat, args[1], .search);
}

fn reFullmatchFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const flags: i64 = if (args.len >= 3) intFromVal(args[2]) else 0;
    const pat = try compileFromArgs(interp, args[0], flags);
    return try doSingle(interp, pat, args[1], .fullmatch);
}

fn reFullmatchKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var flags: i64 = if (args.len >= 3) intFromVal(args[2]) else 0;
    for (kw_names, kw_values) |n, v| {
        if (std.mem.eql(u8, n.str.bytes, "flags")) flags = intFromVal(v);
    }
    const pat = try compileFromArgs(interp, args[0], flags);
    return try doSingle(interp, pat, args[1], .fullmatch);
}

fn reFindallFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const flags: i64 = if (args.len >= 3) intFromVal(args[2]) else 0;
    const pat = try compileFromArgs(interp, args[0], flags);
    return try doFindall(interp, pat, args[1]);
}

fn reFindallKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var flags: i64 = if (args.len >= 3) intFromVal(args[2]) else 0;
    for (kw_names, kw_values) |n, v| {
        if (std.mem.eql(u8, n.str.bytes, "flags")) flags = intFromVal(v);
    }
    const pat = try compileFromArgs(interp, args[0], flags);
    return try doFindall(interp, pat, args[1]);
}

fn reFinditerFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const flags: i64 = if (args.len >= 3) intFromVal(args[2]) else 0;
    const pat = try compileFromArgs(interp, args[0], flags);
    return try doFinditer(interp, pat, args[1]);
}

fn reFinditerKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var flags: i64 = if (args.len >= 3) intFromVal(args[2]) else 0;
    for (kw_names, kw_values) |n, v| {
        if (std.mem.eql(u8, n.str.bytes, "flags")) flags = intFromVal(v);
    }
    const pat = try compileFromArgs(interp, args[0], flags);
    return try doFinditer(interp, pat, args[1]);
}

fn reSplitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const max_split: i64 = if (args.len >= 3) intFromVal(args[2]) else 0;
    const flags: i64 = if (args.len >= 4) intFromVal(args[3]) else 0;
    const pat = try compileFromArgs(interp, args[0], flags);
    return try doSplit(interp, pat, args[1], max_split);
}

fn reSplitKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var max_split: i64 = if (args.len >= 3) intFromVal(args[2]) else 0;
    var flags: i64 = if (args.len >= 4) intFromVal(args[3]) else 0;
    for (kw_names, kw_values) |n, v| {
        const nm = n.str.bytes;
        if (std.mem.eql(u8, nm, "maxsplit")) max_split = intFromVal(v);
        if (std.mem.eql(u8, nm, "flags")) flags = intFromVal(v);
    }
    const pat = try compileFromArgs(interp, args[0], flags);
    return try doSplit(interp, pat, args[1], max_split);
}

fn reSubFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const count: i64 = if (args.len >= 4) intFromVal(args[3]) else 0;
    const flags: i64 = if (args.len >= 5) intFromVal(args[4]) else 0;
    const pat = try compileFromArgs(interp, args[0], flags);
    const r = try doSub(interp, pat, args[1], args[2], count);
    return r.result;
}

fn reSubKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var count: i64 = if (args.len >= 4) intFromVal(args[3]) else 0;
    var flags: i64 = if (args.len >= 5) intFromVal(args[4]) else 0;
    for (kw_names, kw_values) |n, v| {
        const nm = n.str.bytes;
        if (std.mem.eql(u8, nm, "count")) count = intFromVal(v);
        if (std.mem.eql(u8, nm, "flags")) flags = intFromVal(v);
    }
    const pat = try compileFromArgs(interp, args[0], flags);
    const r = try doSub(interp, pat, args[1], args[2], count);
    return r.result;
}

fn reSubnFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const count: i64 = if (args.len >= 4) intFromVal(args[3]) else 0;
    const flags: i64 = if (args.len >= 5) intFromVal(args[4]) else 0;
    const pat = try compileFromArgs(interp, args[0], flags);
    const r = try doSub(interp, pat, args[1], args[2], count);
    const t = try Tuple.init(interp.allocator, 2);
    t.items[0] = r.result;
    t.items[1] = Value{ .small_int = r.count };
    return Value{ .tuple = t };
}

fn reSubnKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var count: i64 = if (args.len >= 4) intFromVal(args[3]) else 0;
    var flags: i64 = if (args.len >= 5) intFromVal(args[4]) else 0;
    for (kw_names, kw_values) |n, v| {
        const nm = n.str.bytes;
        if (std.mem.eql(u8, nm, "count")) count = intFromVal(v);
        if (std.mem.eql(u8, nm, "flags")) flags = intFromVal(v);
    }
    const pat = try compileFromArgs(interp, args[0], flags);
    const r = try doSub(interp, pat, args[1], args[2], count);
    const t = try Tuple.init(interp.allocator, 2);
    t.items[0] = r.result;
    t.items[1] = Value{ .small_int = r.count };
    return Value{ .tuple = t };
}

fn reEscapeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const src = try argString(args[0]);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for (src) |c| {
        if (isSpecial(c)) try out.append(a, '\\');
        try out.append(a, c);
    }
    const s = try Str.init(a, out.items);
    return Value{ .str = s };
}

fn isSpecial(c: u8) bool {
    return switch (c) {
        '(', ')', '[', ']', '{', '}', '?', '*', '+', '-', '|', '^', '$', '\\', '.', '&', '~', '#', ' ', '\t', '\n', '\r', 0x0B, 0x0C => true,
        else => false,
    };
}

// --- Pattern method shims (instance is args[0]) ---

fn patternInstance(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

fn patternMatch(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try patternInstance(args);
    return try doSingle(interp, Value{ .instance = inst }, args[1], .anchored);
}

fn patternSearch(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try patternInstance(args);
    return try doSingle(interp, Value{ .instance = inst }, args[1], .search);
}

fn patternFullmatch(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try patternInstance(args);
    return try doSingle(interp, Value{ .instance = inst }, args[1], .fullmatch);
}

fn patternFindall(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try patternInstance(args);
    return try doFindall(interp, Value{ .instance = inst }, args[1]);
}

fn patternFinditer(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try patternInstance(args);
    return try doFinditer(interp, Value{ .instance = inst }, args[1]);
}

fn patternSplit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try patternInstance(args);
    const max_split: i64 = if (args.len >= 3) intFromVal(args[2]) else 0;
    return try doSplit(interp, Value{ .instance = inst }, args[1], max_split);
}

fn patternSub(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try patternInstance(args);
    const count: i64 = if (args.len >= 4) intFromVal(args[3]) else 0;
    const r = try doSub(interp, Value{ .instance = inst }, args[1], args[2], count);
    return r.result;
}

fn patternSubn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try patternInstance(args);
    const count: i64 = if (args.len >= 4) intFromVal(args[3]) else 0;
    const r = try doSub(interp, Value{ .instance = inst }, args[1], args[2], count);
    const t = try Tuple.init(interp.allocator, 2);
    t.items[0] = r.result;
    t.items[1] = Value{ .small_int = r.count };
    return Value{ .tuple = t };
}

// --- Match method shims ---

fn matchInstance(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

fn resolveGroupIndex(pat: *Instance, key: Value) ?usize {
    return switch (key) {
        .small_int => |i| if (i < 0) null else @intCast(i),
        .str => |s| blk: {
            const prog = getProg(pat);
            for (prog.group_names, 0..) |gn, idx| {
                if (gn.len > 0 and std.mem.eql(u8, gn, s.bytes)) break :blk idx;
            }
            break :blk null;
        },
        else => null,
    };
}

fn spanAt(spans: *Tuple, idx: usize) ?struct { s: i64, e: i64 } {
    if (idx >= spans.items.len) return null;
    const tt = spans.items[idx].tuple;
    const s = tt.items[0].small_int;
    const e = tt.items[1].small_int;
    return .{ .s = s, .e = e };
}

fn matchGroup(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try matchInstance(args);
    const spans = matchSpansOf(inst);
    const input = matchStringOf(inst);
    const pat = matchPatternOf(inst);

    if (args.len == 1) {
        const sp = spanAt(spans, 0).?;
        const s = try Str.init(a, input[@intCast(sp.s)..@intCast(sp.e)]);
        return Value{ .str = s };
    }
    if (args.len == 2) {
        const idx = resolveGroupIndex(pat, args[1]) orelse {
            try interp.raisePy("IndexError", "no such group");
            return error.PyException;
        };
        const sp = spanAt(spans, idx) orelse {
            try interp.raisePy("IndexError", "no such group");
            return error.PyException;
        };
        if (sp.s < 0) return Value.none;
        const s = try Str.init(a, input[@intCast(sp.s)..@intCast(sp.e)]);
        return Value{ .str = s };
    }
    // multiple keys → tuple
    const t = try Tuple.init(a, args.len - 1);
    for (args[1..], 0..) |k, i| {
        const idx = resolveGroupIndex(pat, k).?;
        const sp = spanAt(spans, idx).?;
        if (sp.s < 0) {
            t.items[i] = Value.none;
        } else {
            const s = try Str.init(a, input[@intCast(sp.s)..@intCast(sp.e)]);
            t.items[i] = Value{ .str = s };
        }
    }
    return Value{ .tuple = t };
}

fn matchGroups(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try matchInstance(args);
    const spans = matchSpansOf(inst);
    const input = matchStringOf(inst);
    const default: Value = if (args.len >= 2) args[1] else Value.none;

    const n = spans.items.len;
    if (n == 0) return Value{ .tuple = try Tuple.init(a, 0) };
    const t = try Tuple.init(a, n - 1);
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const sp = spanAt(spans, i).?;
        if (sp.s < 0) {
            t.items[i - 1] = default;
        } else {
            const s = try Str.init(a, input[@intCast(sp.s)..@intCast(sp.e)]);
            t.items[i - 1] = Value{ .str = s };
        }
    }
    return Value{ .tuple = t };
}

fn matchGroupdict(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try matchInstance(args);
    const spans = matchSpansOf(inst);
    const input = matchStringOf(inst);
    const pat = matchPatternOf(inst);
    const prog = getProg(pat);
    const default: Value = if (args.len >= 2) args[1] else Value.none;

    const d = try Dict.init(a);
    for (prog.group_names, 0..) |gn, idx| {
        if (gn.len == 0) continue;
        const sp = spanAt(spans, idx).?;
        const v: Value = if (sp.s < 0) default else blk: {
            const s = try Str.init(a, input[@intCast(sp.s)..@intCast(sp.e)]);
            break :blk Value{ .str = s };
        };
        try d.setStr(a, gn, v);
    }
    return Value{ .dict = d };
}

fn matchSpan(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try matchInstance(args);
    const spans = matchSpansOf(inst);
    const idx: usize = if (args.len >= 2) blk: {
        const pat = matchPatternOf(inst);
        break :blk resolveGroupIndex(pat, args[1]).?;
    } else 0;
    const sp = spanAt(spans, idx).?;
    const t = try Tuple.init(a, 2);
    t.items[0] = Value{ .small_int = sp.s };
    t.items[1] = Value{ .small_int = sp.e };
    return Value{ .tuple = t };
}

fn matchStart(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const inst = try matchInstance(args);
    const spans = matchSpansOf(inst);
    const idx: usize = if (args.len >= 2) blk: {
        const pat = matchPatternOf(inst);
        break :blk resolveGroupIndex(pat, args[1]).?;
    } else 0;
    return Value{ .small_int = spanAt(spans, idx).?.s };
}

fn matchExpand(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try matchInstance(args);
    if (args.len < 2 or args[1] != .str) return error.TypeError;
    const tmpl_src = args[1].str.bytes;
    const spans = matchSpansOf(inst);
    const input = matchStringOf(inst);
    const pat = matchPatternOf(inst);
    const prog = getProg(pat);

    const sp_arr = try a.alloc(re.Span, spans.items.len);
    defer a.free(sp_arr);
    for (spans.items, 0..) |it, i| {
        const s = it.tuple.items[0].small_int;
        const e = it.tuple.items[1].small_int;
        sp_arr[i] = .{
            .start = if (s < 0) re.NPOS else @intCast(s),
            .end = if (e < 0) re.NPOS else @intCast(e),
        };
    }
    var tmpl = try re.replace_mod.parseTemplate(a, tmpl_src, prog);
    defer tmpl.deinit(a);
    const piece = try re.replace_mod.apply(a, tmpl, input, sp_arr);
    defer a.free(piece);
    const s = try Str.init(a, piece);
    return Value{ .str = s };
}

fn matchEnd(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const inst = try matchInstance(args);
    const spans = matchSpansOf(inst);
    const idx: usize = if (args.len >= 2) blk: {
        const pat = matchPatternOf(inst);
        break :blk resolveGroupIndex(pat, args[1]).?;
    } else 0;
    return Value{ .small_int = spanAt(spans, idx).?.e };
}

// --- core operations ---

const SingleMode = enum { anchored, search, fullmatch };

fn doSingle(interp: *Interp, pat_v: Value, input_v: Value, mode: SingleMode) !Value {
    const a = interp.allocator;
    const pat = pat_v.instance;
    const prog = getProg(pat);
    const input = try argString(input_v);
    const m_opt = switch (mode) {
        .anchored => try re.match(a, prog, input),
        .search => try re.search(a, prog, input, 0),
        .fullmatch => try re.fullmatch(a, prog, input),
    };
    if (m_opt) |m| {
        var mm = m;
        defer mm.deinit(a);
        return try buildMatchInstance(interp, pat, input, mm);
    }
    return Value.none;
}

fn doFindall(interp: *Interp, pat_v: Value, input_v: Value) !Value {
    const a = interp.allocator;
    const pat = pat_v.instance;
    const prog = getProg(pat);
    const input = try argString(input_v);
    const out = try List.init(a);
    var pos: usize = 0;
    while (pos <= input.len) {
        const m_opt = try re.search(a, prog, input, pos);
        if (m_opt == null) break;
        var m = m_opt.?;
        defer m.deinit(a);
        const item = try findallItem(a, prog, input, m.spans);
        try out.append(a, item);
        if (m.spans[0].end == m.spans[0].start) {
            pos = m.spans[0].end + 1;
        } else {
            pos = m.spans[0].end;
        }
    }
    return Value{ .list = out };
}

fn findallItem(a: std.mem.Allocator, prog: *re.Pattern, input: []const u8, spans: []const re.Span) !Value {
    if (prog.group_count == 0) {
        const sp = spans[0];
        const s = try Str.init(a, input[sp.start..sp.end]);
        return Value{ .str = s };
    }
    if (prog.group_count == 1) {
        const sp = spans[1];
        if (sp.start == re.NPOS) {
            const s = try Str.init(a, "");
            return Value{ .str = s };
        }
        const s = try Str.init(a, input[sp.start..sp.end]);
        return Value{ .str = s };
    }
    const t = try Tuple.init(a, prog.group_count);
    var i: usize = 1;
    while (i <= prog.group_count) : (i += 1) {
        const sp = spans[i];
        if (sp.start == re.NPOS) {
            const s = try Str.init(a, "");
            t.items[i - 1] = Value{ .str = s };
        } else {
            const s = try Str.init(a, input[sp.start..sp.end]);
            t.items[i - 1] = Value{ .str = s };
        }
    }
    return Value{ .tuple = t };
}

fn doFinditer(interp: *Interp, pat_v: Value, input_v: Value) !Value {
    const a = interp.allocator;
    const pat = pat_v.instance;
    const prog = getProg(pat);
    const input = try argString(input_v);
    const out = try List.init(a);
    var pos: usize = 0;
    while (pos <= input.len) {
        const m_opt = try re.search(a, prog, input, pos);
        if (m_opt == null) break;
        var m = m_opt.?;
        const minst = try buildMatchInstance(interp, pat, input, m);
        m.deinit(a);
        try out.append(a, minst);
        const ss = pat;
        _ = ss;
        // Advance.
        const last_match = out.items.items[out.items.items.len - 1].instance;
        const sp_t = matchSpansOf(last_match).items[0].tuple;
        const start = sp_t.items[0].small_int;
        const end = sp_t.items[1].small_int;
        if (end == start) pos = @intCast(end + 1) else pos = @intCast(end);
    }
    return Value{ .list = out };
}

fn doSplit(interp: *Interp, pat_v: Value, input_v: Value, max_split: i64) !Value {
    const a = interp.allocator;
    const pat = pat_v.instance;
    const prog = getProg(pat);
    const input = try argString(input_v);
    const out = try List.init(a);
    var pos: usize = 0;
    var splits: i64 = 0;
    while (pos <= input.len) {
        if (max_split > 0 and splits >= max_split) break;
        const m_opt = try re.search(a, prog, input, pos);
        if (m_opt == null) break;
        var m = m_opt.?;
        defer m.deinit(a);
        const ms = m.spans[0].start;
        const me = m.spans[0].end;
        if (ms == me) {
            // empty match: advance one char to avoid infinite loop
            if (pos >= input.len) break;
            pos += 1;
            continue;
        }
        const seg = try Str.init(a, input[pos..ms]);
        try out.append(a, Value{ .str = seg });
        // Include captured groups (Python: if groups in pattern, they
        // appear in the result list).
        var gi: u32 = 1;
        while (gi <= prog.group_count) : (gi += 1) {
            const sp = m.spans[gi];
            if (sp.start == re.NPOS) {
                try out.append(a, Value.none);
            } else {
                const gs = try Str.init(a, input[sp.start..sp.end]);
                try out.append(a, Value{ .str = gs });
            }
        }
        pos = me;
        splits += 1;
    }
    const tail = try Str.init(a, input[pos..]);
    try out.append(a, Value{ .str = tail });
    return Value{ .list = out };
}

const SubResult = struct { result: Value, count: i64 };

fn doSub(interp: *Interp, pat_v: Value, repl_v: Value, input_v: Value, max_count: i64) !SubResult {
    const a = interp.allocator;
    const pat = pat_v.instance;
    const prog = getProg(pat);
    const input = try argString(input_v);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    // Pre-parse replacement template if it's a string.
    var tmpl: ?re.replace_mod.Template = null;
    defer if (tmpl) |*t| t.deinit(a);
    const callable = (repl_v != .str);
    if (!callable) {
        tmpl = try re.replace_mod.parseTemplate(a, repl_v.str.bytes, prog);
    }

    var pos: usize = 0;
    var count: i64 = 0;
    while (pos <= input.len) {
        if (max_count > 0 and count >= max_count) break;
        const m_opt = try re.search(a, prog, input, pos);
        if (m_opt == null) break;
        var m = m_opt.?;
        defer m.deinit(a);
        const ms = m.spans[0].start;
        const me = m.spans[0].end;
        try out.appendSlice(a, input[pos..ms]);

        if (callable) {
            const minst = try buildMatchInstance(interp, pat, input, m);
            const r = try dispatch.invoke(interp, repl_v, &.{minst});
            if (r != .str) {
                try interp.typeError("re.sub callable must return str");
                return error.TypeError;
            }
            try out.appendSlice(a, r.str.bytes);
        } else {
            const piece = try re.replace_mod.apply(a, tmpl.?, input, m.spans);
            defer a.free(piece);
            try out.appendSlice(a, piece);
        }

        if (ms == me) {
            if (me < input.len) try out.append(a, input[me]);
            pos = me + 1;
        } else {
            pos = me;
        }
        count += 1;
    }
    if (pos < input.len) try out.appendSlice(a, input[pos..]);

    const s = try Str.init(a, out.items);
    return .{ .result = Value{ .str = s }, .count = count };
}
