//! Pinhole `collections.abc` module: each ABC is a class with a
//! non-null `abc_kind`. `isinstance(obj, abc)` first walks `obj`'s
//! MRO looking for the abc itself or anything registered via
//! `abc.register(cls)`; built-in types are then matched by the
//! virtual-registration table baked into `builtinAbcMember`; finally,
//! the ABCs that ship with a `__subclasshook__` in CPython
//! (`Hashable`, `Iterable`, `Iterator`, `Reversible`, `Sized`,
//! `Container`, `Callable`, `Collection`, `Awaitable`,
//! `AsyncIterable`, `AsyncIterator`, `Buffer`) get a structural
//! check on the user instance's class. The remaining ABCs
//! (`Sequence`, `Mapping`, `MutableMapping`, ...) require explicit
//! inheritance or registration, matching CPython.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Class = @import("../object/class.zig").Class;
const AbcKind = @import("../object/class.zig").AbcKind;
const Instance = @import("../object/instance.zig").Instance;
const Dict = @import("../object/dict.zig").Dict;
const Descriptor = @import("../object/descriptor.zig").Descriptor;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "collections.abc");
    try registerAbc(interp, m, "Hashable", .hashable);
    try registerAbc(interp, m, "Callable", .callable);
    try registerAbc(interp, m, "Iterable", .iterable);
    try registerAbc(interp, m, "Iterator", .iterator);
    try registerAbc(interp, m, "Generator", .generator);
    try registerAbc(interp, m, "Reversible", .reversible);
    try registerAbc(interp, m, "Sized", .sized);
    try registerAbc(interp, m, "Container", .container);
    try registerAbc(interp, m, "Collection", .collection);
    try registerAbc(interp, m, "Sequence", .sequence);
    try registerAbc(interp, m, "MutableSequence", .mutable_sequence);
    try registerAbc(interp, m, "Set", .set_);
    try registerAbc(interp, m, "MutableSet", .mutable_set);
    try registerAbc(interp, m, "Mapping", .mapping);
    try registerAbc(interp, m, "MutableMapping", .mutable_mapping);
    try registerAbc(interp, m, "MappingView", .mapping_view);
    try registerAbc(interp, m, "KeysView", .keys_view);
    try registerAbc(interp, m, "ItemsView", .items_view);
    try registerAbc(interp, m, "ValuesView", .values_view);
    try registerAbc(interp, m, "Awaitable", .awaitable);
    try registerAbc(interp, m, "Coroutine", .coroutine);
    try registerAbc(interp, m, "AsyncIterable", .async_iterable);
    try registerAbc(interp, m, "AsyncIterator", .async_iterator);
    try registerAbc(interp, m, "AsyncGenerator", .async_generator);
    try registerAbc(interp, m, "Buffer", .buffer);
    return m;
}

fn registerAbc(interp: *Interp, m: *Module, name: []const u8, kind: AbcKind) !void {
    const a = interp.allocator;
    const dict = try Dict.init(a);
    const cls = try Class.init(a, name, &.{}, dict);
    cls.abc_kind = kind;
    const reg_fn = try a.create(BuiltinFn);
    reg_fn.* = .{ .name = "register", .func = abcRegister };
    const reg_desc = try Descriptor.init(a, .classmethod, Value{ .builtin_fn = reg_fn });
    try dict.setStr(a, "register", Value{ .descriptor = reg_desc });
    try m.attrs.setStr(a, name, Value{ .class = cls });
}

fn abcRegister(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 2 or args[0] != .class or args[1] != .class) {
        try interp.typeError("register expects (abc_class, target_class)");
        return error.TypeError;
    }
    const abc_cls = args[0].class;
    if (abc_cls.abc_kind == null) {
        try interp.typeError("register requires an ABC class");
        return error.TypeError;
    }
    try abc_cls.abc_registered.append(interp.allocator, args[1].class);
    return args[1];
}

/// `isinstance(v, abc)` core: mro walk for direct/registered subclasses,
/// then a virtual-registration table for built-in types, then a
/// structural `__subclasshook__` for the ABCs that ship one.
pub fn isInstanceOfAbc(abc: *Class, v: Value) bool {
    const kind = abc.abc_kind orelse return false;
    if (v == .instance) {
        for (v.instance.cls.mro) |c| if (c == abc) return true;
        for (abc.abc_registered.items) |reg| {
            for (v.instance.cls.mro) |c| if (c == reg) return true;
        }
    }
    if (builtinAbcMember(v, kind)) return true;
    if (v == .instance and instanceAbcStructural(v.instance, kind)) return true;
    return false;
}

