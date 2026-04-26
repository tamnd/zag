//! Pinhole `numbers` module: the abstract numeric tower
//! `Number` -> `Complex` -> `Real` -> `Rational` -> `Integral`.
//! Each ABC carries an `abc_kind` so `isinstance(v, cls)` is true
//! for the right built-in numeric values, and the inheritance chain
//! gives `issubclass(Integral, Number)` etc. for free via MRO.
//! `register()` is reused from the `collections.abc` machinery -- it
//! appends to `abc_registered`, which `isInstanceOfAbc` already walks.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Class = @import("../object/class.zig").Class;
const AbcKind = @import("../object/class.zig").AbcKind;
const Dict = @import("../object/dict.zig").Dict;
const Descriptor = @import("../object/descriptor.zig").Descriptor;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "numbers");
    const number = try makeAbc(interp, "Number", &.{}, .number);
    const complex_ = try makeAbc(interp, "Complex", &.{number}, .complex_);
    const real = try makeAbc(interp, "Real", &.{complex_}, .real);
    const rational = try makeAbc(interp, "Rational", &.{real}, .rational);
    const integral = try makeAbc(interp, "Integral", &.{rational}, .integral);
    try m.attrs.setStr(a, "Number", Value{ .class = number });
    try m.attrs.setStr(a, "Complex", Value{ .class = complex_ });
    try m.attrs.setStr(a, "Real", Value{ .class = real });
    try m.attrs.setStr(a, "Rational", Value{ .class = rational });
    try m.attrs.setStr(a, "Integral", Value{ .class = integral });
    return m;
}

fn makeAbc(
    interp: *Interp,
    name: []const u8,
    bases: []const *Class,
    kind: AbcKind,
) !*Class {
    const a = interp.allocator;
    const dict = try Dict.init(a);
    const cls = try Class.init(a, name, bases, dict);
    cls.abc_kind = kind;
    const reg_fn = try a.create(BuiltinFn);
    reg_fn.* = .{ .name = "register", .func = abcRegister };
    const reg_desc = try Descriptor.init(a, .classmethod, Value{ .builtin_fn = reg_fn });
    try dict.setStr(a, "register", Value{ .descriptor = reg_desc });
    return cls;
}

fn abcRegister(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 2 or args[0] != .class or args[1] != .class) {
        try interp.typeError("register expects (abc_class, target_class)");
        return error.TypeError;
    }
    const abc_cls = args[0].class;
    if (abc_cls.abc_kind == null) {
        try interp.typeError("register requires an ABC class");
        return error.TypeError;
    }
    try abc_cls.abc_registered.append(interp.allocator, args[1].class);
    return args[1];
}
