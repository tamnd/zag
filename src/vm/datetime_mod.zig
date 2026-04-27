//! Pinhole `datetime`: enough surface for fixtures. date/time/datetime/
//! timedelta/timezone with the methods 116_datetime exercises.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Str = @import("../object/string.zig").Str;
const Tuple = @import("../object/tuple.zig").Tuple;
const List = @import("../object/list.zig").List;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

fn appendFmt(buf: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(s);
    try buf.appendSlice(a, s);
}

/// Append a non-negative integer padded with leading zeros to `width`.
/// Zig 0.16's `{d:0>N}` always emits a `+` for signed types, so we go
/// through unsigned formatting here.
fn padU(buf: *std.ArrayList(u8), a: std.mem.Allocator, width: usize, val: anytype) !void {
    const u: u64 = if (val < 0) 0 else @intCast(val);
    const s = try std.fmt.allocPrint(a, "{d}", .{u});
    defer a.free(s);
    if (s.len < width) try buf.appendNTimes(a, '0', width - s.len);
    try buf.appendSlice(a, s);
}

fn allocPadU(a: std.mem.Allocator, width: usize, val: anytype) ![]u8 {
    const u: u64 = if (val < 0) 0 else @intCast(val);
    const inner = try std.fmt.allocPrint(a, "{d}", .{u});
    if (inner.len >= width) return inner;
    defer a.free(inner);
    const out = try a.alloc(u8, width);
    const pad = width - inner.len;
    @memset(out[0..pad], '0');
    @memcpy(out[pad..], inner);
    return out;
}

// ---- module entry ----

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "datetime");

    try buildClasses(interp);

    try m.attrs.setStr(a, "MINYEAR", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "MAXYEAR", Value{ .small_int = 9999 });

    try m.attrs.setStr(a, "tzinfo", Value{ .class = interp.dt_tzinfo_class.? });
    try m.attrs.setStr(a, "timedelta", Value{ .class = interp.dt_timedelta_class.? });
    try m.attrs.setStr(a, "date", Value{ .class = interp.dt_date_class.? });
    try m.attrs.setStr(a, "time", Value{ .class = interp.dt_time_class.? });
    try m.attrs.setStr(a, "datetime", Value{ .class = interp.dt_datetime_class.? });
    try m.attrs.setStr(a, "timezone", Value{ .class = interp.dt_timezone_class.? });

    // Module-level UTC: same instance as timezone.utc.
    const utc = try makeTimezoneUtc(interp);
    try m.attrs.setStr(a, "UTC", utc);

    // Class attrs: min/max/resolution and timezone.utc/min/max.
    try setClassConsts(interp);
    try interp.dt_timezone_class.?.dict.setStr(a, "utc", utc);

    return m;
}

pub fn ensureClasses(interp: *Interp) !void {
    return buildClasses(interp);
}

fn buildClasses(interp: *Interp) !void {
    if (interp.dt_date_class != null) return;
    const a = interp.allocator;

    // tzinfo: empty class so isinstance(x, tzinfo) works (not exercised here).
    {
        const d = try Dict.init(a);
        interp.dt_tzinfo_class = try Class.init(a, "tzinfo", &.{}, d);
    }

    // timedelta
    {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", tdInitFn);
        try reg(a, d, "total_seconds", tdTotalSecondsFn);
        try reg(a, d, "__repr__", tdReprFn);
        try reg(a, d, "__str__", tdStrFn);
        try reg(a, d, "__add__", tdAddFn);
        try reg(a, d, "__radd__", tdAddFn);
        try reg(a, d, "__sub__", tdSubFn);
        try reg(a, d, "__rsub__", tdRsubFn);
        try reg(a, d, "__mul__", tdMulFn);
        try reg(a, d, "__rmul__", tdMulFn);
        try reg(a, d, "__truediv__", tdTrueDivFn);
        try reg(a, d, "__floordiv__", tdFloorDivFn);
        try reg(a, d, "__mod__", tdModFn);
        try reg(a, d, "__neg__", tdNegFn);
        try reg(a, d, "__pos__", tdPosFn);
        try reg(a, d, "__abs__", tdAbsFn);
        try reg(a, d, "__bool__", tdBoolFn);
        try reg(a, d, "__lt__", tdLtFn);
        try reg(a, d, "__le__", tdLeFn);
        try reg(a, d, "__gt__", tdGtFn);
        try reg(a, d, "__ge__", tdGeFn);
        try reg(a, d, "__eq__", tdEqFn);
        try reg(a, d, "__ne__", tdNeFn);
        try reg(a, d, "__hash__", tdHashFn);
        // property accessors stored as instance dict slots written by __init__
        interp.dt_timedelta_class = try Class.init(a, "timedelta", &.{}, d);
    }

    // date
    {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", dateInitFn);
        try reg(a, d, "isoformat", dateIsoformatFn);
        try reg(a, d, "__repr__", dateReprFn);
        try reg(a, d, "__str__", dateStrFn);
        try reg(a, d, "weekday", dateWeekdayFn);
        try reg(a, d, "isoweekday", dateIsoweekdayFn);
        try reg(a, d, "toordinal", dateToOrdinalFn);
        try reg(a, d, "isocalendar", dateIsocalendarFn);
        try reg(a, d, "timetuple", dateTimetupleFn);
        try reg(a, d, "ctime", dateCtimeFn);
        try reg(a, d, "strftime", dateStrftimeFn);
        try regKw(a, d, "replace", dateReplaceKwFn);
        try reg(a, d, "fromordinal", dateFromOrdinalFn);
        try reg(a, d, "fromisoformat", dateFromisoformatFn);
        try reg(a, d, "fromisocalendar", dateFromisocalendarFn);
        try reg(a, d, "fromtimestamp", dateFromtimestampFn);
        try reg(a, d, "today", dateTodayFn);
        try reg(a, d, "__add__", dateAddFn);
        try reg(a, d, "__radd__", dateAddFn);
        try reg(a, d, "__sub__", dateSubFn);
        try reg(a, d, "__lt__", dateLtFn);
        try reg(a, d, "__le__", dateLeFn);
        try reg(a, d, "__gt__", dateGtFn);
        try reg(a, d, "__ge__", dateGeFn);
        try reg(a, d, "__eq__", dateEqFn);
        try reg(a, d, "__ne__", dateNeFn);
        try reg(a, d, "__hash__", dateHashFn);
        interp.dt_date_class = try Class.init(a, "date", &.{}, d);
    }

    // time
    {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", timeInitFn);
        try regKw(a, d, "isoformat", timeIsoformatFn);
        try reg(a, d, "__repr__", timeReprFn);
        try reg(a, d, "__str__", timeStrFn);
        try reg(a, d, "strftime", timeStrftimeFn);
        try regKw(a, d, "replace", timeReplaceFn);
        try reg(a, d, "utcoffset", timeUtcoffsetFn);
        try reg(a, d, "dst", timeDstFn);
        try reg(a, d, "tzname", timeTznameFn);
        try reg(a, d, "fromisoformat", timeFromisoformatFn);
        try reg(a, d, "__bool__", timeBoolFn);
        try reg(a, d, "__lt__", timeLtFn);
        try reg(a, d, "__le__", timeLeFn);
        try reg(a, d, "__gt__", timeGtFn);
        try reg(a, d, "__ge__", timeGeFn);
        try reg(a, d, "__eq__", timeEqFn);
        try reg(a, d, "__ne__", timeNeFn);
        try reg(a, d, "__hash__", timeHashFn);
        interp.dt_time_class = try Class.init(a, "time", &.{}, d);
    }

    // datetime
    {
        const d = try Dict.init(a);
        try regKw(a, d, "__init__", dtInitFn);
        try regKw(a, d, "isoformat", dtIsoformatFn);
        try reg(a, d, "__repr__", dtReprFn);
        try reg(a, d, "__str__", dtStrFn);
        try reg(a, d, "ctime", dtCtimeFn);
        try reg(a, d, "weekday", dtWeekdayFn);
        try reg(a, d, "isoweekday", dtIsoweekdayFn);
        try reg(a, d, "isocalendar", dtIsocalendarFn);
        try reg(a, d, "timetuple", dtTimetupleFn);
        try reg(a, d, "toordinal", dtToOrdinalFn);
        try reg(a, d, "strftime", dtStrftimeFn);
        try regKw(a, d, "replace", dtReplaceFn);
        try reg(a, d, "date", dtDateFn);
        try reg(a, d, "time", dtTimeFn);
        try reg(a, d, "timetz", dtTimetzFn);
        try reg(a, d, "utcoffset", dtUtcoffsetFn);
        try reg(a, d, "dst", dtDstFn);
        try reg(a, d, "tzname", dtTznameFn);
        try reg(a, d, "timestamp", dtTimestampFn);
        try reg(a, d, "utctimetuple", dtUtctimetupleFn);
        try reg(a, d, "fromordinal", dtFromOrdinalFn);
        try reg(a, d, "fromisoformat", dtFromisoformatFn);
        try reg(a, d, "fromisocalendar", dtFromisocalendarFn);
        try regKw(a, d, "fromtimestamp", dtFromtimestampFn);
        try reg(a, d, "utcfromtimestamp", dtUtcFromtimestampFn);
        try reg(a, d, "today", dtTodayFn);
        try reg(a, d, "now", dtNowFn);
        try reg(a, d, "utcnow", dtUtcNowFn);
        try reg(a, d, "combine", dtCombineFn);
        try reg(a, d, "strptime", dtStrptimeFn);
        try reg(a, d, "__add__", dtAddFn);
        try reg(a, d, "__radd__", dtAddFn);
        try reg(a, d, "__sub__", dtSubFn);
        try reg(a, d, "__lt__", dtLtFn);
        try reg(a, d, "__le__", dtLeFn);
        try reg(a, d, "__gt__", dtGtFn);
        try reg(a, d, "__ge__", dtGeFn);
        try reg(a, d, "__eq__", dtEqFn);
        try reg(a, d, "__ne__", dtNeFn);
        try reg(a, d, "__hash__", dtHashFn);
        interp.dt_datetime_class = try Class.init(a, "datetime", &.{}, d);
    }

    // timezone
    {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", tzInitFn);
        try reg(a, d, "utcoffset", tzUtcoffsetFn);
        try reg(a, d, "tzname", tzTznameFn);
        try reg(a, d, "dst", tzDstFn);
        try reg(a, d, "__repr__", tzReprFn);
        try reg(a, d, "__str__", tzStrFn);
        try reg(a, d, "__eq__", tzEqFn);
        try reg(a, d, "__ne__", tzNeFn);
        try reg(a, d, "__hash__", tzHashFn);
        interp.dt_timezone_class = try Class.init(a, "timezone", &.{}, d);
    }
}

