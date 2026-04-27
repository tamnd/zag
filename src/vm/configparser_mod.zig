//! configparser module — ConfigParser, RawConfigParser, dialects, interpolation.

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

const INTERP_NONE: u8 = 0;
const INTERP_BASIC: u8 = 1;
const INTERP_EXTENDED: u8 = 2;

// ===== low-level data structures =====

const Section = struct {
    name: []u8,
    keys: std.ArrayListUnmanaged([]u8) = .empty,
    vals: std.ArrayListUnmanaged(?[]u8) = .empty,

    fn get(self: *Section, key: []const u8) ??[]u8 {
        for (self.keys.items, self.vals.items) |k, v| {
            if (std.mem.eql(u8, k, key)) return v;
        }
        return null;
    }

    fn has(self: *Section, key: []const u8) bool {
        for (self.keys.items) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }

    fn set(self: *Section, a: std.mem.Allocator, key: []const u8, val: ?[]const u8) !void {
        for (self.keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                if (self.vals.items[i]) |old| a.free(old);
                self.vals.items[i] = if (val) |v| try a.dupe(u8, v) else null;
                return;
            }
        }
        try self.keys.append(a, try a.dupe(u8, key));
        try self.vals.append(a, if (val) |v| try a.dupe(u8, v) else null);
    }

    fn remove(self: *Section, a: std.mem.Allocator, key: []const u8) bool {
        for (self.keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                a.free(self.keys.orderedRemove(i));
                if (self.vals.orderedRemove(i)) |v| a.free(v);
                return true;
            }
        }
        return false;
    }

    fn deinit(self: *Section, a: std.mem.Allocator) void {
        a.free(self.name);
        for (self.keys.items) |k| a.free(k);
        for (self.vals.items) |v| if (v) |s| a.free(s);
        self.keys.deinit(a);
        self.vals.deinit(a);
    }
};

