//! Pinhole `difflib`: get_close_matches, SequenceMatcher (str+list),
//! ndiff, unified_diff, context_diff, restore, Differ. Just enough
//! to satisfy the fixture probes.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "difflib");
    try regKw(interp, m, "get_close_matches", getCloseMatchesFn, getCloseMatchesKw);
    try reg(interp, m, "ndiff", ndiffFn);
    try regKw(interp, m, "unified_diff", unifiedDiffFn, unifiedDiffKw);
    try regKw(interp, m, "context_diff", contextDiffFn, contextDiffKw);
    try reg(interp, m, "SequenceMatcher", seqMatcherFn);
    try reg(interp, m, "Differ", differCtorFn);
    try reg(interp, m, "IS_LINE_JUNK", isLineJunkFn);
    try reg(interp, m, "IS_CHARACTER_JUNK", isCharJunkFn);
    try reg(interp, m, "restore", restoreFn);
    return m;
}

fn isLineJunkFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .str) return Value{ .boolean = false };
    const s = args[0].str.bytes;
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    if (i < s.len and s[i] == '#') {
        i += 1;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    }
    if (i < s.len and s[i] == '\n') i += 1;
    return Value{ .boolean = i == s.len };
}

fn isCharJunkFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .str) return Value{ .boolean = false };
    const s = args[0].str.bytes;
    if (s.len == 0) return Value{ .boolean = false };
    return Value{ .boolean = s[0] == ' ' or s[0] == '\t' };
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

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn argStr(v: Value) ![]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

fn seqOfStr(a: std.mem.Allocator, v: Value) ![][]const u8 {
    const items: []const Value = switch (v) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    const out = try a.alloc([]const u8, items.len);
    for (items, 0..) |it, i| {
        if (it != .str) return error.TypeError;
        out[i] = it.str.bytes;
    }
    return out;
}

// --- token sequences (works for str and list-of-str) ---

fn toTokens(a: std.mem.Allocator, v: Value) ![][]const u8 {
    switch (v) {
        .str => |s| {
            const out = try a.alloc([]const u8, s.bytes.len);
            var i: usize = 0;
            while (i < s.bytes.len) : (i += 1) out[i] = s.bytes[i .. i + 1];
            return out;
        },
        .list => |l| {
            const out = try a.alloc([]const u8, l.items.items.len);
            for (l.items.items, 0..) |it, i| {
                if (it != .str) return error.TypeError;
                out[i] = it.str.bytes;
            }
            return out;
        },
        .tuple => |t| {
            const out = try a.alloc([]const u8, t.items.len);
            for (t.items, 0..) |it, i| {
                if (it != .str) return error.TypeError;
                out[i] = it.str.bytes;
            }
            return out;
        },
        else => return error.TypeError,
    }
}

fn matchCountTokens(a: [][]const u8, b: [][]const u8) usize {
    if (a.len == 0 or b.len == 0) return 0;
    var best_i: usize = 0;
    var best_j: usize = 0;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        var j: usize = 0;
        while (j < b.len) : (j += 1) {
            var k: usize = 0;
            while (i + k < a.len and j + k < b.len and std.mem.eql(u8, a[i + k], b[j + k])) : (k += 1) {}
            if (k > best_len) {
                best_len = k;
                best_i = i;
                best_j = j;
            }
        }
    }
    if (best_len == 0) return 0;
    return best_len +
        matchCountTokens(a[0..best_i], b[0..best_j]) +
        matchCountTokens(a[best_i + best_len ..], b[best_j + best_len ..]);
}

fn ratioTokens(a: [][]const u8, b: [][]const u8) f64 {
    const total = a.len + b.len;
    if (total == 0) return 1.0;
    const m: f64 = @floatFromInt(matchCountTokens(a, b));
    const t: f64 = @floatFromInt(total);
    return 2.0 * m / t;
}

// Byte-level helpers retained for get_close_matches.
fn matchCount(a: []const u8, b: []const u8) usize {
    if (a.len == 0 or b.len == 0) return 0;
    var best_i: usize = 0;
    var best_j: usize = 0;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        var j: usize = 0;
        while (j < b.len) : (j += 1) {
            var k: usize = 0;
            while (i + k < a.len and j + k < b.len and a[i + k] == b[j + k]) : (k += 1) {}
            if (k > best_len) {
                best_len = k;
                best_i = i;
                best_j = j;
            }
        }
    }
    if (best_len == 0) return 0;
    return best_len +
        matchCount(a[0..best_i], b[0..best_j]) +
        matchCount(a[best_i + best_len ..], b[best_j + best_len ..]);
}

