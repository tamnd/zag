//! Pinhole `getpass` module: getuser(), getpass() stub, GetPassWarning.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

fn getUserFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (interp.env_map) |em| {
        const keys = [_][]const u8{ "USER", "LOGNAME", "USERNAME" };
        for (keys) |k| {
            if (em.get(k)) |v| return Value{ .str = try Str.init(a, v) };
        }
    }
    return Value{ .str = try Str.init(a, "user") };
}

fn getPassFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return getPassImpl(p, args, &.{}, &.{});
}

fn getPassKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return getPassImpl(p, args, kn, kv);
}

fn getPassImpl(p: *anyopaque, _args: []const Value, _kn: []const Value, _kv: []const Value) anyerror!Value {
    _ = _args;
    _ = _kn;
    _ = _kv;
    const interp: *Interp = @ptrCast(@alignCast(p));
    // Non-interactive stub: return empty string
    return Value{ .str = try Str.init(interp.allocator, "") };
}

// GetPassWarning class - instantiable warning class
var getpass_warning_class: ?*Class = null;

fn getOrCreateWarningClass(interp: *Interp) !*Class {
    if (getpass_warning_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const cls = try Class.init(a, "GetPassWarning", &.{}, d);
    getpass_warning_class = cls;
    return cls;
}

fn getPassWarningInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    // args[0] is self (instance), args[1] is message
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    if (args.len >= 2) {
        try inst.dict.setStr(a, "message", args[1]);
        // Also store as args tuple for Exception compatibility
        const Tuple = @import("../object/tuple.zig").Tuple;
        const t = try Tuple.init(a, 1);
        t.items[0] = args[1];
        try inst.dict.setStr(a, "args", Value{ .tuple = t });
    }
    return Value.none;
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "getpass");

    const f_user = try a.create(BuiltinFn);
    f_user.* = .{ .name = "getuser", .func = getUserFn };
    try m.attrs.setStr(a, "getuser", Value{ .builtin_fn = f_user });

    const f_pass = try a.create(BuiltinFn);
    f_pass.* = .{ .name = "getpass", .func = getPassFn, .kw_func = getPassKw };
    try m.attrs.setStr(a, "getpass", Value{ .builtin_fn = f_pass });

    // GetPassWarning as a class (isinstance(GetPassWarning, type) == True)
    getpass_warning_class = null;
    const warn_cls = try getOrCreateWarningClass(interp);
    try m.attrs.setStr(a, "GetPassWarning", Value{ .class = warn_cls });

    // Register __init__ so GetPassWarning('msg') works
    const f_warn = try a.create(BuiltinFn);
    f_warn.* = .{ .name = "GetPassWarning.__init__", .func = getPassWarningInitFn };
    try warn_cls.dict.setStr(a, "__init__", Value{ .builtin_fn = f_warn });

    return m;
}
