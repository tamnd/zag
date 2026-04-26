//! Pinhole `cmath` module: complex-arg analogues of the `math`
//! functions. Constants follow CPython exactly. Each function widens
//! its input to a `Complex(f64)` so callers can pass plain ints and
//! floats; the result always comes back as a `complex` value.
//!
//! Where possible we reach for `std.math.complex`; for the few
//! functions whose signed-zero behaviour matters (`cos`, `sin`,
//! `acos`, `asin`, ...) we follow CPython's `cmathmodule.c` formulas
//! directly so the printed +0.0 / -0.0 split matches.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Complex = value_mod.Complex;
const Module = @import("../object/module.zig").Module;
const Tuple = @import("../object/tuple.zig").Tuple;
const Interp = @import("interp.zig").Interp;
const cmath = std.math.complex;
const ZComplex = cmath.Complex(f64);

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "cmath");
    try m.attrs.setStr(a, "pi", Value{ .float = std.math.pi });
    try m.attrs.setStr(a, "e", Value{ .float = std.math.e });
    try m.attrs.setStr(a, "tau", Value{ .float = std.math.tau });
    try m.attrs.setStr(a, "inf", Value{ .float = std.math.inf(f64) });
    try m.attrs.setStr(a, "nan", Value{ .float = std.math.nan(f64) });
    try m.attrs.setStr(a, "infj", Value{ .complex_num = .{ .re = 0, .im = std.math.inf(f64) } });
    try m.attrs.setStr(a, "nanj", Value{ .complex_num = .{ .re = 0, .im = std.math.nan(f64) } });

    try reg(interp, m, "phase", phaseFn);
    try reg(interp, m, "polar", polarFn);
    try reg(interp, m, "rect", rectFn);
    try reg(interp, m, "exp", expFn);
    try reg(interp, m, "log", logFn);
    try reg(interp, m, "log10", log10Fn);
    try reg(interp, m, "sqrt", sqrtFn);
    try reg(interp, m, "sin", sinFn);
    try reg(interp, m, "cos", cosFn);
    try reg(interp, m, "tan", tanFn);
    try reg(interp, m, "asin", asinFn);
    try reg(interp, m, "acos", acosFn);
    try reg(interp, m, "atan", atanFn);
    try reg(interp, m, "sinh", sinhFn);
    try reg(interp, m, "cosh", coshFn);
    try reg(interp, m, "tanh", tanhFn);
    try reg(interp, m, "asinh", asinhFn);
    try reg(interp, m, "acosh", acoshFn);
    try reg(interp, m, "atanh", atanhFn);
    try reg(interp, m, "isfinite", isfiniteFn);
    try reg(interp, m, "isinf", isinfFn);
    try reg(interp, m, "isnan", isnanFn);
    try regKw(interp, m, "isclose", iscloseFn, iscloseKw);
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

fn asComplex(interp: *Interp, v: Value) !ZComplex {
    return switch (v) {
        .complex_num => |c| ZComplex.init(c.re, c.im),
        .float => |f| ZComplex.init(f, 0),
        .small_int => |i| ZComplex.init(@floatFromInt(i), 0),
        .boolean => |b| ZComplex.init(if (b) 1.0 else 0.0, 0),
        else => {
            try interp.typeError("expected number");
            return error.TypeError;
        },
    };
}

fn cval(z: ZComplex) Value {
    return Value{ .complex_num = .{ .re = z.re, .im = z.im } };
}

fn phaseFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    return Value{ .float = std.math.atan2(z.im, z.re) };
}

fn polarFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    const r = std.math.hypot(z.re, z.im);
    const phi = std.math.atan2(z.im, z.re);
    const t = try Tuple.init(interp.allocator, 2);
    t.items[0] = Value{ .float = r };
    t.items[1] = Value{ .float = phi };
    return Value{ .tuple = t };
}

fn rectFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const r = try toFloat(interp, args[0]);
    const phi = try toFloat(interp, args[1]);
    return Value{ .complex_num = .{
        .re = r * @cos(phi),
        .im = r * @sin(phi),
    } };
}

fn toFloat(interp: *Interp, v: Value) !f64 {
    return switch (v) {
        .float => |f| f,
        .small_int => |i| @floatFromInt(i),
        .boolean => |b| if (b) 1.0 else 0.0,
        else => {
            try interp.typeError("expected real number");
            return error.TypeError;
        },
    };
}

fn expFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    // exp(a+bi) = exp(a) * (cos(b) + i*sin(b)).
    const ea = @exp(z.re);
    return Value{ .complex_num = .{
        .re = ea * @cos(z.im),
        .im = ea * @sin(z.im),
    } };
}

fn logFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    const lz = ZComplex.init(@log(std.math.hypot(z.re, z.im)), std.math.atan2(z.im, z.re));
    if (args.len >= 2) {
        const b = try asComplex(interp, args[1]);
        const lb = ZComplex.init(@log(std.math.hypot(b.re, b.im)), std.math.atan2(b.im, b.re));
        return cval(lz.div(lb));
    }
    return cval(lz);
}

fn log10Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    const ln10 = @log(@as(f64, 10));
    return Value{ .complex_num = .{
        .re = @log(std.math.hypot(z.re, z.im)) / ln10,
        .im = std.math.atan2(z.im, z.re) / ln10,
    } };
}

