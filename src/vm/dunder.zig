//! Dunder dispatch helpers. User-defined classes can override
//! arithmetic, comparison, container, conversion, and call protocols
//! by defining `__add__`, `__eq__`, `__getitem__`, `__call__`, etc.
//! These helpers hide the boilerplate: look up the method on the
//! class via MRO, prepend `self`, and invoke it. NotImplemented
//! sentinels stay visible to the caller so binop reflection can fall
//! through to the right operand.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;

const Interp = @import("interp.zig").Interp;

/// Walk the instance's class MRO looking for `name`. Returns the
/// resolved attribute (typically a function), or null if absent.
pub fn lookup(instance: Value, name: []const u8) ?Value {
    if (instance != .instance) return null;
    return instance.instance.cls.lookup(name);
}

/// Invoke `instance.<name>(extra...)` if the dunder exists. Returns
/// null if not found. The result may be `.not_implemented`; the caller
/// decides whether to fall through or raise.
pub fn call(interp: *Interp, instance: Value, name: []const u8, extra: []const Value) anyerror!?Value {
    const m = lookup(instance, name) orelse return null;
    var stack_buf: [8]Value = undefined;
    const total = extra.len + 1;
    const args = if (total <= stack_buf.len) stack_buf[0..total] else try interp.allocator.alloc(Value, total);
    defer if (total > stack_buf.len) interp.allocator.free(args);
    args[0] = instance;
    @memcpy(args[1..], extra);
    return try @import("dispatch.zig").invoke(interp, m, args);
}

/// Try `a.__op__(b)` then `b.__rop__(a)`. Returns null if neither
/// dunder applies (or both returned NotImplemented), so the caller
/// can fall through to the built-in operand types.
pub fn binop(
    interp: *Interp,
    a: Value,
    b: Value,
    op_name: []const u8,
    rop_name: []const u8,
) !?Value {
    if (a == .instance) {
        if (try call(interp, a, op_name, &.{b})) |r| {
            if (r != .not_implemented) return r;
        }
    }
    if (b == .instance) {
        if (try call(interp, b, rop_name, &.{a})) |r| {
            if (r != .not_implemented) return r;
        }
    }
    return null;
}

/// CPython 3.14 COMPARE_OP kinds: 0 `<`, 1 `<=`, 2 `==`, 3 `!=`,
/// 4 `>`, 5 `>=`. Returns null when neither side defines the dunder
/// (or both returned NotImplemented), so default semantics (identity
/// for `==`, TypeError for ordering) take over.
pub fn compare(interp: *Interp, a: Value, b: Value, kind: u3) !?bool {
    const fwd: []const u8 = switch (kind) {
        0 => "__lt__",
        1 => "__le__",
        2 => "__eq__",
        3 => "__ne__",
        4 => "__gt__",
        5 => "__ge__",
        else => return null,
    };
    const rev: []const u8 = switch (kind) {
        0 => "__gt__",
        1 => "__ge__",
        2 => "__eq__",
        3 => "__ne__",
        4 => "__lt__",
        5 => "__le__",
        else => return null,
    };
    if (a == .instance) {
        if (try call(interp, a, fwd, &.{b})) |r| {
            if (r != .not_implemented) return r.isTruthy();
        }
    }
    if (b == .instance) {
        if (try call(interp, b, rev, &.{a})) |r| {
            if (r != .not_implemented) return r.isTruthy();
        }
    }
    return null;
}

/// Interp-aware equality: routes through `__eq__` when either side
/// is a user instance, otherwise falls back to `Value.equals`. Used
/// by dict/set whose default equality is identity for instances.
pub fn valuesEqual(interp: *Interp, a: Value, b: Value) !bool {
    if (a == .instance or b == .instance) {
        if (try compare(interp, a, b, 2)) |eq| return eq;
    }
    return a.equals(b);
}