const ConfigState = struct {
    a: std.mem.Allocator,
    sections: std.ArrayListUnmanaged(*Section) = .empty,
    def_keys: std.ArrayListUnmanaged([]u8) = .empty,
    def_vals: std.ArrayListUnmanaged(?[]u8) = .empty,
    raw: bool = false,
    allow_no_value: bool = false,
    strict: bool = true,
    inline_comment_prefixes: ?[]const u8 = null,
    delimiters: [2]u8 = .{ '=', ':' },
    comment_prefixes: []const u8 = "#;",
    interp_type: u8 = INTERP_BASIC,

    fn create(a: std.mem.Allocator, raw: bool) !*ConfigState {
        const self = try a.create(ConfigState);
        self.* = .{ .a = a, .raw = raw };
        if (raw) self.interp_type = INTERP_NONE;
        return self;
    }

    fn getSection(self: *ConfigState, name: []const u8) ?*Section {
        for (self.sections.items) |sec| {
            if (std.mem.eql(u8, sec.name, name)) return sec;
        }
        return null;
    }

    fn getDefault(self: *ConfigState, key: []const u8) ??[]u8 {
        for (self.def_keys.items, self.def_vals.items) |k, v| {
            if (std.mem.eql(u8, k, key)) return v;
        }
        return null;
    }

    fn setDefault(self: *ConfigState, key: []const u8, val: ?[]const u8) !void {
        for (self.def_keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                if (self.def_vals.items[i]) |old| self.a.free(old);
                self.def_vals.items[i] = if (val) |v| try self.a.dupe(u8, v) else null;
                return;
            }
        }
        try self.def_keys.append(self.a, try self.a.dupe(u8, key));
        try self.def_vals.append(self.a, if (val) |v| try self.a.dupe(u8, v) else null);
    }

    fn getRaw(self: *ConfigState, section: []const u8, key: []const u8) ??[]u8 {
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
        const a = self.a;
        var cur_sec: ?*Section = null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first_line = true;
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            // Check comment prefixes
            if (line.len == 0) continue;
            var is_comment = false;
            for (self.comment_prefixes) |cp| {
                if (line[0] == cp) { is_comment = true; break; }
            }
            if (is_comment) continue;
            if (line[0] == '[') {
                const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
                const sec_name = std.mem.trim(u8, line[1..end], " \t");
                if (std.ascii.eqlIgnoreCase(sec_name, "DEFAULT")) {
                    cur_sec = null;
                } else {
                    cur_sec = self.getSection(sec_name);
                    if (cur_sec == null) {
                        const sec = try a.create(Section);
                        sec.* = .{ .name = try a.dupe(u8, sec_name) };
                        try self.sections.append(a, sec);
                        cur_sec = sec;
                    }
                }
                first_line = false;
                continue;
            }
            // Check for section header missing
            if (first_line and std.mem.indexOfAny(u8, line, "=:") != null) {
                if (self.strict) {
                    return error.MissingSectionHeader;
                }
            }
            // Find delimiter
            var eq_pos: ?usize = null;
            for (line, 0..) |c, idx| {
                if (c == self.delimiters[0] or c == self.delimiters[1]) {
                    eq_pos = idx;
                    break;
                }
            }
            if (eq_pos == null) {
                // No value — allow_no_value
                if (self.allow_no_value) {
                    const key_raw = std.mem.trim(u8, line, " \t");
                    const lkey = try a.dupe(u8, key_raw);
                    defer a.free(lkey);
                    for (lkey) |*c| c.* = std.ascii.toLower(c.*);
                    if (cur_sec) |sec| {
                        if (self.strict and sec.has(lkey)) return error.DuplicateOption;
                        try sec.set(a, lkey, null);
                    } else {
                        try self.setDefault(lkey, null);
                    }
                }
                continue;
            }
            const eq = eq_pos.?;
            const key_raw = std.mem.trimEnd(u8, line[0..eq], " \t");
            var val = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
            // Handle inline comments
            if (self.inline_comment_prefixes) |icp| {
                for (icp) |ic| {
                    if (std.mem.indexOfScalar(u8, val, ic)) |ic_pos| {
                        val = std.mem.trimEnd(u8, val[0..ic_pos], " \t");
                        break;
                    }
                }
            }
            const lkey = try a.dupe(u8, key_raw);
            defer a.free(lkey);
            for (lkey) |*c| c.* = std.ascii.toLower(c.*);
            if (cur_sec) |sec| {
                if (self.strict and sec.has(lkey)) return error.DuplicateOption;
                try sec.set(a, lkey, val);
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
        for (self.def_vals.items) |v| if (v) |s| self.a.free(s);
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

fn raiseErr(interp: *Interp, cls: ?*Class, msg: []const u8, args_vals: []const Value) !void {
    const a = interp.allocator;
    if (cls) |c| {
        const inst = try Instance.init(a, c);
        const t = try Tuple.init(a, args_vals.len);
        @memcpy(t.items, args_vals);
        try inst.dict.setStr(a, "args", Value{ .tuple = t });
        try inst.dict.setStr(a, "message", Value{ .str = try Str.init(a, msg) });
        interp.current_exc = Value{ .instance = inst };
    } else {
        try interp.raisePy("Error", msg);
    }
}

fn raiseNoSection(interp: *Interp, name: []const u8) !void {
    const msg = try std.fmt.allocPrint(interp.allocator, "No section: '{s}'", .{name});
    defer interp.allocator.free(msg);
    const nv = Value{ .str = try Str.init(interp.allocator, name) };
    try raiseErr(interp, interp.configparser_no_section_class, msg, &.{nv});
}

fn raiseNoOption(interp: *Interp, section: []const u8, key: []const u8) !void {
    const a = interp.allocator;
    const msg = try std.fmt.allocPrint(a, "No option '{s}' in section: '{s}'", .{ key, section });
    defer a.free(msg);
    const kv = Value{ .str = try Str.init(a, key) };
    const sv = Value{ .str = try Str.init(a, section) };
    try raiseErr(interp, interp.configparser_no_option_class, msg, &.{ kv, sv });
}

fn raiseDupSection(interp: *Interp, name: []const u8) !void {
    const msg = try std.fmt.allocPrint(interp.allocator, "Section '{s}' already exists", .{name});
    defer interp.allocator.free(msg);
    const nv = Value{ .str = try Str.init(interp.allocator, name) };
    try raiseErr(interp, interp.configparser_dup_section_class, msg, &.{nv});
}

fn raiseDupOption(interp: *Interp, section: []const u8, key: []const u8) !void {
    const a = interp.allocator;
    const msg = try std.fmt.allocPrint(a, "Duplicate option '{s}' in section: '{s}'", .{ key, section });
    defer a.free(msg);
    const kv = Value{ .str = try Str.init(a, key) };
    const sv = Value{ .str = try Str.init(a, section) };
    try raiseErr(interp, interp.configparser_dup_option_class, msg, &.{ kv, sv });
}

fn raiseMissingHeader(interp: *Interp) !void {
    try raiseErr(interp, interp.configparser_missing_header_class, "File contains no section headers.", &.{});
}

fn raiseInterpMissing(interp: *Interp, section: []const u8, option: []const u8, rawval: []const u8, ref: []const u8) !void {
    const a = interp.allocator;
    const msg = try std.fmt.allocPrint(a, "Bad value substitution: option '{s}' in section '{s}' contains an interpolation key '{s}' which is not a valid option name. Raw value: '{s}'", .{ option, section, ref, rawval });
    defer a.free(msg);
    try raiseErr(interp, interp.configparser_interp_missing_class, msg, &.{});
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

// ===== BasicInterpolation =====

fn basicInterp(a: std.mem.Allocator, state: *ConfigState, section: []const u8, raw_val: []const u8, depth: usize) ![]u8 {
    if (depth > 10) return error.InterpolationDepthError;
    if (std.mem.indexOf(u8, raw_val, "%(") == null) return a.dupe(u8, raw_val);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < raw_val.len) {
        if (i + 1 < raw_val.len and raw_val[i] == '%' and raw_val[i + 1] == '(') {
            const end = std.mem.indexOfScalarPos(u8, raw_val, i + 2, ')') orelse {
                try out.appendSlice(a, raw_val[i..]);
                break;
            };
            const key = raw_val[i + 2 .. end];
            if (end + 1 < raw_val.len and raw_val[end + 1] == 's') {
                // Look up key in section, then defaults
                if (state.getRaw(section, key)) |opt_v| {
                    if (opt_v) |v| {
                        const expanded = try basicInterp(a, state, section, v, depth + 1);
                        defer a.free(expanded);
                        try out.appendSlice(a, expanded);
                    }
                    i = end + 2;
                    continue;
                }
                // Not found — will raise later; just skip for now
                i = end + 2;
                continue;
            }
            try out.appendSlice(a, raw_val[i .. end + 2]);
            i = end + 2;
        } else {
            try out.append(a, raw_val[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

// ===== ExtendedInterpolation =====

fn extendedInterp(a: std.mem.Allocator, state: *ConfigState, section: []const u8, raw_val: []const u8, depth: usize) ![]u8 {
    if (depth > 10) return error.InterpolationDepthError;
    if (std.mem.indexOf(u8, raw_val, "${") == null) return a.dupe(u8, raw_val);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < raw_val.len) {
        if (i + 1 < raw_val.len and raw_val[i] == '$' and raw_val[i + 1] == '{') {
            const end = std.mem.indexOfScalarPos(u8, raw_val, i + 2, '}') orelse {
                try out.appendSlice(a, raw_val[i..]);
                break;
            };
            const ref = raw_val[i + 2 .. end];
            var lookup_sec = section;
            var lookup_key = ref;
            if (std.mem.indexOf(u8, ref, ":")) |colon| {
                lookup_sec = ref[0..colon];
                lookup_key = ref[colon + 1 ..];
            }
            if (state.getRaw(lookup_sec, lookup_key)) |opt_v| {
                if (opt_v) |v| {
                    const expanded = try extendedInterp(a, state, lookup_sec, v, depth + 1);
                    defer a.free(expanded);
                    try out.appendSlice(a, expanded);
                }
            } else {
                // key not found — emit literal
                try out.appendSlice(a, raw_val[i .. end + 1]);
            }
            i = end + 1;
        } else {
            try out.append(a, raw_val[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

fn interpolate(a: std.mem.Allocator, state: *ConfigState, section: []const u8, raw_val: []const u8) ![]u8 {
    return switch (state.interp_type) {
        INTERP_BASIC => basicInterp(a, state, section, raw_val, 0),
        INTERP_EXTENDED => extendedInterp(a, state, section, raw_val, 0),
        else => a.dupe(u8, raw_val),
    };
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

    for (kn, kv) |name_v, val_v| {
        if (name_v != .str) continue;
        const kname = name_v.str.bytes;
        if (std.mem.eql(u8, kname, "defaults")) {
            if (val_v == .dict) {
                for (val_v.dict.pairs.items) |pair| {
                    if (pair.key != .str) continue;
                    const lkey = try a.dupe(u8, pair.key.str.bytes);
                    defer a.free(lkey);
                    for (lkey) |*c| c.* = std.ascii.toLower(c.*);
                    const vstr: ?[]const u8 = switch (pair.value) {
                        .str => |s| s.bytes,
                        .none => null,
                        else => null,
                    };
                    try state.setDefault(lkey, vstr);
                }
            }
        } else if (std.mem.eql(u8, kname, "allow_no_value")) {
            if (val_v == .boolean) state.allow_no_value = val_v.boolean;
        } else if (std.mem.eql(u8, kname, "strict")) {
            if (val_v == .boolean) state.strict = val_v.boolean;
        } else if (std.mem.eql(u8, kname, "inline_comment_prefixes")) {
            if (val_v == .tuple and val_v.tuple.items.len > 0 and val_v.tuple.items[0] == .str) {
                state.inline_comment_prefixes = val_v.tuple.items[0].str.bytes;
            }
        } else if (std.mem.eql(u8, kname, "delimiters")) {
            if (val_v == .tuple and val_v.tuple.items.len >= 1 and val_v.tuple.items[0] == .str) {
                const d0 = val_v.tuple.items[0].str.bytes;
                if (d0.len > 0) {
                    state.delimiters[0] = d0[0];
                    if (val_v.tuple.items.len >= 2 and val_v.tuple.items[1] == .str) {
                        const d1 = val_v.tuple.items[1].str.bytes;
                        if (d1.len > 0) state.delimiters[1] = d1[0];
                    } else {
                        state.delimiters[1] = 0; // only one delimiter
                    }
                }
            }
        } else if (std.mem.eql(u8, kname, "comment_prefixes")) {
            if (val_v == .tuple) {
                // Build a string of comment chars
                var cp_buf: [8]u8 = undefined;
                var cp_len: usize = 0;
                for (val_v.tuple.items) |cv| {
                    if (cv == .str and cv.str.bytes.len > 0 and cp_len < 8) {
                        cp_buf[cp_len] = cv.str.bytes[0];
                        cp_len += 1;
                    }
                }
                state.comment_prefixes = try a.dupe(u8, cp_buf[0..cp_len]);
            }
        } else if (std.mem.eql(u8, kname, "interpolation")) {
            // Check if it's an ExtendedInterpolation instance
            if (val_v == .instance) {
                const cls_name = val_v.instance.cls.name;
                if (std.mem.eql(u8, cls_name, "ExtendedInterpolation")) {
                    state.interp_type = INTERP_EXTENDED;
                } else if (std.mem.eql(u8, cls_name, "BasicInterpolation")) {
                    state.interp_type = INTERP_BASIC;
                } else {
                    state.interp_type = INTERP_NONE;
                }
            } else if (val_v == .none) {
                state.interp_type = INTERP_NONE;
            }
        }
    }

    try inst.dict.setStr(a, "__state", Value{ .small_int = @intCast(@intFromPtr(state)) });
    return Value.none;
}

// ===== read_string =====

fn readStringFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    state.parse(args[1].str.bytes) catch |err| switch (err) {
        error.MissingSectionHeader => {
            try raiseMissingHeader(interp);
            return error.PyException;
        },
        error.DuplicateOption => {
            try raiseDupOption(interp, "?", "?");
            return error.PyException;
        },
        else => return err,
    };
    return Value.none;
}

// ===== read_file =====

fn readFileFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    const fp = args[1];
    // Call fp.read() to get content
    const read_attr = try dispatch.loadAttrValue(interp, fp, "read");
    const content_v = try dispatch.invoke(interp, read_attr, &.{});
    const text: []const u8 = switch (content_v) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        else => return error.TypeError,
    };
    state.parse(text) catch |err| switch (err) {
        error.MissingSectionHeader => {
            try raiseMissingHeader(interp);
            return error.PyException;
        },
        error.DuplicateOption => {
            try raiseDupOption(interp, "?", "?");
            return error.PyException;
        },
        else => return err,
    };
    return Value.none;
}

// ===== read_dict =====

fn readDictFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    if (args[1] != .dict) return error.TypeError;
    for (args[1].dict.pairs.items) |outer| {
        if (outer.key != .str) continue;
        const sec_name = outer.key.str.bytes;
        _ = try state.addSection(sec_name);
        const sec = state.getSection(sec_name).?;
        if (outer.value == .dict) {
            for (outer.value.dict.pairs.items) |inner| {
                if (inner.key != .str) continue;
                const lkey = try a.dupe(u8, inner.key.str.bytes);
                defer a.free(lkey);
                for (lkey) |*c| c.* = std.ascii.toLower(c.*);
                const vstr: ?[]const u8 = switch (inner.value) {
                    .str => |s| s.bytes,
                    .small_int => |n| blk: {
                        const s = try std.fmt.allocPrint(a, "{d}", .{n});
                        defer a.free(s);
                        break :blk s;
                    },
                    .none => null,
                    else => null,
                };
                try sec.set(a, lkey, vstr);
            }
        }
    }
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
    const lkey = try a.dupe(u8, args[2].str.bytes);
    defer a.free(lkey);
    for (lkey) |*c| c.* = std.ascii.toLower(c.*);
    return Value{ .boolean = state.getRaw(args[1].str.bytes, lkey) != null };
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
    const lkey = try a.dupe(u8, args[2].str.bytes);
    defer a.free(lkey);
    for (lkey) |*c| c.* = std.ascii.toLower(c.*);

    var fallback: ?Value = null;
    var raw_mode = false;
    if (args.len >= 4) fallback = args[3];
    for (kn, kv) |nm, vl| {
        if (nm == .str) {
            if (std.mem.eql(u8, nm.str.bytes, "fallback")) fallback = vl;
            if (std.mem.eql(u8, nm.str.bytes, "raw") and vl == .boolean) raw_mode = vl.boolean;
        }
    }

    if (state.getSection(sec_name) == null and fallback == null) {
        try raiseNoSection(interp, sec_name);
        return error.PyException;
    }

    if (state.getRaw(sec_name, lkey)) |opt_v| {
        if (opt_v) |raw_val| {
            if (raw_mode or state.raw) {
                return Value{ .str = try Str.init(a, raw_val) };
            }
            // Check for missing interpolation key → InterpolationMissingOptionError
            if (state.interp_type == INTERP_BASIC) {
                var scan: usize = 0;
                while (std.mem.indexOfPos(u8, raw_val, scan, "%(")) |pi| {
                    const ei = std.mem.indexOfScalarPos(u8, raw_val, pi + 2, ')') orelse break;
                    const ref_key = raw_val[pi + 2 .. ei];
                    if (state.getRaw(sec_name, ref_key) == null) {
                        try raiseInterpMissing(interp, sec_name, lkey, raw_val, ref_key);
                        return error.PyException;
                    }
                    scan = ei + 1;
                }
            }
            const interpolated = try interpolate(a, state, sec_name, raw_val);
            defer a.free(interpolated);
            return Value{ .str = try Str.init(a, interpolated) };
        }
        // allow_no_value: key exists with null value
        return Value.none;
    }
    if (fallback) |fb| return fb;
    try raiseNoOption(interp, sec_name, lkey);
    return error.PyException;
}

// ===== getint / getfloat / getboolean =====

fn getintFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return getintImpl(p, args, &.{}, &.{});
}
fn getintKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return getintImpl(p, args, kn, kv);
}
fn getintImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const vstr = try getImpl(p, args, kn, kv);
    if (vstr != .str) return vstr;
    const s = std.mem.trim(u8, vstr.str.bytes, " \t");
    const n = std.fmt.parseInt(i64, s, 10) catch {
        try interp.raisePy("ValueError", "invalid literal for int");
        return error.PyException;
    };
    return Value{ .small_int = n };
}

fn getfloatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return getfloatImpl(p, args, &.{}, &.{});
}
fn getfloatKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return getfloatImpl(p, args, kn, kv);
}
fn getfloatImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const vstr = try getImpl(p, args, kn, kv);
    if (vstr != .str) return vstr;
    const s = std.mem.trim(u8, vstr.str.bytes, " \t");
    const f = std.fmt.parseFloat(f64, s) catch {
        try interp.raisePy("ValueError", "invalid literal for float");
        return error.PyException;
    };
    return Value{ .float = f };
}

fn getbooleanFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return getbooleanImpl(p, args, &.{}, &.{});
}
fn getbooleanKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return getbooleanImpl(p, args, kn, kv);
}
fn getbooleanImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const vstr = try getImpl(p, args, kn, kv);
    if (vstr != .str) return vstr;
    const s = std.mem.trim(u8, vstr.str.bytes, " \t");
    const true_vals = &[_][]const u8{ "1", "yes", "true", "on" };
    const false_vals = &[_][]const u8{ "0", "no", "false", "off" };
    for (true_vals) |tv| if (std.ascii.eqlIgnoreCase(s, tv)) return Value{ .boolean = true };
    for (false_vals) |fv| if (std.ascii.eqlIgnoreCase(s, fv)) return Value{ .boolean = false };
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
    for (sec.keys.items) |k| try list.append(a, Value{ .str = try Str.init(a, k) });
    for (state.def_keys.items) |dk| {
        var found = false;
        for (sec.keys.items) |k| if (std.mem.eql(u8, k, dk)) { found = true; break; };
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
    const list = try List.init(a);
    for (sec.keys.items, sec.vals.items) |k, v| {
        const t = try Tuple.init(a, 2);
        t.items[0] = Value{ .str = try Str.init(a, k) };
        t.items[1] = if (v) |vs| Value{ .str = try Str.init(a, vs) } else Value.none;
        try list.append(a, Value{ .tuple = t });
    }
    return Value{ .list = list };
}

