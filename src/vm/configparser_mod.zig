//! Pinhole `configparser`. Implements ConfigParser and RawConfigParser.
//! State is kept in a heap-allocated ConfigState struct; a pointer is
//! stored in the instance dict under "__state" as a small_int.

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
const Bytes = @import("../object/bytes.zig").Bytes;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

// ===== low-level data structures =====

const Section = struct {
    name: []u8,
    keys: std.ArrayListUnmanaged([]u8) = .empty,
    vals: std.ArrayListUnmanaged([]u8) = .empty,

    fn get(self: *Section, key: []const u8) ?[]const u8 {
        for (self.keys.items, self.vals.items) |k, v| {
            if (std.mem.eql(u8, k, key)) return v;
        }
        return null;
    }

    fn set(self: *Section, a: std.mem.Allocator, key: []const u8, val: []const u8) !void {
        for (self.keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                a.free(self.vals.items[i]);
                self.vals.items[i] = try a.dupe(u8, val);
                return;
            }
        }
        try self.keys.append(a, try a.dupe(u8, key));
        try self.vals.append(a, try a.dupe(u8, val));
    }

    fn remove(self: *Section, a: std.mem.Allocator, key: []const u8) bool {
        for (self.keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                a.free(self.keys.orderedRemove(i));
                a.free(self.vals.orderedRemove(i));
                return true;
            }
        }
        return false;
    }

    fn deinit(self: *Section, a: std.mem.Allocator) void {
        a.free(self.name);
        for (self.keys.items) |k| a.free(k);
        for (self.vals.items) |v| a.free(v);
        self.keys.deinit(a);
        self.vals.deinit(a);
    }
};

