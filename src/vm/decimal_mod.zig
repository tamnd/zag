//! Pinhole `decimal` module: enough surface for the 134_decimal
//! fixture. Decimal values are class instances carrying four dict
//! slots: `_sign` (0/1), `_coeff` (digit string), `_exp` (i64), and
//! `_special` (0=finite, 1=Inf, 2=qNaN, 3=sNaN). All arithmetic runs
//! on big-int coefficients; printing follows CPython's `__str__`
//! rules (engineering notation when `exp > 0` or `adjusted < -6`).
//!
//! Context state lives on a single `decimal_active_context` Value on
//! the interp; `localcontext()` is a context manager that swaps that
//! pointer on `__enter__`/`__exit__`.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Tuple = @import("../object/tuple.zig").Tuple;
const List = @import("../object/list.zig").List;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const BigInt = std.math.big.int.Managed;

const SPECIAL_FINITE: i64 = 0;
const SPECIAL_INF: i64 = 1;
const SPECIAL_QNAN: i64 = 2;
const SPECIAL_SNAN: i64 = 3;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);
    const m = try Module.init(a, "decimal");
    try m.attrs.setStr(a, "Decimal", Value{ .class = interp.decimal_class.? });
    try m.attrs.setStr(a, "Context", Value{ .class = interp.decimal_context_class.? });
    try m.attrs.setStr(a, "InvalidOperation", Value{ .class = interp.decimal_invalid_op_class.? });
    try m.attrs.setStr(a, "DivisionByZero", Value{ .class = interp.decimal_div_zero_class.? });
    try m.attrs.setStr(a, "Overflow", Value{ .class = interp.decimal_overflow_class.? });

    inline for (.{
        "ROUND_UP", "ROUND_DOWN", "ROUND_CEILING", "ROUND_FLOOR",
        "ROUND_HALF_UP", "ROUND_HALF_DOWN", "ROUND_HALF_EVEN", "ROUND_05UP",
    }) |name| {
        const s = try Str.init(a, name);
        try m.attrs.setStr(a, name, Value{ .str = s });
    }

    try reg(interp, m, "getcontext", getcontextFn);
    try reg(interp, m, "setcontext", setcontextFn);
    try reg(interp, m, "localcontext", localcontextFn);

    // Default/Basic/Extended contexts.
    const default_ctx = try makeContext(interp, 28, "ROUND_HALF_EVEN");
    const basic_ctx = try makeContext(interp, 9, "ROUND_HALF_UP");
    const ext_ctx = try makeContext(interp, 9, "ROUND_HALF_EVEN");
    try m.attrs.setStr(a, "DefaultContext", default_ctx);
    try m.attrs.setStr(a, "BasicContext", basic_ctx);
    try m.attrs.setStr(a, "ExtendedContext", ext_ctx);

    // The active context starts as a copy of DefaultContext.
    if (interp.decimal_active_context == null) {
        const active = try makeContext(interp, 28, "ROUND_HALF_EVEN");
        interp.decimal_active_context = active;
    }
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn methodReg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn methodRegKw(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn ensureClasses(interp: *Interp) !void {
    if (interp.decimal_class != null) return;
    const a = interp.allocator;

    // DivisionByZero, InvalidOperation, Overflow extend ArithmeticError.
    const arith_v = interp.builtins.getStr("ArithmeticError") orelse return error.TypeError;
    if (arith_v != .class) return error.TypeError;
    const arith_cls = arith_v.class;

    {
        const d = try Dict.init(a);
        interp.decimal_invalid_op_class = try Class.init(a, "InvalidOperation", &.{arith_cls}, d);
    }
    {
        const d = try Dict.init(a);
        interp.decimal_div_zero_class = try Class.init(a, "DivisionByZero", &.{arith_cls}, d);
    }
    {
        const d = try Dict.init(a);
        interp.decimal_overflow_class = try Class.init(a, "Overflow", &.{arith_cls}, d);
    }

    // DecimalTuple is a thin holder for as_tuple().
    {
        const d = try Dict.init(a);
        interp.decimal_tuple_class = try Class.init(a, "DecimalTuple", &.{}, d);
    }

    // Context class. Prec/rounding live as instance attrs so the
    // fixture's `ctx.prec = 3` works through the regular setattr path.
    {
        const d = try Dict.init(a);
        try methodReg(a, d, "__enter__", ctxEnterFn);
        try methodReg(a, d, "__exit__", ctxExitFn);
        interp.decimal_context_class = try Class.init(a, "Context", &.{}, d);
    }

    // Decimal class.
    {
        const d = try Dict.init(a);
        try methodReg(a, d, "__init__", decimalInitFn);
        try methodReg(a, d, "__repr__", decimalReprFn);
        try methodReg(a, d, "__str__", decimalStrFn);
        try methodReg(a, d, "__add__", decimalAddFn);
        try methodReg(a, d, "__radd__", decimalAddFn);
        try methodReg(a, d, "__sub__", decimalSubFn);
        try methodReg(a, d, "__rsub__", decimalRsubFn);
        try methodReg(a, d, "__mul__", decimalMulFn);
        try methodReg(a, d, "__rmul__", decimalMulFn);
        try methodReg(a, d, "__truediv__", decimalDivFn);
        try methodReg(a, d, "__floordiv__", decimalFloorDivFn);
        try methodReg(a, d, "__mod__", decimalModFn);
        try methodReg(a, d, "__pow__", decimalPowFn);
        try methodReg(a, d, "__neg__", decimalNegFn);
        try methodReg(a, d, "__pos__", decimalPosFn);
        try methodReg(a, d, "__abs__", decimalAbsFn);
        try methodReg(a, d, "__eq__", decimalEqFn);
        try methodReg(a, d, "__ne__", decimalNeFn);
        try methodReg(a, d, "__lt__", decimalLtFn);
        try methodReg(a, d, "__le__", decimalLeFn);
        try methodReg(a, d, "__gt__", decimalGtFn);
        try methodReg(a, d, "__ge__", decimalGeFn);
        try methodReg(a, d, "__bool__", decimalBoolFn);
        try methodReg(a, d, "__int__", decimalIntFn);
        try methodReg(a, d, "__float__", decimalFloatFn);
        try methodRegKw(a, d, "quantize", quantizeFn, quantizeKw);
        try methodRegKw(a, d, "to_integral_value", toIntegralFn, toIntegralKw);
        try methodReg(a, d, "adjusted", adjustedFn);
        try methodReg(a, d, "as_tuple", asTupleFn);
        try methodReg(a, d, "normalize", normalizeFn);
        try methodReg(a, d, "sqrt", sqrtFn);
        try methodReg(a, d, "compare", compareFn);
        try methodReg(a, d, "copy_sign", copySignFn);
        try methodReg(a, d, "max", maxFn);
        try methodReg(a, d, "min", minFn);
        try methodReg(a, d, "is_finite", isFiniteFn);
        try methodReg(a, d, "is_infinite", isInfiniteFn);
        try methodReg(a, d, "is_nan", isNanFn);
        try methodReg(a, d, "is_qnan", isQnanFn);
        try methodReg(a, d, "is_snan", isSnanFn);
        try methodReg(a, d, "is_signed", isSignedFn);
        try methodReg(a, d, "is_zero", isZeroFn);
        try methodReg(a, d, "is_normal", isNormalFn);
        interp.decimal_class = try Class.init(a, "Decimal", &.{}, d);
    }
}

fn makeContext(interp: *Interp, prec: i64, rounding: []const u8) !Value {
    const a = interp.allocator;
    const cls = interp.decimal_context_class.?;
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "prec", Value{ .small_int = prec });
    const r = try Str.init(a, rounding);
    try inst.dict.setStr(a, "rounding", Value{ .str = r });
    return Value{ .instance = inst };
}

// ===== Decimal helpers =====