// ===== defaults =====

fn defaultsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    const d = try Dict.init(a);
    for (state.def_keys.items, state.def_vals.items) |k, v| {
        const vv: Value = if (v) |vs| Value{ .str = try Str.init(a, vs) } else Value.none;
        try d.setStr(a, k, vv);
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
    const lkey = try a.dupe(u8, args[2].str.bytes);
    defer a.free(lkey);
    for (lkey) |*c| c.* = std.ascii.toLower(c.*);
    const sec = state.getSection(args[1].str.bytes) orelse {
        try raiseNoSection(interp, args[1].str.bytes);
        return error.PyException;
    };
    try sec.set(a, lkey, args[3].str.bytes);
    return Value.none;
}

// ===== add_section =====

fn addSectionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    const ok = try state.addSection(args[1].str.bytes);
    if (!ok) {
        try raiseDupSection(interp, args[1].str.bytes);
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
    const lkey = try a.dupe(u8, args[2].str.bytes);
    defer a.free(lkey);
    for (lkey) |*c| c.* = std.ascii.toLower(c.*);
    const sec = state.getSection(args[1].str.bytes) orelse {
        try raiseNoSection(interp, args[1].str.bytes);
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
    return writeImpl(p, args, &.{}, &.{});
}
fn writeKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return writeImpl(p, args, kn, kv);
}
fn writeImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    const fp = args[1];
    var space_around: bool = true;
    for (kn, kv) |n, v| {
        if (n == .str and std.mem.eql(u8, n.str.bytes, "space_around_delimiters") and v == .boolean)
            space_around = v.boolean;
    }
    const delim_str: []const u8 = if (space_around) " = " else "=";

    if (state.def_keys.items.len > 0) {
        try callWrite(interp, fp, "[DEFAULT]\n");
        for (state.def_keys.items, state.def_vals.items) |k, v| {
            const vs: []const u8 = if (v) |s| s else "";
            const line = try std.fmt.allocPrint(a, "{s}{s}{s}\n", .{ k, delim_str, vs });
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
            const vs: []const u8 = if (v) |s| s else "";
            const line = try std.fmt.allocPrint(a, "{s}{s}{s}\n", .{ k, delim_str, vs });
            defer a.free(line);
            try callWrite(interp, fp, line);
        }
        try callWrite(interp, fp, "\n");
    }
    return Value.none;
}

