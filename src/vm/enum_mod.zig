//! Pinhole `enum` module. The base classes `Enum`, `IntEnum`,
//! `StrEnum`, `Flag`, and `IntFlag` carry an `EnumKind` marker on
//! the Class. When `__build_class__` finishes a class whose MRO
//! includes one of those bases, `processClass` walks the namespace,
//! converts plain attributes into singleton member instances, and
//! attaches the canonical-member list so `iter(cls)`, `len(cls)`,
//! `cls(value)`, and `cls['NAME']` all work.
//!
//! `auto()` returns a sentinel that the body processor replaces with
//! the next sequential int (1, 2, 3, ...) for Enum/IntEnum, the next
//! power-of-two for Flag/IntFlag, and the lowercase attribute name
//! for StrEnum. `unique` is a class decorator that raises ValueError
//! if a class has any aliases.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const class_mod = @import("../object/class.zig");
const Class = class_mod.Class;
const EnumKind = class_mod.EnumKind;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const dunder = @import("dunder.zig");

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);

    const m = try Module.init(a, "enum");
    try m.attrs.setStr(a, "Enum", Value{ .class = interp.enum_enum_class.? });
    try m.attrs.setStr(a, "IntEnum", Value{ .class = interp.enum_int_enum_class.? });
    try m.attrs.setStr(a, "StrEnum", Value{ .class = interp.enum_str_enum_class.? });
    try m.attrs.setStr(a, "Flag", Value{ .class = interp.enum_flag_class.? });
    try m.attrs.setStr(a, "IntFlag", Value{ .class = interp.enum_int_flag_class.? });
    try regModFn(interp, m, "auto", autoFn);
    try regModFn(interp, m, "unique", uniqueFn);
    return m;
}

fn ensureClasses(interp: *Interp) !void {
    if (interp.enum_enum_class != null) return;
    const a = interp.allocator;

    const enum_dict = try Dict.init(a);
    try reg(a, enum_dict, "__str__", memberStrFn);
    try reg(a, enum_dict, "__repr__", memberReprFn);
    try reg(a, enum_dict, "__hash__", memberHashFn);
    try reg(a, enum_dict, "__eq__", memberEqFn);
    try reg(a, enum_dict, "__class_getitem__", classGetItemFn);
    const enum_cls = try Class.init(a, "Enum", &.{}, enum_dict);
    enum_cls.enum_kind = .plain;
    interp.enum_enum_class = enum_cls;

    const int_enum_dict = try Dict.init(a);
    try reg(a, int_enum_dict, "__str__", intEnumStrFn);
    try reg(a, int_enum_dict, "__add__", intEnumAddFn);
    try reg(a, int_enum_dict, "__sub__", intEnumSubFn);
    try reg(a, int_enum_dict, "__lt__", intEnumLtFn);
    try reg(a, int_enum_dict, "__le__", intEnumLeFn);
    try reg(a, int_enum_dict, "__gt__", intEnumGtFn);
    try reg(a, int_enum_dict, "__ge__", intEnumGeFn);
    const int_enum_cls = try Class.init(a, "IntEnum", &.{enum_cls}, int_enum_dict);
    int_enum_cls.enum_kind = .int_enum;
    interp.enum_int_enum_class = int_enum_cls;

    const str_enum_dict = try Dict.init(a);
    try reg(a, str_enum_dict, "__str__", strEnumStrFn);
    const str_enum_cls = try Class.init(a, "StrEnum", &.{enum_cls}, str_enum_dict);
    str_enum_cls.enum_kind = .str_enum;
    interp.enum_str_enum_class = str_enum_cls;

    const flag_dict = try Dict.init(a);
    try reg(a, flag_dict, "__or__", flagOrFn);
    try reg(a, flag_dict, "__and__", flagAndFn);
    try reg(a, flag_dict, "__xor__", flagXorFn);
    try reg(a, flag_dict, "__contains__", flagContainsFn);
    try reg(a, flag_dict, "__repr__", flagReprFn);
    try reg(a, flag_dict, "__str__", flagStrFn);
    const flag_cls = try Class.init(a, "Flag", &.{enum_cls}, flag_dict);
    flag_cls.enum_kind = .flag;
    interp.enum_flag_class = flag_cls;

    const int_flag_dict = try Dict.init(a);
    const int_flag_cls = try Class.init(a, "IntFlag", &.{flag_cls}, int_flag_dict);
    int_flag_cls.enum_kind = .int_flag;
    interp.enum_int_flag_class = int_flag_cls;

    const auto_dict = try Dict.init(a);
    interp.enum_auto_class = try Class.init(a, "auto", &.{}, auto_dict);
}