fn reg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(a: std.mem.Allocator, d: *Dict, name: []const u8, comptime kw_func: value_mod.BuiltinKwFnPtr) !void {
    const Wrap = struct {
        fn call(p: *anyopaque, args: []const Value) anyerror!Value {
            return kw_func(p, args, &.{}, &.{});
        }
    };
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = Wrap.call, .kw_func = kw_func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

// ---- helpers ----

fn intArg(v: Value) !i64 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| if (b) 1 else 0,
        else => error.TypeError,
    };
}

fn intArgDefault(v: Value, def: i64) !i64 {
    if (v == .none) return def;
    return intArg(v);
}

fn isLeapYear(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

const days_in_month_normal = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

fn daysInMonth(y: i64, m: i64) i64 {
    if (m == 2 and isLeapYear(y)) return 29;
    return days_in_month_normal[@intCast(m - 1)];
}

fn daysBeforeYear(y: i64) i64 {
    const yp = y - 1;
    return yp * 365 + @divFloor(yp, 4) - @divFloor(yp, 100) + @divFloor(yp, 400);
}

fn daysBeforeMonth(y: i64, m: i64) i64 {
    var sum: i64 = 0;
    var i: i64 = 1;
    while (i < m) : (i += 1) sum += daysInMonth(y, i);
    return sum;
}

fn ymdToOrdinal(y: i64, m: i64, d: i64) i64 {
    return daysBeforeYear(y) + daysBeforeMonth(y, m) + d;
}

fn ordinalToYmd(n: i64) struct { y: i64, m: i64, d: i64 } {
    // CPython divides into 400-year cycles.
    var n0 = n - 1; // 0-based
    const n400 = @divFloor(n0, 146097);
    n0 -= n400 * 146097;
    var y: i64 = n400 * 400 + 1;

    const n100 = @divFloor(n0, 36524);
    n0 -= n100 * 36524;
    const n4 = @divFloor(n0, 1461);
    n0 -= n4 * 1461;
    const n1 = @divFloor(n0, 365);
    n0 -= n1 * 365;
    y += n100 * 100 + n4 * 4 + n1;
    if (n1 == 4 or n100 == 4) {
        return .{ .y = y - 1, .m = 12, .d = 31 };
    }
    const leap = (n1 == 3) and (n4 != 24 or n100 == 3);
    var month: i64 = 1;
    while (true) : (month += 1) {
        const dim = if (month == 2 and leap) @as(i64, 29) else days_in_month_normal[@intCast(month - 1)];
        if (n0 < dim) {
            return .{ .y = y, .m = month, .d = n0 + 1 };
        }
        n0 -= dim;
    }
}

// Monday=0
fn weekdayFromOrdinal(ord: i64) i64 {
    return @mod(ord + 6, 7);
}

const month_full = [_][]const u8{ "", "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const month_abbrev = [_][]const u8{ "", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const day_full = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
const day_abbrev = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };

fn getInt(inst: *Instance, key: []const u8) i64 {
    const v = inst.dict.getStr(key) orelse return 0;
    return switch (v) {
        .small_int => |x| x,
        .boolean => |b| if (b) 1 else 0,
        else => 0,
    };
}

fn setInt(a: std.mem.Allocator, inst: *Instance, key: []const u8, n: i64) !void {
    try inst.dict.setStr(a, key, Value{ .small_int = n });
}

fn getOptValue(inst: *Instance, key: []const u8) Value {
    return inst.dict.getStr(key) orelse Value.none;
}

// ---- timedelta ----

fn tdInitFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) {
        try interp.typeError("timedelta __init__ missing self");
        return error.TypeError;
    }
    const self = args[0].instance;
    const pos = args[1..];

    // Defaults: days, seconds, microseconds, milliseconds, minutes, hours, weeks
    var days: f64 = 0;
    var seconds: f64 = 0;
    var microseconds: f64 = 0;
    var milliseconds: f64 = 0;
    var minutes: f64 = 0;
    var hours: f64 = 0;
    var weeks: f64 = 0;

    const names = [_][]const u8{ "days", "seconds", "microseconds", "milliseconds", "minutes", "hours", "weeks" };
    const slots = [_]*f64{ &days, &seconds, &microseconds, &milliseconds, &minutes, &hours, &weeks };

    for (pos, 0..) |v, i| {
        if (i >= slots.len) {
            try interp.typeError("timedelta() too many positional arguments");
            return error.TypeError;
        }
        slots[i].* = try numToF64(v);
    }
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        for (names, 0..) |n, i| {
            if (std.mem.eql(u8, kn.str.bytes, n)) {
                slots[i].* = try numToF64(kv);
                break;
            }
        }
    }

    // Convert everything to microseconds.
    const total_us: f64 = (((days * 86400.0 + seconds) * 1e6) + microseconds + milliseconds * 1000.0 + minutes * 60_000_000.0 + hours * 3_600_000_000.0 + weeks * 7 * 86_400_000_000.0);
    var us_i: i128 = @intFromFloat(@round(total_us));
    // Normalize: 0 <= us < 1e6, 0 <= s < 86400, days unbounded.
    var d: i128 = @divFloor(us_i, 86_400_000_000);
    us_i -= d * 86_400_000_000;
    const s_i: i128 = @divFloor(us_i, 1_000_000);
    us_i -= s_i * 1_000_000;
    if (us_i < 0) {
        us_i += 1_000_000;
        // need to subtract a second; will be rebalanced below
    }
    // The above is one possible approach; redo cleanly:
    // (Re-derive from total_us to keep correctness.)
    us_i = @intFromFloat(@round(total_us));
    d = @divFloor(us_i, 86_400_000_000);
    var rem: i128 = us_i - d * 86_400_000_000;
    const ss: i128 = @divFloor(rem, 1_000_000);
    rem -= ss * 1_000_000;
    // rem in [0, 1e6)
    const dd: i128 = d;

    // Validate range as CPython
    const min_days: i64 = -999999999;
    const max_days: i64 = 999999999;
    if (dd < min_days or dd > max_days) {
        try interp.raisePy("OverflowError", "timedelta # of days is too large");
        return error.PyException;
    }

    try setInt(a, self, "_days", @intCast(dd));
    try setInt(a, self, "_seconds", @intCast(ss));
    try setInt(a, self, "_microseconds", @intCast(rem));
    // expose as Python attrs
    try inst_setProp(a, self);
    return Value.none;
}

fn numToF64(v: Value) !f64 {
    return switch (v) {
        .small_int => |i| @floatFromInt(i),
        .boolean => |b| @floatFromInt(@as(i64, @intFromBool(b))),
        .float => |f| f,
        .big_int => |i| blk: {
            const r = i.inner.toFloat(f64, .nearest_even);
            break :blk r[0];
        },
        else => error.TypeError,
    };
}

fn inst_setProp(a: std.mem.Allocator, inst: *Instance) !void {
    // Mirror the internal _* fields onto the public names date users read.
    if (inst.dict.getStr("_days")) |v| try inst.dict.setStr(a, "days", v);
    if (inst.dict.getStr("_seconds")) |v| try inst.dict.setStr(a, "seconds", v);
    if (inst.dict.getStr("_microseconds")) |v| try inst.dict.setStr(a, "microseconds", v);
}

fn tdMicros(self: *Instance) i128 {
    const d: i128 = getInt(self, "_days");
    const s: i128 = getInt(self, "_seconds");
    const u: i128 = getInt(self, "_microseconds");
    return d * 86_400_000_000 + s * 1_000_000 + u;
}

pub fn newTimedeltaPub(interp: *Interp, days: i128, seconds: i128, microseconds: i128) !Value {
    return newTimedelta(interp, days, seconds, microseconds);
}

pub fn newDatePub(interp: *Interp, y: i64, m: i64, d: i64) !Value {
    return newDate(interp, y, m, d);
}

pub fn newTimePub(interp: *Interp, h: i64, m: i64, s: i64, us: i64, tzinfo: Value, fold: i64) !Value {
    return newTime(interp, h, m, s, us, tzinfo, fold);
}

pub fn newDatetimePub(interp: *Interp, y: i64, mo: i64, d: i64, hh: i64, mm: i64, ss: i64, us: i64, tz: Value, fold: i64) !Value {
    return newDatetime(interp, y, mo, d, hh, mm, ss, us, tz, fold);
}

