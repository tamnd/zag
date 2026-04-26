//! Pinhole `array` module. Exposes the `array.array` class (Class+
//! Instance pattern; items live on the instance dict under "_items"
//! as a Python list, typecode/itemsize as plain attrs) and the
//! `typecodes` constant. Each typecode has a per-element width and
//! signedness; `validate` rejects values outside the typecode's range.

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
const Bytes = @import("../object/bytes.zig").Bytes;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Iter = @import("../object/iter.zig").Iter;
const BigInt = @import("../object/bigint.zig").BigInt;
const Slice = @import("../object/slice.zig").Slice;
const Interp = @import("interp.zig").Interp;
const builtins_mod = @import("builtins.zig");
const dispatch = @import("dispatch.zig");

const TYPECODES = "bBuwhHiIlLqQfd";

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClass(interp);

    const m = try Module.init(a, "array");
    const tc_str = try Str.init(a, TYPECODES);
    try m.attrs.setStr(a, "typecodes", Value{ .str = tc_str });
    try m.attrs.setStr(a, "array", Value{ .class = interp.array_class.? });
    try m.attrs.setStr(a, "ArrayType", Value{ .class = interp.array_class.? });
    return m;
}

fn ensureClass(interp: *Interp) !void {
    if (interp.array_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try regKw(a, d, "__init__", initKw);
    try reg(a, d, "__repr__", reprFn);
    try reg(a, d, "__len__", lenFn);
    try reg(a, d, "__iter__", iterFn);
    try reg(a, d, "__contains__", containsFn);
    try reg(a, d, "__getitem__", getitemFn);
    try reg(a, d, "__setitem__", setitemFn);
    try reg(a, d, "__delitem__", delitemFn);
    try reg(a, d, "append", appendFn);
    try reg(a, d, "extend", extendFn);
    try reg(a, d, "fromlist", fromlistFn);
    try reg(a, d, "insert", insertFn);
    try reg(a, d, "pop", popFn);
    try reg(a, d, "remove", removeFn);
    try reg(a, d, "count", countFn);
    try reg(a, d, "index", indexFn);
    try reg(a, d, "reverse", reverseFn);
    try reg(a, d, "tobytes", tobytesFn);
    try reg(a, d, "frombytes", frombytesFn);
    try reg(a, d, "tolist", tolistFn);
    try reg(a, d, "buffer_info", bufferInfoFn);
    try reg(a, d, "byteswap", byteswapFn);
    interp.array_class = try Class.init(a, "array", &.{}, d);
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

fn instSelf(opaque_interp: *anyopaque, args: []const Value) !*Instance {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .instance) {
        try interp.typeError("expected array.array self");
        return error.TypeError;
    }
    return args[0].instance;
}

fn itemsOf(self: *Instance) ?*List {
    const v = self.dict.getStr("_items") orelse return null;
    if (v != .list) return null;
    return v.list;
}

fn typecodeOf(self: *Instance) ?u8 {
    const v = self.dict.getStr("typecode") orelse return null;
    if (v != .str or v.str.bytes.len == 0) return null;
    return v.str.bytes[0];
}

fn itemsizeFor(tc: u8) ?u8 {
    return switch (tc) {
        'b', 'B' => 1,
        'h', 'H' => 2,
        'i', 'I', 'f' => 4,
        'l', 'L', 'q', 'Q', 'd' => 8,
        'u', 'w' => 4,
        else => null,
    };
}

fn isFloatTc(tc: u8) bool {
    return tc == 'f' or tc == 'd';
}

const IntRange = struct { lo: i128, hi: i128 };

fn rangeFor(tc: u8) ?IntRange {
    return switch (tc) {
        'b' => .{ .lo = -128, .hi = 127 },
        'B' => .{ .lo = 0, .hi = 255 },
        'h' => .{ .lo = -32768, .hi = 32767 },
        'H' => .{ .lo = 0, .hi = 65535 },
        'i' => .{ .lo = -2147483648, .hi = 2147483647 },
        'I' => .{ .lo = 0, .hi = 4294967295 },
        'l', 'q' => .{ .lo = -9223372036854775808, .hi = 9223372036854775807 },
        'L', 'Q' => .{ .lo = 0, .hi = 18446744073709551615 },
        else => null,
    };
}

fn intFromValue(v: Value) ?i128 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        .big_int => |bi| bi.inner.toInt(i128) catch null,
        else => null,
    };
}

