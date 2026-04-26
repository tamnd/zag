//! `statistics` module: full surface for the fixture (mean/median
//! family, geometric/harmonic/quantiles, dispersion, covariance/
//! correlation/linear_regression, kde/kde_random, plus the NormalDist
//! class with arithmetic, samples(), from_samples(), overlap()).
//!
//! StatisticsError lives both on the module and in builtins so that
//! `raisePy("StatisticsError", ...)` finds it and `from statistics
//! import StatisticsError` returns the same class object.

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
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Str = @import("../object/string.zig").Str;
const Function = @import("../object/function.zig").Function;
const Interp = @import("interp.zig").Interp;
const builtins_mod = @import("builtins.zig");

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);
    const m = try Module.init(a, "statistics");
    try reg(interp, m, "mean", meanFn);
    try regKw(interp, m, "fmean", fmeanFn, fmeanKw);
    try reg(interp, m, "median", medianFn);
    try reg(interp, m, "median_low", medianLowFn);
    try reg(interp, m, "median_high", medianHighFn);
    try regKw(interp, m, "median_grouped", medianGroupedFn, medianGroupedKw);
    try reg(interp, m, "mode", modeFn);
    try reg(interp, m, "multimode", multimodeFn);
    try regKw(interp, m, "pvariance", pvarianceFn, pvarianceKw);
    try regKw(interp, m, "variance", varianceFn, varianceKw);
    try reg(interp, m, "pstdev", pstdevFn);
    try reg(interp, m, "stdev", stdevFn);
    try reg(interp, m, "geometric_mean", geometricMeanFn);
    try regKw(interp, m, "harmonic_mean", harmonicMeanFn, harmonicMeanKw);
    try regKw(interp, m, "quantiles", quantilesFn, quantilesKw);
    try reg(interp, m, "covariance", covarianceFn);
    try regKw(interp, m, "correlation", correlationFn, correlationKw);
    try regKw(interp, m, "linear_regression", linearRegressionFn, linearRegressionKw);
    try regKw(interp, m, "kde", kdeFn, kdeKw);
    try regKw(interp, m, "kde_random", kdeRandomFn, kdeRandomKw);
    try m.attrs.setStr(a, "StatisticsError", Value{ .class = interp.statistics_error_class.? });
    try m.attrs.setStr(a, "NormalDist", Value{ .class = interp.statistics_normal_dist_class.? });
    return m;
}

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;
    if (interp.statistics_error_class == null) {
        const ed = try Dict.init(a);
        const exc = interp.builtins.getStr("Exception") orelse Value.none;
        const parents: []const *Class = if (exc == .class) &[_]*Class{exc.class} else &[_]*Class{};
        const cls = try Class.init(a, "StatisticsError", parents, ed);
        interp.statistics_error_class = cls;
        try interp.builtins.setStr(a, "StatisticsError", Value{ .class = cls });
    }
    if (interp.statistics_normal_dist_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "__init__", ndInit);
        try methodReg(a, d, "__repr__", ndRepr);
        try methodReg(a, d, "__add__", ndAdd);
        try methodReg(a, d, "__radd__", ndAdd);
        try methodReg(a, d, "__sub__", ndSub);
        try methodReg(a, d, "__rsub__", ndRsub);
        try methodReg(a, d, "__mul__", ndMul);
        try methodReg(a, d, "__rmul__", ndMul);
        try methodReg(a, d, "__truediv__", ndDiv);
        try methodReg(a, d, "__eq__", ndEq);
        try methodReg(a, d, "pdf", ndPdf);
        try methodReg(a, d, "cdf", ndCdf);
        try methodReg(a, d, "inv_cdf", ndInvCdf);
        try methodReg(a, d, "zscore", ndZscore);
        try methodRegKw(a, d, "quantiles", ndQuantilesFn, ndQuantilesKw);
        try methodRegKw(a, d, "samples", ndSamplesFn, ndSamplesKw);
        try methodReg(a, d, "overlap", ndOverlap);
        const cls = try Class.init(a, "NormalDist", &.{}, d);
        // classmethod from_samples
        const desc = try @import("../object/descriptor.zig").Descriptor.init(
            a,
            .classmethod,
            try classmethodValue(a, "from_samples", ndFromSamples),
        );
        try d.setStr(a, "from_samples", Value{ .descriptor = desc });
        interp.statistics_normal_dist_class = cls;
    }
}