// ===== __getitem__ (SectionProxy) =====

fn getitemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const state = stateFromInst(args[0].instance);
    const sec_name = args[1].str.bytes;
    if (state.getSection(sec_name) == null) {
        try raiseNoSection(interp, sec_name);
        return error.PyException;
    }
    // Return a SectionProxy instance
    const proxy_cls = interp.configparser_proxy_class orelse {
        try raiseNoSection(interp, sec_name);
        return error.PyException;
    };
    const inst = try Instance.init(a, proxy_cls);
    try inst.dict.setStr(a, "__parser_ptr", Value{ .small_int = @intCast(@intFromPtr(state)) });
    try inst.dict.setStr(a, "__sec_name", Value{ .str = try Str.init(a, sec_name) });
    return Value{ .instance = inst };
}

// ===== SectionProxy methods =====

fn proxyGetitem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const inst = args[0].instance;
    const state_v = inst.dict.getStr("__parser_ptr") orelse return error.TypeError;
    const state: *ConfigState = @ptrFromInt(@as(usize, @intCast(state_v.small_int)));
    const sec_name_v = inst.dict.getStr("__sec_name") orelse return error.TypeError;
    const sec_name = sec_name_v.str.bytes;
    const lkey = try a.dupe(u8, args[1].str.bytes);
    defer a.free(lkey);
    for (lkey) |*c| c.* = std.ascii.toLower(c.*);
    if (state.getRaw(sec_name, lkey)) |opt_v| {
        if (opt_v) |raw_val| {
            const interpolated = try interpolate(a, state, sec_name, raw_val);
            defer a.free(interpolated);
            return Value{ .str = try Str.init(a, interpolated) };
        }
        return Value.none;
    }
    try raiseNoOption(interp, sec_name, lkey);
    return error.PyException;
}

