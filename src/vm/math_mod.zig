//! Pinhole `math` module: enough constants and functions for fixture
//! 63. Float ops follow CPython semantics tightly enough for shared
//! prints (formatted values, isclose, etc.). Big-int factorial is not
//! supported -- the fixture stays under 13!.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Interp = @import("interp.zig").Interp;
const builtins_mod = @import("builtins.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "math");
    const a = interp.allocator;
    try m.attrs.setStr(a, "pi", Value{ .float = std.math.pi });
    try m.attrs.setStr(a, "e", Value{ .float = std.math.e });
    try m.attrs.setStr(a, "tau", Value{ .float = std.math.tau });
    try m.attrs.setStr(a, "inf", Value{ .float = std.math.inf(f64) });
    try m.attrs.setStr(a, "nan", Value{ .float = std.math.nan(f64) });

    try reg(interp, m, "sqrt", sqrtFn);
    try reg(interp, m, "ceil", ceilFn);
    try reg(interp, m, "floor", floorFn);
    try reg(interp, m, "trunc", truncFn);
    try reg(interp, m, "fabs", fabsFn);
    try reg(interp, m, "gcd", gcdFn);
    try reg(interp, m, "lcm", lcmFn);
    try reg(interp, m, "factorial", factorialFn);
    try reg(interp, m, "comb", combFn);
    try reg(interp, m, "perm", permFn);
    try reg(interp, m, "hypot", hypotFn);
    try reg(interp, m, "dist", distFn);
    try regKw(interp, m, "prod", prodFn, prodKw);
    try regKw(interp, m, "isclose", iscloseFn, iscloseKw);
    try reg(interp, m, "log", logFn);
    try reg(interp, m, "log2", log2Fn);
    try reg(interp, m, "log10", log10Fn);
    try reg(interp, m, "exp", expFn);
    try reg(interp, m, "sin", sinFn);
    try reg(interp, m, "cos", cosFn);
    try reg(interp, m, "tan", tanFn);
    try reg(interp, m, "atan2", atan2Fn);
    try reg(interp, m, "degrees", degreesFn);
    try reg(interp, m, "radians", radiansFn);
    try reg(interp, m, "copysign", copysignFn);
    try reg(interp, m, "fmod", fmodFn);
    try reg(interp, m, "isfinite", isfiniteFn);
    try reg(interp, m, "isinf", isinfFn);
    try reg(interp, m, "isnan", isnanFn);
    try reg(interp, m, "modf", modfFn);
    try reg(interp, m, "frexp", frexpFn);
    try reg(interp, m, "ldexp", ldexpFn);
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

fn asFloat(interp: *Interp, v: Value) !f64 {
    return switch (v) {
        .float => |f| f,
        .small_int => |i| @floatFromInt(i),
        .boolean => |b| if (b) 1.0 else 0.0,
        else => {
            try interp.typeError("expected number");
            return error.TypeError;
        },
    };
}

fn asInt(interp: *Interp, v: Value) !i64 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        else => {
            try interp.typeError("expected int");
            return error.TypeError;
        },
    };
}

fn intResult(x: i64) Value {
    return Value{ .small_int = x };
}

fn floatResult(x: f64) Value {
    return Value{ .float = x };
}

fn sqrtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(@sqrt(try asFloat(interp, args[0])));
}

fn ceilFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args[0] == .small_int) return args[0];
    const f = try asFloat(interp, args[0]);
    return intResult(@as(i64, @intFromFloat(@ceil(f))));
}

fn floorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args[0] == .small_int) return args[0];
    const f = try asFloat(interp, args[0]);
    return intResult(@as(i64, @intFromFloat(@floor(f))));
}

fn truncFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args[0] == .small_int) return args[0];
    const f = try asFloat(interp, args[0]);
    return intResult(@as(i64, @intFromFloat(@trunc(f))));
}

fn fabsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(@abs(try asFloat(interp, args[0])));
}

fn gcd2(a: i64, b: i64) i64 {
    var x = if (a < 0) -a else a;
    var y = if (b < 0) -b else b;
    while (y != 0) {
        const t = @mod(x, y);
        x = y;
        y = t;
    }
    return x;
}

fn gcdFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len == 0) return intResult(0);
    var g: i64 = try asInt(interp, args[0]);
    if (g < 0) g = -g;
    var i: usize = 1;
    while (i < args.len) : (i += 1) g = gcd2(g, try asInt(interp, args[i]));
    return intResult(g);
}

fn lcmFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len == 0) return intResult(1);
    var l: i64 = try asInt(interp, args[0]);
    if (l < 0) l = -l;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        var x = try asInt(interp, args[i]);
        if (x < 0) x = -x;
        if (l == 0 or x == 0) {
            l = 0;
        } else {
            l = @divTrunc(l, gcd2(l, x)) * x;
        }
    }
    return intResult(l);
}

fn factorialFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const n = try asInt(interp, args[0]);
    if (n < 0) {
        try interp.raisePy("ValueError", "factorial() not defined for negative values");
        return error.PyException;
    }
    var r: i64 = 1;
    var k: i64 = 2;
    while (k <= n) : (k += 1) r *= k;
    return intResult(r);
}

