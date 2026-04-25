//! Pinhole `difflib`: get_close_matches, SequenceMatcher.ratio,
//! ndiff, unified_diff. Just enough to satisfy the fixture probes.

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
    try reg(interp, m, "SequenceMatcher", seqMatcherFn);
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

// Ratcliff-Obershelp matching count.
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
    // Skip entirely when sequences are identical.
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

// --- SequenceMatcher: a callable that returns a small instance
// holding `_a`/`_b`, exposing a `ratio` method ---

fn ensureClass(interp: *Interp) !void {
    if (interp.difflib_seqmatch_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "ratio", smRatio);
    try methodReg(a, d, "quick_ratio", smRatio);
    try methodReg(a, d, "real_quick_ratio", smRatio);
    try methodReg(a, d, "set_seq1", smSetSeq1);
    try methodReg(a, d, "set_seq2", smSetSeq2);
    try methodReg(a, d, "set_seqs", smSetSeqs);
    interp.difflib_seqmatch_class = try Class.init(a, "SequenceMatcher", &.{}, d);
}

fn seqMatcherFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    try ensureClass(interp);
    const inst = try Instance.init(a, interp.difflib_seqmatch_class.?);
    if (args.len >= 2 and args[1] == .str) {
        const s = try Str.init(a, args[1].str.bytes);
        try inst.dict.setStr(a, "a", Value{ .str = s });
    }
    if (args.len >= 3 and args[2] == .str) {
        const s = try Str.init(a, args[2].str.bytes);
        try inst.dict.setStr(a, "b", Value{ .str = s });
    }
    return Value{ .instance = inst };
}

fn smSetSeq1(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const s = try Str.init(a, args[1].str.bytes);
    try args[0].instance.dict.setStr(a, "a", Value{ .str = s });
    return Value.none;
}

fn smSetSeq2(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const s = try Str.init(a, args[1].str.bytes);
    try args[0].instance.dict.setStr(a, "b", Value{ .str = s });
    return Value.none;
}

fn smSetSeqs(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3 or args[0] != .instance or args[1] != .str or args[2] != .str) return error.TypeError;
    const s1 = try Str.init(a, args[1].str.bytes);
    const s2 = try Str.init(a, args[2].str.bytes);
    try args[0].instance.dict.setStr(a, "a", Value{ .str = s1 });
    try args[0].instance.dict.setStr(a, "b", Value{ .str = s2 });
    return Value.none;
}

fn smRatio(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const a_v = inst.dict.getStr("a") orelse return Value{ .float = 0.0 };
    const b_v = inst.dict.getStr("b") orelse return Value{ .float = 0.0 };
    if (a_v != .str or b_v != .str) return Value{ .float = 0.0 };
    return Value{ .float = ratio(a_v.str.bytes, b_v.str.bytes) };
}
