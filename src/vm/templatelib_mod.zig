//! Pinhole `string.templatelib` module: Template, Interpolation, convert.
//!
//! The runtime objects already exist (BUILD_TEMPLATE / BUILD_INTERPOLATION
//! produce them via `interp.template_class` / `interp.interpolation_class`).
//! This module exports the same classes for `from string.templatelib import
//! Template, Interpolation, convert` and adds the small surface — manual
//! constructors, repr (in value.zig), iteration, concatenation, convert().

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Tuple = @import("../object/tuple.zig").Tuple;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const List = @import("../object/list.zig").List;
const Iter = @import("../object/iter.zig").Iter;
const Interp = @import("interp.zig").Interp;
const strmethods = @import("strmethods.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "string.templatelib");
    try ensureClasses(interp);
    try regCtor(interp, m, "Template", templateCtor);
    try regCtor(interp, m, "Interpolation", interpolationCtor);
    try regFn(interp, m, "convert", convertFn);
    return m;
}

fn regCtor(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regFn(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

pub fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;
    if (interp.template_class == null) {
        const d = try Dict.init(a);
        interp.template_class = try Class.init(a, "Template", &.{}, d);
    }
    // Always (re)wire methods — safe to call repeatedly with setStr.
    const td = interp.template_class.?.dict;
    if (td.getStr("__add__") == null) {
        try methodReg(a, td, "__add__", templateAdd);
        try methodReg(a, td, "__iter__", templateIter);
    }
    if (interp.interpolation_class == null) {
        const d2 = try Dict.init(a);
        interp.interpolation_class = try Class.init(a, "Interpolation", &.{}, d2);
    }
}

fn newTemplate(interp: *Interp, strings: Value, interpolations: Value) !Value {
    try ensureClasses(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.template_class.?);
    try inst.dict.setStr(a, "strings", strings);
    try inst.dict.setStr(a, "interpolations", interpolations);
    if (interpolations == .tuple) {
        const vt = try Tuple.init(a, interpolations.tuple.items.len);
        for (interpolations.tuple.items, 0..) |it, i| {
            if (it == .instance) {
                vt.items[i] = it.instance.dict.getStr("value") orelse Value.none;
            } else vt.items[i] = Value.none;
        }
        try inst.dict.setStr(a, "values", Value{ .tuple = vt });
    }
    return Value{ .instance = inst };
}

fn isInterp(v: Value) bool {
    return v == .instance and std.mem.eql(u8, v.instance.cls.name, "Interpolation");
}

fn isTemplate(v: Value) bool {
    return v == .instance and std.mem.eql(u8, v.instance.cls.name, "Template");
}

fn emptyStr(a: std.mem.Allocator) !Value {
    return Value{ .str = try Str.init(a, "") };
}

/// Manual Template constructor: takes a sequence of (str | Interpolation)
/// args and normalizes to (strings, interpolations) such that
/// len(strings) == len(interpolations) + 1, with consecutive strings
/// merged and consecutive Interpolations separated by ''.
fn templateCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;

    var strings: std.ArrayList(Value) = .empty;
    defer strings.deinit(a);
    var interps: std.ArrayList(Value) = .empty;
    defer interps.deinit(a);

    var pending_str: std.ArrayList(u8) = .empty;
    defer pending_str.deinit(a);

    // Always start with at least one (possibly empty) string.
    var has_pending = false;

    for (args) |x| {
        if (x == .str) {
            try pending_str.appendSlice(a, x.str.bytes);
            has_pending = true;
        } else if (isInterp(x)) {
            // Flush pending string (or empty string if none).
            if (has_pending) {
                const owned = try pending_str.toOwnedSlice(a);
                pending_str = .empty;
                try strings.append(a, Value{ .str = try Str.fromOwnedSlice(a, owned) });
                has_pending = false;
            } else {
                // No pending string — either start of args, or right
                // after another interp. In both cases we need an ''.
                try strings.append(a, try emptyStr(a));
            }
            try interps.append(a, x);
        } else {
            try interp.typeError("Template() arguments must be str or Interpolation");
            return error.TypeError;
        }
    }
    // Final string (may be empty).
    if (has_pending) {
        const owned = try pending_str.toOwnedSlice(a);
        pending_str = .empty;
        try strings.append(a, Value{ .str = try Str.fromOwnedSlice(a, owned) });
    } else {
        try strings.append(a, try emptyStr(a));
    }

    const st = try Tuple.init(a, strings.items.len);
    for (strings.items, 0..) |s, i| st.items[i] = s;
    const it = try Tuple.init(a, interps.items.len);
    for (interps.items, 0..) |x, i| it.items[i] = x;

    return newTemplate(interp, Value{ .tuple = st }, Value{ .tuple = it });
}

