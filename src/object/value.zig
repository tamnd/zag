//! The tagged-union runtime value. Every Python-visible thing that
//! the VM pushes on the operand stack, stores in a local, or puts in
//! a collection is a `Value`.
//!
//! Heap arms are single-indirection pointers owned by an allocator
//! kept on the `Interp`. Milestone 1 leaks heap objects at process
//! exit; that is deliberate and called out in the README.

const std = @import("std");

const Str = @import("string.zig").Str;
const Bytes = @import("bytes.zig").Bytes;
const Bytearray = @import("bytearray.zig").Bytearray;
const Memoryview = @import("memoryview.zig").Memoryview;
const Tuple = @import("tuple.zig").Tuple;
const List = @import("list.zig").List;
const Dict = @import("dict.zig").Dict;
const Code = @import("code.zig").Code;
const Slice = @import("slice.zig").Slice;
const Iter = @import("iter.zig").Iter;
const Function = @import("function.zig").Function;
const Cell = @import("cell.zig").Cell;
const Class = @import("class.zig").Class;
const Instance = @import("instance.zig").Instance;
const Descriptor = @import("descriptor.zig").Descriptor;
const Generator = @import("generator.zig").Generator;
const Set = @import("set.zig").Set;
const EnumIter = @import("enum_iter.zig").EnumIter;
const Module = @import("module.zig").Module;
const BigInt = @import("bigint.zig").BigInt;
const BoundMethod = @import("bound_method.zig").BoundMethod;
const Partial = @import("partial.zig").Partial;
const CachedFn = @import("cached_fn.zig").CachedFn;
const CachedProperty = @import("cached_property.zig").CachedProperty;
const Deque = @import("deque.zig").Deque;
const Counter = @import("counter.zig").Counter;
const DefaultDict = @import("defaultdict.zig").DefaultDict;
const OrderedDict = @import("ordered_dict.zig").OrderedDict;
const NamedTuple = @import("named_tuple.zig").NamedTuple;
const NamedTupleFactory = @import("named_tuple.zig").NamedTupleFactory;

pub const Tag = enum(u8) {
    none,
    boolean,
    small_int,
    big_int,
    float,
    complex_num,
    str,
    bytes,
    bytearray,
    memoryview,
    tuple,
    list,
    dict,
    code,
    builtin_fn,
    bound_method,
    partial,
    cached_fn,
    cached_property,
    function,
    cell,
    class,
    instance,
    slice,
    iter,
    descriptor,
    generator,
    set,
    enum_iter,
    module,
    deque,
    counter,
    defaultdict,
    ordered_dict,
    named_tuple,
    named_tuple_factory,
    /// `...` / `Ellipsis` singleton.
    ellipsis,
    /// `NotImplemented` singleton -- distinct from the
    /// `NotImplementedError` exception class.
    not_implemented,
    /// Placeholder pushed by PUSH_NULL. Distinct from `.none` — CPython
    /// uses `NULL` as a C-level sentinel before a CALL and `None` as a
    /// real Python value.
    null_sentinel,
};

pub const BuiltinFnPtr = *const fn (
    interp: *anyopaque, // *vm.interp.Interp; avoid circular import at comptime
    args: []const Value,
) anyerror!Value;