fn floatFromValue(v: Value) ?f64 {
    return switch (v) {
        .small_int => |i| @floatFromInt(i),
        .boolean => |b| @floatFromInt(@intFromBool(b)),
        .float => |f| f,
        .big_int => |bi| blk: {
            const r = bi.inner.toFloat(f64, .nearest_even);
            break :blk r[0];
        },
        else => null,
    };
}

fn validateAndCoerce(interp: *Interp, tc: u8, v: Value) !Value {
    if (isFloatTc(tc)) {
        const f = floatFromValue(v) orelse {
            try interp.raisePy("TypeError", "must be real number");
            return error.PyException;
        };
        if (tc == 'f') {
            const f32_v: f32 = @floatCast(f);
            return Value{ .float = @floatCast(f32_v) };
        }
        return Value{ .float = f };
    }
    const r = rangeFor(tc) orelse {
        try interp.raisePy("ValueError", "bad typecode");
        return error.PyException;
    };
    const iv = intFromValue(v) orelse {
        try interp.raisePy("TypeError", "an integer is required");
        return error.PyException;
    };
    if (iv < r.lo or iv > r.hi) {
        try interp.raisePy("OverflowError", "value out of range");
        return error.PyException;
    }
    if (iv >= std.math.minInt(i64) and iv <= std.math.maxInt(i64)) {
        return Value{ .small_int = @intCast(iv) };
    }
    // Only 'L' / 'Q' can hold values outside i64.
    return try u128ToValue(interp.allocator, @intCast(iv));
}

fn u128ToValue(a: std.mem.Allocator, v: u128) !Value {
    if (v <= std.math.maxInt(i64)) return Value{ .small_int = @intCast(v) };
    const hi: u64 = @truncate(v >> 64);
    const lo: u64 = @truncate(v);
    var managed = try std.math.big.int.Managed.initSet(a, hi);
    errdefer managed.deinit();
    try managed.shiftLeft(&managed, 64);
    var lo_m = try std.math.big.int.Managed.initSet(a, lo);
    defer lo_m.deinit();
    try managed.add(&managed, &lo_m);
    const big = try BigInt.fromManaged(a, managed);
    return Value{ .big_int = big };
}

fn raiseTC(interp: *Interp, msg: []const u8) anyerror {
    interp.raisePy("ValueError", msg) catch {};
    return error.PyException;
}

fn raiseType(interp: *Interp, msg: []const u8) anyerror {
    interp.raisePy("TypeError", msg) catch {};
    return error.PyException;
}

fn raiseIndex(interp: *Interp, msg: []const u8) anyerror {
    interp.raisePy("IndexError", msg) catch {};
    return error.PyException;
}

// ===== __init__ =====

fn initKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    _ = kw_names;
    _ = kw_values;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instSelf(p, args);
    if (args.len < 2 or args[1] != .str or args[1].str.bytes.len != 1) {
        return raiseType(interp, "array() argument 1 must be a unicode character");
    }
    const tc = args[1].str.bytes[0];
    const item_sz = itemsizeFor(tc) orelse return raiseTC(interp, "bad typecode (must be in bBuwhHiIlLqQfd)");
    if (tc == 'u' or tc == 'w') {
        return raiseTC(interp, "typecode not supported");
    }

    const tc_str = try Str.init(a, args[1].str.bytes);
    try self.dict.setStr(a, "typecode", Value{ .str = tc_str });
    try self.dict.setStr(a, "itemsize", Value{ .small_int = @intCast(item_sz) });
    const items = try List.init(a);
    try self.dict.setStr(a, "_items", Value{ .list = items });

    if (args.len >= 3) {
        const init_v = args[2];
        switch (init_v) {
            .bytes => |b| try frombytesInto(interp, items, tc, b.data),
            .bytearray => |b| try frombytesInto(interp, items, tc, b.data.items),
            else => {
                const mat = try builtins_mod.materialize(interp, init_v);
                for (mat.items.items) |x| {
                    const coerced = try validateAndCoerce(interp, tc, x);
                    try items.append(a, coerced);
                }
            },
        }
    }
    return Value.none;
}