fn proxyContains(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return Value{ .boolean = false };
    const inst = args[0].instance;
    const state_v = inst.dict.getStr("__parser_ptr") orelse return Value{ .boolean = false };
    const state: *ConfigState = @ptrFromInt(@as(usize, @intCast(state_v.small_int)));
    const sec_name_v = inst.dict.getStr("__sec_name") orelse return Value{ .boolean = false };
    const sec_name = sec_name_v.str.bytes;
    const lkey = try a.dupe(u8, args[1].str.bytes);
    defer a.free(lkey);
    for (lkey) |*c| c.* = std.ascii.toLower(c.*);
    return Value{ .boolean = state.getRaw(sec_name, lkey) != null };
}

fn proxyKeys(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state_v = inst.dict.getStr("__parser_ptr") orelse return error.TypeError;
    const state: *ConfigState = @ptrFromInt(@as(usize, @intCast(state_v.small_int)));
    const sec_name_v = inst.dict.getStr("__sec_name") orelse return error.TypeError;
    const sec_name = sec_name_v.str.bytes;
    const sec = state.getSection(sec_name) orelse return error.TypeError;
    const list = try List.init(a);
    for (sec.keys.items) |k| try list.append(a, Value{ .str = try Str.init(a, k) });
    for (state.def_keys.items) |dk| {
        var found = false;
        for (sec.keys.items) |k| if (std.mem.eql(u8, k, dk)) { found = true; break; };
        if (!found) try list.append(a, Value{ .str = try Str.init(a, dk) });
    }
    return Value{ .list = list };
}

