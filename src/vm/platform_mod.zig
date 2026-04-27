//! Pinhole `platform` module: system(), machine(), python_version(), etc.

const std = @import("std");
const builtin = @import("builtin");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Tuple = @import("../object/tuple.zig").Tuple;
const Interp = @import("interp.zig").Interp;

fn strFn(comptime s: []const u8) BuiltinFnPtr {
    return struct {
        fn f(p: *anyopaque, args: []const Value) anyerror!Value {
            _ = args;
            const interp: *Interp = @ptrCast(@alignCast(p));
            const str = try Str.init(interp.allocator, s);
            return Value{ .str = str };
        }
    }.f;
}

fn systemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = comptime switch (builtin.os.tag) {
        .macos => "Darwin",
        .linux => "Linux",
        .windows => "Windows",
        else => "Unknown",
    };
    return Value{ .str = try Str.init(interp.allocator, s) };
}

fn machineFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = comptime switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        .arm => "armv7l",
        else => "unknown",
    };
    return Value{ .str = try Str.init(interp.allocator, s) };
}

fn pythonVersionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, "3.14.4") };
}

fn pythonImplementationFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, "CPython") };
}

fn pythonVersionTupleFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const t = try Tuple.init(a, 3);
    t.items[0] = Value{ .str = try Str.init(a, "3") };
    t.items[1] = Value{ .str = try Str.init(a, "14") };
    t.items[2] = Value{ .str = try Str.init(a, "4") };
    return Value{ .tuple = t };
}

fn nodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&buf) catch "localhost";
    return Value{ .str = try Str.init(a, hostname) };
}

fn architectureFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const t = try Tuple.init(a, 2);
    const bits = comptime if (@sizeOf(usize) == 8) "64bit" else "32bit";
    t.items[0] = Value{ .str = try Str.init(a, bits) };
    t.items[1] = Value{ .str = try Str.init(a, "") };
    return Value{ .tuple = t };
}

fn releaseFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, "") };
}

fn versionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, "CPython 3.14.4") };
}

fn processorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return machineFn(p, args);
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "platform");
    try reg(interp, m, "system", systemFn);
    try reg(interp, m, "machine", machineFn);
    try reg(interp, m, "python_version", pythonVersionFn);
    try reg(interp, m, "python_implementation", pythonImplementationFn);
    try reg(interp, m, "python_version_tuple", pythonVersionTupleFn);
    try reg(interp, m, "node", nodeFn);
    try reg(interp, m, "architecture", architectureFn);
    try reg(interp, m, "release", releaseFn);
    try reg(interp, m, "version", versionFn);
    try reg(interp, m, "processor", processorFn);
    try reg(interp, m, "platform", strFn(""));
    try reg(interp, m, "uname", architectureFn); // stub
    return m;
}
