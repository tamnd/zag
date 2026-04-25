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
const format_mod = @import("format.zig");

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
        if (a == .instance) {
            const s = try formatInstance(interp, a, .str);
            try w.writeAll(s);
        } else {
            try a.writeStr(w);
        }
    }
    try w.writeByte('\n');
    try w.flush();
    return Value.none;
}

const FormatKind = enum { repr, str };

/// Render an instance via `__str__` / `__repr__` (with `__str__`
/// falling back to `__repr__`). Returns the rendered bytes; falls
/// back to the default `<X object>` form if neither dunder exists.
pub fn formatInstance(interp: *Interp, v: Value, kind: FormatKind) ![]const u8 {
    const dunder = @import("dunder.zig");
    if (kind == .str) {
        if (try dunder.call(interp, v, "__str__", &.{})) |r| {
            if (r == .str) return r.str.bytes;
        }
    }
    if (try dunder.call(interp, v, "__repr__", &.{})) |r| {
        if (r == .str) return r.str.bytes;
    }
    var w = std.Io.Writer.Allocating.init(interp.allocator);
    if (kind == .str) try v.writeStr(&w.writer) else try v.writeRepr(&w.writer);
    return w.written();
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
        .instance => blk: {
            if (try @import("dunder.zig").call(interp, args[0], "__abs__", &.{})) |r| break :blk r;
            try interp.typeError("bad operand type for abs()");
            break :blk error.TypeError;
        },
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
        .memoryview => |m| Value{ .small_int = @intCast(m.len) },
        .tuple => |t| Value{ .small_int = @intCast(t.items.len) },
        .list => |l| Value{ .small_int = @intCast(l.items.items.len) },
        .dict => |d| Value{ .small_int = @intCast(d.count()) },
        .set => |s| Value{ .small_int = @intCast(s.items.items.len) },
        .deque => |d| Value{ .small_int = @intCast(d.items.items.items.len) },
        .counter => |c| Value{ .small_int = @intCast(c.data.count()) },
        .defaultdict => |d| Value{ .small_int = @intCast(d.data.count()) },
        .ordered_dict => |od| Value{ .small_int = @intCast(od.data.count()) },
        .named_tuple => |nt| Value{ .small_int = @intCast(nt.items.len) },
        .instance => blk: {
            if (try @import("dunder.zig").call(interp, args[0], "__len__", &.{})) |r| break :blk r;
            try interp.stderr.print(
                "TypeError: object of type '{s}' has no len()\n",
                .{args[0].typeName()},
            );
            try interp.stderr.flush();
            break :blk error.TypeError;
        },
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
        .memoryview => |m| for (m.data()) |x| try out.append(a, Value{ .small_int = @intCast(x) }),
        .dict => |d| for (d.keys.items) |k| {
            const piece = try Str.init(a, k);
            try out.append(a, Value{ .str = piece });
        },
        .set => |s| for (s.items.items) |x| try out.append(a, x),
        .deque => |d| for (d.items.items.items) |x| try out.append(a, x),
        .counter => |c| for (c.data.pairs.items) |p| try out.append(a, p.key),
        .defaultdict => |dd| for (dd.data.pairs.items) |p| try out.append(a, p.key),
        .ordered_dict => |od| for (od.data.pairs.items) |p| try out.append(a, p.key),
        .named_tuple => |nt| for (nt.items) |x| try out.append(a, x),
        .instance => {
            const dispatch = @import("dispatch.zig");
            const dunder = @import("dunder.zig");
            if (try dunder.call(interp, v, "__iter__", &.{})) |it_v| {
                while (try dispatch.iterStep(interp, it_v)) |x| try out.append(a, x);
            } else if (dunder.lookup(v, "__getitem__")) |_| {
                var i: i64 = 0;
                while (true) : (i += 1) {
                    const idx = Value{ .small_int = i };
                    const r = dunder.call(interp, v, "__getitem__", &.{idx}) catch |e| switch (e) {
                        error.PyException => {
                            if (interp.current_exc) |cur| {
                                if (cur == .instance and std.mem.eql(u8, cur.instance.cls.name, "IndexError")) {
                                    interp.current_exc = null;
                                    return out;
                                }
                            }
                            return e;
                        },
                        else => return e,
                    };
                    try out.append(a, r.?);
                }
            } else {
                try interp.typeError("object is not iterable");
                return error.TypeError;
            }
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
    const out = materialize(interp, args[0]) catch {
        try interp.typeError("sorted() argument must be iterable");
        return error.TypeError;
    };
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
    if (args[0] == .bytearray) {
        try interp.raisePy("TypeError", "unhashable type: 'bytearray'");
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
    if (args[0] == .instance) {
        if (try @import("dunder.zig").call(interp, args[0], "__hash__", &.{})) |r| return r;
    }
    return Value{ .small_int = 0 };
}

pub fn dictBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const d = try Dict.init(interp.allocator);
    if (args.len == 0) return Value{ .dict = d };
    // Copy from existing dict-shaped containers directly to preserve
    // insertion order and avoid the iter-of-pairs path.
    switch (args[0]) {
        .dict => |src| {
            for (src.pairs.items) |p| try d.setKey(interp.allocator, p.key, p.value);
            return Value{ .dict = d };
        },
        .defaultdict => |dd| {
            for (dd.data.pairs.items) |p| try d.setKey(interp.allocator, p.key, p.value);
            return Value{ .dict = d };
        },
        .ordered_dict => |od| {
            for (od.data.pairs.items) |p| try d.setKey(interp.allocator, p.key, p.value);
            return Value{ .dict = d };
        },
        .counter => |c| {
            for (c.data.pairs.items) |p| try d.setKey(interp.allocator, p.key, p.value);
            return Value{ .dict = d };
        },
        else => {},
    }
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
    return intBuiltinKw(interp_opaque, args, &.{}, &.{});
}

pub fn intBuiltinKw(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    var base: ?u8 = null;
    if (args.len >= 2) {
        switch (args[1]) {
            .small_int => |b| base = @intCast(b),
            else => {},
        }
    }
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "base")) {
            switch (kv) {
                .small_int => |b| base = @intCast(b),
                else => {},
            }
        }
    }
    if (args.len == 0) return Value{ .small_int = 0 };
    return switch (args[0]) {
        .small_int => args[0],
        .boolean => |b| Value{ .small_int = @intFromBool(b) },
        .float => |f| Value{ .small_int = @intFromFloat(f) },
        .str => |s| blk: {
            const trimmed = std.mem.trim(u8, s.bytes, " \t");
            const radix: u8 = base orelse 10;
            const v = std.fmt.parseInt(i64, trimmed, radix) catch {
                try interp.raisePy("ValueError", "invalid literal for int()");
                break :blk error.PyException;
            };
            break :blk Value{ .small_int = v };
        },
        .instance => blk: {
            if (try @import("dunder.zig").call(interp, args[0], "__int__", &.{})) |r| break :blk r;
            if (try @import("dunder.zig").call(interp, args[0], "__index__", &.{})) |r| break :blk r;
            try interp.typeError("int() argument must be str, bytes, or number");
            break :blk error.TypeError;
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
        .instance => blk: {
            if (try @import("dunder.zig").call(interp, args[0], "__float__", &.{})) |r| break :blk r;
            try interp.typeError("float() argument must be str or number");
            break :blk error.TypeError;
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
        .memoryview => blk: {
            if (interp.memoryview_type) |c| break :blk Value{ .class = c };
            const c = try Class.init(interp.allocator, "memoryview", &.{}, try Dict.init(interp.allocator));
            interp.memoryview_type = c;
            break :blk Value{ .class = c };
        },
        .ellipsis => blk: {
            if (interp.ellipsis_type) |c| break :blk Value{ .class = c };
            const c = try Class.init(interp.allocator, "ellipsis", &.{}, try Dict.init(interp.allocator));
            interp.ellipsis_type = c;
            break :blk Value{ .class = c };
        },
        .not_implemented => blk: {
            if (interp.not_implemented_type) |c| break :blk Value{ .class = c };
            const c = try Class.init(interp.allocator, "NotImplementedType", &.{}, try Dict.init(interp.allocator));
            interp.not_implemented_type = c;
            break :blk Value{ .class = c };
        },
        .slice => blk: {
            if (interp.slice_type) |c| break :blk Value{ .class = c };
            const c = try Class.init(interp.allocator, "slice", &.{}, try Dict.init(interp.allocator));
            interp.slice_type = c;
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
    switch (args[0]) {
        .bytes => |b| {
            const out = try Bytes.init(interp.allocator, b.data);
            return Value{ .bytes = out };
        },
        .bytearray => |b| {
            const out = try Bytes.init(interp.allocator, b.data.items);
            return Value{ .bytes = out };
        },
        .memoryview => |m| {
            const out = try Bytes.init(interp.allocator, m.data());
            return Value{ .bytes = out };
        },
        else => {},
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

pub fn memoryviewBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const Memoryview = @import("../object/memoryview.zig").Memoryview;
    if (args.len != 1) {
        try interp.typeError("memoryview() takes exactly one argument");
        return error.TypeError;
    }
    return switch (args[0]) {
        .bytes => |b| Value{ .memoryview = try Memoryview.fromBytes(interp.allocator, b) },
        .bytearray => |b| Value{ .memoryview = try Memoryview.fromBytearray(interp.allocator, b) },
        .memoryview => |m| Value{ .memoryview = try m.slice(interp.allocator, 0, m.len) },
        else => {
            try interp.typeError("memoryview: a bytes-like object is required");
            return error.TypeError;
        },
    };
}

pub fn boolBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len == 0) return Value{ .boolean = false };
    if (args[0] == .instance) {
        if (try @import("dunder.zig").call(interp, args[0], "__bool__", &.{})) |r| {
            return Value{ .boolean = r.isTruthy() };
        }
        if (try @import("dunder.zig").call(interp, args[0], "__len__", &.{})) |r| {
            const n: i64 = switch (r) {
                .small_int => |i| i,
                .boolean => |x| @intFromBool(x),
                else => 1,
            };
            return Value{ .boolean = n != 0 };
        }
        return Value{ .boolean = true };
    }
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
        .instance => {
            const dunder = @import("dunder.zig");
            if (args.len == 2) {
                if (try dunder.call(interp, args[0], "__round__", &.{args[1]})) |r| return r;
            } else {
                if (try dunder.call(interp, args[0], "__round__", &.{})) |r| return r;
            }
            try interp.typeError("round() argument must be a number");
            return error.TypeError;
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
    if (args[0] == .instance) {
        const bytes = try formatInstance(interp, args[0], .repr);
        const s = try Str.init(interp.allocator, bytes);
        return Value{ .str = s };
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

/// `pow(b, e)` and `pow(b, e, m)`. The 3-arg form requires int args
/// and computes `b ** e mod m` with the modular-inverse trick when
/// `e` is negative.
pub fn powBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 2 or args.len > 3) {
        try interp.typeError("pow() takes 2 or 3 arguments");
        return error.TypeError;
    }
    const has_mod = args.len == 3;
    if (has_mod) {
        const b = try intArgFlex(interp, args[0]);
        const e = try intArgFlex(interp, args[1]);
        const m = try intArgFlex(interp, args[2]);
        if (m == 0) {
            try interp.raisePy("ValueError", "pow() 3rd argument cannot be 0");
            return error.PyException;
        }
        var base: i128 = b;
        var exp: i128 = e;
        const mod: i128 = m;
        if (exp < 0) {
            const inv = modInverse(@mod(base, mod), mod) orelse {
                try interp.raisePy("ValueError", "base is not invertible for the given modulus");
                return error.PyException;
            };
            base = inv;
            exp = -exp;
        }
        var result: i128 = @mod(@as(i128, 1), mod);
        var b_acc: i128 = @mod(base, mod);
        if (b_acc < 0) b_acc += mod;
        while (exp > 0) {
            if ((exp & 1) == 1) result = @mod(result * b_acc, mod);
            exp >>= 1;
            if (exp > 0) b_acc = @mod(b_acc * b_acc, mod);
        }
        if (result < 0) result += mod;
        return Value{ .small_int = @intCast(result) };
    }
    // 2-arg: integer fast path -> int when exponent is non-negative,
    // float otherwise. Float bases always go through pow(f64).
    if ((args[0] == .small_int or args[0] == .boolean) and (args[1] == .small_int or args[1] == .boolean)) {
        const b = try intArgFlex(interp, args[0]);
        const e = try intArgFlex(interp, args[1]);
        if (e < 0) {
            const f = std.math.pow(f64, @floatFromInt(b), @floatFromInt(e));
            return Value{ .float = f };
        }
        return integerPow(interp, b, e);
    }
    const bf: f64 = switch (args[0]) {
        .small_int => |i| @floatFromInt(i),
        .boolean => |b| if (b) 1.0 else 0.0,
        .float => |f| f,
        else => {
            try interp.typeError("pow() base must be a number");
            return error.TypeError;
        },
    };
    const ef: f64 = switch (args[1]) {
        .small_int => |i| @floatFromInt(i),
        .boolean => |b| if (b) 1.0 else 0.0,
        .float => |f| f,
        else => {
            try interp.typeError("pow() exponent must be a number");
            return error.TypeError;
        },
    };
    return Value{ .float = std.math.pow(f64, bf, ef) };
}

fn integerPow(interp: *Interp, base: i64, exp: i64) !Value {
    const BigInt = @import("../object/bigint.zig").BigInt;
    if (exp == 0) return Value{ .small_int = 1 };
    if (base == 0) return Value{ .small_int = 0 };
    if (base == 1) return Value{ .small_int = 1 };
    if (base == -1) return Value{ .small_int = if (@mod(exp, 2) == 0) 1 else -1 };
    // Try i64 fast path with overflow check.
    var result: i64 = 1;
    var b_acc: i64 = base;
    var e: u64 = @intCast(exp);
    var overflowed = false;
    while (e > 0 and !overflowed) {
        if ((e & 1) == 1) {
            const r = @mulWithOverflow(result, b_acc);
            if (r[1] != 0) {
                overflowed = true;
                break;
            }
            result = r[0];
        }
        e >>= 1;
        if (e > 0) {
            const r = @mulWithOverflow(b_acc, b_acc);
            if (r[1] != 0) {
                overflowed = true;
                break;
            }
            b_acc = r[0];
        }
    }
    if (!overflowed) return Value{ .small_int = result };
    // Promote to bigint and finish.
    var acc = try std.math.big.int.Managed.initSet(interp.allocator, base);
    const u32_exp: u32 = @intCast(exp);
    var out = try std.math.big.int.Managed.init(interp.allocator);
    try out.pow(&acc, u32_exp);
    acc.deinit();
    const bi = try BigInt.fromManaged(interp.allocator, out);
    return Value{ .big_int = bi };
}

fn intArgFlex(interp: *Interp, v: Value) !i64 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        else => {
            try interp.typeError("an integer is required");
            return error.TypeError;
        },
    };
}

/// Extended Euclidean to find the modular inverse of `a` mod `m`.
/// Returns null when `gcd(a, m) != 1`. Caller has already taken
/// `a mod m` so 0 <= a < |m|.
fn modInverse(a: i128, m: i128) ?i128 {
    var old_r: i128 = a;
    var r: i128 = if (m < 0) -m else m;
    var old_s: i128 = 1;
    var s: i128 = 0;
    while (r != 0) {
        const q = @divTrunc(old_r, r);
        const new_r = old_r - q * r;
        old_r = r;
        r = new_r;
        const new_s = old_s - q * s;
        old_s = s;
        s = new_s;
    }
    if (old_r != 1 and old_r != -1) return null;
    var inv = if (old_r == -1) -old_s else old_s;
    const am = if (m < 0) -m else m;
    inv = @mod(inv, am);
    if (inv < 0) inv += am;
    return inv;
}

pub fn divmodBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2) {
        try interp.typeError("divmod() takes exactly 2 arguments");
        return error.TypeError;
    }
    if (args[0] == .instance or args[1] == .instance) {
        const dunder = @import("dunder.zig");
        if (try dunder.binop(interp, args[0], args[1], "__divmod__", "__rdivmod__")) |r| return r;
    }
    if (args[0] == .small_int and args[1] == .small_int) {
        const a = args[0].small_int;
        const b = args[1].small_int;
        if (b == 0) {
            try interp.raisePy("ZeroDivisionError", "integer division or modulo by zero");
            return error.PyException;
        }
        const q = @divFloor(a, b);
        const r = @mod(a, b);
        const t = try @import("../object/tuple.zig").Tuple.init(interp.allocator, 2);
        t.items[0] = Value{ .small_int = q };
        t.items[1] = Value{ .small_int = r };
        return Value{ .tuple = t };
    }
    try interp.typeError("divmod() unsupported operand types");
    return error.TypeError;
}