// ===== __repr__ =====

fn reprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instSelf(p, args);
    const items = itemsOf(self) orelse return raiseType(interp, "array missing _items");
    const tc = typecodeOf(self) orelse return raiseType(interp, "array missing typecode");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var w = std.Io.Writer.Allocating.init(a);
    defer w.deinit();
    try buf.appendSlice(a, "array('");
    try buf.append(a, tc);
    try buf.append(a, '\'');
    if (items.items.items.len > 0) {
        try buf.appendSlice(a, ", [");
        for (items.items.items, 0..) |v, i| {
            if (i != 0) try buf.appendSlice(a, ", ");
            // Reuse value's repr.
            w.clearRetainingCapacity();
            try v.writeRepr(&w.writer);
            try buf.appendSlice(a, w.written());
        }
        try buf.append(a, ']');
    }
    try buf.append(a, ')');
    const s = try Str.init(a, buf.items);
    return Value{ .str = s };
}

// ===== __len__ =====

fn lenFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(p, args);
    const items = itemsOf(self) orelse return error.TypeError;
    return Value{ .small_int = @intCast(items.items.items.len) };
}

// ===== __iter__ =====

fn iterFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const self = try instSelf(p, args);
    const items = itemsOf(self) orelse return error.TypeError;
    const it = try Iter.init(interp.allocator, .{ .list = items });
    return Value{ .iter = it };
}

// ===== __contains__ =====

fn containsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(p, args);
    if (args.len != 2) return error.TypeError;
    const items = itemsOf(self) orelse return error.TypeError;
    for (items.items.items) |x| {
        if (Value.equals(x, args[1])) return Value{ .boolean = true };
    }
    return Value{ .boolean = false };
}

// ===== __getitem__ =====

fn normalizeIdx(idx: i64, n: i64) ?i64 {
    var i = idx;
    if (i < 0) i += n;
    if (i < 0 or i >= n) return null;
    return i;
}

fn getitemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instSelf(p, args);
    if (args.len != 2) return error.TypeError;
    const items = itemsOf(self) orelse return error.TypeError;
    const tc = typecodeOf(self) orelse return error.TypeError;

    if (args[1] == .slice) {
        const sl = args[1].slice;
        const n: i64 = @intCast(items.items.items.len);
        const start_default: i64 = 0;
        const stop_default: i64 = n;
        const step_v: i64 = if (sl.step == .small_int) sl.step.small_int else 1;
        var start: i64 = start_default;
        var stop: i64 = stop_default;
        if (sl.start == .small_int) {
            start = sl.start.small_int;
            if (start < 0) start += n;
            if (start < 0) start = 0;
            if (start > n) start = n;
        }
        if (sl.stop == .small_int) {
            stop = sl.stop.small_int;
            if (stop < 0) stop += n;
            if (stop < 0) stop = 0;
            if (stop > n) stop = n;
        }
        const out_inst = try Instance.init(a, interp.array_class.?);
        const tc_str = try Str.init(a, &[_]u8{tc});
        try out_inst.dict.setStr(a, "typecode", Value{ .str = tc_str });
        try out_inst.dict.setStr(a, "itemsize", Value{ .small_int = @intCast(itemsizeFor(tc).?) });
        const out_items = try List.init(a);
        if (step_v == 1) {
            var i = start;
            while (i < stop) : (i += 1) try out_items.append(a, items.items.items[@intCast(i)]);
        } else if (step_v > 0) {
            var i = start;
            while (i < stop) : (i += step_v) try out_items.append(a, items.items.items[@intCast(i)]);
        } else if (step_v < 0) {
            var i = start;
            while (i > stop) : (i += step_v) try out_items.append(a, items.items.items[@intCast(i)]);
        }
        try out_inst.dict.setStr(a, "_items", Value{ .list = out_items });
        return Value{ .instance = out_inst };
    }

    const idx_raw = intFromValue(args[1]) orelse return raiseType(interp, "array indices must be integers");
    const n: i64 = @intCast(items.items.items.len);
    const i = normalizeIdx(@intCast(idx_raw), n) orelse return raiseIndex(interp, "array index out of range");
    return items.items.items[@intCast(i)];
}

