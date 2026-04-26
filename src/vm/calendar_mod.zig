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
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
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

const day_enum_names = [_][]const u8{
    "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY",
};
const month_enum_names = [_][]const u8{
    "", "JANUARY", "FEBRUARY", "MARCH",     "APRIL",   "MAY",      "JUNE",
    "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER",
};

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "calendar");

    try ensureClasses(interp);

    // Day constants (Monday=0..Sunday=6).
    try m.attrs.setStr(a, "MONDAY", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "TUESDAY", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "WEDNESDAY", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "THURSDAY", Value{ .small_int = 3 });
    try m.attrs.setStr(a, "FRIDAY", Value{ .small_int = 4 });
    try m.attrs.setStr(a, "SATURDAY", Value{ .small_int = 5 });
    try m.attrs.setStr(a, "SUNDAY", Value{ .small_int = 6 });

    // Month constants (January=1..December=12).
    try m.attrs.setStr(a, "JANUARY", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "FEBRUARY", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "MARCH", Value{ .small_int = 3 });
    try m.attrs.setStr(a, "APRIL", Value{ .small_int = 4 });
    try m.attrs.setStr(a, "MAY", Value{ .small_int = 5 });
    try m.attrs.setStr(a, "JUNE", Value{ .small_int = 6 });
    try m.attrs.setStr(a, "JULY", Value{ .small_int = 7 });
    try m.attrs.setStr(a, "AUGUST", Value{ .small_int = 8 });
    try m.attrs.setStr(a, "SEPTEMBER", Value{ .small_int = 9 });
    try m.attrs.setStr(a, "OCTOBER", Value{ .small_int = 10 });
    try m.attrs.setStr(a, "NOVEMBER", Value{ .small_int = 11 });
    try m.attrs.setStr(a, "DECEMBER", Value{ .small_int = 12 });

    // month_name / month_abbr / day_name / day_abbr exposed as lists; the
    // fixture only indexes them, so a list is indistinguishable from
    // CPython's calendar._localized_month proxy.
    try m.attrs.setStr(a, "month_name", try strList(a, &month_names));
    try m.attrs.setStr(a, "month_abbr", try strList(a, &month_abbrs));
    try m.attrs.setStr(a, "day_name", try strList(a, &day_names));
    try m.attrs.setStr(a, "day_abbr", try strList(a, &day_abbrs));

    try m.attrs.setStr(a, "Day", Value{ .class = interp.calendar_day_class.? });
    try m.attrs.setStr(a, "Month", Value{ .class = interp.calendar_month_class.? });
    try m.attrs.setStr(a, "Calendar", Value{ .class = interp.calendar_calendar_class.? });
    try m.attrs.setStr(a, "TextCalendar", Value{ .class = interp.calendar_text_class.? });
    try m.attrs.setStr(a, "HTMLCalendar", Value{ .class = interp.calendar_html_class.? });
    try m.attrs.setStr(a, "LocaleTextCalendar", Value{ .class = interp.calendar_locale_text_class.? });
    try m.attrs.setStr(a, "LocaleHTMLCalendar", Value{ .class = interp.calendar_locale_html_class.? });
    try m.attrs.setStr(a, "IllegalMonthError", Value{ .class = interp.calendar_illegal_month_class.? });
    try m.attrs.setStr(a, "IllegalWeekdayError", Value{ .class = interp.calendar_illegal_weekday_class.? });

    try regModFn(interp, m, "isleap", isleapFn);
    try regModFn(interp, m, "leapdays", leapdaysFn);
    try regModFn(interp, m, "weekday", weekdayFn);
    try regModFn(interp, m, "monthrange", monthrangeFn);
    try regModFn(interp, m, "monthcalendar", monthcalendarFn);
    try regModFn(interp, m, "timegm", timegmFn);
    try regModFn(interp, m, "firstweekday", firstweekdayFn);
    try regModFn(interp, m, "setfirstweekday", setfirstweekdayFn);
    try regModFn(interp, m, "weekheader", weekheaderFn);
    try regModFn(interp, m, "month", monthFn);
    try regModFn(interp, m, "prmonth", prmonthFn);
    try regModFn(interp, m, "calendar", yearFn);
    try regModFn(interp, m, "prcal", prcalFn);
    try regModFn(interp, m, "formatstring", formatstringFn);

    interp.calendar_module = m;
    return m;
}

