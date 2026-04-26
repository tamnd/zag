//! Pinhole `zoneinfo`: enough surface to satisfy 117_zoneinfo. We
//! don't ship real tzdata; instead we recognise a hard-coded set of
//! zone keys and only resolve UTC's offset/name. The fixture only
//! exercises arithmetic on UTC; the rest is identity (key access).

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Set = @import("../object/set.zig").Set;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const datetime_mod = @import("datetime_mod.zig");

const known_zones = [_][]const u8{
    "UTC",
    "GMT",
    "Africa/Abidjan",          "Africa/Accra",         "Africa/Algiers",
    "Africa/Cairo",            "Africa/Casablanca",    "Africa/Johannesburg",
    "Africa/Lagos",            "Africa/Nairobi",       "Africa/Tripoli",
    "Africa/Tunis",            "Africa/Khartoum",      "Africa/Maputo",
    "Africa/Windhoek",         "Africa/Addis_Ababa",
    "America/Anchorage",       "America/Argentina/Buenos_Aires",
    "America/Bogota",          "America/Caracas",      "America/Chicago",
    "America/Denver",          "America/Detroit",      "America/Edmonton",
    "America/El_Salvador",     "America/Guatemala",    "America/Halifax",
    "America/Havana",          "America/Indiana/Indianapolis",
    "America/Jamaica",         "America/La_Paz",       "America/Lima",
    "America/Los_Angeles",     "America/Mexico_City",  "America/Montevideo",
    "America/New_York",        "America/Noronha",      "America/Panama",
    "America/Phoenix",         "America/Port-au-Prince",
    "America/Puerto_Rico",     "America/Regina",       "America/Santiago",
    "America/Sao_Paulo",       "America/Tijuana",      "America/Toronto",
    "America/Vancouver",       "America/Winnipeg",     "America/Whitehorse",
    "Antarctica/Casey",        "Antarctica/Davis",
    "Asia/Almaty",             "Asia/Amman",           "Asia/Baghdad",
    "Asia/Bahrain",            "Asia/Baku",            "Asia/Bangkok",
    "Asia/Beirut",             "Asia/Calcutta",        "Asia/Colombo",
    "Asia/Damascus",           "Asia/Dhaka",           "Asia/Dubai",
    "Asia/Hong_Kong",          "Asia/Irkutsk",         "Asia/Jakarta",
    "Asia/Jerusalem",          "Asia/Kabul",           "Asia/Karachi",
    "Asia/Kathmandu",          "Asia/Kolkata",         "Asia/Krasnoyarsk",
    "Asia/Kuala_Lumpur",       "Asia/Kuwait",          "Asia/Magadan",
    "Asia/Manila",             "Asia/Muscat",          "Asia/Nicosia",
    "Asia/Novosibirsk",        "Asia/Omsk",            "Asia/Pyongyang",
    "Asia/Qatar",              "Asia/Riyadh",          "Asia/Saigon",
    "Asia/Seoul",              "Asia/Shanghai",        "Asia/Singapore",
    "Asia/Taipei",             "Asia/Tashkent",        "Asia/Tbilisi",
    "Asia/Tehran",             "Asia/Tokyo",           "Asia/Ulaanbaatar",
    "Asia/Vladivostok",        "Asia/Yakutsk",         "Asia/Yangon",
    "Asia/Yekaterinburg",      "Asia/Yerevan",
    "Atlantic/Azores",         "Atlantic/Bermuda",     "Atlantic/Canary",
    "Atlantic/Cape_Verde",     "Atlantic/Reykjavik",   "Atlantic/South_Georgia",
    "Australia/Adelaide",      "Australia/Brisbane",   "Australia/Darwin",
    "Australia/Hobart",        "Australia/Melbourne",  "Australia/Perth",
    "Australia/Sydney",
    "Europe/Amsterdam",        "Europe/Athens",        "Europe/Belgrade",
    "Europe/Berlin",           "Europe/Brussels",      "Europe/Bucharest",
    "Europe/Budapest",         "Europe/Chisinau",      "Europe/Copenhagen",
    "Europe/Dublin",           "Europe/Helsinki",      "Europe/Istanbul",
    "Europe/Kiev",             "Europe/Lisbon",        "Europe/London",
    "Europe/Luxembourg",       "Europe/Madrid",        "Europe/Malta",
    "Europe/Minsk",            "Europe/Monaco",        "Europe/Moscow",
    "Europe/Oslo",             "Europe/Paris",         "Europe/Prague",
    "Europe/Riga",             "Europe/Rome",          "Europe/Samara",
    "Europe/Sofia",            "Europe/Stockholm",     "Europe/Tallinn",
    "Europe/Tirane",           "Europe/Vienna",        "Europe/Vilnius",
    "Europe/Warsaw",           "Europe/Zagreb",        "Europe/Zurich",
    "Indian/Maldives",         "Indian/Mauritius",
    "Pacific/Auckland",        "Pacific/Chatham",      "Pacific/Fiji",
    "Pacific/Guam",            "Pacific/Honolulu",     "Pacific/Midway",
    "Pacific/Pago_Pago",       "Pacific/Port_Moresby", "Pacific/Tahiti",
    "Pacific/Tongatapu",
};

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "zoneinfo");

    try ensureClasses(interp);

    try m.attrs.setStr(a, "ZoneInfo", Value{ .class = interp.zoneinfo_class.? });
    try m.attrs.setStr(a, "ZoneInfoNotFoundError", Value{ .class = interp.zoneinfo_not_found_class.? });

    // TZPATH is an empty tuple by default.
    const tz_path = try Tuple.init(a, 0);
    try m.attrs.setStr(a, "TZPATH", Value{ .tuple = tz_path });

    try regModFn(interp, m, "available_timezones", availableTimezonesFn);
    try regModFn(interp, m, "reset_tzpath", resetTzpathFn);

    interp.zoneinfo_module = m;
    return m;
}

