//! Pinhole `typing`. TypeVar, cast, TYPE_CHECKING, NamedTuple,
//! TypedDict, Optional/Union/Any/List/Dict/Tuple/Set.

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
const NamedTupleFactory = @import("../object/named_tuple.zig").NamedTupleFactory;

// ===== GenericAlias (returned by Optional[X], Union[X,Y], List[X], etc.) =====

fn genericAliasGetitem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    // Return a simple instance wrapping the type args
    const cls = interp.typing_generic_alias_class.?;
    const inst = try Instance.init(a, cls);
    if (args.len >= 1) try inst.dict.setStr(a, "__origin__", args[0]);
    if (args.len >= 2) try inst.dict.setStr(a, "__args__", args[1]);
    return Value{ .instance = inst };
}

fn genericEq(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2) return Value{ .boolean = false };
    // Two generic aliases are "equal" if they have the same representation.
    // For our simplified purposes, just check identity.
    return Value{ .boolean = args[0].equals(args[1]) };
}

// ===== TypeVar =====

fn typeVarFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const cls = interp.typing_typevar_class.?;
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "__name__", args[0]);
    try inst.dict.setStr(a, "name", args[0]);
    return Value{ .instance = inst };
}

// ===== cast =====

fn castFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2) return Value.none;
    return args[1]; // runtime no-op
}

// ===== TypedDict =====

fn typedDictFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return typedDictImpl(p, args, &.{}, &.{});
}

fn typedDictKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return typedDictImpl(p, args, kn, kv);
}

fn typedDictImpl(p: *anyopaque, args: []const Value, _kn: []const Value, _kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = _kn;
    _ = _kv;
    // TypedDict(name, fields) → returns a class that, when called, creates a dict
    const name: []const u8 = if (args.len >= 1 and args[0] == .str) args[0].str.bytes else "TypedDict";
    const d = try Dict.init(a);
    try d.setStr(a, "__typed_dict__", Value{ .boolean = true });
    const cls = try Class.init(a, name, &.{}, d);
    return Value{ .class = cls };
}

// ===== class_getitem helpers =====

fn classGetitem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    // Returns a GenericAlias instance
    const alias_cls = interp.typing_generic_alias_class.?;
    const inst = try Instance.init(a, alias_cls);
    if (args.len >= 1) try inst.dict.setStr(a, "__origin__", args[0]);
    if (args.len >= 2) try inst.dict.setStr(a, "__args__", args[1]);
    return Value{ .instance = inst };
}

// ===== NamedTuple subclass detection =====

