//! Pinhole `logging.handlers`: rotating, memory, queue, and stub handlers.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");
const logging_mod = @import("logging_mod.zig");
const file_io = @import("file_io.zig");

const NOTSET: i64 = 0;
const DEBUG: i64 = 10;
const INFO: i64 = 20;
const WARNING: i64 = 30;
const ERROR: i64 = 40;
const CRITICAL: i64 = 50;

fn reg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regMod(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn argInst(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

fn handlerSetLevel(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const level: i64 = if (args[1] == .small_int) args[1].small_int else NOTSET;
    try args[0].instance.dict.setStr(a, "_level", Value{ .small_int = level });
    return Value.none;
}

fn handlerSetFormatter(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    try args[0].instance.dict.setStr(a, "_formatter", args[1]);
    return Value.none;
}

fn handlerClose(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    if (inst.dict.getStr("_stream")) |sv| {
        if (sv == .instance) {
            const close_attr = dispatch.loadAttrValue(interp, sv, "close") catch return Value.none;
            _ = dispatch.invoke(interp, close_attr, &.{sv}) catch {};
        }
    }
    return Value.none;
}

// ===== RotatingFileHandler =====

fn rotatingInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const inst = args[0].instance;
    const filename = args[1].str.bytes;
    // mode arg may be keyword; look in positional args[2]
    const mode = if (args.len >= 3 and args[2] == .str) args[2].str.bytes else "a";
    const maxBytes: i64 = if (args.len >= 4 and args[3] == .small_int) args[3].small_int else 0;
    const backupCount: i64 = if (args.len >= 5 and args[4] == .small_int) args[4].small_int else 0;
    try logging_mod.fileHandlerOpen(interp, inst, filename, mode);
    try inst.dict.setStr(a, "_level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "_formatter", Value.none);
    try inst.dict.setStr(a, "_filters", Value{ .list = try List.init(a) });
    try inst.dict.setStr(a, "_maxBytes", Value{ .small_int = maxBytes });
    try inst.dict.setStr(a, "_backupCount", Value{ .small_int = backupCount });
    try inst.dict.setStr(a, "_filename", Value{ .str = try Str.init(a, filename) });
    try inst.dict.setStr(a, "_rotate_mode", Value{ .str = try Str.init(a, mode) });
    return Value.none;
}

fn rotatingKw(p: *anyopaque, args: []const Value, kw_keys: []const Value, kw_vals: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const inst = args[0].instance;
    const filename = args[1].str.bytes;

    var mode: []const u8 = "a";
    var maxBytes: i64 = 0;
    var backupCount: i64 = 0;

    for (kw_keys, kw_vals) |k, v| {
        if (k != .str) continue;
        if (std.mem.eql(u8, k.str.bytes, "mode") and v == .str) mode = v.str.bytes;
        if (std.mem.eql(u8, k.str.bytes, "maxBytes") and v == .small_int) maxBytes = v.small_int;
        if (std.mem.eql(u8, k.str.bytes, "backupCount") and v == .small_int) backupCount = v.small_int;
    }
    if (args.len >= 3 and args[2] == .str) mode = args[2].str.bytes;
    if (args.len >= 4 and args[3] == .small_int) maxBytes = args[3].small_int;
    if (args.len >= 5 and args[4] == .small_int) backupCount = args[4].small_int;

    try logging_mod.fileHandlerOpen(interp, inst, filename, mode);
    try inst.dict.setStr(a, "_level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "_formatter", Value.none);
    try inst.dict.setStr(a, "_filters", Value{ .list = try List.init(a) });
    try inst.dict.setStr(a, "_maxBytes", Value{ .small_int = maxBytes });
    try inst.dict.setStr(a, "_backupCount", Value{ .small_int = backupCount });
    try inst.dict.setStr(a, "_filename", Value{ .str = try Str.init(a, filename) });
    try inst.dict.setStr(a, "_rotate_mode", Value{ .str = try Str.init(a, mode) });
    return Value.none;
}

fn shouldRollover(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .boolean = false };
}

// ===== TimedRotatingFileHandler =====

fn timedRotatingInitKw(p: *anyopaque, args: []const Value, kw_keys: []const Value, kw_vals: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const inst = args[0].instance;
    const filename = args[1].str.bytes;

    var when: []const u8 = "h";
    var interval: i64 = 1;
    var backupCount: i64 = 0;

    for (kw_keys, kw_vals) |k, v| {
        if (k != .str) continue;
        if (std.mem.eql(u8, k.str.bytes, "when") and v == .str) when = v.str.bytes;
        if (std.mem.eql(u8, k.str.bytes, "interval") and v == .small_int) interval = v.small_int;
        if (std.mem.eql(u8, k.str.bytes, "backupCount") and v == .small_int) backupCount = v.small_int;
    }
    if (args.len >= 3 and args[2] == .str) when = args[2].str.bytes;
    if (args.len >= 4 and args[3] == .small_int) interval = args[3].small_int;
    if (args.len >= 5 and args[4] == .small_int) backupCount = args[4].small_int;

    try logging_mod.fileHandlerOpen(interp, inst, filename, "a");
    try inst.dict.setStr(a, "_level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "_formatter", Value.none);
    try inst.dict.setStr(a, "_filters", Value{ .list = try List.init(a) });
    try inst.dict.setStr(a, "_when", Value{ .str = try Str.init(a, when) });
    try inst.dict.setStr(a, "_interval", Value{ .small_int = interval });
    try inst.dict.setStr(a, "_backupCount", Value{ .small_int = backupCount });
    return Value.none;
}

fn timedShouldRollover(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .boolean = false };
}

// ===== WatchedFileHandler =====

fn watchedInitKw(p: *anyopaque, args: []const Value, kw_keys: []const Value, kw_vals: []const Value) anyerror!Value {
    // Same as FileHandler init
    _ = kw_keys; _ = kw_vals;
    return rotatingInit(p, args);
}

// ===== BufferingHandler =====

fn bufferingInitKw(p: *anyopaque, args: []const Value, kw_keys: []const Value, kw_vals: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    var cap: i64 = 10;
    if (args.len >= 2 and args[1] == .small_int) cap = args[1].small_int;
    for (kw_keys, kw_vals) |k, v| {
        if (k != .str) continue;
        if (std.mem.eql(u8, k.str.bytes, "capacity") and v == .small_int) cap = v.small_int;
    }
    const buf = try List.init(a);
    try inst.dict.setStr(a, "_buffer", Value{ .list = buf });
    try inst.dict.setStr(a, "buffer", Value{ .list = buf });
    try inst.dict.setStr(a, "_capacity", Value{ .small_int = cap });
    try inst.dict.setStr(a, "_level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "_formatter", Value.none);
    try inst.dict.setStr(a, "_filters", Value{ .list = try List.init(a) });
    return Value.none;
}

fn bufferingInit(p: *anyopaque, args: []const Value) anyerror!Value {
    return bufferingInitKw(p, args, &.{}, &.{});
}

fn bufferingClose(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

// ===== MemoryHandler =====

fn memoryInitKw(p: *anyopaque, args: []const Value, kw_keys: []const Value, kw_vals: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    var cap: i64 = 10;
    if (args.len >= 2 and args[1] == .small_int) cap = args[1].small_int;

    var flushLevel: i64 = ERROR;
    var target: Value = Value.none;
    for (kw_keys, kw_vals) |k, v| {
        if (k != .str) continue;
        if (std.mem.eql(u8, k.str.bytes, "capacity") and v == .small_int) cap = v.small_int;
        if (std.mem.eql(u8, k.str.bytes, "flushLevel") and v == .small_int) flushLevel = v.small_int;
        if (std.mem.eql(u8, k.str.bytes, "target")) target = v;
    }

    const buf = try List.init(a);
    try inst.dict.setStr(a, "_membuffer", Value{ .list = buf });
    try inst.dict.setStr(a, "_capacity", Value{ .small_int = cap });
    try inst.dict.setStr(a, "_flush_level", Value{ .small_int = flushLevel });
    try inst.dict.setStr(a, "_target", target);
    try inst.dict.setStr(a, "_level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "_formatter", Value.none);
    try inst.dict.setStr(a, "_filters", Value{ .list = try List.init(a) });
    return Value.none;
}

fn memoryClose(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    // Flush remaining buffered records to target
    if (inst.dict.getStr("_membuffer")) |mbv| {
        if (mbv == .list and mbv.list.items.items.len > 0) {
            const target = inst.dict.getStr("_target") orelse Value.none;
            if (target != .none and target == .instance) {
                for (mbv.list.items.items) |rv| {
                    if (rv == .instance) {
                        const level = if (rv.instance.dict.getStr("levelno")) |v| (if (v == .small_int) v.small_int else INFO) else INFO;
                        const name_ = if (rv.instance.dict.getStr("name")) |v| (if (v == .str) v.str.bytes else "") else "";
                        const msg_ = if (rv.instance.dict.getStr("_msg")) |v| (if (v == .str) v.str.bytes else "") else "";
                        try logging_mod.emitDirect(interp, target.instance, level, name_, msg_);
                    }
                }
            }
            mbv.list.items.clearRetainingCapacity();
        }
    }
    return Value.none;
}

// ===== QueueHandler =====

fn queueHandlerInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    try inst.dict.setStr(a, "_queue", args[1]);
    try inst.dict.setStr(a, "_level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "_formatter", Value.none);
    try inst.dict.setStr(a, "_filters", Value{ .list = try List.init(a) });
    return Value.none;
}

// ===== QueueListener =====

fn queueListenerInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const queue = args[1];
    try inst.dict.setStr(a, "_queue", queue);
    // Collect handler args[2..]
    const handlers = try List.init(a);
    for (args[2..]) |h| try handlers.append(a, h);
    try inst.dict.setStr(a, "_handlers", Value{ .list = handlers });
    return Value.none;
}

fn queueListenerStart(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn queueListenerStop(p: *anyopaque, args: []const Value) anyerror!Value {
    // Drain the queue synchronously to all handlers.
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const queue = inst.dict.getStr("_queue") orelse return Value.none;
    const handlers_v = inst.dict.getStr("_handlers") orelse Value.none;
    const handlers: ?*List = if (handlers_v == .list) handlers_v.list else null;

    // Drain via get_nowait until exception
    const get_fn = dispatch.loadAttrValue(interp, queue, "get_nowait") catch return Value.none;
    while (true) {
        const rec = dispatch.invoke(interp, get_fn, &.{}) catch |e| {
            if (e == error.PyException) {
                interp.current_exc = null;
                break;
            }
            break;
        };
        if (handlers) |hl| {
            for (hl.items.items) |h| {
                if (h != .instance) continue;
                // Extract level/name/msg from record instance
                const level = if (rec == .instance) (if (rec.instance.dict.getStr("levelno")) |v| (if (v == .small_int) v.small_int else INFO) else INFO) else INFO;
                const name_ = if (rec == .instance) (if (rec.instance.dict.getStr("name")) |v| (if (v == .str) v.str.bytes else "") else "") else "";
                const msg_ = if (rec == .instance) (if (rec.instance.dict.getStr("_msg")) |v| (if (v == .str) v.str.bytes else "") else "") else "";
                logging_mod.emitDirect(interp, h.instance, level, name_, msg_) catch {};
            }
        }
    }
    return Value.none;
}

// ===== Stub handlers =====

fn stubInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    try inst.dict.setStr(a, "_null", Value{ .boolean = true });
    try inst.dict.setStr(a, "_level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "_formatter", Value.none);
    try inst.dict.setStr(a, "_filters", Value{ .list = try List.init(a) });
    return Value.none;
}

fn stubClose(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn makeStubClass(a: std.mem.Allocator, name: []const u8, parent: *Class) !*Class {
    const d = try Dict.init(a);
    const f_init = try a.create(BuiltinFn);
    f_init.* = .{ .name = "__init__", .func = stubInit };
    try d.setStr(a, "__init__", Value{ .builtin_fn = f_init });
    const f_sl = try a.create(BuiltinFn);
    f_sl.* = .{ .name = "setLevel", .func = handlerSetLevel };
    try d.setStr(a, "setLevel", Value{ .builtin_fn = f_sl });
    const f_cl = try a.create(BuiltinFn);
    f_cl.* = .{ .name = "close", .func = stubClose };
    try d.setStr(a, "close", Value{ .builtin_fn = f_cl });
    return Class.init(a, name, &[_]*Class{parent}, d);
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "logging.handlers");
    const base = interp.logging_handler_class orelse return m;

    // Constants
    try m.attrs.setStr(a, "DEFAULT_TCP_LOGGING_PORT", Value{ .small_int = 9020 });
    try m.attrs.setStr(a, "DEFAULT_UDP_LOGGING_PORT", Value{ .small_int = 9021 });
    try m.attrs.setStr(a, "SYSLOG_UDP_PORT", Value{ .small_int = 514 });

    // RotatingFileHandler
    {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", rotatingInit);
        try reg(a, d, "setLevel", handlerSetLevel);
        try reg(a, d, "setFormatter", handlerSetFormatter);
        try reg(a, d, "close", handlerClose);
        try reg(a, d, "shouldRollover", shouldRollover);
        const f_kw = try a.create(BuiltinFn);
        f_kw.* = .{ .name = "__init__", .func = rotatingInit, .kw_func = rotatingKw };
        try d.setStr(a, "__init__", Value{ .builtin_fn = f_kw });
        const cls = try Class.init(a, "RotatingFileHandler", &[_]*Class{base}, d);
        try m.attrs.setStr(a, "RotatingFileHandler", Value{ .class = cls });
    }

    // TimedRotatingFileHandler
    {
        const d = try Dict.init(a);
        try reg(a, d, "setLevel", handlerSetLevel);
        try reg(a, d, "setFormatter", handlerSetFormatter);
        try reg(a, d, "close", handlerClose);
        try reg(a, d, "shouldRollover", timedShouldRollover);
        const f_kw = try a.create(BuiltinFn);
        f_kw.* = .{ .name = "__init__", .func = rotatingInit, .kw_func = timedRotatingInitKw };
        try d.setStr(a, "__init__", Value{ .builtin_fn = f_kw });
        const cls = try Class.init(a, "TimedRotatingFileHandler", &[_]*Class{base}, d);
        try m.attrs.setStr(a, "TimedRotatingFileHandler", Value{ .class = cls });
    }

    // WatchedFileHandler
    {
        const d = try Dict.init(a);
        try reg(a, d, "setLevel", handlerSetLevel);
        try reg(a, d, "setFormatter", handlerSetFormatter);
        try reg(a, d, "close", handlerClose);
        const f_kw = try a.create(BuiltinFn);
        f_kw.* = .{ .name = "__init__", .func = rotatingInit, .kw_func = watchedInitKw };
        try d.setStr(a, "__init__", Value{ .builtin_fn = f_kw });
        const cls = try Class.init(a, "WatchedFileHandler", &[_]*Class{base}, d);
        try m.attrs.setStr(a, "WatchedFileHandler", Value{ .class = cls });
    }

    // BufferingHandler
    {
        const d = try Dict.init(a);
        try reg(a, d, "setLevel", handlerSetLevel);
        try reg(a, d, "setFormatter", handlerSetFormatter);
        try reg(a, d, "close", bufferingClose);
        const f_kw = try a.create(BuiltinFn);
        f_kw.* = .{ .name = "__init__", .func = bufferingInit, .kw_func = bufferingInitKw };
        try d.setStr(a, "__init__", Value{ .builtin_fn = f_kw });
        const cls = try Class.init(a, "BufferingHandler", &[_]*Class{base}, d);
        try m.attrs.setStr(a, "BufferingHandler", Value{ .class = cls });
    }

    // MemoryHandler
    {
        const d = try Dict.init(a);
        try reg(a, d, "setLevel", handlerSetLevel);
        try reg(a, d, "setFormatter", handlerSetFormatter);
        try reg(a, d, "close", memoryClose);
        const f_kw = try a.create(BuiltinFn);
        f_kw.* = .{ .name = "__init__", .func = rotatingInit, .kw_func = memoryInitKw };
        try d.setStr(a, "__init__", Value{ .builtin_fn = f_kw });
        const cls = try Class.init(a, "MemoryHandler", &[_]*Class{base}, d);
        try m.attrs.setStr(a, "MemoryHandler", Value{ .class = cls });
    }

    // QueueHandler
    {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", queueHandlerInit);
        try reg(a, d, "setLevel", handlerSetLevel);
        try reg(a, d, "setFormatter", handlerSetFormatter);
        const cls = try Class.init(a, "QueueHandler", &[_]*Class{base}, d);
        try m.attrs.setStr(a, "QueueHandler", Value{ .class = cls });
    }

    // QueueListener
    {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", queueListenerInit);
        try reg(a, d, "start", queueListenerStart);
        try reg(a, d, "stop", queueListenerStop);
        const cls = try Class.init(a, "QueueListener", &.{}, d);
        try m.attrs.setStr(a, "QueueListener", Value{ .class = cls });
    }

    // Stub handlers
    const socket_cls = try makeStubClass(a, "SocketHandler", base);
    try m.attrs.setStr(a, "SocketHandler", Value{ .class = socket_cls });

    const dgram_cls = try makeStubClass(a, "DatagramHandler", base);
    try m.attrs.setStr(a, "DatagramHandler", Value{ .class = dgram_cls });

    const smtp_cls = try makeStubClass(a, "SMTPHandler", base);
    try m.attrs.setStr(a, "SMTPHandler", Value{ .class = smtp_cls });

    const http_cls = try makeStubClass(a, "HTTPHandler", base);
    try m.attrs.setStr(a, "HTTPHandler", Value{ .class = http_cls });

    // SysLogHandler with LOG_USER=1
    {
        const d = try Dict.init(a);
        const f_init = try a.create(BuiltinFn);
        f_init.* = .{ .name = "__init__", .func = stubInit };
        try d.setStr(a, "__init__", Value{ .builtin_fn = f_init });
        const f_sl = try a.create(BuiltinFn);
        f_sl.* = .{ .name = "setLevel", .func = handlerSetLevel };
        try d.setStr(a, "setLevel", Value{ .builtin_fn = f_sl });
        const f_cl = try a.create(BuiltinFn);
        f_cl.* = .{ .name = "close", .func = stubClose };
        try d.setStr(a, "close", Value{ .builtin_fn = f_cl });
        try d.setStr(a, "LOG_USER", Value{ .small_int = 1 });
        const cls = try Class.init(a, "SysLogHandler", &[_]*Class{base}, d);
        try m.attrs.setStr(a, "SysLogHandler", Value{ .class = cls });
    }

    return m;
}
