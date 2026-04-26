//! Pinhole `fractions` module: `Fraction` rationals with big-int
//! numerator/denominator. Values store `numerator` and `denominator`
//! directly on the instance dict (so attribute access works without
//! property descriptors); both are kept reduced and the denominator is
//! always positive. Float→Fraction goes through the IEEE-754 mantissa/
//! exponent split, then a single GCD strips out the power-of-two
//! shared between numerator and denominator.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Tuple = @import("../object/tuple.zig").Tuple;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Descriptor = @import("../object/descriptor.zig").Descriptor;
const Interp = @import("interp.zig").Interp;
const ZBig = std.math.big.int.Managed;
const BigInt = @import("../object/bigint.zig").BigInt;

const Ratio = struct { num: ZBig, den: ZBig };

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);
    const m = try Module.init(a, "fractions");
    try m.attrs.setStr(a, "Fraction", Value{ .class = interp.fractions_class.? });
    return m;
}

fn ensureClasses(interp: *Interp) !void {
    if (interp.fractions_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "__init__", initFn);
    try methodReg(a, d, "__repr__", reprFn);
    try methodReg(a, d, "__str__", strFn);
    try methodReg(a, d, "__add__", addFn);
    try methodReg(a, d, "__radd__", addFn);
    try methodReg(a, d, "__sub__", subFn);
    try methodReg(a, d, "__rsub__", rsubFn);
    try methodReg(a, d, "__mul__", mulFn);
    try methodReg(a, d, "__rmul__", mulFn);
    try methodReg(a, d, "__truediv__", divFn);
    try methodReg(a, d, "__rtruediv__", rdivFn);
    try methodReg(a, d, "__floordiv__", floordivFn);
    try methodReg(a, d, "__rfloordiv__", rfloordivFn);
    try methodReg(a, d, "__mod__", modFn);
    try methodReg(a, d, "__rmod__", rmodFn);
    try methodReg(a, d, "__pow__", powFn);
    try methodReg(a, d, "__neg__", negFn);
    try methodReg(a, d, "__pos__", posFn);
    try methodReg(a, d, "__abs__", absFn);
    try methodReg(a, d, "__bool__", boolFn);
    try methodReg(a, d, "__int__", intFn);
    try methodReg(a, d, "__float__", floatFn);
    try methodReg(a, d, "__floor__", floorMethodFn);
    try methodReg(a, d, "__ceil__", ceilMethodFn);
    try methodReg(a, d, "__trunc__", truncMethodFn);
    try methodReg(a, d, "__round__", roundMethodFn);
    try methodReg(a, d, "__eq__", eqFn);
    try methodReg(a, d, "__ne__", neFn);
    try methodReg(a, d, "__lt__", ltFn);
    try methodReg(a, d, "__le__", leFn);
    try methodReg(a, d, "__gt__", gtFn);
    try methodReg(a, d, "__ge__", geFn);
    try methodReg(a, d, "as_integer_ratio", asIntegerRatioFn);
    try methodReg(a, d, "is_integer", isIntegerFn);
    try methodReg(a, d, "limit_denominator", limitDenominatorFn);

    const cls = try Class.init(a, "Fraction", &.{}, d);

    // Classmethods.
    try registerClassmethod(a, d, "from_float", fromFloatCls);
    try registerClassmethod(a, d, "from_decimal", fromDecimalCls);
    try registerClassmethod(a, d, "from_number", fromNumberCls);

    interp.fractions_class = cls;
}

fn methodReg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn registerClassmethod(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    const desc = try Descriptor.init(a, .classmethod, Value{ .builtin_fn = f });
    try d.setStr(a, name, Value{ .descriptor = desc });
}

// ===== Helpers =====

/// Materialise a Value as `*ZBig` (caller frees with `.deinit()`).
fn valueToBig(a: std.mem.Allocator, v: Value) !ZBig {
    var b = try ZBig.init(a);
    errdefer b.deinit();
    switch (v) {
        .small_int => |i| try b.set(i),
        .big_int => |bi| try b.copy(bi.inner.toConst()),
        .boolean => |x| try b.set(@as(i64, if (x) 1 else 0)),
        else => return error.TypeError,
    }
    return b;
}

/// Wrap a `ZBig` into a Python int Value, using `small_int` when it fits.
fn bigToValue(a: std.mem.Allocator, b: *ZBig) !Value {
    if (b.toInt(i64)) |v| {
        return Value{ .small_int = v };
    } else |_| {}
    var copy = try ZBig.init(a);
    errdefer copy.deinit();
    try copy.copy(b.toConst());
    const big = try BigInt.fromManaged(a, copy);
    return Value{ .big_int = big };
}

/// Compute gcd of |x| and |y| (always non-negative).
fn gcdBig(a: std.mem.Allocator, x: *const ZBig, y: *const ZBig) !ZBig {
    var ax = try ZBig.init(a);
    defer ax.deinit();
    try ax.copy(x.toConst());
    if (!ax.isPositive() and !ax.eqlZero()) ax.negate();
    var ay = try ZBig.init(a);
    defer ay.deinit();
    try ay.copy(y.toConst());
    if (!ay.isPositive() and !ay.eqlZero()) ay.negate();
    var g = try ZBig.init(a);
    errdefer g.deinit();
    if (ax.eqlZero()) {
        try g.copy(ay.toConst());
        return g;
    }
    if (ay.eqlZero()) {
        try g.copy(ax.toConst());
        return g;
    }
    try g.gcd(&ax, &ay);
    return g;
}