fn proxyItems(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const state_v = inst.dict.getStr("__parser_ptr") orelse return error.TypeError;
    const state: *ConfigState = @ptrFromInt(@as(usize, @intCast(state_v.small_int)));
    const sec_name_v = inst.dict.getStr("__sec_name") orelse return error.TypeError;
    const sec_name = sec_name_v.str.bytes;
    const sec = state.getSection(sec_name) orelse return error.TypeError;
    const list = try List.init(a);
    for (sec.keys.items, sec.vals.items) |k, v| {
        const t = try Tuple.init(a, 2);
        t.items[0] = Value{ .str = try Str.init(a, k) };
        t.items[1] = if (v) |vs| Value{ .str = try Str.init(a, vs) } else Value.none;
        try list.append(a, Value{ .tuple = t });
    }
    // Add defaults not in section
    if (state.getSection(sec_name)) |_| {
        for (state.def_keys.items, state.def_vals.items) |dk, dv| {
            var found = false;
            for (sec.keys.items) |k| if (std.mem.eql(u8, k, dk)) { found = true; break; };
            if (!found) {
                const t = try Tuple.init(a, 2);
                t.items[0] = Value{ .str = try Str.init(a, dk) };
                t.items[1] = if (dv) |vs| Value{ .str = try Str.init(a, vs) } else Value.none;
                try list.append(a, Value{ .tuple = t });
            }
        }
    }
    return Value{ .list = list };
}