fn ratio(a: []const u8, b: []const u8) f64 {
    const total = a.len + b.len;
    if (total == 0) return 1.0;
    const m: f64 = @floatFromInt(matchCount(a, b));
    const t: f64 = @floatFromInt(total);
    return 2.0 * m / t;
}

fn getCloseMatchesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return getCloseMatchesKw(p, args, &.{}, &.{});
}

fn getCloseMatchesKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const word = try argStr(args[0]);
    const possibilities: []const Value = switch (args[1]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    var n: usize = 3;
    var cutoff: f64 = 0.6;
    if (args.len >= 3 and args[2] == .small_int) n = @intCast(args[2].small_int);
    if (args.len >= 4) cutoff = floatOf(args[3]);
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "n") and kv == .small_int) {
            n = @intCast(kv.small_int);
        } else if (std.mem.eql(u8, kn.str.bytes, "cutoff")) {
            cutoff = floatOf(kv);
        }
    }
    const Item = struct { ratio: f64, str: []const u8 };
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(a);
    for (possibilities) |v| {
        if (v != .str) continue;
        const r = ratio(word, v.str.bytes);
        if (r >= cutoff) try items.append(a, .{ .ratio = r, .str = v.str.bytes });
    }
    std.sort.block(Item, items.items, {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            if (x.ratio != y.ratio) return x.ratio > y.ratio;
            return std.mem.order(u8, x.str, y.str) == .gt;
        }
    }.lt);
    const list = try List.init(a);
    var taken: usize = 0;
    for (items.items) |it| {
        if (taken >= n) break;
        const s = try Str.init(a, it.str);
        try list.append(a, Value{ .str = s });
        taken += 1;
    }
    return Value{ .list = list };
}

fn floatOf(v: Value) f64 {
    return switch (v) {
        .float => |f| f,
        .small_int => |i| @floatFromInt(i),
        else => 0,
    };
}

// --- ndiff ---

fn ndiffFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const aa = try seqOfStr(a, args[0]);
    defer a.free(aa);
    const bb = try seqOfStr(a, args[1]);
    defer a.free(bb);
    const lines = try diffLines(a, aa, bb, "  ", "- ", "+ ");
    defer a.free(lines);
    const list = try List.init(a);
    for (lines) |line| {
        const s = try Str.init(a, line);
        a.free(line);
        try list.append(a, Value{ .str = s });
    }
    return Value{ .list = list };
}

fn diffLines(a: std.mem.Allocator, aa: [][]const u8, bb: [][]const u8, eq_pfx: []const u8, del_pfx: []const u8, add_pfx: []const u8) ![][]u8 {
    const m = aa.len;
    const n = bb.len;
    const dp = try a.alloc(usize, (m + 1) * (n + 1));
    defer a.free(dp);
    @memset(dp, 0);
    var i: usize = 0;
    while (i < m) : (i += 1) {
        var j: usize = 0;
        while (j < n) : (j += 1) {
            if (std.mem.eql(u8, aa[i], bb[j])) {
                dp[(i + 1) * (n + 1) + (j + 1)] = dp[i * (n + 1) + j] + 1;
            } else {
                dp[(i + 1) * (n + 1) + (j + 1)] = @max(
                    dp[i * (n + 1) + (j + 1)],
                    dp[(i + 1) * (n + 1) + j],
                );
            }
        }
    }
    var stack: std.ArrayList([]u8) = .empty;
    defer stack.deinit(a);
    i = m;
    var j: usize = n;
    while (i > 0 or j > 0) {
        if (i > 0 and j > 0 and std.mem.eql(u8, aa[i - 1], bb[j - 1])) {
            try stack.append(a, try std.fmt.allocPrint(a, "{s}{s}", .{ eq_pfx, aa[i - 1] }));
            i -= 1;
            j -= 1;
        } else if (j > 0 and (i == 0 or dp[i * (n + 1) + (j - 1)] >= dp[(i - 1) * (n + 1) + j])) {
            try stack.append(a, try std.fmt.allocPrint(a, "{s}{s}", .{ add_pfx, bb[j - 1] }));
            j -= 1;
        } else {
            try stack.append(a, try std.fmt.allocPrint(a, "{s}{s}", .{ del_pfx, aa[i - 1] }));
            i -= 1;
        }
    }
    const out = try a.alloc([]u8, stack.items.len);
    var k: usize = 0;
    while (k < stack.items.len) : (k += 1) {
        out[k] = stack.items[stack.items.len - 1 - k];
    }
    return out;
}