/// Reduce (n, d) into the canonical (num, den) form (gcd=1, den>0).
fn reduceInPlace(a: std.mem.Allocator, n: *ZBig, d: *ZBig) !void {
    if (d.eqlZero()) return error.DivByZero;
    if (!d.isPositive()) {
        d.negate();
        n.negate();
    }
    var g = try gcdBig(a, n, d);
    defer g.deinit();
    if (!g.eqlZero()) {
        var one = try ZBig.initSet(a, 1);
        defer one.deinit();
        if (g.order(one) != .eq) {
            var qn = try ZBig.init(a);
            defer qn.deinit();
            var rn = try ZBig.init(a);
            defer rn.deinit();
            try qn.divFloor(&rn, n, &g);
            try n.copy(qn.toConst());
            var qd = try ZBig.init(a);
            defer qd.deinit();
            var rd = try ZBig.init(a);
            defer rd.deinit();
            try qd.divFloor(&rd, d, &g);
            try d.copy(qd.toConst());
        }
    }
}

/// Read the canonical fraction off an instance.
const Frac = struct {
    num: Value,
    den: Value,
};

fn readFrac(v: Value) ?Frac {
    if (v != .instance) return null;
    const inst = v.instance;
    const n = inst.dict.getStr("numerator") orelse return null;
    const d = inst.dict.getStr("denominator") orelse return null;
    return Frac{ .num = n, .den = d };
}

/// Build a fresh Fraction instance from raw `n` and `d` ZBig values
/// (which the helper reduces and stores as int Values on the dict).
fn newFraction(interp: *Interp, n_in: *ZBig, d_in: *ZBig) !Value {
    const a = interp.allocator;
    var n = try ZBig.init(a);
    defer n.deinit();
    try n.copy(n_in.toConst());
    var d = try ZBig.init(a);
    defer d.deinit();
    try d.copy(d_in.toConst());
    try reduceInPlace(a, &n, &d);
    const inst = try Instance.init(a, interp.fractions_class.?);
    const nv = try bigToValue(a, &n);
    const dv = try bigToValue(a, &d);
    try inst.dict.setStr(a, "numerator", nv);
    try inst.dict.setStr(a, "denominator", dv);
    return Value{ .instance = inst };
}

/// Coerce any number-like Value into a (num, den) pair held in two
/// freshly-allocated ZBig values. Caller must `.deinit()` both.
fn coerceToFrac(interp: *Interp, v: Value) !Ratio {
    const a = interp.allocator;
    switch (v) {
        .instance => {
            const f = readFrac(v) orelse {
                try interp.typeError("expected Fraction or numeric");
                return error.TypeError;
            };
            var n = try valueToBig(a, f.num);
            errdefer n.deinit();
            var d = try valueToBig(a, f.den);
            errdefer d.deinit();
            return .{ .num = n, .den = d };
        },
        .small_int, .big_int, .boolean => {
            var n = try valueToBig(a, v);
            errdefer n.deinit();
            var d = try ZBig.initSet(a, 1);
            errdefer d.deinit();
            return .{ .num = n, .den = d };
        },
        .float => |f| {
            const r = try floatToRatio(a, f);
            return r;
        },
        else => {
            try interp.typeError("expected number");
            return error.TypeError;
        },
    }
}

/// Decompose an f64 into (numerator, 2^k * denominator) and reduce.
fn floatToRatio(a: std.mem.Allocator, f: f64) !Ratio {
    if (std.math.isNan(f)) return error.InvalidValue;
    if (std.math.isInf(f)) return error.InvalidValue;
    const bits: u64 = @bitCast(f);
    const sign: u1 = @intCast(bits >> 63);
    const exp_bits: u64 = (bits >> 52) & 0x7FF;
    const mant_bits: u64 = bits & ((@as(u64, 1) << 52) - 1);
    var m: u64 = undefined;
    var e: i32 = undefined;
    if (exp_bits == 0) {
        if (mant_bits == 0) {
            // ±0
            var z = try ZBig.initSet(a, 0);
            errdefer z.deinit();
            var o = try ZBig.initSet(a, 1);
            errdefer o.deinit();
            return .{ .num = z, .den = o };
        }
        m = mant_bits;
        e = -1074;
    } else {
        m = (@as(u64, 1) << 52) | mant_bits;
        e = @as(i32, @intCast(exp_bits)) - 1075;
    }
    var n = try ZBig.init(a);
    errdefer n.deinit();
    try n.set(m);
    var d = try ZBig.initSet(a, 1);
    errdefer d.deinit();
    if (e >= 0) {
        // n <<= e
        try shiftLeftBig(a, &n, @intCast(e));
    } else {
        // d <<= -e
        try shiftLeftBig(a, &d, @intCast(-e));
    }
    if (sign == 1) n.negate();
    try reduceInPlace(a, &n, &d);
    return .{ .num = n, .den = d };
}

fn shiftLeftBig(a: std.mem.Allocator, b: *ZBig, shift: usize) !void {
    var pow = try ZBig.initSet(a, 1);
    defer pow.deinit();
    var two = try ZBig.initSet(a, 2);
    defer two.deinit();
    var i: usize = 0;
    while (i < shift) : (i += 1) try pow.mul(&pow, &two);
    try b.mul(b, &pow);
}

// ===== __init__ =====

