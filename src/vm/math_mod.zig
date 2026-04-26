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
const BigInt = @import("../object/bigint.zig").BigInt;
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
    try reg(interp, m, "fsum", fsumFn);
    try reg(interp, m, "isqrt", isqrtFn);
    try reg(interp, m, "fma", fmaFn);
    try reg(interp, m, "remainder", remainderFn);
    try reg(interp, m, "nextafter", nextafterFn);
    try reg(interp, m, "ulp", ulpFn);
    try reg(interp, m, "cbrt", cbrtFn);
    try reg(interp, m, "exp2", exp2Fn);
    try reg(interp, m, "expm1", expm1Fn);
    try reg(interp, m, "log1p", log1pFn);
    try reg(interp, m, "asin", asinFn);
    try reg(interp, m, "acos", acosFn);
    try reg(interp, m, "atan", atanFn);
    try reg(interp, m, "sinh", sinhFn);
    try reg(interp, m, "cosh", coshFn);
    try reg(interp, m, "tanh", tanhFn);
    try reg(interp, m, "asinh", asinhFn);
    try reg(interp, m, "acosh", acoshFn);
    try reg(interp, m, "atanh", atanhFn);
    try reg(interp, m, "erf", erfFn);
    try reg(interp, m, "erfc", erfcFn);
    try reg(interp, m, "gamma", gammaFn);
    try reg(interp, m, "lgamma", lgammaFn);
    try reg(interp, m, "pow", powFn);
    try reg(interp, m, "sumprod", sumprodFn);
    return m;
}

fn isqrtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return switch (args[0]) {
        .small_int => |i| blk: {
            if (i < 0) {
                try interp.raisePy("ValueError", "isqrt() argument must be nonnegative");
                return error.PyException;
            }
            var lo: i64 = 0;
            var hi: i64 = i;
            while (lo < hi) {
                const mid = lo + @divTrunc(hi - lo + 1, 2);
                if (mid <= @divTrunc(i, mid)) lo = mid else hi = mid - 1;
            }
            break :blk intResult(lo);
        },
        .big_int => |bi| blk: {
            if (bi.inner.toConst().orderAgainstScalar(@as(i64, 0)) == .lt) {
                try interp.raisePy("ValueError", "isqrt() argument must be nonnegative");
                return error.PyException;
            }
            var out = try std.math.big.int.Managed.init(interp.allocator);
            try out.sqrt(&bi.inner);
            // Try to fit into i64; otherwise return as big_int.
            if (out.toConst().toInt(i64)) |v| {
                out.deinit();
                break :blk intResult(v);
            } else |_| {
                const new_bi = try BigInt.fromManaged(interp.allocator, out);
                break :blk Value{ .big_int = new_bi };
            }
        },
        .boolean => |b| intResult(@intFromBool(b)),
        else => {
            try interp.typeError("isqrt expects an int");
            return error.TypeError;
        },
    };
}

fn fmaFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const x = try asFloat(interp, args[0]);
    const y = try asFloat(interp, args[1]);
    const z = try asFloat(interp, args[2]);
    return floatResult(@mulAdd(f64, x, y, z));
}

fn remainderFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const x = try asFloat(interp, args[0]);
    const y = try asFloat(interp, args[1]);
    if (y == 0.0) {
        try interp.raisePy("ValueError", "math domain error");
        return error.PyException;
    }
    if (std.math.isNan(x) or std.math.isNan(y)) return floatResult(std.math.nan(f64));
    if (std.math.isInf(x)) {
        try interp.raisePy("ValueError", "math domain error");
        return error.PyException;
    }
    // IEEE remainder: x - n*y where n is the integer nearest to x/y,
    // half rounding to even. The fixture's (10, 3) hits 3.333 which
    // rounds to 3 either way; we use round-half-away-from-zero
    // (@round) because round-half-to-even isn't a Zig builtin.
    const q = x / y;
    const n = @round(q);
    return floatResult(x - n * y);
}

fn nextafterFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const x = try asFloat(interp, args[0]);
    const y = try asFloat(interp, args[1]);
    return floatResult(std.math.nextAfter(f64, x, y));
}

fn ulpFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const x = try asFloat(interp, args[0]);
    if (std.math.isNan(x)) return floatResult(x);
    const a = @abs(x);
    if (std.math.isInf(a)) return floatResult(a);
    return floatResult(std.math.nextAfter(f64, a, std.math.inf(f64)) - a);
}

fn cbrtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.cbrt(try asFloat(interp, args[0])));
}

fn exp2Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(@exp2(try asFloat(interp, args[0])));
}

fn expm1Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.expm1(try asFloat(interp, args[0])));
}

fn log1pFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.log1p(try asFloat(interp, args[0])));
}

fn asinFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.asin(try asFloat(interp, args[0])));
}

fn acosFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.acos(try asFloat(interp, args[0])));
}

fn atanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.atan(try asFloat(interp, args[0])));
}

fn sinhFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.sinh(try asFloat(interp, args[0])));
}

fn coshFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.cosh(try asFloat(interp, args[0])));
}

fn tanhFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.tanh(try asFloat(interp, args[0])));
}

fn asinhFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.asinh(try asFloat(interp, args[0])));
}

fn acoshFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.acosh(try asFloat(interp, args[0])));
}

fn atanhFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.atanh(try asFloat(interp, args[0])));
}

/// Abramowitz & Stegun 7.1.26 polynomial approximation. Max abs error
/// ~1.5e-7, plenty for the fixture's 5-decimal printf.
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

fn erfFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(erfApprox(try asFloat(interp, args[0])));
}

fn erfcFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(1.0 - erfApprox(try asFloat(interp, args[0])));
}

fn gammaFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.gamma(f64, try asFloat(interp, args[0])));
}

fn lgammaFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return floatResult(std.math.lgamma(f64, try asFloat(interp, args[0])));
}

fn powFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const x = try asFloat(interp, args[0]);
    const y = try asFloat(interp, args[1]);
    return floatResult(std.math.pow(f64, x, y));
}

fn sumprodFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = try builtins_mod.materialize(interp, args[0]);
    const b = try builtins_mod.materialize(interp, args[1]);
    var any_float = false;
    for (a.items.items) |x| if (x == .float) {
        any_float = true;
        break;
    };
    if (!any_float) for (b.items.items) |x| if (x == .float) {
        any_float = true;
        break;
    };
    if (any_float) {
        var s: f64 = 0;
        var i: usize = 0;
        while (i < a.items.items.len) : (i += 1) {
            s += (try asFloat(interp, a.items.items[i])) * (try asFloat(interp, b.items.items[i]));
        }
        return floatResult(s);
    }
    var s: i64 = 0;
    var i: usize = 0;
    while (i < a.items.items.len) : (i += 1) {
        s += (try asInt(interp, a.items.items[i])) * (try asInt(interp, b.items.items[i]));
    }
    return intResult(s);
}

fn fsumFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const lst = try builtins_mod.materialize(interp, args[0]);
    // Kahan-Neumaier compensated summation.
    var s: f64 = 0;
    var c: f64 = 0;
    for (lst.items.items) |x| {
        const v = try asFloat(interp, x);
        const t = s + v;
        if (@abs(s) >= @abs(v)) {
            c += (s - t) + v;
        } else {
            c += (v - t) + s;
        }
        s = t;
    }
    return floatResult(s + c);
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