// Called from buildClass when NamedTuple is a base.
pub fn processNamedTupleSubclass(interp: *Interp, cls: *Class) !?Value {
    const nt_cls = interp.typing_namedtuple_class orelse return null;
    // Check if any base is the NamedTuple sentinel
    var is_nt = false;
    for (cls.bases) |base| {
        if (base == nt_cls) { is_nt = true; break; }
    }
    if (!is_nt) return null;

    const a = interp.allocator;
    // Extract field names from __annotate_func__
    const af_v = cls.dict.getStr("__annotate_func__") orelse return Value{ .class = cls };
    if (af_v != .function) return Value{ .class = cls };
    const code = af_v.function.code;

    var field_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer field_names.deinit(a);
    var defaults: std.ArrayListUnmanaged(Value) = .empty;
    defer defaults.deinit(a);

    if (code.consts.len >= 2) {
        for (code.consts[1..]) |cv| {
            if (cv == .str) {
                try field_names.append(a, cv.str.bytes);
            }
        }
    }

    // Collect defaults in REVERSE order (trailing fields with defaults)
    // Python's namedtuple stores defaults for trailing fields only.
    // Defaults are class attributes in the class dict.
    for (field_names.items) |fname| {
        if (cls.dict.getStr(fname)) |dv| {
            try defaults.append(a, dv);
        }
    }

    // Build owned copies
    const owned_name = try a.dupe(u8, cls.name);
    const owned_fields = try a.alloc([]const u8, field_names.items.len);
    for (field_names.items, 0..) |fname, i| {
        owned_fields[i] = try a.dupe(u8, fname);
    }

    const owned_defaults = try a.dupe(Value, defaults.items);
    const factory = try NamedTupleFactory.initWithDefaults(a, owned_name, owned_fields, owned_defaults);
    return Value{ .named_tuple_factory = factory };
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

fn regClassGetitem(a: std.mem.Allocator, cls: *Class) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = "__class_getitem__", .func = classGetitem };
    try cls.dict.setStr(a, "__class_getitem__", Value{ .builtin_fn = f });
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "typing");

    // GenericAlias class
    if (interp.typing_generic_alias_class == null) {
        const d = try Dict.init(a);
        interp.typing_generic_alias_class = try Class.init(a, "_GenericAlias", &.{}, d);
    }

    // TypeVar class
    if (interp.typing_typevar_class == null) {
        const d = try Dict.init(a);
        interp.typing_typevar_class = try Class.init(a, "TypeVar", &.{}, d);
    }
    try reg(a, m, "TypeVar", typeVarFn);

    // cast
    try reg(a, m, "cast", castFn);

    // TYPE_CHECKING = False
    try m.attrs.setStr(a, "TYPE_CHECKING", Value{ .boolean = false });

    // Any
    if (interp.typing_any == null) {
        const d = try Dict.init(a);
        const cls = try Class.init(a, "Any", &.{}, d);
        interp.typing_any = Value{ .class = cls };
    }
    try m.attrs.setStr(a, "Any", interp.typing_any.?);

    // Optional, Union (subscriptable forms)
    {
        const mk = struct {
            fn make(aa: std.mem.Allocator, cname: []const u8) !*Class {
                const d = try Dict.init(aa);
                const cls = try Class.init(aa, cname, &.{}, d);
                try regClassGetitem(aa, cls);
                return cls;
            }
        };
        if (interp.typing_optional_class == null)
            interp.typing_optional_class = try mk.make(a, "Optional");
        if (interp.typing_union_class == null)
            interp.typing_union_class = try mk.make(a, "Union");
        try m.attrs.setStr(a, "Optional", Value{ .class = interp.typing_optional_class.? });
        try m.attrs.setStr(a, "Union", Value{ .class = interp.typing_union_class.? });
    }

    // List, Dict, Tuple, Set, FrozenSet, Type, Callable, Iterator, Iterable
    {
        const aliases = &[_]struct { []const u8, []const u8 }{
            .{ "List", "List" }, .{ "Dict", "Dict" }, .{ "Tuple", "Tuple" },
            .{ "Set", "Set" }, .{ "FrozenSet", "FrozenSet" },
            .{ "Type", "Type" }, .{ "Callable", "Callable" },
            .{ "Iterator", "Iterator" }, .{ "Iterable", "Iterable" },
            .{ "Sequence", "Sequence" }, .{ "Mapping", "Mapping" },
            .{ "MutableMapping", "MutableMapping" }, .{ "MutableSequence", "MutableSequence" },
            .{ "Awaitable", "Awaitable" }, .{ "Coroutine", "Coroutine" },
            .{ "Generator", "Generator" }, .{ "AsyncGenerator", "AsyncGenerator" },
            .{ "ClassVar", "ClassVar" }, .{ "Final", "Final" },
        };
        for (aliases) |pair| {
            const d = try Dict.init(a);
            const cls = try Class.init(a, pair[1], &.{}, d);
            try regClassGetitem(a, cls);
            try m.attrs.setStr(a, pair[0], Value{ .class = cls });
        }
    }

    // NamedTuple (sentinel class)
    if (interp.typing_namedtuple_class == null) {
        const d = try Dict.init(a);
        try d.setStr(a, "__typing_namedtuple__", Value{ .boolean = true });
        interp.typing_namedtuple_class = try Class.init(a, "NamedTuple", &.{}, d);
    }
    try m.attrs.setStr(a, "NamedTuple", Value{ .class = interp.typing_namedtuple_class.? });

    // TypedDict
    try regKw(a, m, "TypedDict", typedDictFn, typedDictKw);

    // overload, no_type_check, get_type_hints, runtime_checkable, Protocol
    // (stubs that return their arg or no-op)
    try m.attrs.setStr(a, "overload", try stubDecorator(a));
    try m.attrs.setStr(a, "no_type_check", try stubDecorator(a));
    try m.attrs.setStr(a, "runtime_checkable", try stubDecorator(a));
    try m.attrs.setStr(a, "final", try stubDecorator(a));

    // get_type_hints
    try reg(a, m, "get_type_hints", getTypeHintsFn);

    // Protocol
    {
        const d = try Dict.init(a);
        try regClassGetitem(a, try Class.init(a, "Protocol", &.{}, d));
        try m.attrs.setStr(a, "Protocol", Value{ .class = try Class.init(a, "Protocol", &.{}, d) });
    }

    // Generic
    {
        const d = try Dict.init(a);
        try regClassGetitem(a, try Class.init(a, "Generic", &.{}, d));
        try m.attrs.setStr(a, "Generic", Value{ .class = try Class.init(a, "Generic", &.{}, d) });
    }

    // MISSING from stdlib but often imported
    try m.attrs.setStr(a, "IO", try makeAlias(a, "IO"));
    try m.attrs.setStr(a, "TextIO", try makeAlias(a, "TextIO"));
    try m.attrs.setStr(a, "BinaryIO", try makeAlias(a, "BinaryIO"));
    try m.attrs.setStr(a, "Pattern", try makeAlias(a, "Pattern"));
    try m.attrs.setStr(a, "Match", try makeAlias(a, "Match"));
    try m.attrs.setStr(a, "AnyStr", Value{ .instance = try typeVarInst(interp, "AnyStr") });
    try m.attrs.setStr(a, "T", Value{ .instance = try typeVarInst(interp, "T") });

    return m;
}

fn stubDecorator(a: std.mem.Allocator) !Value {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = "stub", .func = identityFn };
    return Value{ .builtin_fn = f };
}

fn identityFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len >= 1) return args[0];
    return Value.none;
}

fn makeAlias(a: std.mem.Allocator, name: []const u8) !Value {
    const d = try Dict.init(a);
    const cls = try Class.init(a, name, &.{}, d);
    try regClassGetitem(a, cls);
    return Value{ .class = cls };
}

fn typeVarInst(interp: *Interp, name: []const u8) !*Instance {
    const a = interp.allocator;
    const cls = interp.typing_typevar_class.?;
    const inst = try Instance.init(a, cls);
    const s = try Str.init(a, name);
    try inst.dict.setStr(a, "__name__", Value{ .str = s });
    try inst.dict.setStr(a, "name", Value{ .str = s });
    return inst;
}

fn getTypeHintsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return Value{ .dict = try Dict.init(a) };
    const cls: *Class = switch (args[0]) {
        .class => |c| c,
        .instance => |i| i.cls,
        else => return Value{ .dict = try Dict.init(a) },
    };
    // Extract from __annotate_func__ like dataclasses does
    const af_v = cls.dict.getStr("__annotate_func__") orelse return Value{ .dict = try Dict.init(a) };
    if (af_v != .function) return Value{ .dict = try Dict.init(a) };
    const code = af_v.function.code;
    const d = try Dict.init(a);
    for (code.consts[1..]) |cv| {
        if (cv == .str) try d.setStr(a, cv.str.bytes, Value.none);
    }
    return Value{ .dict = d };
}