fn initFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) {
        try interp.typeError("Fraction.__init__: missing self");
        return error.TypeError;
    }
    const inst = args[0].instance;
    var n = try ZBig.initSet(a, 0);
    defer n.deinit();
    var d = try ZBig.initSet(a, 1);
    defer d.deinit();
    if (args.len == 1) {
        // Fraction() -> 0/1
    } else if (args.len == 2) {
        const r = try coerceArg(interp, args[1]);
        var rn = r.num;
        defer rn.deinit();
        var rd = r.den;
        defer rd.deinit();
        try n.copy(rn.toConst());
        try d.copy(rd.toConst());
    } else if (args.len == 3) {
        const ra = try coerceArg(interp, args[1]);
        var ran = ra.num;
        defer ran.deinit();
        var rad = ra.den;
        defer rad.deinit();
        const rb = try coerceArg(interp, args[2]);
        var rbn = rb.num;
        defer rbn.deinit();
        var rbd = rb.den;
        defer rbd.deinit();
        // Fraction(a, b) = (a.num * b.den) / (a.den * b.num).
        try n.mul(&ran, &rbd);
        try d.mul(&rad, &rbn);
    } else {
        try interp.typeError("Fraction takes 0..2 args");
        return error.TypeError;
    }
    try reduceInPlace(a, &n, &d);
    const nv = try bigToValue(a, &n);
    const dv = try bigToValue(a, &d);
    try inst.dict.setStr(a, "numerator", nv);
    try inst.dict.setStr(a, "denominator", dv);
    return Value.none;
}

/// Coerce a constructor argument: int/bool, float, str, or Fraction.
fn coerceArg(interp: *Interp, v: Value) !Ratio {
    const a = interp.allocator;
    switch (v) {
        .str => |s| {
            return try parseFractionString(a, s.bytes);
        },
        else => {
            return try coerceToFrac(interp, v);
        },
    }
}

fn parseFractionString(a: std.mem.Allocator, raw: []const u8) !Ratio {
    var s = raw;
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
    while (s.len > 0 and (s[s.len - 1] == ' ' or s[s.len - 1] == '\t')) s = s[0 .. s.len - 1];
    // Try "n/d" first.
    if (std.mem.indexOfScalar(u8, s, '/')) |slash| {
        var n = try ZBig.init(a);
        errdefer n.deinit();
        try n.setString(10, s[0..slash]);
        var d = try ZBig.init(a);
        errdefer d.deinit();
        try d.setString(10, s[slash + 1 ..]);
        return .{ .num = n, .den = d };
    }
    // Otherwise: integer or decimal-with-exponent.
    var sign: i64 = 1;
    var t = s;
    if (t.len > 0 and t[0] == '+') {
        t = t[1..];
    } else if (t.len > 0 and t[0] == '-') {
        sign = -1;
        t = t[1..];
    }
    var int_part: []const u8 = "";
    var frac_part: []const u8 = "";
    var i: usize = 0;
    const istart = i;
    while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) {}
    int_part = t[istart..i];
    if (i < t.len and t[i] == '.') {
        i += 1;
        const fstart = i;
        while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) {}
        frac_part = t[fstart..i];
    }
    var exp_v: i64 = 0;
    if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
        i += 1;
        var esign: i64 = 1;
        if (i < t.len and t[i] == '+') {
            i += 1;
        } else if (i < t.len and t[i] == '-') {
            esign = -1;
            i += 1;
        }
        var ev: i64 = 0;
        while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) {
            ev = ev * 10 + @as(i64, @intCast(t[i] - '0'));
        }
        exp_v = esign * ev;
    }
    if (int_part.len == 0 and frac_part.len == 0) return error.InvalidValue;
    // Numerator string = int_part ++ frac_part. Then exp -= len(frac_part).
    const buf = try a.alloc(u8, int_part.len + frac_part.len);
    defer a.free(buf);
    @memcpy(buf[0..int_part.len], int_part);
    @memcpy(buf[int_part.len..], frac_part);
    var n = try ZBig.init(a);
    errdefer n.deinit();
    if (buf.len == 0) {
        try n.set(0);
    } else {
        try n.setString(10, buf);
    }
    var d = try ZBig.initSet(a, 1);
    errdefer d.deinit();
    const total_exp = exp_v - @as(i64, @intCast(frac_part.len));
    var ten = try ZBig.initSet(a, 10);
    defer ten.deinit();
    if (total_exp >= 0) {
        var k: i64 = 0;
        while (k < total_exp) : (k += 1) try n.mul(&n, &ten);
    } else {
        var k: i64 = 0;
        while (k < -total_exp) : (k += 1) try d.mul(&d, &ten);
    }
    if (sign == -1) n.negate();
    return .{ .num = n, .den = d };
}

// ===== __repr__ / __str__ =====

fn reprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const f = readFrac(args[0]) orelse return error.TypeError;
    const ns = try valueIntToStr(a, f.num);
    defer a.free(ns);
    const ds = try valueIntToStr(a, f.den);
    defer a.free(ds);
    const out = try std.fmt.allocPrint(a, "Fraction({s}, {s})", .{ ns, ds });
    return Value{ .str = try Str.fromOwnedSlice(a, out) };
}

fn strFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const f = readFrac(args[0]) orelse return error.TypeError;
    const ns = try valueIntToStr(a, f.num);
    defer a.free(ns);
    const den_one = (f.den == .small_int and f.den.small_int == 1);
    if (den_one) {
        const out = try a.dupe(u8, ns);
        return Value{ .str = try Str.fromOwnedSlice(a, out) };
    }
    const ds = try valueIntToStr(a, f.den);
    defer a.free(ds);
    const out = try std.fmt.allocPrint(a, "{s}/{s}", .{ ns, ds });
    return Value{ .str = try Str.fromOwnedSlice(a, out) };
}

fn valueIntToStr(a: std.mem.Allocator, v: Value) ![]u8 {
    return switch (v) {
        .small_int => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .big_int => |bi| try bi.toString10(a),
        .boolean => |b| try a.dupe(u8, if (b) "1" else "0"),
        else => return error.TypeError,
    };
}

// ===== Arithmetic =====

