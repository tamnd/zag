//! `abc` module: ABC, ABCMeta, abstractmethod, get_cache_token.
//!
//! `abstractmethod(fn)` wraps the function in an Instance whose class
//! carries `__isabstractmethod__ = True`. `buildClassKw` in dispatch.zig
//! scans the class namespace for such instances to compute
//! `__abstractmethods__`, and `instantiate` refuses to create an object
//! from a class that still has unresolved abstract methods.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Dict = @import("../object/dict.zig").Dict;
const Descriptor = @import("../object/descriptor.zig").Descriptor;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "abc");

    // ABC sentinel class -- user classes inherit from it to opt in.
    const abc_dict = try Dict.init(a);
    // Install a register classmethod on ABC itself so user classes that
    // inherit it also pick it up via MRO.
    const reg_fn = try a.create(BuiltinFn);
    reg_fn.* = .{ .name = "register", .func = abcRegister };
    const reg_desc = try Descriptor.init(a, .classmethod, Value{ .builtin_fn = reg_fn });
    try abc_dict.setStr(a, "register", Value{ .descriptor = reg_desc });
    const abc_cls = try Class.init(a, "ABC", &.{}, abc_dict);
    interp.abc_abc_class = abc_cls;
    try m.attrs.setStr(a, "ABC", Value{ .class = abc_cls });

    // ABCMeta sentinel class.
    const abcmeta_dict = try Dict.init(a);
    const reg_fn2 = try a.create(BuiltinFn);
    reg_fn2.* = .{ .name = "register", .func = abcRegister };
    const reg_desc2 = try Descriptor.init(a, .classmethod, Value{ .builtin_fn = reg_fn2 });
    try abcmeta_dict.setStr(a, "register", Value{ .descriptor = reg_desc2 });
    const abcmeta_cls = try Class.init(a, "ABCMeta", &.{}, abcmeta_dict);
    interp.abc_abcmeta_class = abcmeta_cls;
    try m.attrs.setStr(a, "ABCMeta", Value{ .class = abcmeta_cls });

    // abstractmethod builtin
    const am_fn = try a.create(BuiltinFn);
    am_fn.* = .{ .name = "abstractmethod", .func = abstractmethodBuiltin };
    try m.attrs.setStr(a, "abstractmethod", Value{ .builtin_fn = am_fn });

    // abstractclassmethod / abstractstaticmethod -- same wrapper for now
    const acm_fn = try a.create(BuiltinFn);
    acm_fn.* = .{ .name = "abstractclassmethod", .func = abstractmethodBuiltin };
    try m.attrs.setStr(a, "abstractclassmethod", Value{ .builtin_fn = acm_fn });

    const asm_fn = try a.create(BuiltinFn);
    asm_fn.* = .{ .name = "abstractstaticmethod", .func = abstractmethodBuiltin };
    try m.attrs.setStr(a, "abstractstaticmethod", Value{ .builtin_fn = asm_fn });

    // get_cache_token returns 0 (we don't track the ABC invalidation token)
    const gct_fn = try a.create(BuiltinFn);
    gct_fn.* = .{ .name = "get_cache_token", .func = getCacheToken };
    try m.attrs.setStr(a, "get_cache_token", Value{ .builtin_fn = gct_fn });

    interp.abc_module = m;
    return m;
}

/// `abstractmethod(fn)` returns an Instance whose class has
/// `__isabstractmethod__ = True`. The Instance also stores the
/// original callable as `__wrapped__` so the MRO scan in
/// `buildClassKw` can retrieve the function name from the code object
/// when needed.
fn abstractmethodBuiltin(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 1) {
        try interp.typeError("abstractmethod() takes exactly one argument");
        return error.TypeError;
    }
    // Ensure the abstract-wrapper class exists (lazy, cached on interp).
    const wrapper_cls = try getOrCreateWrapperClass(interp);
    const inst = try Instance.init(interp.allocator, wrapper_cls);
    // Mark the instance itself as abstract.
    try inst.dict.setStr(interp.allocator, "__isabstractmethod__", Value{ .boolean = true });
    // Preserve the wrapped callable.
    try inst.dict.setStr(interp.allocator, "__wrapped__", args[0]);
    return Value{ .instance = inst };
}

/// Lazy singleton: a Class named "__AbstractMethod__" with
/// `__isabstractmethod__ = True` in its own dict (the class-level flag)
/// and a `__call__` that delegates to `__wrapped__`.
fn getOrCreateWrapperClass(interp: *Interp) !*Class {
    // We re-use `abc_abc_class` as the parent of the wrapper so that
    // `isinstance(wrapper, ABC)` doesn't interfere. Instead we keep the
    // wrapper class in a private field.
    // We store it as the first entry in the abc_module's attrs under a
    // private key, or simply inline here using a static pointer cached
    // in the module dict.
    const m = interp.abc_module orelse return error.NameError;
    const sentinel = "__abstract_wrapper_class__";
    if (m.attrs.getStr(sentinel)) |v| {
        if (v == .class) return v.class;
    }
    const a = interp.allocator;
    const cls_dict = try Dict.init(a);
    // The class carries `__isabstractmethod__ = True` so the MRO scan in
    // buildClassKw can detect wrapper instances by checking their class dict.
    try cls_dict.setStr(a, "__isabstractmethod__", Value{ .boolean = true });
    // Install a __call__ builtin so wrapper instances are callable.
    const call_fn = try a.create(BuiltinFn);
    call_fn.* = .{ .name = "__call__", .func = wrapperCall };
    try cls_dict.setStr(a, "__call__", Value{ .builtin_fn = call_fn });
    const cls = try Class.init(a, "__AbstractMethod__", &.{}, cls_dict);
    try m.attrs.setStr(a, sentinel, Value{ .class = cls });
    return cls;
}

/// `wrapper_instance(*args)`: delegate to `wrapper_instance.__wrapped__(*args)`.
fn wrapperCall(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len == 0 or args[0] != .instance) {
        try interp.typeError("abstract method wrapper called without self");
        return error.TypeError;
    }
    const self = args[0].instance;
    const wrapped = self.dict.getStr("__wrapped__") orelse {
        try interp.typeError("abstract method has no __wrapped__");
        return error.TypeError;
    };
    return try @import("dispatch.zig").invoke(interp, wrapped, args[1..]);
}

/// `register(cls, subclass)` -- registers `subclass` as a virtual
/// subclass of `cls`. Works for any class (not just ones with abc_kind).
pub fn abcRegister(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 2 or args[0] != .class or args[1] != .class) {
        try interp.typeError("register expects (abc_class, target_class)");
        return error.TypeError;
    }
    const abc_cls = args[0].class;
    try abc_cls.abc_registered.append(interp.allocator, args[1].class);
    return args[1];
}

fn getCacheToken(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    _ = opaque_interp;
    _ = args;
    return Value{ .small_int = 0 };
}

/// Return true if `v` is an abstractmethod wrapper instance (i.e. it was
/// returned by `abstractmethod(fn)`). Called from `buildClassKw`.
pub fn isAbstractWrapper(v: Value) bool {
    if (v != .instance) return false;
    // Check __isabstractmethod__ on the instance dict.
    if (v.instance.dict.getStr("__isabstractmethod__")) |flag| {
        return flag == .boolean and flag.boolean;
    }
    return false;
}
