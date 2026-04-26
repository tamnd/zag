//! Pinhole `os`. Just enough surface for fixtures: `remove`/`unlink`.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "os");
    try reg(interp, m, "remove", removeFn);
    try reg(interp, m, "unlink", removeFn);
    const path = try Module.init(a, "os.path");
    try reg(interp, path, "join", pathJoinFn);
    try m.attrs.setStr(a, "path", Value{ .module = path });
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn pathJoinFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for (args) |arg| {
        if (arg != .str) continue;
        const s = arg.str.bytes;
        if (s.len > 0 and s[0] == '/') {
            out.clearRetainingCapacity();
            try out.appendSlice(a, s);
        } else if (out.items.len > 0 and out.items[out.items.len - 1] != '/') {
            try out.append(a, '/');
            try out.appendSlice(a, s);
        } else {
            try out.appendSlice(a, s);
        }
    }
    const Str = @import("../object/string.zig").Str;
    const s = try Str.init(a, out.items);
    return Value{ .str = s };
}

fn removeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("os.remove expects a path");
        return error.TypeError;
    }
    std.Io.Dir.cwd().deleteFile(interp.io, args[0].str.bytes) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", args[0].str.bytes);
            return error.PyException;
        },
        else => return err,
    };
    return Value.none;
}
