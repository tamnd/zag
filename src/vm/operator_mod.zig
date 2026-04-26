//! `operator` module: thin wrappers over the existing dispatch
//! arithmetic / comparison / subscript helpers, plus
//! `attrgetter` / `itemgetter` / `methodcaller` factories.
//!
//! Most of these are 1:1 with a BINARY_OP arg, so the module is just
//! a registration table of small adapters.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "operator");
    try register(interp, m, "add", addFn);
    try register(interp, m, "sub", subFn);
    try register(interp, m, "mul", mulFn);
    try register(interp, m, "truediv", truedivFn);
    try register(interp, m, "floordiv", floordivFn);
    try register(interp, m, "mod", modFn);
    try register(interp, m, "pow", powFn);
    try register(interp, m, "neg", negFn);
    try register(interp, m, "pos", posFn);
    try register(interp, m, "abs", absFn);
    try register(interp, m, "inv", invFn);
    try register(interp, m, "invert", invFn);
    try register(interp, m, "not_", notFn);
    try register(interp, m, "truth", truthFn);
    try register(interp, m, "is_", isFn);
    try register(interp, m, "is_not", isNotFn);
    try register(interp, m, "lt", ltFn);
    try register(interp, m, "le", leFn);
    try register(interp, m, "eq", eqFn);
    try register(interp, m, "ne", neFn);
    try register(interp, m, "gt", gtFn);
    try register(interp, m, "ge", geFn);
    try register(interp, m, "and_", andFn);
    try register(interp, m, "or_", orFn);
    try register(interp, m, "xor", xorFn);
    try register(interp, m, "lshift", lshiftFn);
    try register(interp, m, "rshift", rshiftFn);
    try register(interp, m, "concat", concatFn);
    try register(interp, m, "getitem", getitemFn);
    try register(interp, m, "setitem", setitemFn);
    try register(interp, m, "delitem", delitemFn);
    try register(interp, m, "contains", containsFn);
    try register(interp, m, "index", indexFn);
    try register(interp, m, "length_hint", lengthHintFn);
    try register(interp, m, "countOf", countOfFn);
    try register(interp, m, "indexOf", indexOfFn);
    try register(interp, m, "iadd", iaddFn);
    try register(interp, m, "iconcat", iaddFn);
    try register(interp, m, "isub", subFn);
    try register(interp, m, "imul", mulFn);
    try register(interp, m, "itruediv", truedivFn);
    try register(interp, m, "ifloordiv", floordivFn);
    try register(interp, m, "imod", modFn);
    try register(interp, m, "ipow", powFn);
    try register(interp, m, "ilshift", lshiftFn);
    try register(interp, m, "irshift", rshiftFn);
    try register(interp, m, "iand", andFn);
    try register(interp, m, "ior", orFn);
    try register(interp, m, "ixor", xorFn);
    try register(interp, m, "attrgetter", attrgetterFn);
    try register(interp, m, "itemgetter", itemgetterFn);
    try registerKw(interp, m, "methodcaller", methodcallerFn, methodcallerKw);

    // Dunder aliases. Most CPython operator entries have a `__name__`
    // counterpart; registering both points to the same trampoline.
    try register(interp, m, "__add__", addFn);
    try register(interp, m, "__sub__", subFn);
    try register(interp, m, "__mul__", mulFn);
    try register(interp, m, "__truediv__", truedivFn);
    try register(interp, m, "__floordiv__", floordivFn);
    try register(interp, m, "__mod__", modFn);
    try register(interp, m, "__pow__", powFn);
    try register(interp, m, "__neg__", negFn);
    try register(interp, m, "__pos__", posFn);
    try register(interp, m, "__abs__", absFn);
    try register(interp, m, "__inv__", invFn);
    try register(interp, m, "__invert__", invFn);
    try register(interp, m, "__not__", notFn);
    try register(interp, m, "__lt__", ltFn);
    try register(interp, m, "__le__", leFn);
    try register(interp, m, "__eq__", eqFn);
    try register(interp, m, "__ne__", neFn);
    try register(interp, m, "__gt__", gtFn);
    try register(interp, m, "__ge__", geFn);
    try register(interp, m, "__and__", andFn);
    try register(interp, m, "__or__", orFn);
    try register(interp, m, "__xor__", xorFn);
    try register(interp, m, "__lshift__", lshiftFn);
    try register(interp, m, "__rshift__", rshiftFn);
    try register(interp, m, "__concat__", concatFn);
    try register(interp, m, "__contains__", containsFn);
    try register(interp, m, "__getitem__", getitemFn);
    try register(interp, m, "__setitem__", setitemFn);
    try register(interp, m, "__delitem__", delitemFn);
    try register(interp, m, "__index__", indexFn);
    try register(interp, m, "__iadd__", iaddFn);
    try register(interp, m, "__iconcat__", iaddFn);
    try register(interp, m, "__isub__", subFn);
    try register(interp, m, "__imul__", mulFn);
    try register(interp, m, "__itruediv__", truedivFn);
    try register(interp, m, "__ifloordiv__", floordivFn);
    try register(interp, m, "__imod__", modFn);
    try register(interp, m, "__ipow__", powFn);
    try register(interp, m, "__ilshift__", lshiftFn);
    try register(interp, m, "__irshift__", rshiftFn);
    try register(interp, m, "__iand__", andFn);
    try register(interp, m, "__ior__", orFn);
    try register(interp, m, "__ixor__", xorFn);
    return m;
}