fn classmethodValue(a: std.mem.Allocator, name: []const u8, func: BuiltinFnPtr) !Value {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    return Value{ .builtin_fn = f };
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

fn methodReg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn methodRegKw(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn raiseStat(interp: *Interp, msg: []const u8) !void {
    const cls = interp.statistics_error_class.?;
    return interp.raiseDecimal(cls, msg);
}

fn floatOf(v: Value) !f64 {
    return switch (v) {
        .small_int => |i| @floatFromInt(i),
        .float => |f| f,
        .boolean => |b| if (b) 1.0 else 0.0,
        else => error.TypeError,
    };
}

fn seqFloats(a: std.mem.Allocator, v: Value) ![]f64 {
    switch (v) {
        .list => |l| {
            const out = try a.alloc(f64, l.items.items.len);
            for (l.items.items, 0..) |it, i| out[i] = try floatOf(it);
            return out;
        },
        .tuple => |t| {
            const out = try a.alloc(f64, t.items.len);
            for (t.items, 0..) |it, i| out[i] = try floatOf(it);
            return out;
        },
        .iter => |it| {
            var buf: std.ArrayList(f64) = .empty;
            errdefer buf.deinit(a);
            while (it.next()) |x| try buf.append(a, try floatOf(x));
            return buf.toOwnedSlice(a);
        },
        else => return error.TypeError,
    }
}

fn allInt(v: Value) bool {
    const items: []const Value = switch (v) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        .iter => return true,
        else => return false,
    };
    for (items) |it| {
        if (it != .small_int and it != .boolean) return false;
    }
    return true;
}

fn maybeIntFloat(v: f64, all_int: bool) Value {
    if (all_int and v == @floor(v) and v >= -1e18 and v <= 1e18) {
        return Value{ .small_int = @intFromFloat(v) };
    }
    return Value{ .float = v };
}

fn cmpF64(_: void, x: f64, y: f64) bool {
    return x < y;
}

// ===== mean family =====

fn meanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const all_int = allInt(args[0]);
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len == 0) {
        try raiseStat(interp, "mean requires at least one data point");
        return error.PyException;
    }
    var sum: f64 = 0;
    for (xs) |x| sum += x;
    return maybeIntFloat(sum / @as(f64, @floatFromInt(xs.len)), all_int);
}

fn fmeanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return fmeanCore(p, args, null);
}

fn fmeanKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    var weights: ?Value = null;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "weights")) weights = kv;
    }
    return fmeanCore(p, args, weights);
}

fn fmeanCore(p: *anyopaque, args: []const Value, weights: ?Value) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len == 0) {
        try raiseStat(interp, "fmean requires at least one data point");
        return error.PyException;
    }
    if (weights) |w| {
        const ws = try seqFloats(a, w);
        defer a.free(ws);
        if (ws.len != xs.len) {
            try raiseStat(interp, "data and weights must be the same length");
            return error.PyException;
        }
        var num: f64 = 0;
        var den: f64 = 0;
        for (xs, ws) |x, ww| {
            num += x * ww;
            den += ww;
        }
        if (den == 0) {
            try raiseStat(interp, "sum of weights must be non-zero");
            return error.PyException;
        }
        return Value{ .float = num / den };
    }
    var sum: f64 = 0;
    for (xs) |x| sum += x;
    return Value{ .float = sum / @as(f64, @floatFromInt(xs.len)) };
}

// ===== median family =====

fn medianFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len == 0) {
        try raiseStat(interp, "no median for empty data");
        return error.PyException;
    }
    std.sort.block(f64, xs, {}, cmpF64);
    const n = xs.len;
    if (n & 1 == 1) {
        const v = xs[n / 2];
        if (allInt(args[0]) and v == @floor(v)) return Value{ .small_int = @intFromFloat(v) };
        return Value{ .float = v };
    }
    return Value{ .float = (xs[n / 2 - 1] + xs[n / 2]) / 2.0 };
}

fn medianLowFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len == 0) {
        try raiseStat(interp, "empty");
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
        try raiseStat(interp, "empty");
        return error.PyException;
    }
    std.sort.block(f64, xs, {}, cmpF64);
    const v = xs[xs.len / 2];
    if (allInt(args[0])) return Value{ .small_int = @intFromFloat(v) };
    return Value{ .float = v };
}

fn medianGroupedFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return medianGroupedCore(p, args, 1.0);
}

fn medianGroupedKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    var interval: f64 = 1.0;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "interval")) interval = floatOf(kv) catch 1.0;
    }
    return medianGroupedCore(p, args, interval);
}

fn medianGroupedCore(p: *anyopaque, args: []const Value, interval: f64) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len == 0) {
        try raiseStat(interp, "no median for empty data");
        return error.PyException;
    }
    std.sort.block(f64, xs, {}, cmpF64);
    const n = xs.len;
    const x = xs[n / 2];
    // Count items equal to and less than x.
    var l_count: usize = 0;
    var same: usize = 0;
    for (xs) |v| {
        if (v < x) l_count += 1;
        if (v == x) same += 1;
    }
    if (same == 0) return Value{ .float = x };
    const cf: f64 = @floatFromInt(l_count);
    const f: f64 = @floatFromInt(same);
    const half: f64 = @as(f64, @floatFromInt(n)) / 2.0;
    const lower = x - interval / 2.0;
    return Value{ .float = lower + interval * (half - cf) / f };
}

// ===== mode =====