fn reg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regModFn(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

// ===== auto() / unique() =====

fn autoFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    const inst = try Instance.init(interp.allocator, interp.enum_auto_class.?);
    return Value{ .instance = inst };
}

fn isAuto(interp: *Interp, v: Value) bool {
    if (v != .instance) return false;
    const auto_cls = interp.enum_auto_class orelse return false;
    return v.instance.cls == auto_cls;
}

fn uniqueFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .class) {
        try interp.typeError("unique expects a class");
        return error.TypeError;
    }
    const cls = args[0].class;
    // After processClass any alias points to an existing canonical
    // member. Look at the __members__ dict: if name -> member.name
    // disagrees, that name is an alias.
    if (cls.dict.getStr("__members__")) |mv| {
        if (mv == .dict) {
            for (mv.dict.pairs.items) |pair| {
                if (pair.key != .str) continue;
                if (pair.value != .instance) continue;
                const stored = pair.value.instance.dict.getStr("_name_") orelse continue;
                if (stored != .str) continue;
                if (!std.mem.eql(u8, pair.key.str.bytes, stored.str.bytes)) {
                    try interp.raisePy("ValueError", "duplicate values found");
                    return error.PyException;
                }
            }
        }
    }
    return args[0];
}

// ===== processClass: turn the class body into members =====

/// Called from `__build_class__` after the class is built and the
/// namespace is the class dict. If any base has `enum_kind` set, this
/// promotes plain attributes to enum members.
pub fn processClass(interp: *Interp, cls: *Class) !void {
    var inherited_kind: ?EnumKind = null;
    for (cls.mro[1..]) |b| {
        if (b.enum_kind) |k| {
            inherited_kind = k;
            break;
        }
    }
    const kind = inherited_kind orelse return;
    cls.enum_kind = kind;

    const a = interp.allocator;

    // Collect candidate (name, raw_value) pairs in insertion order
    // before mutating cls.dict (mutation invalidates iteration).
    const Cand = struct { name: []const u8, raw: Value };
    var cands: std.ArrayList(Cand) = .empty;
    defer cands.deinit(a);
    for (cls.dict.keys.items) |key| {
        if (isReservedName(key)) continue;
        const v = cls.dict.getStr(key) orelse continue;
        if (isMethodish(v)) continue;
        try cands.append(a, .{ .name = key, .raw = v });
    }

    const members_map = try Dict.init(a);
    const value_map = try Dict.init(a);
    var auto_seq: i64 = 0;
    var flag_bit: u6 = 0;

    for (cands.items) |c| {
        var resolved = c.raw;
        if (isAuto(interp, c.raw)) {
            switch (kind) {
                .flag, .int_flag => {
                    resolved = Value{ .small_int = @as(i64, 1) << flag_bit };
                    flag_bit += 1;
                },
                .str_enum => {
                    var lower = try a.alloc(u8, c.name.len);
                    for (c.name, 0..) |ch, i| {
                        lower[i] = std.ascii.toLower(ch);
                    }
                    const s = try Str.init(a, lower);
                    a.free(lower);
                    resolved = Value{ .str = s };
                },
                else => {
                    auto_seq += 1;
                    resolved = Value{ .small_int = auto_seq };
                },
            }
        } else if (resolved == .small_int) {
            // Track auto sequence: next auto starts after the largest
            // explicit small_int.
            switch (kind) {
                .plain, .int_enum => if (resolved.small_int > auto_seq) {
                    auto_seq = resolved.small_int;
                },
                else => {},
            }
        }

        // Aliases: if a canonical member already has this value, this
        // name is an alias. Point it at the existing member.
        if (value_map.getKey(resolved)) |existing| {
            try cls.dict.setStr(a, c.name, existing);
            try members_map.setStr(a, c.name, existing);
            continue;
        }

        // Canonical member: build an Instance whose cls = the new
        // class, store name/value attrs.
        const member = try Instance.init(a, cls);
        const name_s = try Str.init(a, c.name);
        try member.dict.setStr(a, "_name_", Value{ .str = name_s });
        try member.dict.setStr(a, "name", Value{ .str = name_s });
        try member.dict.setStr(a, "_value_", resolved);
        try member.dict.setStr(a, "value", resolved);
        const mv = Value{ .instance = member };
        try cls.dict.setStr(a, c.name, mv);
        try members_map.setStr(a, c.name, mv);
        try value_map.setKey(a, resolved, mv);
        try cls.enum_canonical_members.append(a, mv);
    }

    cls.enum_value_to_member = value_map;
    try cls.dict.setStr(a, "__members__", Value{ .dict = members_map });
}

