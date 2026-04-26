//! Pinhole `copyreg`. The fixture exercises the registration
//! surface (dispatch_table, pickle, constructor, add_extension /
//! remove_extension / clear_extension_cache) but never asks pickle
//! to consult any of it — so this is purely book-keeping with the
//! validation that the public docs guarantee.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

pub const Extension = struct {
    module: []u8,
    name: []u8,
    code: i64,
};

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "copyreg");
    if (interp.copyreg_dispatch_table == null) {
        interp.copyreg_dispatch_table = try Dict.init(a);
    }
    try m.attrs.setStr(a, "dispatch_table", Value{ .dict = interp.copyreg_dispatch_table.? });
    try reg(interp, m, "pickle", pickleFn);
    try reg(interp, m, "constructor", constructorFn);
    try reg(interp, m, "add_extension", addExtensionFn);
    try reg(interp, m, "remove_extension", removeExtensionFn);
    try reg(interp, m, "clear_extension_cache", clearExtensionCacheFn);
    try reg(interp, m, "__newobj__", newobjFn);
    try reg(interp, m, "__newobj_ex__", newobjExFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn isCallable(v: Value) bool {
    return switch (v) {
        .builtin_fn, .function, .bound_method, .partial, .cached_fn, .class, .named_tuple_factory => true,
        .instance => |inst| inst.cls.dict.getStr("__call__") != null,
        else => false,
    };
}

fn pickleFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args.len > 3) {
        try interp.raisePy("TypeError", "pickle() takes (type, reducer[, ctor])");
        return error.PyException;
    }
    if (!isCallable(args[1])) {
        try interp.raisePy("TypeError", "reduction functions must be callable");
        return error.PyException;
    }
    if (args.len == 3 and args[2] != .none and !isCallable(args[2])) {
        try interp.raisePy("TypeError", "constructors must be callable");
        return error.PyException;
    }
    const dt = interp.copyreg_dispatch_table orelse {
        try interp.raisePy("RuntimeError", "copyreg not initialized");
        return error.PyException;
    };
    try dt.setKey(interp.allocator, args[0], args[1]);
    return Value.none;
}

fn constructorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1) {
        try interp.raisePy("TypeError", "constructor() takes one argument");
        return error.PyException;
    }
    if (!isCallable(args[0])) {
        try interp.raisePy("TypeError", "constructors must be callable");
        return error.PyException;
    }
    return Value.none;
}

fn extensionEql(e: Extension, mod: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, e.module, mod) and std.mem.eql(u8, e.name, name);
}

fn addExtensionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 3 or args[0] != .str or args[1] != .str or args[2] != .small_int) {
        try interp.raisePy("TypeError", "add_extension(module, name, code) requires str, str, int");
        return error.PyException;
    }
    const mod = args[0].str.bytes;
    const name = args[1].str.bytes;
    const code = args[2].small_int;
    if (code <= 0 or code > 0x7fffffff) {
        try interp.raisePy("ValueError", "code out of range");
        return error.PyException;
    }
    const a = interp.allocator;
    // If exact triple is registered, idempotent. If the same
    // (module, name) maps to a different code, or the same code
    // maps to a different (module, name), raise ValueError.
    for (interp.copyreg_extensions.items) |e| {
        if (e.code == code and extensionEql(e, mod, name)) return Value.none;
        if (extensionEql(e, mod, name)) {
            try interp.raisePy("ValueError", "code conflict");
            return error.PyException;
        }
        if (e.code == code) {
            try interp.raisePy("ValueError", "name conflict");
            return error.PyException;
        }
    }
    const owned_mod = try a.dupe(u8, mod);
    const owned_name = try a.dupe(u8, name);
    try interp.copyreg_extensions.append(a, .{ .module = owned_mod, .name = owned_name, .code = code });
    return Value.none;
}

fn removeExtensionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 3 or args[0] != .str or args[1] != .str or args[2] != .small_int) {
        try interp.raisePy("TypeError", "remove_extension(module, name, code) requires str, str, int");
        return error.PyException;
    }
    const mod = args[0].str.bytes;
    const name = args[1].str.bytes;
    const code = args[2].small_int;
    var i: usize = 0;
    while (i < interp.copyreg_extensions.items.len) : (i += 1) {
        const e = interp.copyreg_extensions.items[i];
        if (e.code == code and extensionEql(e, mod, name)) {
            const a = interp.allocator;
            a.free(e.module);
            a.free(e.name);
            _ = interp.copyreg_extensions.orderedRemove(i);
            return Value.none;
        }
    }
    try interp.raisePy("ValueError", "extension not registered");
    return error.PyException;
}

fn clearExtensionCacheFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = interp;
    // Cache is decoupled from the registry. Nothing to drop here
    // because this implementation never populates a cache; the
    // function exists so callers can invoke it without surprise.
    return Value.none;
}

fn newobjFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) {
        try interp.raisePy("TypeError", "__newobj__ requires a class");
        return error.PyException;
    }
    const dispatch = @import("dispatch.zig");
    return dispatch.invoke(interp, args[0], args[1..]);
}

fn newobjExFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 3) {
        try interp.raisePy("TypeError", "__newobj_ex__ requires (cls, args, kwargs)");
        return error.PyException;
    }
    return Value.none;
}