fn modeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const items: []const Value = switch (args[0]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    if (items.len == 0) {
        try raiseStat(interp, "no mode for empty data");
        return error.PyException;
    }
    var best_count: usize = 0;
    var best_idx: usize = 0;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var c: usize = 0;
        var j: usize = 0;
        while (j < items.len) : (j += 1) if (items[i].equals(items[j])) {
            c += 1;
        };
        if (c > best_count) {
            best_count = c;
            best_idx = i;
        }
    }
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
        for (items) |it| if (it.equals(items[i])) {
            c += 1;
        };
        if (c > best_count) best_count = c;
    }
    i = 0;
    while (i < items.len) : (i += 1) {
        var seen = false;
        var k: usize = 0;
        while (k < i) : (k += 1) if (items[k].equals(items[i])) {
            seen = true;
            break;
        };
        if (seen) continue;
        var c: usize = 0;
        for (items) |it| if (it.equals(items[i])) {
            c += 1;
        };
        if (c == best_count) try list.append(a, items[i]);
    }
    return Value{ .list = list };
}

// ===== variance / stdev =====

fn varianceCore(xs: []const f64, sample: bool, mu_opt: ?f64) f64 {
    if (xs.len == 0) return 0;
    const mu: f64 = if (mu_opt) |m| m else blk: {
        var sum: f64 = 0;
        for (xs) |x| sum += x;
        break :blk sum / @as(f64, @floatFromInt(xs.len));
    };
    var ss: f64 = 0;
    for (xs) |x| ss += (x - mu) * (x - mu);
    const denom: f64 = if (sample) @floatFromInt(xs.len - 1) else @floatFromInt(xs.len);
    return ss / denom;
}

fn pvarianceFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return pvarianceCore(p, args, null);
}

fn pvarianceKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    var mu: ?f64 = null;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "mu")) mu = floatOf(kv) catch null;
    }
    return pvarianceCore(p, args, mu);
}

fn pvarianceCore(p: *anyopaque, args: []const Value, mu: ?f64) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    return maybeIntFloat(varianceCore(xs, false, mu), allInt(args[0]) and mu == null);
}

fn varianceFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return varianceCoreFn(p, args, null);
}

fn varianceKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    var mu: ?f64 = null;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "xbar")) mu = floatOf(kv) catch null;
    }
    return varianceCoreFn(p, args, mu);
}

fn varianceCoreFn(p: *anyopaque, args: []const Value, mu: ?f64) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len < 2) {
        try raiseStat(interp, "variance requires at least two data points");
        return error.PyException;
    }
    return maybeIntFloat(varianceCore(xs, true, mu), allInt(args[0]) and mu == null);
}

fn pstdevFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    return Value{ .float = @sqrt(varianceCore(xs, false, null)) };
}

fn stdevFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len < 2) {
        try raiseStat(interp, "stdev requires at least two data points");
        return error.PyException;
    }
    return Value{ .float = @sqrt(varianceCore(xs, true, null)) };
}

// ===== geometric / harmonic =====

fn geometricMeanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len == 0) {
        try raiseStat(interp, "geometric_mean requires at least one data point");
        return error.PyException;
    }
    for (xs) |x| if (x <= 0) {
        try raiseStat(interp, "geometric mean requires positive values");
        return error.PyException;
    };
    var log_sum: f64 = 0;
    for (xs) |x| log_sum += @log(x);
    return Value{ .float = @exp(log_sum / @as(f64, @floatFromInt(xs.len))) };
}

fn harmonicMeanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return harmonicMeanCore(p, args, null);
}

fn harmonicMeanKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    var weights: ?Value = null;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "weights")) weights = kv;
    }
    return harmonicMeanCore(p, args, weights);
}

fn harmonicMeanCore(p: *anyopaque, args: []const Value, weights: ?Value) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    if (xs.len == 0) {
        try raiseStat(interp, "harmonic_mean requires at least one data point");
        return error.PyException;
    }
    for (xs) |x| if (x < 0) {
        try raiseStat(interp, "harmonic mean does not support negative values");
        return error.PyException;
    };
    for (xs) |x| if (x == 0) return Value{ .small_int = 0 };

    if (weights) |w| {
        const ws = try seqFloats(a, w);
        defer a.free(ws);
        if (ws.len != xs.len) {
            try raiseStat(interp, "data and weights must be the same length");
            return error.PyException;
        }
        var num: f64 = 0;
        var den: f64 = 0;
        for (xs, ws) |x, ww| {
            num += ww;
            den += ww / x;
        }
        if (den == 0) return Value{ .small_int = 0 };
        return Value{ .float = num / den };
    }
    var sum: f64 = 0;
    for (xs) |x| sum += 1.0 / x;
    return Value{ .float = @as(f64, @floatFromInt(xs.len)) / sum };
}

