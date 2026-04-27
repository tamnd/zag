//! Pinhole `dataclasses`. Reads __annotate_func__ co_consts for field
//! names, default values from class attributes; injects __init__,
//! __repr__, __eq__ into the class. Supports frozen=True.

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
const builtins_mod = @import("builtins.zig");
const dispatch = @import("dispatch.zig");

// ===== Field class =====

fn buildFieldClass(interp: *Interp) !*Class {
    const a = interp.allocator;
    const d = try Dict.init(a);
    return Class.init(a, "Field", &.{}, d);
}

fn makeField(interp: *Interp, name: []const u8, default: ?Value) !Value {
    const a = interp.allocator;
    const cls = interp.dataclasses_field_class.?;
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, name) });
    if (default) |dv| {
        try inst.dict.setStr(a, "default", dv);
        try inst.dict.setStr(a, "has_default", Value{ .boolean = true });
    } else {
        try inst.dict.setStr(a, "default", Value.none);
        try inst.dict.setStr(a, "has_default", Value{ .boolean = false });
    }
    return Value{ .instance = inst };
}

fn isFieldObject(v: Value) bool {
    if (v != .instance) return false;
    return v.instance.dict.getStr("_is_field") != null;
}

fn fieldFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return fieldImpl(p, args, &.{}, &.{});
}

fn fieldKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return fieldImpl(p, args, kn, kv);
}

fn fieldImpl(p: *anyopaque, _args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    _ = _args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const cls = interp.dataclasses_field_class.?;
    const inst = try Instance.init(a, cls);
    var default_val: Value = Value.none;
    var factory_val: Value = Value.none;
    var has_def = false;
    for (kn, kv) |nm, vl| {
        if (nm == .str) {
            if (std.mem.eql(u8, nm.str.bytes, "default")) {
                default_val = vl;
                has_def = true;
            } else if (std.mem.eql(u8, nm.str.bytes, "default_factory")) {
                factory_val = vl;
                has_def = true;
            }
        }
    }
    try inst.dict.setStr(a, "_is_field", Value{ .boolean = true });
    try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, "") });
    try inst.dict.setStr(a, "default", default_val);
    try inst.dict.setStr(a, "default_factory", factory_val);
    try inst.dict.setStr(a, "has_default", Value{ .boolean = has_def });
    return Value{ .instance = inst };
}

// ===== extract field names from __annotate_func__ =====

fn getFieldNames(interp: *Interp, cls: *Class) !?std.ArrayListUnmanaged([]const u8) {
    const a = interp.allocator;
    const af_v = cls.dict.getStr("__annotate_func__") orelse return null;
    if (af_v != .function) return null;
    const code = af_v.function.code;
    // co_consts[0] = 2 (format value), co_consts[1..] = field name strings
    if (code.consts.len < 2) return .empty;
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (code.consts[1..]) |cv| {
        if (cv == .str) try names.append(a, cv.str.bytes);
    }
    return names;
}

// ===== apply @dataclass transformation =====

fn applyDataclass(interp: *Interp, cls: *Class, frozen: bool) !Value {
    const a = interp.allocator;

    // extract field names
    const names_opt = try getFieldNames(interp, cls);
    var names: std.ArrayListUnmanaged([]const u8) = names_opt orelse .empty;
    defer names.deinit(a);

    // build __dc_fields__ list of Field instances
    // Include inherited fields from parent dataclasses (base classes first)
    const flist = try List.init(a);
    for (cls.mro[1..]) |base| {
        // Skip 'object' (no __dc_fields__) and self
        if (base == cls) continue;
        const inherited_v = base.dict.getStr("__dc_fields__") orelse continue;
        if (inherited_v != .list) continue;
        for (inherited_v.list.items.items) |fv| {
            try flist.append(a, fv);
        }
        break; // Only take from first dataclass parent
    }
    for (names.items) |name| {
        const raw_def: ?Value = cls.dict.getStr(name);
        const field_v: Value = if (raw_def) |dv| blk: {
            if (isFieldObject(dv)) {
                // Already a Field from field(); set its name
                try dv.instance.dict.setStr(a, "name", Value{ .str = try Str.init(a, name) });
                break :blk dv;
            }
            break :blk try makeField(interp, name, raw_def);
        } else try makeField(interp, name, null);
        try flist.append(a, field_v);
    }
    try cls.dict.setStr(a, "__dc_fields__", Value{ .list = flist });
    if (frozen) try cls.dict.setStr(a, "__dc_frozen__", Value{ .boolean = true });

    // inject methods
    try injectMethods(interp, cls);

    return Value{ .class = cls };
}