pub const BuiltinKwFnPtr = *const fn (
    interp: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value;

pub const BuiltinFn = struct {
    name: []const u8,
    func: BuiltinFnPtr,
    /// Optional kwarg-aware variant. When a CALL_KW lands on a builtin
    /// with this set, the dispatcher routes through `kw_func` instead
    /// of rejecting the call. Builtins without it stay positional-only.
    kw_func: ?BuiltinKwFnPtr = null,
};

pub const Complex = struct { re: f64, im: f64 };

pub const Value = union(Tag) {
    none,
    boolean: bool,
    small_int: i64,
    big_int: *BigInt,
    float: f64,
    complex_num: Complex,
    str: *Str,
    bytes: *Bytes,
    bytearray: *Bytearray,
    memoryview: *Memoryview,
    tuple: *Tuple,
    list: *List,
    dict: *Dict,
    code: *Code,
    builtin_fn: *BuiltinFn,
    bound_method: *BoundMethod,
    partial: *Partial,
    cached_fn: *CachedFn,
    cached_property: *CachedProperty,
    function: *Function,
    cell: *Cell,
    class: *Class,
    instance: *Instance,
    slice: *Slice,
    iter: *Iter,
    descriptor: *Descriptor,
    generator: *Generator,
    set: *Set,
    enum_iter: *EnumIter,
    module: *Module,
    deque: *Deque,
    counter: *Counter,
    defaultdict: *DefaultDict,
    ordered_dict: *OrderedDict,
    named_tuple: *NamedTuple,
    named_tuple_factory: *NamedTupleFactory,
    ellipsis,
    not_implemented,
    null_sentinel,

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .none, .null_sentinel => false,
            .boolean => |b| b,
            .small_int => |i| i != 0,
            .big_int => |bi| !bi.inner.eqlZero(),
            .float => |f| f != 0.0,
            .complex_num => |c| c.re != 0.0 or c.im != 0.0,
            .str => |s| s.bytes.len != 0,
            .bytes => |b| b.data.len != 0,
            .bytearray => |b| b.data.items.len != 0,
            .memoryview => |m| m.len != 0,
            .tuple => |t| t.items.len != 0,
            .list => |l| l.items.items.len != 0,
            .dict => |d| d.count() != 0,
            .set => |s| s.items.items.len != 0,
            .ellipsis, .not_implemented => true,
            .code, .builtin_fn, .bound_method, .partial, .cached_fn, .cached_property, .function, .cell, .class, .instance, .slice, .iter, .descriptor, .generator, .enum_iter, .module, .named_tuple_factory => true,
            .deque => |d| d.items.items.items.len != 0,
            .counter => |c| c.data.count() != 0,
            .defaultdict => |dd| dd.data.count() != 0,
            .ordered_dict => |od| od.data.count() != 0,
            .named_tuple => |nt| nt.items.len != 0,
        };
    }

    /// Python `repr()` for a small set of types. Enough to format the
    /// None/Bool/Int/Str cases the hello fixture exercises via print().
    pub fn writeRepr(self: Value, w: *std.Io.Writer) !void {
        switch (self) {
            .none => try w.writeAll("None"),
            .null_sentinel => try w.writeAll("<NULL>"),
            .boolean => |b| try w.writeAll(if (b) "True" else "False"),
            .small_int => |i| try w.print("{d}", .{i}),
            .big_int => |bi| {
                const a = bi.inner.allocator;
                const s = try bi.toString10(a);
                defer a.free(s);
                try w.writeAll(s);
            },
            .float => |f| try writeFloat(w, f),
            .complex_num => |c| try writeComplex(w, c),
            .str => |s| try writeStrRepr(w, s.bytes),
            .bytes => |b| {
                try w.writeAll("b'");
                try writeBytesContent(w, b.data);
                try w.writeByte('\'');
            },
            .bytearray => |b| {
                try w.writeAll("bytearray(b'");
                try writeBytesContent(w, b.data.items);
                try w.writeAll("')");
            },
            .memoryview => |m| try w.print("<memory at 0x{x}>", .{@intFromPtr(m)}),
            .tuple => |t| {
                try w.writeByte('(');
                for (t.items, 0..) |it, i| {
                    if (i != 0) try w.writeAll(", ");
                    try it.writeRepr(w);
                }
                if (t.items.len == 1) try w.writeByte(',');
                try w.writeByte(')');
            },
            .list => |l| {
                try w.writeByte('[');
                for (l.items.items, 0..) |it, i| {
                    if (i != 0) try w.writeAll(", ");
                    try it.writeRepr(w);
                }
                try w.writeByte(']');
            },
            .dict => |d| {
                try w.writeByte('{');
                for (d.pairs.items, 0..) |p, i| {
                    if (i != 0) try w.writeAll(", ");
                    try p.key.writeRepr(w);
                    try w.writeAll(": ");
                    try p.value.writeRepr(w);
                }
                try w.writeByte('}');
            },
            .set => |s| {
                if (s.frozen) {
                    if (s.items.items.len == 0) {
                        try w.writeAll("frozenset()");
                        return;
                    }
                    try w.writeAll("frozenset(");
                }
                if (s.items.items.len == 0 and !s.frozen) {
                    try w.writeAll("set()");
                    return;
                }
                try w.writeByte('{');
                for (s.items.items, 0..) |it, i| {
                    if (i != 0) try w.writeAll(", ");
                    try it.writeRepr(w);
                }
                try w.writeByte('}');
                if (s.frozen) try w.writeByte(')');
            },
            .code => |c| try w.print("<code object {s}>", .{c.name}),
            .builtin_fn => |f| try w.print("<built-in function {s}>", .{f.name}),
            .bound_method => |bm| switch (bm.func) {
                .builtin_fn => |f| try w.print("<built-in method {s}>", .{f.name}),
                else => try w.writeAll("<bound method>"),
            },
            .partial => try w.writeAll("functools.partial(...)"),
            .cached_fn => try w.writeAll("<cached function>"),
            .cached_property => try w.writeAll("<cached_property>"),
            .function => |f| try w.print("<function {s}>", .{f.code.qualname}),
            .cell => try w.writeAll("<cell>"),
            .class => |c| try w.print("<class '{s}'>", .{c.name}),
            .instance => |obj| {
                if (std.mem.eql(u8, obj.cls.name, "Interpolation")) {
                    const v = obj.dict.getStr("value") orelse Value.none;
                    const e = obj.dict.getStr("expression") orelse Value.none;
                    const c = obj.dict.getStr("conversion") orelse Value.none;
                    const f = obj.dict.getStr("format_spec") orelse Value.none;
                    try w.writeAll("Interpolation(");
                    try v.writeRepr(w);
                    try w.writeAll(", ");
                    try e.writeRepr(w);
                    try w.writeAll(", ");
                    try c.writeRepr(w);
                    try w.writeAll(", ");
                    try f.writeRepr(w);
                    try w.writeByte(')');
                } else {
                    try w.print("<{s} object>", .{obj.cls.name});
                }
            },
            .iter => try w.writeAll("<iterator>"),
            .generator => try w.writeAll("<generator>"),
            .enum_iter => try w.writeAll("<enumerate object>"),
            .module => |m| try w.print("<module '{s}'>", .{m.name}),
            .descriptor => |d| switch (d.kind) {
                .property => try w.writeAll("<property object>"),
                .classmethod => try w.writeAll("<classmethod object>"),
                .staticmethod => try w.writeAll("<staticmethod object>"),
            },
            .slice => |sl| {
                try w.writeAll("slice(");
                try sl.start.writeRepr(w);
                try w.writeAll(", ");
                try sl.stop.writeRepr(w);
                try w.writeAll(", ");
                try sl.step.writeRepr(w);
                try w.writeByte(')');
            },
            .ellipsis => try w.writeAll("Ellipsis"),
            .not_implemented => try w.writeAll("NotImplemented"),
            .deque => |dq| {
                try w.writeAll("deque([");
                for (dq.items.items.items, 0..) |it, i| {
                    if (i != 0) try w.writeAll(", ");
                    try it.writeRepr(w);
                }
                try w.writeByte(']');
                if (dq.maxlen) |ml| try w.print(", maxlen={d}", .{ml});
                try w.writeByte(')');
            },
            .counter => |c| {
                try w.writeAll("Counter({");
                for (c.data.pairs.items, 0..) |p, i| {
                    if (i != 0) try w.writeAll(", ");
                    try p.key.writeRepr(w);
                    try w.writeAll(": ");
                    try p.value.writeRepr(w);
                }
                try w.writeAll("})");
            },
            .defaultdict => |dd| {
                try w.writeAll("defaultdict(");
                try dd.factory.writeRepr(w);
                try w.writeAll(", {");
                for (dd.data.pairs.items, 0..) |p, i| {
                    if (i != 0) try w.writeAll(", ");
                    try p.key.writeRepr(w);
                    try w.writeAll(": ");
                    try p.value.writeRepr(w);
                }
                try w.writeAll("})");
            },
            .ordered_dict => |od| {
                try w.writeAll("OrderedDict({");
                for (od.data.pairs.items, 0..) |p, i| {
                    if (i != 0) try w.writeAll(", ");
                    try p.key.writeRepr(w);
                    try w.writeAll(": ");
                    try p.value.writeRepr(w);
                }
                try w.writeAll("})");
            },
            .named_tuple => |nt| {
                try w.print("{s}(", .{nt.factory.type_name});
                for (nt.factory.fields, nt.items, 0..) |fname, item, i| {
                    if (i != 0) try w.writeAll(", ");
                    try w.print("{s}=", .{fname});
                    try item.writeRepr(w);
                }
                try w.writeByte(')');
            },
            .named_tuple_factory => |f| try w.print("<class '{s}'>", .{f.type_name}),
        }
    }

    /// Python `str()` for values where it differs from repr — strings
    /// render without quotes; an instance with a tuple `args` attr
    /// (the exception shape we use) renders the same way CPython
    /// formats `str(exc)` — empty for `args = ()`, the bare message
    /// for `(msg,)`, and a tuple repr for two or more.
    pub fn writeStr(self: Value, w: *std.Io.Writer) !void {
        switch (self) {
            .str => |s| try w.writeAll(s.bytes),
            .instance => |obj| {
                if (obj.dict.getStr("args")) |a| switch (a) {
                    .tuple => |t| {
                        if (t.items.len == 0) return;
                        if (t.items.len == 1) {
                            // KeyError formats `args[0]` via repr,
                            // matching CPython: `str(KeyError("x"))`
                            // is `'x'`, not `x`.
                            if (instanceIsClass(obj, "KeyError")) {
                                try t.items[0].writeRepr(w);
                                return;
                            }
                            try t.items[0].writeStr(w);
                            return;
                        }
                        try a.writeRepr(w);
                        return;
                    },
                    else => {},
                };
                try self.writeRepr(w);
            },
            else => try self.writeRepr(w),
        }
    }

    fn instanceIsClass(obj: anytype, name: []const u8) bool {
        var cls: ?*@import("class.zig").Class = obj.cls;
        while (cls) |c| {
            if (std.mem.eql(u8, c.name, name)) return true;
            cls = if (c.bases.len > 0) c.bases[0] else null;
        }
        return false;
    }

    /// Bytes-content escaping used by both `bytes` and `bytearray`
    /// repr. CPython prefers single quotes and escapes backslash, the
    /// chosen quote, `\n` `\r` `\t`, and any byte outside the printable
    /// ASCII range as `\xHH`.
    fn writeStrRepr(w: *std.Io.Writer, data: []const u8) !void {
        // CPython picks single quotes unless the string contains a `'`
        // and no `"`, in which case it switches to double quotes.
        var has_sq = false;
        var has_dq = false;
        for (data) |c| {
            if (c == '\'') has_sq = true;
            if (c == '"') has_dq = true;
        }
        const quote: u8 = if (has_sq and !has_dq) '"' else '\'';
        try w.writeByte(quote);
        for (data) |c| {
            switch (c) {
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => {
                    if (c == quote) {
                        try w.writeByte('\\');
                        try w.writeByte(c);
                    } else if (c < 0x20 or c == 0x7f) {
                        try w.print("\\x{x:0>2}", .{c});
                    } else {
                        try w.writeByte(c);
                    }
                },
            }
        }
        try w.writeByte(quote);
    }

    fn writeBytesContent(w: *std.Io.Writer, data: []const u8) !void {
        for (data) |c| {
            switch (c) {
                '\\' => try w.writeAll("\\\\"),
                '\'' => try w.writeAll("\\'"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x20...0x26, 0x28...0x5b, 0x5d...0x7e => try w.writeByte(c),
                else => try w.print("\\x{x:0>2}", .{c}),
            }
        }
    }

    /// Python's float repr appends a trailing `.0` to whole-valued
    /// floats so they're distinguishable from ints at the REPL:
    /// `print(10/4)` -> `2.5`, but `print(1.0)` -> `1.0`, not `1`.
    /// Zig's {d} already does shortest-round-trip, so we only need to
    /// fix up the "no decimal, no exponent" case.
    fn writeFloat(w: *std.Io.Writer, f: f64) !void {
        var buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{f});
        try w.writeAll(s);
        if (std.mem.indexOfAny(u8, s, ".eEnN") == null) {
            try w.writeAll(".0");
        }
    }

    /// Format a complex number the way CPython's `repr(complex)` does:
    /// when the real part is positive zero, drop it and the parens
    /// (`2j`, `0j`); otherwise wrap in parens and always print an
    /// explicit sign on the imaginary part (`(1+2j)`, `(-1-2j)`).
    /// Component formatting differs from `float.__repr__` in one
    /// place: whole-valued floats print *without* the trailing `.0`
    /// (so `complex(5, 0)` reads `(5+0j)`, not `(5.0+0.0j)`).
    fn writeComplex(w: *std.Io.Writer, c: Complex) !void {
        const real_is_pos_zero = c.re == 0.0 and !std.math.signbit(c.re);
        if (real_is_pos_zero) {
            try writeComplexComponent(w, c.im);
            try w.writeByte('j');
            return;
        }
        try w.writeByte('(');
        try writeComplexComponent(w, c.re);
        if (c.im >= 0.0 or std.math.isNan(c.im)) try w.writeByte('+');
        try writeComplexComponent(w, c.im);
        try w.writeAll("j)");
    }

    fn writeComplexComponent(w: *std.Io.Writer, f: f64) !void {
        var buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{f});
        try w.writeAll(s);
    }

    pub const Order = enum { lt, eq, gt };

    /// Compare for the type pairs the comparison fixture exercises.
    /// Returns null when the operand types cannot be ordered (and the
    /// caller wants to map that to TypeError); equality between
    /// unordered types is handled in `richCompare`, not here.
    pub fn order(a: Value, b: Value) ?Order {
        if (a == .small_int and b == .small_int) {
            const x = a.small_int;
            const y = b.small_int;
            return if (x < y) .lt else if (x == y) .eq else .gt;
        }
        if ((a == .small_int or a == .boolean) and (b == .small_int or b == .boolean)) {
            const x: i64 = if (a == .boolean) @intFromBool(a.boolean) else a.small_int;
            const y: i64 = if (b == .boolean) @intFromBool(b.boolean) else b.small_int;
            return if (x < y) .lt else if (x == y) .eq else .gt;
        }
        if (a == .big_int and b == .big_int) {
            return switch (a.big_int.inner.order(b.big_int.inner)) {
                .lt => .lt,
                .eq => .eq,
                .gt => .gt,
            };
        }
        // Mixed small_int / big_int: compare via the big_int's sign and
        // magnitude. We avoid allocating by using `orderAgainstScalar`.
        if (a == .big_int and (b == .small_int or b == .boolean)) {
            const y: i64 = if (b == .boolean) @intFromBool(b.boolean) else b.small_int;
            const o = a.big_int.inner.toConst().orderAgainstScalar(y);
            return switch (o) {
                .lt => .lt,
                .eq => .eq,
                .gt => .gt,
            };
        }
        if ((a == .small_int or a == .boolean) and b == .big_int) {
            const x: i64 = if (a == .boolean) @intFromBool(a.boolean) else a.small_int;
            const o = b.big_int.inner.toConst().orderAgainstScalar(x);
            return switch (o) {
                .lt => .gt,
                .eq => .eq,
                .gt => .lt,
            };
        }
        const af: ?f64 = switch (a) {
            .small_int => |i| @floatFromInt(i),
            .boolean => |x| if (x) 1.0 else 0.0,
            .float => |f| f,
            else => null,
        };
        const bf: ?f64 = switch (b) {
            .small_int => |i| @floatFromInt(i),
            .boolean => |x| if (x) 1.0 else 0.0,
            .float => |f| f,
            else => null,
        };
        if (af != null and bf != null) {
            const x = af.?;
            const y = bf.?;
            return if (x < y) .lt else if (x == y) .eq else .gt;
        }
        if (a == .str and b == .str) {
            const cmp = std.mem.order(u8, a.str.bytes, b.str.bytes);
            return switch (cmp) {
                .lt => .lt,
                .eq => .eq,
                .gt => .gt,
            };
        }
        // bytes / bytearray are lexicographically comparable, including
        // cross-type (`bytearray(b"abc") < b"abd"` works). memoryview
        // is intentionally excluded -- CPython raises TypeError on
        // `mv < mv`, so we let the compare fall through to null here.
        const a_bytes: ?[]const u8 = switch (a) {
            .bytes => |x| x.data,
            .bytearray => |x| x.data.items,
            else => null,
        };
        const b_bytes: ?[]const u8 = switch (b) {
            .bytes => |x| x.data,
            .bytearray => |x| x.data.items,
            else => null,
        };
        if (a_bytes != null and b_bytes != null) {
            return switch (std.mem.order(u8, a_bytes.?, b_bytes.?)) {
                .lt => .lt,
                .eq => .eq,
                .gt => .gt,
            };
        }
        if (a == .tuple and b == .tuple) {
            const ax = a.tuple.items;
            const bx = b.tuple.items;
            const n = @min(ax.len, bx.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const sub = order(ax[i], bx[i]) orelse return null;
                if (sub != .eq) return sub;
            }
            return if (ax.len < bx.len) .lt else if (ax.len == bx.len) .eq else .gt;
        }
        return null;
    }

    /// Python `==`: equal-typed values delegate to `order`; mixed
    /// types that aren't orderable simply aren't equal (Python returns
    /// False here, not TypeError). Complex compares to itself by
    /// component, and to int/float when its imaginary part is zero
    /// (matching CPython's mixed-numeric coercion rule).
    pub fn equals(a: Value, b: Value) bool {
        if (a == .none and b == .none) return true;
        if (a == .complex_num or b == .complex_num) return complexEquals(a, b);
        if (a == .set and b == .set) return setEquals(a.set, b.set);
        if (a == .named_tuple and b == .named_tuple) {
            const ax = a.named_tuple.items;
            const bx = b.named_tuple.items;
            if (ax.len != bx.len) return false;
            for (ax, bx) |x, y| if (!x.equals(y)) return false;
            return true;
        }
        if (a == .dict and b == .dict) {
            const ax = a.dict.pairs.items;
            const bx = b.dict.pairs.items;
            if (ax.len != bx.len) return false;
            outer_dict: for (ax) |pa| {
                for (bx) |pb| {
                    if (pa.key.equals(pb.key) and pa.value.equals(pb.value)) continue :outer_dict;
                }
                return false;
            }
            return true;
        }
        if (a == .list and b == .list) {
            const ax = a.list.items.items;
            const bx = b.list.items.items;
            if (ax.len != bx.len) return false;
            for (ax, bx) |x, y| if (!x.equals(y)) return false;
            return true;
        }
        if (a == .tuple and b == .tuple) {
            const ax = a.tuple.items;
            const bx = b.tuple.items;
            if (ax.len != bx.len) return false;
            for (ax, bx) |x, y| if (!x.equals(y)) return false;
            return true;
        }
        // bytes/bytearray compare by content across the two types,
        // matching CPython: `b"x" == bytearray(b"x")` is True.
        const a_bytes: ?[]const u8 = switch (a) {
            .bytes => |x| x.data,
            .bytearray => |x| x.data.items,
            .memoryview => |m| m.data(),
            else => null,
        };
        const b_bytes: ?[]const u8 = switch (b) {
            .bytes => |x| x.data,
            .bytearray => |x| x.data.items,
            .memoryview => |m| m.data(),
            else => null,
        };
        if (a_bytes != null and b_bytes != null) {
            return std.mem.eql(u8, a_bytes.?, b_bytes.?);
        }
        if (order(a, b)) |o| return o == .eq;
        return false;
    }

    /// Set / frozenset equality is element-wise, order-insensitive,
    /// and indifferent to the `frozen` flag — `frozenset({1,2}) ==
    /// {1,2}` is True in CPython.
    fn setEquals(a: anytype, b: anytype) bool {
        if (a.items.items.len != b.items.items.len) return false;
        outer: for (a.items.items) |x| {
            for (b.items.items) |y| {
                if (x.equals(y)) continue :outer;
            }
            return false;
        }
        return true;
    }

    fn complexEquals(a: Value, b: Value) bool {
        const ac = asComplex(a) orelse return false;
        const bc = asComplex(b) orelse return false;
        return ac.re == bc.re and ac.im == bc.im;
    }

    pub fn asComplex(v: Value) ?Complex {
        return switch (v) {
            .small_int => |i| Complex{ .re = @floatFromInt(i), .im = 0 },
            .boolean => |x| Complex{ .re = if (x) 1.0 else 0.0, .im = 0 },
            .float => |f| Complex{ .re = f, .im = 0 },
            .complex_num => |c| c,
            else => null,
        };
    }

    /// Python `is`: object identity. Singletons (None/True/False) are
    /// unique. Small ints compare by value (CPython caches them; for
    /// the fixture's `1 is not 2` this is indistinguishable). Heap
    /// objects compare by pointer.
    pub fn identityEq(a: Value, b: Value) bool {
        if (@as(Tag, a) != @as(Tag, b)) return false;
        return switch (a) {
            .none, .null_sentinel, .ellipsis, .not_implemented => true,
            .boolean => |x| x == b.boolean,
            .small_int => |x| x == b.small_int,
            .big_int => |x| x == b.big_int,
            .float => |x| x == b.float,
            .complex_num => |x| x.re == b.complex_num.re and x.im == b.complex_num.im,
            .str => |p| p == b.str,
            .bytes => |p| p == b.bytes,
            .bytearray => |p| p == b.bytearray,
            .memoryview => |p| p == b.memoryview,
            .tuple => |p| p == b.tuple,
            .list => |p| p == b.list,
            .dict => |p| p == b.dict,
            .code => |p| p == b.code,
            .builtin_fn => |p| p == b.builtin_fn,
            .bound_method => |p| p == b.bound_method,
            .partial => |p| p == b.partial,
            .cached_fn => |p| p == b.cached_fn,
            .cached_property => |p| p == b.cached_property,
            .function => |p| p == b.function,
            .cell => |p| p == b.cell,
            .class => |p| p == b.class,
            .instance => |p| p == b.instance,
            .slice => |p| p == b.slice,
            .iter => |p| p == b.iter,
            .descriptor => |p| p == b.descriptor,
            .generator => |p| p == b.generator,
            .set => |p| p == b.set,
            .enum_iter => |p| p == b.enum_iter,
            .module => |p| p == b.module,
            .deque => |p| p == b.deque,
            .counter => |p| p == b.counter,
            .defaultdict => |p| p == b.defaultdict,
            .ordered_dict => |p| p == b.ordered_dict,
            .named_tuple => |p| p == b.named_tuple,
            .named_tuple_factory => |p| p == b.named_tuple_factory,
        };
    }

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .none => "NoneType",
            .null_sentinel => "<NULL>",
            .boolean => "bool",
            .small_int => "int",
            .big_int => "int",
            .float => "float",
            .complex_num => "complex",
            .str => "str",
            .bytes => "bytes",
            .bytearray => "bytearray",
            .memoryview => "memoryview",
            .tuple => "tuple",
            .list => "list",
            .dict => "dict",
            .code => "code",
            .builtin_fn => "builtin_function_or_method",
            .bound_method => "method",
            .partial => "functools.partial",
            .cached_fn => "function",
            .cached_property => "cached_property",
            .function => "function",
            .cell => "cell",
            .class => "type",
            .instance => |obj| obj.cls.name,
            .slice => "slice",
            .iter => "iterator",
            .descriptor => |d| switch (d.kind) {
                .property => "property",
                .classmethod => "classmethod",
                .staticmethod => "staticmethod",
            },
            .generator => "generator",
            .set => |s| if (s.frozen) "frozenset" else "set",
            .enum_iter => "enumerate",
            .module => "module",
            .ellipsis => "ellipsis",
            .not_implemented => "NotImplementedType",
            .deque => "collections.deque",
            .counter => "Counter",
            .defaultdict => "collections.defaultdict",
            .ordered_dict => "collections.OrderedDict",
            .named_tuple => |nt| nt.factory.type_name,
            .named_tuple_factory => "type",
        };
    }
};

test "value size is small" {
    try std.testing.expect(@sizeOf(Value) <= 24);
}

test "bool truthy" {
    try std.testing.expect(!Value.none.isTruthy());
    try std.testing.expect((Value{ .boolean = true }).isTruthy());
    try std.testing.expect(!(Value{ .boolean = false }).isTruthy());
    try std.testing.expect((Value{ .small_int = 1 }).isTruthy());
    try std.testing.expect(!(Value{ .small_int = 0 }).isTruthy());
}