const Dec = struct {
    sign: u1, // 0 or 1
    coeff: []const u8, // digit string
    exp: i64,
    special: i64, // 0 finite, 1 inf, 2 qnan, 3 snan
};

fn readDec(v: Value) ?Dec {
    if (v != .instance) return null;
    const inst = v.instance;
    const sv = inst.dict.getStr("_sign") orelse return null;
    const cv = inst.dict.getStr("_coeff") orelse return null;
    const ev = inst.dict.getStr("_exp") orelse return null;
    const spv = inst.dict.getStr("_special") orelse return null;
    if (sv != .small_int or cv != .str or ev != .small_int or spv != .small_int) return null;
    return Dec{
        .sign = @intCast(sv.small_int),
        .coeff = cv.str.bytes,
        .exp = ev.small_int,
        .special = spv.small_int,
    };
}

fn newDec(interp: *Interp, sign: u1, coeff: []const u8, exp: i64, special: i64) !Value {
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.decimal_class.?);
    try inst.dict.setStr(a, "_sign", Value{ .small_int = @as(i64, sign) });
    const s = try Str.init(a, coeff);
    try inst.dict.setStr(a, "_coeff", Value{ .str = s });
    try inst.dict.setStr(a, "_exp", Value{ .small_int = exp });
    try inst.dict.setStr(a, "_special", Value{ .small_int = special });
    return Value{ .instance = inst };
}

/// Strip leading zeros, but always leave at least one digit ("0").
fn stripLeading(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i + 1 < s.len and s[i] == '0') : (i += 1) {}
    return s[i..];
}

/// Strip trailing zeros and report how many were dropped (so callers
/// can adjust the exponent).
fn stripTrailing(s: []const u8) struct { coeff: []const u8, dropped: usize } {
    var n = s.len;
    var dropped: usize = 0;
    while (n > 1 and s[n - 1] == '0') : (n -= 1) dropped += 1;
    return .{ .coeff = s[0..n], .dropped = dropped };
}

/// Parse a Python-style decimal literal: optional sign, then either a
/// finite mantissa with optional fraction and exponent, or one of the
/// special tokens (Inf, Infinity, NaN, sNaN).
fn parseDecimalString(a: std.mem.Allocator, s_in: []const u8) !struct { sign: u1, coeff: []u8, exp: i64, special: i64 } {
    var s = s_in;
    // Strip surrounding whitespace.
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\t' or s[0] == '\n' or s[0] == '\r')) s = s[1..];
    while (s.len > 0 and (s[s.len - 1] == ' ' or s[s.len - 1] == '\t' or s[s.len - 1] == '\n' or s[s.len - 1] == '\r')) s = s[0 .. s.len - 1];
    if (s.len == 0) return error.InvalidValue;
    var sign: u1 = 0;
    if (s[0] == '+') {
        s = s[1..];
    } else if (s[0] == '-') {
        sign = 1;
        s = s[1..];
    }
    if (s.len == 0) return error.InvalidValue;
    // Specials.
    if (eqlIgnoreCase(s, "inf") or eqlIgnoreCase(s, "infinity")) {
        const c = try a.dupe(u8, "0");
        return .{ .sign = sign, .coeff = c, .exp = 0, .special = SPECIAL_INF };
    }
    if (eqlIgnoreCase(s, "nan")) {
        const c = try a.dupe(u8, "");
        return .{ .sign = sign, .coeff = c, .exp = 0, .special = SPECIAL_QNAN };
    }
    if (s.len > 1 and (s[0] == 's' or s[0] == 'S') and eqlIgnoreCase(s[1..], "nan")) {
        const c = try a.dupe(u8, "");
        return .{ .sign = sign, .coeff = c, .exp = 0, .special = SPECIAL_SNAN };
    }
    // Finite: <int>(.<frac>)?(E[+-]?<int>)?
    var i: usize = 0;
    var int_part: []const u8 = "";
    var frac_part: []const u8 = "";
    const istart = i;
    while (i < s.len and isDigit(s[i])) : (i += 1) {}
    int_part = s[istart..i];
    if (i < s.len and s[i] == '.') {
        i += 1;
        const fstart = i;
        while (i < s.len and isDigit(s[i])) : (i += 1) {}
        frac_part = s[fstart..i];
    }
    if (int_part.len == 0 and frac_part.len == 0) return error.InvalidValue;
    var exp: i64 = -@as(i64, @intCast(frac_part.len));
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        var esign: i64 = 1;
        if (i < s.len and s[i] == '+') {
            i += 1;
        } else if (i < s.len and s[i] == '-') {
            esign = -1;
            i += 1;
        }
        if (i >= s.len or !isDigit(s[i])) return error.InvalidValue;
        var ev: i64 = 0;
        while (i < s.len and isDigit(s[i])) : (i += 1) {
            ev = ev * 10 + @as(i64, @intCast(s[i] - '0'));
        }
        exp += esign * ev;
    }
    if (i != s.len) return error.InvalidValue;
    // Build coefficient = int_part ++ frac_part, drop leading zeros (keep one).
    var buf = try a.alloc(u8, int_part.len + frac_part.len);
    @memcpy(buf[0..int_part.len], int_part);
    @memcpy(buf[int_part.len..], frac_part);
    if (buf.len == 0) {
        a.free(buf);
        const c = try a.dupe(u8, "0");
        return .{ .sign = sign, .coeff = c, .exp = exp, .special = SPECIAL_FINITE };
    }
    const stripped = stripLeading(buf);
    if (stripped.len == buf.len) {
        return .{ .sign = sign, .coeff = buf, .exp = exp, .special = SPECIAL_FINITE };
    }
    // Reallocate to drop leading zeros.
    const out = try a.dupe(u8, stripped);
    a.free(buf);
    return .{ .sign = sign, .coeff = out, .exp = exp, .special = SPECIAL_FINITE };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |c, i| {
        const c1 = if (c >= 'A' and c <= 'Z') c | 0x20 else c;
        const c2 = if (b[i] >= 'A' and b[i] <= 'Z') b[i] | 0x20 else b[i];
        if (c1 != c2) return false;
    }
    return true;
}

/// Render a Decimal as Python `str()` would: engineering notation when
/// exp > 0 or adjusted < -6, otherwise dotted-decimal.
fn formatDecimal(a: std.mem.Allocator, d: Dec) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    if (d.special == SPECIAL_INF) {
        if (d.sign == 1) try buf.appendSlice(a, "-");
        try buf.appendSlice(a, "Infinity");
        return buf.toOwnedSlice(a);
    }
    if (d.special == SPECIAL_QNAN) {
        if (d.sign == 1) try buf.appendSlice(a, "-");
        try buf.appendSlice(a, "NaN");
        return buf.toOwnedSlice(a);
    }
    if (d.special == SPECIAL_SNAN) {
        if (d.sign == 1) try buf.appendSlice(a, "-");
        try buf.appendSlice(a, "sNaN");
        return buf.toOwnedSlice(a);
    }
    // Finite.
    const coeff = if (d.coeff.len == 0) "0" else d.coeff;
    const len_c: i64 = @intCast(coeff.len);
    const adjusted = d.exp + len_c - 1;
    if (d.sign == 1) try buf.appendSlice(a, "-");
    if (d.exp <= 0 and adjusted >= -6) {
        if (d.exp == 0) {
            try buf.appendSlice(a, coeff);
        } else {
            const e_pos: i64 = d.exp + len_c;
            if (e_pos <= 0) {
                try buf.appendSlice(a, "0.");
                var k: i64 = 0;
                while (k < -e_pos) : (k += 1) try buf.append(a, '0');
                try buf.appendSlice(a, coeff);
            } else {
                const ep: usize = @intCast(e_pos);
                try buf.appendSlice(a, coeff[0..ep]);
                try buf.append(a, '.');
                try buf.appendSlice(a, coeff[ep..]);
            }
        }
    } else {
        // Exponent notation: one digit before the dot.
        try buf.append(a, coeff[0]);
        if (coeff.len > 1) {
            try buf.append(a, '.');
            try buf.appendSlice(a, coeff[1..]);
        }
        try buf.append(a, 'E');
        if (adjusted >= 0) {
            try buf.append(a, '+');
            const s = try std.fmt.allocPrint(a, "{d}", .{adjusted});
            defer a.free(s);
            try buf.appendSlice(a, s);
        } else {
            try buf.append(a, '-');
            const s = try std.fmt.allocPrint(a, "{d}", .{-adjusted});
            defer a.free(s);
            try buf.appendSlice(a, s);
        }
    }
    return buf.toOwnedSlice(a);
}