const ConfigState = struct {
    a: std.mem.Allocator,
    sections: std.ArrayListUnmanaged(*Section) = .empty,
    def_keys: std.ArrayListUnmanaged([]u8) = .empty,
    def_vals: std.ArrayListUnmanaged([]u8) = .empty,
    raw: bool,

    fn create(a: std.mem.Allocator, raw: bool) !*ConfigState {
        const self = try a.create(ConfigState);
        self.* = .{ .a = a, .raw = raw };
        return self;
    }

    fn getSection(self: *ConfigState, name: []const u8) ?*Section {
        for (self.sections.items) |sec| {
            if (std.mem.eql(u8, sec.name, name)) return sec;
        }
        return null;
    }

    fn getDefault(self: *ConfigState, key: []const u8) ?[]const u8 {
        for (self.def_keys.items, self.def_vals.items) |k, v| {
            if (std.mem.eql(u8, k, key)) return v;
        }
        return null;
    }

    fn setDefault(self: *ConfigState, key: []const u8, val: []const u8) !void {
        for (self.def_keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                self.a.free(self.def_vals.items[i]);
                self.def_vals.items[i] = try self.a.dupe(u8, val);
                return;
            }
        }
        try self.def_keys.append(self.a, try self.a.dupe(u8, key));
        try self.def_vals.append(self.a, try self.a.dupe(u8, val));
    }

    fn getValue(self: *ConfigState, section: []const u8, key: []const u8) ?[]const u8 {
        if (self.getSection(section)) |sec| {
            if (sec.get(key)) |v| return v;
        }
        return self.getDefault(key);
    }

    fn addSection(self: *ConfigState, name: []const u8) !bool {
        if (self.getSection(name) != null) return false;
        const sec = try self.a.create(Section);
        sec.* = .{ .name = try self.a.dupe(u8, name) };
        try self.sections.append(self.a, sec);
        return true;
    }

    fn removeSection(self: *ConfigState, name: []const u8) bool {
        for (self.sections.items, 0..) |sec, i| {
            if (std.mem.eql(u8, sec.name, name)) {
                sec.deinit(self.a);
                self.a.destroy(sec);
                _ = self.sections.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    fn parse(self: *ConfigState, text: []const u8) !void {
        var cur_sec: ?*Section = null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
            if (line[0] == '[') {
                const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
                const sec_name = std.mem.trim(u8, line[1..end], " \t");
                if (std.ascii.eqlIgnoreCase(sec_name, "DEFAULT")) {
                    cur_sec = null;
                } else {
                    cur_sec = self.getSection(sec_name);
                    if (cur_sec == null) {
                        const sec = try self.a.create(Section);
                        sec.* = .{ .name = try self.a.dupe(u8, sec_name) };
                        try self.sections.append(self.a, sec);
                        cur_sec = sec;
                    }
                }
                continue;
            }
            const eq = std.mem.indexOfAny(u8, line, "=:") orelse continue;
            const key_raw = std.mem.trimEnd(u8, line[0..eq], " \t");
            const val = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
            const lkey = try self.a.dupe(u8, key_raw);
            defer self.a.free(lkey);
            for (lkey) |*c| c.* = std.ascii.toLower(c.*);
            if (cur_sec) |sec| {
                try sec.set(self.a, lkey, val);
            } else {
                try self.setDefault(lkey, val);
            }
        }
    }

    fn deinit(self: *ConfigState) void {
        for (self.sections.items) |sec| {
            sec.deinit(self.a);
            self.a.destroy(sec);
        }
        self.sections.deinit(self.a);
        for (self.def_keys.items) |k| self.a.free(k);
        for (self.def_vals.items) |v| self.a.free(v);
        self.def_keys.deinit(self.a);
        self.def_vals.deinit(self.a);
        self.a.destroy(self);
    }
};

// ===== helpers =====

fn stateFromInst(inst: *Instance) *ConfigState {
    const v = inst.dict.getStr("__state").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn raiseNoSection(interp: *Interp, name: []const u8) !void {
    const a = interp.allocator;
    const msg = try std.fmt.allocPrint(a, "No section: '{s}'", .{name});
    defer a.free(msg);
    if (interp.configparser_no_section_class) |cls| {
        const inst = try Instance.init(a, cls);
        const t = try Tuple.init(a, 1);
        t.items[0] = Value{ .str = try Str.init(a, name) };
        try inst.dict.setStr(a, "args", Value{ .tuple = t });
        try inst.dict.setStr(a, "message", Value{ .str = try Str.init(a, msg) });
        interp.current_exc = Value{ .instance = inst };
    } else {
        try interp.raisePy("KeyError", msg);
    }
}

fn raiseNoOption(interp: *Interp, section: []const u8, key: []const u8) !void {
    const a = interp.allocator;
    const msg = try std.fmt.allocPrint(a, "No option '{s}' in section: '{s}'", .{ key, section });
    defer a.free(msg);
    if (interp.configparser_no_option_class) |cls| {
        const inst = try Instance.init(a, cls);
        const t = try Tuple.init(a, 2);
        t.items[0] = Value{ .str = try Str.init(a, key) };
        t.items[1] = Value{ .str = try Str.init(a, section) };
        try inst.dict.setStr(a, "args", Value{ .tuple = t });
        try inst.dict.setStr(a, "message", Value{ .str = try Str.init(a, msg) });
        interp.current_exc = Value{ .instance = inst };
    } else {
        try interp.raisePy("KeyError", msg);
    }
}

fn raiseDupSection(interp: *Interp, name: []const u8) !void {
    const a = interp.allocator;
    const msg = try std.fmt.allocPrint(a, "Section '{s}' already exists", .{name});
    defer a.free(msg);
    if (interp.configparser_dup_section_class) |cls| {
        const inst = try Instance.init(a, cls);
        const t = try Tuple.init(a, 1);
        t.items[0] = Value{ .str = try Str.init(a, name) };
        try inst.dict.setStr(a, "args", Value{ .tuple = t });
        try inst.dict.setStr(a, "message", Value{ .str = try Str.init(a, msg) });
        interp.current_exc = Value{ .instance = inst };
    } else {
        try interp.raisePy("ValueError", msg);
    }
}

fn callWrite(interp: *Interp, fp: Value, text: []const u8) !void {
    const a = interp.allocator;
    const s = try Str.init(a, text);
    const attr = try dispatch.loadAttrValue(interp, fp, "write");
    _ = try dispatch.invoke(interp, attr, &.{Value{ .str = s }});
}

fn reg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regMod(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

// ===== __init__ =====

fn initFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return initImpl(p, args, &.{}, &.{});
}

fn initKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return initImpl(p, args, kn, kv);
}

fn initImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;

    const raw = inst.cls.dict.getStr("__raw__") != null;
    const state = try ConfigState.create(a, raw);
    errdefer state.deinit();

    // handle defaults= kwarg
    for (kn, kv) |name_v, val_v| {
        if (name_v != .str) continue;
        if (!std.mem.eql(u8, name_v.str.bytes, "defaults")) continue;
        if (val_v == .none) continue;
        if (val_v != .dict) continue;
        const def_dict = val_v.dict;
        for (def_dict.pairs.items) |pair| {
            if (pair.key != .str or pair.value != .str) continue;
            const lkey = try a.dupe(u8, pair.key.str.bytes);
            defer a.free(lkey);
            for (lkey) |*c| c.* = std.ascii.toLower(c.*);
            try state.setDefault(lkey, pair.value.str.bytes);
        }
    }

    try inst.dict.setStr(a, "__state", Value{ .small_int = @intCast(@intFromPtr(state)) });
    return Value.none;
}

