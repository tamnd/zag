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
const Bytes = @import("../object/bytes.zig").Bytes;
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
        .complex_num => |c| Value{ .float = @sqrt(c.re * c.re + c.im * c.im) },
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
        .bytearray => |b| Value{ .small_int = @intCast(b.data.items.len) },
        .tuple => |t| Value{ .small_int = @intCast(t.items.len) },
        .list => |l| Value{ .small_int = @intCast(l.items.items.len) },
        .dict => |d| Value{ .small_int = @intCast(d.count()) },
        .set => |s| Value{ .small_int = @intCast(s.items.items.len) },
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
        .enum_iter => {
            const dispatch = @import("dispatch.zig");
            while (try dispatch.iterStep(interp, v)) |x| {
                try out.append(a, x);
            }
        },
        .str => |s| for (s.bytes) |b| {
            const piece = try Str.init(a, &[_]u8{b});
            try out.append(a, Value{ .str = piece });
        },
        .bytes => |b| for (b.data) |x| try out.append(a, Value{ .small_int = @intCast(x) }),
        .bytearray => |b| for (b.data.items) |x| try out.append(a, Value{ .small_int = @intCast(x) }),
        .dict => |d| for (d.keys.items) |k| {
            const piece = try Str.init(a, k);
            try out.append(a, Value{ .str = piece });
        },
        .set => |s| for (s.items.items) |x| try out.append(a, x),
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

pub fn tupleBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len == 0) {
        const t = try Tuple.init(interp.allocator, 0);
        return Value{ .tuple = t };
    }
    const lst = try materialize(interp, args[0]);
    const t = try Tuple.init(interp.allocator, lst.items.items.len);
    for (lst.items.items, 0..) |it, i| t.items[i] = it;
    return Value{ .tuple = t };
}

pub fn setBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const Set = @import("../object/set.zig").Set;
    const s = try Set.init(interp.allocator);
    if (args.len == 0) return Value{ .set = s };
    const lst = try materialize(interp, args[0]);
    for (lst.items.items) |it| try s.add(interp.allocator, it);
    return Value{ .set = s };
}

pub fn frozensetBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const Set = @import("../object/set.zig").Set;
    const s = try Set.initFrozen(interp.allocator);
    if (args.len == 0) return Value{ .set = s };
    const lst = try materialize(interp, args[0]);
    for (lst.items.items) |it| try s.add(interp.allocator, it);
    return Value{ .set = s };
}

/// `hash(obj)` -- the only path the fixture exercises is the
/// negative one: `hash({1,2})` raises TypeError because plain sets
/// are unhashable. We return a placeholder int for everything else
/// and tighten as fixtures demand.
pub fn hashBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("hash() takes exactly one argument");
        return error.TypeError;
    }
    if (args[0] == .set and !args[0].set.frozen) {
        try interp.raisePy("TypeError", "unhashable type: 'set'");
        return error.PyException;
    }
    if (args[0] == .list) {
        try interp.raisePy("TypeError", "unhashable type: 'list'");
        return error.PyException;
    }
    if (args[0] == .dict) {
        try interp.raisePy("TypeError", "unhashable type: 'dict'");
        return error.PyException;
    }
    return Value{ .small_int = 0 };
}

pub fn dictBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const d = try Dict.init(interp.allocator);
    if (args.len == 0) return Value{ .dict = d };
    // Iterable of (k, v) pairs.
    const lst = try materialize(interp, args[0]);
    for (lst.items.items) |pair| {
        const items: []const Value = switch (pair) {
            .tuple => |t| t.items,
            .list => |l| l.items.items,
            else => {
                try interp.typeError("dict() argument must be iterable of pairs");
                return error.TypeError;
            },
        };
        if (items.len != 2) {
            try interp.typeError("dict() pair must have length 2");
            return error.TypeError;
        }
        try d.setKey(interp.allocator, items[0], items[1]);
    }
    return Value{ .dict = d };
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
    return enumerateBuiltinKw(interp_opaque, args, &.{}, &.{});
}

pub fn enumerateBuiltinKw(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("enumerate() expected one positional argument");
        return error.TypeError;
    }
    var start: i64 = 0;
    for (kw_names, kw_values) |n, v| {
        if (n != .str) {
            try interp.typeError("enumerate() keyword name must be str");
            return error.TypeError;
        }
        if (std.mem.eql(u8, n.str.bytes, "start")) {
            start = switch (v) {
                .small_int => |i| i,
                .boolean => |b| @intFromBool(b),
                else => {
                    try interp.typeError("enumerate() start must be int");
                    return error.TypeError;
                },
            };
        } else {
            try interp.typeError("enumerate() got an unexpected keyword argument");
            return error.TypeError;
        }
    }
    const EnumIter = @import("../object/enum_iter.zig").EnumIter;
    // Normalize the source: pass-through generators/enum_iters (lazy
    // already), wrap everything else in an Iter so iterStep stays a
    // single .iter / .generator / .enum_iter switch.
    const dispatch = @import("dispatch.zig");
    const src: Value = switch (args[0]) {
        .generator, .enum_iter, .iter => args[0],
        else => Value{ .iter = try dispatch.makeIter(interp, args[0]) },
    };
    const e = try EnumIter.init(interp.allocator, src, start);
    return Value{ .enum_iter = e };
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