pub fn formatBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1 or args.len > 2) {
        try interp.typeError("format() takes 1 or 2 arguments");
        return error.TypeError;
    }
    const spec_str: []const u8 = if (args.len == 2) switch (args[1]) {
        .str => |s| s.bytes,
        else => {
            try interp.typeError("format() spec must be a str");
            return error.TypeError;
        },
    } else "";
    if (args[0] == .instance) {
        const spec_v = if (args.len == 2) args[1] else blk: {
            const empty = try Str.init(interp.allocator, "");
            break :blk Value{ .str = empty };
        };
        if (try @import("dunder.zig").call(interp, args[0], "__format__", &.{spec_v})) |r| return r;
    }
    const buf = try format_mod.format(interp.allocator, args[0], spec_str);
    const s = try Str.fromOwnedSlice(interp.allocator, buf);
    return Value{ .str = s };
}

/// `ascii(obj)` is `repr(obj)` with non-ASCII bytes inside string
/// literals escaped as `\xHH` / `\uHHHH` / `\UHHHHHHHH`. Containers
/// (list/tuple/dict/set) are walked so nested strings get the same
/// treatment.
pub fn asciiBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("ascii() takes exactly one argument");
        return error.TypeError;
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(interp.allocator);
    try writeAsciiRepr(interp.allocator, &out, args[0]);
    const s = try Str.init(interp.allocator, out.items);
    return Value{ .str = s };
}