// ===== __setitem__ =====

fn setitemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const self = try instSelf(p, args);
    if (args.len != 3) return error.TypeError;
    const items = itemsOf(self) orelse return error.TypeError;
    const tc = typecodeOf(self) orelse return error.TypeError;
    const idx_raw = intFromValue(args[1]) orelse return raiseType(interp, "array indices must be integers");
    const n: i64 = @intCast(items.items.items.len);
    const i = normalizeIdx(@intCast(idx_raw), n) orelse return raiseIndex(interp, "array assignment index out of range");
    const coerced = try validateAndCoerce(interp, tc, args[2]);
    items.items.items[@intCast(i)] = coerced;
    return Value.none;
}

// ===== __delitem__ =====

fn delitemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const self = try instSelf(p, args);
    if (args.len != 2) return error.TypeError;
    const items = itemsOf(self) orelse return error.TypeError;
    const idx_raw = intFromValue(args[1]) orelse return raiseType(interp, "array indices must be integers");
    const n: i64 = @intCast(items.items.items.len);
    const i = normalizeIdx(@intCast(idx_raw), n) orelse return raiseIndex(interp, "array assignment index out of range");
    _ = items.items.orderedRemove(@intCast(i));
    return Value.none;
}

// ===== append =====

fn appendFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const self = try instSelf(p, args);
    if (args.len != 2) return error.TypeError;
    const items = itemsOf(self) orelse return error.TypeError;
    const tc = typecodeOf(self) orelse return error.TypeError;
    const coerced = try validateAndCoerce(interp, tc, args[1]);
    try items.append(interp.allocator, coerced);
    return Value.none;
}

// ===== extend =====

fn extendFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const self = try instSelf(p, args);
    if (args.len != 2) return error.TypeError;
    const items = itemsOf(self) orelse return error.TypeError;
    const tc = typecodeOf(self) orelse return error.TypeError;
    const seed = try builtins_mod.materialize(interp, args[1]);
    for (seed.items.items) |x| {
        const coerced = try validateAndCoerce(interp, tc, x);
        try items.append(interp.allocator, coerced);
    }
    return Value.none;
}

// ===== fromlist =====

fn fromlistFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return extendFn(p, args);
}

// ===== insert =====

fn insertFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const self = try instSelf(p, args);
    if (args.len != 3) return error.TypeError;
    const items = itemsOf(self) orelse return error.TypeError;
    const tc = typecodeOf(self) orelse return error.TypeError;
    const idx_raw = intFromValue(args[1]) orelse return raiseType(interp, "array indices must be integers");
    const coerced = try validateAndCoerce(interp, tc, args[2]);
    var i: i64 = @intCast(idx_raw);
    const n: i64 = @intCast(items.items.items.len);
    if (i < 0) i += n;
    if (i < 0) i = 0;
    if (i > n) i = n;
    try items.items.insert(interp.allocator, @intCast(i), coerced);
    return Value.none;
}

// ===== pop =====

fn popFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const self = try instSelf(p, args);
    const items = itemsOf(self) orelse return error.TypeError;
    const n: i64 = @intCast(items.items.items.len);
    if (n == 0) return raiseIndex(interp, "pop from empty array");
    var i: i64 = n - 1;
    if (args.len >= 2) {
        const idx_raw = intFromValue(args[1]) orelse return raiseType(interp, "array indices must be integers");
        i = @intCast(idx_raw);
        if (i < 0) i += n;
        if (i < 0 or i >= n) return raiseIndex(interp, "pop index out of range");
    }
    return items.items.orderedRemove(@intCast(i));
}

// ===== remove =====