fn ensureClasses(interp: *Interp) !void {
    if (interp.calendar_calendar_class != null) return;
    const a = interp.allocator;

    // Day enum: instances carry .value (int) and .name (str).
    {
        const d = try Dict.init(a);
        try reg(a, d, "__repr__", enumReprFn);
        try reg(a, d, "__str__", enumReprFn);
        const cls = try Class.init(a, "Day", &.{}, d);
        for (day_enum_names, 0..) |nm, i| {
            const inst = try Instance.init(a, cls);
            try inst.dict.setStr(a, "value", Value{ .small_int = @intCast(i) });
            try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, nm) });
            try cls.dict.setStr(a, nm, Value{ .instance = inst });
        }
        interp.calendar_day_class = cls;
    }

    // Month enum: indices 1..12.
    {
        const d = try Dict.init(a);
        try reg(a, d, "__repr__", enumReprFn);
        try reg(a, d, "__str__", enumReprFn);
        const cls = try Class.init(a, "Month", &.{}, d);
        var i: usize = 1;
        while (i <= 12) : (i += 1) {
            const inst = try Instance.init(a, cls);
            try inst.dict.setStr(a, "value", Value{ .small_int = @intCast(i) });
            try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, month_enum_names[i]) });
            try cls.dict.setStr(a, month_enum_names[i], Value{ .instance = inst });
        }
        interp.calendar_month_class = cls;
    }

    // IllegalMonthError / IllegalWeekdayError extend ValueError.
    {
        const ve_v = interp.builtins.getStr("ValueError") orelse return error.TypeError;
        const dm = try Dict.init(a);
        interp.calendar_illegal_month_class = try Class.init(a, "IllegalMonthError", &.{ve_v.class}, dm);
        const dw = try Dict.init(a);
        interp.calendar_illegal_weekday_class = try Class.init(a, "IllegalWeekdayError", &.{ve_v.class}, dw);
    }

    // Calendar
    var cal_class: *Class = undefined;
    {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", calInitFn);
        try reg(a, d, "iterweekdays", calIterweekdaysFn);
        try reg(a, d, "itermonthdays", calItermonthdaysFn);
        try reg(a, d, "itermonthdays2", calItermonthdays2Fn);
        try reg(a, d, "itermonthdays3", calItermonthdays3Fn);
        try reg(a, d, "itermonthdays4", calItermonthdays4Fn);
        try reg(a, d, "itermonthdates", calItermonthdaysFn);
        try reg(a, d, "monthdayscalendar", calMonthdayscalendarFn);
        try reg(a, d, "monthdays2calendar", calMonthdays2calendarFn);
        try reg(a, d, "monthdatescalendar", calMonthdayscalendarFn);
        try regKw(a, d, "yeardayscalendar", calYeardayscalendarFn);
        try regKw(a, d, "yeardays2calendar", calYeardays2calendarFn);
        try regKw(a, d, "yeardatescalendar", calYeardayscalendarFn);
        cal_class = try Class.init(a, "Calendar", &.{}, d);
        interp.calendar_calendar_class = cal_class;
    }

    // TextCalendar(Calendar)
    var text_class: *Class = undefined;
    {
        const d = try Dict.init(a);
        try regKw(a, d, "formatmonth", tcFormatmonthFn);
        try reg(a, d, "formatweekheader", tcFormatweekheaderFn);
        try regKw(a, d, "formatyear", tcFormatyearFn);
        try regKw(a, d, "prmonth", tcPrmonthFn);
        try regKw(a, d, "pryear", tcPryearFn);
        try reg(a, d, "formatmonthname", tcFormatmonthnameFn);
        try reg(a, d, "formatday", tcFormatdayFn);
        try reg(a, d, "formatweek", tcFormatweekFn);
        text_class = try Class.init(a, "TextCalendar", &.{cal_class}, d);
        interp.calendar_text_class = text_class;
    }

    // HTMLCalendar(Calendar)
    var html_class: *Class = undefined;
    {
        const d = try Dict.init(a);
        try regKw(a, d, "formatmonth", hcFormatmonthFn);
        try regKw(a, d, "formatyear", hcFormatyearFn);
        try regKw(a, d, "formatyearpage", hcFormatyearpageFn);
        try reg(a, d, "formatday", hcFormatdayFn);
        try reg(a, d, "formatweek", hcFormatweekFn);
        try reg(a, d, "formatweekday", hcFormatweekdayFn);
        try reg(a, d, "formatweekheader", hcFormatweekheaderFn);
        try reg(a, d, "formatmonthname", hcFormatmonthnameFn);
        // class attrs for css classes.
        try d.setStr(a, "cssclass_year", Value{ .str = try Str.init(a, "year") });
        try d.setStr(a, "cssclass_year_head", Value{ .str = try Str.init(a, "year") });
        try d.setStr(a, "cssclass_month", Value{ .str = try Str.init(a, "month") });
        try d.setStr(a, "cssclass_month_head", Value{ .str = try Str.init(a, "month") });
        try d.setStr(a, "cssclasses", try strList(a, &.{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" }));
        html_class = try Class.init(a, "HTMLCalendar", &.{cal_class}, d);
        interp.calendar_html_class = html_class;
    }

    // LocaleTextCalendar(TextCalendar) / LocaleHTMLCalendar(HTMLCalendar)
    {
        const d = try Dict.init(a);
        interp.calendar_locale_text_class = try Class.init(a, "LocaleTextCalendar", &.{text_class}, d);
    }
    {
        const d = try Dict.init(a);
        interp.calendar_locale_html_class = try Class.init(a, "LocaleHTMLCalendar", &.{html_class}, d);
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

fn regModFn(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
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
        .instance => |inst| if (inst.dict.getStr("value")) |vv| switch (vv) {
            .small_int => |i| i,
            .boolean => |b| if (b) 1 else 0,
            else => error.TypeError,
        } else error.TypeError,
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
    const ai = y1 - 1;
    const bi = y2 - 1;
    const fa = @divFloor(ai, 4) - @divFloor(ai, 100) + @divFloor(ai, 400);
    const fb = @divFloor(bi, 4) - @divFloor(bi, 100) + @divFloor(bi, 400);
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
    const h = @mod(d + @divFloor(13 * (mm + 1), 5) + k + @divFloor(k, 4) + @divFloor(j, 4) - 2 * j, 7);
    return @mod(h + 5, 7);
}

fn weekdayFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 3) return error.TypeError;
    const y = try intArg(args[0]);
    const m = try intArg(args[1]);
    const d = try intArg(args[2]);
    return Value{ .small_int = weekdayOf(y, m, d) };
}

fn raiseIllegalMonth(interp: *Interp, m: i64) !void {
    const a = interp.allocator;
    const cls = interp.calendar_illegal_month_class.?;
    const inst = try Instance.init(a, cls);
    const t = try Tuple.init(a, 1);
    const msg = try std.fmt.allocPrint(a, "bad month number {d}; must be 1-12", .{m});
    t.items[0] = Value{ .str = try Str.fromOwnedSlice(a, msg) };
    try inst.dict.setStr(a, "args", Value{ .tuple = t });
    interp.current_exc = Value{ .instance = inst };
}

fn raiseIllegalWeekday(interp: *Interp, w: i64) !void {
    const a = interp.allocator;
    const cls = interp.calendar_illegal_weekday_class.?;
    const inst = try Instance.init(a, cls);
    const t = try Tuple.init(a, 1);
    const msg = try std.fmt.allocPrint(a, "bad weekday number {d}; must be 0 (Monday) to 6 (Sunday)", .{w});
    t.items[0] = Value{ .str = try Str.fromOwnedSlice(a, msg) };
    try inst.dict.setStr(a, "args", Value{ .tuple = t });
    interp.current_exc = Value{ .instance = inst };
}

fn monthrangeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const y = try intArg(args[0]);
    const m = try intArg(args[1]);
    if (m < 1 or m > 12) {
        try raiseIllegalMonth(interp, m);
        return error.PyException;
    }
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
    if (m < 1 or m > 12) {
        try raiseIllegalMonth(interp, m);
        return error.PyException;
    }
    return try buildMonthDaysCalendar(a, y, m, interp.calendar_first_weekday);
}

fn buildMonthDaysCalendar(a: std.mem.Allocator, y: i64, m: i64, fwd: i64) !Value {
    const first = weekdayOf(y, m, 1);
    const ndays = daysInMonth(y, m);
    const out = try List.init(a);
    var week = try List.init(a);
    var col: i64 = @mod(first - fwd, 7);
    var c: i64 = 0;
    while (c < col) : (c += 1) try week.append(a, Value{ .small_int = 0 });
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

fn firstweekdayFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .small_int = interp.calendar_first_weekday };
}