fn writeAsciiRepr(a: std.mem.Allocator, out: *std.ArrayList(u8), v: Value) anyerror!void {
    switch (v) {
        .str => |s| {
            try out.append(a, '\'');
            try escapeAsciiStr(a, out, s.bytes);
            try out.append(a, '\'');
        },
        .list => |lst| {
            try out.append(a, '[');
            for (lst.items.items, 0..) |item, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try writeAsciiRepr(a, out, item);
            }
            try out.append(a, ']');
        },
        .tuple => |tup| {
            try out.append(a, '(');
            for (tup.items, 0..) |item, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try writeAsciiRepr(a, out, item);
            }
            if (tup.items.len == 1) try out.append(a, ',');
            try out.append(a, ')');
        },
        .dict => |d| {
            try out.append(a, '{');
            var first = true;
            for (d.keys.items) |k| {
                if (!first) try out.appendSlice(a, ", ");
                first = false;
                try out.append(a, '\'');
                try escapeAsciiStr(a, out, k);
                try out.append(a, '\'');
                try out.appendSlice(a, ": ");
                const val = d.getStr(k).?;
                try writeAsciiRepr(a, out, val);
            }
            try out.append(a, '}');
        },
        .set => |sv| {
            if (sv.items.items.len == 0) {
                try out.appendSlice(a, "set()");
            } else {
                try out.append(a, '{');
                for (sv.items.items, 0..) |item, i| {
                    if (i > 0) try out.appendSlice(a, ", ");
                    try writeAsciiRepr(a, out, item);
                }
                try out.append(a, '}');
            }
        },
        else => {
            // Fall back to repr for non-string non-container values;
            // their reprs are pure ASCII already.
            var buf: [4096]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try v.writeRepr(&w);
            try out.appendSlice(a, w.buffered());
        },
    }
}