fn isReservedName(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__")) return true;
    if (std.mem.startsWith(u8, name, "_") and std.mem.endsWith(u8, name, "_")) {
        if (name.len >= 2) return true;
    }
    return false;
}

fn isMethodish(v: Value) bool {
    return switch (v) {
        .function, .builtin_fn, .bound_method, .partial, .cached_fn, .cached_property, .descriptor => true,
        else => false,
    };
}

// ===== Class-level helpers exposed to dispatch =====

/// `Cls(value)` for an enum class. Returns the member whose `_value_`
/// matches, or builds a Flag/IntFlag composite when value is an int
/// combination of known bits.
pub fn callEnum(interp: *Interp, cls: *Class, args: []const Value) !Value {
    if (cls.enum_canonical_members.items.len == 0) {
        // Functional API: `Enum('Name', spec)` builds a fresh class.
        return try functionalCall(interp, cls, args);
    }
    if (args.len != 1) {
        try interp.typeError("enum class requires one argument");
        return error.TypeError;
    }
    const v = args[0];
    if (cls.enum_value_to_member) |vm| {
        if (vm.getKey(v)) |m| return m;
    }
    if (cls.enum_kind == .flag or cls.enum_kind == .int_flag) {
        if (v == .small_int) return try buildFlagComposite(interp, cls, v.small_int);
    }
    try interp.raisePy("ValueError", "value is not a valid enum member");
    return error.PyException;
}

/// Functional API: `Enum('Color', ['RED', 'GREEN'])` and friends.
fn functionalCall(interp: *Interp, cls: *Class, args: []const Value) !Value {
    if (args.len != 2 or args[0] != .str) {
        try interp.typeError("Functional API requires (name, members)");
        return error.TypeError;
    }
    const a = interp.allocator;
    const new_dict = try Dict.init(a);
    const new_cls = try Class.init(a, args[0].str.bytes, &.{cls}, new_dict);
    new_cls.enum_kind = cls.enum_kind;

    switch (args[1]) {
        .list => |l| {
            for (l.items.items, 0..) |it, i| {
                if (it != .str) {
                    try interp.typeError("Functional API: member name must be str");
                    return error.TypeError;
                }
                try new_dict.setStr(a, it.str.bytes, Value{ .small_int = @intCast(i + 1) });
            }
        },
        .tuple => |t| {
            for (t.items, 0..) |it, i| {
                if (it != .str) {
                    try interp.typeError("Functional API: member name must be str");
                    return error.TypeError;
                }
                try new_dict.setStr(a, it.str.bytes, Value{ .small_int = @intCast(i + 1) });
            }
        },
        .str => |s| {
            // Whitespace-separated names.
            var it = std.mem.tokenizeAny(u8, s.bytes, " ,");
            var i: i64 = 1;
            while (it.next()) |tok| : (i += 1) {
                try new_dict.setStr(a, try a.dupe(u8, tok), Value{ .small_int = i });
            }
        },
        .dict => |d| {
            for (d.pairs.items) |pair| {
                if (pair.key != .str) {
                    try interp.typeError("Functional API: dict keys must be str");
                    return error.TypeError;
                }
                try new_dict.setStr(a, pair.key.str.bytes, pair.value);
            }
        },
        else => {
            try interp.typeError("Functional API: members must be list/tuple/str/dict");
            return error.TypeError;
        },
    }

    try processClass(interp, new_cls);
    return Value{ .class = new_cls };
}

fn buildFlagComposite(interp: *Interp, cls: *Class, val: i64) !Value {
    const a = interp.allocator;
    if (cls.enum_value_to_member) |vm| {
        if (vm.getKey(Value{ .small_int = val })) |m| return m;
    }
    // No canonical match -- fabricate a composite member instance.
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "_name_", Value.none);
    try inst.dict.setStr(a, "name", Value.none);
    try inst.dict.setStr(a, "_value_", Value{ .small_int = val });
    try inst.dict.setStr(a, "value", Value{ .small_int = val });
    return Value{ .instance = inst };
}

pub fn iterClass(interp: *Interp, cls: *Class) !Value {
    const lst = try List.init(interp.allocator);
    for (cls.enum_canonical_members.items) |m| try lst.append(interp.allocator, m);
    return Value{ .list = lst };
}

