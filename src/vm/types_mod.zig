//! Pinhole `types` module. The builtin-value types (NoneType,
//! FunctionType, ModuleType, ...) are exposed as `Class` objects with
//! `value_tag` set, so `isinstance(x, types.NoneType)` reduces to a
//! tag check on `x`. SimpleNamespace and MappingProxyType are normal
//! Class+Instance classes; `new_class` returns a fresh user class.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Iter = @import("../object/iter.zig").Iter;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);

    const m = try Module.init(a, "types");
    try m.attrs.setStr(a, "NoneType", Value{ .class = interp.types_none_class.? });
    try m.attrs.setStr(a, "EllipsisType", Value{ .class = interp.types_ellipsis_class.? });
    try m.attrs.setStr(a, "NotImplementedType", Value{ .class = interp.types_not_implemented_class.? });
    try m.attrs.setStr(a, "FunctionType", Value{ .class = interp.types_function_class.? });
    try m.attrs.setStr(a, "LambdaType", Value{ .class = interp.types_function_class.? });
    try m.attrs.setStr(a, "BuiltinFunctionType", Value{ .class = interp.types_builtin_function_class.? });
    try m.attrs.setStr(a, "BuiltinMethodType", Value{ .class = interp.types_builtin_function_class.? });
    try m.attrs.setStr(a, "MethodType", Value{ .class = interp.types_method_class.? });
    try m.attrs.setStr(a, "GeneratorType", Value{ .class = interp.types_generator_class.? });
    try m.attrs.setStr(a, "ModuleType", Value{ .class = interp.types_module_class.? });
    try m.attrs.setStr(a, "SimpleNamespace", Value{ .class = interp.types_simple_namespace_class.? });
    try m.attrs.setStr(a, "MappingProxyType", Value{ .class = interp.types_mapping_proxy_class.? });
    try regModFn(interp, m, "new_class", newClassFn);
    return m;
}

fn ensureClasses(interp: *Interp) !void {
    if (interp.types_none_class != null) return;
    const a = interp.allocator;

    interp.types_none_class = try makeTagClass(a, "NoneType", .none);
    interp.types_ellipsis_class = try makeTagClass(a, "ellipsis", .ellipsis);
    interp.types_not_implemented_class = try makeTagClass(a, "NotImplementedType", .not_implemented);
    interp.types_function_class = try makeTagClass(a, "function", .function);
    interp.types_builtin_function_class = try makeTagClass(a, "builtin_function_or_method", .builtin_fn);
    interp.types_method_class = try makeTagClass(a, "method", .bound_method);
    interp.types_generator_class = try makeTagClass(a, "generator", .generator);
    interp.types_module_class = try makeTagClass(a, "module", .module);

    const sn_dict = try Dict.init(a);
    try regKw(a, sn_dict, "__init__", snInitKw);
    try reg(a, sn_dict, "__repr__", snReprFn);
    try reg(a, sn_dict, "__eq__", snEqFn);
    interp.types_simple_namespace_class = try Class.init(a, "SimpleNamespace", &.{}, sn_dict);
    interp.types_simple_namespace_class.?.qualname = "types.SimpleNamespace";

    const mp_dict = try Dict.init(a);
    try reg(a, mp_dict, "__init__", mpInitFn);
    try reg(a, mp_dict, "__getitem__", mpGetitemFn);
    try reg(a, mp_dict, "__setitem__", mpSetitemFn);
    try reg(a, mp_dict, "__delitem__", mpDelitemFn);
    try reg(a, mp_dict, "__contains__", mpContainsFn);
    try reg(a, mp_dict, "__len__", mpLenFn);
    try reg(a, mp_dict, "__iter__", mpIterFn);
    try reg(a, mp_dict, "__repr__", mpReprFn);
    try reg(a, mp_dict, "keys", mpKeysFn);
    try reg(a, mp_dict, "values", mpValuesFn);
    try reg(a, mp_dict, "items", mpItemsFn);
    try reg(a, mp_dict, "get", mpGetFn);
    try reg(a, mp_dict, "copy", mpCopyFn);
    interp.types_mapping_proxy_class = try Class.init(a, "mappingproxy", &.{}, mp_dict);
}

fn makeTagClass(a: std.mem.Allocator, name: []const u8, tag: value_mod.Tag) !*Class {
    const d = try Dict.init(a);
    const c = try Class.init(a, name, &.{}, d);
    c.value_tag = tag;
    return c;
}