// ===== injected methods =====

fn dcInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const cls = inst.cls;
    const fields_v = cls.lookup("__dc_fields__") orelse return Value.none;
    if (fields_v != .list) return Value.none;
    const fields = fields_v.list.items.items;

    // count required (no default) fields
    var pos_arg_idx: usize = 1; // args[0] is self
    for (fields, 0..) |fv, fi| {
        if (fv != .instance) continue;
        const fname_v = fv.instance.dict.getStr("name") orelse continue;
        if (fname_v != .str) continue;
        const fname = fname_v.str.bytes;
        const has_def_v = fv.instance.dict.getStr("has_default") orelse Value{ .boolean = false };
        const has_def = has_def_v == .boolean and has_def_v.boolean;

        if (pos_arg_idx < args.len) {
            try inst.dict.setStr(a, fname, args[pos_arg_idx]);
            pos_arg_idx += 1;
        } else if (has_def) {
            // Check for default_factory (from field(default_factory=...))
            const factory_v = fv.instance.dict.getStr("default_factory") orelse Value.none;
            if (factory_v != .none and factory_v != .null_sentinel) {
                const new_val = dispatch.invoke(interp, factory_v, &.{}) catch Value.none;
                try inst.dict.setStr(a, fname, new_val);
            } else {
                const def_v = fv.instance.dict.getStr("default") orelse Value.none;
                // For plain (non-field()) defaults, avoid returning the Field object
                const class_def = blk: {
                    const cd = cls.lookup(fname) orelse break :blk def_v;
                    if (isFieldObject(cd)) break :blk def_v;
                    break :blk cd;
                };
                try inst.dict.setStr(a, fname, class_def);
            }
        } else {
            // no arg and no default - TypeError
            const msg = try std.fmt.allocPrint(a, "__init__() missing required argument: '{s}' (field {d})", .{ fname, fi });
            defer a.free(msg);
            try interp.raisePy("TypeError", msg);
            return error.PyException;
        }
    }
    return Value.none;
}

fn dcRepr(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const cls = inst.cls;
    const fields_v = cls.lookup("__dc_fields__") orelse {
        return Value{ .str = try Str.init(a, "<dataclass>") };
    };
    if (fields_v != .list) return Value{ .str = try Str.init(a, "<dataclass>") };
    const fields = fields_v.list.items.items;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, cls.name);
    try out.append(a, '(');
    var first = true;
    for (fields) |fv| {
        if (fv != .instance) continue;
        const fname_v = fv.instance.dict.getStr("name") orelse continue;
        if (fname_v != .str) continue;
        const fname = fname_v.str.bytes;
        const val = inst.dict.getStr(fname) orelse Value.none;
        if (!first) try out.appendSlice(a, ", ");
        first = false;
        try out.appendSlice(a, fname);
        try out.appendSlice(a, "=");
        const rv = try builtins_mod.reprBuiltin(interp, &[_]Value{val});
        if (rv == .str) try out.appendSlice(a, rv.str.bytes);
    }
    try out.append(a, ')');
    return Value{ .str = try Str.init(a, out.items) };
}