fn register(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn registerKw(
    interp: *Interp,
    m: *Module,
    name: []const u8,
    func: BuiltinFnPtr,
    kw_func: value_mod.BuiltinKwFnPtr,
) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn binTwo(interp: *Interp, args: []const Value, name: []const u8) !void {
    if (args.len != 2) {
        try interp.typeError(name);
        return error.TypeError;
    }
}

fn addFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "add expects 2 arguments");
    return dispatch.binaryOp(interp, args[0], args[1], 0);
}
fn subFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "sub expects 2 arguments");
    return dispatch.binaryOp(interp, args[0], args[1], 10);
}
fn mulFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "mul expects 2 arguments");
    return dispatch.binaryOp(interp, args[0], args[1], 5);
}
fn truedivFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "truediv expects 2 arguments");
    return dispatch.binaryOp(interp, args[0], args[1], 11);
}
fn floordivFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "floordiv expects 2 arguments");
    return dispatch.binaryOp(interp, args[0], args[1], 2);
}
fn modFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "mod expects 2 arguments");
    return dispatch.binaryOp(interp, args[0], args[1], 6);
}
fn powFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "pow expects 2 arguments");
    return dispatch.binaryOp(interp, args[0], args[1], 8);
}
fn andFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "and_ expects 2 arguments");
    return dispatch.binaryOp(interp, args[0], args[1], 1);
}
fn orFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "or_ expects 2 arguments");
    return dispatch.binaryOp(interp, args[0], args[1], 7);
}
fn xorFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "xor expects 2 arguments");
    return dispatch.binaryOp(interp, args[0], args[1], 12);
}
fn lshiftFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "lshift expects 2 arguments");
    return dispatch.binaryOp(interp, args[0], args[1], 3);
}
fn rshiftFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "rshift expects 2 arguments");
    return dispatch.binaryOp(interp, args[0], args[1], 9);
}

fn negFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 1) {
        try interp.typeError("neg expects 1 argument");
        return error.TypeError;
    }
    return switch (args[0]) {
        .small_int => |i| Value{ .small_int = -i },
        .float => |f| Value{ .float = -f },
        .boolean => |b| Value{ .small_int = if (b) -1 else 0 },
        else => {
            try interp.typeError("neg: bad operand type");
            return error.TypeError;
        },
    };
}
fn posFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 1) {
        try interp.typeError("pos expects 1 argument");
        return error.TypeError;
    }
    return switch (args[0]) {
        .small_int => |i| Value{ .small_int = i },
        .float => |f| Value{ .float = f },
        .boolean => |b| Value{ .small_int = @intFromBool(b) },
        else => {
            try interp.typeError("pos: bad operand type");
            return error.TypeError;
        },
    };
}
fn notFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    _ = opaque_interp;
    if (args.len != 1) return error.TypeError;
    return Value{ .boolean = !args[0].isTruthy() };
}
fn indexFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 1) {
        try interp.typeError("index expects 1 argument");
        return error.TypeError;
    }
    return switch (args[0]) {
        .small_int => args[0],
        .boolean => |b| Value{ .small_int = @intFromBool(b) },
        .big_int => args[0],
        else => {
            try interp.typeError("'object' object cannot be interpreted as an integer");
            return error.TypeError;
        },
    };
}
fn truthFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    _ = opaque_interp;
    if (args.len != 1) return error.TypeError;
    return Value{ .boolean = args[0].isTruthy() };
}

fn absFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    return @import("builtins.zig").absBuiltin(opaque_interp, args);
}

fn invFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 1) {
        try interp.typeError("invert expects 1 argument");
        return error.TypeError;
    }
    return switch (args[0]) {
        .small_int => |i| Value{ .small_int = ~i },
        .boolean => |b| Value{ .small_int = ~@as(i64, @intFromBool(b)) },
        else => {
            try interp.typeError("invert: bad operand type");
            return error.TypeError;
        },
    };
}