fn reg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(a: std.mem.Allocator, d: *Dict, name: []const u8, comptime kw_func: BuiltinKwFnPtr) !void {
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

// ===== ModuleType call =====

/// Called by `instantiate` when the user does `types.ModuleType(name, doc=None)`.
/// Produces a real `.module` Value rather than going through Class+Instance.
pub fn moduleTypeCall(
    interp: *Interp,
    positional: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) !Value {
    if (positional.len < 1 or positional.len > 2 or positional[0] != .str) {
        try interp.typeError("ModuleType expects (name, doc=None)");
        return error.TypeError;
    }
    var doc_v: Value = Value.none;
    if (positional.len == 2) doc_v = positional[1];
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "doc")) doc_v = kv;
    }
    const name = positional[0].str.bytes;
    const m = try Module.init(interp.allocator, name);
    const name_s = try Str.init(interp.allocator, name);
    try m.attrs.setStr(interp.allocator, "__name__", Value{ .str = name_s });
    try m.attrs.setStr(interp.allocator, "__doc__", doc_v);
    return Value{ .module = m };
}

// ===== SimpleNamespace =====

fn snInitKw(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) {
        try interp.typeError("SimpleNamespace expects self");
        return error.TypeError;
    }
    if (args.len > 1) {
        try interp.typeError("SimpleNamespace takes no positional arguments");
        return error.TypeError;
    }
    const inst = args[0].instance;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        try inst.dict.setStr(interp.allocator, kn.str.bytes, kv);
    }
    return Value.none;
}

fn snReprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) {
        try interp.typeError("SimpleNamespace.__repr__ expects self");
        return error.TypeError;
    }
    const inst = args[0].instance;
    var w = std.Io.Writer.Allocating.init(interp.allocator);
    try w.writer.writeAll("namespace(");
    var first = true;
    for (inst.dict.pairs.items) |pair| {
        if (pair.key != .str) continue;
        if (!first) try w.writer.writeAll(", ");
        first = false;
        try w.writer.print("{s}=", .{pair.key.str.bytes});
        try pair.value.writeRepr(&w.writer);
    }
    try w.writer.writeAll(")");
    const s = try Str.init(interp.allocator, w.written());
    return Value{ .str = s };
}

fn snEqFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2) {
        try interp.typeError("SimpleNamespace.__eq__ expects (self, other)");
        return error.TypeError;
    }
    if (args[0] != .instance or args[1] != .instance) return Value{ .boolean = false };
    const a = args[0].instance;
    const b = args[1].instance;
    if (a.cls != b.cls) return Value{ .boolean = false };
    if (a.dict.pairs.items.len != b.dict.pairs.items.len) return Value{ .boolean = false };
    for (a.dict.pairs.items) |pair| {
        const other = b.dict.getKey(pair.key) orelse return Value{ .boolean = false };
        if (!pair.value.equals(other)) return Value{ .boolean = false };
    }
    return Value{ .boolean = true };
}

// ===== MappingProxyType =====

fn mpDictOf(self: *Instance) ?*Dict {
    const v = self.dict.getStr("_data") orelse return null;
    if (v != .dict) return null;
    return v.dict;
}

fn mpInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2 or args[0] != .instance) {
        try interp.typeError("MappingProxyType expects (mapping)");
        return error.TypeError;
    }
    if (args[1] != .dict) {
        try interp.typeError("MappingProxyType argument must be a dict");
        return error.TypeError;
    }
    try args[0].instance.dict.setStr(interp.allocator, "_data", args[1]);
    return Value.none;
}

fn mpGetitemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2 or args[0] != .instance) {
        try interp.typeError("mappingproxy.__getitem__ expects (self, key)");
        return error.TypeError;
    }
    const d = mpDictOf(args[0].instance) orelse return error.TypeError;
    if (d.getKey(args[1])) |v| return v;
    try interp.raisePyValue("KeyError", args[1]);
    return error.PyException;
}

fn mpSetitemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    try interp.raisePy("TypeError", "'mappingproxy' object does not support item assignment");
    return error.PyException;
}

fn mpDelitemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    try interp.raisePy("TypeError", "'mappingproxy' object does not support item deletion");
    return error.PyException;
}

fn mpContainsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2 or args[0] != .instance) {
        try interp.typeError("mappingproxy.__contains__ expects (self, key)");
        return error.TypeError;
    }
    const d = mpDictOf(args[0].instance) orelse return error.TypeError;
    return Value{ .boolean = d.findKeyWrap(args[1]) };
}