fn newTimedelta(interp: *Interp, days: i128, seconds: i128, microseconds: i128) !Value {
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.dt_timedelta_class.?);
    var us: i128 = days * 86_400_000_000 + seconds * 1_000_000 + microseconds;
    const dd: i128 = @divFloor(us, 86_400_000_000);
    us -= dd * 86_400_000_000;
    const ss: i128 = @divFloor(us, 1_000_000);
    us -= ss * 1_000_000;
    try setInt(a, inst, "_days", @intCast(dd));
    try setInt(a, inst, "_seconds", @intCast(ss));
    try setInt(a, inst, "_microseconds", @intCast(us));
    try inst_setProp(a, inst);
    return Value{ .instance = inst };
}

fn newTimedeltaFromMicros(interp: *Interp, total_us: i128) !Value {
    return newTimedelta(interp, 0, 0, total_us);
}

fn isTimedelta(interp: *Interp, v: Value) bool {
    return v == .instance and v.instance.cls == interp.dt_timedelta_class.?;
}

fn isDate(interp: *Interp, v: Value) bool {
    return v == .instance and v.instance.cls == interp.dt_date_class.?;
}

fn isTime(interp: *Interp, v: Value) bool {
    return v == .instance and v.instance.cls == interp.dt_time_class.?;
}

fn isDatetime(interp: *Interp, v: Value) bool {
    return v == .instance and v.instance.cls == interp.dt_datetime_class.?;
}

fn isTimezone(interp: *Interp, v: Value) bool {
    return v == .instance and v.instance.cls == interp.dt_timezone_class.?;
}

fn tdTotalSecondsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const us = tdMicros(self);
    const seconds: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(us)))) / 1e6;
    return Value{ .float = seconds };
}

fn tdReprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return tdStrFn(p, args);
}

fn tdStrFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const days = getInt(self, "_days");
    const seconds = getInt(self, "_seconds");
    const us = getInt(self, "_microseconds");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    if (days != 0) {
        if (@abs(days) == 1) {
            try appendFmt(&buf, a, "{d} day, ", .{days});
        } else {
            try appendFmt(&buf, a, "{d} days, ", .{days});
        }
    }
    const hh = @divTrunc(seconds, 3600);
    const mm = @mod(@divTrunc(seconds, 60), 60);
    const ss = @mod(seconds, 60);
    try appendFmt(&buf, a, "{d}:", .{hh});
    try padU(&buf, a, 2, mm);
    try buf.append(a, ':');
    try padU(&buf, a, 2, ss);
    if (us != 0) {
        try buf.append(a, '.');
        try padU(&buf, a, 6, us);
    }
    const owned = try buf.toOwnedSlice(a);
    return Value{ .str = try Str.fromOwnedSlice(a, owned) };
}

fn tdAddFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const a_v = args[0];
    const b_v = args[1];
    if (isTimedelta(interp, a_v) and isTimedelta(interp, b_v)) {
        return newTimedeltaFromMicros(interp, tdMicros(a_v.instance) + tdMicros(b_v.instance));
    }
    return Value.not_implemented;
}

fn tdSubFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const a_v = args[0];
    const b_v = args[1];
    if (isTimedelta(interp, a_v) and isTimedelta(interp, b_v)) {
        return newTimedeltaFromMicros(interp, tdMicros(a_v.instance) - tdMicros(b_v.instance));
    }
    return Value.not_implemented;
}

fn tdRsubFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const a_v = args[1]; // other
    const b_v = args[0]; // self
    if (isTimedelta(interp, a_v) and isTimedelta(interp, b_v)) {
        return newTimedeltaFromMicros(interp, tdMicros(a_v.instance) - tdMicros(b_v.instance));
    }
    return Value.not_implemented;
}

fn tdMulFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const a_v = args[0];
    const b_v = args[1];
    if (isTimedelta(interp, a_v)) {
        const us = tdMicros(a_v.instance);
        switch (b_v) {
            .small_int => |k| return newTimedeltaFromMicros(interp, us * @as(i128, k)),
            .boolean => |k| return newTimedeltaFromMicros(interp, us * @as(i128, @intFromBool(k))),
            .float => |f| {
                const r: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(us)))) * f;
                return newTimedeltaFromMicros(interp, @intFromFloat(@round(r)));
            },
            else => return Value.not_implemented,
        }
    }
    if (isTimedelta(interp, b_v)) {
        // commutative
        return tdMulFn(p, &.{ b_v, a_v });
    }
    return Value.not_implemented;
}

fn tdTrueDivFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const a_v = args[0];
    const b_v = args[1];
    if (!isTimedelta(interp, a_v)) return Value.not_implemented;
    const us = tdMicros(a_v.instance);
    if (isTimedelta(interp, b_v)) {
        const us2 = tdMicros(b_v.instance);
        const r: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(us)))) / @as(f64, @floatFromInt(@as(i64, @intCast(us2))));
        return Value{ .float = r };
    }
    switch (b_v) {
        .small_int => |k| return newTimedeltaFromMicros(interp, @divTrunc(us, @as(i128, k))),
        .float => |f| {
            const r: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(us)))) / f;
            return newTimedeltaFromMicros(interp, @intFromFloat(@round(r)));
        },
        else => return Value.not_implemented,
    }
}

fn tdFloorDivFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const a_v = args[0];
    const b_v = args[1];
    if (!isTimedelta(interp, a_v)) return Value.not_implemented;
    const us = tdMicros(a_v.instance);
    if (isTimedelta(interp, b_v)) {
        const us2 = tdMicros(b_v.instance);
        return Value{ .small_int = @intCast(@divFloor(us, us2)) };
    }
    switch (b_v) {
        .small_int => |k| return newTimedeltaFromMicros(interp, @divFloor(us, @as(i128, k))),
        else => return Value.not_implemented,
    }
}

fn tdModFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const a_v = args[0];
    const b_v = args[1];
    if (!isTimedelta(interp, a_v) or !isTimedelta(interp, b_v)) return Value.not_implemented;
    const us = tdMicros(a_v.instance);
    const us2 = tdMicros(b_v.instance);
    return newTimedeltaFromMicros(interp, @mod(us, us2));
}

fn tdNegFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    return newTimedeltaFromMicros(interp, -tdMicros(args[0].instance));
}
fn tdPosFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    return newTimedeltaFromMicros(interp, tdMicros(args[0].instance));
}
fn tdAbsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const us = tdMicros(args[0].instance);
    return newTimedeltaFromMicros(interp, if (us < 0) -us else us);
}
fn tdBoolFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    return Value{ .boolean = tdMicros(args[0].instance) != 0 };
}

fn tdCmp(interp: *Interp, args: []const Value) ?std.math.Order {
    if (args.len < 2) return null;
    if (!isTimedelta(interp, args[0]) or !isTimedelta(interp, args[1])) return null;
    const a_us = tdMicros(args[0].instance);
    const b_us = tdMicros(args[1].instance);
    if (a_us < b_us) return .lt;
    if (a_us > b_us) return .gt;
    return .eq;
}

fn tdLtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .boolean = (tdCmp(interp, args) orelse return Value.not_implemented) == .lt };
}
fn tdLeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const o = tdCmp(interp, args) orelse return Value.not_implemented;
    return Value{ .boolean = o != .gt };
}
fn tdGtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .boolean = (tdCmp(interp, args) orelse return Value.not_implemented) == .gt };
}
fn tdGeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const o = tdCmp(interp, args) orelse return Value.not_implemented;
    return Value{ .boolean = o != .lt };
}
fn tdEqFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const o = tdCmp(interp, args) orelse return Value{ .boolean = false };
    return Value{ .boolean = o == .eq };
}
fn tdNeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const o = tdCmp(interp, args) orelse return Value{ .boolean = true };
    return Value{ .boolean = o != .eq };
}
fn tdHashFn(_: *anyopaque, args: []const Value) anyerror!Value {
    return Value{ .small_int = @intCast(tdMicros(args[0].instance) & 0x7fffffff) };
}

// ---- date ----

fn dateInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 4 or args[0] != .instance) {
        try interp.typeError("date(year, month, day)");
        return error.TypeError;
    }
    const self = args[0].instance;
    const y = try intArg(args[1]);
    const m = try intArg(args[2]);
    const d = try intArg(args[3]);
    if (y < 1 or y > 9999) {
        try interp.raisePy("ValueError", "year out of range");
        return error.PyException;
    }
    if (m < 1 or m > 12) {
        try interp.raisePy("ValueError", "month out of range");
        return error.PyException;
    }
    if (d < 1 or d > daysInMonth(y, m)) {
        try interp.raisePy("ValueError", "day out of range for month");
        return error.PyException;
    }
    try setInt(a, self, "year", y);
    try setInt(a, self, "month", m);
    try setInt(a, self, "day", d);
    return Value.none;
}

fn newDate(interp: *Interp, y: i64, m: i64, d: i64) !Value {
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.dt_date_class.?);
    try setInt(a, inst, "year", y);
    try setInt(a, inst, "month", m);
    try setInt(a, inst, "day", d);
    return Value{ .instance = inst };
}

fn dateIsoformatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try padU(&buf, a, 4, getInt(self, "year"));
    try buf.append(a, '-');
    try padU(&buf, a, 2, getInt(self, "month"));
    try buf.append(a, '-');
    try padU(&buf, a, 2, getInt(self, "day"));
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn dateStrFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dateIsoformatFn(p, args);
}

