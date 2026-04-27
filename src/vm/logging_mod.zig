//! Pinhole `logging`. Logger/Handler/Formatter/StreamHandler/NullHandler.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

// ===== levels =====

const NOTSET: i64 = 0;
const DEBUG: i64 = 10;
const INFO: i64 = 20;
const WARNING: i64 = 30;
const ERROR: i64 = 40;
const CRITICAL: i64 = 50;

fn levelName(level: i64) []const u8 {
    return switch (level) {
        NOTSET => "NOTSET",
        DEBUG => "DEBUG",
        INFO => "INFO",
        WARNING => "WARNING",
        ERROR => "ERROR",
        CRITICAL => "CRITICAL",
        else => "Level",
    };
}

// ===== global state (stored as pointer on interp) =====

const LoggerState = struct {
    name: []u8,
    level: i64,
    handlers: std.ArrayListUnmanaged(*Instance) = .empty,
};

pub const LoggingState = struct {
    a: std.mem.Allocator,
    loggers: std.StringHashMapUnmanaged(*LoggerState) = .empty,
    instances: std.StringHashMapUnmanaged(*Instance) = .empty,
    disabled: i64 = NOTSET,

    fn getOrCreate(self: *LoggingState, name: []const u8) !*LoggerState {
        if (self.loggers.get(name)) |ls| return ls;
        const ls = try self.a.create(LoggerState);
        const owned = try self.a.dupe(u8, name);
        ls.* = .{ .name = owned, .level = NOTSET };
        try self.loggers.put(self.a, owned, ls);
        return ls;
    }
};

fn gstate(interp: *Interp) *LoggingState {
    return interp.logging_state.?;
}

// ===== format =====