// ===== __init__ =====

fn decimalInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) {
        try interp.typeError("Decimal.__init__: missing self");
        return error.TypeError;
    }
    const inst = args[0].instance;
    if (args.len == 1) {
        // Decimal() with no value -> 0.
        try writeSlots(a, inst, 0, "0", 0, SPECIAL_FINITE);
        return Value.none;
    }
    const v = args[1];
    switch (v) {
        .str => |s| {
            const parsed = try parseDecimalString(a, s.bytes);
            try writeSlots(a, inst, parsed.sign, parsed.coeff, parsed.exp, parsed.special);
            a.free(parsed.coeff);
        },
        .small_int => |i| {
            var sign: u1 = 0;
            var ai: i128 = i;
            if (ai < 0) {
                sign = 1;
                ai = -ai;
            }
            const s = try std.fmt.allocPrint(a, "{d}", .{ai});
            defer a.free(s);
            try writeSlots(a, inst, sign, s, 0, SPECIAL_FINITE);
        },
        .big_int => |bi| {
            const s = try bi.toString10(a);
            defer a.free(s);
            var sign: u1 = 0;
            var coeff: []const u8 = s;
            if (coeff.len > 0 and coeff[0] == '-') {
                sign = 1;
                coeff = coeff[1..];
            }
            try writeSlots(a, inst, sign, coeff, 0, SPECIAL_FINITE);
        },
        .boolean => |b| {
            try writeSlots(a, inst, 0, if (b) "1" else "0", 0, SPECIAL_FINITE);
        },
        .instance => {
            // Decimal(other_decimal) -> copy.
            const od = readDec(v) orelse {
                try interp.typeError("Decimal: unsupported instance arg");
                return error.TypeError;
            };
            try writeSlots(a, inst, od.sign, od.coeff, od.exp, od.special);
        },
        else => {
            try interp.typeError("Decimal: unsupported argument type");
            return error.TypeError;
        },
    }
    return Value.none;
}

fn writeSlots(a: std.mem.Allocator, inst: *Instance, sign: u1, coeff: []const u8, exp: i64, special: i64) !void {
    try inst.dict.setStr(a, "_sign", Value{ .small_int = @as(i64, sign) });
    const s = try Str.init(a, coeff);
    try inst.dict.setStr(a, "_coeff", Value{ .str = s });
    try inst.dict.setStr(a, "_exp", Value{ .small_int = exp });
    try inst.dict.setStr(a, "_special", Value{ .small_int = special });
}

// ===== __repr__ / __str__ =====

fn decimalReprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const d = readDec(args[0]) orelse return error.TypeError;
    const inner = try formatDecimal(a, d);
    defer a.free(inner);
    const out = try std.fmt.allocPrint(a, "Decimal('{s}')", .{inner});
    return Value{ .str = try Str.fromOwnedSlice(a, out) };
}

fn decimalStrFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const d = readDec(args[0]) orelse return error.TypeError;
    const out = try formatDecimal(a, d);
    return Value{ .str = try Str.fromOwnedSlice(a, out) };
}

// ===== Coerce helper =====

/// Coerce a value to a Dec (parsing strings, widening ints, accepting
/// other Decimals).
fn coerce(interp: *Interp, v: Value) !struct { d: Dec, owned_coeff: ?[]u8 } {
    const a = interp.allocator;
    switch (v) {
        .instance => {
            if (readDec(v)) |d| return .{ .d = d, .owned_coeff = null };
            try interp.typeError("Decimal expected");
            return error.TypeError;
        },
        .small_int => |i| {
            var sign: u1 = 0;
            var ai: i128 = i;
            if (ai < 0) {
                sign = 1;
                ai = -ai;
            }
            const s = try std.fmt.allocPrint(a, "{d}", .{ai});
            return .{ .d = .{ .sign = sign, .coeff = s, .exp = 0, .special = SPECIAL_FINITE }, .owned_coeff = s };
        },
        .boolean => |b| {
            const s = try a.dupe(u8, if (b) "1" else "0");
            return .{ .d = .{ .sign = 0, .coeff = s, .exp = 0, .special = SPECIAL_FINITE }, .owned_coeff = s };
        },
        else => {
            try interp.typeError("Decimal arithmetic: unsupported type");
            return error.TypeError;
        },
    }
}

fn freeCoerce(a: std.mem.Allocator, c: anytype) void {
    if (c.owned_coeff) |buf| a.free(buf);
}

// ===== Arithmetic =====

fn currentPrec(interp: *Interp) i64 {
    if (interp.decimal_active_context) |v| {
        if (v == .instance) {
            const inst = v.instance;
            if (inst.dict.getStr("prec")) |p| if (p == .small_int) return p.small_int;
        }
    }
    return 28;
}

fn coeffToBig(a: std.mem.Allocator, coeff: []const u8) !BigInt {
    var bi = try BigInt.init(a);
    errdefer bi.deinit();
    if (coeff.len == 0) {
        try bi.set(0);
    } else {
        try bi.setString(10, coeff);
    }
    return bi;
}

fn bigToCoeff(a: std.mem.Allocator, bi: *const BigInt) ![]u8 {
    const s = try bi.toString(a, 10, .lower);
    if (s.len == 0) {
        a.free(s);
        return try a.dupe(u8, "0");
    }
    if (s[0] == '-') {
        const out = try a.dupe(u8, s[1..]);
        a.free(s);
        return out;
    }
    return s;
}

/// Multiply a digit string by 10^k by appending k zero characters.
fn shiftCoeff(a: std.mem.Allocator, coeff: []const u8, k: usize) ![]u8 {
    if (k == 0) return try a.dupe(u8, coeff);
    if (coeff.len == 1 and coeff[0] == '0') return try a.dupe(u8, "0");
    const out = try a.alloc(u8, coeff.len + k);
    @memcpy(out[0..coeff.len], coeff);
    @memset(out[coeff.len..], '0');
    return out;
}

fn isCoeffZero(coeff: []const u8) bool {
    for (coeff) |c| if (c != '0') return false;
    return true;
}

/// Compare two unsigned coefficient strings numerically.
fn cmpCoeff(a: []const u8, b: []const u8) std.math.Order {
    const sa = stripLeading(a);
    const sb = stripLeading(b);
    if (sa.len != sb.len) return if (sa.len < sb.len) .lt else .gt;
    return std.mem.order(u8, sa, sb);
}