fn escapeAsciiStr(a: std.mem.Allocator, out: *std.ArrayList(u8), body: []const u8) !void {
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c < 0x80) {
            switch (c) {
                '\\' => try out.appendSlice(a, "\\\\"),
                '\'' => try out.appendSlice(a, "\\'"),
                '\n' => try out.appendSlice(a, "\\n"),
                '\r' => try out.appendSlice(a, "\\r"),
                '\t' => try out.appendSlice(a, "\\t"),
                else => {
                    if (c < 0x20 or c == 0x7f) {
                        var tmp: [4]u8 = undefined;
                        const s = try std.fmt.bufPrint(&tmp, "\\x{x:0>2}", .{c});
                        try out.appendSlice(a, s);
                    } else {
                        try out.append(a, c);
                    }
                },
            }
            i += 1;
            continue;
        }
        // Decode one UTF-8 codepoint.
        const len = std.unicode.utf8ByteSequenceLength(c) catch {
            try out.append(a, c);
            i += 1;
            continue;
        };
        if (i + len > body.len) {
            try out.append(a, c);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(body[i .. i + len]) catch {
            try out.append(a, c);
            i += 1;
            continue;
        };
        if (cp <= 0xff) {
            var tmp: [4]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "\\x{x:0>2}", .{cp});
            try out.appendSlice(a, s);
        } else if (cp <= 0xffff) {
            var tmp: [6]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{cp});
            try out.appendSlice(a, s);
        } else {
            var tmp: [10]u8 = undefined;
            const s = try std.fmt.bufPrint(&tmp, "\\U{x:0>8}", .{cp});
            try out.appendSlice(a, s);
        }
        i += len;
    }
}