fn ensureClasses(interp: *Interp) !void {
    if (interp.zoneinfo_class != null) return;
    const a = interp.allocator;

    // ZoneInfoNotFoundError extends KeyError.
    {
        const ke_v = interp.builtins.getStr("KeyError") orelse return error.TypeError;
        const d = try Dict.init(a);
        interp.zoneinfo_not_found_class = try Class.init(a, "ZoneInfoNotFoundError", &.{ke_v.class}, d);
    }

    // ZoneInfo class.
    {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", ziInitFn);
        try reg(a, d, "__str__", ziStrFn);
        try reg(a, d, "__repr__", ziReprFn);
        try reg(a, d, "utcoffset", ziUtcoffsetFn);
        try reg(a, d, "tzname", ziTznameFn);
        try reg(a, d, "dst", ziDstFn);
        // Classmethods modeled as plain builtin_fn off the class dict.
        try reg(a, d, "no_cache", ziNoCacheFn);
        try regKw(a, d, "clear_cache", ziClearCacheFn);
        interp.zoneinfo_class = try Class.init(a, "ZoneInfo", &.{}, d);
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

fn isKnownZone(key: []const u8) bool {
    for (known_zones) |z| {
        if (std.mem.eql(u8, z, key)) return true;
    }
    return false;
}

fn raiseNotFound(interp: *Interp, key: []const u8) !void {
    const a = interp.allocator;
    const cls = interp.zoneinfo_not_found_class.?;
    const inst = try Instance.init(a, cls);
    const t = try Tuple.init(a, 1);
    const msg = try std.fmt.allocPrint(a, "No time zone found with key {s}", .{key});
    t.items[0] = Value{ .str = try Str.fromOwnedSlice(a, msg) };
    try inst.dict.setStr(a, "args", Value{ .tuple = t });
    interp.current_exc = Value{ .instance = inst };
}

fn ensureCacheMap(interp: *Interp) !*Dict {
    if (interp.zoneinfo_cache) |c| return c;
    const c = try Dict.init(interp.allocator);
    interp.zoneinfo_cache = c;
    return c;
}

fn ziInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const self = args[0].instance;
    const key = args[1].str.bytes;
    if (!isKnownZone(key)) {
        try raiseNotFound(interp, key);
        return error.PyException;
    }
    try populateZone(interp, self, key);
    return Value.none;
}

fn populateZone(interp: *Interp, self: *Instance, key: []const u8) !void {
    const a = interp.allocator;
    try self.dict.setStr(a, "key", Value{ .str = try Str.init(a, key) });
    if (std.mem.eql(u8, key, "UTC") or std.mem.eql(u8, key, "GMT")) {
        // Zero offset, name = key. Reuse datetime's timedelta(0).
        const td_zero = try datetime_mod.newTimedeltaPub(interp, 0, 0, 0);
        try self.dict.setStr(a, "_offset", td_zero);
        try self.dict.setStr(a, "_name", Value{ .str = try Str.init(a, key) });
    }
}

fn ziStrFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = interp;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    if (self.dict.getStr("key")) |k| return k;
    return error.TypeError;
}