fn dcEq(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = interp;
    if (args.len < 2 or args[0] != .instance) return Value{ .boolean = false };
    const self = args[0].instance;
    const other = args[1];
    if (other != .instance) return Value{ .boolean = false };
    if (self.cls != other.instance.cls) return Value{ .boolean = false };
    const cls = self.cls;
    const fields_v = cls.lookup("__dc_fields__") orelse return Value{ .boolean = true };
    if (fields_v != .list) return Value{ .boolean = true };
    for (fields_v.list.items.items) |fv| {
        if (fv != .instance) continue;
        const fname_v = fv.instance.dict.getStr("name") orelse continue;
        if (fname_v != .str) continue;
        const fname = fname_v.str.bytes;
        const v1 = self.dict.getStr(fname) orelse Value.none;
        const v2 = other.instance.dict.getStr(fname) orelse Value.none;
        if (!v1.equals(v2)) return Value{ .boolean = false };
    }
    return Value{ .boolean = true };
}

fn dcFrozenSetattr(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    try interp.raisePy("AttributeError", "cannot assign to field of frozen instance");
    return error.PyException;
}

fn injectMethods(interp: *Interp, cls: *Class) !void {
    const a = interp.allocator;
    const frozen_v = cls.dict.getStr("__dc_frozen__");
    const frozen = frozen_v != null and frozen_v.? == .boolean and frozen_v.?.boolean;

    inline for (&[_]struct { name: []const u8, func: BuiltinFnPtr }{
        .{ .name = "__init__", .func = dcInit },
        .{ .name = "__repr__", .func = dcRepr },
        .{ .name = "__eq__", .func = dcEq },
    }) |m| {
        const f = try a.create(BuiltinFn);
        f.* = .{ .name = m.name, .func = m.func };
        try cls.dict.setStr(a, m.name, Value{ .builtin_fn = f });
    }
    if (frozen) {
        const f = try a.create(BuiltinFn);
        f.* = .{ .name = "__setattr__", .func = dcFrozenSetattr };
        try cls.dict.setStr(a, "__setattr__", Value{ .builtin_fn = f });
    }
    // mark as dataclass
    try cls.dict.setStr(a, "__dataclass__", Value{ .boolean = true });
}

// ===== DataclassFactory =====
// Returned when `@dataclass(frozen=True)` is called.

fn factoryCall(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const factory = args[0].instance;
    const cls_v = if (args.len >= 2) args[1] else return error.TypeError;
    if (cls_v != .class) return error.TypeError;
    const frozen_v = factory.dict.getStr("frozen") orelse Value{ .boolean = false };
    const frozen = frozen_v == .boolean and frozen_v.boolean;
    return applyDataclass(interp, cls_v.class, frozen);
}

fn factoryInit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value.none;
}

// ===== module functions =====

fn dataclassFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len >= 1 and args[0] == .class) {
        return applyDataclass(interp, args[0].class, false);
    }
    // no class arg - return a factory with frozen=false
    return makeFactory(interp, false);
}

fn dataclassKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    // Check if a class was passed as positional arg
    if (args.len >= 1 and args[0] == .class) {
        return applyDataclass(interp, args[0].class, false);
    }
    // Extract frozen kwarg
    var frozen = false;
    for (kn, kv) |nm, vl| {
        if (nm == .str and std.mem.eql(u8, nm.str.bytes, "frozen")) {
            frozen = vl == .boolean and vl.boolean;
        }
    }
    return makeFactory(interp, frozen);
}

fn makeFactory(interp: *Interp, frozen: bool) !Value {
    const a = interp.allocator;
    const cls = interp.dataclasses_factory_class.?;
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "frozen", Value{ .boolean = frozen });
    return Value{ .instance = inst };
}

fn fieldsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const cls: *Class = switch (args[0]) {
        .class => |c| c,
        .instance => |i| i.cls,
        else => return error.TypeError,
    };
    const fv = cls.lookup("__dc_fields__") orelse {
        try interp.raisePy("TypeError", "fields() called on non-dataclass");
        return error.PyException;
    };
    if (fv != .list) return Value{ .tuple = try Tuple.init(a, 0) };
    const items = fv.list.items.items;
    const t = try Tuple.init(a, items.len);
    for (items, 0..) |item, i| t.items[i] = item;
    return Value{ .tuple = t };
}