// ===== read_string =====

fn readStringFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    try state.parse(args[1].str.bytes);
    return Value.none;
}

// ===== sections =====

fn sectionsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    const list = try List.init(a);
    for (state.sections.items) |sec| {
        try list.append(a, Value{ .str = try Str.init(a, sec.name) });
    }
    return Value{ .list = list };
}

// ===== has_section =====

fn hasSectionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    return Value{ .boolean = state.getSection(args[1].str.bytes) != null };
}

// ===== has_option =====

fn hasOptionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3 or args[0] != .instance or args[1] != .str or args[2] != .str) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    const sec_name = args[1].str.bytes;
    const key_raw = args[2].str.bytes;
    const lkey = try a.dupe(u8, key_raw);
    defer a.free(lkey);
    for (lkey) |*c| c.* = std.ascii.toLower(c.*);
    if (state.getValue(sec_name, lkey) != null) return Value{ .boolean = true };
    return Value{ .boolean = false };
}

// ===== get =====

fn getFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return getImpl(p, args, &.{}, &.{});
}

fn getKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return getImpl(p, args, kn, kv);
}

fn getImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3 or args[0] != .instance or args[1] != .str or args[2] != .str) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    const sec_name = args[1].str.bytes;
    const key_raw = args[2].str.bytes;
    const lkey = try a.dupe(u8, key_raw);
    defer a.free(lkey);
    for (lkey) |*c| c.* = std.ascii.toLower(c.*);

    var fallback: ?Value = null;
    // positional fallback
    if (args.len >= 4) fallback = args[3];
    // kwarg fallback
    for (kn, kv) |nm, vl| {
        if (nm == .str and std.mem.eql(u8, nm.str.bytes, "fallback")) {
            fallback = vl;
            break;
        }
    }

    if (state.getSection(sec_name) == null and fallback == null) {
        try raiseNoSection(interp, sec_name);
        return error.PyException;
    }

    if (state.getValue(sec_name, lkey)) |v| {
        return Value{ .str = try Str.init(a, v) };
    }
    if (fallback) |fb| return fb;
    try raiseNoOption(interp, sec_name, lkey);
    return error.PyException;
}

// ===== getint / getfloat / getboolean =====

fn getintFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const vstr = try getImpl(p, args, &.{}, &.{});
    if (vstr != .str) return vstr;
    const s = std.mem.trim(u8, vstr.str.bytes, " \t");
    const n = std.fmt.parseInt(i64, s, 10) catch {
        try interp.raisePy("ValueError", "invalid literal for int");
        return error.PyException;
    };
    return Value{ .small_int = n };
}