/// Single-arg `type(obj)` only -- the metaclass / 3-arg form is
/// out of scope. Returns the runtime class for instances and
/// matching builtin classes for primitives.
pub fn typeBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("type() takes 1 argument");
        return error.TypeError;
    }
    return switch (args[0]) {
        .instance => |obj| Value{ .class = obj.cls },
        .class => |c| Value{ .class = c },
        .module => blk: {
            if (interp.module_type) |c| break :blk Value{ .class = c };
            const c = try Class.init(interp.allocator, "module", &.{}, try Dict.init(interp.allocator));
            interp.module_type = c;
            break :blk Value{ .class = c };
        },
        .complex_num => blk: {
            if (interp.complex_type) |c| break :blk Value{ .class = c };
            const c = try Class.init(interp.allocator, "complex", &.{}, try Dict.init(interp.allocator));
            interp.complex_type = c;
            break :blk Value{ .class = c };
        },
        .bytearray => blk: {
            if (interp.bytearray_type) |c| break :blk Value{ .class = c };
            const c = try Class.init(interp.allocator, "bytearray", &.{}, try Dict.init(interp.allocator));
            interp.bytearray_type = c;
            break :blk Value{ .class = c };
        },
        .bytes => blk: {
            if (interp.bytes_type) |c| break :blk Value{ .class = c };
            const c = try Class.init(interp.allocator, "bytes", &.{}, try Dict.init(interp.allocator));
            interp.bytes_type = c;
            break :blk Value{ .class = c };
        },
        .set => |s| blk: {
            if (s.frozen) {
                if (interp.frozenset_type) |c| break :blk Value{ .class = c };
                const c = try Class.init(interp.allocator, "frozenset", &.{}, try Dict.init(interp.allocator));
                interp.frozenset_type = c;
                break :blk Value{ .class = c };
            }
            if (interp.set_type) |c| break :blk Value{ .class = c };
            const c = try Class.init(interp.allocator, "set", &.{}, try Dict.init(interp.allocator));
            interp.set_type = c;
            break :blk Value{ .class = c };
        },
        else => |v| blk: {
            const name = v.typeName();
            if (interp.builtins.getStr(name)) |found| {
                if (found == .class) break :blk found;
            }
            try interp.typeError("type(): no class for primitive (zag)");
            break :blk error.TypeError;
        },
    };
}

pub fn bytesBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len == 0) {
        const out = try Bytes.init(interp.allocator, "");
        return Value{ .bytes = out };
    }
    const list = try materialize(interp, args[0]);
    var buf = try interp.allocator.alloc(u8, list.items.items.len);
    for (list.items.items, 0..) |v, i| {
        if (v != .small_int) {
            try interp.typeError("bytes() argument must be iterable of ints");
            return error.TypeError;
        }
        buf[i] = @intCast(v.small_int);
    }
    const out = try Bytes.fromOwnedSlice(interp.allocator, buf);
    return Value{ .bytes = out };
}

pub fn bytearrayBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const Bytearray = @import("../object/bytearray.zig").Bytearray;
    if (args.len == 0) {
        const out = try Bytearray.init(interp.allocator);
        return Value{ .bytearray = out };
    }
    switch (args[0]) {
        // bytearray(int) -> n zero bytes.
        .small_int => |n| {
            if (n < 0) {
                try interp.raisePy("ValueError", "negative count");
                return error.PyException;
            }
            const out = try Bytearray.zeroes(interp.allocator, @intCast(n));
            return Value{ .bytearray = out };
        },
        .bytes => |b| {
            const out = try Bytearray.fromSlice(interp.allocator, b.data);
            return Value{ .bytearray = out };
        },
        .bytearray => |b| {
            const out = try Bytearray.fromSlice(interp.allocator, b.data.items);
            return Value{ .bytearray = out };
        },
        else => {
            const list = try materialize(interp, args[0]);
            const out = try Bytearray.init(interp.allocator);
            for (list.items.items) |v| {
                const i: i64 = switch (v) {
                    .small_int => |x| x,
                    .boolean => |x| @intFromBool(x),
                    else => {
                        try interp.typeError("bytearray() argument must be iterable of ints");
                        return error.TypeError;
                    },
                };
                if (i < 0 or i > 255) {
                    try interp.raisePy("ValueError", "byte must be in range(0, 256)");
                    return error.PyException;
                }
                try out.data.append(interp.allocator, @intCast(i));
            }
            return Value{ .bytearray = out };
        },
    }
}

pub fn boolBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    _ = interp_opaque;
    if (args.len == 0) return Value{ .boolean = false };
    return Value{ .boolean = args[0].isTruthy() };
}

