//! Pinhole `platform` module: system(), machine(), python_version(), uname(), etc.

const std = @import("std");
const builtin = @import("builtin");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Tuple = @import("../object/tuple.zig").Tuple;
const Interp = @import("interp.zig").Interp;

const system_str: []const u8 = switch (builtin.os.tag) {
    .macos => "Darwin",
    .linux => "Linux",
    .windows => "Windows",
    else => "Unknown",
};

const machine_str: []const u8 = switch (builtin.cpu.arch) {
    .aarch64 => "arm64",
    .x86_64 => "x86_64",
    .arm => "armv7l",
    else => "unknown",
};

fn strFn(comptime s: []const u8) BuiltinFnPtr {
    return struct {
        fn f(p: *anyopaque, args: []const Value) anyerror!Value {
            _ = args;
            const interp: *Interp = @ptrCast(@alignCast(p));
            return Value{ .str = try Str.init(interp.allocator, s) };
        }
    }.f;
}

fn systemFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, system_str) };
}

fn machineFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, machine_str) };
}

fn pythonVersionFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, "3.14.4") };
}

fn pythonImplementationFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, "CPython") };
}

fn pythonVersionTupleFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const t = try Tuple.init(a, 3);
    t.items[0] = Value{ .str = try Str.init(a, "3") };
    t.items[1] = Value{ .str = try Str.init(a, "14") };
    t.items[2] = Value{ .str = try Str.init(a, "4") };
    return Value{ .tuple = t };
}

fn getHostname(allocator: std.mem.Allocator) []const u8 {
    if (comptime builtin.os.tag == .windows) return "localhost";
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const h = std.posix.gethostname(&buf) catch return "localhost";
    return allocator.dupe(u8, if (h.len > 0) h else "localhost") catch "localhost";
}

fn nodeFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, getHostname(interp.allocator)) };
}

fn architectureFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const t = try Tuple.init(a, 2);
    const bits = comptime if (@sizeOf(usize) == 8) "64bit" else "32bit";
    t.items[0] = Value{ .str = try Str.init(a, bits) };
    t.items[1] = Value{ .str = try Str.init(a, "") };
    return Value{ .tuple = t };
}

fn releaseFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, "") };
}

fn versionFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, "CPython 3.14.4") };
}

fn processorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return machineFn(p, args);
}

fn platformFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const node = getHostname(a);
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}-{s}", .{ system_str, node }) catch system_str;
    return Value{ .str = try Str.init(a, s) };
}

fn unameFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;

    const cls = try getUnameClass(interp);
    const inst = try Instance.init(a, cls);

    const node = getHostname(a);

    try inst.dict.setStr(a, "system",    Value{ .str = try Str.init(a, system_str) });
    try inst.dict.setStr(a, "node",      Value{ .str = try Str.init(a, if (node.len > 0) node else "localhost") });
    try inst.dict.setStr(a, "release",   Value{ .str = try Str.init(a, "") });
    try inst.dict.setStr(a, "version",   Value{ .str = try Str.init(a, "CPython 3.14.4") });
    try inst.dict.setStr(a, "machine",   Value{ .str = try Str.init(a, machine_str) });
    try inst.dict.setStr(a, "processor", Value{ .str = try Str.init(a, machine_str) });
    return Value{ .instance = inst };
}

fn getUnameClass(interp: *Interp) !*Class {
    if (interp.platform_uname_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const cls = try Class.init(a, "uname_result", &.{}, d);
    interp.platform_uname_class = cls;
    return cls;
}

fn win32VerFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const t = try Tuple.init(a, 4);
    t.items[0] = Value{ .str = try Str.init(a, "") };
    t.items[1] = Value{ .str = try Str.init(a, "") };
    t.items[2] = Value{ .str = try Str.init(a, "") };
    t.items[3] = Value{ .str = try Str.init(a, "") };
    return Value{ .tuple = t };
}

fn macVerFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const t = try Tuple.init(a, 3);
    t.items[0] = Value{ .str = try Str.init(a, "") };
    t.items[1] = Value{ .str = try Str.init(a, "") };
    t.items[2] = Value{ .str = try Str.init(a, "") };
    return Value{ .tuple = t };
}

fn pythonBuildFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const t = try Tuple.init(a, 2);
    t.items[0] = Value{ .str = try Str.init(a, "main") };
    t.items[1] = Value{ .str = try Str.init(a, "") };
    return Value{ .tuple = t };
}

fn pythonCompilerFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .str = try Str.init(interp.allocator, "Clang") };
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "platform");
    try reg(interp, m, "system",                 systemFn);
    try reg(interp, m, "machine",                machineFn);
    try reg(interp, m, "python_version",         pythonVersionFn);
    try reg(interp, m, "python_implementation",  pythonImplementationFn);
    try reg(interp, m, "python_version_tuple",   pythonVersionTupleFn);
    try reg(interp, m, "node",                   nodeFn);
    try reg(interp, m, "architecture",           architectureFn);
    try reg(interp, m, "release",                releaseFn);
    try reg(interp, m, "version",                versionFn);
    try reg(interp, m, "processor",              processorFn);
    try reg(interp, m, "platform",               platformFn);
    try reg(interp, m, "uname",                  unameFn);
    try reg(interp, m, "win32_ver",              win32VerFn);
    try reg(interp, m, "mac_ver",                macVerFn);
    try reg(interp, m, "python_build",           pythonBuildFn);
    try reg(interp, m, "python_compiler",        pythonCompilerFn);
    try reg(interp, m, "python_branch",          strFn("main"));
    try reg(interp, m, "python_revision",        strFn(""));
    return m;
}
