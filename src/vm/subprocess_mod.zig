//! Pinhole `subprocess` module: run, check_output, CompletedProcess, PIPE/DEVNULL/STDOUT.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Bytes = @import("../object/bytes.zig").Bytes;
const Interp = @import("interp.zig").Interp;

const PIPE: i64 = -1;
const STDOUT: i64 = -2;
const DEVNULL: i64 = -3;

fn getOrCreateCpClass(interp: *Interp) !*Class {
    if (interp.subprocess_module) |m| {
        if (m.attrs.getStr("CompletedProcess")) |v| if (v == .class) return v.class;
    }
    const a = interp.allocator;
    const d = try Dict.init(a);
    const cls = try Class.init(a, "CompletedProcess", &.{}, d);
    if (interp.subprocess_module) |m| {
        try m.attrs.setStr(a, "CompletedProcess", Value{ .class = cls });
    }
    return cls;
}

fn makeCp(interp: *Interp, cmd: Value, rc: i64, stdout_v: Value, stderr_v: Value) !Value {
    const a = interp.allocator;
    const cls = try getOrCreateCpClass(interp);
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "args", cmd);
    try inst.dict.setStr(a, "returncode", Value{ .small_int = rc });
    try inst.dict.setStr(a, "stdout", stdout_v);
    try inst.dict.setStr(a, "stderr", stderr_v);
    return Value{ .instance = inst };
}

fn buildArgv(a: std.mem.Allocator, cmd_v: Value) ![][]u8 {
    switch (cmd_v) {
        .list => |lst| {
            const argv = try a.alloc([]u8, lst.items.items.len);
            for (lst.items.items, 0..) |item, i| {
                argv[i] = if (item == .str) try a.dupe(u8, item.str.bytes) else try a.dupe(u8, "");
            }
            return argv;
        },
        .tuple => |t| {
            const argv = try a.alloc([]u8, t.items.len);
            for (t.items, 0..) |item, i| {
                argv[i] = if (item == .str) try a.dupe(u8, item.str.bytes) else try a.dupe(u8, "");
            }
            return argv;
        },
        .str => |s| {
            const argv = try a.alloc([]u8, 1);
            argv[0] = try a.dupe(u8, s.bytes);
            return argv;
        },
        else => return error.TypeError,
    }
}

fn freeArgv(a: std.mem.Allocator, argv: [][]u8) void {
    for (argv) |arg| a.free(arg);
    a.free(argv);
}

fn runKwFn(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.typeError("subprocess.run() requires at least one argument");
        return error.TypeError;
    }
    const cmd_v = args[0];

    var capture_output = false;
    var text_mode = false;
    var stdout_pipe = false;
    var stderr_pipe = false;
    var do_check = false;

    for (kn, kv) |k, v| {
        if (k != .str) continue;
        const name = k.str.bytes;
        if (std.mem.eql(u8, name, "capture_output")) {
            if (v == .boolean) capture_output = v.boolean;
        } else if (std.mem.eql(u8, name, "text")) {
            if (v == .boolean) text_mode = v.boolean;
        } else if (std.mem.eql(u8, name, "stdout")) {
            if (v == .small_int and v.small_int == PIPE) stdout_pipe = true;
        } else if (std.mem.eql(u8, name, "stderr")) {
            if (v == .small_int and v.small_int == PIPE) stderr_pipe = true;
        } else if (std.mem.eql(u8, name, "check")) {
            if (v == .boolean) do_check = v.boolean;
        }
    }
    if (capture_output) {
        stdout_pipe = true;
        stderr_pipe = true;
    }

    const argv_const = buildArgv(a, cmd_v) catch {
        try interp.typeError("subprocess: args must be list/tuple/str");
        return error.TypeError;
    };
    defer freeArgv(a, argv_const);

    // Always collect stdout+stderr via run(); if not piped we discard.
    const const_argv: []const []const u8 = @ptrCast(argv_const);
    const result = std.process.run(a, interp.io, .{ .argv = const_argv }) catch |err| {
        try interp.raisePy("OSError", @errorName(err));
        return error.PyException;
    };
    defer a.free(result.stdout);
    defer a.free(result.stderr);

    const rc: i64 = switch (result.term) {
        .exited => |code| @intCast(code),
        else => -1,
    };

    const stdout_val: Value = if (stdout_pipe or capture_output) blk: {
        if (text_mode) {
            break :blk Value{ .str = try Str.init(a, result.stdout) };
        } else {
            const b = try Bytes.init(a, result.stdout);
            break :blk Value{ .bytes = b };
        }
    } else Value.none;

    const stderr_val: Value = if (stderr_pipe or capture_output) blk: {
        if (text_mode) {
            break :blk Value{ .str = try Str.init(a, result.stderr) };
        } else {
            const b = try Bytes.init(a, result.stderr);
            break :blk Value{ .bytes = b };
        }
    } else Value.none;

    if (do_check and rc != 0) {
        try interp.raisePy("CalledProcessError", "Command returned non-zero exit status");
        return error.PyException;
    }

    return makeCp(interp, cmd_v, rc, stdout_val, stderr_val);
}

fn runFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return runKwFn(p, args, &.{}, &.{});
}

fn checkOutputKwFn(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;

    var new_kn = try a.alloc(Value, kn.len + 1);
    defer a.free(new_kn);
    var new_kv = try a.alloc(Value, kv.len + 1);
    defer a.free(new_kv);
    @memcpy(new_kn[0..kn.len], kn);
    @memcpy(new_kv[0..kv.len], kv);
    new_kn[kn.len] = Value{ .str = try Str.init(a, "capture_output") };
    new_kv[kv.len] = Value{ .boolean = true };

    const result = try runKwFn(p, args, new_kn, new_kv);
    if (result != .instance) return Value.none;
    return result.instance.dict.getStr("stdout") orelse Value.none;
}

fn checkOutputFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return checkOutputKwFn(p, args, &.{}, &.{});
}

fn reg(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    _ = reg;
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "subprocess");
    interp.subprocess_module = m;

    try regKw(a, m, "run", runFn, runKwFn);
    try regKw(a, m, "check_output", checkOutputFn, checkOutputKwFn);

    try m.attrs.setStr(a, "PIPE", Value{ .small_int = PIPE });
    try m.attrs.setStr(a, "STDOUT", Value{ .small_int = STDOUT });
    try m.attrs.setStr(a, "DEVNULL", Value{ .small_int = DEVNULL });

    _ = try getOrCreateCpClass(interp);

    return m;
}