fn dateReprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "datetime.date({d}, {d}, {d})", .{ getInt(self, "year"), getInt(self, "month"), getInt(self, "day") });
    return Value{ .str = try Str.init(interp.allocator, s) };
}

fn dateWeekdayFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    const ord = ymdToOrdinal(getInt(self, "year"), getInt(self, "month"), getInt(self, "day"));
    return Value{ .small_int = weekdayFromOrdinal(ord) };
}

fn dateIsoweekdayFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    const ord = ymdToOrdinal(getInt(self, "year"), getInt(self, "month"), getInt(self, "day"));
    return Value{ .small_int = weekdayFromOrdinal(ord) + 1 };
}

fn dateToOrdinalFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    return Value{ .small_int = ymdToOrdinal(getInt(self, "year"), getInt(self, "month"), getInt(self, "day")) };
}

fn isoYearWeekDay(y: i64, m: i64, d: i64) struct { y: i64, w: i64, dow: i64 } {
    const ord = ymdToOrdinal(y, m, d);
    const dow = weekdayFromOrdinal(ord) + 1; // 1..7
    // ISO year is the year of the Thursday of this week.
    const thu_ord = ord - (dow - 4);
    const iso_year = ordinalToYmd(thu_ord).y;
    // ISO week 1 is the week containing the first Thursday of iso_year.
    const jan1_ord = ymdToOrdinal(iso_year, 1, 1);
    const jan1_dow = weekdayFromOrdinal(jan1_ord) + 1;
    const w1_thu_ord = jan1_ord + @mod(4 - jan1_dow, 7);
    const w1_mon_ord = w1_thu_ord - 3;
    const this_mon_ord = ord - (dow - 1);
    const week = @divFloor(this_mon_ord - w1_mon_ord, 7) + 1;
    return .{ .y = iso_year, .w = week, .dow = dow };
}

fn dateIsocalendarFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    const r = isoYearWeekDay(getInt(self, "year"), getInt(self, "month"), getInt(self, "day"));
    // Build an Instance with .year/.week/.weekday attrs (CPython uses IsoCalendarDate).
    const inst = try Instance.init(a, interp.dt_date_class.?);
    // Use a tiny ad-hoc class for IsoCalendarDate? Easier: return a tuple-like Instance with attrs.
    try setInt(a, inst, "year", r.y);
    try setInt(a, inst, "week", r.w);
    try setInt(a, inst, "weekday", r.dow);
    return Value{ .instance = inst };
}

fn dateTimetupleFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    const y = getInt(self, "year");
    const m = getInt(self, "month");
    const d = getInt(self, "day");
    const ord = ymdToOrdinal(y, m, d);
    const yday = ord - daysBeforeYear(y);
    const dow = weekdayFromOrdinal(ord);
    const t = try Tuple.init(a, 9);
    t.items[0] = Value{ .small_int = y };
    t.items[1] = Value{ .small_int = m };
    t.items[2] = Value{ .small_int = d };
    t.items[3] = Value{ .small_int = 0 };
    t.items[4] = Value{ .small_int = 0 };
    t.items[5] = Value{ .small_int = 0 };
    t.items[6] = Value{ .small_int = dow };
    t.items[7] = Value{ .small_int = yday };
    t.items[8] = Value{ .small_int = -1 };
    return Value{ .tuple = t };
}

fn dateCtimeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    const y = getInt(self, "year");
    const m = getInt(self, "month");
    const d = getInt(self, "day");
    const ord = ymdToOrdinal(y, m, d);
    const dow = weekdayFromOrdinal(ord);
    const a = interp.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, day_abbrev[@intCast(dow)]);
    try buf.append(a, ' ');
    try buf.appendSlice(a, month_abbrev[@intCast(m)]);
    try buf.append(a, ' ');
    if (d < 10) try buf.append(a, ' ');
    try appendFmt(&buf, a, "{d}", .{@as(u64, @intCast(d))});
    try buf.appendSlice(a, " 00:00:00 ");
    try padU(&buf, a, 4, y);
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn dateStrftimeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[1] != .str) return error.TypeError;
    const self = args[0].instance;
    return strftime(interp, args[1].str.bytes, getInt(self, "year"), getInt(self, "month"), getInt(self, "day"), 0, 0, 0, 0);
}

fn dateReplaceFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dateReplaceKwFn(p, args, &.{}, &.{});
}

fn dateReplaceKwFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    var y = getInt(self, "year");
    var m = getInt(self, "month");
    var d = getInt(self, "day");
    if (args.len >= 2) y = try intArg(args[1]);
    if (args.len >= 3) m = try intArg(args[2]);
    if (args.len >= 4) d = try intArg(args[3]);
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const n = kn.str.bytes;
        if (std.mem.eql(u8, n, "year")) y = try intArg(kv);
        if (std.mem.eql(u8, n, "month")) m = try intArg(kv);
        if (std.mem.eql(u8, n, "day")) d = try intArg(kv);
    }
    return newDate(interp, y, m, d);
}

fn dateFromOrdinalFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const ord = try intArg(args[0]);
    const r = ordinalToYmd(ord);
    return newDate(interp, r.y, r.m, r.d);
}

fn dateFromisoformatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const s = args[0].str.bytes;
    // Format: YYYY-MM-DD
    if (s.len < 10) return error.TypeError;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return error.TypeError;
    const m = std.fmt.parseInt(i64, s[5..7], 10) catch return error.TypeError;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return error.TypeError;
    return newDate(interp, y, m, d);
}

fn dateFromisocalendarFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 3) return error.TypeError;
    const y = try intArg(args[0]);
    const w = try intArg(args[1]);
    const dow = try intArg(args[2]);
    // Monday of ISO week 1 of year y.
    const jan1_ord = ymdToOrdinal(y, 1, 1);
    const jan1_dow = weekdayFromOrdinal(jan1_ord) + 1;
    const w1_thu_ord = jan1_ord + @mod(4 - jan1_dow, 7);
    const w1_mon_ord = w1_thu_ord - 3;
    const target = w1_mon_ord + (w - 1) * 7 + (dow - 1);
    const r = ordinalToYmd(target);
    return newDate(interp, r.y, r.m, r.d);
}

fn dateFromtimestampFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const ts: i64 = switch (args[0]) {
        .small_int => |i| i,
        .float => |f| @intFromFloat(f),
        .boolean => |b| @intFromBool(b),
        else => return error.TypeError,
    };
    const days = @divFloor(ts, 86400);
    const ord = days + ymdToOrdinal(1970, 1, 1);
    const r = ordinalToYmd(ord);
    return newDate(interp, r.y, r.m, r.d);
}

fn dateTodayFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    return newDate(interp, 1970, 1, 1);
}

fn dateAddFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const a_v = args[0];
    const b_v = args[1];
    var d_inst: *Instance = undefined;
    var td_inst: *Instance = undefined;
    if (isDate(interp, a_v) and isTimedelta(interp, b_v)) {
        d_inst = a_v.instance;
        td_inst = b_v.instance;
    } else if (isDate(interp, b_v) and isTimedelta(interp, a_v)) {
        d_inst = b_v.instance;
        td_inst = a_v.instance;
    } else {
        return Value.not_implemented;
    }
    const days = getInt(td_inst, "_days");
    const ord = ymdToOrdinal(getInt(d_inst, "year"), getInt(d_inst, "month"), getInt(d_inst, "day")) + days;
    const r = ordinalToYmd(ord);
    return newDate(interp, r.y, r.m, r.d);
}

fn dateSubFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const a_v = args[0];
    const b_v = args[1];
    if (!isDate(interp, a_v)) return Value.not_implemented;
    const a_ord = ymdToOrdinal(getInt(a_v.instance, "year"), getInt(a_v.instance, "month"), getInt(a_v.instance, "day"));
    if (isDate(interp, b_v)) {
        const b_ord = ymdToOrdinal(getInt(b_v.instance, "year"), getInt(b_v.instance, "month"), getInt(b_v.instance, "day"));
        return newTimedelta(interp, @as(i128, a_ord - b_ord), 0, 0);
    }
    if (isTimedelta(interp, b_v)) {
        const days = getInt(b_v.instance, "_days");
        const ord = a_ord - days;
        const r = ordinalToYmd(ord);
        return newDate(interp, r.y, r.m, r.d);
    }
    return Value.not_implemented;
}

fn dateCmp(interp: *Interp, args: []const Value) ?std.math.Order {
    if (args.len < 2) return null;
    const a_v = args[0];
    const b_v = args[1];
    if (!isDate(interp, a_v) or (!isDate(interp, b_v) and !isDatetime(interp, b_v))) return null;
    if (isDatetime(interp, b_v) and !isDatetime(interp, a_v)) return null;
    const a_ord = ymdToOrdinal(getInt(a_v.instance, "year"), getInt(a_v.instance, "month"), getInt(a_v.instance, "day"));
    const b_ord = ymdToOrdinal(getInt(b_v.instance, "year"), getInt(b_v.instance, "month"), getInt(b_v.instance, "day"));
    if (a_ord < b_ord) return .lt;
    if (a_ord > b_ord) return .gt;
    return .eq;
}