fn setfirstweekdayFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const w = try intArg(args[0]);
    if (w < 0 or w > 6) {
        try raiseIllegalWeekday(interp, w);
        return error.PyException;
    }
    interp.calendar_first_weekday = w;
    return Value.none;
}

fn weekheaderFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const width = try intArg(args[0]);
    return try makeWeekheader(interp.allocator, @max(width, 0), interp.calendar_first_weekday);
}

fn makeWeekheader(a: std.mem.Allocator, width: i64, fwd: i64) !Value {
    const w: usize = @intCast(@max(width, 0));
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var i: i64 = 0;
    while (i < 7) : (i += 1) {
        if (i > 0) try buf.append(a, ' ');
        const day_idx: usize = @intCast(@mod(fwd + i, 7));
        const full = day_names[day_idx];
        const truncated = if (full.len > w) full[0..w] else full;
        // Right-justify within width.
        if (truncated.len < w) {
            try buf.appendNTimes(a, ' ', w - truncated.len);
        }
        try buf.appendSlice(a, truncated);
    }
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn monthFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const y = try intArg(args[0]);
    const m = try intArg(args[1]);
    var w: i64 = 2;
    var l: i64 = 1;
    if (args.len >= 3) w = try intArg(args[2]);
    if (args.len >= 4) l = try intArg(args[3]);
    if (m < 1 or m > 12) {
        try raiseIllegalMonth(interp, m);
        return error.PyException;
    }
    return try formatMonthText(interp, y, m, w, l);
}

fn prmonthFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const v = try monthFn(p, args);
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = interp;
    return v;
}

fn yearFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const y = try intArg(args[0]);
    var w: i64 = 2;
    var l: i64 = 1;
    var c: i64 = 6;
    var mm: i64 = 3;
    if (args.len >= 2) w = try intArg(args[1]);
    if (args.len >= 3) l = try intArg(args[2]);
    if (args.len >= 4) c = try intArg(args[3]);
    if (args.len >= 5) mm = try intArg(args[4]);
    return try formatYearText(interp, y, w, l, c, mm);
}

fn prcalFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return yearFn(p, args);
}

fn formatstringFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const items: []const Value = switch (args[0]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    var sep_str: []const u8 = " ";
    if (args.len >= 3 and args[2] == .str) sep_str = args[2].str.bytes;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    for (items, 0..) |it, i| {
        if (i > 0) try buf.appendSlice(a, sep_str);
        if (it == .str) try buf.appendSlice(a, it.str.bytes);
    }
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

// ---- Calendar class methods ----

fn instArg(args: []const Value, idx: usize) !*Instance {
    if (idx >= args.len) return error.TypeError;
    if (args[idx] != .instance) return error.TypeError;
    return args[idx].instance;
}

fn instFwd(self: *Instance, fallback: i64) i64 {
    if (self.dict.getStr("firstweekday")) |v| {
        return switch (v) {
            .small_int => |i| i,
            .boolean => |b| if (b) 1 else 0,
            else => fallback,
        };
    }
    return fallback;
}

fn calInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const self = try instArg(args, 0);
    var fwd: i64 = 0;
    if (args.len >= 2) fwd = try intArg(args[1]);
    if (fwd < 0 or fwd > 6) {
        try raiseIllegalWeekday(interp, fwd);
        return error.PyException;
    }
    try self.dict.setStr(interp.allocator, "firstweekday", Value{ .small_int = fwd });
    return Value.none;
}