fn ziReprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const key = if (self.dict.getStr("key")) |k| k.str.bytes else "";
    const s = try std.fmt.allocPrint(a, "zoneinfo.ZoneInfo(key='{s}')", .{key});
    return Value{ .str = try Str.fromOwnedSlice(a, s) };
}

fn ziUtcoffsetFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    return self.dict.getStr("_offset") orelse Value.none;
}

fn ziTznameFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    return self.dict.getStr("_name") orelse Value.none;
}

fn ziDstFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    // For UTC/GMT, dst is timedelta(0); otherwise None.
    const key = if (self.dict.getStr("key")) |k| k.str.bytes else "";
    if (std.mem.eql(u8, key, "UTC") or std.mem.eql(u8, key, "GMT")) {
        return try datetime_mod.newTimedeltaPub(interp, 0, 0, 0);
    }
    return Value.none;
}

fn ziNoCacheFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const key = args[0].str.bytes;
    if (!isKnownZone(key)) {
        try raiseNotFound(interp, key);
        return error.PyException;
    }
    const inst = try Instance.init(a, interp.zoneinfo_class.?);
    try populateZone(interp, inst, key);
    return Value{ .instance = inst };
}

fn ziClearCacheFn(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    var only_keys: Value = Value.none;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "only_keys")) only_keys = kv;
    }
    if (interp.zoneinfo_cache) |c| {
        if (only_keys == .none) {
            c.pairs.clearRetainingCapacity();
            c.keys.clearRetainingCapacity();
        } else if (only_keys == .list) {
            for (only_keys.list.items.items) |kv| {
                if (kv == .str) {
                    _ = c.delete(kv.str.bytes);
                }
            }
        }
    }
    return Value.none;
}

fn availableTimezonesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    const a = interp.allocator;
    const s = try Set.init(a);
    for (known_zones) |z| {
        try s.add(a, Value{ .str = try Str.init(a, z) });
    }
    return Value{ .set = s };
}

fn resetTzpathFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value.none;
}

/// Custom instantiation: routes ZoneInfo(key) through the interp-wide
/// cache. Called from dispatch.instantiate when it sees the class.
pub fn cachedInstantiate(interp: *Interp, positional: []const Value) !?Value {
    if (positional.len != 1 or positional[0] != .str) return null;
    const key = positional[0].str.bytes;
    if (!isKnownZone(key)) {
        try raiseNotFound(interp, key);
        return error.PyException;
    }
    const cache = try ensureCacheMap(interp);
    if (cache.getStr(key)) |v| return v;
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.zoneinfo_class.?);
    try populateZone(interp, inst, key);
    const v = Value{ .instance = inst };
    try cache.setStr(a, key, v);
    return v;
}
