//! Pinhole `time` module: time, sleep, gmtime, localtime, mktime, strftime, strptime, etc.

const std = @import("std");
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

fn getOrCreateStructTimeClass(interp: *Interp) !*Class {
    if (interp.time_struct_time_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const cls = try Class.init(a, "struct_time", &.{}, d);
    interp.time_struct_time_class = cls;
    return cls;
}

fn setStructTimeFields(interp: *Interp, inst: *Instance, year: i64, mon: i64, mday: i64, hour: i64, min_: i64, sec: i64, wday: i64, yday: i64, isdst: i64) !void {
    const a = interp.allocator;
    try inst.dict.setStr(a, "tm_year", Value{ .small_int = year });
    try inst.dict.setStr(a, "tm_mon", Value{ .small_int = mon });
    try inst.dict.setStr(a, "tm_mday", Value{ .small_int = mday });
    try inst.dict.setStr(a, "tm_hour", Value{ .small_int = hour });
    try inst.dict.setStr(a, "tm_min", Value{ .small_int = min_ });
    try inst.dict.setStr(a, "tm_sec", Value{ .small_int = sec });
    try inst.dict.setStr(a, "tm_wday", Value{ .small_int = wday });
    try inst.dict.setStr(a, "tm_yday", Value{ .small_int = yday });
    try inst.dict.setStr(a, "tm_isdst", Value{ .small_int = isdst });
}

fn nowSecs(interp: *Interp) f64 {
    const ts = std.Io.Timestamp.now(interp.io, .real);
    return @as(f64, @floatFromInt(ts.nanoseconds)) / 1e9;
}

fn nowNs(interp: *Interp) i64 {
    const ts = std.Io.Timestamp.now(interp.io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, 1));
}

fn epochSecsToStruct(interp: *Interp, secs: i64) !Value {
    const a = interp.allocator;
    const cls = try getOrCreateStructTimeClass(interp);
    const inst = try Instance.init(a, cls);
    const SECS_PER_MIN: i64 = 60;
    var remaining = secs;
    const sec = @mod(remaining, SECS_PER_MIN); remaining = @divTrunc(remaining, SECS_PER_MIN);
    const min_ = @mod(remaining, 60); remaining = @divTrunc(remaining, 60);
    const hour = @mod(remaining, 24); remaining = @divTrunc(remaining, 24);
    var days: i64 = remaining;
    const wday = @mod(days + 3, 7); // Jan 1 1970 was Thursday (3)
    var year: i64 = 1970;
    while (true) {
        const is_leap = (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0));
        const days_in_year: i64 = if (is_leap) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }
    const yday = days + 1;
    const is_leap = (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0));
    const month_days = [_]i64{ 31, if (is_leap) @as(i64, 29) else @as(i64, 28), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var mon: i64 = 1;
    var mday = days;
    for (month_days) |md| {
        if (mday < md) break;
        mday -= md;
        mon += 1;
    }
    mday += 1;
    try setStructTimeFields(interp, inst, year, mon, mday, hour, min_, sec, wday, yday, 0);
    return Value{ .instance = inst };
}

fn timeFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .float = nowSecs(interp) };
}

fn timeNsFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .small_int = nowNs(interp) };
}

fn perfCounterFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const ts = std.Io.Timestamp.now(interp.io, .awake);
    return Value{ .float = @as(f64, @floatFromInt(ts.nanoseconds)) / 1e9 };
}

fn monotonicFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const ts = std.Io.Timestamp.now(interp.io, .awake);
    return Value{ .float = @as(f64, @floatFromInt(ts.nanoseconds)) / 1e9 };
}

fn processTimeFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .float = 0.0 };
}

fn sleepFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len >= 1) {
        const secs: f64 = switch (args[0]) {
            .float => |f| f,
            .small_int => |i| @floatFromInt(i),
            else => 0.0,
        };
        if (secs > 0) {
            const ns: i96 = @intFromFloat(secs * 1e9);
            interp.io.sleep(.{ .nanoseconds = ns }, .real) catch {};
        }
    }
    return Value.none;
}

fn gmtimeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const secs: i64 = if (args.len >= 1) switch (args[0]) {
        .float => |f| @intFromFloat(f),
        .small_int => |i| i,
        else => @intFromFloat(nowSecs(interp)),
    } else @intFromFloat(nowSecs(interp));
    return epochSecsToStruct(interp, secs);
}

fn localtimeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return gmtimeFn(p, args);
}