fn combFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const n = try asInt(interp, args[0]);
    const k_in = try asInt(interp, args[1]);
    if (k_in < 0 or n < 0) return intResult(0);
    if (k_in > n) return intResult(0);
    var k = k_in;
    if (k > n - k) k = n - k;
    var r: i64 = 1;
    var i: i64 = 0;
    while (i < k) : (i += 1) {
        r = @divTrunc(r * (n - i), i + 1);
    }
    return intResult(r);
}

fn permFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const n = try asInt(interp, args[0]);
    const k: i64 = if (args.len >= 2 and args[1] != .none) try asInt(interp, args[1]) else n;
    if (k < 0 or n < 0 or k > n) return intResult(0);
    var r: i64 = 1;
    var i: i64 = 0;
    while (i < k) : (i += 1) r *= (n - i);
    return intResult(r);
}

fn hypotFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var s: f64 = 0;
    for (args) |x| {
        const f = try asFloat(interp, x);
        s += f * f;
    }
    return floatResult(@sqrt(s));
}

fn distFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = try builtins_mod.materialize(interp, args[0]);
    const b = try builtins_mod.materialize(interp, args[1]);
    var s: f64 = 0;
    var i: usize = 0;
    while (i < a.items.items.len) : (i += 1) {
        const d = (try asFloat(interp, a.items.items[i])) - (try asFloat(interp, b.items.items[i]));
        s += d * d;
    }
    return floatResult(@sqrt(s));
}

fn prodFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return prodKw(p, args, &.{}, &.{});
}

fn prodKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var start_v: Value = Value{ .small_int = 1 };
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "start")) start_v = kv;
    }
    if (args.len >= 2) start_v = args[1];
    const lst = try builtins_mod.materialize(interp, args[0]);
    var any_float = start_v == .float;
    for (lst.items.items) |x| if (x == .float) {
        any_float = true;
        break;
    };
    if (any_float) {
        var f: f64 = try asFloat(interp, start_v);
        for (lst.items.items) |x| f *= try asFloat(interp, x);
        return floatResult(f);
    }
    var i: i64 = try asInt(interp, start_v);
    for (lst.items.items) |x| i *= try asInt(interp, x);
    return intResult(i);
}

fn iscloseFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return iscloseKw(p, args, &.{}, &.{});
}

fn iscloseKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = try asFloat(interp, args[0]);
    const b = try asFloat(interp, args[1]);
    var rel_tol: f64 = 1e-9;
    var abs_tol: f64 = 0.0;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "rel_tol")) rel_tol = try asFloat(interp, kv);
        if (std.mem.eql(u8, kn.str.bytes, "abs_tol")) abs_tol = try asFloat(interp, kv);
    }
    if (a == b) return Value{ .boolean = true };
    if (std.math.isInf(a) or std.math.isInf(b)) return Value{ .boolean = false };
    const diff = @abs(a - b);
    const tol = @max(rel_tol * @max(@abs(a), @abs(b)), abs_tol);
    return Value{ .boolean = diff <= tol };
}

fn logFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const x = try asFloat(interp, args[0]);
    if (args.len == 2) {
        const base = try asFloat(interp, args[1]);
        return floatResult(@log(x) / @log(base));
    }
    return floatResult(@log(x));
}

fn log2Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(@log2(try asFloat(interp, args[0])));
}

fn log10Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(@log10(try asFloat(interp, args[0])));
}

fn expFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(@exp(try asFloat(interp, args[0])));
}

fn sinFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(@sin(try asFloat(interp, args[0])));
}

fn cosFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(@cos(try asFloat(interp, args[0])));
}

fn tanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(@tan(try asFloat(interp, args[0])));
}

fn atan2Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const y = try asFloat(interp, args[0]);
    const x = try asFloat(interp, args[1]);
    return floatResult(std.math.atan2(y, x));
}

fn degreesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(try asFloat(interp, args[0]) * (180.0 / std.math.pi));
}

fn radiansFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(try asFloat(interp, args[0]) * (std.math.pi / 180.0));
}

fn copysignFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.copysign(try asFloat(interp, args[0]), try asFloat(interp, args[1])));
}

fn fmodFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(@rem(try asFloat(interp, args[0]), try asFloat(interp, args[1])));
}

fn isfiniteFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const f = try asFloat(interp, args[0]);
    return Value{ .boolean = std.math.isFinite(f) };
}

fn isinfFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const f = try asFloat(interp, args[0]);
    return Value{ .boolean = std.math.isInf(f) };
}

fn isnanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const f = try asFloat(interp, args[0]);
    return Value{ .boolean = std.math.isNan(f) };
}

fn modfFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const f = try asFloat(interp, args[0]);
    const whole = @trunc(f);
    const frac = f - whole;
    const t = try Tuple.init(interp.allocator, 2);
    t.items[0] = floatResult(frac);
    t.items[1] = floatResult(whole);
    return Value{ .tuple = t };
}

fn frexpFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const f = try asFloat(interp, args[0]);
    const r = std.math.frexp(f);
    const t = try Tuple.init(interp.allocator, 2);
    t.items[0] = floatResult(r.significand);
    t.items[1] = intResult(@intCast(r.exponent));
    return Value{ .tuple = t };
}

fn ldexpFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const m = try asFloat(interp, args[0]);
    const e = try asInt(interp, args[1]);
    return floatResult(std.math.ldexp(m, @intCast(e)));
}