// ===== quantiles =====

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
    var inclusive = false;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "n") and kv == .small_int) {
            n = @intCast(kv.small_int);
        } else if (std.mem.eql(u8, kn.str.bytes, "method") and kv == .str) {
            inclusive = std.mem.eql(u8, kv.str.bytes, "inclusive");
        }
    }
    std.sort.block(f64, xs, {}, cmpF64);
    const list = try List.init(a);
    if (xs.len < 2) return Value{ .list = list };
    const m = xs.len;
    if (inclusive) {
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const num = i * (m - 1);
            const j = num / n;
            const delta = num - j * n;
            const v = (xs[j] * @as(f64, @floatFromInt(n - delta)) +
                xs[j + 1] * @as(f64, @floatFromInt(delta))) / @as(f64, @floatFromInt(n));
            try list.append(a, Value{ .float = v });
        }
    } else {
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
                const v = (xs[j - 1] * @as(f64, @floatFromInt(n - delta)) +
                    xs[j] * @as(f64, @floatFromInt(delta))) / @as(f64, @floatFromInt(n));
                try list.append(a, Value{ .float = v });
            }
        }
    }
    return Value{ .list = list };
}

// ===== covariance / correlation / linear_regression =====

fn covarianceFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    const ys = try seqFloats(a, args[1]);
    defer a.free(ys);
    if (xs.len != ys.len) {
        try raiseStat(interp, "covariance requires equal-length sequences");
        return error.PyException;
    }
    if (xs.len < 2) {
        try raiseStat(interp, "covariance requires at least two data points");
        return error.PyException;
    }
    var sx: f64 = 0;
    var sy: f64 = 0;
    for (xs, ys) |x, y| {
        sx += x;
        sy += y;
    }
    const mx = sx / @as(f64, @floatFromInt(xs.len));
    const my = sy / @as(f64, @floatFromInt(ys.len));
    var sxy: f64 = 0;
    for (xs, ys) |x, y| sxy += (x - mx) * (y - my);
    return Value{ .float = sxy / @as(f64, @floatFromInt(xs.len - 1)) };
}

fn rankIntoFloats(a: std.mem.Allocator, xs: []const f64) ![]f64 {
    const n = xs.len;
    const idx = try a.alloc(usize, n);
    defer a.free(idx);
    for (0..n) |i| idx[i] = i;
    const Ctx = struct { xs: []const f64 };
    const sorter = struct {
        fn lt(ctx: Ctx, i: usize, j: usize) bool {
            return ctx.xs[i] < ctx.xs[j];
        }
    }.lt;
    std.sort.block(usize, idx, Ctx{ .xs = xs }, sorter);
    const ranks = try a.alloc(f64, n);
    var i: usize = 0;
    while (i < n) {
        var j = i;
        while (j + 1 < n and xs[idx[j + 1]] == xs[idx[i]]) : (j += 1) {}
        const avg_rank = @as(f64, @floatFromInt(i + j + 2)) / 2.0;
        var k: usize = i;
        while (k <= j) : (k += 1) ranks[idx[k]] = avg_rank;
        i = j + 1;
    }
    return ranks;
}

fn correlationFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return correlationCore(p, args, false);
}

fn correlationKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    var ranked = false;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "method") and kv == .str) {
            ranked = std.mem.eql(u8, kv.str.bytes, "ranked");
        }
    }
    return correlationCore(p, args, ranked);
}

fn correlationCore(p: *anyopaque, args: []const Value, ranked: bool) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    const ys = try seqFloats(a, args[1]);
    defer a.free(ys);
    if (xs.len != ys.len) {
        try raiseStat(interp, "correlation requires equal-length sequences");
        return error.PyException;
    }
    if (xs.len < 2) {
        try raiseStat(interp, "correlation requires at least two data points");
        return error.PyException;
    }
    if (ranked) {
        const rx = try rankIntoFloats(a, xs);
        defer a.free(rx);
        const ry = try rankIntoFloats(a, ys);
        defer a.free(ry);
        @memcpy(xs, rx);
        @memcpy(ys, ry);
    }
    var sx: f64 = 0;
    var sy: f64 = 0;
    for (xs, ys) |x, y| {
        sx += x;
        sy += y;
    }
    const mx = sx / @as(f64, @floatFromInt(xs.len));
    const my = sy / @as(f64, @floatFromInt(ys.len));
    var sxy: f64 = 0;
    var sxx: f64 = 0;
    var syy: f64 = 0;
    for (xs, ys) |x, y| {
        sxy += (x - mx) * (y - my);
        sxx += (x - mx) * (x - mx);
        syy += (y - my) * (y - my);
    }
    if (sxx == 0 or syy == 0) {
        try raiseStat(interp, "at least one of the inputs is constant");
        return error.PyException;
    }
    return Value{ .float = sxy / @sqrt(sxx * syy) };
}

fn linearRegressionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return linearRegressionCore(p, args, false);
}

fn linearRegressionKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    var proportional = false;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "proportional")) {
            proportional = kv == .boolean and kv.boolean;
        }
    }
    return linearRegressionCore(p, args, proportional);
}