fn mktimeFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value{ .float = 0.0 };
    const inst = args[0].instance;
    const year = if (inst.dict.getStr("tm_year")) |v| switch (v) { .small_int => |i| i, else => @as(i64, 1970) } else @as(i64, 1970);
    const mon = if (inst.dict.getStr("tm_mon")) |v| switch (v) { .small_int => |i| i, else => @as(i64, 1) } else @as(i64, 1);
    const mday = if (inst.dict.getStr("tm_mday")) |v| switch (v) { .small_int => |i| i, else => @as(i64, 1) } else @as(i64, 1);
    const hour = if (inst.dict.getStr("tm_hour")) |v| switch (v) { .small_int => |i| i, else => @as(i64, 0) } else @as(i64, 0);
    const min_ = if (inst.dict.getStr("tm_min")) |v| switch (v) { .small_int => |i| i, else => @as(i64, 0) } else @as(i64, 0);
    const sec = if (inst.dict.getStr("tm_sec")) |v| switch (v) { .small_int => |i| i, else => @as(i64, 0) } else @as(i64, 0);
    var days: i64 = 0;
    var y: i64 = 1970;
    while (y < year) : (y += 1) {
        const is_leap = (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0));
        days += if (is_leap) 366 else 365;
    }
    const is_leap = (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0));
    const month_days = [_]i64{ 31, if (is_leap) @as(i64, 29) else @as(i64, 28), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: i64 = 1;
    while (m < mon) : (m += 1) {
        days += month_days[@intCast(m - 1)];
    }
    days += mday - 1;
    const ts = days * 86400 + hour * 3600 + min_ * 60 + sec;
    return Value{ .float = @floatFromInt(ts) };
}

fn strftimeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return Value{ .str = try Str.init(a, "") };
    const fmt = args[0].str.bytes;

    const st: ?*Instance = if (args.len >= 2 and args[1] == .instance) args[1].instance else null;

    const year: i64 = if (st) |s| if (s.dict.getStr("tm_year")) |v| switch (v) { .small_int => |i| i, else => @as(i64, 2024) } else @as(i64, 2024) else 2024;
    const mon: i64 = if (st) |s| if (s.dict.getStr("tm_mon")) |v| switch (v) { .small_int => |i| i, else => @as(i64, 1) } else @as(i64, 1) else 1;
    const mday: i64 = if (st) |s| if (s.dict.getStr("tm_mday")) |v| switch (v) { .small_int => |i| i, else => @as(i64, 1) } else @as(i64, 1) else 1;
    const hour: i64 = if (st) |s| if (s.dict.getStr("tm_hour")) |v| switch (v) { .small_int => |i| i, else => @as(i64, 0) } else @as(i64, 0) else 0;
    const min_: i64 = if (st) |s| if (s.dict.getStr("tm_min")) |v| switch (v) { .small_int => |i| i, else => @as(i64, 0) } else @as(i64, 0) else 0;
    const sec: i64 = if (st) |s| if (s.dict.getStr("tm_sec")) |v| switch (v) { .small_int => |i| i, else => @as(i64, 0) } else @as(i64, 0) else 0;
    const wday: i64 = if (st) |s| if (s.dict.getStr("tm_wday")) |v| switch (v) { .small_int => |i| i, else => @as(i64, 0) } else @as(i64, 0) else 0;
    const yday: i64 = if (st) |s| if (s.dict.getStr("tm_yday")) |v| switch (v) { .small_int => |i| i, else => @as(i64, 1) } else @as(i64, 1) else 1;

    const day_names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const day_names_full = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
    const month_names_full = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            const spec = fmt[i + 1];
            i += 2;
            switch (spec) {
                'Y' => try out.appendSlice(a, try std.fmt.allocPrint(a, "{d:0>4}", .{@as(u64, @intCast(year))})),
                'y' => try out.appendSlice(a, try std.fmt.allocPrint(a, "{d:0>2}", .{@as(u64, @intCast(@mod(year, 100)))})),
                'm' => try out.appendSlice(a, try std.fmt.allocPrint(a, "{d:0>2}", .{@as(u64, @intCast(mon))})),
                'd' => try out.appendSlice(a, try std.fmt.allocPrint(a, "{d:0>2}", .{@as(u64, @intCast(mday))})),
                'H' => try out.appendSlice(a, try std.fmt.allocPrint(a, "{d:0>2}", .{@as(u64, @intCast(hour))})),
                'M' => try out.appendSlice(a, try std.fmt.allocPrint(a, "{d:0>2}", .{@as(u64, @intCast(min_))})),
                'S' => try out.appendSlice(a, try std.fmt.allocPrint(a, "{d:0>2}", .{@as(u64, @intCast(sec))})),
                'j' => try out.appendSlice(a, try std.fmt.allocPrint(a, "{d:0>3}", .{@as(u64, @intCast(yday))})),
                'A' => try out.appendSlice(a, day_names_full[@intCast(@mod(wday, 7))]),
                'a' => try out.appendSlice(a, day_names[@intCast(@mod(wday, 7))]),
                'B' => try out.appendSlice(a, month_names_full[@intCast(@mod(mon - 1, 12))]),
                'b', 'h' => try out.appendSlice(a, month_names[@intCast(@mod(mon - 1, 12))]),
                'n' => try out.append(a, '\n'),
                't' => try out.append(a, '\t'),
                '%' => try out.append(a, '%'),
                else => {
                    try out.append(a, '%');
                    try out.append(a, spec);
                },
            }
        } else {
            try out.append(a, fmt[i]);
            i += 1;
        }
    }
    return Value{ .str = try Str.init(a, out.items) };
}