fn isFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "is_ expects 2 arguments");
    return Value{ .boolean = args[0].identityEq(args[1]) };
}

fn isNotFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "is_not expects 2 arguments");
    return Value{ .boolean = !args[0].identityEq(args[1]) };
}

fn concatFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "concat expects 2 arguments");
    return dispatch.binaryAdd(interp, args[0], args[1]);
}

fn lengthHintFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args.len > 2) {
        try interp.typeError("length_hint expects 1 or 2 arguments");
        return error.TypeError;
    }
    const obj = args[0];
    const default: i64 = if (args.len == 2) switch (args[1]) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        else => 0,
    } else 0;
    return switch (obj) {
        .list => |l| Value{ .small_int = @intCast(l.items.items.len) },
        .tuple => |t| Value{ .small_int = @intCast(t.items.len) },
        .str => |s| Value{ .small_int = @intCast(s.len()) },
        .bytes => |b| Value{ .small_int = @intCast(b.data.len) },
        .bytearray => |b| Value{ .small_int = @intCast(b.data.items.len) },
        .dict => |d| Value{ .small_int = @intCast(d.pairs.items.len) },
        .set => |s| Value{ .small_int = @intCast(s.items.items.len) },
        else => Value{ .small_int = default },
    };
}

fn countOfFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "countOf expects 2 arguments");
    var count: i64 = 0;
    switch (args[0]) {
        .list => |l| for (l.items.items) |it| {
            if (it.equals(args[1])) count += 1;
        },
        .tuple => |t| for (t.items) |it| {
            if (it.equals(args[1])) count += 1;
        },
        else => {
            try interp.typeError("countOf: argument must be iterable");
            return error.TypeError;
        },
    }
    return Value{ .small_int = count };
}

fn indexOfFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "indexOf expects 2 arguments");
    switch (args[0]) {
        .list => |l| for (l.items.items, 0..) |it, i| {
            if (it.equals(args[1])) return Value{ .small_int = @intCast(i) };
        },
        .tuple => |t| for (t.items, 0..) |it, i| {
            if (it.equals(args[1])) return Value{ .small_int = @intCast(i) };
        },
        else => {
            try interp.typeError("indexOf: argument must be iterable");
            return error.TypeError;
        },
    }
    try interp.raisePy("ValueError", "sequence.index(x): x not in sequence");
    return error.PyException;
}

fn iaddFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "iadd expects 2 arguments");
    // Mutate the destination list in place so `is` still holds.
    if (args[0] == .list) {
        const dst = args[0].list;
        switch (args[1]) {
            .list => |l| for (l.items.items) |it| try dst.append(interp.allocator, it),
            .tuple => |t| for (t.items) |it| try dst.append(interp.allocator, it),
            else => {
                try interp.typeError("iadd: rhs must be a sequence");
                return error.TypeError;
            },
        }
        return args[0];
    }
    return dispatch.binaryAdd(interp, args[0], args[1]);
}

fn ltFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "lt expects 2 arguments");
    return Value{ .boolean = try dispatch.compareOp(interp, args[0], args[1], 0) };
}
fn leFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "le expects 2 arguments");
    return Value{ .boolean = try dispatch.compareOp(interp, args[0], args[1], 1) };
}
fn eqFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "eq expects 2 arguments");
    return Value{ .boolean = try dispatch.compareOp(interp, args[0], args[1], 2) };
}
fn neFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "ne expects 2 arguments");
    return Value{ .boolean = try dispatch.compareOp(interp, args[0], args[1], 3) };
}
fn gtFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "gt expects 2 arguments");
    return Value{ .boolean = try dispatch.compareOp(interp, args[0], args[1], 4) };
}
fn geFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "ge expects 2 arguments");
    return Value{ .boolean = try dispatch.compareOp(interp, args[0], args[1], 5) };
}

fn getitemFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "getitem expects 2 arguments");
    return dispatch.subscript(interp, args[0], args[1]);
}
fn setitemFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 3) {
        try interp.typeError("setitem expects 3 arguments");
        return error.TypeError;
    }
    try dispatch.storeSubscr(interp, args[0], args[1], args[2]);
    return Value.none;
}
fn delitemFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "delitem expects 2 arguments");
    const container = args[0];
    const key = args[1];
    switch (container) {
        .list => |l| switch (key) {
            .small_int => |i| {
                const n: i64 = @intCast(l.items.items.len);
                var idx = i;
                if (idx < 0) idx += n;
                if (idx < 0 or idx >= n) {
                    try interp.indexError("list deletion index out of range");
                    return error.IndexError;
                }
                _ = l.items.orderedRemove(@intCast(idx));
            },
            else => {
                try interp.typeError("list indices must be integers");
                return error.TypeError;
            },
        },
        .dict => |d| {
            if (key != .str) {
                try interp.typeError("dict del only supports str keys");
                return error.TypeError;
            }
            if (!d.delete(key.str.bytes)) {
                try interp.raisePy("KeyError", "missing key");
                return error.PyException;
            }
        },
        else => {
            try interp.typeError("delitem: unsupported container");
            return error.TypeError;
        },
    }
    return Value.none;
}
fn containsFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    try binTwo(interp, args, "contains expects 2 arguments");
    return Value{ .boolean = try dispatch.containsOp(interp, args[1], args[0]) };
}

