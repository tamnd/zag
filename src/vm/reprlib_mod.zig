//! Pinhole `reprlib` module. Provides a `Repr` class with the
//! per-type size limits CPython exposes (`maxlist`, `maxdict`,
//! `maxstring`, ...), a module-level `aRepr` instance plus
//! `reprlib.repr` shortcut, and `recursive_repr(fillvalue=...)`,
//! a decorator that swaps in `fillvalue` whenever a `__repr__`
//! recurses into the same instance.
//!
//! Limits are read live from the instance dict so user code can
//! mutate `r.maxlist = 3` and the next `r.repr(...)` honors it.

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
const Set = @import("../object/set.zig").Set;
const Str = @import("../object/string.zig").Str;
const Bytes = @import("../object/bytes.zig").Bytes;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");
const dunder = @import("dunder.zig");

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);

    const m = try Module.init(a, "reprlib");
    try m.attrs.setStr(a, "Repr", Value{ .class = interp.reprlib_repr_class.? });

    const arepr = try newDefaultRepr(interp);
    try m.attrs.setStr(a, "aRepr", arepr);
    interp.reprlib_arepr = arepr;

    try regModFn(interp, m, "repr", reprModFn);
    try regModKw(interp, m, "recursive_repr", recursiveReprKw);
    return m;
}

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;
    if (interp.reprlib_repr_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "__init__", reprInitFn);
        try reg(a, d, "repr", reprMethod);
        try reg(a, d, "repr1", repr1Method);
        interp.reprlib_repr_class = try Class.init(a, "Repr", &.{}, d);
    }
    if (interp.reprlib_recursive_wrapper_class == null) {
        const d = try Dict.init(a);
        try reg(a, d, "__call__", recursiveWrapperCall);
        interp.reprlib_recursive_wrapper_class = try Class.init(a, "_RecursiveReprWrapper", &.{}, d);
    }
}

fn reg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regModFn(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regModKw(interp: *Interp, m: *Module, name: []const u8, comptime kw_func: BuiltinKwFnPtr) !void {
    const Wrap = struct {
        fn call(p: *anyopaque, args: []const Value) anyerror!Value {
            return kw_func(p, args, &.{}, &.{});
        }
    };
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = Wrap.call, .kw_func = kw_func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

// ===== Default Repr instance =====

fn newDefaultRepr(interp: *Interp) !Value {
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.reprlib_repr_class.?);
    try setDefaults(a, inst);
    return Value{ .instance = inst };
}

fn setDefaults(a: std.mem.Allocator, inst: *Instance) !void {
    try inst.dict.setStr(a, "maxlevel", Value{ .small_int = 6 });
    try inst.dict.setStr(a, "maxtuple", Value{ .small_int = 6 });
    try inst.dict.setStr(a, "maxlist", Value{ .small_int = 6 });
    try inst.dict.setStr(a, "maxarray", Value{ .small_int = 5 });
    try inst.dict.setStr(a, "maxdict", Value{ .small_int = 4 });
    try inst.dict.setStr(a, "maxset", Value{ .small_int = 6 });
    try inst.dict.setStr(a, "maxfrozenset", Value{ .small_int = 6 });
    try inst.dict.setStr(a, "maxdeque", Value{ .small_int = 6 });
    try inst.dict.setStr(a, "maxstring", Value{ .small_int = 30 });
    try inst.dict.setStr(a, "maxlong", Value{ .small_int = 40 });
    try inst.dict.setStr(a, "maxother", Value{ .small_int = 30 });
    const fill = try Str.init(a, "...");
    try inst.dict.setStr(a, "fillvalue", Value{ .str = fill });
}

fn reprInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) {
        try interp.typeError("Repr.__init__ expects self");
        return error.TypeError;
    }
    try setDefaults(interp.allocator, args[0].instance);
    return Value.none;
}

// ===== reprlib.repr (module-level) =====

fn reprModFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1) {
        try interp.typeError("reprlib.repr() takes one argument");
        return error.TypeError;
    }
    const arepr = interp.reprlib_arepr orelse {
        try interp.typeError("reprlib.aRepr not initialized");
        return error.TypeError;
    };
    if (arepr != .instance) return error.TypeError;
    return formatRepr(interp, arepr.instance, args[0]);
}

// ===== Repr.repr / Repr.repr1 =====