fn opDispatch(interp: *Interp, args: []const Value, comptime op: enum { add, sub, rsub, mul, div, rdiv, floordiv, rfloordiv, mod, rmod, pow }) !Value {
    if (args.len != 2) return error.TypeError;
    const a = interp.allocator;
    var l = try coerceToFrac(interp, args[0]);
    defer {
        l.num.deinit();
        l.den.deinit();
    }
    var r = try coerceToFrac(interp, args[1]);
    defer {
        r.num.deinit();
        r.den.deinit();
    }
    var n = try ZBig.init(a);
    defer n.deinit();
    var d = try ZBig.init(a);
    defer d.deinit();
    switch (op) {
        .add => {
            // (l.n*r.d + r.n*l.d) / (l.d*r.d)
            var t1 = try ZBig.init(a);
            defer t1.deinit();
            var t2 = try ZBig.init(a);
            defer t2.deinit();
            try t1.mul(&l.num, &r.den);
            try t2.mul(&r.num, &l.den);
            try n.add(&t1, &t2);
            try d.mul(&l.den, &r.den);
        },
        .sub => {
            var t1 = try ZBig.init(a);
            defer t1.deinit();
            var t2 = try ZBig.init(a);
            defer t2.deinit();
            try t1.mul(&l.num, &r.den);
            try t2.mul(&r.num, &l.den);
            try n.sub(&t1, &t2);
            try d.mul(&l.den, &r.den);
        },
        .rsub => {
            // r - l (used when called as args[0].__rsub__(args[1])
            // — i.e. args[1] - args[0])
            var t1 = try ZBig.init(a);
            defer t1.deinit();
            var t2 = try ZBig.init(a);
            defer t2.deinit();
            try t1.mul(&r.num, &l.den);
            try t2.mul(&l.num, &r.den);
            try n.sub(&t1, &t2);
            try d.mul(&l.den, &r.den);
        },
        .mul => {
            try n.mul(&l.num, &r.num);
            try d.mul(&l.den, &r.den);
        },
        .div => {
            try n.mul(&l.num, &r.den);
            try d.mul(&l.den, &r.num);
            if (d.eqlZero()) {
                try interp.raisePy("ZeroDivisionError", "Fraction division by zero");
                return error.PyException;
            }
        },
        .rdiv => {
            // (args[1] / args[0]) -- the Fraction is on the right of /.
            try n.mul(&r.num, &l.den);
            try d.mul(&r.den, &l.num);
            if (d.eqlZero()) {
                try interp.raisePy("ZeroDivisionError", "Fraction division by zero");
                return error.PyException;
            }
        },
        .floordiv, .mod, .rfloordiv, .rmod => {
            // Compute divmod of (a/b) by (c/d): floor((a*d)/(b*c))
            // and remainder = (a/b) - q*(c/d).
            const lhs_n = if (op == .rfloordiv or op == .rmod) &r.num else &l.num;
            const lhs_d = if (op == .rfloordiv or op == .rmod) &r.den else &l.den;
            const rhs_n = if (op == .rfloordiv or op == .rmod) &l.num else &r.num;
            const rhs_d = if (op == .rfloordiv or op == .rmod) &l.den else &r.den;
            if (rhs_n.eqlZero()) {
                try interp.raisePy("ZeroDivisionError", "Fraction division by zero");
                return error.PyException;
            }
            var num = try ZBig.init(a);
            defer num.deinit();
            try num.mul(lhs_n, rhs_d);
            var den = try ZBig.init(a);
            defer den.deinit();
            try den.mul(lhs_d, rhs_n);
            // Adjust sign: Python floor toward -inf. divFloor handles
            // signed numerator, but `den` may be negative. Force den>0.
            if (!den.isPositive()) {
                den.negate();
                num.negate();
            }
            var q = try ZBig.init(a);
            defer q.deinit();
            var rem = try ZBig.init(a);
            defer rem.deinit();
            try q.divFloor(&rem, &num, &den);
            if (op == .floordiv or op == .rfloordiv) {
                var one = try ZBig.initSet(a, 1);
                defer one.deinit();
                return try newFraction(interp, &q, &one);
            }
            // mod = lhs - q * rhs. As fraction: lhs.n/lhs.d - q*(rhs.n/rhs.d)
            // = (lhs.n * rhs.d - q * rhs.n * lhs.d) / (lhs.d * rhs.d)
            var t1 = try ZBig.init(a);
            defer t1.deinit();
            try t1.mul(lhs_n, rhs_d);
            var t2 = try ZBig.init(a);
            defer t2.deinit();
            try t2.mul(&q, rhs_n);
            try t2.mul(&t2, lhs_d);
            try n.sub(&t1, &t2);
            try d.mul(lhs_d, rhs_d);
        },
        .pow => {
            // Only integer exponents (simplest case for fixture).
            // For Fraction**Fraction with integer exponent denominator,
            // CPython falls back to float when the exponent isn't an
            // integer. The fixture exercises both paths.
            const exp_is_int = blk: {
                if (r.den.toInt(i64)) |v| {
                    break :blk v == 1;
                } else |_| break :blk false;
            };
            if (!exp_is_int) {
                // Float fallback: float(self) ** float(other).
                const base_f = try fracToFloat(&l.num, &l.den);
                const exp_f = try fracToFloat(&r.num, &r.den);
                return Value{ .float = std.math.pow(f64, base_f, exp_f) };
            }
            // r is integer; sign in r.num.
            const exp_int = r.num.toInt(i64) catch {
                try interp.typeError("Fraction ** : exponent too large");
                return error.TypeError;
            };
            if (exp_int == 0) {
                var one = try ZBig.initSet(a, 1);
                defer one.deinit();
                return try newFraction(interp, &one, &one);
            }
            const negative = exp_int < 0;
            const k: u64 = if (negative) @intCast(-exp_int) else @intCast(exp_int);
            const new_n = try powInt(a, &l.num, k);
            const new_d = try powInt(a, &l.den, k);
            try n.copy(new_n.toConst());
            var new_n_mut = new_n;
            new_n_mut.deinit();
            try d.copy(new_d.toConst());
            var new_d_mut = new_d;
            new_d_mut.deinit();
            if (negative) {
                // Swap n and d.
                var tmp = try ZBig.init(a);
                defer tmp.deinit();
                try tmp.copy(n.toConst());
                try n.copy(d.toConst());
                try d.copy(tmp.toConst());
            }
        },
    }
    return try newFraction(interp, &n, &d);
}

