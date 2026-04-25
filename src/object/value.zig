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
    slice,
    /// Placeholder pushed by PUSH_NULL. Distinct from `.none` — CPython
    /// uses `NULL` as a C-level sentinel before a CALL and `None` as a
    /// real Python value.
    null_sentinel,
};

pub const BuiltinFnPtr = *const fn (
    interp: *anyopaque, // *vm.interp.Interp; avoid circular import at comptime
    args: []const Value,
) anyerror!Value;

pub const BuiltinFn = struct {
    name: []const u8,
    func: BuiltinFnPtr,
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
    slice: *Slice,
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
            .code, .builtin_fn, .slice => true,
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
            .dict => try w.writeAll("{...}"),
            .code => |c| try w.print("<code object {s}>", .{c.name}),
            .builtin_fn => |f| try w.print("<built-in function {s}>", .{f.name}),
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
    /// render without quotes, everything else falls back to repr.
    pub fn writeStr(self: Value, w: *std.Io.Writer) !void {
        switch (self) {
            .str => |s| try w.writeAll(s.bytes),
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
        if (a == .str and b == .str) {
            const cmp = std.mem.order(u8, a.str.bytes, b.str.bytes);
            return switch (cmp) {
                .lt => .lt,
                .eq => .eq,
                .gt => .gt,
            };
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
            .slice => |p| p == b.slice,
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
            .slice => "slice",
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