fn asdictFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const fv = inst.cls.lookup("__dc_fields__") orelse return Value{ .dict = try Dict.init(a) };
    if (fv != .list) return Value{ .dict = try Dict.init(a) };
    const d = try Dict.init(a);
    for (fv.list.items.items) |field_v| {
        if (field_v != .instance) continue;
        const fname_v = field_v.instance.dict.getStr("name") orelse continue;
        if (fname_v != .str) continue;
        const fname = fname_v.str.bytes;
        const val = inst.dict.getStr(fname) orelse Value.none;
        try d.setStr(a, fname, val);
    }
    return Value{ .dict = d };
}

fn astupleFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const fv = inst.cls.lookup("__dc_fields__") orelse return Value{ .tuple = try Tuple.init(a, 0) };
    if (fv != .list) return Value{ .tuple = try Tuple.init(a, 0) };
    const fields = fv.list.items.items;
    const t = try Tuple.init(a, fields.len);
    for (fields, 0..) |field_v, i| {
        if (field_v != .instance) { t.items[i] = Value.none; continue; }
        const fname_v = field_v.instance.dict.getStr("name") orelse { t.items[i] = Value.none; continue; };
        if (fname_v != .str) { t.items[i] = Value.none; continue; }
        t.items[i] = inst.dict.getStr(fname_v.str.bytes) orelse Value.none;
    }
    return Value{ .tuple = t };
}

fn isDataclassFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    const cls: ?*Class = switch (args[0]) {
        .class => |c| c,
        .instance => |i| i.cls,
        else => null,
    };
    if (cls == null) return Value{ .boolean = false };
    return Value{ .boolean = cls.?.lookup("__dataclass__") != null };
}

fn replaceFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return replaceImpl(p, args, &.{}, &.{});
}

fn replaceKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return replaceImpl(p, args, kn, kv);
}

fn replaceImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const src = args[0].instance;
    const cls = src.cls;
    const new_inst = try Instance.init(a, cls);
    // copy all fields from src, then override with kwargs
    const fv = cls.lookup("__dc_fields__") orelse return Value{ .instance = new_inst };
    if (fv == .list) {
        for (fv.list.items.items) |field_v| {
            if (field_v != .instance) continue;
            const fname_v = field_v.instance.dict.getStr("name") orelse continue;
            if (fname_v != .str) continue;
            const fname = fname_v.str.bytes;
            var val = src.dict.getStr(fname) orelse Value.none;
            // check if overridden by kwarg
            for (kn, kv) |nm, vl| {
                if (nm == .str and std.mem.eql(u8, nm.str.bytes, fname)) {
                    val = vl;
                    break;
                }
            }
            try new_inst.dict.setStr(a, fname, val);
        }
    }
    return Value{ .instance = new_inst };
}

// ===== reg helpers =====

fn reg(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "dataclasses");

    // Field class
    if (interp.dataclasses_field_class == null)
        interp.dataclasses_field_class = try buildFieldClass(interp);
    try m.attrs.setStr(a, "Field", Value{ .class = interp.dataclasses_field_class.? });

    // DataclassFactory class (returned by @dataclass(frozen=True))
    if (interp.dataclasses_factory_class == null) {
        const d = try Dict.init(a);
        const f = try a.create(BuiltinFn);
        f.* = .{ .name = "__call__", .func = factoryCall };
        try d.setStr(a, "__call__", Value{ .builtin_fn = f });
        interp.dataclasses_factory_class = try Class.init(a, "_DataclassDecorator", &.{}, d);
    }

    // dataclass decorator
    regKw(a, m, "dataclass", dataclassFn, dataclassKw) catch {};

    // module functions
    reg(a, m, "fields", fieldsFn) catch {};
    reg(a, m, "asdict", asdictFn) catch {};
    reg(a, m, "astuple", astupleFn) catch {};
    reg(a, m, "is_dataclass", isDataclassFn) catch {};
    try regKw(a, m, "replace", replaceFn, replaceKw);
    try regKw(a, m, "field", fieldFn, fieldKw);

    // MISSING sentinel
    try m.attrs.setStr(a, "MISSING", Value.none);

    return m;
}