/// Add: align exponents, add or subtract big-ints, normalise sign.
fn addDecImpl(interp: *Interp, x: Dec, y: Dec, neg_y: bool) !Value {
    const a = interp.allocator;
    if (x.special != SPECIAL_FINITE or y.special != SPECIAL_FINITE) {
        // Specials: minimal handling.
        if (x.special == SPECIAL_QNAN or x.special == SPECIAL_SNAN or
            y.special == SPECIAL_QNAN or y.special == SPECIAL_SNAN)
            return try newDec(interp, 0, "", 0, SPECIAL_QNAN);
        // Inf cases.
        const ys: u1 = if (neg_y) (1 - y.sign) else y.sign;
        if (x.special == SPECIAL_INF and y.special == SPECIAL_INF) {
            if (x.sign == ys) return try newDec(interp, x.sign, "0", 0, SPECIAL_INF);
            return try newDec(interp, 0, "", 0, SPECIAL_QNAN);
        }
        if (x.special == SPECIAL_INF) return try newDec(interp, x.sign, "0", 0, SPECIAL_INF);
        return try newDec(interp, ys, "0", 0, SPECIAL_INF);
    }
    const ys: u1 = if (neg_y) (1 - y.sign) else y.sign;
    // Align exponents: shift smaller-exp coefficient up, OR shift larger-exp coeff up so both have same exp.
    const e = @min(x.exp, y.exp);
    const x_shift: usize = @intCast(x.exp - e);
    const y_shift: usize = @intCast(y.exp - e);
    const xc = try shiftCoeff(a, x.coeff, x_shift);
    defer a.free(xc);
    const yc = try shiftCoeff(a, y.coeff, y_shift);
    defer a.free(yc);
    var xb = try coeffToBig(a, xc);
    defer xb.deinit();
    var yb = try coeffToBig(a, yc);
    defer yb.deinit();
    var result_sign: u1 = 0;
    var sum_b = try BigInt.init(a);
    defer sum_b.deinit();
    if (x.sign == ys) {
        try sum_b.add(&xb, &yb);
        result_sign = x.sign;
    } else {
        // Subtract smaller from larger.
        const ord = cmpCoeff(xc, yc);
        if (ord == .gt) {
            try sum_b.sub(&xb, &yb);
            result_sign = x.sign;
        } else if (ord == .lt) {
            try sum_b.sub(&yb, &xb);
            result_sign = ys;
        } else {
            try sum_b.set(0);
            result_sign = 0;
        }
    }
    const out_coeff = try bigToCoeff(a, &sum_b);
    defer a.free(out_coeff);
    return try roundResult(interp, result_sign, out_coeff, e, currentPrec(interp));
}

/// Round `coeff` so it has at most `prec` digits, adjusting exp.
fn roundResult(interp: *Interp, sign: u1, coeff: []const u8, exp: i64, prec: i64) !Value {
    const a = interp.allocator;
    const stripped = stripLeading(coeff);
    if (stripped.len <= @as(usize, @intCast(prec))) {
        return try newDec(interp, sign, stripped, exp, SPECIAL_FINITE);
    }
    // Need to round off (stripped.len - prec) digits from the right.
    const drop: usize = stripped.len - @as(usize, @intCast(prec));
    const new_coeff_buf = try a.alloc(u8, @intCast(prec));
    defer a.free(new_coeff_buf);
    @memcpy(new_coeff_buf, stripped[0..@intCast(prec)]);
    // Apply rounding: ROUND_HALF_EVEN by default.
    const rd = stripped[@intCast(prec)];
    var round_up = false;
    if (rd > '5') {
        round_up = true;
    } else if (rd == '5') {
        // Half: check remaining digits for non-zero, or use even-tie.
        var any_nonzero = false;
        var i: usize = @intCast(@as(i64, @intCast(prec)) + 1);
        while (i < stripped.len) : (i += 1) {
            if (stripped[i] != '0') {
                any_nonzero = true;
                break;
            }
        }
        if (any_nonzero) {
            round_up = true;
        } else {
            const last = new_coeff_buf[new_coeff_buf.len - 1];
            if ((last - '0') & 1 == 1) round_up = true;
        }
    }
    var rounded_coeff: []u8 = undefined;
    if (round_up) {
        rounded_coeff = try addOneToDigits(a, new_coeff_buf);
    } else {
        rounded_coeff = try a.dupe(u8, new_coeff_buf);
    }
    defer a.free(rounded_coeff);
    return try newDec(interp, sign, rounded_coeff, exp + @as(i64, @intCast(drop)), SPECIAL_FINITE);
}

fn addOneToDigits(a: std.mem.Allocator, digits: []const u8) ![]u8 {
    var carry: u8 = 1;
    var buf = try a.alloc(u8, digits.len);
    var i = digits.len;
    while (i > 0) {
        i -= 1;
        const d = digits[i] - '0' + carry;
        if (d >= 10) {
            buf[i] = '0';
            carry = 1;
        } else {
            buf[i] = '0' + d;
            carry = 0;
        }
    }
    if (carry == 1) {
        const out = try a.alloc(u8, digits.len + 1);
        out[0] = '1';
        @memcpy(out[1..], buf);
        a.free(buf);
        return out;
    }
    return buf;
}

fn binaryDispatch(interp: *Interp, args: []const Value, comptime mode: enum { add, sub, rsub, mul, div, floordiv, mod, pow }) !Value {
    if (args.len != 2) return error.TypeError;
    const a = interp.allocator;
    const lc = try coerce(interp, args[0]);
    defer freeCoerce(a, lc);
    const rc = try coerce(interp, args[1]);
    defer freeCoerce(a, rc);
    switch (mode) {
        .add => return try addDecImpl(interp, lc.d, rc.d, false),
        .sub => return try addDecImpl(interp, lc.d, rc.d, true),
        .rsub => return try addDecImpl(interp, rc.d, lc.d, true),
        .mul => return try mulDec(interp, lc.d, rc.d),
        .div => return try divDec(interp, lc.d, rc.d),
        .floordiv => return try floordivDec(interp, lc.d, rc.d),
        .mod => return try modDec(interp, lc.d, rc.d),
        .pow => return try powDec(interp, lc.d, rc.d),
    }
}

fn decimalAddFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return binaryDispatch(interp, args, .add);
}

fn decimalSubFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return binaryDispatch(interp, args, .sub);
}

fn decimalRsubFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return binaryDispatch(interp, args, .rsub);
}

fn decimalMulFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return binaryDispatch(interp, args, .mul);
}

fn decimalDivFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return binaryDispatch(interp, args, .div);
}

fn decimalFloorDivFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return binaryDispatch(interp, args, .floordiv);
}

fn decimalModFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return binaryDispatch(interp, args, .mod);
}

fn decimalPowFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return binaryDispatch(interp, args, .pow);
}

fn mulDec(interp: *Interp, x: Dec, y: Dec) !Value {
    const a = interp.allocator;
    if (x.special != SPECIAL_FINITE or y.special != SPECIAL_FINITE) {
        if (x.special == SPECIAL_QNAN or x.special == SPECIAL_SNAN or
            y.special == SPECIAL_QNAN or y.special == SPECIAL_SNAN)
            return try newDec(interp, 0, "", 0, SPECIAL_QNAN);
        // 0 * inf = NaN
        const x_zero = x.special == SPECIAL_FINITE and isCoeffZero(x.coeff);
        const y_zero = y.special == SPECIAL_FINITE and isCoeffZero(y.coeff);
        if ((x.special == SPECIAL_INF and y_zero) or (y.special == SPECIAL_INF and x_zero))
            return try newDec(interp, 0, "", 0, SPECIAL_QNAN);
        return try newDec(interp, x.sign ^ y.sign, "0", 0, SPECIAL_INF);
    }
    var xb = try coeffToBig(a, x.coeff);
    defer xb.deinit();
    var yb = try coeffToBig(a, y.coeff);
    defer yb.deinit();
    var prod = try BigInt.init(a);
    defer prod.deinit();
    try prod.mul(&xb, &yb);
    const out = try bigToCoeff(a, &prod);
    defer a.free(out);
    return try roundResult(interp, x.sign ^ y.sign, out, x.exp + y.exp, currentPrec(interp));
}