fn fmtMsg(a: std.mem.Allocator, fmt_str: []const u8, level: i64, name: []const u8, msg: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < fmt_str.len) {
        if (fmt_str[i] == '%' and i + 1 < fmt_str.len and fmt_str[i + 1] == '(') {
            const tail = fmt_str[i + 2 ..];
            if (std.mem.indexOfScalar(u8, tail, ')')) |end| {
                if (end + 1 < tail.len and tail[end + 1] == 's') {
                    const key = tail[0..end];
                    if (std.mem.eql(u8, key, "levelname")) {
                        try out.appendSlice(a, levelName(level));
                    } else if (std.mem.eql(u8, key, "name")) {
                        try out.appendSlice(a, name);
                    } else if (std.mem.eql(u8, key, "message")) {
                        try out.appendSlice(a, msg);
                    } else {
                        try out.appendSlice(a, fmt_str[i .. i + 2 + end + 2]);
                    }
                    i += 2 + end + 2;
                    continue;
                }
            }
        }
        try out.append(a, fmt_str[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

// ===== emit =====

fn emit(interp: *Interp, h: *Instance, level: i64, name: []const u8, msg: []const u8) !void {
    const a = interp.allocator;
    // check handler minimum level
    const hlevel = if (h.dict.getStr("_level")) |v| (if (v == .small_int) v.small_int else NOTSET) else NOTSET;
    if (level < hlevel) return;
    // NullHandler: skip
    if (h.dict.getStr("_null")) |nv| if (nv == .boolean and nv.boolean) return;
    // format
    var text: []u8 = undefined;
    var owned = false;
    if (h.dict.getStr("_formatter")) |fv| {
        if (fv == .instance) {
            if (fv.instance.dict.getStr("_fmt")) |sv| {
                if (sv == .str) {
                    text = try fmtMsg(a, sv.str.bytes, level, name, msg);
                    owned = true;
                }
            }
        }
    }
    if (!owned) {
        text = try a.dupe(u8, msg);
        owned = true;
    }
    defer if (owned) a.free(text);
    // write to stream
    const sv = h.dict.getStr("_stream") orelse Value.none;
    if (sv == .none) return;
    const line = try std.fmt.allocPrint(a, "{s}\n", .{text});
    defer a.free(line);
    const attr = try dispatch.loadAttrValue(interp, sv, "write");
    _ = try dispatch.invoke(interp, attr, &.{Value{ .str = try Str.init(a, line) }});
}

fn logAt(interp: *Interp, inst: *Instance, level: i64, msg: []const u8) !void {
    const state_v = inst.dict.getStr("__state") orelse return;
    const ls: *LoggerState = @ptrFromInt(@as(usize, @intCast(state_v.small_int)));
    const gs = gstate(interp);
    const eff = if (ls.level == NOTSET) DEBUG else ls.level;
    if (level < eff or level <= gs.disabled) return;
    for (ls.handlers.items) |h| try emit(interp, h, level, ls.name, msg);
}

// ===== Logger methods =====

fn loggerSetLevel(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const level: i64 = if (args[1] == .small_int) args[1].small_int else NOTSET;
    const state_v = inst.dict.getStr("__state") orelse return error.TypeError;
    const ls: *LoggerState = @ptrFromInt(@as(usize, @intCast(state_v.small_int)));
    ls.level = level;
    try inst.dict.setStr(a, "level", Value{ .small_int = level });
    return Value.none;
}

fn loggerIsEnabledFor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const level: i64 = if (args[1] == .small_int) args[1].small_int else NOTSET;
    const state_v = inst.dict.getStr("__state") orelse return Value{ .boolean = false };
    const ls: *LoggerState = @ptrFromInt(@as(usize, @intCast(state_v.small_int)));
    const eff = if (ls.level == NOTSET) DEBUG else ls.level;
    const gs = gstate(interp);
    return Value{ .boolean = level >= eff and level > gs.disabled };
}

fn loggerGetEffectiveLevel(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state_v = inst.dict.getStr("__state") orelse return Value{ .small_int = DEBUG };
    const ls: *LoggerState = @ptrFromInt(@as(usize, @intCast(state_v.small_int)));
    return Value{ .small_int = if (ls.level == NOTSET) DEBUG else ls.level };
}

fn loggerAddHandler(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const handler_inst = args[1].instance;
    const state_v = inst.dict.getStr("__state") orelse return error.TypeError;
    const ls: *LoggerState = @ptrFromInt(@as(usize, @intCast(state_v.small_int)));
    try ls.handlers.append(a, handler_inst);
    if (inst.dict.getStr("handlers")) |hv| {
        if (hv == .list) try hv.list.append(a, Value{ .instance = handler_inst });
    }
    return Value.none;
}

fn loggerDebug(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const msg = if (args[1] == .str) args[1].str.bytes else "";
    try logAt(interp, args[0].instance, DEBUG, msg);
    return Value.none;
}

fn loggerInfo(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const msg = if (args[1] == .str) args[1].str.bytes else "";
    try logAt(interp, args[0].instance, INFO, msg);
    return Value.none;
}

fn loggerWarning(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const msg = if (args[1] == .str) args[1].str.bytes else "";
    try logAt(interp, args[0].instance, WARNING, msg);
    return Value.none;
}

fn loggerError(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const msg = if (args[1] == .str) args[1].str.bytes else "";
    try logAt(interp, args[0].instance, ERROR, msg);
    return Value.none;
}

fn loggerCritical(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const msg = if (args[1] == .str) args[1].str.bytes else "";
    try logAt(interp, args[0].instance, CRITICAL, msg);
    return Value.none;
}

// ===== Handler methods =====

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

// ===== StreamHandler.__init__ =====

fn streamHandlerInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const stream = if (args.len >= 2) args[1] else Value.none;
    try inst.dict.setStr(a, "_stream", stream);
    try inst.dict.setStr(a, "_level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "_formatter", Value.none);
    return Value.none;
}

// ===== NullHandler.__init__ =====

fn nullHandlerInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    try inst.dict.setStr(a, "_null", Value{ .boolean = true });
    try inst.dict.setStr(a, "_level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "_formatter", Value.none);
    return Value.none;
}

// ===== Formatter.__init__ =====

fn formatterInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const fmt_str = if (args.len >= 2 and args[1] == .str) args[1].str.bytes else "%(message)s";
    try inst.dict.setStr(a, "_fmt", Value{ .str = try Str.init(a, fmt_str) });
    return Value.none;
}

// ===== module-level functions =====

fn getLoggerFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const name = if (args.len >= 1 and args[0] == .str) args[0].str.bytes else "root";
    const gs = gstate(interp);
    // return cached instance
    if (gs.instances.get(name)) |inst| return Value{ .instance = inst };
    // create logger state
    const ls = try gs.getOrCreate(name);
    // create instance
    const inst = try Instance.init(a, interp.logging_logger_class.?);
    try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, name) });
    try inst.dict.setStr(a, "level", Value{ .small_int = ls.level });
    try inst.dict.setStr(a, "propagate", Value{ .boolean = true });
    try inst.dict.setStr(a, "handlers", Value{ .list = try List.init(a) });
    try inst.dict.setStr(a, "__state", Value{ .small_int = @intCast(@intFromPtr(ls)) });
    try gs.instances.put(a, ls.name, inst);
    return Value{ .instance = inst };
}