// --- attrgetter / itemgetter / methodcaller ---
//
// Each returns a callable. Implemented as a Partial whose underlying
// function is a small trampoline BuiltinFn that reads its config out
// of the bound positional args.

fn attrgetterFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1) {
        try interp.typeError("attrgetter expects at least one name");
        return error.TypeError;
    }
    for (args) |a| if (a != .str) {
        try interp.typeError("attrgetter: names must be str");
        return error.TypeError;
    };
    const tramp = try interp.allocator.create(BuiltinFn);
    tramp.* = .{ .name = "attrgetter", .func = attrgetterCall };
    const Partial = @import("../object/partial.zig").Partial;
    const p = try Partial.init(
        interp.allocator,
        Value{ .builtin_fn = tramp },
        args,
        &.{},
        &.{},
    );
    return Value{ .partial = p };
}

fn attrgetterCall(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    // args = [name1, name2, ..., target]
    if (args.len < 2) {
        try interp.typeError("attrgetter: missing target");
        return error.TypeError;
    }
    const target = args[args.len - 1];
    const names = args[0 .. args.len - 1];
    if (names.len == 1) return getAttr(interp, target, names[0].str.bytes);
    const out = try Tuple.init(interp.allocator, names.len);
    for (names, 0..) |n, i| out.items[i] = try getAttr(interp, target, n.str.bytes);
    return Value{ .tuple = out };
}

fn getAttr(interp: *Interp, target: Value, name: []const u8) !Value {
    // Walk simple dotted names: "x.y.z" => repeated lookups.
    var rest = name;
    var cur = target;
    while (rest.len > 0) {
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
        const seg = rest[0..dot];
        cur = try dispatch.loadAttrValue(interp, cur, seg);
        rest = if (dot == rest.len) "" else rest[dot + 1 ..];
    }
    return cur;
}

fn itemgetterFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1) {
        try interp.typeError("itemgetter expects at least one key");
        return error.TypeError;
    }
    const tramp = try interp.allocator.create(BuiltinFn);
    tramp.* = .{ .name = "itemgetter", .func = itemgetterCall };
    const Partial = @import("../object/partial.zig").Partial;
    const p = try Partial.init(
        interp.allocator,
        Value{ .builtin_fn = tramp },
        args,
        &.{},
        &.{},
    );
    return Value{ .partial = p };
}

fn itemgetterCall(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 2) {
        try interp.typeError("itemgetter: missing target");
        return error.TypeError;
    }
    const target = args[args.len - 1];
    const keys = args[0 .. args.len - 1];
    if (keys.len == 1) return dispatch.subscript(interp, target, keys[0]);
    const out = try Tuple.init(interp.allocator, keys.len);
    for (keys, 0..) |k, i| out.items[i] = try dispatch.subscript(interp, target, k);
    return Value{ .tuple = out };
}

fn methodcallerFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    return methodcallerKw(opaque_interp, args, &.{}, &.{});
}

fn methodcallerKw(
    opaque_interp: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("methodcaller expects a method name");
        return error.TypeError;
    }
    const tramp = try interp.allocator.create(BuiltinFn);
    tramp.* = .{ .name = "methodcaller", .func = methodcallerCall, .kw_func = methodcallerCallKw };
    const Partial = @import("../object/partial.zig").Partial;
    const p = try Partial.init(
        interp.allocator,
        Value{ .builtin_fn = tramp },
        args,
        kw_names,
        kw_values,
    );
    return Value{ .partial = p };
}

fn methodcallerCall(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    return methodcallerCallKw(opaque_interp, args, &.{}, &.{});
}

fn methodcallerCallKw(
    opaque_interp: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    // args = [name, *bound_args, target]
    if (args.len < 2) {
        try interp.typeError("methodcaller: missing target");
        return error.TypeError;
    }
    const name = args[0].str.bytes;
    const target = args[args.len - 1];
    const bound = args[1 .. args.len - 1];
    const method = try dispatch.loadAttrValue(interp, target, name);
    return dispatch.invokeKwPub(interp, method, bound, kw_names, kw_values);
}