fn divDec(interp: *Interp, x: Dec, y: Dec) !Value {
    const a = interp.allocator;
    if (x.special != SPECIAL_FINITE or y.special != SPECIAL_FINITE) {
        if (x.special == SPECIAL_QNAN or x.special == SPECIAL_SNAN or
            y.special == SPECIAL_QNAN or y.special == SPECIAL_SNAN)
            return try newDec(interp, 0, "", 0, SPECIAL_QNAN);
        return try newDec(interp, 0, "", 0, SPECIAL_QNAN);
    }
    if (isCoeffZero(y.coeff)) {
        if (isCoeffZero(x.coeff)) {
            try interp.raiseDecimal(interp.decimal_invalid_op_class.?, "0/0");
            return error.PyException;
        }
        try interp.raiseDecimal(interp.decimal_div_zero_class.?, "division by zero");
        return error.PyException;
    }
    if (isCoeffZero(x.coeff)) {
        return try newDec(interp, x.sign ^ y.sign, "0", x.exp - y.exp, SPECIAL_FINITE);
    }
    const prec = currentPrec(interp);
    var n = try coeffToBig(a, x.coeff);
    defer n.deinit();
    var d = try coeffToBig(a, y.coeff);
    defer d.deinit();
    var exp: i64 = x.exp - y.exp;
    // Loop: shift n until n // d >= 10^(prec-1).
    var ten = try BigInt.initSet(a, 10);
    defer ten.deinit();
    var threshold = try BigInt.initSet(a, 1);
    defer threshold.deinit();
    {
        var i: i64 = 0;
        while (i < prec - 1) : (i += 1) {
            try threshold.mul(&threshold, &ten);
        }
    }
    // We want n // d >= threshold, i.e., n >= d * threshold.
    var d_times_threshold = try BigInt.init(a);
    defer d_times_threshold.deinit();
    try d_times_threshold.mul(&d, &threshold);
    while (n.order(d_times_threshold) == .lt) {
        try n.mul(&n, &ten);
        exp -= 1;
    }
    var q = try BigInt.init(a);
    defer q.deinit();
    var r = try BigInt.init(a);
    defer r.deinit();
    try q.divFloor(&r, &n, &d);
    // Now q has approximately prec digits. Apply rounding using r.
    // For ROUND_HALF_EVEN: next digit ~ (r*10) // d. Use that to decide.
    var round_up = false;
    if (!r.eqlZero()) {
        // Compute 2*r vs d.
        var two_r = try BigInt.init(a);
        defer two_r.deinit();
        var two = try BigInt.initSet(a, 2);
        defer two.deinit();
        try two_r.mul(&r, &two);
        const ord = two_r.order(d);
        if (ord == .gt) {
            round_up = true;
        } else if (ord == .eq) {
            // Half: round to even.
            const q_str = try q.toString(a, 10, .lower);
            defer a.free(q_str);
            const last = q_str[q_str.len - 1];
            if ((last - '0') & 1 == 1) round_up = true;
        }
    }
    if (round_up) {
        var one = try BigInt.initSet(a, 1);
        defer one.deinit();
        try q.add(&q, &one);
    }
    const out = try bigToCoeff(a, &q);
    defer a.free(out);
    // q may now have prec or prec+1 digits (after carry). roundResult
    // handles that — but exp is correct.
    return try roundResult(interp, x.sign ^ y.sign, out, exp, prec);
}

fn floordivDec(interp: *Interp, x: Dec, y: Dec) !Value {
    const a = interp.allocator;
    if (x.special != SPECIAL_FINITE or y.special != SPECIAL_FINITE) {
        try interp.raiseDecimal(interp.decimal_invalid_op_class.?, "//");
        return error.PyException;
    }
    if (isCoeffZero(y.coeff)) {
        try interp.raiseDecimal(interp.decimal_div_zero_class.?, "division by zero");
        return error.PyException;
    }
    var n = try coeffToBig(a, x.coeff);
    defer n.deinit();
    var d = try coeffToBig(a, y.coeff);
    defer d.deinit();
    const delta = x.exp - y.exp;
    var ten = try BigInt.initSet(a, 10);
    defer ten.deinit();
    if (delta > 0) {
        var i: i64 = 0;
        while (i < delta) : (i += 1) try n.mul(&n, &ten);
    } else if (delta < 0) {
        var i: i64 = 0;
        while (i < -delta) : (i += 1) try d.mul(&d, &ten);
    }
    var q = try BigInt.init(a);
    defer q.deinit();
    var r = try BigInt.init(a);
    defer r.deinit();
    try q.divFloor(&r, &n, &d);
    const out = try bigToCoeff(a, &q);
    defer a.free(out);
    return try newDec(interp, x.sign ^ y.sign, out, 0, SPECIAL_FINITE);
}

fn modDec(interp: *Interp, x: Dec, y: Dec) !Value {
    const a = interp.allocator;
    if (x.special != SPECIAL_FINITE or y.special != SPECIAL_FINITE) {
        try interp.raiseDecimal(interp.decimal_invalid_op_class.?, "%");
        return error.PyException;
    }
    if (isCoeffZero(y.coeff)) {
        try interp.raiseDecimal(interp.decimal_invalid_op_class.?, "% with zero divisor");
        return error.PyException;
    }
    // r = x - (x // y) * y, but result.exp = min(x.exp, y.exp) and sign follows x (truncated).
    const exp = @min(x.exp, y.exp);
    var n = try coeffToBig(a, x.coeff);
    defer n.deinit();
    var d = try coeffToBig(a, y.coeff);
    defer d.deinit();
    var ten = try BigInt.initSet(a, 10);
    defer ten.deinit();
    const x_shift: usize = @intCast(x.exp - exp);
    const y_shift: usize = @intCast(y.exp - exp);
    {
        var i: usize = 0;
        while (i < x_shift) : (i += 1) try n.mul(&n, &ten);
    }
    {
        var i: usize = 0;
        while (i < y_shift) : (i += 1) try d.mul(&d, &ten);
    }
    var q = try BigInt.init(a);
    defer q.deinit();
    var r = try BigInt.init(a);
    defer r.deinit();
    try q.divFloor(&r, &n, &d);
    // Adjust to truncation: q*d + r = n with 0 <= r < d. But we want
    // truncation-toward-zero quotient. Since n,d are absolute values,
    // floor and trunc agree here. The result sign is x.sign
    // (truncated div remainder follows dividend sign).
    const out = try bigToCoeff(a, &r);
    defer a.free(out);
    return try newDec(interp, x.sign, out, exp, SPECIAL_FINITE);
}

fn powDec(interp: *Interp, x: Dec, y: Dec) !Value {
    if (y.special != SPECIAL_FINITE or x.special != SPECIAL_FINITE) {
        try interp.raiseDecimal(interp.decimal_invalid_op_class.?, "**");
        return error.PyException;
    }
    // Only integer exponents (positive) supported.
    if (y.exp != 0 and !(y.exp > 0)) {
        // y.exp < 0 -> non-integer exponent
        try interp.raiseDecimal(interp.decimal_invalid_op_class.?, "** with non-integer exponent");
        return error.PyException;
    }
    // Compute integer value of y.
    const a = interp.allocator;
    var yb = try coeffToBig(a, y.coeff);
    defer yb.deinit();
    var ten = try BigInt.initSet(a, 10);
    defer ten.deinit();
    {
        var i: i64 = 0;
        while (i < y.exp) : (i += 1) try yb.mul(&yb, &ten);
    }
    if (y.sign == 1) {
        try interp.raiseDecimal(interp.decimal_invalid_op_class.?, "** with negative exponent");
        return error.PyException;
    }
    const exp_int = yb.toInt(i64) catch {
        try interp.raiseDecimal(interp.decimal_invalid_op_class.?, "exponent too large");
        return error.PyException;
    };
    // Square-and-multiply.
    var result = try newDec(interp, 0, "1", 0, SPECIAL_FINITE);
    var base = try newDec(interp, x.sign, x.coeff, x.exp, SPECIAL_FINITE);
    var e = exp_int;
    while (e > 0) : (e >>= 1) {
        if ((e & 1) == 1) {
            const rd = readDec(result).?;
            const bd = readDec(base).?;
            result = try mulDec(interp, rd, bd);
        }
        if (e > 1) {
            const bd = readDec(base).?;
            base = try mulDec(interp, bd, bd);
        }
    }
    return result;
}

