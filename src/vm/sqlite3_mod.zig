//! Pinhole `sqlite3`. Provides the exception hierarchy and module
//! attributes. No actual SQL engine — the fixture only tests the
//! class hierarchy, attribute presence, and exception catching.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Interp = @import("interp.zig").Interp;

fn makeExcClass(a: std.mem.Allocator, name: []const u8, base: *Class) !*Class {
    const d = try Dict.init(a);
    return Class.init(a, name, &.{base}, d);
}

fn getBuiltinExc(interp: *Interp, name: []const u8) !*Class {
    const v = interp.builtins.getStr(name) orelse {
        return error.NameError;
    };
    if (v != .class) return error.TypeError;
    return v.class;
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "sqlite3");

    // Exception base classes
    const exc_class = try getBuiltinExc(interp, "Exception");

    const warning_cls = try makeExcClass(a, "Warning", exc_class);
    const error_cls = try makeExcClass(a, "Error", exc_class);
    const db_error_cls = try makeExcClass(a, "DatabaseError", error_cls);
    const op_error_cls = try makeExcClass(a, "OperationalError", db_error_cls);
    const int_error_cls = try makeExcClass(a, "IntegrityError", db_error_cls);
    const prog_error_cls = try makeExcClass(a, "ProgrammingError", db_error_cls);
    const data_error_cls = try makeExcClass(a, "DataError", db_error_cls);
    const internal_error_cls = try makeExcClass(a, "InternalError", db_error_cls);
    const not_supported_cls = try makeExcClass(a, "NotSupportedError", db_error_cls);

    // Row class (just needs to be callable — no real implementation)
    const row_d = try Dict.init(a);
    const row_cls = try Class.init(a, "Row", &.{}, row_d);

    // connect stub
    const conn_fn = try a.create(BuiltinFn);
    conn_fn.* = .{ .name = "connect", .func = connectFn };

    try m.attrs.setStr(a, "connect", Value{ .builtin_fn = conn_fn });
    try m.attrs.setStr(a, "Error", Value{ .class = error_cls });
    try m.attrs.setStr(a, "Warning", Value{ .class = warning_cls });
    try m.attrs.setStr(a, "DatabaseError", Value{ .class = db_error_cls });
    try m.attrs.setStr(a, "OperationalError", Value{ .class = op_error_cls });
    try m.attrs.setStr(a, "IntegrityError", Value{ .class = int_error_cls });
    try m.attrs.setStr(a, "ProgrammingError", Value{ .class = prog_error_cls });
    try m.attrs.setStr(a, "DataError", Value{ .class = data_error_cls });
    try m.attrs.setStr(a, "InternalError", Value{ .class = internal_error_cls });
    try m.attrs.setStr(a, "NotSupportedError", Value{ .class = not_supported_cls });
    try m.attrs.setStr(a, "Row", Value{ .class = row_cls });

    const ver_str = try Str.init(a, "3.39.5");
    try m.attrs.setStr(a, "sqlite_version", Value{ .str = ver_str });

    const ver_tuple = try Tuple.init(a, 3);
    ver_tuple.items[0] = Value{ .small_int = 3 };
    ver_tuple.items[1] = Value{ .small_int = 39 };
    ver_tuple.items[2] = Value{ .small_int = 5 };
    try m.attrs.setStr(a, "sqlite_version_info", Value{ .tuple = ver_tuple });

    try m.attrs.setStr(a, "PARSE_DECLTYPES", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "PARSE_COLNAMES", Value{ .small_int = 2 });

    return m;
}

fn connectFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    try interp.raisePy("NotImplementedError", "sqlite3.connect not implemented");
    return error.PyException;
}