fn calIterweekdaysFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instArg(args, 0);
    const fwd = instFwd(self, 0);
    const out = try List.init(a);
    var i: i64 = 0;
    while (i < 7) : (i += 1) {
        try out.append(a, Value{ .small_int = @mod(fwd + i, 7) });
    }
    return Value{ .list = out };
}

fn calItermonthdaysFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instArg(args, 0);
    if (args.len < 3) return error.TypeError;
    const y = try intArg(args[1]);
    const m = try intArg(args[2]);
    if (m < 1 or m > 12) {
        try raiseIllegalMonth(interp, m);
        return error.PyException;
    }
    const fwd = instFwd(self, 0);
    const first = weekdayOf(y, m, 1);
    const ndays = daysInMonth(y, m);
    const days_before: i64 = @mod(first - fwd, 7);
    const days_after: i64 = @mod(7 - @mod(days_before + ndays, 7), 7);
    const total: i64 = days_before + ndays + days_after;
    const out = try List.init(a);
    var i: i64 = 0;
    while (i < total) : (i += 1) {
        const d = i - days_before + 1;
        const v: i64 = if (d < 1 or d > ndays) 0 else d;
        try out.append(a, Value{ .small_int = v });
    }
    return Value{ .list = out };
}

fn calItermonthdays2Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instArg(args, 0);
    if (args.len < 3) return error.TypeError;
    const y = try intArg(args[1]);
    const m = try intArg(args[2]);
    if (m < 1 or m > 12) {
        try raiseIllegalMonth(interp, m);
        return error.PyException;
    }
    const fwd = instFwd(self, 0);
    const first = weekdayOf(y, m, 1);
    const ndays = daysInMonth(y, m);
    const days_before: i64 = @mod(first - fwd, 7);
    const days_after: i64 = @mod(7 - @mod(days_before + ndays, 7), 7);
    const total: i64 = days_before + ndays + days_after;
    const out = try List.init(a);
    var i: i64 = 0;
    while (i < total) : (i += 1) {
        const d = i - days_before + 1;
        const v: i64 = if (d < 1 or d > ndays) 0 else d;
        const wd: i64 = @mod(fwd + i, 7);
        const t = try Tuple.fromSlice(a, &[_]Value{
            Value{ .small_int = v },
            Value{ .small_int = wd },
        });
        try out.append(a, Value{ .tuple = t });
    }
    return Value{ .list = out };
}

fn calItermonthdays3Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instArg(args, 0);
    if (args.len < 3) return error.TypeError;
    const y = try intArg(args[1]);
    const m = try intArg(args[2]);
    if (m < 1 or m > 12) {
        try raiseIllegalMonth(interp, m);
        return error.PyException;
    }
    const fwd = instFwd(self, 0);
    const first = weekdayOf(y, m, 1);
    const ndays = daysInMonth(y, m);
    const days_before: i64 = @mod(first - fwd, 7);
    const days_after: i64 = @mod(7 - @mod(days_before + ndays, 7), 7);
    // Pre/post month dates: Python pads with neighboring months.
    const out = try List.init(a);
    // Walk i from -days_before to ndays + days_after - 1 mapping to (yy, mm, dd).
    var i: i64 = -days_before;
    const end: i64 = ndays + days_after;
    while (i < end) : (i += 1) {
        const target = monthDayPlus(y, m, i);
        const t = try Tuple.fromSlice(a, &[_]Value{
            Value{ .small_int = target.y },
            Value{ .small_int = target.m },
            Value{ .small_int = target.d },
        });
        try out.append(a, Value{ .tuple = t });
    }
    return Value{ .list = out };
}

fn calItermonthdays4Fn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instArg(args, 0);
    if (args.len < 3) return error.TypeError;
    const y = try intArg(args[1]);
    const m = try intArg(args[2]);
    if (m < 1 or m > 12) {
        try raiseIllegalMonth(interp, m);
        return error.PyException;
    }
    const fwd = instFwd(self, 0);
    const first = weekdayOf(y, m, 1);
    const ndays = daysInMonth(y, m);
    const days_before: i64 = @mod(first - fwd, 7);
    const days_after: i64 = @mod(7 - @mod(days_before + ndays, 7), 7);
    const out = try List.init(a);
    var i: i64 = -days_before;
    const end: i64 = ndays + days_after;
    var idx: i64 = 0;
    while (i < end) : ({
        i += 1;
        idx += 1;
    }) {
        const target = monthDayPlus(y, m, i);
        const wd: i64 = @mod(fwd + idx, 7);
        const t = try Tuple.fromSlice(a, &[_]Value{
            Value{ .small_int = target.y },
            Value{ .small_int = target.m },
            Value{ .small_int = target.d },
            Value{ .small_int = wd },
        });
        try out.append(a, Value{ .tuple = t });
    }
    return Value{ .list = out };
}

const YMD = struct { y: i64, m: i64, d: i64 };

/// Day at offset `delta` from (y, m, 1).
fn monthDayPlus(y: i64, m: i64, delta: i64) YMD {
    const new_d = 1 + delta;
    if (new_d >= 1 and new_d <= daysInMonth(y, m)) {
        return .{ .y = y, .m = m, .d = new_d };
    }
    if (new_d < 1) {
        // Previous month.
        var prev_y = y;
        var prev_m = m - 1;
        if (prev_m < 1) {
            prev_m = 12;
            prev_y -= 1;
        }
        const prev_ndays = daysInMonth(prev_y, prev_m);
        return .{ .y = prev_y, .m = prev_m, .d = prev_ndays + new_d };
    }
    // Next month.
    var next_y = y;
    var next_m = m + 1;
    if (next_m > 12) {
        next_m = 1;
        next_y += 1;
    }
    return .{ .y = next_y, .m = next_m, .d = new_d - daysInMonth(y, m) };
}