pub fn sliceBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const Slice = @import("../object/slice.zig").Slice;
    var start: Value = Value.none;
    var stop: Value = Value.none;
    var step: Value = Value.none;
    switch (args.len) {
        1 => stop = args[0],
        2 => {
            start = args[0];
            stop = args[1];
        },
        3 => {
            start = args[0];
            stop = args[1];
            step = args[2];
        },
        else => {
            try interp.typeError("slice expected 1 to 3 arguments");
            return error.TypeError;
        },
    }
    const sl = try Slice.init(interp.allocator, start, stop, step);
    return Value{ .slice = sl };
}

pub fn hasattrBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2 or args[1] != .str) {
        try interp.typeError("hasattr() takes (obj, str)");
        return error.TypeError;
    }
    const name = args[1].str.bytes;
    return Value{ .boolean = lookupAttr(args[0], name) != null };
}

pub fn getattrBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 2 or args.len > 3 or args[1] != .str) {
        try interp.typeError("getattr() takes (obj, str[, default])");
        return error.TypeError;
    }
    const name = args[1].str.bytes;
    if (lookupAttr(args[0], name)) |v| return v;
    if (args.len == 3) return args[2];
    try interp.attributeError(args[0].typeName(), name);
    return error.AttributeError;
}

pub fn setattrBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 3 or args[1] != .str) {
        try interp.typeError("setattr() takes (obj, str, value)");
        return error.TypeError;
    }
    const name = args[1].str.bytes;
    if (args[0] == .instance) {
        try args[0].instance.dict.setStr(interp.allocator, name, args[2]);
        return Value.none;
    }
    try interp.typeError("setattr: target object has no writable attributes");
    return error.TypeError;
}

