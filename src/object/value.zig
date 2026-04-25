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

pub const Tag = enum(u8) {
    none,
    boolean,
    small_int,
    float,
    str,
    bytes,
    tuple,
    list,
    dict,
    code,
    builtin_fn,
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

pub const Value = union(Tag) {
    none,
    boolean: bool,
    small_int: i64,
    float: f64,
    str: *Str,
    bytes: *Bytes,
    tuple: *Tuple,
    list: *List,
    dict: *Dict,
    code: *Code,
    builtin_fn: *BuiltinFn,
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
    null_sentinel,

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .none, .null_sentinel => false,
            .boolean => |b| b,
            .small_int => |i| i != 0,
            .float => |f| f != 0.0,
            .str => |s| s.bytes.len != 0,
            .bytes => |b| b.data.len != 0,
            .tuple => |t| t.items.len != 0,
            .list => |l| l.items.items.len != 0,
            .dict => |d| d.count() != 0,
            .set => |s| s.items.items.len != 0,
            .code, .builtin_fn, .function, .cell, .class, .instance, .slice, .iter, .descriptor, .generator, .enum_iter, .module => true,
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
            .float => |f| try writeFloat(w, f),
            .str => |s| {
                try w.writeByte('\'');
                try w.writeAll(s.bytes);
                try w.writeByte('\'');
            },
            .bytes => |b| try w.print("b'{s}'", .{b.data}),
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
                try w.writeByte('{');
                for (s.items.items, 0..) |it, i| {
                    if (i != 0) try w.writeAll(", ");
                    try it.writeRepr(w);
                }
                try w.writeByte('}');
            },
            .code => |c| try w.print("<code object {s}>", .{c.name}),
            .builtin_fn => |f| try w.print("<built-in function {s}>", .{f.name}),
            .function => |f| try w.print("<function {s}>", .{f.code.qualname}),
            .cell => try w.writeAll("<cell>"),
            .class => |c| try w.print("<class '{s}'>", .{c.name}),
            .instance => |obj| try w.print("<{s} object>", .{obj.cls.name}),
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
    /// False here, not TypeError).
    pub fn equals(a: Value, b: Value) bool {
        if (a == .none and b == .none) return true;
        if (order(a, b)) |o| return o == .eq;
        return false;
    }

    /// Python `is`: object identity. Singletons (None/True/False) are
    /// unique. Small ints compare by value (CPython caches them; for
    /// the fixture's `1 is not 2` this is indistinguishable). Heap
    /// objects compare by pointer.
    pub fn identityEq(a: Value, b: Value) bool {
        if (@as(Tag, a) != @as(Tag, b)) return false;
        return switch (a) {
            .none, .null_sentinel => true,
            .boolean => |x| x == b.boolean,
            .small_int => |x| x == b.small_int,
            .float => |x| x == b.float,
            .str => |p| p == b.str,
            .bytes => |p| p == b.bytes,
            .tuple => |p| p == b.tuple,
            .list => |p| p == b.list,
            .dict => |p| p == b.dict,
            .code => |p| p == b.code,
            .builtin_fn => |p| p == b.builtin_fn,
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
        };
    }

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .none => "NoneType",
            .null_sentinel => "<NULL>",
            .boolean => "bool",
            .small_int => "int",
            .float => "float",
            .str => "str",
            .bytes => "bytes",
            .tuple => "tuple",
            .list => "list",
            .dict => "dict",
            .code => "code",
            .builtin_fn => "builtin_function_or_method",
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
            .set => "set",
            .enum_iter => "enumerate",
            .module => "module",
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