pub fn lenClass(cls: *Class) i64 {
    return @intCast(cls.enum_canonical_members.items.len);
}

pub fn classContains(cls: *Class, v: Value) bool {
    if (v != .instance) return false;
    if (v.instance.cls != cls) return false;
    for (cls.enum_canonical_members.items) |m| {
        if (m.instance == v.instance) return true;
    }
    return false;
}

// ===== member methods =====

fn memberStrFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const name = (inst.dict.getStr("_name_") orelse Value.none);
    if (name != .str) return Value{ .str = try Str.init(interp.allocator, "?") };
    const out = try std.fmt.allocPrint(interp.allocator, "{s}.{s}", .{ inst.cls.name, name.str.bytes });
    defer interp.allocator.free(out);
    return Value{ .str = try Str.init(interp.allocator, out) };
}

fn memberReprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const name = inst.dict.getStr("_name_") orelse Value.none;
    const value = inst.dict.getStr("_value_") orelse Value.none;
    var w = std.Io.Writer.Allocating.init(interp.allocator);
    try w.writer.writeAll("<");
    try w.writer.writeAll(inst.cls.name);
    if (name == .str) {
        try w.writer.writeByte('.');
        try w.writer.writeAll(name.str.bytes);
    }
    try w.writer.writeAll(": ");
    try value.writeRepr(&w.writer);
    try w.writer.writeAll(">");
    return Value{ .str = try Str.init(interp.allocator, w.written()) };
}

fn memberHashFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len != 1 or args[0] != .instance) return error.TypeError;
    return Value{ .small_int = @intCast(@as(usize, @intFromPtr(args[0].instance)) & 0x7fffffff) };
}

fn memberEqFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len != 2) return error.TypeError;
    if (args[0] == .instance and args[1] == .instance) {
        return Value{ .boolean = args[0].instance == args[1].instance };
    }
    // For IntEnum/StrEnum, compare value to other primitive.
    if (args[0] == .instance) {
        if (memberValue(args[0])) |mv| {
            return Value{ .boolean = mv.equals(args[1]) };
        }
    }
    return Value.not_implemented;
}

fn memberValue(v: Value) ?Value {
    if (v != .instance) return null;
    return v.instance.dict.getStr("_value_");
}

fn classGetItemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2 or args[0] != .class or args[1] != .str) {
        try interp.typeError("Cls[name] expects str");
        return error.TypeError;
    }
    const cls = args[0].class;
    if (cls.dict.getStr("__members__")) |mv| {
        if (mv == .dict) {
            if (mv.dict.getStr(args[1].str.bytes)) |m| return m;
        }
    }
    try interp.raisePy("KeyError", args[1].str.bytes);
    return error.PyException;
}

// ===== IntEnum methods =====

fn intEnumStrFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) return error.TypeError;
    const v = memberValue(args[0]) orelse return error.TypeError;
    var w = std.Io.Writer.Allocating.init(interp.allocator);
    try v.writeRepr(&w.writer);
    return Value{ .str = try Str.init(interp.allocator, w.written()) };
}

fn intEnumBinop(args: []const Value, comptime op: u8) !Value {
    if (args.len != 2) return Value.not_implemented;
    const lv = if (args[0] == .instance) memberValue(args[0]) orelse return Value.not_implemented else args[0];
    const rv = if (args[1] == .instance) memberValue(args[1]) orelse args[1] else args[1];
    if (lv != .small_int) return Value.not_implemented;
    const other_int: i64 = switch (rv) {
        .small_int => |i| i,
        .boolean => |b| if (b) @as(i64, 1) else @as(i64, 0),
        else => return Value.not_implemented,
    };
    const result: i64 = switch (op) {
        '+' => lv.small_int + other_int,
        '-' => lv.small_int - other_int,
        else => return Value.not_implemented,
    };
    return Value{ .small_int = result };
}

fn intEnumAddFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    return intEnumBinop(args, '+');
}

fn intEnumSubFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    return intEnumBinop(args, '-');
}

