//! Pinhole `sys`: enough surface for the fixture probes — version_info,
//! byteorder, maxsize, modules, path, argv, getrecursionlimit, exc_info,
//! and a stdout proxy with `write`/`flush`.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Tuple = @import("../object/tuple.zig").Tuple;
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const NamedTupleFactory = @import("../object/named_tuple.zig").NamedTupleFactory;
const NamedTuple = @import("../object/named_tuple.zig").NamedTuple;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "sys");

    // version_info as named tuple with major/minor/micro/releaselevel/serial
    const vi_factory = try NamedTupleFactory.init(a, "version_info",
        &.{ "major", "minor", "micro", "releaselevel", "serial" });
    const vi_items = [_]Value{
        Value{ .small_int = 3 },
        Value{ .small_int = 14 },
        Value{ .small_int = 0 },
        Value{ .str = try Str.init(a, "final") },
        Value{ .small_int = 0 },
    };
    const vi = try NamedTuple.init(a, vi_factory, &vi_items);
    try m.attrs.setStr(a, "version_info", Value{ .named_tuple = vi });

    try m.attrs.setStr(a, "version", Value{ .str = try Str.init(a, "3.14.0 (zag)") });
    try m.attrs.setStr(a, "byteorder", Value{ .str = try Str.init(a, "little") });
    try m.attrs.setStr(a, "maxsize", Value{ .small_int = std.math.maxInt(i64) });
    try m.attrs.setStr(a, "platform", Value{ .str = try Str.init(a, "linux") });

    const path = try List.init(a);
    try m.attrs.setStr(a, "path", Value{ .list = path });

    const argv = try List.init(a);
    try argv.append(a, Value{ .str = try Str.init(a, "") });
    try m.attrs.setStr(a, "argv", Value{ .list = argv });

    // sys.modules: keyed by name; "sys" included so `"sys" in sys.modules` is True.
    const modules = try Dict.init(a);
    try modules.setStr(a, "sys", Value{ .module = m });
    try m.attrs.setStr(a, "modules", Value{ .dict = modules });

    try reg(interp, m, "getrecursionlimit", getrecursionlimitFn);
    try reg(interp, m, "setrecursionlimit", setrecursionlimitFn);
    try reg(interp, m, "exc_info", excInfoFn);
    try reg(interp, m, "exit", exitFn);

    // stdout proxy with write/flush bound methods.
    const stdout_inst = try buildStdProxy(interp, false);
    try m.attrs.setStr(a, "stdout", Value{ .instance = stdout_inst });
    const stderr_inst = try buildStdProxy(interp, true);
    try m.attrs.setStr(a, "stderr", Value{ .instance = stderr_inst });

    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn buildStdProxy(interp: *Interp, is_stderr: bool) !*Instance {
    const a = interp.allocator;
    if (interp.sys_stream_class == null) {
        const dict = try Dict.init(a);
        const wf = try a.create(BuiltinFn);
        wf.* = .{ .name = "write", .func = writeFn };
        try dict.setStr(a, "write", Value{ .builtin_fn = wf });
        const ff = try a.create(BuiltinFn);
        ff.* = .{ .name = "flush", .func = flushFn };
        try dict.setStr(a, "flush", Value{ .builtin_fn = ff });
        const cls = try Class.init(a, "_StdStream", &.{}, dict);
        interp.sys_stream_class = cls;
    }
    const inst = try Instance.init(a, interp.sys_stream_class.?);
    try inst.dict.setStr(a, "_is_stderr", Value{ .boolean = is_stderr });
    const name_str = if (is_stderr) "<stderr>" else "<stdout>";
    try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, name_str) });
    try inst.dict.setStr(a, "mode", Value{ .str = try Str.init(a, "w") });
    try inst.dict.setStr(a, "closed", Value{ .boolean = false });
    try inst.dict.setStr(a, "encoding", Value{ .str = try Str.init(a, "utf-8") });
    return inst;
}

fn writeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance or args[1] != .str) {
        try interp.typeError("write expects (self, str)");
        return error.TypeError;
    }
    const is_err = blk: {
        const v = args[0].instance.dict.getStr("_is_stderr") orelse Value{ .boolean = false };
        break :blk v == .boolean and v.boolean;
    };
    const w = if (is_err) interp.stderr else interp.stdout;
    try w.writeAll(args[1].str.bytes);
    return Value{ .small_int = @intCast(args[1].str.bytes.len) };
}

fn flushFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const is_err = blk: {
        const v = args[0].instance.dict.getStr("_is_stderr") orelse Value{ .boolean = false };
        break :blk v == .boolean and v.boolean;
    };
    const w = if (is_err) interp.stderr else interp.stdout;
    try w.flush();
    return Value.none;
}

fn getrecursionlimitFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .small_int = interp.recursion_limit };
}

fn setrecursionlimitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .small_int) {
        try interp.typeError("setrecursionlimit expects int");
        return error.TypeError;
    }
    interp.recursion_limit = args[0].small_int;
    return Value.none;
}

fn excInfoFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const t = try Tuple.init(a, 3);
    if (interp.handling_exc) |e| {
        if (e == .instance) {
            t.items[0] = Value{ .class = e.instance.cls };
            t.items[1] = e;
            t.items[2] = e.instance.dict.getStr("__traceback__") orelse Value.none;
            return Value{ .tuple = t };
        }
    }
    t.items[0] = Value.none;
    t.items[1] = Value.none;
    t.items[2] = Value.none;
    return Value{ .tuple = t };
}

fn exitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const arg: Value = if (args.len > 0) args[0] else Value.none;
    try interp.raisePyValue("SystemExit", arg);
    return error.PyException;
}