pub fn delattrBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2 or args[1] != .str) {
        try interp.typeError("delattr() takes (obj, str)");
        return error.TypeError;
    }
    const name = args[1].str.bytes;
    if (args[0] == .instance) {
        if (args[0].instance.dict.delete(name)) return Value.none;
        const msg = try std.fmt.allocPrint(
            interp.allocator,
            "'{s}' object has no attribute '{s}'",
            .{ args[0].typeName(), name },
        );
        defer interp.allocator.free(msg);
        try interp.raisePy("AttributeError", msg);
        return error.PyException;
    }
    try interp.raisePy("TypeError", "delattr: target object is immutable");
    return error.PyException;
}

fn lookupAttr(obj: Value, name: []const u8) ?Value {
    return switch (obj) {
        .instance => |inst| inst.dict.getStr(name) orelse inst.cls.lookup(name),
        .class => |cls| cls.lookup(name),
        .module => |m| m.attrs.getStr(name),
        else => null,
    };
}

pub fn dirBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("dir() takes exactly one argument in zag");
        return error.TypeError;
    }
    const out = try List.init(interp.allocator);
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(interp.allocator);
    const a = interp.allocator;
    switch (args[0]) {
        .instance => |inst| {
            for (inst.dict.keys.items) |k| {
                if (seen.contains(k)) continue;
                try seen.put(a, k, {});
                const s = try Str.init(a, k);
                try out.append(a, Value{ .str = s });
            }
            for (inst.cls.mro) |cls| {
                for (cls.dict.keys.items) |k| {
                    if (seen.contains(k)) continue;
                    try seen.put(a, k, {});
                    const s = try Str.init(a, k);
                    try out.append(a, Value{ .str = s });
                }
            }
        },
        .class => |cls| {
            for (cls.mro) |c| {
                for (c.dict.keys.items) |k| {
                    if (seen.contains(k)) continue;
                    try seen.put(a, k, {});
                    const s = try Str.init(a, k);
                    try out.append(a, Value{ .str = s });
                }
            }
        },
        .module => |m| {
            for (m.attrs.keys.items) |k| {
                if (seen.contains(k)) continue;
                try seen.put(a, k, {});
                const s = try Str.init(a, k);
                try out.append(a, Value{ .str = s });
            }
        },
        else => {},
    }
    std.sort.pdq(Value, out.items.items, {}, lessThanForSort);
    return Value{ .list = out };
}