fn getLevelNameFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    if (args[0] == .str) {
        const s = args[0].str.bytes;
        if (std.mem.eql(u8, s, "NOTSET")) return Value{ .small_int = NOTSET };
        if (std.mem.eql(u8, s, "DEBUG")) return Value{ .small_int = DEBUG };
        if (std.mem.eql(u8, s, "INFO")) return Value{ .small_int = INFO };
        if (std.mem.eql(u8, s, "WARNING") or std.mem.eql(u8, s, "WARN")) return Value{ .small_int = WARNING };
        if (std.mem.eql(u8, s, "ERROR")) return Value{ .small_int = ERROR };
        if (std.mem.eql(u8, s, "CRITICAL") or std.mem.eql(u8, s, "FATAL")) return Value{ .small_int = CRITICAL };
        return Value{ .str = try Str.init(a, "Level") };
    }
    const level: i64 = if (args[0] == .small_int) args[0].small_int else 0;
    return Value{ .str = try Str.init(a, levelName(level)) };
}

fn disableFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const level: i64 = if (args.len >= 1 and args[0] == .small_int) args[0].small_int else NOTSET;
    gstate(interp).disabled = level;
    return Value.none;
}

fn basicConfigFn(p: *anyopaque, _: []const Value) anyerror!Value {
    _ = p;
    return Value.none;
}

fn basicConfigKw(p: *anyopaque, _: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    _ = p;
    return Value.none;
}

// ===== reg helpers =====

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

fn regModKw(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "logging");

    // global state
    if (interp.logging_state == null) {
        const gs = try a.create(LoggingState);
        gs.* = .{ .a = a };
        interp.logging_state = gs;
    }

    // level constants
    const consts = &[_]struct { []const u8, i64 }{
        .{ "NOTSET", NOTSET }, .{ "DEBUG", DEBUG }, .{ "INFO", INFO },
        .{ "WARNING", WARNING }, .{ "WARN", WARNING },
        .{ "ERROR", ERROR }, .{ "CRITICAL", CRITICAL }, .{ "FATAL", CRITICAL },
    };
    for (consts) |pr| try m.attrs.setStr(a, pr[0], Value{ .small_int = pr[1] });

    // module functions
    try regMod(a, m, "getLogger", getLoggerFn);
    try regMod(a, m, "getLevelName", getLevelNameFn);
    try regMod(a, m, "disable", disableFn);
    try regModKw(a, m, "basicConfig", basicConfigFn, basicConfigKw);

    // Handler base class
    if (interp.logging_handler_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "setLevel", handlerSetLevel);
        try reg(a, d, "setFormatter", handlerSetFormatter);
        interp.logging_handler_class = try Class.init(a, "Handler", &.{}, d);
    }
    try m.attrs.setStr(a, "Handler", Value{ .class = interp.logging_handler_class.? });

    // StreamHandler
    if (interp.logging_stream_handler_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", streamHandlerInit);
        try reg(a, d, "setLevel", handlerSetLevel);
        try reg(a, d, "setFormatter", handlerSetFormatter);
        interp.logging_stream_handler_class = try Class.init(
            a, "StreamHandler", &[_]*Class{interp.logging_handler_class.?}, d,
        );
    }
    try m.attrs.setStr(a, "StreamHandler", Value{ .class = interp.logging_stream_handler_class.? });

    // NullHandler
    if (interp.logging_null_handler_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", nullHandlerInit);
        interp.logging_null_handler_class = try Class.init(
            a, "NullHandler", &[_]*Class{interp.logging_handler_class.?}, d,
        );
    }
    try m.attrs.setStr(a, "NullHandler", Value{ .class = interp.logging_null_handler_class.? });

    // Formatter
    if (interp.logging_formatter_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", formatterInit);
        interp.logging_formatter_class = try Class.init(a, "Formatter", &.{}, d);
    }
    try m.attrs.setStr(a, "Formatter", Value{ .class = interp.logging_formatter_class.? });

    // Logger
    if (interp.logging_logger_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "setLevel", loggerSetLevel);
        try reg(a, d, "getEffectiveLevel", loggerGetEffectiveLevel);
        try reg(a, d, "isEnabledFor", loggerIsEnabledFor);
        try reg(a, d, "addHandler", loggerAddHandler);
        try reg(a, d, "debug", loggerDebug);
        try reg(a, d, "info", loggerInfo);
        try reg(a, d, "warning", loggerWarning);
        try reg(a, d, "warn", loggerWarning);
        try reg(a, d, "error", loggerError);
        try reg(a, d, "critical", loggerCritical);
        try reg(a, d, "fatal", loggerCritical);
        interp.logging_logger_class = try Class.init(a, "Logger", &.{}, d);
    }
    try m.attrs.setStr(a, "Logger", Value{ .class = interp.logging_logger_class.? });

    return m;
}