fn powInt(a: std.mem.Allocator, base_in: *const ZBig, k_in: u64) !ZBig {
    var result = try ZBig.initSet(a, 1);
    errdefer result.deinit();
    var base = try ZBig.init(a);
    defer base.deinit();
    try base.copy(base_in.toConst());
    var k = k_in;
    while (k > 0) : (k >>= 1) {
        if ((k & 1) == 1) try result.mul(&result, &base);
        if (k > 1) try base.mul(&base, &base);
    }
    return result;
}

fn fracToFloat(num: *const ZBig, den: *const ZBig) !f64 {
    const n_f = num.toFloat(f64, .nearest_even);
    const d_f = den.toFloat(f64, .nearest_even);
    return n_f[0] / d_f[0];
}

fn addFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return opDispatch(@as(*Interp, @ptrCast(@alignCast(p))), args, .add);
}
fn subFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return opDispatch(@as(*Interp, @ptrCast(@alignCast(p))), args, .sub);
}
fn rsubFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return opDispatch(@as(*Interp, @ptrCast(@alignCast(p))), args, .rsub);
}
fn mulFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return opDispatch(@as(*Interp, @ptrCast(@alignCast(p))), args, .mul);
}
fn divFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return opDispatch(@as(*Interp, @ptrCast(@alignCast(p))), args, .div);
}
fn rdivFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return opDispatch(@as(*Interp, @ptrCast(@alignCast(p))), args, .rdiv);
}
fn floordivFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return opDispatch(@as(*Interp, @ptrCast(@alignCast(p))), args, .floordiv);
}
fn rfloordivFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return opDispatch(@as(*Interp, @ptrCast(@alignCast(p))), args, .rfloordiv);
}
fn modFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return opDispatch(@as(*Interp, @ptrCast(@alignCast(p))), args, .mod);
}
fn rmodFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return opDispatch(@as(*Interp, @ptrCast(@alignCast(p))), args, .rmod);
}
fn powFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return opDispatch(@as(*Interp, @ptrCast(@alignCast(p))), args, .pow);
}

// ===== Unary =====

fn negFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const f = readFrac(args[0]) orelse return error.TypeError;
    var n = try valueToBig(a, f.num);
    defer n.deinit();
    var d = try valueToBig(a, f.den);
    defer d.deinit();
    n.negate();
    return try newFraction(interp, &n, &d);
}

fn posFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const f = readFrac(args[0]) orelse return error.TypeError;
    var n = try valueToBig(a, f.num);
    defer n.deinit();
    var d = try valueToBig(a, f.den);
    defer d.deinit();
    return try newFraction(interp, &n, &d);
}

fn absFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const f = readFrac(args[0]) orelse return error.TypeError;
    var n = try valueToBig(a, f.num);
    defer n.deinit();
    var d = try valueToBig(a, f.den);
    defer d.deinit();
    if (!n.isPositive() and !n.eqlZero()) n.negate();
    return try newFraction(interp, &n, &d);
}

fn boolFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const f = readFrac(args[0]) orelse return error.TypeError;
    return Value{ .boolean = !valueIntIsZero(f.num) };
}

fn valueIntIsZero(v: Value) bool {
    return switch (v) {
        .small_int => |i| i == 0,
        .big_int => |bi| bi.inner.eqlZero(),
        .boolean => |b| !b,
        else => false,
    };
}

fn intFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const f = readFrac(args[0]) orelse return error.TypeError;
    var n = try valueToBig(a, f.num);
    defer n.deinit();
    var d = try valueToBig(a, f.den);
    defer d.deinit();
    // Truncate toward zero: q = trunc(n/d). Python int(Fraction) is
    // toward zero, not floor.
    const negative = !n.isPositive() and !n.eqlZero();
    if (negative) n.negate();
    var q = try ZBig.init(a);
    defer q.deinit();
    var r = try ZBig.init(a);
    defer r.deinit();
    try q.divFloor(&r, &n, &d);
    if (negative) q.negate();
    return try bigToValue(a, &q);
}

fn floatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const f = readFrac(args[0]) orelse return error.TypeError;
    const a = std.heap.page_allocator;
    var n = try valueToBig(a, f.num);
    defer n.deinit();
    var d = try valueToBig(a, f.den);
    defer d.deinit();
    return Value{ .float = try fracToFloat(&n, &d) };
}

// ===== floor / ceil / trunc =====

fn floorMethodFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const f = readFrac(args[0]) orelse return error.TypeError;
    var n = try valueToBig(a, f.num);
    defer n.deinit();
    var d = try valueToBig(a, f.den);
    defer d.deinit();
    var q = try ZBig.init(a);
    defer q.deinit();
    var rem = try ZBig.init(a);
    defer rem.deinit();
    try q.divFloor(&rem, &n, &d);
    return try bigToValue(a, &q);
}