fn mpLenFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) {
        try interp.typeError("mappingproxy.__len__ expects self");
        return error.TypeError;
    }
    const d = mpDictOf(args[0].instance) orelse return error.TypeError;
    return Value{ .small_int = @intCast(d.count()) };
}

fn mpIterFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) {
        try interp.typeError("mappingproxy.__iter__ expects self");
        return error.TypeError;
    }
    const d = mpDictOf(args[0].instance) orelse return error.TypeError;
    const out = try List.init(interp.allocator);
    for (d.pairs.items) |pair| try out.append(interp.allocator, pair.key);
    const it = try Iter.init(interp.allocator, .{ .list = out });
    return Value{ .iter = it };
}

fn mpKeysFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) {
        try interp.typeError("mappingproxy.keys expects self");
        return error.TypeError;
    }
    const d = mpDictOf(args[0].instance) orelse return error.TypeError;
    const out = try List.init(interp.allocator);
    for (d.pairs.items) |pair| try out.append(interp.allocator, pair.key);
    return Value{ .list = out };
}

fn mpValuesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) {
        try interp.typeError("mappingproxy.values expects self");
        return error.TypeError;
    }
    const d = mpDictOf(args[0].instance) orelse return error.TypeError;
    const out = try List.init(interp.allocator);
    for (d.pairs.items) |pair| try out.append(interp.allocator, pair.value);
    return Value{ .list = out };
}

fn mpItemsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) {
        try interp.typeError("mappingproxy.items expects self");
        return error.TypeError;
    }
    const d = mpDictOf(args[0].instance) orelse return error.TypeError;
    const out = try List.init(interp.allocator);
    for (d.pairs.items) |pair| {
        const t = try Tuple.init(interp.allocator, 2);
        t.items[0] = pair.key;
        t.items[1] = pair.value;
        try out.append(interp.allocator, Value{ .tuple = t });
    }
    return Value{ .list = out };
}

fn mpGetFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args.len > 3 or args[0] != .instance) {
        try interp.typeError("mappingproxy.get expects (self, key[, default])");
        return error.TypeError;
    }
    const d = mpDictOf(args[0].instance) orelse return error.TypeError;
    if (d.getKey(args[1])) |v| return v;
    return if (args.len == 3) args[2] else Value.none;
}

fn mpCopyFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) {
        try interp.typeError("mappingproxy.copy expects self");
        return error.TypeError;
    }
    const d = mpDictOf(args[0].instance) orelse return error.TypeError;
    const out = try Dict.init(interp.allocator);
    for (d.pairs.items) |pair| try out.setKey(interp.allocator, pair.key, pair.value);
    return Value{ .dict = out };
}

fn mpReprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) {
        try interp.typeError("mappingproxy.__repr__ expects self");
        return error.TypeError;
    }
    const d = mpDictOf(args[0].instance) orelse return error.TypeError;
    var w = std.Io.Writer.Allocating.init(interp.allocator);
    try w.writer.writeAll("mappingproxy(");
    const dv = Value{ .dict = d };
    try dv.writeRepr(&w.writer);
    try w.writer.writeAll(")");
    const s = try Str.init(interp.allocator, w.written());
    return Value{ .str = s };
}

// ===== new_class =====

/// `types.new_class(name, bases=(), kwds=None, exec_body=None)` -- runs
/// exec_body against a fresh dict, then builds a Class around it.
fn newClassFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("new_class expects (name, bases=(), kwds=None, exec_body=None)");
        return error.TypeError;
    }
    const name = args[0].str.bytes;

    var bases_buf: [8]*Class = undefined;
    var n_bases: usize = 0;
    if (args.len >= 2 and args[1] == .tuple) {
        for (args[1].tuple.items) |b| {
            if (b != .class) {
                try interp.typeError("new_class: base must be a class");
                return error.TypeError;
            }
            if (n_bases >= bases_buf.len) {
                try interp.typeError("new_class: too many bases");
                return error.TypeError;
            }
            bases_buf[n_bases] = b.class;
            n_bases += 1;
        }
    }

    const ns = try Dict.init(interp.allocator);
    if (args.len >= 4 and args[3] != .none) {
        const dispatch = @import("dispatch.zig");
        _ = try dispatch.invoke(interp, args[3], &.{Value{ .dict = ns }});
    }
    return Value{ .class = try Class.init(interp.allocator, name, bases_buf[0..n_bases], ns) };
}