fn linearRegressionCore(p: *anyopaque, args: []const Value, proportional: bool) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const xs = try seqFloats(a, args[0]);
    defer a.free(xs);
    const ys = try seqFloats(a, args[1]);
    defer a.free(ys);
    if (xs.len != ys.len) {
        try raiseStat(interp, "linear_regression requires equal-length sequences");
        return error.PyException;
    }
    if (xs.len < 2) {
        try raiseStat(interp, "linear_regression requires at least two data points");
        return error.PyException;
    }
    var slope: f64 = 0;
    var intercept: f64 = 0;
    if (proportional) {
        var sxy: f64 = 0;
        var sxx: f64 = 0;
        for (xs, ys) |x, y| {
            sxy += x * y;
            sxx += x * x;
        }
        if (sxx == 0) {
            try raiseStat(interp, "x is constant");
            return error.PyException;
        }
        slope = sxy / sxx;
    } else {
        var sx: f64 = 0;
        var sy: f64 = 0;
        for (xs, ys) |x, y| {
            sx += x;
            sy += y;
        }
        const mx = sx / @as(f64, @floatFromInt(xs.len));
        const my = sy / @as(f64, @floatFromInt(ys.len));
        var sxx: f64 = 0;
        var sxy: f64 = 0;
        for (xs, ys) |x, y| {
            sxx += (x - mx) * (x - mx);
            sxy += (x - mx) * (y - my);
        }
        if (sxx == 0) {
            try raiseStat(interp, "x is constant");
            return error.PyException;
        }
        slope = sxy / sxx;
        intercept = my - slope * mx;
    }
    // Build a small ad-hoc instance with .slope and .intercept attrs.
    const dummy_d = try Dict.init(a);
    const cls = try Class.init(a, "LinearRegression", &.{}, dummy_d);
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "slope", Value{ .float = slope });
    try inst.dict.setStr(a, "intercept", Value{ .float = intercept });
    return Value{ .instance = inst };
}

// ===== kde =====
// kde() returns a callable Instance whose dict holds the data and
// kernel parameters. __call__ does the actual kernel evaluation; the
// fixture only checks that the return is a positive float and that
// cdf is monotonic, so we don't need byte-equal output.

fn kernelPdfStd(k: u8, t: f64) f64 {
    return switch (k) {
        1 => if (@abs(t) >= 1.0) 0.0 else (1.0 - @abs(t)),
        2 => if (@abs(t) >= 1.0) 0.0 else 0.5,
        3 => if (@abs(t) >= 1.0) 0.0 else 0.75 * (1.0 - t * t),
        else => @exp(-0.5 * t * t) / @sqrt(2.0 * std.math.pi),
    };
}

fn kernelCdfStd(k: u8, t: f64) f64 {
    return switch (k) {
        1 => blk: {
            if (t <= -1.0) break :blk 0.0;
            if (t >= 1.0) break :blk 1.0;
            if (t < 0.0) break :blk 0.5 * (1.0 + t) * (1.0 + t);
            break :blk 1.0 - 0.5 * (1.0 - t) * (1.0 - t);
        },
        2 => blk: {
            if (t <= -1.0) break :blk 0.0;
            if (t >= 1.0) break :blk 1.0;
            break :blk 0.5 * (t + 1.0);
        },
        3 => blk: {
            if (t <= -1.0) break :blk 0.0;
            if (t >= 1.0) break :blk 1.0;
            break :blk 0.5 + 0.75 * t - 0.25 * t * t * t;
        },
        else => 0.5 * (1.0 + erfApprox(t / @sqrt(2.0))),
    };
}

var kde_class: ?*Class = null;

fn ensureKdeClass(interp: *Interp) !*Class {
    if (kde_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "__call__", kdeCall);
    const cls = try Class.init(a, "kde_callable", &.{}, d);
    kde_class = cls;
    return cls;
}

fn kdeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return kdeKw(p, args, &.{}, &.{});
}

fn kdeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    var h: f64 = 1.0;
    var kernel: i64 = 0;
    var cumulative = false;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "h")) h = floatOf(kv) catch 1.0;
        if (std.mem.eql(u8, kn.str.bytes, "kernel") and kv == .str) {
            const ks = kv.str.bytes;
            if (std.mem.eql(u8, ks, "triangular")) kernel = 1;
            if (std.mem.eql(u8, ks, "rectangular") or std.mem.eql(u8, ks, "uniform")) kernel = 2;
            if (std.mem.eql(u8, ks, "epanechnikov")) kernel = 3;
        }
        if (std.mem.eql(u8, kn.str.bytes, "cumulative")) cumulative = kv == .boolean and kv.boolean;
    }
    const cls = try ensureKdeClass(interp);
    const inst = try Instance.init(a, cls);
    // Stash data as a list on the dict
    const data_list = try List.init(a);
    switch (args[0]) {
        .list => |l| for (l.items.items) |it| try data_list.append(a, it),
        .tuple => |t| for (t.items) |it| try data_list.append(a, it),
        else => return error.TypeError,
    }
    try inst.dict.setStr(a, "_data", Value{ .list = data_list });
    try inst.dict.setStr(a, "_h", Value{ .float = h });
    try inst.dict.setStr(a, "_kernel", Value{ .small_int = kernel });
    try inst.dict.setStr(a, "_cumulative", Value{ .boolean = cumulative });
    return Value{ .instance = inst };
}