fn ceilMethodFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const f = readFrac(args[0]) orelse return error.TypeError;
    var n = try valueToBig(a, f.num);
    defer n.deinit();
    var d = try valueToBig(a, f.den);
    defer d.deinit();
    // ceil(n/d) = -floor(-n/d) = (n + d - 1)/d for n>=0; or floor + 1 if not exact.
    var q = try ZBig.init(a);
    defer q.deinit();
    var rem = try ZBig.init(a);
    defer rem.deinit();
    try q.divFloor(&rem, &n, &d);
    if (!rem.eqlZero()) {
        var one = try ZBig.initSet(a, 1);
        defer one.deinit();
        try q.add(&q, &one);
    }
    return try bigToValue(a, &q);
}

fn truncMethodFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return intFn(p, args);
}

fn roundMethodFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args.len > 2) return error.TypeError;
    const f = readFrac(args[0]) orelse return error.TypeError;
    if (args.len == 1 or (args.len == 2 and args[1] == .none)) {
        return try roundToInt(interp, f);
    }
    if (args[1] != .small_int) {
        try interp.typeError("round: ndigits must be int");
        return error.TypeError;
    }
    const ndigits = args[1].small_int;
    // round(self, ndigits) = self.__round__(ndigits) -> Fraction.
    // Multiply by 10^ndigits, round to int (half-even), divide back.
    var n = try valueToBig(a, f.num);
    defer n.deinit();
    var d = try valueToBig(a, f.den);
    defer d.deinit();
    var ten = try ZBig.initSet(a, 10);
    defer ten.deinit();
    if (ndigits > 0) {
        var k: i64 = 0;
        while (k < ndigits) : (k += 1) try n.mul(&n, &ten);
    } else {
        var k: i64 = 0;
        while (k < -ndigits) : (k += 1) try d.mul(&d, &ten);
    }
    // Round n/d half-to-even.
    var rounded = try roundHalfEven(a, &n, &d);
    defer rounded.deinit();
    // Result: rounded / 10^ndigits.
    var den_pow = try ZBig.initSet(a, 1);
    defer den_pow.deinit();
    if (ndigits > 0) {
        var k: i64 = 0;
        while (k < ndigits) : (k += 1) try den_pow.mul(&den_pow, &ten);
    } else if (ndigits < 0) {
        // den = 1, but the integer value is multiplied by 10^|ndigits|.
        var k: i64 = 0;
        while (k < -ndigits) : (k += 1) try rounded.mul(&rounded, &ten);
    }
    return try newFraction(interp, &rounded, &den_pow);
}

fn roundToInt(interp: *Interp, f: Frac) !Value {
    const a = interp.allocator;
    var n = try valueToBig(a, f.num);
    defer n.deinit();
    var d = try valueToBig(a, f.den);
    defer d.deinit();
    var rounded = try roundHalfEven(a, &n, &d);
    defer rounded.deinit();
    return try bigToValue(a, &rounded);
}

/// Half-to-even rounding of n/d (with d>0, n any sign) to a ZBig.
fn roundHalfEven(a: std.mem.Allocator, n: *const ZBig, d: *const ZBig) !ZBig {
    var nn = try ZBig.init(a);
    defer nn.deinit();
    try nn.copy(n.toConst());
    var dd = try ZBig.init(a);
    defer dd.deinit();
    try dd.copy(d.toConst());
    // Force d > 0.
    if (!dd.isPositive()) {
        dd.negate();
        nn.negate();
    }
    var q = try ZBig.init(a);
    errdefer q.deinit();
    var r = try ZBig.init(a);
    defer r.deinit();
    try q.divFloor(&r, &nn, &dd);
    if (r.eqlZero()) return q;
    // Compare 2*r to d.
    var two = try ZBig.initSet(a, 2);
    defer two.deinit();
    var two_r = try ZBig.init(a);
    defer two_r.deinit();
    try two_r.mul(&r, &two);
    const ord = two_r.order(dd);
    var bump = false;
    if (ord == .gt) {
        bump = true;
    } else if (ord == .eq) {
        // Half: round to even. Bump if q is odd.
        var two2 = try ZBig.initSet(a, 2);
        defer two2.deinit();
        var qq = try ZBig.init(a);
        defer qq.deinit();
        var rr = try ZBig.init(a);
        defer rr.deinit();
        try qq.divFloor(&rr, &q, &two2);
        if (!rr.eqlZero()) bump = true;
    }
    if (bump) {
        var one = try ZBig.initSet(a, 1);
        defer one.deinit();
        try q.add(&q, &one);
    }
    return q;
}

// ===== Comparison =====

fn cmpFrac(a: std.mem.Allocator, l_n: *ZBig, l_d: *ZBig, r_n: *ZBig, r_d: *ZBig) !std.math.Order {
    var t1 = try ZBig.init(a);
    defer t1.deinit();
    var t2 = try ZBig.init(a);
    defer t2.deinit();
    try t1.mul(l_n, r_d);
    try t2.mul(r_n, l_d);
    return t1.order(t2);
}