fn intEnumCmp(args: []const Value, kind: u8) !Value {
    if (args.len != 2) return Value.not_implemented;
    const lv = if (args[0] == .instance) memberValue(args[0]) orelse return Value.not_implemented else args[0];
    const rv = if (args[1] == .instance) memberValue(args[1]) orelse args[1] else args[1];
    if (lv != .small_int) return Value.not_implemented;
    const ri: i64 = switch (rv) {
        .small_int => |i| i,
        .boolean => |b| if (b) @as(i64, 1) else @as(i64, 0),
        else => return Value.not_implemented,
    };
    const li = lv.small_int;
    return Value{ .boolean = switch (kind) {
        '<' => li < ri,
        'l' => li <= ri,
        '>' => li > ri,
        'g' => li >= ri,
        else => false,
    } };
}

fn intEnumLtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    return intEnumCmp(args, '<');
}
fn intEnumLeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    return intEnumCmp(args, 'l');
}
fn intEnumGtFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    return intEnumCmp(args, '>');
}
fn intEnumGeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    return intEnumCmp(args, 'g');
}

// ===== StrEnum =====

fn strEnumStrFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len != 1 or args[0] != .instance) return error.TypeError;
    const v = memberValue(args[0]) orelse return error.TypeError;
    if (v != .str) return error.TypeError;
    return v;
}

// ===== Flag =====

fn flagBitop(interp: *Interp, args: []const Value, comptime op: u8) !Value {
    if (args.len != 2) return Value.not_implemented;
    const lv = if (args[0] == .instance) memberValue(args[0]) orelse return Value.not_implemented else args[0];
    const rv = if (args[1] == .instance) memberValue(args[1]) orelse args[1] else args[1];
    if (lv != .small_int or rv != .small_int) return Value.not_implemented;
    const result_val: i64 = switch (op) {
        '|' => lv.small_int | rv.small_int,
        '&' => lv.small_int & rv.small_int,
        '^' => lv.small_int ^ rv.small_int,
        else => return Value.not_implemented,
    };
    if (args[0] != .instance) return Value{ .small_int = result_val };
    const cls = args[0].instance.cls;
    return try buildFlagComposite(interp, cls, result_val);
}

fn flagOrFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return flagBitop(interp, args, '|');
}
fn flagAndFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return flagBitop(interp, args, '&');
}
fn flagXorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return flagBitop(interp, args, '^');
}

fn flagContainsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len != 2) return Value.not_implemented;
    const lv = memberValue(args[0]) orelse return Value{ .boolean = false };
    const rv = if (args[1] == .instance) memberValue(args[1]) orelse return Value{ .boolean = false } else args[1];
    if (lv != .small_int or rv != .small_int) return Value{ .boolean = false };
    return Value{ .boolean = (lv.small_int & rv.small_int) == rv.small_int };
}

fn flagReprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const value = inst.dict.getStr("_value_") orelse Value.none;
    const name = inst.dict.getStr("_name_") orelse Value.none;
    var w = std.Io.Writer.Allocating.init(interp.allocator);
    try w.writer.writeAll("<");
    try w.writer.writeAll(inst.cls.name);
    if (name == .str) {
        try w.writer.writeByte('.');
        try w.writer.writeAll(name.str.bytes);
    } else if (value == .small_int) {
        // Composite: list canonical members whose bits are set.
        try w.writer.writeByte('.');
        try writeFlagNames(&w.writer, inst.cls, value.small_int);
    }
    try w.writer.writeAll(": ");
    try value.writeRepr(&w.writer);
    try w.writer.writeAll(">");
    return Value{ .str = try Str.init(interp.allocator, w.written()) };
}

fn flagStrFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const value = inst.dict.getStr("_value_") orelse Value.none;
    const name = inst.dict.getStr("_name_") orelse Value.none;
    var w = std.Io.Writer.Allocating.init(interp.allocator);
    try w.writer.writeAll(inst.cls.name);
    try w.writer.writeByte('.');
    if (name == .str) {
        try w.writer.writeAll(name.str.bytes);
    } else if (value == .small_int) {
        try writeFlagNames(&w.writer, inst.cls, value.small_int);
    }
    return Value{ .str = try Str.init(interp.allocator, w.written()) };
}

fn writeFlagNames(w: *std.Io.Writer, cls: *Class, val: i64) !void {
    var first = true;
    for (cls.enum_canonical_members.items) |m| {
        if (m != .instance) continue;
        const mv = m.instance.dict.getStr("_value_") orelse continue;
        if (mv != .small_int) continue;
        if (mv.small_int == 0) continue;
        if ((val & mv.small_int) != mv.small_int) continue;
        if (!first) try w.writeByte('|');
        first = false;
        const mn = m.instance.dict.getStr("_name_") orelse continue;
        if (mn == .str) try w.writeAll(mn.str.bytes);
    }
}