fn interpolationCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) {
        try interp.typeError("Interpolation expects (value, expression, [conversion, [format_spec]])");
        return error.TypeError;
    }
    try ensureClasses(interp);
    const inst = try Instance.init(a, interp.interpolation_class.?);
    try inst.dict.setStr(a, "value", args[0]);
    try inst.dict.setStr(a, "expression", args[1]);
    const conv: Value = if (args.len >= 3) args[2] else Value.none;
    try inst.dict.setStr(a, "conversion", conv);
    const fs: Value = if (args.len >= 4) args[3] else Value{ .str = try Str.init(a, "") };
    try inst.dict.setStr(a, "format_spec", fs);
    return Value{ .instance = inst };
}

fn convertFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) {
        try interp.typeError("convert(value, conversion)");
        return error.TypeError;
    }
    if (args[1] == .none) return args[0];
    if (args[1] != .str or args[1].str.bytes.len != 1) {
        try interp.typeError("convert: conversion must be 's'/'r'/'a' or None");
        return error.TypeError;
    }
    return strmethods.convertField(interp, args[0], args[1].str.bytes[0]);
}

/// Template.__add__: merge two templates. The trailing string of self
/// concatenates with the leading string of other.
fn templateAdd(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or !isTemplate(args[0]) or !isTemplate(args[1])) {
        try interp.typeError("Template.__add__: expected (Template, Template)");
        return error.TypeError;
    }
    const left = args[0].instance;
    const right = args[1].instance;
    const lstrs = left.dict.getStr("strings") orelse return error.TypeError;
    const linterps = left.dict.getStr("interpolations") orelse return error.TypeError;
    const rstrs = right.dict.getStr("strings") orelse return error.TypeError;
    const rinterps = right.dict.getStr("interpolations") orelse return error.TypeError;
    if (lstrs != .tuple or linterps != .tuple or rstrs != .tuple or rinterps != .tuple) {
        try interp.typeError("Template fields must be tuples");
        return error.TypeError;
    }
    const ls = lstrs.tuple.items;
    const rs = rstrs.tuple.items;
    const li = linterps.tuple.items;
    const ri = rinterps.tuple.items;
    // Glue ls[-1] + rs[0].
    const glue_left: []const u8 = if (ls.len > 0 and ls[ls.len - 1] == .str) ls[ls.len - 1].str.bytes else "";
    const glue_right: []const u8 = if (rs.len > 0 and rs[0] == .str) rs[0].str.bytes else "";
    var glued: std.ArrayList(u8) = .empty;
    defer glued.deinit(a);
    try glued.appendSlice(a, glue_left);
    try glued.appendSlice(a, glue_right);
    const glued_owned = try glued.toOwnedSlice(a);
    const glued_str = Value{ .str = try Str.fromOwnedSlice(a, glued_owned) };

    const total_strings = if (ls.len + rs.len > 0) ls.len + rs.len - 1 else 0;
    const new_strs = try Tuple.init(a, total_strings);
    var idx: usize = 0;
    if (ls.len > 0) {
        for (ls[0 .. ls.len - 1]) |s| {
            new_strs.items[idx] = s;
            idx += 1;
        }
        new_strs.items[idx] = glued_str;
        idx += 1;
        if (rs.len > 1) {
            for (rs[1..]) |s| {
                new_strs.items[idx] = s;
                idx += 1;
            }
        }
    } else {
        for (rs) |s| {
            new_strs.items[idx] = s;
            idx += 1;
        }
    }

    const new_interps = try Tuple.init(a, li.len + ri.len);
    var k: usize = 0;
    for (li) |x| {
        new_interps.items[k] = x;
        k += 1;
    }
    for (ri) |x| {
        new_interps.items[k] = x;
        k += 1;
    }

    return newTemplate(interp, Value{ .tuple = new_strs }, Value{ .tuple = new_interps });
}

/// Template.__iter__: yields strings and interpolations interleaved,
/// dropping empty strings (CPython skips them).
fn templateIter(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or !isTemplate(args[0])) {
        try interp.typeError("Template.__iter__: expected Template");
        return error.TypeError;
    }
    const inst = args[0].instance;
    const strs = inst.dict.getStr("strings") orelse Value.none;
    const interps = inst.dict.getStr("interpolations") orelse Value.none;
    const out = try List.init(a);
    if (strs == .tuple and interps == .tuple) {
        const ss = strs.tuple.items;
        const is = interps.tuple.items;
        var i: usize = 0;
        while (i < ss.len) : (i += 1) {
            if (ss[i] == .str and ss[i].str.bytes.len > 0) try out.append(a, ss[i]);
            if (i < is.len) try out.append(a, is[i]);
        }
    }
    return Value{ .iter = try Iter.init(a, .{ .list = out }) };
}