fn eqFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    var l = try coerceToFrac(interp, args[0]);
    defer {
        l.num.deinit();
        l.den.deinit();
    }
    var r = coerceToFrac(interp, args[1]) catch {
        return Value{ .boolean = false };
    };
    defer {
        r.num.deinit();
        r.den.deinit();
    }
    const o = try cmpFrac(a, &l.num, &l.den, &r.num, &r.den);
    return Value{ .boolean = o == .eq };
}
fn neFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const eq = try eqFn(p, args);
    return Value{ .boolean = !eq.boolean };
}
fn ltFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    var l = try coerceToFrac(interp, args[0]);
    defer {
        l.num.deinit();
        l.den.deinit();
    }
    var r = try coerceToFrac(interp, args[1]);
    defer {
        r.num.deinit();
        r.den.deinit();
    }
    const o = try cmpFrac(a, &l.num, &l.den, &r.num, &r.den);
    return Value{ .boolean = o == .lt };
}
fn leFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    var l = try coerceToFrac(interp, args[0]);
    defer {
        l.num.deinit();
        l.den.deinit();
    }
    var r = try coerceToFrac(interp, args[1]);
    defer {
        r.num.deinit();
        r.den.deinit();
    }
    const o = try cmpFrac(a, &l.num, &l.den, &r.num, &r.den);
    return Value{ .boolean = o == .lt or o == .eq };
}
fn gtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    var l = try coerceToFrac(interp, args[0]);
    defer {
        l.num.deinit();
        l.den.deinit();
    }
    var r = try coerceToFrac(interp, args[1]);
    defer {
        r.num.deinit();
        r.den.deinit();
    }
    const o = try cmpFrac(a, &l.num, &l.den, &r.num, &r.den);
    return Value{ .boolean = o == .gt };
}
fn geFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    var l = try coerceToFrac(interp, args[0]);
    defer {
        l.num.deinit();
        l.den.deinit();
    }
    var r = try coerceToFrac(interp, args[1]);
    defer {
        r.num.deinit();
        r.den.deinit();
    }
    const o = try cmpFrac(a, &l.num, &l.den, &r.num, &r.den);
    return Value{ .boolean = o == .gt or o == .eq };
}

// ===== Misc methods =====

fn asIntegerRatioFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const f = readFrac(args[0]) orelse return error.TypeError;
    const t = try Tuple.init(a, 2);
    t.items[0] = f.num;
    t.items[1] = f.den;
    return Value{ .tuple = t };
}

fn isIntegerFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const f = readFrac(args[0]) orelse return error.TypeError;
    return Value{ .boolean = f.den == .small_int and f.den.small_int == 1 };
}

fn limitDenominatorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const f = readFrac(args[0]) orelse return error.TypeError;
    if (args.len < 2) {
        try interp.typeError("limit_denominator requires max_denominator");
        return error.TypeError;
    }
    var max_d = try valueToBig(a, args[1]);
    defer max_d.deinit();
    var one = try ZBig.initSet(a, 1);
    defer one.deinit();
    if (max_d.order(one) == .lt) {
        try interp.raisePy("ValueError", "max_denominator must be >= 1");
        return error.PyException;
    }
    var n = try valueToBig(a, f.num);
    defer n.deinit();
    var d = try valueToBig(a, f.den);
    defer d.deinit();
    if (d.order(max_d) != .gt) {
        // Already small enough.
        return try newFraction(interp, &n, &d);
    }
    // p0,q0 = 0,1; p1,q1 = 1,0. Compute continued-fraction convergents.
    var p0 = try ZBig.initSet(a, 0);
    defer p0.deinit();
    var q0 = try ZBig.initSet(a, 1);
    defer q0.deinit();
    var p1 = try ZBig.initSet(a, 1);
    defer p1.deinit();
    var q1 = try ZBig.initSet(a, 0);
    defer q1.deinit();
    var nn = try ZBig.init(a);
    defer nn.deinit();
    try nn.copy(n.toConst());
    var dd = try ZBig.init(a);
    defer dd.deinit();
    try dd.copy(d.toConst());
    // For limit_denominator we work with absolute value of n;
    // the sign re-attaches at the end.
    const negative = !nn.isPositive() and !nn.eqlZero();
    if (negative) nn.negate();
    while (true) {
        var aa = try ZBig.init(a);
        defer aa.deinit();
        var rr = try ZBig.init(a);
        defer rr.deinit();
        try aa.divFloor(&rr, &nn, &dd);
        // q2 = q0 + a * q1
        var q2 = try ZBig.init(a);
        defer q2.deinit();
        try q2.mul(&aa, &q1);
        try q2.add(&q2, &q0);
        if (q2.order(max_d) == .gt) break;
        // p0,q0 = p1,q1; p1,q1 = p0+a*p1, q2.
        var new_p1 = try ZBig.init(a);
        defer new_p1.deinit();
        try new_p1.mul(&aa, &p1);
        try new_p1.add(&new_p1, &p0);
        // Shift state.
        try p0.copy(p1.toConst());
        try q0.copy(q1.toConst());
        try p1.copy(new_p1.toConst());
        try q1.copy(q2.toConst());
        // n,d = d, n - a*d
        var ad = try ZBig.init(a);
        defer ad.deinit();
        try ad.mul(&aa, &dd);
        var new_n = try ZBig.init(a);
        defer new_n.deinit();
        try new_n.sub(&nn, &ad);
        try nn.copy(dd.toConst());
        try dd.copy(new_n.toConst());
        if (dd.eqlZero()) break;
    }
    // k = (max_d - q0) // q1
    var k = try ZBig.init(a);
    defer k.deinit();
    var diff = try ZBig.init(a);
    defer diff.deinit();
    try diff.sub(&max_d, &q0);
    var rem_k = try ZBig.init(a);
    defer rem_k.deinit();
    try k.divFloor(&rem_k, &diff, &q1);
    // bound1 = (p0 + k*p1) / (q0 + k*q1).
    var b1n = try ZBig.init(a);
    defer b1n.deinit();
    try b1n.mul(&k, &p1);
    try b1n.add(&b1n, &p0);
    var b1d = try ZBig.init(a);
    defer b1d.deinit();
    try b1d.mul(&k, &q1);
    try b1d.add(&b1d, &q0);
    // bound2 = p1 / q1.
    var b2n = try ZBig.init(a);
    defer b2n.deinit();
    try b2n.copy(p1.toConst());
    var b2d = try ZBig.init(a);
    defer b2d.deinit();
    try b2d.copy(q1.toConst());
    // self_abs = |n| / d.
    // Compute |bound2 - self_abs| and |bound1 - self_abs|, pick smaller.
    var self_n = try ZBig.init(a);
    defer self_n.deinit();
    try self_n.copy(n.toConst());
    if (negative) self_n.negate();
    if (negative) {
        // For comparison/abs we used positive; final result wears the
        // sign by negating the chosen numerator at the end.
        self_n.negate();
    }
    // |b2 - self| vs |b1 - self|: use cross-multiplication and
    // compare magnitudes of numerators (denominators are positive).
    // diff_b2 = b2.n*d - self.n*b2.d ; over (b2.d * d)
    var diff2_n = try ZBig.init(a);
    defer diff2_n.deinit();
    var t_a = try ZBig.init(a);
    defer t_a.deinit();
    try t_a.mul(&b2n, &d);
    var t_b = try ZBig.init(a);
    defer t_b.deinit();
    try t_b.mul(&self_n, &b2d);
    try diff2_n.sub(&t_a, &t_b);
    var abs_d2 = try ZBig.init(a);
    defer abs_d2.deinit();
    try abs_d2.copy(diff2_n.toConst());
    if (!abs_d2.isPositive() and !abs_d2.eqlZero()) abs_d2.negate();
    var diff1_n = try ZBig.init(a);
    defer diff1_n.deinit();
    var t_c = try ZBig.init(a);
    defer t_c.deinit();
    try t_c.mul(&b1n, &d);
    var t_d = try ZBig.init(a);
    defer t_d.deinit();
    try t_d.mul(&self_n, &b1d);
    try diff1_n.sub(&t_c, &t_d);
    var abs_d1 = try ZBig.init(a);
    defer abs_d1.deinit();
    try abs_d1.copy(diff1_n.toConst());
    if (!abs_d1.isPositive() and !abs_d1.eqlZero()) abs_d1.negate();
    // |b2 - self| / (b2.d * d) vs |b1 - self| / (b1.d * d).
    // Cross-multiply: abs_d2 * (b1.d * d) vs abs_d1 * (b2.d * d).
    // Equivalent: abs_d2 * b1.d vs abs_d1 * b2.d (cancel d).
    var lhs = try ZBig.init(a);
    defer lhs.deinit();
    try lhs.mul(&abs_d2, &b1d);
    var rhs = try ZBig.init(a);
    defer rhs.deinit();
    try rhs.mul(&abs_d1, &b2d);
    var chosen_n = try ZBig.init(a);
    defer chosen_n.deinit();
    var chosen_d = try ZBig.init(a);
    defer chosen_d.deinit();
    if (lhs.order(rhs) != .gt) {
        // |b2 - self| <= |b1 - self|: pick bound2.
        try chosen_n.copy(b2n.toConst());
        try chosen_d.copy(b2d.toConst());
    } else {
        try chosen_n.copy(b1n.toConst());
        try chosen_d.copy(b1d.toConst());
    }
    if (negative) chosen_n.negate();
    return try newFraction(interp, &chosen_n, &chosen_d);
}

