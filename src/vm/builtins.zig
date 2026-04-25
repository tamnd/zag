const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Interp = @import("interp.zig").Interp;
const List = @import("../object/list.zig").List;
const Iter = @import("../object/iter.zig").Iter;
const Tuple = @import("../object/tuple.zig").Tuple;
const Class = @import("../object/class.zig").Class;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Descriptor = @import("../object/descriptor.zig").Descriptor;

pub const BuiltinError = error{
    BadArgument,
    OutOfMemory,
    WriteFailed,
};

pub fn print(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const w = interp.stdout;
    for (args, 0..) |a, i| {
        if (i != 0) try w.writeByte(' ');
        try a.writeStr(w);
    }
    try w.writeByte('\n');
    try w.flush();
    return Value.none;
}

pub fn absBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.stderr.print(
            "TypeError: abs() takes exactly one argument ({d} given)\n",
            .{args.len},
        );
        try interp.stderr.flush();
        return error.TypeError;
    }
    return switch (args[0]) {
        .small_int => |i| Value{ .small_int = if (i < 0) -i else i },
        .float => |f| Value{ .float = if (f < 0) -f else f },
        .boolean => |b| Value{ .small_int = if (b) 1 else 0 },
        else => |v| blk: {
            try interp.stderr.print(
                "TypeError: bad operand type for abs(): '{s}'\n",
                .{v.typeName()},
            );
            try interp.stderr.flush();
            break :blk error.TypeError;
        },
    };
}

/// Stub for the `super` global. Zero-arg `super()` is intercepted by
/// `LOAD_SUPER_ATTR` -- the bytecode pushes this value and pops it
/// without ever calling it. Calling `super(...)` directly is out of
/// scope for now.
pub fn superBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    try interp.typeError("super() proxy objects not implemented");
    return error.TypeError;
}

fn makeDescriptor(interp_opaque: *anyopaque, kind: Descriptor.Kind, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("descriptor builtin expects exactly one argument");
        return error.TypeError;
    }
    const d = try Descriptor.init(interp.allocator, kind, args[0]);
    return Value{ .descriptor = d };
}

pub fn propertyBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return makeDescriptor(interp_opaque, .property, args);
}

pub fn classmethodBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return makeDescriptor(interp_opaque, .classmethod, args);
}

pub fn staticmethodBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return makeDescriptor(interp_opaque, .staticmethod, args);
}

pub fn lenBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.stderr.print(
            "TypeError: len() takes exactly one argument ({d} given)\n",
            .{args.len},
        );
        try interp.stderr.flush();
        return error.TypeError;
    }
    return switch (args[0]) {
        .str => |s| Value{ .small_int = @intCast(s.len()) },
        .bytes => |b| Value{ .small_int = @intCast(b.data.len) },
        .tuple => |t| Value{ .small_int = @intCast(t.items.len) },
        .list => |l| Value{ .small_int = @intCast(l.items.items.len) },
        .dict => |d| Value{ .small_int = @intCast(d.count()) },
        else => |v| blk: {
            try interp.stderr.print(
                "TypeError: object of type '{s}' has no len()\n",
                .{v.typeName()},
            );
            try interp.stderr.flush();
            break :blk error.TypeError;
        },
    };
}

fn iterableItems(v: Value) ?[]const Value {
    return switch (v) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => null,
    };
}

pub fn sumBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const list = try materialize(interp, args[0]);
    var acc: i64 = 0;
    for (list.items.items) |it| {
        switch (it) {
            .small_int => |i| acc += i,
            .boolean => |b| acc += @intFromBool(b),
            else => {
                try interp.typeError("unsupported operand type for +");
                return error.TypeError;
            },
        }
    }
    return Value{ .small_int = acc };
}

/// Materialize any iterable into a fresh `List`. Used by builtins
/// that don't want to special-case every container shape. Iterators
/// get drained -- caller owns the result. Strings yield single-byte
/// `Str` values, matching CPython's `list("abc") == ['a','b','c']`.
pub fn materialize(interp: *Interp, v: Value) !*List {
    const a = interp.allocator;
    const out = try List.init(a);
    switch (v) {
        .list => |l| for (l.items.items) |x| try out.append(a, x),
        .tuple => |t| for (t.items) |x| try out.append(a, x),
        .iter => |it| while (it.next()) |x| try out.append(a, x),
        .generator => |g| {
            const dispatch = @import("dispatch.zig");
            while (try dispatch.genResume(interp, g, Value.none)) |x| {
                try out.append(a, x);
            }
        },
        .str => |s| for (s.bytes) |b| {
            const piece = try Str.init(a, &[_]u8{b});
            try out.append(a, Value{ .str = piece });
        },
        .dict => |d| for (d.keys.items) |k| {
            const piece = try Str.init(a, k);
            try out.append(a, Value{ .str = piece });
        },
        else => {
            try interp.typeError("object is not iterable");
            return error.TypeError;
        },
    }
    return out;
}

