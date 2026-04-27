//! Pinhole `getpass` module: getuser(), getpass() stub.

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

fn getUserFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    // Try $USER, then $LOGNAME, then $USERNAME via interp.env_map, then fall back.
    if (interp.env_map) |em| {
        const keys = [_][]const u8{ "USER", "LOGNAME", "USERNAME" };
        for (keys) |k| {
            if (em.get(k)) |v| return Value{ .str = try Str.init(a, v) };
        }
    }
    return Value{ .str = try Str.init(a, "user") };
}

fn getPassFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    // Non-interactive stub: return empty string
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, "") };
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "getpass");

    const f_user = try a.create(BuiltinFn);
    f_user.* = .{ .name = "getuser", .func = getUserFn };
    try m.attrs.setStr(a, "getuser", Value{ .builtin_fn = f_user });

    const f_pass = try a.create(BuiltinFn);
    f_pass.* = .{ .name = "getpass", .func = getPassFn };
    try m.attrs.setStr(a, "getpass", Value{ .builtin_fn = f_pass });

    return m;
}
