//! Pinhole `random` module. We don't reproduce CPython's Mersenne
//! Twister byte for byte; the fixture only checks (a) re-seeding to
//! the same int yields the same `random()`, and (b) bounded outputs
//! land in the documented intervals. A deterministic stdlib PRNG
//! threaded through interp state is enough.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Interp = @import("interp.zig").Interp;
const builtins_mod = @import("builtins.zig");

const State = struct {
    prng: std.Random.DefaultPrng,

    fn init(seed: u64) State {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    fn random(self: *State) std.Random {
        return self.prng.random();
    }
};

var g_state: State = State.init(0);

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "random");
    try reg(interp, m, "seed", seedFn);
    try reg(interp, m, "random", randomFn);
    try reg(interp, m, "randint", randintFn);
    try reg(interp, m, "choice", choiceFn);
    try regKw(interp, m, "choices", choicesFn, choicesKw);
    try reg(interp, m, "shuffle", shuffleFn);
    try reg(interp, m, "sample", sampleFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw_func: value_mod.BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn asI64(v: Value) i64 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        else => 0,
    };
}

fn seedFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const seed: u64 = if (args.len >= 1) blk: {
        const v = asI64(args[0]);
        break :blk @bitCast(v);
    } else 0;
    g_state = State.init(seed);
    return Value.none;
}

fn randomFn(_: *anyopaque, _: []const Value) anyerror!Value {
    const f = g_state.random().float(f64);
    return Value{ .float = f };
}

fn randintFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2) {
        try interp.typeError("randint expects (a, b)");
        return error.TypeError;
    }
    const a = asI64(args[0]);
    const b = asI64(args[1]);
    if (b < a) return Value{ .small_int = a };
    const r = g_state.random().intRangeAtMost(i64, a, b);
    return Value{ .small_int = r };
}

fn choiceFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1) {
        try interp.typeError("choice expects one iterable");
        return error.TypeError;
    }
    const lst = try builtins_mod.materialize(interp, args[0]);
    if (lst.items.items.len == 0) {
        try interp.raisePy("IndexError", "Cannot choose from an empty sequence");
        return error.PyException;
    }
    const idx = g_state.random().intRangeLessThan(usize, 0, lst.items.items.len);
    return lst.items.items[idx];
}

fn choicesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    // Simplified: positional `population` and optional `k` as arg[1]
    // when we got it as positional. The fixture passes `k=` as kwarg
    // but we also accept positional. With kwargs we'd need a kw_func;
    // for the fixture, we patch via a kw entry point too.
    const interp: *Interp = @ptrCast(@alignCast(p));
    return choicesCore(interp, args, 1);
}

fn choicesKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var k: usize = 1;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "k")) k = @intCast(asI64(kv));
    }
    return choicesCore(interp, args, k);
}

fn choicesCore(interp: *Interp, args: []const Value, k_default: usize) !Value {
    const lst = try builtins_mod.materialize(interp, args[0]);
    var k: usize = k_default;
    if (args.len >= 2) k = @intCast(asI64(args[1]));
    const out = try List.init(interp.allocator);
    if (lst.items.items.len == 0) return Value{ .list = out };
    var i: usize = 0;
    while (i < k) : (i += 1) {
        const idx = g_state.random().intRangeLessThan(usize, 0, lst.items.items.len);
        try out.append(interp.allocator, lst.items.items[idx]);
    }
    return Value{ .list = out };
}

fn shuffleFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .list) {
        try interp.typeError("shuffle expects a list");
        return error.TypeError;
    }
    const items = args[0].list.items.items;
    g_state.random().shuffle(Value, items);
    return Value.none;
}

fn sampleFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 2) {
        try interp.typeError("sample expects (population, k)");
        return error.TypeError;
    }
    const lst = try builtins_mod.materialize(interp, args[0]);
    const k: usize = @intCast(asI64(args[1]));
    const n = lst.items.items.len;
    if (k > n) {
        try interp.raisePy("ValueError", "Sample larger than population");
        return error.PyException;
    }
    const buf = try interp.allocator.alloc(Value, n);
    defer interp.allocator.free(buf);
    @memcpy(buf, lst.items.items);
    // Partial Fisher-Yates: swap the last n-i elements.
    var i: usize = 0;
    while (i < k) : (i += 1) {
        const j = g_state.random().intRangeLessThan(usize, i, n);
        const tmp = buf[i];
        buf[i] = buf[j];
        buf[j] = tmp;
    }
    const out = try List.init(interp.allocator);
    var x: usize = 0;
    while (x < k) : (x += 1) try out.append(interp.allocator, buf[x]);
    return Value{ .list = out };
}