fn reprMethod(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2 or args[0] != .instance) {
        try interp.typeError("Repr.repr expects (self, obj)");
        return error.TypeError;
    }
    return formatRepr(interp, args[0].instance, args[1]);
}

fn repr1Method(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 3 or args[0] != .instance) {
        try interp.typeError("Repr.repr1 expects (self, obj, level)");
        return error.TypeError;
    }
    if (args[2] != .small_int) {
        try interp.typeError("Repr.repr1: level must be int");
        return error.TypeError;
    }
    const level: i64 = args[2].small_int;
    const out = try repr1(interp, args[0].instance, args[1], level);
    return Value{ .str = try Str.init(interp.allocator, out) };
}

fn formatRepr(interp: *Interp, self: *Instance, obj: Value) !Value {
    const level = readInt(self, "maxlevel", 6);
    const s = try repr1(interp, self, obj, level);
    return Value{ .str = try Str.init(interp.allocator, s) };
}

// ===== Core dispatch =====

fn repr1(interp: *Interp, self: *Instance, x: Value, level: i64) anyerror![]const u8 {
    return switch (x) {
        .list => |l| reprIterable(interp, self, l.items.items, "[", "]", readInt(self, "maxlist", 6), level, false),
        .tuple => |t| reprIterable(interp, self, t.items, "(", ")", readInt(self, "maxtuple", 6), level, true),
        .set => |s| blk: {
            if (s.items.items.len == 0) break :blk if (s.frozen)
                try interp.allocator.dupe(u8, "frozenset()")
            else
                try interp.allocator.dupe(u8, "set()");
            const sorted = try interp.allocator.dupe(Value, s.items.items);
            defer interp.allocator.free(sorted);
            std.sort.block(Value, sorted, {}, lessValue);
            const limit = readInt(self, if (s.frozen) "maxfrozenset" else "maxset", 6);
            if (s.frozen) {
                const inner = try reprIterable(interp, self, sorted, "{", "}", limit, level, false);
                defer interp.allocator.free(inner);
                break :blk try std.fmt.allocPrint(interp.allocator, "frozenset({s})", .{inner});
            }
            break :blk try reprIterable(interp, self, sorted, "{", "}", limit, level, false);
        },
        .dict => |d| reprDict(interp, self, d, level),
        .str => reprStr(interp, self, x),
        .small_int, .big_int => reprInt(interp, self, x),
        else => reprOther(interp, self, x),
    };
}

fn reprIterable(
    interp: *Interp,
    self: *Instance,
    items: []const Value,
    left: []const u8,
    right: []const u8,
    maxiter: i64,
    level: i64,
    is_tuple: bool,
) anyerror![]const u8 {
    var w = std.Io.Writer.Allocating.init(interp.allocator);
    try w.writer.writeAll(left);
    if (level <= 0 and items.len > 0) {
        try writeFill(&w.writer, self);
    } else {
        const newlevel = level - 1;
        const limit: usize = @intCast(@max(@as(i64, 0), maxiter));
        const n = @min(items.len, limit);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i > 0) try w.writer.writeAll(", ");
            const piece = try repr1(interp, self, items[i], newlevel);
            defer interp.allocator.free(piece);
            try w.writer.writeAll(piece);
        }
        if (items.len > limit) {
            if (n > 0) try w.writer.writeAll(", ");
            try writeFill(&w.writer, self);
        }
        if (items.len == 1 and is_tuple) try w.writer.writeAll(",");
    }
    try w.writer.writeAll(right);
    return w.written();
}

fn reprDict(interp: *Interp, self: *Instance, d: *Dict, level: i64) anyerror![]const u8 {
    var w = std.Io.Writer.Allocating.init(interp.allocator);
    try w.writer.writeAll("{");
    if (level <= 0 and d.pairs.items.len > 0) {
        try writeFill(&w.writer, self);
    } else {
        const newlevel = level - 1;
        const maxd = readInt(self, "maxdict", 4);
        const limit: usize = @intCast(@max(@as(i64, 0), maxd));
        // Sort keys for stable output (matches CPython for str/int keys).
        const sorted = try interp.allocator.dupe(Dict.Pair, d.pairs.items);
        defer interp.allocator.free(sorted);
        std.sort.block(Dict.Pair, sorted, {}, lessPairKey);
        const n = @min(sorted.len, limit);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i > 0) try w.writer.writeAll(", ");
            const ks = try repr1(interp, self, sorted[i].key, newlevel);
            defer interp.allocator.free(ks);
            try w.writer.writeAll(ks);
            try w.writer.writeAll(": ");
            const vs = try repr1(interp, self, sorted[i].value, newlevel);
            defer interp.allocator.free(vs);
            try w.writer.writeAll(vs);
        }
        if (sorted.len > limit) {
            if (n > 0) try w.writer.writeAll(", ");
            try writeFill(&w.writer, self);
        }
    }
    try w.writer.writeAll("}");
    return w.written();
}