// ===== Unary =====

fn decimalNegFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const d = readDec(args[0]) orelse return error.TypeError;
    if (d.special != SPECIAL_FINITE) return try newDec(interp, 1 - d.sign, d.coeff, d.exp, d.special);
    // -0 stays as 0 with sign flipped per spec, but the fixture's
    // `print(-Decimal('3.14'))` expects "-3.14". For zero: keep
    // unchanged sign? CPython gives Decimal('-0') for -Decimal('0').
    return try newDec(interp, 1 - d.sign, d.coeff, d.exp, SPECIAL_FINITE);
}

fn decimalPosFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const d = readDec(args[0]) orelse return error.TypeError;
    return try newDec(interp, d.sign, d.coeff, d.exp, d.special);
}

fn decimalAbsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const d = readDec(args[0]) orelse return error.TypeError;
    return try newDec(interp, 0, d.coeff, d.exp, d.special);
}

fn decimalBoolFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const d = readDec(args[0]) orelse return error.TypeError;
    if (d.special != SPECIAL_FINITE) return Value{ .boolean = true };
    return Value{ .boolean = !isCoeffZero(d.coeff) };
}

fn decimalIntFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const d = readDec(args[0]) orelse return error.TypeError;
    if (d.special != SPECIAL_FINITE) {
        try interp.typeError("cannot convert non-finite Decimal to int");
        return error.TypeError;
    }
    var bi = try coeffToBig(a, d.coeff);
    defer bi.deinit();
    var ten = try BigInt.initSet(a, 10);
    defer ten.deinit();
    if (d.exp >= 0) {
        var i: i64 = 0;
        while (i < d.exp) : (i += 1) try bi.mul(&bi, &ten);
    } else {
        var i: i64 = 0;
        while (i < -d.exp) : (i += 1) {
            var q = try BigInt.init(a);
            defer q.deinit();
            var r = try BigInt.init(a);
            defer r.deinit();
            try q.divFloor(&r, &bi, &ten);
            try bi.copy(q.toConst());
        }
    }
    if (d.sign == 1) bi.negate();
    if (bi.toInt(i64)) |v| {
        return Value{ .small_int = v };
    } else |_| {}
    const big = try @import("../object/bigint.zig").BigInt.fromManaged(a, bi);
    bi = try BigInt.init(a); // disown
    return Value{ .big_int = big };
}

fn decimalFloatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const d = readDec(args[0]) orelse return error.TypeError;
    const s = try formatDecimal(a, d);
    defer a.free(s);
    const f = std.fmt.parseFloat(f64, s) catch {
        try interp.typeError("cannot convert Decimal to float");
        return error.TypeError;
    };
    return Value{ .float = f };
}

// ===== Comparison =====

fn cmpDec(x: Dec, y: Dec) std.math.Order {
    // Special handling: NaN compares as unordered (not handled here; equals false).
    if (x.special != SPECIAL_FINITE or y.special != SPECIAL_FINITE) {
        // For Inf: just sign-based.
        return .eq; // treat as equal (caller should special-case)
    }
    // Sign first.
    const x_zero = isCoeffZero(x.coeff);
    const y_zero = isCoeffZero(y.coeff);
    if (x_zero and y_zero) return .eq;
    if (x_zero) return if (y.sign == 0) .lt else .gt;
    if (y_zero) return if (x.sign == 0) .gt else .lt;
    if (x.sign != y.sign) {
        return if (x.sign == 0) .gt else .lt;
    }
    // Same sign, both non-zero. Compare numeric magnitudes by aligning.
    const ax = stripLeading(x.coeff);
    const ay = stripLeading(y.coeff);
    const x_adj = x.exp + @as(i64, @intCast(ax.len)) - 1;
    const y_adj = y.exp + @as(i64, @intCast(ay.len)) - 1;
    var mag: std.math.Order = undefined;
    if (x_adj != y_adj) {
        mag = if (x_adj < y_adj) .lt else .gt;
    } else {
        // Equal adjusted exponents: compare digits left-justified.
        var i: usize = 0;
        const n = @max(ax.len, ay.len);
        mag = .eq;
        while (i < n) : (i += 1) {
            const ca: u8 = if (i < ax.len) ax[i] else '0';
            const cb: u8 = if (i < ay.len) ay[i] else '0';
            if (ca != cb) {
                mag = if (ca < cb) .lt else .gt;
                break;
            }
        }
    }
    if (x.sign == 1) {
        // Both negative: invert.
        return switch (mag) {
            .lt => .gt,
            .gt => .lt,
            .eq => .eq,
        };
    }
    return mag;
}

fn decimalEqFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len != 2) return error.TypeError;
    const lc = try coerce(interp, args[0]);
    defer freeCoerce(a, lc);
    const rc = coerce(interp, args[1]) catch {
        return Value{ .boolean = false };
    };
    defer freeCoerce(a, rc);
    if (lc.d.special == SPECIAL_QNAN or lc.d.special == SPECIAL_SNAN or
        rc.d.special == SPECIAL_QNAN or rc.d.special == SPECIAL_SNAN)
        return Value{ .boolean = false };
    return Value{ .boolean = cmpDec(lc.d, rc.d) == .eq };
}

fn decimalNeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const r = try decimalEqFn(p, args);
    return Value{ .boolean = !r.boolean };
}

fn decimalLtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const lc = try coerce(interp, args[0]);
    defer freeCoerce(a, lc);
    const rc = try coerce(interp, args[1]);
    defer freeCoerce(a, rc);
    return Value{ .boolean = cmpDec(lc.d, rc.d) == .lt };
}

fn decimalLeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const lc = try coerce(interp, args[0]);
    defer freeCoerce(a, lc);
    const rc = try coerce(interp, args[1]);
    defer freeCoerce(a, rc);
    const o = cmpDec(lc.d, rc.d);
    return Value{ .boolean = o == .lt or o == .eq };
}

fn decimalGtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const lc = try coerce(interp, args[0]);
    defer freeCoerce(a, lc);
    const rc = try coerce(interp, args[1]);
    defer freeCoerce(a, rc);
    return Value{ .boolean = cmpDec(lc.d, rc.d) == .gt };
}

fn decimalGeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const lc = try coerce(interp, args[0]);
    defer freeCoerce(a, lc);
    const rc = try coerce(interp, args[1]);
    defer freeCoerce(a, rc);
    const o = cmpDec(lc.d, rc.d);
    return Value{ .boolean = o == .gt or o == .eq };
}

// ===== Predicates =====

fn isFiniteFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const d = readDec(args[0]) orelse return error.TypeError;
    return Value{ .boolean = d.special == SPECIAL_FINITE };
}
fn isInfiniteFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const d = readDec(args[0]) orelse return error.TypeError;
    return Value{ .boolean = d.special == SPECIAL_INF };
}
fn isNanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const d = readDec(args[0]) orelse return error.TypeError;
    return Value{ .boolean = d.special == SPECIAL_QNAN or d.special == SPECIAL_SNAN };
}
fn isQnanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const d = readDec(args[0]) orelse return error.TypeError;
    return Value{ .boolean = d.special == SPECIAL_QNAN };
}
fn isSnanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const d = readDec(args[0]) orelse return error.TypeError;
    return Value{ .boolean = d.special == SPECIAL_SNAN };
}
fn isSignedFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const d = readDec(args[0]) orelse return error.TypeError;
    return Value{ .boolean = d.sign == 1 };
}
fn isZeroFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const d = readDec(args[0]) orelse return error.TypeError;
    return Value{ .boolean = d.special == SPECIAL_FINITE and isCoeffZero(d.coeff) };
}
fn isNormalFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const d = readDec(args[0]) orelse return error.TypeError;
    if (d.special != SPECIAL_FINITE) return Value{ .boolean = false };
    return Value{ .boolean = !isCoeffZero(d.coeff) };
}