// --- unified_diff ---

fn unifiedDiffFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return unifiedDiffKw(p, args, &.{}, &.{});
}

fn unifiedDiffKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const aa = try seqOfStr(a, args[0]);
    defer a.free(aa);
    const bb = try seqOfStr(a, args[1]);
    defer a.free(bb);
    var fromfile: []const u8 = "";
    var tofile: []const u8 = "";
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str or kv != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "fromfile")) fromfile = kv.str.bytes
        else if (std.mem.eql(u8, kn.str.bytes, "tofile")) tofile = kv.str.bytes;
    }
    const list = try List.init(a);
    if (aa.len == bb.len) {
        var same = true;
        for (aa, bb) |x, y| if (!std.mem.eql(u8, x, y)) {
            same = false;
            break;
        };
        if (same) return Value{ .list = list };
    }
    {
        const h = try std.fmt.allocPrint(a, "--- {s}\n", .{fromfile});
        const s = try Str.init(a, h);
        a.free(h);
        try list.append(a, Value{ .str = s });
    }
    {
        const h = try std.fmt.allocPrint(a, "+++ {s}\n", .{tofile});
        const s = try Str.init(a, h);
        a.free(h);
        try list.append(a, Value{ .str = s });
    }
    {
        const h = try std.fmt.allocPrint(a, "@@ -1,{d} +1,{d} @@\n", .{ aa.len, bb.len });
        const s = try Str.init(a, h);
        a.free(h);
        try list.append(a, Value{ .str = s });
    }
    const lines = try diffLines(a, aa, bb, " ", "-", "+");
    defer a.free(lines);
    for (lines) |line| {
        const s = try Str.init(a, line);
        a.free(line);
        try list.append(a, Value{ .str = s });
    }
    return Value{ .list = list };
}

// --- context_diff ---

fn contextDiffFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return contextDiffKw(p, args, &.{}, &.{});
}

fn contextDiffKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const aa = try seqOfStr(a, args[0]);
    defer a.free(aa);
    const bb = try seqOfStr(a, args[1]);
    defer a.free(bb);
    var fromfile: []const u8 = "";
    var tofile: []const u8 = "";
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str or kv != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "fromfile")) fromfile = kv.str.bytes
        else if (std.mem.eql(u8, kn.str.bytes, "tofile")) tofile = kv.str.bytes;
    }
    const list = try List.init(a);
    if (aa.len == bb.len) {
        var same = true;
        for (aa, bb) |x, y| if (!std.mem.eql(u8, x, y)) {
            same = false;
            break;
        };
        if (same) return Value{ .list = list };
    }

    // Compute opcodes on full sequences (no context grouping; one hunk).
    const opcodes = try computeOpcodesForLines(a, aa, bb);
    defer a.free(opcodes);

    {
        const h = try std.fmt.allocPrint(a, "*** {s}\n", .{fromfile});
        const s = try Str.init(a, h);
        a.free(h);
        try list.append(a, Value{ .str = s });
    }
    {
        const h = try std.fmt.allocPrint(a, "--- {s}\n", .{tofile});
        const s = try Str.init(a, h);
        a.free(h);
        try list.append(a, Value{ .str = s });
    }

    {
        const s = try Str.init(a, "***************\n");
        try list.append(a, Value{ .str = s });
    }

    // a-side header.
    const a_range = try formatContextRange(a, 0, aa.len);
    defer a.free(a_range);
    {
        const h = try std.fmt.allocPrint(a, "*** {s} ****\n", .{a_range});
        const s = try Str.init(a, h);
        a.free(h);
        try list.append(a, Value{ .str = s });
    }

    // a-side body: walk opcodes, emit each a-line with prefix.
    var has_replace_or_delete = false;
    for (opcodes) |op| {
        if (op.tag == .replace or op.tag == .delete) {
            has_replace_or_delete = true;
            break;
        }
    }
    if (has_replace_or_delete) {
        for (opcodes) |op| {
            const pfx: []const u8 = switch (op.tag) {
                .equal => "  ",
                .replace => "! ",
                .delete => "- ",
                .insert => continue,
            };
            var k: usize = op.i1;
            while (k < op.i2) : (k += 1) {
                const h = try std.fmt.allocPrint(a, "{s}{s}", .{ pfx, aa[k] });
                const s = try Str.init(a, h);
                a.free(h);
                try list.append(a, Value{ .str = s });
            }
        }
    }

    // b-side header.
    const b_range = try formatContextRange(a, 0, bb.len);
    defer a.free(b_range);
    {
        const h = try std.fmt.allocPrint(a, "--- {s} ----\n", .{b_range});
        const s = try Str.init(a, h);
        a.free(h);
        try list.append(a, Value{ .str = s });
    }

    var has_replace_or_insert = false;
    for (opcodes) |op| {
        if (op.tag == .replace or op.tag == .insert) {
            has_replace_or_insert = true;
            break;
        }
    }
    if (has_replace_or_insert) {
        for (opcodes) |op| {
            const pfx: []const u8 = switch (op.tag) {
                .equal => "  ",
                .replace => "! ",
                .insert => "+ ",
                .delete => continue,
            };
            var k: usize = op.j1;
            while (k < op.j2) : (k += 1) {
                const h = try std.fmt.allocPrint(a, "{s}{s}", .{ pfx, bb[k] });
                const s = try Str.init(a, h);
                a.free(h);
                try list.append(a, Value{ .str = s });
            }
        }
    }

    return Value{ .list = list };
}