fn csqrt(z: ZComplex) ZComplex {
    // Mirrors CPython's c_sqrt so signed zeros propagate through to
    // asin / acos / asinh / acosh exactly as they do upstream.
    if (z.re == 0.0 and z.im == 0.0) return ZComplex.init(0, z.im);
    const ax = @abs(z.re) / 8.0;
    const ay = @abs(z.im) / 8.0;
    const s = 2.0 * @sqrt(ax + std.math.hypot(ax, ay));
    const d = @abs(z.im) / (2.0 * s);
    if (z.re >= 0) {
        return ZComplex.init(s, std.math.copysign(d, z.im));
    } else {
        return ZComplex.init(d, std.math.copysign(s, z.im));
    }
}

fn sqrtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    return cval(csqrt(z));
}

fn sinFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    return Value{ .complex_num = .{
        .re = @sin(z.re) * std.math.cosh(z.im),
        .im = @cos(z.re) * std.math.sinh(z.im),
    } };
}

fn cosFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    return Value{ .complex_num = .{
        .re = @cos(z.re) * std.math.cosh(z.im),
        .im = -@sin(z.re) * std.math.sinh(z.im),
    } };
}

fn tanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    return cval(cmath.tan(z));
}

fn asinFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    // Special-table entry: zero in -> zero out (with positive zero
    // imag). Avoids the spurious -0 imag from the general formula.
    if (z.re == 0.0 and z.im == 0.0) return cval(ZComplex.init(0, 0));
    const s1 = csqrt(ZComplex.init(1.0 - z.re, -z.im));
    const s2 = csqrt(ZComplex.init(1.0 + z.re, z.im));
    return Value{ .complex_num = .{
        .re = std.math.atan2(z.re, s1.re * s2.re - s1.im * s2.im),
        .im = std.math.asinh(s2.re * s1.im - s2.im * s1.re),
    } };
}

fn acosFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    const s1 = csqrt(ZComplex.init(1.0 - z.re, -z.im));
    const s2 = csqrt(ZComplex.init(1.0 + z.re, z.im));
    return Value{ .complex_num = .{
        .re = 2.0 * std.math.atan2(s1.re, s2.re),
        .im = std.math.asinh(s2.re * s1.im - s2.im * s1.re),
    } };
}

fn atanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    return cval(cmath.atan(z));
}

fn sinhFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    return Value{ .complex_num = .{
        .re = std.math.sinh(z.re) * @cos(z.im),
        .im = std.math.cosh(z.re) * @sin(z.im),
    } };
}

fn coshFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    return Value{ .complex_num = .{
        .re = std.math.cosh(z.re) * @cos(z.im),
        .im = std.math.sinh(z.re) * @sin(z.im),
    } };
}

fn tanhFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    return cval(cmath.tanh(z));
}

fn asinhFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    if (z.re == 0.0 and z.im == 0.0) return cval(ZComplex.init(0, 0));
    // asinh(z) = i * asin(-i * z), inlined.
    const w = ZComplex.init(z.im, -z.re);
    const s1 = csqrt(ZComplex.init(1.0 - w.re, -w.im));
    const s2 = csqrt(ZComplex.init(1.0 + w.re, w.im));
    const a_re = std.math.atan2(w.re, s1.re * s2.re - s1.im * s2.im);
    const a_im = std.math.asinh(s2.re * s1.im - s2.im * s1.re);
    return Value{ .complex_num = .{ .re = -a_im, .im = a_re } };
}

fn acoshFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    const s1 = csqrt(ZComplex.init(z.re - 1.0, z.im));
    const s2 = csqrt(ZComplex.init(z.re + 1.0, z.im));
    return Value{ .complex_num = .{
        .re = std.math.asinh(s1.re * s2.re + s1.im * s2.im),
        .im = 2.0 * std.math.atan2(s1.im, s2.re),
    } };
}

fn atanhFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    return cval(cmath.atanh(z));
}

fn isfiniteFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    return Value{ .boolean = std.math.isFinite(z.re) and std.math.isFinite(z.im) };
}

fn isinfFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    return Value{ .boolean = std.math.isInf(z.re) or std.math.isInf(z.im) };
}

fn isnanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const z = try asComplex(interp, args[0]);
    return Value{ .boolean = std.math.isNan(z.re) or std.math.isNan(z.im) };
}

fn iscloseFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return iscloseKw(p, args, &.{}, &.{});
}

fn iscloseKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = try asComplex(interp, args[0]);
    const b = try asComplex(interp, args[1]);
    var rel_tol: f64 = 1e-9;
    var abs_tol: f64 = 0.0;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "rel_tol")) rel_tol = try toFloat(interp, kv);
        if (std.mem.eql(u8, kn.str.bytes, "abs_tol")) abs_tol = try toFloat(interp, kv);
    }
    if (a.re == b.re and a.im == b.im) return Value{ .boolean = true };
    const a_inf = std.math.isInf(a.re) or std.math.isInf(a.im);
    const b_inf = std.math.isInf(b.re) or std.math.isInf(b.im);
    if (a_inf or b_inf) return Value{ .boolean = false };
    const a_nan = std.math.isNan(a.re) or std.math.isNan(a.im);
    const b_nan = std.math.isNan(b.re) or std.math.isNan(b.im);
    if (a_nan or b_nan) return Value{ .boolean = false };
    const dre = a.re - b.re;
    const dim = a.im - b.im;
    const diff = std.math.hypot(dre, dim);
    const ar = std.math.hypot(a.re, a.im);
    const br = std.math.hypot(b.re, b.im);
    const tol = @max(rel_tol * @max(ar, br), abs_tol);
    return Value{ .boolean = diff <= tol };
}