// ===== adjusted, as_tuple, normalize =====

fn adjustedFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const d = readDec(args[0]) orelse return error.TypeError;
    if (d.special != SPECIAL_FINITE) return Value{ .small_int = 0 };
    const stripped = stripLeading(d.coeff);
    return Value{ .small_int = d.exp + @as(i64, @intCast(stripped.len)) - 1 };
}

fn asTupleFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const d = readDec(args[0]) orelse return error.TypeError;
    const cls = interp.decimal_tuple_class.?;
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "sign", Value{ .small_int = @as(i64, d.sign) });
    // digits: tuple of ints.
    if (d.special == SPECIAL_INF) {
        const t = try Tuple.init(a, 1);
        t.items[0] = Value{ .small_int = 0 };
        try inst.dict.setStr(a, "digits", Value{ .tuple = t });
        const s = try Str.init(a, "F");
        try inst.dict.setStr(a, "exponent", Value{ .str = s });
    } else if (d.special == SPECIAL_QNAN or d.special == SPECIAL_SNAN) {
        const t = try Tuple.init(a, 0);
        try inst.dict.setStr(a, "digits", Value{ .tuple = t });
        const ec: []const u8 = if (d.special == SPECIAL_QNAN) "n" else "N";
        const s = try Str.init(a, ec);
        try inst.dict.setStr(a, "exponent", Value{ .str = s });
    } else {
        const stripped = stripLeading(d.coeff);
        const t = try Tuple.init(a, stripped.len);
        for (stripped, 0..) |c, i| {
            t.items[i] = Value{ .small_int = @as(i64, @intCast(c - '0')) };
        }
        try inst.dict.setStr(a, "digits", Value{ .tuple = t });
        try inst.dict.setStr(a, "exponent", Value{ .small_int = d.exp });
    }
    return Value{ .instance = inst };
}

fn normalizeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const d = readDec(args[0]) orelse return error.TypeError;
    if (d.special != SPECIAL_FINITE) return try newDec(interp, d.sign, d.coeff, d.exp, d.special);
    if (isCoeffZero(d.coeff)) return try newDec(interp, d.sign, "0", 0, SPECIAL_FINITE);
    const stripped = stripLeading(d.coeff);
    const r = stripTrailing(stripped);
    return try newDec(interp, d.sign, r.coeff, d.exp + @as(i64, @intCast(r.dropped)), SPECIAL_FINITE);
}

// ===== sqrt =====

fn sqrtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const d = readDec(args[0]) orelse return error.TypeError;
    if (d.special != SPECIAL_FINITE) return try newDec(interp, 0, "", 0, SPECIAL_QNAN);
    if (d.sign == 1 and !isCoeffZero(d.coeff)) {
        try interp.raiseDecimal(interp.decimal_invalid_op_class.?, "sqrt of negative");
        return error.PyException;
    }
    if (isCoeffZero(d.coeff)) {
        return try newDec(interp, d.sign, "0", @divFloor(d.exp, 2), SPECIAL_FINITE);
    }
    const prec = currentPrec(interp);
    var n = try coeffToBig(a, d.coeff);
    defer n.deinit();
    var e = d.exp;
    var ten = try BigInt.initSet(a, 10);
    defer ten.deinit();
    // Try exact: if e is even, isqrt(n)^2 == n implies exact.
    if (@mod(e, 2) == 0) {
        var s_try = try BigInt.init(a);
        defer s_try.deinit();
        try s_try.sqrt(&n);
        var sq = try BigInt.init(a);
        defer sq.deinit();
        try sq.mul(&s_try, &s_try);
        if (sq.order(n) == .eq) {
            const out = try bigToCoeff(a, &s_try);
            defer a.free(out);
            return try newDec(interp, 0, out, @divFloor(e, 2), SPECIAL_FINITE);
        }
    }
    // Inexact: scale to prec digits.
    if (@mod(e, 2) != 0) {
        try n.mul(&n, &ten);
        e -= 1;
    }
    // n_str_len gives number of digits in n; result of isqrt has
    // ceil(n_str_len / 2) digits. We want exactly `prec` digits.
    const n_str = try n.toString(a, 10, .lower);
    defer a.free(n_str);
    const digits_n = n_str.len;
    const digits_r = (digits_n + 1) / 2;
    const need: i64 = prec - @as(i64, @intCast(digits_r));
    const shift: i64 = if (need > 0) need else 0;
    // Scale by 10^(2*shift).
    var scale_factor = try BigInt.initSet(a, 1);
    defer scale_factor.deinit();
    {
        var i: i64 = 0;
        while (i < 2 * shift) : (i += 1) try scale_factor.mul(&scale_factor, &ten);
    }
    var n_scaled = try BigInt.init(a);
    defer n_scaled.deinit();
    try n_scaled.mul(&n, &scale_factor);
    var s = try BigInt.init(a);
    defer s.deinit();
    try s.sqrt(&n_scaled);
    const out = try bigToCoeff(a, &s);
    defer a.free(out);
    return try newDec(interp, 0, out, @divFloor(e, 2) - shift, SPECIAL_FINITE);
}

// ===== compare, copy_sign, max, min =====

fn compareFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const lc = try coerce(interp, args[0]);
    defer freeCoerce(a, lc);
    const rc = try coerce(interp, args[1]);
    defer freeCoerce(a, rc);
    const o = cmpDec(lc.d, rc.d);
    return switch (o) {
        .lt => try newDec(interp, 1, "1", 0, SPECIAL_FINITE),
        .eq => try newDec(interp, 0, "0", 0, SPECIAL_FINITE),
        .gt => try newDec(interp, 0, "1", 0, SPECIAL_FINITE),
    };
}

fn copySignFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const lc = try coerce(interp, args[0]);
    defer freeCoerce(a, lc);
    const rc = try coerce(interp, args[1]);
    defer freeCoerce(a, rc);
    return try newDec(interp, rc.d.sign, lc.d.coeff, lc.d.exp, lc.d.special);
}

fn maxFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const lc = try coerce(interp, args[0]);
    defer freeCoerce(a, lc);
    const rc = try coerce(interp, args[1]);
    defer freeCoerce(a, rc);
    const o = cmpDec(lc.d, rc.d);
    if (o == .lt) return try newDec(interp, rc.d.sign, rc.d.coeff, rc.d.exp, rc.d.special);
    return try newDec(interp, lc.d.sign, lc.d.coeff, lc.d.exp, lc.d.special);
}

fn minFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const lc = try coerce(interp, args[0]);
    defer freeCoerce(a, lc);
    const rc = try coerce(interp, args[1]);
    defer freeCoerce(a, rc);
    const o = cmpDec(lc.d, rc.d);
    if (o == .gt) return try newDec(interp, rc.d.sign, rc.d.coeff, rc.d.exp, rc.d.special);
    return try newDec(interp, lc.d.sign, lc.d.coeff, lc.d.exp, lc.d.special);
}

// ===== quantize, to_integral_value =====

fn quantizeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return quantizeImpl(p, args, &.{}, &.{});
}
fn quantizeKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return quantizeImpl(p, args, kw_names, kw_values);
}

fn lookupKw(kw_names: []const Value, kw_values: []const Value, name: []const u8) ?Value {
    for (kw_names, 0..) |kn, i| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, name)) return kw_values[i];
    }
    return null;
}

fn parseRoundingMode(v: Value) ?[]const u8 {
    if (v != .str) return null;
    return v.str.bytes;
}