fn removeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const self = try instSelf(p, args);
    if (args.len != 2) return error.TypeError;
    const items = itemsOf(self) orelse return error.TypeError;
    for (items.items.items, 0..) |x, i| {
        if (Value.equals(x, args[1])) {
            _ = items.items.orderedRemove(i);
            return Value.none;
        }
    }
    return raiseTC(interp, "array.remove(x): x not in array");
}

// ===== count =====

fn countFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(p, args);
    if (args.len != 2) return error.TypeError;
    const items = itemsOf(self) orelse return error.TypeError;
    var n: i64 = 0;
    for (items.items.items) |x| if (Value.equals(x, args[1])) {
        n += 1;
    };
    return Value{ .small_int = n };
}

// ===== index =====

fn indexFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const self = try instSelf(p, args);
    if (args.len < 2) return error.TypeError;
    const items = itemsOf(self) orelse return error.TypeError;
    var start: usize = 0;
    if (args.len >= 3) {
        const s_raw = intFromValue(args[2]) orelse return raiseType(interp, "array indices must be integers");
        var s: i64 = @intCast(s_raw);
        const n: i64 = @intCast(items.items.items.len);
        if (s < 0) s += n;
        if (s < 0) s = 0;
        start = @intCast(s);
    }
    var i = start;
    while (i < items.items.items.len) : (i += 1) {
        if (Value.equals(items.items.items[i], args[1])) return Value{ .small_int = @intCast(i) };
    }
    return raiseTC(interp, "array.index(x): x not in array");
}

// ===== reverse =====

fn reverseFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const self = try instSelf(p, args);
    const items = itemsOf(self) orelse return error.TypeError;
    std.mem.reverse(Value, items.items.items);
    return Value.none;
}

// ===== tobytes =====

fn writeIntLE(buf: *std.ArrayList(u8), a: std.mem.Allocator, val: u128, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const shift: u7 = @intCast(i * 8);
        const byte: u8 = @truncate(val >> shift);
        try buf.append(a, byte);
    }
}

fn valueToU128Bits(v: Value, n: usize) ?u128 {
    const iv: i128 = switch (v) {
        .small_int => |x| x,
        .boolean => |b| @intFromBool(b),
        .big_int => |bi| bi.inner.toInt(i128) catch return null,
        else => return null,
    };
    if (n == 16) {
        return @bitCast(iv);
    }
    const mask: u128 = if (n >= 16) ~@as(u128, 0) else (@as(u128, 1) << @intCast(n * 8)) - 1;
    const bits: u128 = @bitCast(iv);
    return bits & mask;
}

fn tobytesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instSelf(p, args);
    const items = itemsOf(self) orelse return error.TypeError;
    const tc = typecodeOf(self) orelse return error.TypeError;
    const item_sz = itemsizeFor(tc) orelse return raiseTC(interp, "bad typecode");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);

    if (isFloatTc(tc)) {
        for (items.items.items) |v| {
            const f = floatFromValue(v) orelse return raiseType(interp, "non-numeric in float array");
            if (tc == 'f') {
                const fv: f32 = @floatCast(f);
                const bits: u32 = @bitCast(fv);
                try writeIntLE(&buf, a, bits, 4);
            } else {
                const bits: u64 = @bitCast(f);
                try writeIntLE(&buf, a, bits, 8);
            }
        }
    } else {
        for (items.items.items) |v| {
            const bits = valueToU128Bits(v, item_sz) orelse return raiseType(interp, "non-int in int array");
            try writeIntLE(&buf, a, bits, item_sz);
        }
    }

    const owned = try a.dupe(u8, buf.items);
    const b = try Bytes.fromOwnedSlice(a, owned);
    return Value{ .bytes = b };
}

// ===== frombytes =====