fn formatContextRange(a: std.mem.Allocator, start: usize, stop: usize) ![]u8 {
    var beginning = start + 1;
    const length = stop - start;
    if (length == 0) beginning -= 1;
    if (length <= 1) return std.fmt.allocPrint(a, "{d}", .{beginning});
    return std.fmt.allocPrint(a, "{d},{d}", .{ beginning, beginning + length - 1 });
}

// --- restore ---

fn restoreFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const items: []const Value = switch (args[0]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    if (args[1] != .small_int) return error.TypeError;
    const which = args[1].small_int;
    const tag: u8 = if (which == 1) '-' else if (which == 2) '+' else return error.ValueError;

    const list = try List.init(a);
    for (items) |v| {
        if (v != .str) continue;
        const line = v.str.bytes;
        if (line.len < 2) continue;
        const c = line[0];
        if (c == tag or c == ' ') {
            const s = try Str.init(a, line[2..]);
            try list.append(a, Value{ .str = s });
        }
    }
    return Value{ .list = list };
}

// --- SequenceMatcher ---

const Tag = enum { equal, replace, delete, insert };
const Opcode = struct { tag: Tag, i1: usize, i2: usize, j1: usize, j2: usize };
const MatchTriple = struct { a: usize, b: usize, size: usize };

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;
    if (interp.difflib_match_class == null) {
        const md = try Dict.init(a);
        interp.difflib_match_class = try Class.init(a, "Match", &.{}, md);
    }
    if (interp.difflib_seqmatch_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "ratio", smRatio);
        try methodReg(a, d, "quick_ratio", smRatio);
        try methodReg(a, d, "real_quick_ratio", smRatio);
        try methodReg(a, d, "set_seq1", smSetSeq1);
        try methodReg(a, d, "set_seq2", smSetSeq2);
        try methodReg(a, d, "set_seqs", smSetSeqs);
        try methodReg(a, d, "find_longest_match", smFindLongestMatch);
        try methodReg(a, d, "get_matching_blocks", smGetMatchingBlocks);
        try methodReg(a, d, "get_opcodes", smGetOpcodes);
        interp.difflib_seqmatch_class = try Class.init(a, "SequenceMatcher", &.{}, d);
    }
    if (interp.difflib_differ_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "compare", differCompare);
        interp.difflib_differ_class = try Class.init(a, "Differ", &.{}, d);
    }
}