fn calMonthdayscalendarFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instArg(args, 0);
    if (args.len < 3) return error.TypeError;
    const y = try intArg(args[1]);
    const m = try intArg(args[2]);
    if (m < 1 or m > 12) {
        try raiseIllegalMonth(interp, m);
        return error.PyException;
    }
    const fwd = instFwd(self, 0);
    return try buildMonthDaysCalendar(a, y, m, fwd);
}

fn calMonthdays2calendarFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instArg(args, 0);
    if (args.len < 3) return error.TypeError;
    const y = try intArg(args[1]);
    const m = try intArg(args[2]);
    if (m < 1 or m > 12) {
        try raiseIllegalMonth(interp, m);
        return error.PyException;
    }
    const fwd = instFwd(self, 0);
    const first = weekdayOf(y, m, 1);
    const ndays = daysInMonth(y, m);
    const days_before: i64 = @mod(first - fwd, 7);
    const days_after: i64 = @mod(7 - @mod(days_before + ndays, 7), 7);
    const total: i64 = days_before + ndays + days_after;
    const out = try List.init(a);
    var week = try List.init(a);
    var i: i64 = 0;
    while (i < total) : (i += 1) {
        const d = i - days_before + 1;
        const dv: i64 = if (d < 1 or d > ndays) 0 else d;
        const wd: i64 = @mod(fwd + i, 7);
        const t = try Tuple.fromSlice(a, &[_]Value{
            Value{ .small_int = dv },
            Value{ .small_int = wd },
        });
        try week.append(a, Value{ .tuple = t });
        if (@mod(i + 1, 7) == 0) {
            try out.append(a, Value{ .list = week });
            week = try List.init(a);
        }
    }
    return Value{ .list = out };
}

fn calYeardayscalendarFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    return yearGroupedCalendar(p, args, kw_names, kw_values, false);
}

fn calYeardays2calendarFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    return yearGroupedCalendar(p, args, kw_names, kw_values, true);
}

fn yearGroupedCalendar(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
    with_weekday: bool,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instArg(args, 0);
    if (args.len < 2) return error.TypeError;
    const y = try intArg(args[1]);
    var width: i64 = 3;
    if (args.len >= 3) width = try intArg(args[2]);
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "width")) width = try intArg(kv);
    }
    if (width < 1) width = 1;
    const fwd = instFwd(self, 0);
    const out = try List.init(a);
    var month: i64 = 1;
    while (month <= 12) {
        const row = try List.init(a);
        var col: i64 = 0;
        while (col < width and month <= 12) : (col += 1) {
            const mc = if (with_weekday)
                try buildMonthDays2Calendar(a, y, month, fwd)
            else
                try buildMonthDaysCalendar(a, y, month, fwd);
            try row.append(a, mc);
            month += 1;
        }
        try out.append(a, Value{ .list = row });
    }
    return Value{ .list = out };
}

fn buildMonthDays2Calendar(a: std.mem.Allocator, y: i64, m: i64, fwd: i64) !Value {
    const first = weekdayOf(y, m, 1);
    const ndays = daysInMonth(y, m);
    const days_before: i64 = @mod(first - fwd, 7);
    const days_after: i64 = @mod(7 - @mod(days_before + ndays, 7), 7);
    const total: i64 = days_before + ndays + days_after;
    const out = try List.init(a);
    var week = try List.init(a);
    var i: i64 = 0;
    while (i < total) : (i += 1) {
        const d = i - days_before + 1;
        const dv: i64 = if (d < 1 or d > ndays) 0 else d;
        const wd: i64 = @mod(fwd + i, 7);
        const t = try Tuple.fromSlice(a, &[_]Value{
            Value{ .small_int = dv },
            Value{ .small_int = wd },
        });
        try week.append(a, Value{ .tuple = t });
        if (@mod(i + 1, 7) == 0) {
            try out.append(a, Value{ .list = week });
            week = try List.init(a);
        }
    }
    return Value{ .list = out };
}

// ---- Text formatting ----

fn formatDayCell(buf: *std.ArrayList(u8), a: std.mem.Allocator, day: i64, w: i64) !void {
    const width: usize = @intCast(@max(w, 0));
    if (day == 0) {
        try buf.appendNTimes(a, ' ', width);
        return;
    }
    const u: u64 = @intCast(day);
    const s = try std.fmt.allocPrint(a, "{d}", .{u});
    defer a.free(s);
    if (s.len < width) try buf.appendNTimes(a, ' ', width - s.len);
    try buf.appendSlice(a, s);
}

fn appendCenter(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8, width: usize) !void {
    if (s.len >= width) {
        try buf.appendSlice(a, s);
        return;
    }
    const pad = width - s.len;
    const left = pad / 2;
    const right = pad - left;
    try buf.appendNTimes(a, ' ', left);
    try buf.appendSlice(a, s);
    try buf.appendNTimes(a, ' ', right);
}