fn dateLtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .boolean = (dateCmp(interp, args) orelse return Value.not_implemented) == .lt };
}
fn dateLeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const o = dateCmp(interp, args) orelse return Value.not_implemented;
    return Value{ .boolean = o != .gt };
}
fn dateGtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .boolean = (dateCmp(interp, args) orelse return Value.not_implemented) == .gt };
}
fn dateGeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const o = dateCmp(interp, args) orelse return Value.not_implemented;
    return Value{ .boolean = o != .lt };
}
fn dateEqFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .boolean = (dateCmp(interp, args) orelse return Value{ .boolean = false }) == .eq };
}
fn dateNeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const o = dateCmp(interp, args) orelse return Value{ .boolean = true };
    return Value{ .boolean = o != .eq };
}
fn dateHashFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    return Value{ .small_int = ymdToOrdinal(getInt(self, "year"), getInt(self, "month"), getInt(self, "day")) };
}

// ---- time ----

fn timeInitFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;

    var hour: i64 = 0;
    var minute: i64 = 0;
    var second: i64 = 0;
    var us: i64 = 0;
    var tzinfo: Value = Value.none;
    var fold: i64 = 0;

    const pos = args[1..];
    if (pos.len > 0) hour = try intArg(pos[0]);
    if (pos.len > 1) minute = try intArg(pos[1]);
    if (pos.len > 2) second = try intArg(pos[2]);
    if (pos.len > 3) us = try intArg(pos[3]);
    if (pos.len > 4) tzinfo = pos[4];

    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const k = kn.str.bytes;
        if (std.mem.eql(u8, k, "hour")) hour = try intArg(kv);
        if (std.mem.eql(u8, k, "minute")) minute = try intArg(kv);
        if (std.mem.eql(u8, k, "second")) second = try intArg(kv);
        if (std.mem.eql(u8, k, "microsecond")) us = try intArg(kv);
        if (std.mem.eql(u8, k, "tzinfo")) tzinfo = kv;
        if (std.mem.eql(u8, k, "fold")) fold = try intArg(kv);
    }

    try setInt(a, self, "hour", hour);
    try setInt(a, self, "minute", minute);
    try setInt(a, self, "second", second);
    try setInt(a, self, "microsecond", us);
    try self.dict.setStr(a, "tzinfo", tzinfo);
    try setInt(a, self, "fold", fold);
    return Value.none;
}

fn newTime(interp: *Interp, h: i64, m: i64, s: i64, us: i64, tzinfo: Value, fold: i64) !Value {
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.dt_time_class.?);
    try setInt(a, inst, "hour", h);
    try setInt(a, inst, "minute", m);
    try setInt(a, inst, "second", s);
    try setInt(a, inst, "microsecond", us);
    try inst.dict.setStr(a, "tzinfo", tzinfo);
    try setInt(a, inst, "fold", fold);
    return Value{ .instance = inst };
}

fn timeIsoformatFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    var timespec: []const u8 = "auto";
    if (args.len >= 2 and args[1] == .str) timespec = args[1].str.bytes;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "timespec") and kv == .str) {
            timespec = kv.str.bytes;
        }
    }
    return formatTime(interp, timespec, getInt(self, "hour"), getInt(self, "minute"), getInt(self, "second"), getInt(self, "microsecond"), getOptValue(self, "tzinfo"));
}

fn formatTime(interp: *Interp, timespec: []const u8, h: i64, m: i64, s: i64, us: i64, tz: Value) !Value {
    const a = interp.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    if (std.mem.eql(u8, timespec, "hours")) {
        try padU(&buf, a, 2, h);
    } else if (std.mem.eql(u8, timespec, "minutes")) {
        try padU(&buf, a, 2, h);
        try buf.append(a, ':');
        try padU(&buf, a, 2, m);
    } else if (std.mem.eql(u8, timespec, "seconds")) {
        try padU(&buf, a, 2, h);
        try buf.append(a, ':');
        try padU(&buf, a, 2, m);
        try buf.append(a, ':');
        try padU(&buf, a, 2, s);
    } else if (std.mem.eql(u8, timespec, "milliseconds")) {
        try padU(&buf, a, 2, h);
        try buf.append(a, ':');
        try padU(&buf, a, 2, m);
        try buf.append(a, ':');
        try padU(&buf, a, 2, s);
        try buf.append(a, '.');
        try padU(&buf, a, 3, @divTrunc(us, 1000));
    } else if (std.mem.eql(u8, timespec, "microseconds")) {
        try padU(&buf, a, 2, h);
        try buf.append(a, ':');
        try padU(&buf, a, 2, m);
        try buf.append(a, ':');
        try padU(&buf, a, 2, s);
        try buf.append(a, '.');
        try padU(&buf, a, 6, us);
    } else {
        // auto
        try padU(&buf, a, 2, h);
        try buf.append(a, ':');
        try padU(&buf, a, 2, m);
        try buf.append(a, ':');
        try padU(&buf, a, 2, s);
        if (us != 0) {
            try buf.append(a, '.');
            try padU(&buf, a, 6, us);
        }
    }
    if (tz != .none) {
        // Append +HH:MM offset.
        const off = try tzUtcoffsetFor(interp, tz, Value.none);
        if (off != .none and isTimedelta(interp, off)) {
            const total_sec = @divTrunc(tdMicros(off.instance), 1_000_000);
            var sign: u8 = '+';
            var sec = total_sec;
            if (sec < 0) {
                sign = '-';
                sec = -sec;
            }
            const oh = @divTrunc(sec, 3600);
            const om = @mod(@divTrunc(sec, 60), 60);
            try buf.append(a, sign);
            try padU(&buf, a, 2, oh);
            try buf.append(a, ':');
            try padU(&buf, a, 2, om);
        }
    }
    const owned = try buf.toOwnedSlice(a);
    return Value{ .str = try Str.fromOwnedSlice(a, owned) };
}

fn tzUtcoffsetFor(interp: *Interp, tz: Value, dt: Value) !Value {
    _ = interp;
    _ = dt;
    if (tz == .none) return Value.none;
    if (tz == .instance) {
        if (tz.instance.dict.getStr("_offset")) |off| return off;
    }
    return Value.none;
}

fn timeReprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return timeStrFn(p, args);
}

fn timeStrFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    return formatTime(interp, "auto", getInt(self, "hour"), getInt(self, "minute"), getInt(self, "second"), getInt(self, "microsecond"), getOptValue(self, "tzinfo"));
}

fn timeStrftimeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[1] != .str) return error.TypeError;
    const self = args[0].instance;
    return strftime(interp, args[1].str.bytes, 1900, 1, 1, getInt(self, "hour"), getInt(self, "minute"), getInt(self, "second"), getInt(self, "microsecond"));
}

fn timeReplaceFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    var hour = getInt(self, "hour");
    var minute = getInt(self, "minute");
    var second = getInt(self, "second");
    var us = getInt(self, "microsecond");
    var tz = getOptValue(self, "tzinfo");
    var fold = getInt(self, "fold");

    const pos = args[1..];
    if (pos.len > 0) hour = try intArg(pos[0]);
    if (pos.len > 1) minute = try intArg(pos[1]);
    if (pos.len > 2) second = try intArg(pos[2]);
    if (pos.len > 3) us = try intArg(pos[3]);
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const k = kn.str.bytes;
        if (std.mem.eql(u8, k, "hour")) hour = try intArg(kv);
        if (std.mem.eql(u8, k, "minute")) minute = try intArg(kv);
        if (std.mem.eql(u8, k, "second")) second = try intArg(kv);
        if (std.mem.eql(u8, k, "microsecond")) us = try intArg(kv);
        if (std.mem.eql(u8, k, "tzinfo")) tz = kv;
        if (std.mem.eql(u8, k, "fold")) fold = try intArg(kv);
    }
    return newTime(interp, hour, minute, second, us, tz, fold);
}

fn timeUtcoffsetFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const tz = getOptValue(args[0].instance, "tzinfo");
    return tzUtcoffsetFor(interp, tz, Value.none);
}

fn timeDstFn(_: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    return Value.none;
}

fn timeTznameFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    const tz = getOptValue(args[0].instance, "tzinfo");
    if (tz == .none) return Value.none;
    if (tz.instance.dict.getStr("_name")) |n| return n;
    return Value.none;
}

fn timeFromisoformatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const s = args[0].str.bytes;
    return parseIsoTime(interp, s);
}

fn parseIsoTime(interp: *Interp, s: []const u8) !Value {
    if (s.len < 5) return error.TypeError;
    const h = std.fmt.parseInt(i64, s[0..2], 10) catch return error.TypeError;
    if (s[2] != ':') return error.TypeError;
    const m = std.fmt.parseInt(i64, s[3..5], 10) catch return error.TypeError;
    var sec: i64 = 0;
    var us: i64 = 0;
    if (s.len >= 8) {
        if (s[5] != ':') return error.TypeError;
        sec = std.fmt.parseInt(i64, s[6..8], 10) catch return error.TypeError;
        if (s.len >= 9 and s[8] == '.') {
            // microseconds
            const frac = s[9..];
            // pad to 6 digits
            var buf: [6]u8 = .{ '0', '0', '0', '0', '0', '0' };
            for (frac, 0..) |c, i| {
                if (i >= 6) break;
                buf[i] = c;
            }
            us = std.fmt.parseInt(i64, &buf, 10) catch return error.TypeError;
        }
    }
    return newTime(interp, h, m, sec, us, Value.none, 0);
}

fn timeBoolFn(_: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    return Value{ .boolean = true };
}

fn timeKey(self: *Instance) i64 {
    return getInt(self, "hour") * 3600_000_000 + getInt(self, "minute") * 60_000_000 + getInt(self, "second") * 1_000_000 + getInt(self, "microsecond");
}