pub fn sortedBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const items = iterableItems(args[0]) orelse {
        try interp.typeError("sorted() argument must be iterable");
        return error.TypeError;
    };
    const out = try List.init(interp.allocator);
    for (items) |it| try out.append(interp.allocator, it);
    const slice = out.items.items;
    std.sort.pdq(Value, slice, {}, lessThanForSort);
    return Value{ .list = out };
}

fn lessThanForSort(_: void, a: Value, b: Value) bool {
    if (a.order(b)) |o| return o == .lt;
    return false;
}

/// Python `range(stop)` and `range(start, stop)`. We hand back an
/// `Iter` directly rather than a separate range sequence object —
/// for `for i in range(...):` the distinction is invisible, and
/// fixtures don't yet exercise len/contains/repr on a range.
pub fn rangeBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    var start: i64 = 0;
    var stop: i64 = 0;
    if (args.len == 1) {
        stop = try intArg(interp, args[0]);
    } else if (args.len == 2) {
        start = try intArg(interp, args[0]);
        stop = try intArg(interp, args[1]);
    } else {
        try interp.typeError("range expected 1 or 2 arguments");
        return error.TypeError;
    }
    const it = try Iter.init(interp.allocator, .{ .range = .{
        .current = start,
        .stop = stop,
        .step = 1,
    } });
    return Value{ .iter = it };
}

fn intArg(interp: *Interp, v: Value) !i64 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        else => {
            try interp.typeError("range argument must be int");
            return error.TypeError;
        },
    };
}

pub fn listBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len == 0) {
        const out = try List.init(interp.allocator);
        return Value{ .list = out };
    }
    const out = try materialize(interp, args[0]);
    return Value{ .list = out };
}

pub fn maxBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    return try minMax(interp, args, true);
}

pub fn minBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    return try minMax(interp, args, false);
}

fn minMax(interp: *Interp, args: []const Value, want_max: bool) !Value {
    var items: []const Value = undefined;
    var owned: ?*List = null;
    if (args.len == 1) {
        owned = try materialize(interp, args[0]);
        items = owned.?.items.items;
    } else {
        items = args;
    }
    if (items.len == 0) {
        try interp.typeError("min/max arg is an empty sequence");
        return error.TypeError;
    }
    var best = items[0];
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const o = best.order(items[i]) orelse {
            try interp.typeError("min/max: types are not orderable");
            return error.TypeError;
        };
        const swap = if (want_max) o == .lt else o == .gt;
        if (swap) best = items[i];
    }
    return best;
}

pub fn reversedBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const src = try materialize(interp, args[0]);
    const out = try List.init(interp.allocator);
    var i: usize = src.items.items.len;
    while (i > 0) {
        i -= 1;
        try out.append(interp.allocator, src.items.items[i]);
    }
    return Value{ .list = out };
}

pub fn enumerateBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const src = try materialize(interp, args[0]);
    const out = try List.init(interp.allocator);
    for (src.items.items, 0..) |v, i| {
        const t = try Tuple.init(interp.allocator, 2);
        t.items[0] = Value{ .small_int = @intCast(i) };
        t.items[1] = v;
        try out.append(interp.allocator, Value{ .tuple = t });
    }
    return Value{ .list = out };
}

pub fn zipBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const out = try List.init(interp.allocator);
    if (args.len == 0) return Value{ .list = out };
    var srcs = try interp.allocator.alloc(*List, args.len);
    defer interp.allocator.free(srcs);
    var min_len: usize = std.math.maxInt(usize);
    for (args, 0..) |a, i| {
        srcs[i] = try materialize(interp, a);
        if (srcs[i].items.items.len < min_len) min_len = srcs[i].items.items.len;
    }
    var i: usize = 0;
    while (i < min_len) : (i += 1) {
        const t = try Tuple.init(interp.allocator, args.len);
        for (srcs, 0..) |s, j| t.items[j] = s.items.items[i];
        try out.append(interp.allocator, Value{ .tuple = t });
    }
    return Value{ .list = out };
}

pub fn mapBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2) {
        try interp.typeError("map() takes exactly 2 arguments (zag)");
        return error.TypeError;
    }
    const dispatch = @import("dispatch.zig");
    const fn_val = args[0];
    const src = try materialize(interp, args[1]);
    const out = try List.init(interp.allocator);
    for (src.items.items) |v| {
        const r = try dispatch.invoke(interp, fn_val, &[_]Value{v});
        try out.append(interp.allocator, r);
    }
    return Value{ .list = out };
}