fn formatMonthText(interp: *Interp, y: i64, m: i64, w: i64, l: i64) !Value {
    const a = interp.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    const ww: usize = @intCast(@max(w, 0));
    const ll: usize = @intCast(@max(l, 0));
    const colwidth: usize = ww * 7 + 6;

    // Title.
    const title = try std.fmt.allocPrint(a, "{s} {d}", .{ month_names[@intCast(m)], y });
    defer a.free(title);
    try appendCenter(&buf, a, title, colwidth);
    // rstrip to drop trailing spaces (CPython does this on the title line).
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
        _ = buf.pop();
    }
    try buf.append(a, '\n');
    var k: usize = 1;
    while (k < ll) : (k += 1) try buf.append(a, '\n');

    // Header.
    const hv = try makeWeekheader(a, w, interp.calendar_first_weekday);
    try buf.appendSlice(a, hv.str.bytes);
    try buf.append(a, '\n');
    k = 1;
    while (k < ll) : (k += 1) try buf.append(a, '\n');

    // Weeks.
    const weeks_v = try buildMonthDaysCalendar(a, y, m, interp.calendar_first_weekday);
    const weeks = weeks_v.list.items.items;
    for (weeks) |week_v| {
        const week = week_v.list.items.items;
        for (week, 0..) |dv, i| {
            if (i > 0) try buf.append(a, ' ');
            const day_int: i64 = if (dv == .small_int) dv.small_int else 0;
            try formatDayCell(&buf, a, day_int, w);
        }
        // rstrip the line.
        while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
            _ = buf.pop();
        }
        try buf.append(a, '\n');
        k = 1;
        while (k < ll) : (k += 1) try buf.append(a, '\n');
    }

    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn formatYearText(interp: *Interp, y: i64, w: i64, l: i64, c: i64, m: i64) !Value {
    const a = interp.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    const ww: usize = @intCast(@max(w, 0));
    const ll: usize = @intCast(@max(l, 0));
    const cc: usize = @intCast(@max(c, 0));
    const mm: usize = @intCast(@max(m, 1));
    const colwidth: usize = ww * 7 + 6;
    const totalwidth: usize = colwidth * mm + cc * (mm - 1);

    // Title (year).
    const ystr = try std.fmt.allocPrint(a, "{d}", .{y});
    defer a.free(ystr);
    try appendCenter(&buf, a, ystr, totalwidth);
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
        _ = buf.pop();
    }
    try buf.append(a, '\n');
    var k: usize = 0;
    while (k < ll) : (k += 1) try buf.append(a, '\n');

    var month: i64 = 1;
    while (month <= 12) {
        const months_in_row: i64 = @min(@as(i64, @intCast(mm)), 13 - month);

        // Month name row.
        var col: i64 = 0;
        while (col < months_in_row) : (col += 1) {
            if (col > 0) try buf.appendNTimes(a, ' ', cc);
            const title = try std.fmt.allocPrint(a, "{s} {d}", .{ month_names[@intCast(month + col)], y });
            defer a.free(title);
            try appendCenter(&buf, a, title, colwidth);
        }
        while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
            _ = buf.pop();
        }
        try buf.append(a, '\n');
        k = 1;
        while (k < ll) : (k += 1) try buf.append(a, '\n');

        // Header row.
        col = 0;
        while (col < months_in_row) : (col += 1) {
            if (col > 0) try buf.appendNTimes(a, ' ', cc);
            const hv = try makeWeekheader(a, w, interp.calendar_first_weekday);
            try buf.appendSlice(a, hv.str.bytes);
        }
        while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
            _ = buf.pop();
        }
        try buf.append(a, '\n');
        k = 1;
        while (k < ll) : (k += 1) try buf.append(a, '\n');

        // Build week-rows for each month in row, then zip.
        var month_weeks: [12][]const Value = undefined;
        var nweeks: usize = 0;
        col = 0;
        while (col < months_in_row) : (col += 1) {
            const mc = try buildMonthDaysCalendar(a, y, month + col, interp.calendar_first_weekday);
            month_weeks[@intCast(col)] = mc.list.items.items;
            if (mc.list.items.items.len > nweeks) nweeks = mc.list.items.items.len;
        }
        var wi: usize = 0;
        while (wi < nweeks) : (wi += 1) {
            col = 0;
            while (col < months_in_row) : (col += 1) {
                if (col > 0) try buf.appendNTimes(a, ' ', cc);
                const mw = month_weeks[@intCast(col)];
                if (wi < mw.len) {
                    const week = mw[wi].list.items.items;
                    for (week, 0..) |dv, i| {
                        if (i > 0) try buf.append(a, ' ');
                        const day_int: i64 = if (dv == .small_int) dv.small_int else 0;
                        try formatDayCell(&buf, a, day_int, w);
                    }
                } else {
                    try buf.appendNTimes(a, ' ', colwidth);
                }
            }
            while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
                _ = buf.pop();
            }
            try buf.append(a, '\n');
            k = 1;
            while (k < ll) : (k += 1) try buf.append(a, '\n');
        }
        month += months_in_row;
    }

    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

// ---- TextCalendar bound methods ----

fn tcFormatmonthFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = try instArg(args, 0);
    if (args.len < 3) return error.TypeError;
    const y = try intArg(args[1]);
    const m = try intArg(args[2]);
    var w: i64 = 0;
    var l: i64 = 0;
    if (args.len >= 4) w = try intArg(args[3]);
    if (args.len >= 5) l = try intArg(args[4]);
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "w")) w = try intArg(kv);
        if (std.mem.eql(u8, kn.str.bytes, "l")) l = try intArg(kv);
    }
    if (w < 2) w = 2;
    if (l < 1) l = 1;
    if (m < 1 or m > 12) {
        try raiseIllegalMonth(interp, m);
        return error.PyException;
    }
    return try formatMonthText(interp, y, m, w, l);
}

fn tcFormatweekheaderFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = try instArg(args, 0);
    if (args.len < 2) return error.TypeError;
    const w = try intArg(args[1]);
    return try makeWeekheader(interp.allocator, w, interp.calendar_first_weekday);
}

