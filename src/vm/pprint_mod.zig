//! Pinhole `pprint`: only the surface the fixture probes.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;
const Dict = @import("../object/dict.zig").Dict;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "pprint");
    try regKw(interp, m, "pformat", pformatFn, pformatKw);
    try regKw(interp, m, "pprint", pprintFn, pprintKw);
    try reg(interp, m, "saferepr", saferepFn);
    try reg(interp, m, "isreadable", isreadableFn);
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

fn writeSingle(w: *std.Io.Writer, v: Value, scratch: std.mem.Allocator) anyerror!void {
    switch (v) {
        .dict => |d| {
            const pairs = d.pairs.items;
            const idx = try scratch.alloc(usize, pairs.len);
            defer scratch.free(idx);
            for (idx, 0..) |*ii, i| ii.* = i;
            std.sort.block(usize, idx, pairs, lessKey);
            try w.writeAll("{");
            for (idx, 0..) |k, i| {
                if (i > 0) try w.writeAll(", ");
                try writeSingle(w, pairs[k].key, scratch);
                try w.writeAll(": ");
                try writeSingle(w, pairs[k].value, scratch);
            }
            try w.writeAll("}");
        },
        .list => |l| {
            try w.writeAll("[");
            for (l.items.items, 0..) |it, i| {
                if (i > 0) try w.writeAll(", ");
                try writeSingle(w, it, scratch);
            }
            try w.writeAll("]");
        },
        .tuple => |t| {
            try w.writeAll("(");
            for (t.items, 0..) |it, i| {
                if (i > 0) try w.writeAll(", ");
                try writeSingle(w, it, scratch);
            }
            if (t.items.len == 1) try w.writeAll(",");
            try w.writeAll(")");
        },
        else => try v.writeRepr(w),
    }
}

fn lessKey(pairs: []const Dict.Pair, a: usize, b: usize) bool {
    const pa = pairs[a].key;
    const pb = pairs[b].key;
    if (pa == .str and pb == .str) {
        return std.mem.order(u8, pa.str.bytes, pb.str.bytes) == .lt;
    }
    if (pa == .small_int and pb == .small_int) return pa.small_int < pb.small_int;
    return false;
}

fn formatTopLevel(a: std.mem.Allocator, v: Value, width: usize) ![]u8 {
    var sw = std.Io.Writer.Allocating.init(a);
    defer sw.deinit();
    try writeSingle(&sw.writer, v, a);
    const single = sw.written();
    if (single.len <= width) return a.dupe(u8, single);

    switch (v) {
        .list => |l| {
            var ow = std.Io.Writer.Allocating.init(a);
            defer ow.deinit();
            try ow.writer.writeAll("[");
            for (l.items.items, 0..) |it, i| {
                if (i > 0) try ow.writer.writeAll(",\n ");
                try writeSingle(&ow.writer, it, a);
            }
            try ow.writer.writeAll("]");
            return a.dupe(u8, ow.written());
        },
        else => return a.dupe(u8, single),
    }
}

fn extractWidth(kw_names: []const Value, kw_values: []const Value) usize {
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "width") and kv == .small_int) {
            return @intCast(kv.small_int);
        }
    }
    return 80;
}

fn pformatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return pformatKw(p, args, &.{}, &.{});
}

fn pformatKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const width = extractWidth(kw_names, kw_values);
    const out = try formatTopLevel(a, args[0], width);
    defer a.free(out);
    const s = try Str.init(a, out);
    return Value{ .str = s };
}

fn pprintFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return pprintKw(p, args, &.{}, &.{});
}

fn pprintKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const width = extractWidth(kw_names, kw_values);
    const out = try formatTopLevel(a, args[0], width);
    defer a.free(out);
    try interp.stdout.writeAll(out);
    try interp.stdout.writeAll("\n");
    return Value.none;
}

fn saferepFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    var w = std.Io.Writer.Allocating.init(a);
    defer w.deinit();
    try args[0].writeRepr(&w.writer);
    const s = try Str.init(a, w.written());
    return Value{ .str = s };
}

fn isreadableFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    return Value{ .boolean = true };
}