pub fn filterBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2) {
        try interp.typeError("filter() takes exactly 2 arguments");
        return error.TypeError;
    }
    const dispatch = @import("dispatch.zig");
    const fn_val = args[0];
    const src = try materialize(interp, args[1]);
    const out = try List.init(interp.allocator);
    for (src.items.items) |v| {
        const keep = if (fn_val == .none) v.isTruthy() else blk: {
            const r = try dispatch.invoke(interp, fn_val, &[_]Value{v});
            break :blk r.isTruthy();
        };
        if (keep) try out.append(interp.allocator, v);
    }
    return Value{ .list = out };
}

pub fn anyBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const src = try materialize(interp, args[0]);
    for (src.items.items) |v| if (v.isTruthy()) return Value{ .boolean = true };
    return Value{ .boolean = false };
}

pub fn allBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const src = try materialize(interp, args[0]);
    for (src.items.items) |v| if (!v.isTruthy()) return Value{ .boolean = false };
    return Value{ .boolean = true };
}

pub fn ordBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1 or args[0] != .str or args[0].str.bytes.len != 1) {
        try interp.typeError("ord() expected a one-character string");
        return error.TypeError;
    }
    return Value{ .small_int = @intCast(args[0].str.bytes[0]) };
}

pub fn chrBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1 or args[0] != .small_int) {
        try interp.typeError("chr() requires int");
        return error.TypeError;
    }
    const i = args[0].small_int;
    if (i < 0 or i > 127) {
        try interp.typeError("chr(): zag only handles 7-bit ASCII");
        return error.TypeError;
    }
    const piece = try Str.init(interp.allocator, &[_]u8{@intCast(i)});
    return Value{ .str = piece };
}

pub fn hexBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return formatRadix(interp_opaque, args, "0x", 16);
}

pub fn octBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return formatRadix(interp_opaque, args, "0o", 8);
}

pub fn binBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return formatRadix(interp_opaque, args, "0b", 2);
}

fn formatRadix(interp_opaque: *anyopaque, args: []const Value, prefix: []const u8, base: u8) !Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1 or args[0] != .small_int) {
        try interp.typeError("hex/oct/bin require an int");
        return error.TypeError;
    }
    const i = args[0].small_int;
    var buf: [80]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll(prefix);
    try w.printInt(i, base, .lower, .{});
    const piece = try Str.init(interp.allocator, w.buffered());
    return Value{ .str = piece };
}

pub fn intBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len == 0) return Value{ .small_int = 0 };
    return switch (args[0]) {
        .small_int => args[0],
        .boolean => |b| Value{ .small_int = @intFromBool(b) },
        .float => |f| Value{ .small_int = @intFromFloat(f) },
        .str => |s| blk: {
            const trimmed = std.mem.trim(u8, s.bytes, " \t");
            const v = std.fmt.parseInt(i64, trimmed, 10) catch {
                try interp.raisePy("ValueError", "invalid literal for int()");
                break :blk error.PyException;
            };
            break :blk Value{ .small_int = v };
        },
        else => {
            try interp.typeError("int() argument must be str, bytes, or number");
            return error.TypeError;
        },
    };
}

pub fn floatBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len == 0) return Value{ .float = 0.0 };
    return switch (args[0]) {
        .float => args[0],
        .small_int => |i| Value{ .float = @floatFromInt(i) },
        .boolean => |b| Value{ .float = if (b) 1.0 else 0.0 },
        .str => |s| blk: {
            const trimmed = std.mem.trim(u8, s.bytes, " \t");
            const v = std.fmt.parseFloat(f64, trimmed) catch {
                try interp.raisePy("ValueError", "could not convert string to float");
                break :blk error.PyException;
            };
            break :blk Value{ .float = v };
        },
        else => {
            try interp.typeError("float() argument must be str or number");
            return error.TypeError;
        },
    };
}

pub fn strBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len == 0) {
        const piece = try Str.init(interp.allocator, "");
        return Value{ .str = piece };
    }
    if (args[0] == .str) return args[0];
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try args[0].writeStr(&w);
    const piece = try Str.init(interp.allocator, w.buffered());
    return Value{ .str = piece };
}