fn tcFormatyearFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = try instArg(args, 0);
    if (args.len < 2) return error.TypeError;
    const y = try intArg(args[1]);
    var w: i64 = 2;
    var l: i64 = 1;
    var c: i64 = 6;
    var m: i64 = 3;
    if (args.len >= 3) w = try intArg(args[2]);
    if (args.len >= 4) l = try intArg(args[3]);
    if (args.len >= 5) c = try intArg(args[4]);
    if (args.len >= 6) m = try intArg(args[5]);
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "w")) w = try intArg(kv);
        if (std.mem.eql(u8, kn.str.bytes, "l")) l = try intArg(kv);
        if (std.mem.eql(u8, kn.str.bytes, "c")) c = try intArg(kv);
        if (std.mem.eql(u8, kn.str.bytes, "m")) m = try intArg(kv);
    }
    return try formatYearText(interp, y, w, l, c, m);
}

fn tcPrmonthFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    return tcFormatmonthFn(p, args, kw_names, kw_values);
}

fn tcPryearFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    return tcFormatyearFn(p, args, kw_names, kw_values);
}

fn tcFormatmonthnameFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = try instArg(args, 0);
    if (args.len < 4) return error.TypeError;
    const y = try intArg(args[1]);
    const m = try intArg(args[2]);
    const width = try intArg(args[3]);
    var withyear = true;
    if (args.len >= 5 and args[4] == .boolean) withyear = args[4].boolean;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    const title = if (withyear)
        try std.fmt.allocPrint(a, "{s} {d}", .{ month_names[@intCast(m)], y })
    else
        try a.dupe(u8, month_names[@intCast(m)]);
    defer a.free(title);
    try appendCenter(&buf, a, title, @intCast(@max(width, 0)));
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn tcFormatdayFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = try instArg(args, 0);
    if (args.len < 4) return error.TypeError;
    const day = try intArg(args[1]);
    _ = try intArg(args[2]); // weekday unused for text
    const width = try intArg(args[3]);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try formatDayCell(&buf, a, day, width);
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn tcFormatweekFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = try instArg(args, 0);
    if (args.len < 3) return error.TypeError;
    const items: []const Value = switch (args[1]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    const width = try intArg(args[2]);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    for (items, 0..) |it, i| {
        if (i > 0) try buf.append(a, ' ');
        const items_inner: []const Value = switch (it) {
            .tuple => |t| t.items,
            .small_int => &[_]Value{it},
            else => &.{},
        };
        const day_v: i64 = if (items_inner.len > 0) (if (items_inner[0] == .small_int) items_inner[0].small_int else 0) else 0;
        try formatDayCell(&buf, a, day_v, width);
    }
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

// ---- HTMLCalendar bound methods ----

fn appendStr(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.appendSlice(a, s);
}

fn appendFmt(buf: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(s);
    try buf.appendSlice(a, s);
}

const css_classes = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };

fn hcFormatmonthFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = try instArg(args, 0);
    if (args.len < 3) return error.TypeError;
    const y = try intArg(args[1]);
    const m = try intArg(args[2]);
    var withyear = true;
    if (args.len >= 4 and args[3] == .boolean) withyear = args[3].boolean;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "withyear") and kv == .boolean) withyear = kv.boolean;
    }
    if (m < 1 or m > 12) {
        try raiseIllegalMonth(interp, m);
        return error.PyException;
    }
    return try buildHtmlMonth(interp, y, m, withyear);
}