fn builtinAbcMember(v: Value, kind: AbcKind) bool {
    return switch (kind) {
        .hashable => switch (v) {
            .list, .dict, .bytearray, .deque, .counter, .defaultdict, .ordered_dict => false,
            .set => |s| s.frozen,
            .instance, .module, .class, .function, .builtin_fn, .bound_method, .partial, .cached_fn, .cached_property, .descriptor, .named_tuple, .named_tuple_factory => false,
            else => true,
        },
        .callable => switch (v) {
            .function, .builtin_fn, .class, .bound_method, .partial, .cached_fn, .named_tuple_factory, .descriptor => true,
            else => false,
        },
        .iterable, .container, .sized, .collection => switch (v) {
            .list, .tuple, .str, .dict, .set, .bytes, .bytearray => true,
            .iter, .generator, .enum_iter => true,
            .deque, .counter, .defaultdict, .ordered_dict => true,
            else => false,
        },
        .iterator => switch (v) {
            .iter, .generator, .enum_iter => true,
            else => false,
        },
        .generator => v == .generator,
        .reversible => switch (v) {
            .list, .tuple, .str, .bytes, .bytearray => true,
            .iter => |it| switch (it.kind) {
                .range => true,
                else => false,
            },
            .dict, .deque, .ordered_dict => true,
            else => false,
        },
        .sequence => switch (v) {
            .list, .tuple, .str, .bytes, .bytearray => true,
            .iter => |it| switch (it.kind) {
                .range => true,
                else => false,
            },
            else => false,
        },
        .mutable_sequence => switch (v) {
            .list, .bytearray => true,
            else => false,
        },
        .set_ => v == .set,
        .mutable_set => switch (v) {
            .set => |s| !s.frozen,
            else => false,
        },
        .mapping => switch (v) {
            .dict, .counter, .defaultdict, .ordered_dict => true,
            else => false,
        },
        .mutable_mapping => switch (v) {
            .dict, .counter, .defaultdict, .ordered_dict => true,
            else => false,
        },
        .buffer => switch (v) {
            .bytes, .bytearray, .memoryview => true,
            else => false,
        },
        .mapping_view, .keys_view, .items_view, .values_view => false,
        .awaitable, .coroutine, .async_iterable, .async_iterator, .async_generator => false,
        .number, .complex_ => switch (v) {
            .small_int, .big_int, .float, .complex_num, .boolean => true,
            else => false,
        },
        .real => switch (v) {
            .small_int, .big_int, .float, .boolean => true,
            else => false,
        },
        .rational, .integral => switch (v) {
            .small_int, .big_int, .boolean => true,
            else => false,
        },
    };
}

/// Structural fallbacks for the ABCs whose CPython `__subclasshook__`
/// returns True when the candidate class supplies the protocol's
/// dunders. ABCs without a hook (Sequence, Mapping, ...) end up
/// returning false here, matching CPython.
fn instanceAbcStructural(inst: *Instance, kind: AbcKind) bool {
    return switch (kind) {
        .hashable => blk: {
            if (inst.cls.lookup("__hash__")) |hv| break :blk hv != .none;
            break :blk true;
        },
        .iterable => inst.cls.lookup("__iter__") != null,
        .iterator => inst.cls.lookup("__iter__") != null and inst.cls.lookup("__next__") != null,
        .reversible => inst.cls.lookup("__reversed__") != null and inst.cls.lookup("__iter__") != null,
        .sized => inst.cls.lookup("__len__") != null,
        .container => inst.cls.lookup("__contains__") != null,
        .callable => inst.cls.lookup("__call__") != null,
        .collection => inst.cls.lookup("__iter__") != null and
            inst.cls.lookup("__contains__") != null and
            inst.cls.lookup("__len__") != null,
        .awaitable => inst.cls.lookup("__await__") != null,
        .async_iterable => inst.cls.lookup("__aiter__") != null,
        .async_iterator => inst.cls.lookup("__aiter__") != null and inst.cls.lookup("__anext__") != null,
        .buffer => inst.cls.lookup("__buffer__") != null,
        else => false,
    };
}