fn reprStr(interp: *Interp, self: *Instance, x: Value) anyerror![]const u8 {
    const a = interp.allocator;
    var probe = std.Io.Writer.Allocating.init(a);
    try x.writeRepr(&probe.writer);
    const full = probe.written();
    const maxstr: i64 = readInt(self, "maxstring", 30);
    const ms: usize = @intCast(@max(@as(i64, 0), maxstr));
    if (full.len <= ms) return full;
    // Trim: i = (maxstring - 3) / 2, j = maxstring - 3 - i.
    const fill = readFill(self);
    if (ms <= fill.len) {
        // Degenerate: fillvalue fills the budget already.
        return try a.dupe(u8, fill);
    }
    const i_n: usize = (ms - 3) / 2;
    const j_n: usize = ms - 3 - i_n;
    if (full.len < i_n + j_n) return full;
    const head = full[0..i_n];
    const tail = full[full.len - j_n ..];
    return try std.fmt.allocPrint(a, "{s}{s}{s}", .{ head, fill, tail });
}

fn reprInt(interp: *Interp, self: *Instance, x: Value) anyerror![]const u8 {
    const a = interp.allocator;
    var probe = std.Io.Writer.Allocating.init(a);
    try x.writeRepr(&probe.writer);
    const full = probe.written();
    const maxlong: i64 = readInt(self, "maxlong", 40);
    const ml: usize = @intCast(@max(@as(i64, 0), maxlong));
    if (full.len <= ml) return full;
    const fill = readFill(self);
    if (ml <= fill.len) return try a.dupe(u8, fill);
    const i_n: usize = (ml - 3) / 2;
    const j_n: usize = ml - 3 - i_n;
    const head = full[0..i_n];
    const tail = full[full.len - j_n ..];
    return try std.fmt.allocPrint(a, "{s}{s}{s}", .{ head, fill, tail });
}

fn reprOther(interp: *Interp, self: *Instance, x: Value) anyerror![]const u8 {
    const a = interp.allocator;
    var probe = std.Io.Writer.Allocating.init(a);
    // Try __repr__ for instances first, otherwise fall back to default writeRepr.
    if (x == .instance) {
        if (try dunder.call(interp, x, "__repr__", &.{})) |r| {
            if (r == .str) {
                return clipOther(interp, self, r.str.bytes);
            }
        }
    }
    try x.writeRepr(&probe.writer);
    return clipOther(interp, self, probe.written());
}

fn clipOther(interp: *Interp, self: *Instance, full: []const u8) ![]const u8 {
    const a = interp.allocator;
    const maxother: i64 = readInt(self, "maxother", 30);
    const mo: usize = @intCast(@max(@as(i64, 0), maxother));
    if (full.len <= mo) return try a.dupe(u8, full);
    const fill = readFill(self);
    if (mo <= fill.len) return try a.dupe(u8, fill);
    const i_n: usize = (mo - 3) / 2;
    const j_n: usize = mo - 3 - i_n;
    const head = full[0..i_n];
    const tail = full[full.len - j_n ..];
    return try std.fmt.allocPrint(a, "{s}{s}{s}", .{ head, fill, tail });
}

// ===== helpers =====

fn readInt(self: *Instance, name: []const u8, default: i64) i64 {
    if (self.dict.getStr(name)) |v| if (v == .small_int) return v.small_int;
    return default;
}

fn readFill(self: *Instance) []const u8 {
    if (self.dict.getStr("fillvalue")) |v| if (v == .str) return v.str.bytes;
    return "...";
}

fn writeFill(w: *std.Io.Writer, self: *Instance) !void {
    try w.writeAll(readFill(self));
}

fn lessValue(_: void, a: Value, b: Value) bool {
    return switch (a) {
        .small_int => |ai| switch (b) {
            .small_int => |bi| ai < bi,
            else => false,
        },
        .str => |as| switch (b) {
            .str => |bs| std.mem.lessThan(u8, as.bytes, bs.bytes),
            else => false,
        },
        else => false,
    };
}