fn buildHtmlMonth(interp: *Interp, y: i64, m: i64, withyear: bool) !Value {
    const a = interp.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);

    try appendStr(&buf, a, "<table border=\"0\" cellpadding=\"0\" cellspacing=\"0\" class=\"month\">\n");
    // Caption.
    if (withyear) {
        try appendFmt(&buf, a, "<tr><th colspan=\"7\" class=\"month\">{s} {d}</th></tr>\n", .{ month_names[@intCast(m)], y });
    } else {
        try appendFmt(&buf, a, "<tr><th colspan=\"7\" class=\"month\">{s}</th></tr>\n", .{month_names[@intCast(m)]});
    }
    // Weekday header.
    try appendStr(&buf, a, "<tr>");
    var i: i64 = 0;
    const fwd = interp.calendar_first_weekday;
    while (i < 7) : (i += 1) {
        const idx: usize = @intCast(@mod(fwd + i, 7));
        try appendFmt(&buf, a, "<th class=\"{s}\">{s}</th>", .{ css_classes[idx], day_abbrs[idx] });
    }
    try appendStr(&buf, a, "</tr>\n");

    const weeks_v = try buildMonthDays2Calendar(a, y, m, fwd);
    for (weeks_v.list.items.items) |week_v| {
        try appendStr(&buf, a, "<tr>");
        const week = week_v.list.items.items;
        for (week) |t_v| {
            const t = t_v.tuple.items;
            const day = if (t[0] == .small_int) t[0].small_int else 0;
            const wd = if (t[1] == .small_int) t[1].small_int else 0;
            const wd_idx: usize = @intCast(@mod(wd, 7));
            if (day == 0) {
                try appendStr(&buf, a, "<td class=\"noday\">&nbsp;</td>");
            } else {
                try appendFmt(&buf, a, "<td class=\"{s}\">{d}</td>", .{ css_classes[wd_idx], day });
            }
        }
        try appendStr(&buf, a, "</tr>\n");
    }
    try appendStr(&buf, a, "</table>\n");
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn hcFormatyearFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = try instArg(args, 0);
    if (args.len < 2) return error.TypeError;
    const y = try intArg(args[1]);
    var width: i64 = 3;
    if (args.len >= 3) width = try intArg(args[2]);
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "width")) width = try intArg(kv);
    }
    if (width < 1) width = 1;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try appendFmt(&buf, a, "<table border=\"0\" cellpadding=\"0\" cellspacing=\"0\" class=\"year\">\n", .{});
    try appendFmt(&buf, a, "<tr><th colspan=\"{d}\" class=\"year\">{d}</th></tr>\n", .{ width, y });
    var month: i64 = 1;
    while (month <= 12) {
        const left = @min(width, 13 - month);
        try appendStr(&buf, a, "<tr>");
        var c: i64 = 0;
        while (c < left) : (c += 1) {
            try appendStr(&buf, a, "<td>");
            const inner = try buildHtmlMonth(interp, y, month + c, false);
            try appendStr(&buf, a, inner.str.bytes);
            try appendStr(&buf, a, "</td>");
        }
        try appendStr(&buf, a, "</tr>\n");
        month += left;
    }
    try appendStr(&buf, a, "</table>\n");
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn hcFormatyearpageFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = try instArg(args, 0);
    if (args.len < 2) return error.TypeError;
    const y = try intArg(args[1]);
    var css: ?[]const u8 = "calendar.css";
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "css")) {
            if (kv == .none) css = null else if (kv == .str) css = kv.str.bytes;
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try appendStr(&buf, a, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    try appendStr(&buf, a, "<!DOCTYPE html>\n<html>\n<head>\n");
    try appendFmt(&buf, a, "<meta charset=\"utf-8\"/>\n<title>Calendar for {d}</title>\n", .{y});
    if (css) |c| try appendFmt(&buf, a, "<link rel=\"stylesheet\" type=\"text/css\" href=\"{s}\"/>\n", .{c});
    try appendStr(&buf, a, "</head>\n<body>\n");
    const inner = try hcFormatyearFn(p, args, kw_names, kw_values);
    try appendStr(&buf, a, inner.str.bytes);
    try appendStr(&buf, a, "</body>\n</html>\n");
    return Value{ .bytes = try @import("../object/bytes.zig").Bytes.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn hcFormatdayFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = try instArg(args, 0);
    if (args.len < 3) return error.TypeError;
    const day = try intArg(args[1]);
    const wd = try intArg(args[2]);
    const wd_idx: usize = @intCast(@mod(wd, 7));
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    if (day == 0) {
        try appendStr(&buf, a, "<td class=\"noday\">&nbsp;</td>");
    } else {
        try appendFmt(&buf, a, "<td class=\"{s}\">{d}</td>", .{ css_classes[wd_idx], day });
    }
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn hcFormatweekFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = try instArg(args, 0);
    if (args.len < 2) return error.TypeError;
    const items: []const Value = switch (args[1]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try appendStr(&buf, a, "<tr>");
    for (items) |it| {
        const inner = it.tuple.items;
        const day = if (inner[0] == .small_int) inner[0].small_int else 0;
        const wd = if (inner[1] == .small_int) inner[1].small_int else 0;
        const wd_idx: usize = @intCast(@mod(wd, 7));
        if (day == 0) {
            try appendStr(&buf, a, "<td class=\"noday\">&nbsp;</td>");
        } else {
            try appendFmt(&buf, a, "<td class=\"{s}\">{d}</td>", .{ css_classes[wd_idx], day });
        }
    }
    try appendStr(&buf, a, "</tr>");
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn hcFormatweekdayFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = try instArg(args, 0);
    if (args.len < 2) return error.TypeError;
    const wd = try intArg(args[1]);
    const idx: usize = @intCast(@mod(wd, 7));
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try appendFmt(&buf, a, "<th class=\"{s}\">{s}</th>", .{ css_classes[idx], day_abbrs[idx] });
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn hcFormatweekheaderFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = try instArg(args, 0);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try appendStr(&buf, a, "<tr>");
    var i: i64 = 0;
    const fwd = interp.calendar_first_weekday;
    while (i < 7) : (i += 1) {
        const idx: usize = @intCast(@mod(fwd + i, 7));
        try appendFmt(&buf, a, "<th class=\"{s}\">{s}</th>", .{ css_classes[idx], day_abbrs[idx] });
    }
    try appendStr(&buf, a, "</tr>");
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

fn hcFormatmonthnameFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = try instArg(args, 0);
    if (args.len < 3) return error.TypeError;
    const y = try intArg(args[1]);
    const m = try intArg(args[2]);
    var withyear = true;
    if (args.len >= 4 and args[3] == .boolean) withyear = args[3].boolean;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    if (withyear) {
        try appendFmt(&buf, a, "<tr><th colspan=\"7\" class=\"month\">{s} {d}</th></tr>", .{ month_names[@intCast(m)], y });
    } else {
        try appendFmt(&buf, a, "<tr><th colspan=\"7\" class=\"month\">{s}</th></tr>", .{month_names[@intCast(m)]});
    }
    return Value{ .str = try Str.fromOwnedSlice(a, try buf.toOwnedSlice(a)) };
}

// ---- Day/Month enum repr ----

fn enumReprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const cls_name = self.cls.name;
    const name = if (self.dict.getStr("name")) |n| (if (n == .str) n.str.bytes else "?") else "?";
    const value = if (self.dict.getStr("value")) |v| (if (v == .small_int) v.small_int else 0) else 0;
    const s = try std.fmt.allocPrint(a, "<{s}.{s}: {d}>", .{ cls_name, name, value });
    return Value{ .str = try Str.fromOwnedSlice(a, s) };
}