fn kdeCall(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2) return error.TypeError;
    const inst = args[0].instance;
    const data_v = inst.dict.getStr("_data") orelse return error.TypeError;
    const h_v = inst.dict.getStr("_h") orelse return error.TypeError;
    const kernel_v = inst.dict.getStr("_kernel") orelse return error.TypeError;
    const cum_v = inst.dict.getStr("_cumulative") orelse Value{ .boolean = false };
    const data = data_v.list.items.items;
    const h: f64 = h_v.float;
    const kernel: u8 = @intCast(kernel_v.small_int);
    const cumulative: bool = cum_v == .boolean and cum_v.boolean;
    const x = try floatOf(args[1]);
    var acc: f64 = 0;
    for (data) |d| {
        const dv = floatOf(d) catch 0.0;
        const t = (x - dv) / h;
        acc += if (cumulative) kernelCdfStd(kernel, t) else kernelPdfStd(kernel, t);
    }
    const n: f64 = @floatFromInt(data.len);
    return Value{ .float = if (cumulative) acc / n else acc / (n * h) };
}

fn kdeRandomFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return kdeRandomKw(p, args, &.{}, &.{});
}

var kde_random_class: ?*Class = null;

fn ensureKdeRandomClass(interp: *Interp) !*Class {
    if (kde_random_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "__call__", kdeRandomCall);
    const cls = try Class.init(a, "kde_sampler", &.{}, d);
    kde_random_class = cls;
    return cls;
}

fn kdeRandomKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    var h: f64 = 1.0;
    var seed: i64 = 0;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "h")) h = floatOf(kv) catch 1.0;
        if (std.mem.eql(u8, kn.str.bytes, "seed")) seed = switch (kv) {
            .small_int => |i| i,
            else => 0,
        };
    }
    const cls = try ensureKdeRandomClass(interp);
    const inst = try Instance.init(a, cls);
    const data_list = try List.init(a);
    switch (args[0]) {
        .list => |l| for (l.items.items) |it| try data_list.append(a, it),
        .tuple => |t| for (t.items) |it| try data_list.append(a, it),
        else => return error.TypeError,
    }
    try inst.dict.setStr(a, "_data", Value{ .list = data_list });
    try inst.dict.setStr(a, "_h", Value{ .float = h });
    try inst.dict.setStr(a, "_seed", Value{ .small_int = seed });
    try inst.dict.setStr(a, "_calls", Value{ .small_int = 0 });
    return Value{ .instance = inst };
}

fn kdeRandomCall(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = args[0].instance;
    const data_v = inst.dict.getStr("_data") orelse return error.TypeError;
    const h_v = inst.dict.getStr("_h") orelse return error.TypeError;
    const seed_v = inst.dict.getStr("_seed") orelse Value{ .small_int = 0 };
    const calls_v = inst.dict.getStr("_calls") orelse Value{ .small_int = 0 };
    const data = data_v.list.items.items;
    const h: f64 = h_v.float;
    const seed: u64 = @bitCast(seed_v.small_int);
    const calls: i64 = calls_v.small_int;
    // Seed with seed + calls so each call returns deterministic values.
    var prng = std.Random.DefaultPrng.init(seed +% @as(u64, @bitCast(calls)));
    const r = prng.random();
    const idx = r.intRangeLessThan(usize, 0, data.len);
    const dv = floatOf(data[idx]) catch 0.0;
    // Add gaussian noise scaled by h.
    const uu1 = @max(r.float(f64), 1e-12);
    const uu2 = r.float(f64);
    const z = @sqrt(-2.0 * @log(uu1)) * @cos(2.0 * std.math.pi * uu2);
    try inst.dict.setStr(a, "_calls", Value{ .small_int = calls + 1 });
    return Value{ .float = dv + h * z };
}

// ===== NormalDist =====

fn erfApprox(x: f64) f64 {
    const a1: f64 = 0.254829592;
    const a2: f64 = -0.284496736;
    const a3: f64 = 1.421413741;
    const a4: f64 = -1.453152027;
    const a5: f64 = 1.061405429;
    const pp: f64 = 0.3275911;
    const sign: f64 = if (x < 0) -1.0 else 1.0;
    const ax = @abs(x);
    const t = 1.0 / (1.0 + pp * ax);
    const poly = ((((a5 * t + a4) * t) + a3) * t + a2) * t + a1;
    const y = 1.0 - poly * t * @exp(-ax * ax);
    return sign * y;
}

fn normCdf(x: f64, mu: f64, sigma: f64) f64 {
    return 0.5 * (1.0 + erfApprox((x - mu) / (sigma * @sqrt(2.0))));
}

fn normPdf(x: f64, mu: f64, sigma: f64) f64 {
    const z = (x - mu) / sigma;
    return @exp(-0.5 * z * z) / (sigma * @sqrt(2.0 * std.math.pi));
}