fn lessPairKey(_: void, a: Dict.Pair, b: Dict.Pair) bool {
    return lessValue({}, a.key, b.key);
}

// ===== recursive_repr decorator =====

/// `recursive_repr(fillvalue='...')` is a decorator factory. It returns
/// a callable that takes the user's `__repr__` and produces a wrapper
/// that swaps in `fillvalue` whenever the same instance is already
/// being repr'd further up the call stack.
fn recursiveReprKw(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var fill_v: Value = Value{ .str = try Str.init(interp.allocator, "...") };
    if (args.len > 1) {
        try interp.typeError("recursive_repr() takes at most one positional argument");
        return error.TypeError;
    }
    if (args.len == 1) fill_v = args[0];
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "fillvalue")) fill_v = kv;
    }
    // Build a closure-ish builtin: returns a builtin_fn that, when
    // called with the user function, produces a wrapper instance.
    const a = interp.allocator;
    const factory_inst = try Instance.init(a, interp.reprlib_recursive_wrapper_class.?);
    try factory_inst.dict.setStr(a, "_factory_only", Value{ .boolean = true });
    try factory_inst.dict.setStr(a, "_fillvalue", fill_v);
    return Value{ .instance = factory_inst };
}

/// `__call__` for the wrapper instance. Two modes share a class:
/// 1. Factory mode (`_factory_only` true): the user did
///    `dec = recursive_repr()` and is now applying `dec(user_fn)`. Builds
///    the real wrapper instance, captures `_wrapped`, returns it.
/// 2. Wrapper mode: this is the wrapped `__repr__` itself. Receives
///    `(self, target)`. Checks `_running` for `id(target)`; on hit,
///    returns `_fillvalue`. Otherwise records the id, invokes the
///    underlying function on `target`, then clears the id.
fn recursiveWrapperCall(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) {
        try interp.typeError("_RecursiveReprWrapper.__call__ expects (self, target)");
        return error.TypeError;
    }
    const self_inst = args[0].instance;
    const factory_only = if (self_inst.dict.getStr("_factory_only")) |v|
        (v == .boolean and v.boolean)
    else
        false;
    if (factory_only) {
        // Building the wrapper around args[1] (the user function).
        if (args.len != 2) {
            try interp.typeError("recursive_repr decorator takes one argument");
            return error.TypeError;
        }
        const a = interp.allocator;
        const wrapper = try Instance.init(a, interp.reprlib_recursive_wrapper_class.?);
        try wrapper.dict.setStr(a, "_wrapped", args[1]);
        try wrapper.dict.setStr(a, "_fillvalue", self_inst.dict.getStr("_fillvalue") orelse Value{ .str = try Str.init(a, "...") });
        const running = try Dict.init(a);
        try wrapper.dict.setStr(a, "_running", Value{ .dict = running });
        return Value{ .instance = wrapper };
    }
    // Wrapper-mode: detect recursion on args[1].
    const wrapped = self_inst.dict.getStr("_wrapped") orelse {
        try interp.typeError("recursive_repr wrapper missing _wrapped");
        return error.TypeError;
    };
    const fill = self_inst.dict.getStr("_fillvalue") orelse Value{ .str = try Str.init(interp.allocator, "...") };
    const running_v = self_inst.dict.getStr("_running") orelse {
        try interp.typeError("recursive_repr wrapper missing _running");
        return error.TypeError;
    };
    if (running_v != .dict) return error.TypeError;
    const running = running_v.dict;

    const target = args[1];
    const id_int: i64 = @intCast(@as(usize, switch (target) {
        .instance => |i| @intFromPtr(i),
        .list => |l| @intFromPtr(l),
        .dict => |d| @intFromPtr(d),
        .set => |s| @intFromPtr(s),
        .tuple => |t| @intFromPtr(t),
        else => 0,
    }));
    const id_v = Value{ .small_int = id_int };
    if (id_int != 0 and running.getKey(id_v) != null) {
        return fill;
    }
    if (id_int != 0) try running.setKey(interp.allocator, id_v, Value{ .boolean = true });
    defer if (id_int != 0) {
        _ = running.removeKeyWrap(id_v);
    };
    // Forward all positional args after self to the underlying function.
    return try dispatch.invoke(interp, wrapped, args[1..]);
}
