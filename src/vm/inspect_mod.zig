//! Pinhole `inspect` module: isfunction, isclass, isbuiltin, ismodule,
//! ismethod, getmembers. Enough to pass the fixture.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

fn isFunctionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    return Value{ .boolean = args[0] == .function };
}

fn isClassFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    return Value{ .boolean = args[0] == .class };
}

fn isBuiltinFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    return Value{ .boolean = args[0] == .builtin_fn };
}

fn isModuleFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    return Value{ .boolean = args[0] == .module };
}

fn isMethodFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    return Value{ .boolean = args[0] == .bound_method };
}

fn isRoutineFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    return Value{ .boolean = args[0] == .function or args[0] == .builtin_fn or args[0] == .bound_method };
}

fn isCallableFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    return Value{
        .boolean = switch (args[0]) {
            .function, .builtin_fn, .bound_method, .class, .named_tuple_factory => true,
            .instance => |i| i.cls.lookup("__call__") != null,
            else => false,
        },
    };
}

fn isGeneratorFunctionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    if (args[0] == .function) {
        const CO_GENERATOR: i32 = 0x20;
        return Value{ .boolean = args[0].function.code.flags & CO_GENERATOR != 0 };
    }
    return Value{ .boolean = false };
}

fn isGeneratorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    return Value{ .boolean = args[0] == .generator };
}

fn isCoroutineFunctionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    if (args[0] == .function) {
        const CO_COROUTINE: i32 = 0x100;
        return Value{ .boolean = args[0].function.code.flags & CO_COROUTINE != 0 };
    }
    return Value{ .boolean = false };
}

fn isFrameFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value{ .boolean = false };
    if (args[0] == .instance) {
        return Value{ .boolean = std.mem.eql(u8, args[0].instance.cls.name, "frame") };
    }
    return Value{ .boolean = false };
}

/// getmembers(obj, predicate=None) → sorted list of (name, value) tuples
fn getMembersFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return Value{ .list = try List.init(a) };
    const obj = args[0];
    const predicate = if (args.len >= 2) args[1] else Value.none;

    const lst = try List.init(a);

    // Collect (name, value) pairs from the object
    switch (obj) {
        .module => |m| {
            for (m.attrs.pairs.items) |pair| {
                if (pair.key != .str) continue;
                const val = pair.value;
                if (predicate != .none) {
                    const keep = try dispatch.invoke(interp, predicate, &.{val});
                    if (keep == .boolean and !keep.boolean) continue;
                    if (keep == .none) continue;
                }
                const t = try Tuple.init(a, 2);
                t.items[0] = pair.key;
                t.items[1] = val;
                try lst.items.append(a, Value{ .tuple = t });
            }
        },
        .class => |cls| {
            for (cls.dict.pairs.items) |pair| {
                if (pair.key != .str) continue;
                const val = pair.value;
                if (predicate != .none) {
                    const keep = try dispatch.invoke(interp, predicate, &.{val});
                    if (keep == .boolean and !keep.boolean) continue;
                    if (keep == .none) continue;
                }
                const t = try Tuple.init(a, 2);
                t.items[0] = pair.key;
                t.items[1] = val;
                try lst.items.append(a, Value{ .tuple = t });
            }
        },
        .instance => |inst| {
            for (inst.dict.pairs.items) |pair| {
                if (pair.key != .str) continue;
                const val = pair.value;
                if (predicate != .none) {
                    const keep = try dispatch.invoke(interp, predicate, &.{val});
                    if (keep == .boolean and !keep.boolean) continue;
                }
                const t = try Tuple.init(a, 2);
                t.items[0] = pair.key;
                t.items[1] = val;
                try lst.items.append(a, Value{ .tuple = t });
            }
        },
        else => {},
    }

    // Sort by name
    std.sort.block(Value, lst.items.items, {}, struct {
        fn lessThan(_: void, lhs: Value, rhs: Value) bool {
            if (lhs != .tuple or rhs != .tuple) return false;
            if (lhs.tuple.items.len < 1 or rhs.tuple.items.len < 1) return false;
            const la = lhs.tuple.items[0];
            const ra = rhs.tuple.items[0];
            if (la != .str or ra != .str) return false;
            return std.mem.lessThan(u8, la.str.bytes, ra.str.bytes);
        }
    }.lessThan);

    return Value{ .list = lst };
}

/// getdoc(obj) → None (stub)
fn getDocFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value.none;
}

/// signature(obj) → stub str
fn signatureFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    return Value{ .str = try Str.init(interp.allocator, "(*args, **kwargs)") };
}

fn reg(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "inspect");

    try reg(a, m, "isfunction", isFunctionFn);
    try reg(a, m, "isclass", isClassFn);
    try reg(a, m, "isbuiltin", isBuiltinFn);
    try reg(a, m, "ismodule", isModuleFn);
    try reg(a, m, "ismethod", isMethodFn);
    try reg(a, m, "isroutine", isRoutineFn);
    try reg(a, m, "iscoroutinefunction", isCoroutineFunctionFn);
    try reg(a, m, "isgeneratorfunction", isGeneratorFunctionFn);
    try reg(a, m, "isgenerator", isGeneratorFn);
    try reg(a, m, "isframe", isFrameFn);
    try reg(a, m, "iscallable", isCallableFn);
    try reg(a, m, "getmembers", getMembersFn);
    try reg(a, m, "getdoc", getDocFn);
    try reg(a, m, "signature", signatureFn);

    return m;
}