// ===== build class =====

fn buildParserClass(interp: *Interp, name: []const u8, raw: bool) !*Class {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try regKw(a, d, "__init__", initFn, initKw);
    try reg(a, d, "read_string", readStringFn);
    try reg(a, d, "read_file", readFileFn);
    try reg(a, d, "read_dict", readDictFn);
    try reg(a, d, "sections", sectionsFn);
    try reg(a, d, "has_section", hasSectionFn);
    try reg(a, d, "has_option", hasOptionFn);
    try regKw(a, d, "get", getFn, getKw);
    try regKw(a, d, "getint", getintFn, getintKw);
    try regKw(a, d, "getfloat", getfloatFn, getfloatKw);
    try regKw(a, d, "getboolean", getbooleanFn, getbooleanKw);
    try reg(a, d, "options", optionsFn);
    try reg(a, d, "items", itemsFn);
    try reg(a, d, "defaults", defaultsFn);
    try reg(a, d, "set", setFn);
    try reg(a, d, "add_section", addSectionFn);
    try reg(a, d, "remove_option", removeOptionFn);
    try reg(a, d, "remove_section", removeSectionFn);
    try regKw(a, d, "write", writeFn, writeKw);
    try reg(a, d, "__getitem__", getitemFn);
    // BOOLEAN_STATES class attribute
    const bs = try Dict.init(a);
    try bs.setStr(a, "1", Value{ .boolean = true });
    try bs.setStr(a, "yes", Value{ .boolean = true });
    try bs.setStr(a, "true", Value{ .boolean = true });
    try bs.setStr(a, "on", Value{ .boolean = true });
    try bs.setStr(a, "0", Value{ .boolean = false });
    try bs.setStr(a, "no", Value{ .boolean = false });
    try bs.setStr(a, "false", Value{ .boolean = false });
    try bs.setStr(a, "off", Value{ .boolean = false });
    try d.setStr(a, "BOOLEAN_STATES", Value{ .dict = bs });
    const cls = try Class.init(a, name, &.{}, d);
    if (raw) try cls.dict.setStr(a, "__raw__", Value{ .boolean = true });
    return cls;
}