fn getfloatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const vstr = try getImpl(p, args, &.{}, &.{});
    if (vstr != .str) return vstr;
    const s = std.mem.trim(u8, vstr.str.bytes, " \t");
    const f = std.fmt.parseFloat(f64, s) catch {
        try interp.raisePy("ValueError", "invalid literal for float");
        return error.PyException;
    };
    return Value{ .float = f };
}

fn getbooleanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const vstr = try getImpl(p, args, &.{}, &.{});
    if (vstr != .str) return vstr;
    const s = std.mem.trim(u8, vstr.str.bytes, " \t");
    const true_vals = &[_][]const u8{ "1", "yes", "true", "on" };
    const false_vals = &[_][]const u8{ "0", "no", "false", "off" };
    for (true_vals) |tv| {
        if (std.ascii.eqlIgnoreCase(s, tv)) return Value{ .boolean = true };
    }
    for (false_vals) |fv| {
        if (std.ascii.eqlIgnoreCase(s, fv)) return Value{ .boolean = false };
    }
    try interp.raisePy("ValueError", "Not a boolean");
    return error.PyException;
}

// ===== options =====

fn optionsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    const sec_name = args[1].str.bytes;
    const sec = state.getSection(sec_name) orelse {
        try raiseNoSection(interp, sec_name);
        return error.PyException;
    };
    const list = try List.init(a);
    for (sec.keys.items) |k| {
        try list.append(a, Value{ .str = try Str.init(a, k) });
    }
    // also include defaults keys not already in section
    for (state.def_keys.items) |dk| {
        var found = false;
        for (sec.keys.items) |k| {
            if (std.mem.eql(u8, k, dk)) { found = true; break; }
        }
        if (!found) try list.append(a, Value{ .str = try Str.init(a, dk) });
    }
    return Value{ .list = list };
}

// ===== items =====

fn itemsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    const sec_name = args[1].str.bytes;
    const sec = state.getSection(sec_name) orelse {
        try raiseNoSection(interp, sec_name);
        return error.PyException;
    };
    const d = try Dict.init(a);
    for (sec.keys.items, sec.vals.items) |k, v| {
        try d.setStr(a, k, Value{ .str = try Str.init(a, v) });
    }
    return Value{ .dict = d };
}

// ===== set =====

fn setFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 4 or args[0] != .instance or args[1] != .str or args[2] != .str or args[3] != .str)
        return error.TypeError;
    const state = stateFromInst(args[0].instance);
    const sec_name = args[1].str.bytes;
    const key_raw = args[2].str.bytes;
    const val = args[3].str.bytes;
    const lkey = try a.dupe(u8, key_raw);
    defer a.free(lkey);
    for (lkey) |*c| c.* = std.ascii.toLower(c.*);
    const sec = state.getSection(sec_name) orelse {
        try raiseNoSection(interp, sec_name);
        return error.PyException;
    };
    try sec.set(a, lkey, val);
    return Value.none;
}

// ===== add_section =====

fn addSectionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    const name = args[1].str.bytes;
    const ok = try state.addSection(name);
    if (!ok) {
        try raiseDupSection(interp, name);
        return error.PyException;
    }
    return Value.none;
}

// ===== remove_option =====

fn removeOptionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3 or args[0] != .instance or args[1] != .str or args[2] != .str) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    const sec_name = args[1].str.bytes;
    const key_raw = args[2].str.bytes;
    const lkey = try a.dupe(u8, key_raw);
    defer a.free(lkey);
    for (lkey) |*c| c.* = std.ascii.toLower(c.*);
    const sec = state.getSection(sec_name) orelse {
        try raiseNoSection(interp, sec_name);
        return error.PyException;
    };
    return Value{ .boolean = sec.remove(a, lkey) };
}

// ===== remove_section =====

fn removeSectionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    return Value{ .boolean = state.removeSection(args[1].str.bytes) };
}

// ===== write =====

