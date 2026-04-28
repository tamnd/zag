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
const file_io = @import("file_io.zig");

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
    propagate: bool = true,
    handlers: std.ArrayListUnmanaged(*Instance) = .empty,
};

pub const LoggingState = struct {
    a: std.mem.Allocator,
    loggers: std.StringHashMapUnmanaged(*LoggerState) = .empty,
    instances: std.StringHashMapUnmanaged(*Instance) = .empty,
    disabled: i64 = NOTSET,

    pub fn getOrCreate(self: *LoggingState, name: []const u8) !*LoggerState {
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

fn passesFilters(h: *Instance, name: []const u8) bool {
    const fv = h.dict.getStr("_filters") orelse return true;
    if (fv != .list) return true;
    for (fv.list.items.items) |filt| {
        if (filt != .instance) continue;
        if (filt.instance.dict.getStr("_filter_name")) |nv| {
            if (nv == .str) {
                const prefix = nv.str.bytes;
                if (prefix.len == 0) continue;
                if (!std.mem.startsWith(u8, name, prefix)) return false;
                if (name.len > prefix.len and name[prefix.len] != '.') return false;
            }
        }
    }
    return true;
}

fn emit(interp: *Interp, h: *Instance, level: i64, name: []const u8, msg: []const u8) anyerror!void {
    const a = interp.allocator;
    // check handler minimum level
    const hlevel = if (h.dict.getStr("_level")) |v| (if (v == .small_int) v.small_int else NOTSET) else NOTSET;
    if (level < hlevel) return;
    // check filters
    if (!passesFilters(h, name)) return;
    // NullHandler: skip
    if (h.dict.getStr("_null")) |nv| if (nv == .boolean and nv.boolean) return;
    // buffering handler: buffer instead of emit
    if (h.dict.getStr("_buffer")) |bv| {
        if (bv == .list) {
            const rec = try makeRecord(a, level, name, msg);
            try bv.list.append(a, Value{ .instance = rec });
            // check capacity
            if (h.dict.getStr("_capacity")) |cv| {
                if (cv == .small_int and bv.list.items.items.len >= @as(usize, @intCast(cv.small_int))) {
                    try flushBufferingHandler(interp, h);
                }
            }
            return;
        }
    }
    // memory handler: buffer with flush on level
    if (h.dict.getStr("_membuffer")) |mbv| {
        if (mbv == .list) {
            const rec = try makeRecord(a, level, name, msg);
            try mbv.list.append(a, Value{ .instance = rec });
            const flush_level: i64 = if (h.dict.getStr("_flush_level")) |flv| (if (flv == .small_int) flv.small_int else ERROR) else ERROR;
            const cap: usize = if (h.dict.getStr("_capacity")) |cv| (if (cv == .small_int and cv.small_int > 0) @intCast(cv.small_int) else 100) else 100;
            if (level >= flush_level or mbv.list.items.items.len >= cap) {
                try flushMemoryHandler(interp, h);
            }
            return;
        }
    }
    // queue handler: put record on queue
    if (h.dict.getStr("_queue")) |qv| {
        const rec = try makeRecord(a, level, name, msg);
        const put_fn = dispatch.loadAttrValue(interp, qv, "put_nowait") catch return;
        _ = dispatch.invoke(interp, put_fn, &.{Value{ .instance = rec }}) catch return;
        return;
    }
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

fn makeRecord(a: std.mem.Allocator, level: i64, name: []const u8, msg: []const u8) !*Instance {
    const d = try Dict.init(a);
    const inst = try a.create(Instance);
    inst.* = .{ .cls = undefined, .dict = d };
    try d.setStr(a, "levelno", Value{ .small_int = level });
    try d.setStr(a, "name", Value{ .str = try Str.init(a, name) });
    try d.setStr(a, "getMessage", Value.none);
    try d.setStr(a, "_msg", Value{ .str = try Str.init(a, msg) });
    return inst;
}

fn emitRecord(interp: *Interp, h: *Instance, rec: *Instance) anyerror!void {
    const level = if (rec.dict.getStr("levelno")) |v| (if (v == .small_int) v.small_int else INFO) else INFO;
    const name = if (rec.dict.getStr("name")) |v| (if (v == .str) v.str.bytes else "") else "";
    const msg = if (rec.dict.getStr("_msg")) |v| (if (v == .str) v.str.bytes else "") else "";
    try emit(interp, h, level, name, msg);
}

fn flushBufferingHandler(_: *Interp, h: *Instance) !void {
    const bv = h.dict.getStr("_buffer") orelse return;
    if (bv != .list) return;
    bv.list.items.clearRetainingCapacity();
}

fn flushMemoryHandler(interp: *Interp, h: *Instance) anyerror!void {
    const mbv = h.dict.getStr("_membuffer") orelse return;
    if (mbv != .list) return;
    const target = h.dict.getStr("_target") orelse Value.none;
    if (target != .none and target == .instance) {
        for (mbv.list.items.items) |rv| {
            if (rv == .instance) try emitRecord(interp, target.instance, rv.instance);
        }
    }
    mbv.list.items.clearRetainingCapacity();
}

/// Called by logging_handlers_mod to emit directly (bypasses buffering guards).
pub fn emitDirect(interp: *Interp, h: *Instance, level: i64, name: []const u8, msg: []const u8) !void {
    try emit(interp, h, level, name, msg);
}

// ===== FileHandler =====

pub fn fileHandlerOpen(interp: *Interp, inst: *Instance, path: []const u8, mode: []const u8) !void {
    const a = interp.allocator;
    const path_val = Value{ .str = try Str.init(a, path) };
    const mode_val = Value{ .str = try Str.init(a, mode) };
    const file_val = try file_io.openFn(@ptrCast(interp), &.{ path_val, mode_val });
    try inst.dict.setStr(a, "_stream", file_val);
    try inst.dict.setStr(a, "_path", Value{ .str = try Str.init(a, path) });
    try inst.dict.setStr(a, "_mode", Value{ .str = try Str.init(a, mode) });
}

fn fileHandlerInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const inst = args[0].instance;
    const path = args[1].str.bytes;
    const mode = if (args.len >= 3 and args[2] == .str) args[2].str.bytes else "a";
    try fileHandlerOpen(interp, inst, path, mode);
    try inst.dict.setStr(a, "_level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "level", Value{ .small_int = NOTSET });
    try inst.dict.setStr(a, "_formatter", Value.none);
    try inst.dict.setStr(a, "_filters", Value{ .list = try List.init(a) });
    return Value.none;
}

fn fileHandlerClose(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    if (inst.dict.getStr("_stream")) |sv| {
        if (sv == .instance) {
            _ = file_io.openFn; // ensure linked
            const close_attr = dispatch.loadAttrValue(interp, sv, "close") catch return Value.none;
            _ = dispatch.invoke(interp, close_attr, &.{sv}) catch {};
        }
    }
    return Value.none;
}

fn handlerAddFilter(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const filt = args[1];
    if (inst.dict.getStr("_filters")) |fv| {
        if (fv == .list) {
            try fv.list.append(a, filt);
            return Value.none;
        }
    }
    const fl = try List.init(a);
    try fl.append(a, filt);
    try inst.dict.setStr(a, "_filters", Value{ .list = fl });
    return Value.none;
}

// ===== Filter =====

fn filterInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const name = if (args.len >= 2 and args[1] == .str) args[1].str.bytes else "";
    try inst.dict.setStr(a, "_filter_name", Value{ .str = try Str.init(a, name) });
    try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, name) });
    return Value.none;
}