pub fn roundBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1 or args.len > 2) {
        try interp.typeError("round() takes 1 or 2 arguments");
        return error.TypeError;
    }
    const ndigits: ?i64 = if (args.len == 2) switch (args[1]) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        .none => null,
        else => {
            try interp.typeError("round() second argument must be int");
            return error.TypeError;
        },
    } else null;
    switch (args[0]) {
        .small_int => |i| {
            if (ndigits == null or ndigits.? >= 0) return Value{ .small_int = i };
            // Negative ndigits: round to multiple of 10^|n|. Banker's
            // rounding to mirror CPython.
            const f: f64 = @floatFromInt(i);
            const scale = std.math.pow(f64, 10.0, @floatFromInt(-ndigits.?));
            const r = roundHalfToEven(f / scale) * scale;
            return Value{ .small_int = @intFromFloat(r) };
        },
        .boolean => |b| return Value{ .small_int = @intFromBool(b) },
        .float => |f| {
            const n: i64 = ndigits orelse 0;
            const scale = std.math.pow(f64, 10.0, @floatFromInt(n));
            const r = roundHalfToEven(f * scale) / scale;
            if (ndigits == null) return Value{ .small_int = @intFromFloat(r) };
            return Value{ .float = r };
        },
        else => {
            try interp.typeError("round() argument must be a number");
            return error.TypeError;
        },
    }
}

/// Banker's rounding -- round-half-to-even, matching CPython's
/// `round()` and IEEE 754 `roundeven`. `@round` in Zig rounds away
/// from zero, which would diverge on `.5` ties.
fn roundHalfToEven(x: f64) f64 {
    const floor = @floor(x);
    const diff = x - floor;
    if (diff < 0.5) return floor;
    if (diff > 0.5) return floor + 1.0;
    // Exact tie -- pick the even neighbour.
    const fi: i64 = @intFromFloat(floor);
    if (@mod(fi, 2) == 0) return floor;
    return floor + 1.0;
}

pub fn reprBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("repr() takes exactly one argument");
        return error.TypeError;
    }
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try args[0].writeRepr(&w);
    const s = try Str.init(interp.allocator, w.buffered());
    return Value{ .str = s };
}

pub fn complexBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len > 2) {
        try interp.typeError("complex() takes at most 2 arguments");
        return error.TypeError;
    }
    var re: f64 = 0;
    var im: f64 = 0;
    if (args.len >= 1) {
        switch (args[0]) {
            .small_int => |i| re = @floatFromInt(i),
            .boolean => |b| re = if (b) 1.0 else 0.0,
            .float => |f| re = f,
            .complex_num => |c| {
                re = c.re;
                im = c.im;
            },
            else => {
                try interp.typeError("complex() first argument must be a number");
                return error.TypeError;
            },
        }
    }
    if (args.len == 2) {
        switch (args[1]) {
            .small_int => |i| im += @as(f64, @floatFromInt(i)),
            .boolean => |b| im += if (b) 1.0 else 0.0,
            .float => |f| im += f,
            .complex_num => |c| {
                re -= c.im;
                im += c.re;
            },
            else => {
                try interp.typeError("complex() second argument must be a number");
                return error.TypeError;
            },
        }
    }
    return Value{ .complex_num = .{ .re = re, .im = im } };
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
    try interp.registerBuiltin("tuple", tupleBuiltin);
    try interp.registerBuiltin("set", setBuiltin);
    try interp.registerBuiltin("frozenset", frozensetBuiltin);
    try interp.registerBuiltin("hash", hashBuiltin);
    try interp.registerBuiltin("dict", dictBuiltin);
    try interp.registerBuiltin("max", maxBuiltin);
    try interp.registerBuiltin("min", minBuiltin);
    try interp.registerBuiltin("reversed", reversedBuiltin);
    try interp.registerBuiltinKw("enumerate", enumerateBuiltin, enumerateBuiltinKw);
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
    try interp.registerBuiltin("complex", complexBuiltin);
    try interp.registerBuiltin("repr", reprBuiltin);
    try interp.registerBuiltin("bool", boolBuiltin);
    try interp.registerBuiltin("round", roundBuiltin);
    try interp.registerBuiltin("str", strBuiltin);
    try interp.registerBuiltin("bytes", bytesBuiltin);
    try interp.registerBuiltin("bytearray", bytearrayBuiltin);
    try interp.registerBuiltin("type", typeBuiltin);
    const dispatch = @import("dispatch.zig");
    try interp.registerBuiltin("__build_class__", dispatch.buildClass);
    try interp.registerBuiltin("isinstance", dispatch.isInstanceBuiltin);
    try interp.registerBuiltin("issubclass", dispatch.isSubclassBuiltin);
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
    const assertion_err = try Class.init(a, "AssertionError", &.{exception}, try Dict.init(a));
    const not_impl_err = try Class.init(a, "NotImplementedError", &.{runtime_err}, try Dict.init(a));
    const import_err = try Class.init(a, "ImportError", &.{exception}, try Dict.init(a));
    const mod_not_found = try Class.init(a, "ModuleNotFoundError", &.{import_err}, try Dict.init(a));

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
        .{ .name = "AssertionError", .cls = assertion_err },
        .{ .name = "NotImplementedError", .cls = not_impl_err },
        .{ .name = "ImportError", .cls = import_err },
        .{ .name = "ModuleNotFoundError", .cls = mod_not_found },
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