// ===== Classmethods =====

fn fromFloatCls(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const v = args[1];
    var n: ZBig = undefined;
    var d: ZBig = undefined;
    switch (v) {
        .float => |fv| {
            const r = try floatToRatio(a, fv);
            n = r.num;
            d = r.den;
        },
        .small_int, .big_int, .boolean => {
            n = try valueToBig(a, v);
            d = try ZBig.initSet(a, 1);
        },
        else => return error.TypeError,
    }
    defer n.deinit();
    defer d.deinit();
    return try newFraction(interp, &n, &d);
}

fn fromDecimalCls(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const v = args[1];
    if (v == .small_int or v == .big_int or v == .boolean) {
        var n = try valueToBig(a, v);
        defer n.deinit();
        var one = try ZBig.initSet(a, 1);
        defer one.deinit();
        return try newFraction(interp, &n, &one);
    }
    if (v != .instance) {
        try interp.typeError("from_decimal: expected Decimal or int");
        return error.TypeError;
    }
    const inst = v.instance;
    const sign_v = inst.dict.getStr("_sign") orelse {
        try interp.typeError("from_decimal: not a Decimal");
        return error.TypeError;
    };
    const coeff_v = inst.dict.getStr("_coeff") orelse return error.TypeError;
    const exp_v = inst.dict.getStr("_exp") orelse return error.TypeError;
    if (sign_v != .small_int or coeff_v != .str or exp_v != .small_int) return error.TypeError;
    const coeff = coeff_v.str.bytes;
    var n = try ZBig.init(a);
    defer n.deinit();
    if (coeff.len == 0) {
        try n.set(0);
    } else {
        try n.setString(10, coeff);
    }
    if (sign_v.small_int == 1) n.negate();
    var d = try ZBig.initSet(a, 1);
    defer d.deinit();
    var ten = try ZBig.initSet(a, 10);
    defer ten.deinit();
    const ev = exp_v.small_int;
    if (ev >= 0) {
        var k: i64 = 0;
        while (k < ev) : (k += 1) try n.mul(&n, &ten);
    } else {
        var k: i64 = 0;
        while (k < -ev) : (k += 1) try d.mul(&d, &ten);
    }
    return try newFraction(interp, &n, &d);
}

fn fromNumberCls(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const v = args[1];
    var r = try coerceToFrac(interp, v);
    defer {
        r.num.deinit();
        r.den.deinit();
    }
    _ = a;
    return try newFraction(interp, &r.num, &r.den);
}