fn timeCmp(interp: *Interp, args: []const Value) ?std.math.Order {
    if (args.len < 2) return null;
    if (!isTime(interp, args[0]) or !isTime(interp, args[1])) return null;
    const a_k = timeKey(args[0].instance);
    const b_k = timeKey(args[1].instance);
    if (a_k < b_k) return .lt;
    if (a_k > b_k) return .gt;
    return .eq;
}

fn timeLtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .boolean = (timeCmp(interp, args) orelse return Value.not_implemented) == .lt };
}
fn timeLeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const o = timeCmp(interp, args) orelse return Value.not_implemented;
    return Value{ .boolean = o != .gt };
}
fn timeGtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .boolean = (timeCmp(interp, args) orelse return Value.not_implemented) == .gt };
}
fn timeGeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const o = timeCmp(interp, args) orelse return Value.not_implemented;
    return Value{ .boolean = o != .lt };
}
fn timeEqFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .boolean = (timeCmp(interp, args) orelse return Value{ .boolean = false }) == .eq };
}
fn timeNeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const o = timeCmp(interp, args) orelse return Value{ .boolean = true };
    return Value{ .boolean = o != .eq };
}
fn timeHashFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    return Value{ .small_int = timeKey(args[0].instance) };
}

// ---- datetime ----

fn dtInitFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;

    var y: i64 = 0;
    var mo: i64 = 0;
    var d: i64 = 0;
    var hh: i64 = 0;
    var mm: i64 = 0;
    var ss: i64 = 0;
    var us: i64 = 0;
    var tz: Value = Value.none;
    var fold: i64 = 0;

    const pos = args[1..];
    if (pos.len < 3) {
        try interp.typeError("datetime() requires year, month, day");
        return error.TypeError;
    }
    y = try intArg(pos[0]);
    mo = try intArg(pos[1]);
    d = try intArg(pos[2]);
    if (pos.len > 3) hh = try intArg(pos[3]);
    if (pos.len > 4) mm = try intArg(pos[4]);
    if (pos.len > 5) ss = try intArg(pos[5]);
    if (pos.len > 6) us = try intArg(pos[6]);
    if (pos.len > 7) tz = pos[7];

    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const k = kn.str.bytes;
        if (std.mem.eql(u8, k, "tzinfo")) tz = kv;
        if (std.mem.eql(u8, k, "fold")) fold = try intArg(kv);
        if (std.mem.eql(u8, k, "year")) y = try intArg(kv);
        if (std.mem.eql(u8, k, "month")) mo = try intArg(kv);
        if (std.mem.eql(u8, k, "day")) d = try intArg(kv);
        if (std.mem.eql(u8, k, "hour")) hh = try intArg(kv);
        if (std.mem.eql(u8, k, "minute")) mm = try intArg(kv);
        if (std.mem.eql(u8, k, "second")) ss = try intArg(kv);
        if (std.mem.eql(u8, k, "microsecond")) us = try intArg(kv);
    }

    try setInt(a, self, "year", y);
    try setInt(a, self, "month", mo);
    try setInt(a, self, "day", d);
    try setInt(a, self, "hour", hh);
    try setInt(a, self, "minute", mm);
    try setInt(a, self, "second", ss);
    try setInt(a, self, "microsecond", us);
    try self.dict.setStr(a, "tzinfo", tz);
    try setInt(a, self, "fold", fold);
    return Value.none;
}

fn newDatetime(interp: *Interp, y: i64, mo: i64, d: i64, hh: i64, mm: i64, ss: i64, us: i64, tz: Value, fold: i64) !Value {
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.dt_datetime_class.?);
    try setInt(a, inst, "year", y);
    try setInt(a, inst, "month", mo);
    try setInt(a, inst, "day", d);
    try setInt(a, inst, "hour", hh);
    try setInt(a, inst, "minute", mm);
    try setInt(a, inst, "second", ss);
    try setInt(a, inst, "microsecond", us);
    try inst.dict.setStr(a, "tzinfo", tz);
    try setInt(a, inst, "fold", fold);
    return Value{ .instance = inst };
}

fn dtIsoformatFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    var sep: u8 = 'T';
    var timespec: []const u8 = "auto";
    if (args.len >= 2 and args[1] == .str and args[1].str.bytes.len > 0) sep = args[1].str.bytes[0];
    if (args.len >= 3 and args[2] == .str) timespec = args[2].str.bytes;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const k = kn.str.bytes;
        if (std.mem.eql(u8, k, "sep") and kv == .str and kv.str.bytes.len > 0) sep = kv.str.bytes[0];
        if (std.mem.eql(u8, k, "timespec") and kv == .str) timespec = kv.str.bytes;
    }
    return formatDatetime(interp, self, sep, timespec);
}

fn formatDatetime(interp: *Interp, self: *Instance, sep: u8, timespec: []const u8) !Value {
    const a = interp.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try padU(&buf, a, 4, getInt(self, "year"));
    try buf.append(a, '-');
    try padU(&buf, a, 2, getInt(self, "month"));
    try buf.append(a, '-');
    try padU(&buf, a, 2, getInt(self, "day"));
    try buf.append(a, sep);
    const time_v = try formatTime(interp, timespec, getInt(self, "hour"), getInt(self, "minute"), getInt(self, "second"), getInt(self, "microsecond"), getOptValue(self, "tzinfo"));
    try buf.appendSlice(a, time_v.str.bytes);
    const owned = try buf.toOwnedSlice(a);
    return Value{ .str = try Str.fromOwnedSlice(a, owned) };
}

fn dtReprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dtStrFn(p, args);
}

fn dtStrFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    return formatDatetime(interp, self, ' ', "auto");
}

fn dtCtimeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    const y = getInt(self, "year");
    const m = getInt(self, "month");
    const d = getInt(self, "day");
    const ord = ymdToOrdinal(y, m, d);
    const dow = weekdayFromOrdinal(ord);
    const a = interp.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, day_abbrev[@intCast(dow)]);
    try buf.append(a, ' ');
    try buf.appendSlice(a, month_abbrev[@intCast(m)]);
    try buf.append(a, ' ');
    if (d < 10) try buf.append(a, ' ');
    try appendFmt(&buf, a, "{d}", .{@as(u64, @intCast(d))});
    try buf.append(a, ' ');
    try padU(&buf, a, 2, getInt(self, "hour"));
    try buf.append(a, ':');
    try padU(&buf, a, 2, getInt(self, "minute"));
    try buf.append(a, ':');
    try padU(&buf, a, 2, getInt(self, "second"));
    try buf.append(a, ' ');
    try padU(&buf, a, 4, y);
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn dtWeekdayFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dateWeekdayFn(p, args);
}
fn dtIsoweekdayFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dateIsoweekdayFn(p, args);
}
fn dtIsocalendarFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dateIsocalendarFn(p, args);
}

fn dtTimetupleFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    const y = getInt(self, "year");
    const m = getInt(self, "month");
    const d = getInt(self, "day");
    const ord = ymdToOrdinal(y, m, d);
    const yday = ord - daysBeforeYear(y);
    const dow = weekdayFromOrdinal(ord);
    const t = try Tuple.init(a, 9);
    t.items[0] = Value{ .small_int = y };
    t.items[1] = Value{ .small_int = m };
    t.items[2] = Value{ .small_int = d };
    t.items[3] = Value{ .small_int = getInt(self, "hour") };
    t.items[4] = Value{ .small_int = getInt(self, "minute") };
    t.items[5] = Value{ .small_int = getInt(self, "second") };
    t.items[6] = Value{ .small_int = dow };
    t.items[7] = Value{ .small_int = yday };
    t.items[8] = Value{ .small_int = -1 };
    return Value{ .tuple = t };
}

fn dtToOrdinalFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dateToOrdinalFn(p, args);
}

fn dtStrftimeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[1] != .str) return error.TypeError;
    const self = args[0].instance;
    return strftime(interp, args[1].str.bytes, getInt(self, "year"), getInt(self, "month"), getInt(self, "day"), getInt(self, "hour"), getInt(self, "minute"), getInt(self, "second"), getInt(self, "microsecond"));
}

fn dtReplaceFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    var y = getInt(self, "year");
    var mo = getInt(self, "month");
    var d = getInt(self, "day");
    var hh = getInt(self, "hour");
    var mm = getInt(self, "minute");
    var ss = getInt(self, "second");
    var us = getInt(self, "microsecond");
    var tz = getOptValue(self, "tzinfo");
    var fold = getInt(self, "fold");
    const pos = args[1..];
    if (pos.len > 0) y = try intArg(pos[0]);
    if (pos.len > 1) mo = try intArg(pos[1]);
    if (pos.len > 2) d = try intArg(pos[2]);
    if (pos.len > 3) hh = try intArg(pos[3]);
    if (pos.len > 4) mm = try intArg(pos[4]);
    if (pos.len > 5) ss = try intArg(pos[5]);
    if (pos.len > 6) us = try intArg(pos[6]);
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const k = kn.str.bytes;
        if (std.mem.eql(u8, k, "year")) y = try intArg(kv);
        if (std.mem.eql(u8, k, "month")) mo = try intArg(kv);
        if (std.mem.eql(u8, k, "day")) d = try intArg(kv);
        if (std.mem.eql(u8, k, "hour")) hh = try intArg(kv);
        if (std.mem.eql(u8, k, "minute")) mm = try intArg(kv);
        if (std.mem.eql(u8, k, "second")) ss = try intArg(kv);
        if (std.mem.eql(u8, k, "microsecond")) us = try intArg(kv);
        if (std.mem.eql(u8, k, "tzinfo")) tz = kv;
        if (std.mem.eql(u8, k, "fold")) fold = try intArg(kv);
    }
    return newDatetime(interp, y, mo, d, hh, mm, ss, us, tz, fold);
}

