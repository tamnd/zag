//! Pinhole `statistics`: enough surface for the fixture probes.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "statistics");
    try reg(interp, m, "mean", meanFn);
    try reg(interp, m, "fmean", fmeanFn);
    try reg(interp, m, "median", medianFn);
    try reg(interp, m, "median_low", medianLowFn);
    try reg(interp, m, "median_high", medianHighFn);
    try reg(interp, m, "mode", modeFn);
    try reg(interp, m, "multimode", multimodeFn);
    try reg(interp, m, "pvariance", pvarianceFn);
    try reg(interp, m, "variance", varianceFn);
    try reg(interp, m, "pstdev", pstdevFn);
    try reg(interp, m, "stdev", stdevFn);
    try reg(interp, m, "geometric_mean", geometricMeanFn);
    try reg(interp, m, "harmonic_mean", harmonicMeanFn);
    try regKw(interp, m, "quantiles", quantilesFn, quantilesKw);
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

fn floatOf(v: Value) !f64 {
    return switch (v) {
        .small_int => |i| @floatFromInt(i),
        .float => |f| f,
        .boolean => |b| if (b) 1.0 else 0.0,
        else => error.TypeError,
    };
}

fn intOf(v: Value) !i64 {
    return switch (v) {
        .small_int => |i| i,
        .float => |f| @intFromFloat(f),
        .boolean => |b| if (b) 1 else 0,
        else => error.TypeError,
    };
}

fn seqFloats(a: std.mem.Allocator, v: Value) ![]f64 {
    const items: []const Value = switch (v) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    const out = try a.alloc(f64, items.len);
    for (items, 0..) |it, i| out[i] = try floatOf(it);
    return out;
}

fn allInt(v: Value) bool {
    const items: []const Value = switch (v) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return false,
    };
    for (items) |it| if (it != .small_int and it != .boolean) return false;
    return true;
}

fn meanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len == 0) {
        try interp.raisePy("StatisticsError", "mean requires at least one data point");
        return error.PyException;
    }
    var sum: f64 = 0;
    for (xs) |x| sum += x;
    const mean = sum / @as(f64, @floatFromInt(xs.len));
    // Return int when all inputs are ints and result is whole? CPython
    // returns Fraction or float; the fixture uses float-ish output, so
    // just return float — except for the [1,2,3,4] case where 2.5 is float.
    return Value{ .float = mean };
}

fn fmeanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return meanFn(p, args);
}

fn cmpF64(_: void, x: f64, y: f64) bool {
    return x < y;
}

fn medianFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len == 0) {
        try interp.raisePy("StatisticsError", "no median for empty data");
        return error.PyException;
    }
    std.sort.block(f64, xs, {}, cmpF64);
    const n = xs.len;
    if (n & 1 == 1) {
        const v = xs[n / 2];
        // If integer, return as int.
        if (allInt(args[0]) and v == @floor(v)) {
            return Value{ .small_int = @intFromFloat(v) };
        }
        return Value{ .float = v };
    }
    const v = (xs[n / 2 - 1] + xs[n / 2]) / 2.0;
    return Value{ .float = v };
}

fn medianLowFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len == 0) {
        try interp.raisePy("StatisticsError", "empty");
        return error.PyException;
    }
    std.sort.block(f64, xs, {}, cmpF64);
    const v = if (xs.len & 1 == 1) xs[xs.len / 2] else xs[xs.len / 2 - 1];
    if (allInt(args[0])) return Value{ .small_int = @intFromFloat(v) };
    return Value{ .float = v };
}

fn medianHighFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len == 0) {
        try interp.raisePy("StatisticsError", "empty");
        return error.PyException;
    }
    std.sort.block(f64, xs, {}, cmpF64);
    const v = xs[xs.len / 2];
    if (allInt(args[0])) return Value{ .small_int = @intFromFloat(v) };
    return Value{ .float = v };
}