fn buildErrClass(interp: *Interp, class_name: []const u8) !*Class {
    const a = interp.allocator;
    const d = try Dict.init(a);
    if (interp.builtins.getStr("Exception")) |exc_v| {
        if (exc_v == .class) return Class.init(a, class_name, &[_]*Class{exc_v.class}, d);
    }
    return Class.init(a, class_name, &.{}, d);
}

fn buildProxyClass(interp: *Interp) !*Class {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try reg(a, d, "__getitem__", proxyGetitem);
    try reg(a, d, "__contains__", proxyContains);
    try reg(a, d, "keys", proxyKeys);
    try reg(a, d, "items", proxyItems);
    return Class.init(a, "SectionProxy", &.{}, d);
}

fn buildInterpClass(interp: *Interp, name: []const u8) !*Class {
    const a = interp.allocator;
    const d = try Dict.init(a);
    _ = name;
    return Class.init(a, "Interpolation", &.{}, d);
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "configparser");

    if (interp.configparser_no_section_class == null)
        interp.configparser_no_section_class = try buildErrClass(interp, "NoSectionError");
    if (interp.configparser_no_option_class == null)
        interp.configparser_no_option_class = try buildErrClass(interp, "NoOptionError");
    if (interp.configparser_dup_section_class == null)
        interp.configparser_dup_section_class = try buildErrClass(interp, "DuplicateSectionError");
    if (interp.configparser_dup_option_class == null)
        interp.configparser_dup_option_class = try buildErrClass(interp, "DuplicateOptionError");
    if (interp.configparser_missing_header_class == null)
        interp.configparser_missing_header_class = try buildErrClass(interp, "MissingSectionHeaderError");
    if (interp.configparser_interp_missing_class == null)
        interp.configparser_interp_missing_class = try buildErrClass(interp, "InterpolationMissingOptionError");
    if (interp.configparser_proxy_class == null)
        interp.configparser_proxy_class = try buildProxyClass(interp);
    if (interp.configparser_class == null)
        interp.configparser_class = try buildParserClass(interp, "ConfigParser", false);
    if (interp.configparser_raw_class == null)
        interp.configparser_raw_class = try buildParserClass(interp, "RawConfigParser", true);

    try m.attrs.setStr(a, "NoSectionError", Value{ .class = interp.configparser_no_section_class.? });
    try m.attrs.setStr(a, "NoOptionError", Value{ .class = interp.configparser_no_option_class.? });
    try m.attrs.setStr(a, "DuplicateSectionError", Value{ .class = interp.configparser_dup_section_class.? });
    try m.attrs.setStr(a, "DuplicateOptionError", Value{ .class = interp.configparser_dup_option_class.? });
    try m.attrs.setStr(a, "MissingSectionHeaderError", Value{ .class = interp.configparser_missing_header_class.? });
    try m.attrs.setStr(a, "InterpolationMissingOptionError", Value{ .class = interp.configparser_interp_missing_class.? });
    try m.attrs.setStr(a, "Error", Value{ .class = interp.configparser_no_section_class.? });
    try m.attrs.setStr(a, "ConfigParser", Value{ .class = interp.configparser_class.? });
    try m.attrs.setStr(a, "RawConfigParser", Value{ .class = interp.configparser_raw_class.? });
    try m.attrs.setStr(a, "SafeConfigParser", Value{ .class = interp.configparser_class.? });
    try m.attrs.setStr(a, "DEFAULTSECT", Value{ .str = try Str.init(a, "DEFAULT") });
    try m.attrs.setStr(a, "MAX_INTERPOLATION_DEPTH", Value{ .small_int = 10 });

    // Build interpolation classes
    const basic_d = try Dict.init(a);
    const basic_cls = try Class.init(a, "BasicInterpolation", &.{}, basic_d);
    const ext_d = try Dict.init(a);
    const ext_cls = try Class.init(a, "ExtendedInterpolation", &.{}, ext_d);
    try m.attrs.setStr(a, "BasicInterpolation", Value{ .class = basic_cls });
    try m.attrs.setStr(a, "ExtendedInterpolation", Value{ .class = ext_cls });
    _ = buildInterpClass;

    return m;
}