fn dtDateFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    return newDate(interp, getInt(self, "year"), getInt(self, "month"), getInt(self, "day"));
}

fn dtTimeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    return newTime(interp, getInt(self, "hour"), getInt(self, "minute"), getInt(self, "second"), getInt(self, "microsecond"), Value.none, 0);
}

fn dtTimetzFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    return newTime(interp, getInt(self, "hour"), getInt(self, "minute"), getInt(self, "second"), getInt(self, "microsecond"), getOptValue(self, "tzinfo"), 0);
}

fn dtUtcoffsetFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const tz = getOptValue(args[0].instance, "tzinfo");
    return tzUtcoffsetFor(interp, tz, args[0]);
}

fn dtDstFn(_: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    return Value.none;
}

fn dtTznameFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    const tz = getOptValue(args[0].instance, "tzinfo");
    if (tz == .none) return Value.none;
    if (tz.instance.dict.getStr("_name")) |n| return n;
    return Value.none;
}

fn dtTimestampFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    const ord = ymdToOrdinal(getInt(self, "year"), getInt(self, "month"), getInt(self, "day"));
    const epoch_ord = ymdToOrdinal(1970, 1, 1);
    const days = ord - epoch_ord;
    const total: f64 = @floatFromInt(days * 86400 + getInt(self, "hour") * 3600 + getInt(self, "minute") * 60 + getInt(self, "second"));
    return Value{ .float = total + @as(f64, @floatFromInt(getInt(self, "microsecond"))) / 1e6 };
}

fn dtUtctimetupleFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dtTimetupleFn(p, args);
}

fn dtFromOrdinalFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const ord = try intArg(args[0]);
    const r = ordinalToYmd(ord);
    return newDatetime(interp, r.y, r.m, r.d, 0, 0, 0, 0, Value.none, 0);
}

fn dtFromisoformatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const s = args[0].str.bytes;
    if (s.len < 10) return error.TypeError;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return error.TypeError;
    const m = std.fmt.parseInt(i64, s[5..7], 10) catch return error.TypeError;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return error.TypeError;
    var hh: i64 = 0;
    var mm: i64 = 0;
    var ss: i64 = 0;
    var us: i64 = 0;
    if (s.len >= 19) {
        hh = std.fmt.parseInt(i64, s[11..13], 10) catch return error.TypeError;
        mm = std.fmt.parseInt(i64, s[14..16], 10) catch return error.TypeError;
        ss = std.fmt.parseInt(i64, s[17..19], 10) catch return error.TypeError;
        if (s.len >= 20 and s[19] == '.') {
            const frac = s[20..];
            var buf: [6]u8 = .{ '0', '0', '0', '0', '0', '0' };
            for (frac, 0..) |c, i| {
                if (i >= 6) break;
                buf[i] = c;
            }
            us = std.fmt.parseInt(i64, &buf, 10) catch return error.TypeError;
        }
    }
    return newDatetime(interp, y, m, d, hh, mm, ss, us, Value.none, 0);
}

fn dtFromisocalendarFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 3) return error.TypeError;
    const y = try intArg(args[0]);
    const w = try intArg(args[1]);
    const dow = try intArg(args[2]);
    const jan1_ord = ymdToOrdinal(y, 1, 1);
    const jan1_dow = weekdayFromOrdinal(jan1_ord) + 1;
    const w1_thu_ord = jan1_ord + @mod(4 - jan1_dow, 7);
    const w1_mon_ord = w1_thu_ord - 3;
    const target = w1_mon_ord + (w - 1) * 7 + (dow - 1);
    const r = ordinalToYmd(target);
    return newDatetime(interp, r.y, r.m, r.d, 0, 0, 0, 0, Value.none, 0);
}

fn dtFromtimestampFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const ts: f64 = switch (args[0]) {
        .small_int => |i| @floatFromInt(i),
        .float => |f| f,
        .boolean => |b| @floatFromInt(@as(i64, @intFromBool(b))),
        else => return error.TypeError,
    };
    var tz: Value = Value.none;
    if (args.len > 1) tz = args[1];
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "tz")) tz = kv;
    }
    const ts_int: i64 = @intFromFloat(ts);
    const us: i64 = @intFromFloat(@round((ts - @as(f64, @floatFromInt(ts_int))) * 1e6));
    const days = @divFloor(ts_int, 86400);
    var rem = ts_int - days * 86400;
    if (rem < 0) {
        rem += 86400;
    }
    const hh = @divFloor(rem, 3600);
    const mm = @mod(@divFloor(rem, 60), 60);
    const ss = @mod(rem, 60);
    const ord = days + ymdToOrdinal(1970, 1, 1);
    const r = ordinalToYmd(ord);
    return newDatetime(interp, r.y, r.m, r.d, hh, mm, ss, us, tz, 0);
}

fn dtUtcFromtimestampFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dtFromtimestampFn(p, args, &.{}, &.{});
}

fn dtTodayFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    return newDatetime(interp, 1970, 1, 1, 0, 0, 0, 0, Value.none, 0);
}
fn dtNowFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dtTodayFn(p, args);
}
fn dtUtcNowFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dtTodayFn(p, args);
}

fn dtCombineFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    if (!isDate(interp, args[0]) or !isTime(interp, args[1])) return error.TypeError;
    const d_inst = args[0].instance;
    const t_inst = args[1].instance;
    return newDatetime(
        interp,
        getInt(d_inst, "year"),
        getInt(d_inst, "month"),
        getInt(d_inst, "day"),
        getInt(t_inst, "hour"),
        getInt(t_inst, "minute"),
        getInt(t_inst, "second"),
        getInt(t_inst, "microsecond"),
        getOptValue(t_inst, "tzinfo"),
        getInt(t_inst, "fold"),
    );
}

fn dtStrptimeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str or args[1] != .str) return error.TypeError;
    return strptime(interp, args[0].str.bytes, args[1].str.bytes);
}

fn dtAddFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const a_v = args[0];
    const b_v = args[1];
    var dt_inst: *Instance = undefined;
    var td_inst: *Instance = undefined;
    if (isDatetime(interp, a_v) and isTimedelta(interp, b_v)) {
        dt_inst = a_v.instance;
        td_inst = b_v.instance;
    } else if (isDatetime(interp, b_v) and isTimedelta(interp, a_v)) {
        dt_inst = b_v.instance;
        td_inst = a_v.instance;
    } else return Value.not_implemented;
    return dtPlusTimedelta(interp, dt_inst, td_inst);
}

fn dtPlusTimedelta(interp: *Interp, dt_inst: *Instance, td_inst: *Instance) !Value {
    const days_add = getInt(td_inst, "_days");
    const sec_add = getInt(td_inst, "_seconds");
    const us_add = getInt(td_inst, "_microseconds");

    var us_total: i128 = getInt(dt_inst, "microsecond") + us_add;
    var sec_total: i128 = getInt(dt_inst, "hour") * 3600 + getInt(dt_inst, "minute") * 60 + getInt(dt_inst, "second") + sec_add;
    var ord_total: i128 = ymdToOrdinal(getInt(dt_inst, "year"), getInt(dt_inst, "month"), getInt(dt_inst, "day")) + days_add;

    sec_total += @divFloor(us_total, 1_000_000);
    us_total = @mod(us_total, 1_000_000);
    ord_total += @divFloor(sec_total, 86400);
    sec_total = @mod(sec_total, 86400);

    const hh = @divFloor(sec_total, 3600);
    const mm = @mod(@divFloor(sec_total, 60), 60);
    const ss = @mod(sec_total, 60);
    const r = ordinalToYmd(@intCast(ord_total));
    return newDatetime(interp, r.y, r.m, r.d, @intCast(hh), @intCast(mm), @intCast(ss), @intCast(us_total), getOptValue(dt_inst, "tzinfo"), 0);
}

fn dtSubFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const a_v = args[0];
    const b_v = args[1];
    if (!isDatetime(interp, a_v)) return Value.not_implemented;
    if (isDatetime(interp, b_v)) {
        const a_us = dtTotalMicros(a_v.instance);
        const b_us = dtTotalMicros(b_v.instance);
        return newTimedelta(interp, 0, 0, a_us - b_us);
    }
    if (isTimedelta(interp, b_v)) {
        // Negate the timedelta and add.
        const td_inst = b_v.instance;
        const negated = try newTimedelta(interp, -getInt(td_inst, "_days"), -getInt(td_inst, "_seconds"), -getInt(td_inst, "_microseconds"));
        return dtPlusTimedelta(interp, a_v.instance, negated.instance);
    }
    return Value.not_implemented;
}

fn dtTotalMicros(self: *Instance) i128 {
    const ord: i128 = ymdToOrdinal(getInt(self, "year"), getInt(self, "month"), getInt(self, "day"));
    return ord * 86_400_000_000 + getInt(self, "hour") * 3_600_000_000 + getInt(self, "minute") * 60_000_000 + getInt(self, "second") * 1_000_000 + getInt(self, "microsecond");
}

fn dtCmp(interp: *Interp, args: []const Value) ?std.math.Order {
    if (args.len < 2) return null;
    if (!isDatetime(interp, args[0]) or !isDatetime(interp, args[1])) return null;
    const a_us = dtTotalMicros(args[0].instance);
    const b_us = dtTotalMicros(args[1].instance);
    if (a_us < b_us) return .lt;
    if (a_us > b_us) return .gt;
    return .eq;
}