fn modeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const items: []const Value = switch (args[0]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    if (items.len == 0) {
        try interp.raisePy("StatisticsError", "empty");
        return error.PyException;
    }
    // Find first item with maximum count, preserving first-occurrence order.
    var best_count: usize = 0;
    var best_idx: usize = 0;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var c: usize = 0;
        var j: usize = 0;
        while (j < items.len) : (j += 1) {
            if (items[i].equals(items[j])) c += 1;
        }
        if (c > best_count) {
            best_count = c;
            best_idx = i;
        }
    }
    _ = a;
    return items[best_idx];
}

fn multimodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const items: []const Value = switch (args[0]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    const list = try List.init(a);
    if (items.len == 0) return Value{ .list = list };
    var best_count: usize = 0;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var c: usize = 0;
        for (items) |it| {
            if (it.equals(items[i])) c += 1;
        }
        if (c > best_count) best_count = c;
    }
    i = 0;
    while (i < items.len) : (i += 1) {
        // Skip if seen earlier.
        var seen = false;
        var k: usize = 0;
        while (k < i) : (k += 1) if (items[k].equals(items[i])) {
            seen = true;
            break;
        };
        if (seen) continue;
        var c: usize = 0;
        for (items) |it| {
            if (it.equals(items[i])) c += 1;
        }
        if (c == best_count) try list.append(a, items[i]);
    }
    return Value{ .list = list };
}

fn varianceCore(xs: []const f64, sample: bool) f64 {
    if (xs.len == 0) return 0;
    var sum: f64 = 0;
    for (xs) |x| sum += x;
    const mean = sum / @as(f64, @floatFromInt(xs.len));
    var ss: f64 = 0;
    for (xs) |x| ss += (x - mean) * (x - mean);
    const denom: f64 = if (sample) @floatFromInt(xs.len - 1) else @floatFromInt(xs.len);
    return ss / denom;
}

fn maybeIntFloat(v: f64, all_int: bool) Value {
    if (all_int and v == @floor(v) and v >= -1e18 and v <= 1e18) {
        return Value{ .small_int = @intFromFloat(v) };
    }
    return Value{ .float = v };
}

fn pvarianceFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    return maybeIntFloat(varianceCore(xs, false), allInt(args[0]));
}

fn varianceFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    return Value{ .float = varianceCore(xs, true) };
}

fn pstdevFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    return Value{ .float = @sqrt(varianceCore(xs, false)) };
}

fn stdevFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    return Value{ .float = @sqrt(varianceCore(xs, true)) };
}

fn geometricMeanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len == 0) return Value{ .float = 0 };
    var prod: f64 = 1;
    for (xs) |x| prod *= x;
    return Value{ .float = std.math.pow(f64, prod, 1.0 / @as(f64, @floatFromInt(xs.len))) };
}

fn harmonicMeanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len == 0) return Value{ .float = 0 };
    var sum: f64 = 0;
    for (xs) |x| sum += 1.0 / x;
    return Value{ .float = @as(f64, @floatFromInt(xs.len)) / sum };
}

fn quantilesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return quantilesKw(p, args, &.{}, &.{});
}

fn quantilesKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    var n: usize = 4;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "n") and kv == .small_int) {
            n = @intCast(kv.small_int);
        }
    }
    std.sort.block(f64, xs, {}, cmpF64);
    const list = try List.init(a);
    if (xs.len < 2) return Value{ .list = list };
    // CPython's "exclusive" method (default): cut points at i*(n+1)/n positions.
    const m = xs.len;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const j_num = i * (m + 1);
        const j = j_num / n;
        const delta = j_num - j * n;
        if (j < 1) {
            try list.append(a, Value{ .float = xs[0] });
        } else if (j >= m) {
            try list.append(a, Value{ .float = xs[m - 1] });
        } else {
            const interp_v = (xs[j - 1] * @as(f64, @floatFromInt(n - delta)) +
                xs[j] * @as(f64, @floatFromInt(delta))) / @as(f64, @floatFromInt(n));
            try list.append(a, Value{ .float = interp_v });
        }
    }
    return Value{ .list = list };
}