fn newMatch(a: std.mem.Allocator, cls: *Class, ai: usize, bj: usize, size: usize) !Value {
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "a", Value{ .small_int = @intCast(ai) });
    try inst.dict.setStr(a, "b", Value{ .small_int = @intCast(bj) });
    try inst.dict.setStr(a, "size", Value{ .small_int = @intCast(size) });
    return Value{ .instance = inst };
}

fn seqMatcherFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    try ensureClasses(interp);
    const inst = try Instance.init(a, interp.difflib_seqmatch_class.?);
    if (args.len >= 2) try inst.dict.setStr(a, "a", args[1]);
    if (args.len >= 3) try inst.dict.setStr(a, "b", args[2]);
    return Value{ .instance = inst };
}

fn smSetSeq1(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    try args[0].instance.dict.setStr(a, "a", args[1]);
    return Value.none;
}

fn smSetSeq2(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    try args[0].instance.dict.setStr(a, "b", args[1]);
    return Value.none;
}

fn smSetSeqs(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3 or args[0] != .instance) return error.TypeError;
    try args[0].instance.dict.setStr(a, "a", args[1]);
    try args[0].instance.dict.setStr(a, "b", args[2]);
    return Value.none;
}

fn instanceTokens(a: std.mem.Allocator, inst: *Instance) ![2][][]const u8 {
    const a_v = inst.dict.getStr("a") orelse return error.TypeError;
    const b_v = inst.dict.getStr("b") orelse return error.TypeError;
    const ta = try toTokens(a, a_v);
    errdefer a.free(ta);
    const tb = try toTokens(a, b_v);
    return .{ ta, tb };
}

fn smRatio(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const ts = instanceTokens(a, args[0].instance) catch return Value{ .float = 0.0 };
    defer a.free(ts[0]);
    defer a.free(ts[1]);
    return Value{ .float = ratioTokens(ts[0], ts[1]) };
}

fn smFindLongestMatch(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    try ensureClasses(interp);
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const ts = try instanceTokens(a, args[0].instance);
    defer a.free(ts[0]);
    defer a.free(ts[1]);
    const lm = findLongestMatch(ts[0], ts[1], 0, ts[0].len, 0, ts[1].len);
    return newMatch(a, interp.difflib_match_class.?, lm.a, lm.b, lm.size);
}

fn smGetMatchingBlocks(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    try ensureClasses(interp);
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const ts = try instanceTokens(a, args[0].instance);
    defer a.free(ts[0]);
    defer a.free(ts[1]);
    const blocks = try computeMatchingBlocks(a, ts[0], ts[1]);
    defer a.free(blocks);
    const list = try List.init(a);
    for (blocks) |bl| {
        const v = try newMatch(a, interp.difflib_match_class.?, bl.a, bl.b, bl.size);
        try list.append(a, v);
    }
    return Value{ .list = list };
}

fn smGetOpcodes(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    try ensureClasses(interp);
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const ts = try instanceTokens(a, args[0].instance);
    defer a.free(ts[0]);
    defer a.free(ts[1]);
    const ops = try computeOpcodes(a, ts[0], ts[1]);
    defer a.free(ops);
    const list = try List.init(a);
    for (ops) |op| {
        const t = try Tuple.init(a, 5);
        const tag_str = try Str.init(a, switch (op.tag) {
            .equal => "equal",
            .replace => "replace",
            .delete => "delete",
            .insert => "insert",
        });
        t.items[0] = Value{ .str = tag_str };
        t.items[1] = Value{ .small_int = @intCast(op.i1) };
        t.items[2] = Value{ .small_int = @intCast(op.i2) };
        t.items[3] = Value{ .small_int = @intCast(op.j1) };
        t.items[4] = Value{ .small_int = @intCast(op.j2) };
        try list.append(a, Value{ .tuple = t });
    }
    return Value{ .list = list };
}

fn findLongestMatch(a: [][]const u8, b: [][]const u8, alo: usize, ahi: usize, blo: usize, bhi: usize) MatchTriple {
    var best_i: usize = alo;
    var best_j: usize = blo;
    var best_k: usize = 0;
    var i: usize = alo;
    while (i < ahi) : (i += 1) {
        var j: usize = blo;
        while (j < bhi) : (j += 1) {
            var k: usize = 0;
            while (i + k < ahi and j + k < bhi and std.mem.eql(u8, a[i + k], b[j + k])) : (k += 1) {}
            if (k > best_k) {
                best_i = i;
                best_j = j;
                best_k = k;
            }
        }
    }
    return .{ .a = best_i, .b = best_j, .size = best_k };
}