// Inverse standard normal via Beasley-Springer-Moro approximation.
fn normInvStd(p: f64) f64 {
    if (p <= 0.0) return -std.math.inf(f64);
    if (p >= 1.0) return std.math.inf(f64);
    const a = [_]f64{ -3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02, 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00 };
    const b = [_]f64{ -5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02, 6.680131188771972e+01, -1.328068155288572e+01 };
    const c = [_]f64{ -7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00, -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00 };
    const d = [_]f64{ 7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00 };
    const plow = 0.02425;
    const phigh = 1.0 - plow;
    if (p < plow) {
        const q = @sqrt(-2.0 * @log(p));
        return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
            ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
    }
    if (p <= phigh) {
        const q = p - 0.5;
        const r = q * q;
        return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
            (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1);
    }
    const q = @sqrt(-2.0 * @log(1.0 - p));
    return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
        ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
}

const ND = struct { mu: f64, sigma: f64 };

fn ndOf(v: Value) ?ND {
    if (v != .instance) return null;
    const inst = v.instance;
    const m = inst.dict.getStr("_mu") orelse return null;
    const s = inst.dict.getStr("_sigma") orelse return null;
    return ND{ .mu = floatOf(m) catch return null, .sigma = floatOf(s) catch return null };
}

fn ndNew(interp: *Interp, mu: f64, sigma: f64) !Value {
    const inst = try Instance.init(interp.allocator, interp.statistics_normal_dist_class.?);
    try inst.dict.setStr(interp.allocator, "_mu", Value{ .float = mu });
    try inst.dict.setStr(interp.allocator, "_sigma", Value{ .float = sigma });
    try inst.dict.setStr(interp.allocator, "mean", Value{ .float = mu });
    try inst.dict.setStr(interp.allocator, "median", Value{ .float = mu });
    try inst.dict.setStr(interp.allocator, "mode", Value{ .float = mu });
    try inst.dict.setStr(interp.allocator, "stdev", Value{ .float = sigma });
    try inst.dict.setStr(interp.allocator, "variance", Value{ .float = sigma * sigma });
    return Value{ .instance = inst };
}

fn ndInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) {
        try interp.typeError("NormalDist.__init__ requires self");
        return error.TypeError;
    }
    const mu: f64 = if (args.len >= 2) try floatOf(args[1]) else 0.0;
    const sigma: f64 = if (args.len >= 3) try floatOf(args[2]) else 1.0;
    if (sigma < 0) {
        try raiseStat(interp, "sigma must be non-negative");
        return error.PyException;
    }
    const inst = args[0].instance;
    try inst.dict.setStr(interp.allocator, "_mu", Value{ .float = mu });
    try inst.dict.setStr(interp.allocator, "_sigma", Value{ .float = sigma });
    try inst.dict.setStr(interp.allocator, "mean", Value{ .float = mu });
    try inst.dict.setStr(interp.allocator, "median", Value{ .float = mu });
    try inst.dict.setStr(interp.allocator, "mode", Value{ .float = mu });
    try inst.dict.setStr(interp.allocator, "stdev", Value{ .float = sigma });
    try inst.dict.setStr(interp.allocator, "variance", Value{ .float = sigma * sigma });
    return Value.none;
}

fn ndRepr(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const nd = ndOf(args[0]) orelse return error.TypeError;
    const buf = try std.fmt.allocPrint(a, "NormalDist(mu={d}, sigma={d})", .{ nd.mu, nd.sigma });
    return Value{ .str = try Str.init(a, buf) };
}

fn ndAdd(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a_nd = ndOf(args[0]) orelse return error.TypeError;
    if (args.len < 2) return error.TypeError;
    if (ndOf(args[1])) |b_nd| {
        return try ndNew(interp, a_nd.mu + b_nd.mu, @sqrt(a_nd.sigma * a_nd.sigma + b_nd.sigma * b_nd.sigma));
    }
    const k = floatOf(args[1]) catch return error.TypeError;
    return try ndNew(interp, a_nd.mu + k, a_nd.sigma);
}

fn ndSub(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a_nd = ndOf(args[0]) orelse return error.TypeError;
    if (args.len < 2) return error.TypeError;
    if (ndOf(args[1])) |b_nd| {
        return try ndNew(interp, a_nd.mu - b_nd.mu, @sqrt(a_nd.sigma * a_nd.sigma + b_nd.sigma * b_nd.sigma));
    }
    const k = floatOf(args[1]) catch return error.TypeError;
    return try ndNew(interp, a_nd.mu - k, a_nd.sigma);
}

fn ndRsub(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a_nd = ndOf(args[0]) orelse return error.TypeError;
    if (args.len < 2) return error.TypeError;
    const k = floatOf(args[1]) catch return error.TypeError;
    return try ndNew(interp, k - a_nd.mu, a_nd.sigma);
}

fn ndMul(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a_nd = ndOf(args[0]) orelse return error.TypeError;
    if (args.len < 2) return error.TypeError;
    const k = floatOf(args[1]) catch return error.TypeError;
    return try ndNew(interp, a_nd.mu * k, a_nd.sigma * @abs(k));
}

fn ndDiv(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a_nd = ndOf(args[0]) orelse return error.TypeError;
    if (args.len < 2) return error.TypeError;
    const k = floatOf(args[1]) catch return error.TypeError;
    return try ndNew(interp, a_nd.mu / k, a_nd.sigma / @abs(k));
}