pub fn strBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len == 0) {
        const piece = try Str.init(interp.allocator, "");
        return Value{ .str = piece };
    }
    if (args[0] == .str) return args[0];
    if (args[0] == .instance) {
        const bytes = try formatInstance(interp, args[0], .str);
        const piece = try Str.init(interp.allocator, bytes);
        return Value{ .str = piece };
    }
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
    try interp.registerBuiltinKw("int", intBuiltin, intBuiltinKw);
    try interp.registerBuiltin("float", floatBuiltin);
    try interp.registerBuiltin("complex", complexBuiltin);
    try interp.registerBuiltin("repr", reprBuiltin);
    try interp.registerBuiltin("bool", boolBuiltin);
    try interp.registerBuiltin("round", roundBuiltin);
    try interp.registerBuiltin("str", strBuiltin);
    try interp.registerBuiltin("bytes", bytesBuiltin);
    try interp.registerBuiltin("bytearray", bytearrayBuiltin);
    try interp.registerBuiltin("memoryview", memoryviewBuiltin);
    try interp.registerBuiltin("type", typeBuiltin);
    const dispatch = @import("dispatch.zig");
    try interp.registerBuiltinKw("__build_class__", dispatch.buildClass, dispatch.buildClassKw);
    try interp.registerBuiltin("isinstance", dispatch.isInstanceBuiltin);
    try interp.registerBuiltin("issubclass", dispatch.isSubclassBuiltin);
    try interp.registerBuiltin("super", superBuiltin);
    try interp.registerBuiltin("property", propertyBuiltin);
    try interp.registerBuiltin("classmethod", classmethodBuiltin);
    try interp.registerBuiltin("staticmethod", staticmethodBuiltin);
    try interp.registerBuiltin("next", dispatch.nextBuiltin);
    try interp.registerBuiltin("iter", dispatch.iterBuiltin);
    try interp.registerBuiltin("pow", powBuiltin);
    try interp.registerBuiltin("format", formatBuiltin);
    try interp.registerBuiltin("divmod", divmodBuiltin);
    try interp.registerBuiltin("ascii", asciiBuiltin);
    try interp.registerBuiltin("slice", sliceBuiltin);
    try interp.registerBuiltin("hasattr", hasattrBuiltin);
    try interp.registerBuiltin("getattr", getattrBuiltin);
    try interp.registerBuiltin("setattr", setattrBuiltin);
    try interp.registerBuiltin("delattr", delattrBuiltin);
    try interp.registerBuiltin("dir", dirBuiltin);
    try interp.builtins.setStr(interp.allocator, "Ellipsis", Value.ellipsis);
    try interp.builtins.setStr(interp.allocator, "NotImplemented", Value.not_implemented);
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