fn matchingBlocksRecurse(a: std.mem.Allocator, aa: [][]const u8, bb: [][]const u8, alo: usize, ahi: usize, blo: usize, bhi: usize, out: *std.ArrayList(MatchTriple)) !void {
    const m = findLongestMatch(aa, bb, alo, ahi, blo, bhi);
    if (m.size == 0) return;
    if (alo < m.a and blo < m.b) {
        try matchingBlocksRecurse(a, aa, bb, alo, m.a, blo, m.b, out);
    }
    try out.append(a, m);
    if (m.a + m.size < ahi and m.b + m.size < bhi) {
        try matchingBlocksRecurse(a, aa, bb, m.a + m.size, ahi, m.b + m.size, bhi, out);
    }
}

fn computeMatchingBlocks(a: std.mem.Allocator, aa: [][]const u8, bb: [][]const u8) ![]MatchTriple {
    var raw: std.ArrayList(MatchTriple) = .empty;
    defer raw.deinit(a);
    try matchingBlocksRecurse(a, aa, bb, 0, aa.len, 0, bb.len, &raw);

    // Collapse adjacent matches.
    var collapsed: std.ArrayList(MatchTriple) = .empty;
    defer collapsed.deinit(a);
    var cur_i: usize = 0;
    var cur_j: usize = 0;
    var cur_k: usize = 0;
    for (raw.items) |m| {
        if (cur_k != 0 and cur_i + cur_k == m.a and cur_j + cur_k == m.b) {
            cur_k += m.size;
        } else {
            if (cur_k != 0) try collapsed.append(a, .{ .a = cur_i, .b = cur_j, .size = cur_k });
            cur_i = m.a;
            cur_j = m.b;
            cur_k = m.size;
        }
    }
    if (cur_k != 0) try collapsed.append(a, .{ .a = cur_i, .b = cur_j, .size = cur_k });
    try collapsed.append(a, .{ .a = aa.len, .b = bb.len, .size = 0 });

    const out = try a.alloc(MatchTriple, collapsed.items.len);
    @memcpy(out, collapsed.items);
    return out;
}

fn computeOpcodes(a: std.mem.Allocator, aa: [][]const u8, bb: [][]const u8) ![]Opcode {
    const blocks = try computeMatchingBlocks(a, aa, bb);
    defer a.free(blocks);
    var out: std.ArrayList(Opcode) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    var j: usize = 0;
    for (blocks) |bl| {
        const ai = bl.a;
        const bj = bl.b;
        const sz = bl.size;
        var tag: ?Tag = null;
        if (i < ai and j < bj) tag = .replace
        else if (i < ai) tag = .delete
        else if (j < bj) tag = .insert;
        if (tag) |t| try out.append(a, .{ .tag = t, .i1 = i, .i2 = ai, .j1 = j, .j2 = bj });
        i = ai + sz;
        j = bj + sz;
        if (sz != 0) try out.append(a, .{ .tag = .equal, .i1 = ai, .i2 = ai + sz, .j1 = bj, .j2 = bj + sz });
    }
    const r = try a.alloc(Opcode, out.items.len);
    @memcpy(r, out.items);
    return r;
}

fn computeOpcodesForLines(a: std.mem.Allocator, aa: [][]const u8, bb: [][]const u8) ![]Opcode {
    return computeOpcodes(a, aa, bb);
}

// --- Differ ---

fn differCtorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    try ensureClasses(interp);
    const inst = try Instance.init(a, interp.difflib_differ_class.?);
    return Value{ .instance = inst };
}

fn differCompare(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3) return error.TypeError;
    const aa = try seqOfStr(a, args[1]);
    defer a.free(aa);
    const bb = try seqOfStr(a, args[2]);
    defer a.free(bb);
    const lines = try diffLines(a, aa, bb, "  ", "- ", "+ ");
    defer a.free(lines);
    const list = try List.init(a);
    for (lines) |line| {
        const s = try Str.init(a, line);
        a.free(line);
        try list.append(a, Value{ .str = s });
    }
    return Value{ .list = list };
}
