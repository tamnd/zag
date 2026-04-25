//! Pinhole `calendar`: enough surface for the fixture probes.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

const month_names = [_][]const u8{
    "", "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
};
const month_abbrs = [_][]const u8{
    "", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};
const day_names = [_][]const u8{
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
};
const day_abbrs = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "calendar");
    try reg(interp, m, "isleap", isleapFn);
    try reg(interp, m, "leapdays", leapdaysFn);
    try reg(interp, m, "weekday", weekdayFn);
    try reg(interp, m, "monthrange", monthrangeFn);
    try reg(interp, m, "monthcalendar", monthcalendarFn);
    try reg(interp, m, "timegm", timegmFn);

    // Day constants (Monday=0..Sunday=6).
    try m.attrs.setStr(a, "MONDAY", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "TUESDAY", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "WEDNESDAY", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "THURSDAY", Value{ .small_int = 3 });
    try m.attrs.setStr(a, "FRIDAY", Value{ .small_int = 4 });
    try m.attrs.setStr(a, "SATURDAY", Value{ .small_int = 5 });
    try m.attrs.setStr(a, "SUNDAY", Value{ .small_int = 6 });

    // month_name / month_abbr / day_name / day_abbr exposed as lists; the
    // fixture only indexes them, so a list is indistinguishable from
    // CPython's calendar._localized_month proxy.
    try m.attrs.setStr(a, "month_name", try strList(a, &month_names));
    try m.attrs.setStr(a, "month_abbr", try strList(a, &month_abbrs));
    try m.attrs.setStr(a, "day_name", try strList(a, &day_names));
    try m.attrs.setStr(a, "day_abbr", try strList(a, &day_abbrs));
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn strList(a: std.mem.Allocator, items: []const []const u8) !Value {
    const list = try List.init(a);
    for (items) |s| {
        const sv = try Str.init(a, s);
        try list.append(a, Value{ .str = sv });
    }
    return Value{ .list = list };
}

fn isLeapYear(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn intArg(v: Value) !i64 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| if (b) 1 else 0,
        else => error.TypeError,
    };
}

fn isleapFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    const y = try intArg(args[0]);
    return Value{ .boolean = isLeapYear(y) };
}

fn leapdaysFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.TypeError;
    const y1 = try intArg(args[0]);
    const y2 = try intArg(args[1]);
    // CPython: number of leap years in [y1, y2)
    const a = y1 - 1;
    const b = y2 - 1;
    const fa = @divFloor(a, 4) - @divFloor(a, 100) + @divFloor(a, 400);
    const fb = @divFloor(b, 4) - @divFloor(b, 100) + @divFloor(b, 400);
    const count = fb - fa;
    return Value{ .small_int = count };
}

const days_in_month_normal = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

fn daysInMonth(y: i64, m: i64) i64 {
    if (m == 2 and isLeapYear(y)) return 29;
    return days_in_month_normal[@intCast(m - 1)];
}

// Zeller-ish: weekday with Monday=0.
fn weekdayOf(y: i64, m: i64, d: i64) i64 {
    var yy = y;
    var mm = m;
    if (mm < 3) {
        mm += 12;
        yy -= 1;
    }
    const k = @mod(yy, 100);
    const j = @divFloor(yy, 100);
    // Zeller's: h = (d + 13*(m+1)/5 + k + k/4 + j/4 - 2*j) mod 7, 0=Saturday
    const h = @mod(d + @divFloor(13 * (mm + 1), 5) + k + @divFloor(k, 4) + @divFloor(j, 4) - 2 * j, 7);
    // Convert: Saturday=0 -> Monday=0
    return @mod(h + 5, 7);
}

fn weekdayFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 3) return error.TypeError;
    const y = try intArg(args[0]);
    const m = try intArg(args[1]);
    const d = try intArg(args[2]);
    return Value{ .small_int = weekdayOf(y, m, d) };
}

fn monthrangeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const y = try intArg(args[0]);
    const m = try intArg(args[1]);
    const first = weekdayOf(y, m, 1);
    const ndays = daysInMonth(y, m);
    const t = try Tuple.fromSlice(a, &[_]Value{
        Value{ .small_int = first },
        Value{ .small_int = ndays },
    });
    return Value{ .tuple = t };
}

fn monthcalendarFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const y = try intArg(args[0]);
    const m = try intArg(args[1]);
    const first = weekdayOf(y, m, 1);
    const ndays = daysInMonth(y, m);
    const out = try List.init(a);
    var week = try List.init(a);
    var col: i64 = 0;
    while (col < first) : (col += 1) {
        try week.append(a, Value{ .small_int = 0 });
    }
    var d: i64 = 1;
    while (d <= ndays) : (d += 1) {
        try week.append(a, Value{ .small_int = d });
        col += 1;
        if (col == 7) {
            try out.append(a, Value{ .list = week });
            week = try List.init(a);
            col = 0;
        }
    }
    if (col != 0) {
        while (col < 7) : (col += 1) try week.append(a, Value{ .small_int = 0 });
        try out.append(a, Value{ .list = week });
    }
    return Value{ .list = out };
}

fn timegmFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    const items: []const Value = switch (args[0]) {
        .tuple => |t| t.items,
        .list => |l| l.items.items,
        else => return error.TypeError,
    };
    if (items.len < 6) return error.TypeError;
    const y = try intArg(items[0]);
    const mo = try intArg(items[1]);
    const d = try intArg(items[2]);
    const hh = try intArg(items[3]);
    const mm = try intArg(items[4]);
    const ss = try intArg(items[5]);

    // Days from 1970-01-01 (UTC) to (y, mo, d).
    var days: i64 = 0;
    var yy: i64 = 1970;
    while (yy < y) : (yy += 1) {
        days += if (isLeapYear(yy)) 366 else 365;
    }
    while (yy > y) : (yy -= 1) {
        days -= if (isLeapYear(yy - 1)) 366 else 365;
    }
    var mi: i64 = 1;
    while (mi < mo) : (mi += 1) days += daysInMonth(y, mi);
    days += d - 1;
    return Value{ .small_int = days * 86400 + hh * 3600 + mm * 60 + ss };
}