fn dtLtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .boolean = (dtCmp(interp, args) orelse return Value.not_implemented) == .lt };
}
fn dtLeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const o = dtCmp(interp, args) orelse return Value.not_implemented;
    return Value{ .boolean = o != .gt };
}
fn dtGtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .boolean = (dtCmp(interp, args) orelse return Value.not_implemented) == .gt };
}
fn dtGeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const o = dtCmp(interp, args) orelse return Value.not_implemented;
    return Value{ .boolean = o != .lt };
}
fn dtEqFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .boolean = (dtCmp(interp, args) orelse return Value{ .boolean = false }) == .eq };
}
fn dtNeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const o = dtCmp(interp, args) orelse return Value{ .boolean = true };
    return Value{ .boolean = o != .eq };
}
fn dtHashFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    return Value{ .small_int = @intCast(dtTotalMicros(args[0].instance) & 0x7fffffff) };
}

// ---- timezone ----

fn tzInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    if (!isTimedelta(interp, args[1])) {
        try interp.typeError("timezone() requires a timedelta");
        return error.TypeError;
    }
    try self.dict.setStr(a, "_offset", args[1]);
    if (args.len >= 3 and args[2] == .str) {
        try self.dict.setStr(a, "_name", args[2]);
    }
    return Value.none;
}

fn makeTimezoneUtc(interp: *Interp) !Value {
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.dt_timezone_class.?);
    const zero = try newTimedelta(interp, 0, 0, 0);
    try inst.dict.setStr(a, "_offset", zero);
    try inst.dict.setStr(a, "_name", Value{ .str = try Str.init(a, "UTC") });
    return Value{ .instance = inst };
}

fn tzUtcoffsetFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    return self.dict.getStr("_offset") orelse Value.none;
}

fn tzTznameFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const self = args[0].instance;
    if (self.dict.getStr("_name")) |n| return n;
    // Auto-generate UTC±HH:MM
    const off = self.dict.getStr("_offset") orelse return Value.none;
    if (!isTimedelta(interp, off)) return Value.none;
    const total_sec = @divTrunc(tdMicros(off.instance), 1_000_000);
    var sign: u8 = '+';
    var sec = total_sec;
    if (sec < 0) {
        sign = '-';
        sec = -sec;
    }
    const hh = @divTrunc(sec, 3600);
    const mm = @mod(@divTrunc(sec, 60), 60);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "UTC");
    try buf.append(a, sign);
    try padU(&buf, a, 2, hh);
    try buf.append(a, ':');
    try padU(&buf, a, 2, mm);
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn tzDstFn(_: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    return Value.none;
}

fn tzReprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return tzStrFn(p, args);
}

fn tzStrFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return tzTznameFn(p, args);
}

fn tzCmp(interp: *Interp, args: []const Value) ?bool {
    if (args.len < 2) return null;
    if (!isTimezone(interp, args[0]) or !isTimezone(interp, args[1])) return null;
    const a_off = args[0].instance.dict.getStr("_offset") orelse return null;
    const b_off = args[1].instance.dict.getStr("_offset") orelse return null;
    return tdMicros(a_off.instance) == tdMicros(b_off.instance);
}

fn tzEqFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .boolean = tzCmp(interp, args) orelse false };
}
fn tzNeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .boolean = !(tzCmp(interp, args) orelse false) };
}
fn tzHashFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    const off = args[0].instance.dict.getStr("_offset") orelse return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(tdMicros(off.instance) & 0x7fffffff) };
}

// ---- strftime / strptime ----

fn strftime(interp: *Interp, fmt: []const u8, y: i64, m: i64, d: i64, hh: i64, mm: i64, ss: i64, us: i64) !Value {
    const a = interp.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        const c = fmt[i];
        if (c != '%' or i + 1 >= fmt.len) {
            try buf.append(a, c);
            continue;
        }
        i += 1;
        const code = fmt[i];
        switch (code) {
            'Y' => try padU(&buf, a, 4, y),
            'm' => try padU(&buf, a, 2, m),
            'd' => try padU(&buf, a, 2, d),
            'H' => try padU(&buf, a, 2, hh),
            'M' => try padU(&buf, a, 2, mm),
            'S' => try padU(&buf, a, 2, ss),
            'f' => try padU(&buf, a, 6, us),
            'A' => {
                const ord = ymdToOrdinal(y, m, d);
                const dow = weekdayFromOrdinal(ord);
                try buf.appendSlice(a, day_full[@intCast(dow)]);
            },
            'a' => {
                const ord = ymdToOrdinal(y, m, d);
                const dow = weekdayFromOrdinal(ord);
                try buf.appendSlice(a, day_abbrev[@intCast(dow)]);
            },
            'B' => try buf.appendSlice(a, month_full[@intCast(m)]),
            'b' => try buf.appendSlice(a, month_abbrev[@intCast(m)]),
            'y' => try padU(&buf, a, 2, @mod(y, 100)),
            'j' => {
                const yday = ymdToOrdinal(y, m, d) - daysBeforeYear(y);
                try padU(&buf, a, 3, yday);
            },
            '%' => try buf.append(a, '%'),
            else => try buf.append(a, code),
        }
    }
    const owned = try buf.toOwnedSlice(a);
    return Value{ .str = try Str.fromOwnedSlice(a, owned) };
}

fn strptime(interp: *Interp, s: []const u8, fmt: []const u8) !Value {
    var y: i64 = 1900;
    var mo: i64 = 1;
    var d: i64 = 1;
    var hh: i64 = 0;
    var mm: i64 = 0;
    var ss: i64 = 0;
    var fi: usize = 0;
    var si: usize = 0;
    while (fi < fmt.len) {
        const fc = fmt[fi];
        if (fc != '%') {
            if (si >= s.len or s[si] != fc) return error.TypeError;
            si += 1;
            fi += 1;
            continue;
        }
        fi += 1;
        if (fi >= fmt.len) return error.TypeError;
        const code = fmt[fi];
        fi += 1;
        const v = parseDecimal(s, &si) orelse return error.TypeError;
        switch (code) {
            'Y' => y = v,
            'y' => y = v + 2000,
            'm' => mo = v,
            'd' => d = v,
            'H' => hh = v,
            'M' => mm = v,
            'S' => ss = v,
            else => {},
        }
    }
    return newDatetime(interp, y, mo, d, hh, mm, ss, 0, Value.none, 0);
}

fn parseDecimal(s: []const u8, si: *usize) ?i64 {
    var i = si.*;
    const start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    const v = std.fmt.parseInt(i64, s[start..i], 10) catch return null;
    si.* = i;
    return v;
}

// ---- class const setup ----

fn setClassConsts(interp: *Interp) !void {
    const a = interp.allocator;

    // timedelta.min/max/resolution
    const td_min = try newTimedelta(interp, -999999999, 0, 0);
    const td_max = try newTimedelta(interp, 999999999, 86399, 999999);
    const td_res = try newTimedelta(interp, 0, 0, 1);
    try interp.dt_timedelta_class.?.dict.setStr(a, "min", td_min);
    try interp.dt_timedelta_class.?.dict.setStr(a, "max", td_max);
    try interp.dt_timedelta_class.?.dict.setStr(a, "resolution", td_res);

    // date.min/max/resolution
    const d_min = try newDate(interp, 1, 1, 1);
    const d_max = try newDate(interp, 9999, 12, 31);
    const d_res = try newTimedelta(interp, 1, 0, 0);
    try interp.dt_date_class.?.dict.setStr(a, "min", d_min);
    try interp.dt_date_class.?.dict.setStr(a, "max", d_max);
    try interp.dt_date_class.?.dict.setStr(a, "resolution", d_res);

    // time.min/max/resolution
    const t_min = try newTime(interp, 0, 0, 0, 0, Value.none, 0);
    const t_max = try newTime(interp, 23, 59, 59, 999999, Value.none, 0);
    const t_res = try newTimedelta(interp, 0, 0, 1);
    try interp.dt_time_class.?.dict.setStr(a, "min", t_min);
    try interp.dt_time_class.?.dict.setStr(a, "max", t_max);
    try interp.dt_time_class.?.dict.setStr(a, "resolution", t_res);

    // datetime.min/max/resolution
    const dt_min = try newDatetime(interp, 1, 1, 1, 0, 0, 0, 0, Value.none, 0);
    const dt_max = try newDatetime(interp, 9999, 12, 31, 23, 59, 59, 999999, Value.none, 0);
    const dt_res = try newTimedelta(interp, 0, 0, 1);
    try interp.dt_datetime_class.?.dict.setStr(a, "min", dt_min);
    try interp.dt_datetime_class.?.dict.setStr(a, "max", dt_max);
    try interp.dt_datetime_class.?.dict.setStr(a, "resolution", dt_res);

    // timezone.min/max
    const off_min = try newTimedelta(interp, 0, -86340, 0); // -23:59
    const off_max = try newTimedelta(interp, 0, 86340, 0); // +23:59
    const tz_min = try Instance.init(a, interp.dt_timezone_class.?);
    try tz_min.dict.setStr(a, "_offset", off_min);
    const tz_max = try Instance.init(a, interp.dt_timezone_class.?);
    try tz_max.dict.setStr(a, "_offset", off_max);
    try interp.dt_timezone_class.?.dict.setStr(a, "min", Value{ .instance = tz_min });
    try interp.dt_timezone_class.?.dict.setStr(a, "max", Value{ .instance = tz_max });
}