fn writeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    const fp = args[1];

    // Write DEFAULT section if non-empty
    if (state.def_keys.items.len > 0) {
        try callWrite(interp, fp, "[DEFAULT]\n");
        for (state.def_keys.items, state.def_vals.items) |k, v| {
            const line = try std.fmt.allocPrint(a, "{s} = {s}\n", .{ k, v });
            defer a.free(line);
            try callWrite(interp, fp, line);
        }
        try callWrite(interp, fp, "\n");
    }

    for (state.sections.items) |sec| {
        const header = try std.fmt.allocPrint(a, "[{s}]\n", .{sec.name});
        defer a.free(header);
        try callWrite(interp, fp, header);
        for (sec.keys.items, sec.vals.items) |k, v| {
            const line = try std.fmt.allocPrint(a, "{s} = {s}\n", .{ k, v });
            defer a.free(line);
            try callWrite(interp, fp, line);
        }
        try callWrite(interp, fp, "\n");
    }
    return Value.none;
}

// ===== build class =====

fn buildParserClass(interp: *Interp, name: []const u8, raw: bool) !*Class {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try regKw(a, d, "__init__", initFn, initKw);
    try reg(a, d, "read_string", readStringFn);
    try reg(a, d, "sections", sectionsFn);
    try reg(a, d, "has_section", hasSectionFn);
    try reg(a, d, "has_option", hasOptionFn);
    try regKw(a, d, "get", getFn, getKw);
    try reg(a, d, "getint", getintFn);
    try reg(a, d, "getfloat", getfloatFn);
    try reg(a, d, "getboolean", getbooleanFn);
    try reg(a, d, "options", optionsFn);
    try reg(a, d, "items", itemsFn);
    try reg(a, d, "set", setFn);
    try reg(a, d, "add_section", addSectionFn);
    try reg(a, d, "remove_option", removeOptionFn);
    try reg(a, d, "remove_section", removeSectionFn);
    try reg(a, d, "write", writeFn);

    const cls = try Class.init(a, name, &.{}, d);
    if (raw) {
        try cls.dict.setStr(a, "__raw__", Value{ .boolean = true });
    }
    return cls;
}

fn buildErrClass(interp: *Interp, class_name: []const u8) !*Class {
    const a = interp.allocator;
    const d = try Dict.init(a);
    if (interp.builtins.getStr("Exception")) |exc_v| {
        if (exc_v == .class) {
            return Class.init(a, class_name, &[_]*Class{exc_v.class}, d);
        }
    }
    return Class.init(a, class_name, &.{}, d);
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "configparser");

    // error classes
    if (interp.configparser_no_section_class == null)
        interp.configparser_no_section_class = try buildErrClass(interp, "NoSectionError");
    if (interp.configparser_no_option_class == null)
        interp.configparser_no_option_class = try buildErrClass(interp, "NoOptionError");
    if (interp.configparser_dup_section_class == null)
        interp.configparser_dup_section_class = try buildErrClass(interp, "DuplicateSectionError");

    try m.attrs.setStr(a, "NoSectionError", Value{ .class = interp.configparser_no_section_class.? });
    try m.attrs.setStr(a, "NoOptionError", Value{ .class = interp.configparser_no_option_class.? });
    try m.attrs.setStr(a, "DuplicateSectionError", Value{ .class = interp.configparser_dup_section_class.? });
    try m.attrs.setStr(a, "Error", Value{ .class = interp.configparser_no_section_class.? });

    if (interp.configparser_class == null)
        interp.configparser_class = try buildParserClass(interp, "ConfigParser", false);
    if (interp.configparser_raw_class == null)
        interp.configparser_raw_class = try buildParserClass(interp, "RawConfigParser", true);

    try m.attrs.setStr(a, "ConfigParser", Value{ .class = interp.configparser_class.? });
    try m.attrs.setStr(a, "RawConfigParser", Value{ .class = interp.configparser_raw_class.? });
    try m.attrs.setStr(a, "SafeConfigParser", Value{ .class = interp.configparser_class.? });

    return m;
}