pub fn install(interp: *Interp) !void {
    try interp.registerBuiltin("print", print);
    try interp.registerBuiltin("abs", absBuiltin);
    try interp.registerBuiltin("len", lenBuiltin);
    try interp.registerBuiltin("sum", sumBuiltin);
    try interp.registerBuiltin("sorted", sortedBuiltin);
    try interp.registerBuiltin("range", rangeBuiltin);
    try interp.registerBuiltin("list", listBuiltin);
    try interp.registerBuiltin("max", maxBuiltin);
    try interp.registerBuiltin("min", minBuiltin);
    try interp.registerBuiltin("reversed", reversedBuiltin);
    try interp.registerBuiltin("enumerate", enumerateBuiltin);
    try interp.registerBuiltin("zip", zipBuiltin);
    try interp.registerBuiltin("map", mapBuiltin);
    try interp.registerBuiltin("filter", filterBuiltin);
    try interp.registerBuiltin("any", anyBuiltin);
    try interp.registerBuiltin("all", allBuiltin);
    try interp.registerBuiltin("ord", ordBuiltin);
    try interp.registerBuiltin("chr", chrBuiltin);
    try interp.registerBuiltin("hex", hexBuiltin);
    try interp.registerBuiltin("oct", octBuiltin);
    try interp.registerBuiltin("bin", binBuiltin);
    try interp.registerBuiltin("int", intBuiltin);
    try interp.registerBuiltin("float", floatBuiltin);
    try interp.registerBuiltin("str", strBuiltin);
    const dispatch = @import("dispatch.zig");
    try interp.registerBuiltin("__build_class__", dispatch.buildClass);
    try interp.registerBuiltin("isinstance", dispatch.isInstanceBuiltin);
    try interp.registerBuiltin("super", superBuiltin);
    try interp.registerBuiltin("property", propertyBuiltin);
    try interp.registerBuiltin("classmethod", classmethodBuiltin);
    try interp.registerBuiltin("staticmethod", staticmethodBuiltin);
    try interp.registerBuiltin("next", dispatch.nextBuiltin);
    try interp.registerBuiltin("iter", dispatch.iterBuiltin);
    try installExceptions(interp);
}

/// Build the exception-class hierarchy and register each as a
/// builtin. Order matters -- a class needs its bases built first so
/// MRO computation can walk them. The shape mirrors CPython's
/// `Exception.__mro__` for the classes the fixtures touch; subclassing
/// these from Python would work without further plumbing.
fn installExceptions(interp: *Interp) !void {
    const a = interp.allocator;
    const base_exc = try Class.init(a, "BaseException", &.{}, try Dict.init(a));
    const exception = try Class.init(a, "Exception", &.{base_exc}, try Dict.init(a));
    const arith = try Class.init(a, "ArithmeticError", &.{exception}, try Dict.init(a));
    const lookup = try Class.init(a, "LookupError", &.{exception}, try Dict.init(a));
    const zero_div = try Class.init(a, "ZeroDivisionError", &.{arith}, try Dict.init(a));
    const value_err = try Class.init(a, "ValueError", &.{exception}, try Dict.init(a));
    const index_err = try Class.init(a, "IndexError", &.{lookup}, try Dict.init(a));
    const key_err = try Class.init(a, "KeyError", &.{lookup}, try Dict.init(a));
    const runtime_err = try Class.init(a, "RuntimeError", &.{exception}, try Dict.init(a));
    const attr_err = try Class.init(a, "AttributeError", &.{exception}, try Dict.init(a));
    const type_err = try Class.init(a, "TypeError", &.{exception}, try Dict.init(a));
    const name_err = try Class.init(a, "NameError", &.{exception}, try Dict.init(a));
    const stop_iter = try Class.init(a, "StopIteration", &.{exception}, try Dict.init(a));

    const pairs = [_]struct { name: []const u8, cls: *Class }{
        .{ .name = "BaseException", .cls = base_exc },
        .{ .name = "Exception", .cls = exception },
        .{ .name = "ArithmeticError", .cls = arith },
        .{ .name = "LookupError", .cls = lookup },
        .{ .name = "ZeroDivisionError", .cls = zero_div },
        .{ .name = "ValueError", .cls = value_err },
        .{ .name = "IndexError", .cls = index_err },
        .{ .name = "KeyError", .cls = key_err },
        .{ .name = "RuntimeError", .cls = runtime_err },
        .{ .name = "AttributeError", .cls = attr_err },
        .{ .name = "TypeError", .cls = type_err },
        .{ .name = "NameError", .cls = name_err },
        .{ .name = "StopIteration", .cls = stop_iter },
    };
    for (pairs) |p| {
        try interp.builtins.setStr(a, p.name, Value{ .class = p.cls });
    }
}

/// True if `cls`'s MRO contains the builtin BaseException -- we use
/// this in `instantiate` to decide whether a no-`__init__` class
/// should default-bind `args`.
pub fn isExceptionClass(interp: *Interp, cls: *Class) bool {
    const base_val = interp.builtins.getStr("BaseException") orelse return false;
    if (base_val != .class) return false;
    for (cls.mro) |c| if (c == base_val.class) return true;
    return false;
}