fn effectiveLevel(gs: *LoggingState, ls: *LoggerState) i64 {
    if (ls.level != NOTSET) return ls.level;
    // Walk up: for "a.b.c" try "a.b", "a", then "root".
    var name: []const u8 = ls.name;
    while (true) {
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
            name = name[0..dot];
        } else {
            name = "root";
        }
        if (gs.loggers.get(name)) |parent| {
            if (parent.level != NOTSET) return parent.level;
            if (std.mem.eql(u8, name, "root")) break;
        } else {
            break;
        }
    }
    return WARNING;
}

fn logAt(interp: *Interp, inst: *Instance, level: i64, msg: []const u8) !void {
    const state_v = inst.dict.getStr("__state") orelse return;
    const ls: *LoggerState = @ptrFromInt(@as(usize, @intCast(state_v.small_int)));
    const gs = gstate(interp);
    if (level < effectiveLevel(gs, ls) or level <= gs.disabled) return;
    // Emit to own handlers, then walk up hierarchy if enabled.
    for (ls.handlers.items) |h| try emit(interp, h, level, ls.name, msg);
    if (ls.propagate and !std.mem.eql(u8, ls.name, "root")) {
        var ancestor_name: []const u8 = ls.name;
        while (true) {
            if (std.mem.lastIndexOfScalar(u8, ancestor_name, '.')) |dot| {
                ancestor_name = ancestor_name[0..dot];
            } else {
                ancestor_name = "root";
            }
            if (gs.loggers.get(ancestor_name)) |anc_ls| {
                for (anc_ls.handlers.items) |h| try emit(interp, h, level, ls.name, msg);
                if (!anc_ls.propagate) break;
            }
            if (std.mem.eql(u8, ancestor_name, "root")) break;
        }
    }
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
    const raw_name = if (args.len >= 1 and args[0] == .str) args[0].str.bytes else "root";
    const name = if (raw_name.len == 0) "root" else raw_name;
    const gs = gstate(interp);
    // return cached instance
    if (gs.instances.get(name)) |inst| return Value{ .instance = inst };
    // create logger state
    const ls = try gs.getOrCreate(name);
    // create instance
    const inst = try Instance.init(a, interp.logging_logger_class.?);
    try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, name) });
    try inst.dict.setStr(a, "level", Value{ .small_int = ls.level });
    try inst.dict.setStr(a, "propagate", Value{ .boolean = ls.propagate });
    const hlist = try List.init(a);
    for (ls.handlers.items) |hi| try hlist.append(a, Value{ .instance = hi });
    try inst.dict.setStr(a, "handlers", Value{ .list = hlist });
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

    // FileHandler
    if (interp.logging_file_handler_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", fileHandlerInit);
        try reg(a, d, "setLevel", handlerSetLevel);
        try reg(a, d, "setFormatter", handlerSetFormatter);
        try reg(a, d, "addFilter", handlerAddFilter);
        try reg(a, d, "close", fileHandlerClose);
        interp.logging_file_handler_class = try Class.init(
            a, "FileHandler", &[_]*Class{interp.logging_handler_class.?}, d,
        );
    }
    try m.attrs.setStr(a, "FileHandler", Value{ .class = interp.logging_file_handler_class.? });

    // Filter
    if (interp.logging_filter_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", filterInit);
        interp.logging_filter_class = try Class.init(a, "Filter", &.{}, d);
    }
    try m.attrs.setStr(a, "Filter", Value{ .class = interp.logging_filter_class.? });

    return m;
}