/// Round `coeff` to drop the trailing `n_drop` digits, applying the
/// named CPython rounding mode.
fn roundOff(a: std.mem.Allocator, sign: u1, coeff: []const u8, n_drop: usize, mode: []const u8) ![]u8 {
    if (n_drop == 0) return try a.dupe(u8, coeff);
    if (n_drop >= coeff.len) {
        // Whole coefficient gets dropped.
        const kept = "0";
        // Decide based on mode whether to round up to 1.
        const round_up = decideRoundUp(sign, kept, coeff, mode);
        if (round_up) {
            // Place 1 at appropriate position.
            const out = try a.alloc(u8, 1);
            out[0] = '1';
            return out;
        }
        return try a.dupe(u8, "0");
    }
    const kept_len = coeff.len - n_drop;
    const kept = coeff[0..kept_len];
    const dropped = coeff[kept_len..];
    const round_up = decideRoundUp(sign, kept, dropped, mode);
    if (!round_up) return try a.dupe(u8, kept);
    return try addOneToDigits(a, kept);
}

fn decideRoundUp(sign: u1, kept: []const u8, dropped: []const u8, mode: []const u8) bool {
    var any_nonzero = false;
    for (dropped) |c| if (c != '0') {
        any_nonzero = true;
        break;
    };
    if (!any_nonzero) return false;
    // First significant dropped digit.
    const first = dropped[0];
    // Whether dropped > 5...0 (strict) i.e. greater-than-half.
    const more_than_half = blk: {
        if (first > '5') break :blk true;
        if (first < '5') break :blk false;
        // first == '5': any later non-zero pushes over half.
        var i: usize = 1;
        while (i < dropped.len) : (i += 1) {
            if (dropped[i] != '0') break :blk true;
        }
        break :blk false;
    };
    const exactly_half = first == '5' and !more_than_half;
    if (std.mem.eql(u8, mode, "ROUND_DOWN")) return false;
    if (std.mem.eql(u8, mode, "ROUND_UP")) return true;
    if (std.mem.eql(u8, mode, "ROUND_CEILING")) return sign == 0;
    if (std.mem.eql(u8, mode, "ROUND_FLOOR")) return sign == 1;
    if (std.mem.eql(u8, mode, "ROUND_HALF_UP")) return more_than_half or exactly_half;
    if (std.mem.eql(u8, mode, "ROUND_HALF_DOWN")) return more_than_half;
    if (std.mem.eql(u8, mode, "ROUND_HALF_EVEN")) {
        if (more_than_half) return true;
        if (exactly_half) {
            const last = if (kept.len == 0) '0' else kept[kept.len - 1];
            return ((last - '0') & 1) == 1;
        }
        return false;
    }
    if (std.mem.eql(u8, mode, "ROUND_05UP")) {
        const last = if (kept.len == 0) '0' else kept[kept.len - 1];
        return last == '0' or last == '5';
    }
    // Unknown mode: default to half-even.
    if (more_than_half) return true;
    if (exactly_half) {
        const last = if (kept.len == 0) '0' else kept[kept.len - 1];
        return ((last - '0') & 1) == 1;
    }
    return false;
}

fn currentRounding(interp: *Interp) []const u8 {
    if (interp.decimal_active_context) |v| {
        if (v == .instance) {
            if (v.instance.dict.getStr("rounding")) |r| if (r == .str) return r.str.bytes;
        }
    }
    return "ROUND_HALF_EVEN";
}

fn quantizeImpl(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const self_d = readDec(args[0]) orelse return error.TypeError;
    const target = readDec(args[1]) orelse {
        try interp.typeError("quantize: arg must be Decimal");
        return error.TypeError;
    };
    var rounding_mode: []const u8 = currentRounding(interp);
    if (lookupKw(kw_names, kw_values, "rounding")) |rv| {
        if (parseRoundingMode(rv)) |m| rounding_mode = m;
    }
    // (Also scan positional args[2] for rounding if kw not given.)
    if (kw_names.len == 0 and args.len >= 3) {
        if (parseRoundingMode(args[2])) |m| rounding_mode = m;
    }
    if (self_d.special != SPECIAL_FINITE or target.special != SPECIAL_FINITE) {
        return try newDec(interp, self_d.sign, self_d.coeff, target.exp, self_d.special);
    }
    const target_exp = target.exp;
    if (target_exp == self_d.exp) {
        return try newDec(interp, self_d.sign, self_d.coeff, self_d.exp, SPECIAL_FINITE);
    }
    if (target_exp < self_d.exp) {
        // Pad with trailing zeros.
        const k: usize = @intCast(self_d.exp - target_exp);
        const padded = try shiftCoeff(a, self_d.coeff, k);
        defer a.free(padded);
        return try newDec(interp, self_d.sign, padded, target_exp, SPECIAL_FINITE);
    }
    // target_exp > self_d.exp: drop digits with rounding.
    const stripped = stripLeading(self_d.coeff);
    const drop: i64 = target_exp - self_d.exp;
    const drop_u: usize = @intCast(drop);
    if (drop_u >= stripped.len) {
        // Round whole coefficient.
        const rounded = try roundOff(a, self_d.sign, stripped, drop_u, rounding_mode);
        defer a.free(rounded);
        return try newDec(interp, self_d.sign, rounded, target_exp, SPECIAL_FINITE);
    }
    const rounded = try roundOff(a, self_d.sign, stripped, drop_u, rounding_mode);
    defer a.free(rounded);
    return try newDec(interp, self_d.sign, rounded, target_exp, SPECIAL_FINITE);
}

fn toIntegralFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return toIntegralImpl(p, args, &.{}, &.{});
}
fn toIntegralKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return toIntegralImpl(p, args, kw_names, kw_values);
}

fn toIntegralImpl(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self_d = readDec(args[0]) orelse return error.TypeError;
    var rounding_mode: []const u8 = currentRounding(interp);
    if (lookupKw(kw_names, kw_values, "rounding")) |rv| {
        if (parseRoundingMode(rv)) |m| rounding_mode = m;
    }
    if (self_d.special != SPECIAL_FINITE) return try newDec(interp, self_d.sign, self_d.coeff, self_d.exp, self_d.special);
    if (self_d.exp >= 0) return try newDec(interp, self_d.sign, self_d.coeff, self_d.exp, SPECIAL_FINITE);
    const stripped = stripLeading(self_d.coeff);
    const drop_i: i64 = -self_d.exp;
    const drop_u: usize = @intCast(drop_i);
    if (drop_u >= stripped.len) {
        const rounded = try roundOff(a, self_d.sign, stripped, drop_u, rounding_mode);
        defer a.free(rounded);
        return try newDec(interp, self_d.sign, rounded, 0, SPECIAL_FINITE);
    }
    const rounded = try roundOff(a, self_d.sign, stripped, drop_u, rounding_mode);
    defer a.free(rounded);
    return try newDec(interp, self_d.sign, rounded, 0, SPECIAL_FINITE);
}

// ===== Module-level functions =====

fn getcontextFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    return interp.decimal_active_context.?;
}

fn setcontextFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) {
        try interp.typeError("setcontext: arg must be Context");
        return error.TypeError;
    }
    interp.decimal_active_context = args[0];
    return Value.none;
}

fn localcontextFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    // Snapshot current ctx into a fresh Context instance.
    const cur = interp.decimal_active_context orelse return error.TypeError;
    if (cur != .instance) return error.TypeError;
    const inst = try Instance.init(a, interp.decimal_context_class.?);
    if (cur.instance.dict.getStr("prec")) |p_v| try inst.dict.setStr(a, "prec", p_v);
    if (cur.instance.dict.getStr("rounding")) |r_v| try inst.dict.setStr(a, "rounding", r_v);
    return Value{ .instance = inst };
}

fn ctxEnterFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len != 1 or args[0] != .instance) return error.TypeError;
    // Save current as `_saved_ctx` on self, install self as active.
    const cur = interp.decimal_active_context orelse return error.TypeError;
    try args[0].instance.dict.setStr(a, "_saved_ctx", cur);
    interp.decimal_active_context = args[0];
    return args[0];
}

fn ctxExitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    if (args[0].instance.dict.getStr("_saved_ctx")) |saved| {
        interp.decimal_active_context = saved;
    }
    return Value{ .boolean = false };
}