fn strptimeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str or args[1] != .str) {
        try interp.typeError("strptime expects (string, format)");
        return error.TypeError;
    }
    const s = args[0].str.bytes;
    const fmt = args[1].str.bytes;
    const a = interp.allocator;

    var year: i64 = 1900;
    var mon: i64 = 1;
    var mday: i64 = 1;
    var hour: i64 = 0;
    var min_: i64 = 0;
    var sec: i64 = 0;

    var si: usize = 0;
    var fi: usize = 0;
    while (fi < fmt.len and si < s.len) {
        if (fmt[fi] == '%' and fi + 1 < fmt.len) {
            const spec = fmt[fi + 1];
            fi += 2;
            switch (spec) {
                'Y' => { year = std.fmt.parseInt(i64, s[si..@min(si+4, s.len)], 10) catch 0; si += 4; },
                'm' => { mon = std.fmt.parseInt(i64, s[si..@min(si+2, s.len)], 10) catch 0; si += 2; },
                'd' => { mday = std.fmt.parseInt(i64, s[si..@min(si+2, s.len)], 10) catch 0; si += 2; },
                'H' => { hour = std.fmt.parseInt(i64, s[si..@min(si+2, s.len)], 10) catch 0; si += 2; },
                'M' => { min_ = std.fmt.parseInt(i64, s[si..@min(si+2, s.len)], 10) catch 0; si += 2; },
                'S' => { sec = std.fmt.parseInt(i64, s[si..@min(si+2, s.len)], 10) catch 0; si += 2; },
                else => { si += 1; },
            }
        } else {
            if (fmt[fi] == s[si]) { fi += 1; si += 1; }
            else break;
        }
    }

    const cls = try getOrCreateStructTimeClass(interp);
    const inst = try Instance.init(a, cls);
    try setStructTimeFields(interp, inst, year, mon, mday, hour, min_, sec, 0, 0, -1);
    return Value{ .instance = inst };
}

fn structTimeCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const cls = try getOrCreateStructTimeClass(interp);
    const inst = try Instance.init(a, cls);
    const items: []const Value = switch (if (args.len >= 1) args[0] else Value.none) {
        .tuple => |t| t.items,
        .list => |l| l.items.items,
        else => &.{},
    };
    var vals: [9]i64 = .{ 1900, 1, 1, 0, 0, 0, 0, 1, -1 };
    for (items, 0..) |v, idx| {
        if (idx >= 9) break;
        vals[idx] = switch (v) {
            .small_int => |n| n,
            .float => |f| @intFromFloat(f),
            else => 0,
        };
    }
    try setStructTimeFields(interp, inst, vals[0], vals[1], vals[2], vals[3], vals[4], vals[5], vals[6], vals[7], vals[8]);
    return Value{ .instance = inst };
}

fn reg(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "time");
    interp.time_module = m;

    try reg(a, m, "time", timeFn);
    try reg(a, m, "time_ns", timeNsFn);
    try reg(a, m, "perf_counter", perfCounterFn);
    try reg(a, m, "perf_counter_ns", perfCounterFn);
    try reg(a, m, "monotonic", monotonicFn);
    try reg(a, m, "monotonic_ns", monotonicFn);
    try reg(a, m, "process_time", processTimeFn);
    try reg(a, m, "thread_time", processTimeFn);
    try reg(a, m, "sleep", sleepFn);
    try reg(a, m, "gmtime", gmtimeFn);
    try reg(a, m, "localtime", localtimeFn);
    try reg(a, m, "mktime", mktimeFn);
    try reg(a, m, "strftime", strftimeFn);
    try reg(a, m, "strptime", strptimeFn);
    try reg(a, m, "struct_time", structTimeCtor);

    try m.attrs.setStr(a, "timezone", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "altzone", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "daylight", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "tzname", Value{ .tuple = blk: {
        const t = try Tuple.init(a, 2);
        t.items[0] = Value{ .str = try Str.init(a, "UTC") };
        t.items[1] = Value{ .str = try Str.init(a, "UTC") };
        break :blk t;
    } });

    return m;
}