fn frombytesInto(interp: *Interp, items: *List, tc: u8, raw: []const u8) !void {
    const a = interp.allocator;
    const item_sz = itemsizeFor(tc) orelse return raiseTC(interp, "bad typecode");
    if (raw.len % item_sz != 0) {
        return raiseTC(interp, "bytes length not a multiple of item size");
    }
    var i: usize = 0;
    while (i < raw.len) : (i += item_sz) {
        const chunk = raw[i .. i + item_sz];
        if (isFloatTc(tc)) {
            if (tc == 'f') {
                var bits: u32 = 0;
                for (chunk, 0..) |b, k| bits |= @as(u32, b) << @intCast(k * 8);
                const f: f32 = @bitCast(bits);
                try items.append(a, Value{ .float = @floatCast(f) });
            } else {
                var bits: u64 = 0;
                for (chunk, 0..) |b, k| bits |= @as(u64, b) << @intCast(k * 8);
                const f: f64 = @bitCast(bits);
                try items.append(a, Value{ .float = f });
            }
        } else {
            // Parse as little-endian, sign-extend for signed types.
            var bits: u128 = 0;
            for (chunk, 0..) |b, k| bits |= @as(u128, b) << @intCast(k * 8);
            const signed = (tc == 'b' or tc == 'h' or tc == 'i' or tc == 'l' or tc == 'q');
            if (signed and item_sz < 16) {
                const sign_bit: u128 = @as(u128, 1) << @intCast(item_sz * 8 - 1);
                if (bits & sign_bit != 0) {
                    const ext: u128 = ~((@as(u128, 1) << @intCast(item_sz * 8)) - 1);
                    bits |= ext;
                }
            }
            const iv: i128 = @bitCast(bits);
            if (iv >= std.math.minInt(i64) and iv <= std.math.maxInt(i64)) {
                try items.append(a, Value{ .small_int = @intCast(iv) });
            } else {
                const v = try u128ToValue(a, @intCast(iv));
                try items.append(a, v);
            }
        }
    }
}

fn frombytesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const self = try instSelf(p, args);
    if (args.len != 2) return error.TypeError;
    const items = itemsOf(self) orelse return error.TypeError;
    const tc = typecodeOf(self) orelse return error.TypeError;
    const raw: []const u8 = switch (args[1]) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        else => return raiseType(interp, "frombytes expects bytes-like"),
    };
    try frombytesInto(interp, items, tc, raw);
    return Value.none;
}

// ===== tolist =====

fn tolistFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instSelf(p, args);
    const items = itemsOf(self) orelse return error.TypeError;
    const out = try List.init(a);
    for (items.items.items) |x| try out.append(a, x);
    return Value{ .list = out };
}

// ===== buffer_info =====

fn bufferInfoFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instSelf(p, args);
    const items = itemsOf(self) orelse return error.TypeError;
    const t = try Tuple.init(a, 2);
    t.items[0] = Value{ .small_int = @intCast(@intFromPtr(items)) };
    t.items[1] = Value{ .small_int = @intCast(items.items.items.len) };
    return Value{ .tuple = t };
}

// ===== byteswap =====

fn byteswapFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const self = try instSelf(p, args);
    const items = itemsOf(self) orelse return error.TypeError;
    const tc = typecodeOf(self) orelse return error.TypeError;
    const item_sz = itemsizeFor(tc) orelse return raiseTC(interp, "bad typecode");
    if (item_sz <= 1) return Value.none;

    // Round-trip via bytes: serialize, reverse each chunk in place,
    // deserialize back into the items list.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    if (isFloatTc(tc)) {
        for (items.items.items) |v| {
            const f = floatFromValue(v) orelse return raiseType(interp, "non-numeric in float array");
            if (tc == 'f') {
                const fv: f32 = @floatCast(f);
                const bits: u32 = @bitCast(fv);
                try writeIntLE(&buf, a, bits, 4);
            } else {
                const bits: u64 = @bitCast(f);
                try writeIntLE(&buf, a, bits, 8);
            }
        }
    } else {
        for (items.items.items) |v| {
            const bits = valueToU128Bits(v, item_sz) orelse return raiseType(interp, "non-int in int array");
            try writeIntLE(&buf, a, bits, item_sz);
        }
    }
    var k: usize = 0;
    while (k < buf.items.len) : (k += item_sz) std.mem.reverse(u8, buf.items[k .. k + item_sz]);
    items.items.clearRetainingCapacity();
    try frombytesInto(interp, items, tc, buf.items);
    return Value.none;
}