fn ndEq(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const a_nd = ndOf(args[0]) orelse return error.TypeError;
    if (args.len < 2) return Value{ .boolean = false };
    const b_nd = ndOf(args[1]) orelse return Value{ .boolean = false };
    return Value{ .boolean = a_nd.mu == b_nd.mu and a_nd.sigma == b_nd.sigma };
}

fn ndPdf(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const nd = ndOf(args[0]) orelse return error.TypeError;
    if (args.len < 2) return error.TypeError;
    const x = try floatOf(args[1]);
    return Value{ .float = normPdf(x, nd.mu, nd.sigma) };
}

fn ndCdf(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const nd = ndOf(args[0]) orelse return error.TypeError;
    if (args.len < 2) return error.TypeError;
    const x = try floatOf(args[1]);
    return Value{ .float = normCdf(x, nd.mu, nd.sigma) };
}

fn ndInvCdf(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const nd = ndOf(args[0]) orelse return error.TypeError;
    if (args.len < 2) return error.TypeError;
    const pp = try floatOf(args[1]);
    return Value{ .float = nd.mu + nd.sigma * normInvStd(pp) };
}

fn ndZscore(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const nd = ndOf(args[0]) orelse return error.TypeError;
    if (args.len < 2) return error.TypeError;
    const x = try floatOf(args[1]);
    return Value{ .float = (x - nd.mu) / nd.sigma };
}

fn ndQuantilesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return ndQuantilesKw(p, args, &.{}, &.{});
}

fn ndQuantilesKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const nd = ndOf(args[0]) orelse return error.TypeError;
    var n: usize = 4;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "n") and kv == .small_int) n = @intCast(kv.small_int);
    }
    const list = try List.init(a);
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const pp = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        try list.append(a, Value{ .float = nd.mu + nd.sigma * normInvStd(pp) });
    }
    return Value{ .list = list };
}

fn ndSamplesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return ndSamplesKw(p, args, &.{}, &.{});
}

fn ndSamplesKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const nd = ndOf(args[0]) orelse return error.TypeError;
    if (args.len < 2) return error.TypeError;
    const n: usize = @intCast(args[1].small_int);
    var seed: u64 = 0;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "seed")) seed = @bitCast(@as(i64, switch (kv) {
            .small_int => |i| i,
            else => 0,
        }));
    }
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const list = try List.init(a);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Box-Muller
        const uu1 = @max(r.float(f64), 1e-12);
        const uu2 = r.float(f64);
        const z = @sqrt(-2.0 * @log(uu1)) * @cos(2.0 * std.math.pi * uu2);
        try list.append(a, Value{ .float = nd.mu + nd.sigma * z });
    }
    return Value{ .list = list };
}

fn ndOverlap(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const a_nd = ndOf(args[0]) orelse return error.TypeError;
    if (args.len < 2) return error.TypeError;
    const b_nd = ndOf(args[1]) orelse return error.TypeError;
    if (a_nd.sigma == b_nd.sigma) {
        if (a_nd.mu == b_nd.mu) return Value{ .float = 1.0 };
        const dmu = @abs(a_nd.mu - b_nd.mu);
        return Value{ .float = 2.0 * normCdf(-dmu / 2.0, 0.0, a_nd.sigma) };
    }
    // General case (Inman & Bradley 1989)
    const X: f64 = a_nd.mu;
    const Y: f64 = b_nd.mu;
    const x_var = a_nd.sigma * a_nd.sigma;
    const y_var = b_nd.sigma * b_nd.sigma;
    const dv = y_var - x_var;
    const dm = @abs(Y - X);
    const a_coef = a_nd.sigma * b_nd.sigma * @sqrt(dm * dm + dv * @log(y_var / x_var));
    const x1 = (a_coef - (X * y_var - Y * x_var)) / dv;
    const x2 = (-a_coef - (X * y_var - Y * x_var)) / dv;
    const cdfx_x1 = normCdf(x1, X, a_nd.sigma);
    const cdfx_x2 = normCdf(x2, X, a_nd.sigma);
    const cdfy_x1 = normCdf(x1, Y, b_nd.sigma);
    const cdfy_x2 = normCdf(x2, Y, b_nd.sigma);
    return Value{ .float = 1.0 - (@abs(cdfy_x1 - cdfx_x1) + @abs(cdfy_x2 - cdfx_x2)) };
}

fn ndFromSamples(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const xs = try seqFloats(a, args[1]);
    defer a.free(xs);
    if (xs.len < 2) {
        try raiseStat(interp, "from_samples requires at least two data points");
        return error.PyException;
    }
    var sum: f64 = 0;
    for (xs) |x| sum += x;
    const mu = sum / @as(f64, @floatFromInt(xs.len));
    var ss: f64 = 0;
    for (xs) |x| ss += (x - mu) * (x - mu);
    const sigma = @sqrt(ss / @as(f64, @floatFromInt(xs.len - 1)));
    return ndNew(interp, mu, sigma);
}
