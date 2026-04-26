//! `random` module. The fixture mostly checks bounded-output ranges
//! and re-seed determinism, so we ship the full method surface backed
//! by Zig's Xoshiro256 PRNG. State is held in a module-level slot for
//! free functions and in a per-instance map for `Random` instances;
//! every function delegates through `unpack`, which picks the right
//! state regardless of whether the caller invoked us as a method or
//! a module function. Variates use textbook formulas (Box-Muller,
//! Marsaglia-Tsang gamma, Best-Fisher von Mises, etc.).

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Bytes = @import("../object/bytes.zig").Bytes;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const BigInt = @import("../object/bigint.zig").BigInt;
const Interp = @import("interp.zig").Interp;
const builtins_mod = @import("builtins.zig");

const State = struct {
    prng: std.Random.DefaultPrng,
    has_gauss_next: bool = false,
    gauss_next: f64 = 0,

    fn init(seed: u64) State {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    fn random(self: *State) std.Random {
        return self.prng.random();
    }
};

var g_state: State = State.init(0);

var inst_states_init: bool = false;
var inst_states: std.AutoHashMap(*Instance, *State) = undefined;

fn ensureInstMap(a: std.mem.Allocator) void {
    if (!inst_states_init) {
        inst_states = std.AutoHashMap(*Instance, *State).init(a);
        inst_states_init = true;
    }
}

fn instStateOf(interp: *Interp, inst: *Instance) *State {
    ensureInstMap(interp.allocator);
    if (inst_states.get(inst)) |s| return s;
    const s = interp.allocator.create(State) catch unreachable;
    s.* = State.init(0);
    inst_states.put(inst, s) catch {};
    return s;
}

const Unpacked = struct {
    state: *State,
    args: []const Value,
};

fn unpack(interp: *Interp, args: []const Value) Unpacked {
    if (args.len > 0 and args[0] == .instance) {
        const inst = args[0].instance;
        const is_random = if (interp.random_class) |c| inst.cls == c else false;
        const is_sys = if (interp.system_random_class) |c| inst.cls == c else false;
        if (is_random or is_sys) {
            return .{ .state = instStateOf(interp, inst), .args = args[1..] };
        }
    }
    return .{ .state = &g_state, .args = args };
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);
    const m = try Module.init(a, "random");
    try regModule(interp, m, "seed", seedFn);
    try regModule(interp, m, "random", randomFn);
    try regModule(interp, m, "uniform", uniformFn);
    try regModule(interp, m, "randint", randintFn);
    try regModule(interp, m, "randrange", randrangeFn);
    try regModule(interp, m, "getrandbits", getrandbitsFn);
    try regModule(interp, m, "randbytes", randbytesFn);
    try regModule(interp, m, "choice", choiceFn);
    try regModuleKw(interp, m, "choices", choicesFn, choicesKw);
    try regModule(interp, m, "shuffle", shuffleFn);
    try regModuleKw(interp, m, "sample", sampleFn, sampleKw);
    try regModule(interp, m, "binomialvariate", binomialvariateFn);
    try regModule(interp, m, "triangular", triangularFn);
    try regModule(interp, m, "expovariate", expovariateFn);
    try regModule(interp, m, "gauss", gaussFn);
    try regModule(interp, m, "normalvariate", normalvariateFn);
    try regModule(interp, m, "lognormvariate", lognormvariateFn);
    try regModule(interp, m, "gammavariate", gammavariateFn);
    try regModule(interp, m, "betavariate", betavariateFn);
    try regModule(interp, m, "vonmisesvariate", vonmisesvariateFn);
    try regModule(interp, m, "paretovariate", paretovariateFn);
    try regModule(interp, m, "weibullvariate", weibullvariateFn);
    try regModule(interp, m, "getstate", getstateFn);
    try regModule(interp, m, "setstate", setstateFn);
    try m.attrs.setStr(a, "Random", Value{ .class = interp.random_class.? });
    try m.attrs.setStr(a, "SystemRandom", Value{ .class = interp.system_random_class.? });
    return m;
}

fn ensureClasses(interp: *Interp) !void {
    if (interp.random_class != null) return;
    const a = interp.allocator;

    const d = try Dict.init(a);
    try regMethod(a, d, "__init__", initFn);
    try regMethod(a, d, "seed", seedFn);
    try regMethod(a, d, "random", randomFn);
    try regMethod(a, d, "uniform", uniformFn);
    try regMethod(a, d, "randint", randintFn);
    try regMethod(a, d, "randrange", randrangeFn);
    try regMethod(a, d, "getrandbits", getrandbitsFn);
    try regMethod(a, d, "randbytes", randbytesFn);
    try regMethod(a, d, "choice", choiceFn);
    try regMethodKw(a, d, "choices", choicesFn, choicesKw);
    try regMethod(a, d, "shuffle", shuffleFn);
    try regMethodKw(a, d, "sample", sampleFn, sampleKw);
    try regMethod(a, d, "binomialvariate", binomialvariateFn);
    try regMethod(a, d, "triangular", triangularFn);
    try regMethod(a, d, "expovariate", expovariateFn);
    try regMethod(a, d, "gauss", gaussFn);
    try regMethod(a, d, "normalvariate", normalvariateFn);
    try regMethod(a, d, "lognormvariate", lognormvariateFn);
    try regMethod(a, d, "gammavariate", gammavariateFn);
    try regMethod(a, d, "betavariate", betavariateFn);
    try regMethod(a, d, "vonmisesvariate", vonmisesvariateFn);
    try regMethod(a, d, "paretovariate", paretovariateFn);
    try regMethod(a, d, "weibullvariate", weibullvariateFn);
    try regMethod(a, d, "getstate", getstateFn);
    try regMethod(a, d, "setstate", setstateFn);
    interp.random_class = try Class.init(a, "Random", &.{}, d);

    const sd = try Dict.init(a);
    try regMethod(a, sd, "random", randomFn);
    try regMethod(a, sd, "getrandbits", getrandbitsFn);
    try regMethod(a, sd, "randbytes", randbytesFn);
    try regMethod(a, sd, "randint", randintFn);
    try regMethod(a, sd, "randrange", randrangeFn);
    try regMethod(a, sd, "uniform", uniformFn);
    try regMethod(a, sd, "choice", choiceFn);
    interp.system_random_class = try Class.init(a, "SystemRandom", &.{}, sd);
}

fn regModule(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regModuleKw(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regMethod(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regMethodKw(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn asI64(v: Value) i64 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn asF64(v: Value) f64 {
    return switch (v) {
        .float => |f| f,
        .small_int => |i| @floatFromInt(i),
        .boolean => |b| if (b) 1.0 else 0.0,
        else => 0.0,
    };
}

// ===== Class init =====

fn initFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) {
        try interp.typeError("Random.__init__ requires self");
        return error.TypeError;
    }
    const st = instStateOf(interp, args[0].instance);
    const seed: u64 = if (args.len >= 2) blk: {
        break :blk @bitCast(asI64(args[1]));
    } else 0;
    st.* = State.init(seed);
    return Value.none;
}

// ===== Core =====

fn seedFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    const seed: u64 = if (u.args.len >= 1) blk: {
        break :blk @bitCast(asI64(u.args[0]));
    } else 0;
    u.state.* = State.init(seed);
    return Value.none;
}

fn randomFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    return Value{ .float = u.state.random().float(f64) };
}

fn uniformFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    if (u.args.len != 2) {
        try interp.typeError("uniform expects (a, b)");
        return error.TypeError;
    }
    const a: f64 = asF64(u.args[0]);
    const b: f64 = asF64(u.args[1]);
    const r = u.state.random().float(f64);
    return Value{ .float = a + (b - a) * r };
}

fn randintFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    if (u.args.len != 2) {
        try interp.typeError("randint expects (a, b)");
        return error.TypeError;
    }
    const a = asI64(u.args[0]);
    const b = asI64(u.args[1]);
    if (b < a) return Value{ .small_int = a };
    const r = u.state.random().intRangeAtMost(i64, a, b);
    return Value{ .small_int = r };
}

fn randrangeFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    if (u.args.len < 1 or u.args.len > 3) {
        try interp.typeError("randrange expects 1 to 3 ints");
        return error.TypeError;
    }
    var start: i64 = 0;
    var stop: i64 = 0;
    var step: i64 = 1;
    if (u.args.len == 1) {
        stop = asI64(u.args[0]);
    } else {
        start = asI64(u.args[0]);
        stop = asI64(u.args[1]);
        if (u.args.len == 3) step = asI64(u.args[2]);
    }
    if (step == 0) {
        try interp.raisePy("ValueError", "randrange() arg 3 must not be zero");
        return error.PyException;
    }
    const span = stop - start;
    const count: i64 = if (step > 0)
        (if (span <= 0) 0 else @divFloor(span - 1, step) + 1)
    else
        (if (span >= 0) 0 else @divFloor(-span - 1, -step) + 1);
    if (count <= 0) {
        try interp.raisePy("ValueError", "empty range for randrange()");
        return error.PyException;
    }
    const k = u.state.random().intRangeLessThan(i64, 0, count);
    return Value{ .small_int = start + k * step };
}

fn getrandbitsFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    if (u.args.len != 1) {
        try interp.typeError("getrandbits expects (n)");
        return error.TypeError;
    }
    const n = asI64(u.args[0]);
    if (n < 0) {
        try interp.raisePy("ValueError", "number of bits must be non-negative");
        return error.PyException;
    }
    if (n == 0) return Value{ .small_int = 0 };
    if (n <= 63) {
        const top: u64 = if (n == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(n)) - 1;
        const x = u.state.random().int(u64) & top;
        return Value{ .small_int = @intCast(x) };
    }
    // Large n: build a big int from n bits.
    var acc = try std.math.big.int.Managed.initSet(interp.allocator, 0);
    errdefer acc.deinit();
    var remaining: i64 = n;
    var shift: i64 = 0;
    while (remaining > 0) {
        const chunk: u6 = if (remaining >= 32) 32 else @intCast(remaining);
        const mask: u32 = if (chunk == 32) ~@as(u32, 0) else (@as(u32, 1) << @intCast(chunk)) - 1;
        const x = u.state.random().int(u32) & mask;
        var part = try std.math.big.int.Managed.initSet(interp.allocator, @as(u64, x));
        defer part.deinit();
        var sh = try std.math.big.int.Managed.init(interp.allocator);
        defer sh.deinit();
        try sh.shiftLeft(&part, @intCast(shift));
        try acc.add(&acc, &sh);
        shift += chunk;
        remaining -= chunk;
    }
    if (acc.toInt(i64)) |v| {
        acc.deinit();
        return Value{ .small_int = v };
    } else |_| {}
    const big = try BigInt.fromManaged(interp.allocator, acc);
    return Value{ .big_int = big };
}

fn randbytesFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    if (u.args.len != 1) {
        try interp.typeError("randbytes expects (n)");
        return error.TypeError;
    }
    const n: usize = @intCast(asI64(u.args[0]));
    const buf = try interp.allocator.alloc(u8, n);
    defer interp.allocator.free(buf);
    u.state.random().bytes(buf);
    const b = try Bytes.init(interp.allocator, buf);
    return Value{ .bytes = b };
}

fn choiceFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    if (u.args.len != 1) {
        try interp.typeError("choice expects one iterable");
        return error.TypeError;
    }
    const lst = try builtins_mod.materialize(interp, u.args[0]);
    if (lst.items.items.len == 0) {
        try interp.raisePy("IndexError", "Cannot choose from an empty sequence");
        return error.PyException;
    }
    const idx = u.state.random().intRangeLessThan(usize, 0, lst.items.items.len);
    return lst.items.items[idx];
}

const ChoicesOpts = struct {
    k: usize = 1,
    weights: ?Value = null,
    cum_weights: ?Value = null,
};

fn choicesFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    return choicesCore(interp, u.state, u.args, .{});
}

fn choicesKw(p: *anyopaque, raw: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    var opts: ChoicesOpts = .{};
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "k")) opts.k = @intCast(asI64(kv));
        if (std.mem.eql(u8, kn.str.bytes, "weights")) opts.weights = kv;
        if (std.mem.eql(u8, kn.str.bytes, "cum_weights")) opts.cum_weights = kv;
    }
    return choicesCore(interp, u.state, u.args, opts);
}

fn choicesCore(interp: *Interp, state: *State, args: []const Value, opts: ChoicesOpts) !Value {
    const lst = try builtins_mod.materialize(interp, args[0]);
    const n = lst.items.items.len;
    const out = try List.init(interp.allocator);
    if (n == 0) return Value{ .list = out };

    // Build cumulative-weight array if either weights or cum_weights provided.
    var cw: ?[]f64 = null;
    defer if (cw) |w| interp.allocator.free(w);
    if (opts.cum_weights) |cv| {
        const wlst = try builtins_mod.materialize(interp, cv);
        const buf = try interp.allocator.alloc(f64, wlst.items.items.len);
        for (wlst.items.items, 0..) |w, i| buf[i] = asF64(w);
        cw = buf;
    } else if (opts.weights) |wv| {
        const wlst = try builtins_mod.materialize(interp, wv);
        const buf = try interp.allocator.alloc(f64, wlst.items.items.len);
        var acc: f64 = 0;
        for (wlst.items.items, 0..) |w, i| {
            acc += asF64(w);
            buf[i] = acc;
        }
        cw = buf;
    }

    var i: usize = 0;
    while (i < opts.k) : (i += 1) {
        if (cw) |w| {
            const total = w[w.len - 1];
            const r = state.random().float(f64) * total;
            // Linear scan (n is small in practice).
            var j: usize = 0;
            while (j < w.len and r >= w[j]) : (j += 1) {}
            if (j >= n) j = n - 1;
            try out.append(interp.allocator, lst.items.items[j]);
        } else {
            const idx = state.random().intRangeLessThan(usize, 0, n);
            try out.append(interp.allocator, lst.items.items[idx]);
        }
    }
    return Value{ .list = out };
}

fn shuffleFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    if (u.args.len != 1 or u.args[0] != .list) {
        try interp.typeError("shuffle expects a list");
        return error.TypeError;
    }
    const items = u.args[0].list.items.items;
    u.state.random().shuffle(Value, items);
    return Value.none;
}

fn sampleFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    return sampleCore(interp, u.state, u.args, null);
}

fn sampleKw(p: *anyopaque, raw: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    var counts: ?Value = null;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "counts")) counts = kv;
    }
    return sampleCore(interp, u.state, u.args, counts);
}

fn sampleCore(interp: *Interp, state: *State, args: []const Value, counts: ?Value) !Value {
    if (args.len < 2) {
        try interp.typeError("sample expects (population, k)");
        return error.TypeError;
    }
    const lst = try builtins_mod.materialize(interp, args[0]);
    const k: usize = @intCast(asI64(args[1]));
    // If counts provided, expand the population.
    var pop_items: []Value = undefined;
    var owned_pop: ?[]Value = null;
    defer if (owned_pop) |op| interp.allocator.free(op);
    if (counts) |cv| {
        const clst = try builtins_mod.materialize(interp, cv);
        var total: usize = 0;
        for (clst.items.items) |c| total += @intCast(asI64(c));
        const buf = try interp.allocator.alloc(Value, total);
        var idx: usize = 0;
        for (lst.items.items, 0..) |val, i| {
            const cnt: usize = if (i < clst.items.items.len) @intCast(asI64(clst.items.items[i])) else 0;
            var j: usize = 0;
            while (j < cnt) : (j += 1) {
                buf[idx] = val;
                idx += 1;
            }
        }
        pop_items = buf;
        owned_pop = buf;
    } else {
        pop_items = lst.items.items;
    }
    const n = pop_items.len;
    if (k > n) {
        try interp.raisePy("ValueError", "Sample larger than population or is negative");
        return error.PyException;
    }
    const buf = try interp.allocator.alloc(Value, n);
    defer interp.allocator.free(buf);
    @memcpy(buf, pop_items);
    var i: usize = 0;
    while (i < k) : (i += 1) {
        const j = state.random().intRangeLessThan(usize, i, n);
        const tmp = buf[i];
        buf[i] = buf[j];
        buf[j] = tmp;
    }
    const out = try List.init(interp.allocator);
    var x: usize = 0;
    while (x < k) : (x += 1) try out.append(interp.allocator, buf[x]);
    return Value{ .list = out };
}

// ===== Variates =====

fn binomialvariateFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    const n: i64 = if (u.args.len >= 1) asI64(u.args[0]) else 1;
    const pp: f64 = if (u.args.len >= 2) asF64(u.args[1]) else 0.5;
    if (n < 0) {
        try interp.raisePy("ValueError", "n must be non-negative");
        return error.PyException;
    }
    var count: i64 = 0;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        if (u.state.random().float(f64) < pp) count += 1;
    }
    return Value{ .small_int = count };
}

fn triangularFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    const low: f64 = if (u.args.len >= 1) asF64(u.args[0]) else 0.0;
    const high: f64 = if (u.args.len >= 2) asF64(u.args[1]) else 1.0;
    var mode: f64 = (low + high) / 2.0;
    if (u.args.len >= 3 and u.args[2] != .none) mode = asF64(u.args[2]);
    if (high == low) return Value{ .float = low };
    var rr = u.state.random().float(f64);
    var lo = low;
    var hi = high;
    const c = (mode - lo) / (hi - lo);
    if (rr > c) {
        rr = 1.0 - rr;
        const tmp = lo;
        lo = hi;
        hi = tmp;
    }
    return Value{ .float = lo + (hi - lo) * @sqrt(rr * c) };
}

fn expovariateFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    const lambd: f64 = if (u.args.len >= 1) asF64(u.args[0]) else 1.0;
    const rr = 1.0 - u.state.random().float(f64); // in (0, 1]
    return Value{ .float = -@log(rr) / lambd };
}

fn gaussCore(state: *State, mu: f64, sigma: f64) f64 {
    if (state.has_gauss_next) {
        state.has_gauss_next = false;
        return mu + sigma * state.gauss_next;
    }
    var uu1: f64 = 0;
    var uu2: f64 = 0;
    while (true) {
        uu1 = state.random().float(f64);
        if (uu1 > 0) break;
    }
    uu2 = state.random().float(f64);
    const r = @sqrt(-2.0 * @log(uu1));
    const theta = 2.0 * std.math.pi * uu2;
    const z0 = r * @cos(theta);
    const z1 = r * @sin(theta);
    state.gauss_next = z1;
    state.has_gauss_next = true;
    return mu + sigma * z0;
}

fn gaussFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    const mu: f64 = if (u.args.len >= 1) asF64(u.args[0]) else 0.0;
    const sigma: f64 = if (u.args.len >= 2) asF64(u.args[1]) else 1.0;
    return Value{ .float = gaussCore(u.state, mu, sigma) };
}

fn normalvariateFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    const mu: f64 = if (u.args.len >= 1) asF64(u.args[0]) else 0.0;
    const sigma: f64 = if (u.args.len >= 2) asF64(u.args[1]) else 1.0;
    return Value{ .float = gaussCore(u.state, mu, sigma) };
}

fn lognormvariateFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    const mu: f64 = if (u.args.len >= 1) asF64(u.args[0]) else 0.0;
    const sigma: f64 = if (u.args.len >= 2) asF64(u.args[1]) else 1.0;
    return Value{ .float = @exp(gaussCore(u.state, mu, sigma)) };
}

fn gammaCore(state: *State, alpha: f64, beta: f64) f64 {
    // Marsaglia & Tsang for alpha >= 1; Ahrens-Dieter for alpha < 1.
    if (alpha <= 0.0 or beta <= 0.0) return 0.0;
    if (alpha < 1.0) {
        // Ahrens-Dieter rejection
        while (true) {
            const uu1 = state.random().float(f64);
            const b = (std.math.e + alpha) / std.math.e;
            const pp = b * uu1;
            if (pp <= 1.0) {
                const x = std.math.pow(f64, pp, 1.0 / alpha);
                const uu2 = state.random().float(f64);
                if (uu2 <= @exp(-x)) return x * beta;
            } else {
                const x = -@log((b - pp) / alpha);
                const uu2 = state.random().float(f64);
                if (uu2 <= std.math.pow(f64, x, alpha - 1.0)) return x * beta;
            }
        }
    }
    if (alpha == 1.0) {
        const r = 1.0 - state.random().float(f64);
        return -@log(r) * beta;
    }
    const d = alpha - 1.0 / 3.0;
    const c = 1.0 / @sqrt(9.0 * d);
    while (true) {
        var x: f64 = 0;
        var v: f64 = 0;
        while (true) {
            x = gaussCore(state, 0.0, 1.0);
            v = 1.0 + c * x;
            if (v > 0) break;
        }
        v = v * v * v;
        const uu1 = state.random().float(f64);
        if (uu1 < 1.0 - 0.0331 * (x * x) * (x * x)) return d * v * beta;
        if (@log(uu1) < 0.5 * x * x + d * (1.0 - v + @log(v))) return d * v * beta;
    }
}

fn gammavariateFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    const alpha: f64 = if (u.args.len >= 1) asF64(u.args[0]) else 1.0;
    const beta: f64 = if (u.args.len >= 2) asF64(u.args[1]) else 1.0;
    return Value{ .float = gammaCore(u.state, alpha, beta) };
}

fn betavariateFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    const alpha: f64 = if (u.args.len >= 1) asF64(u.args[0]) else 1.0;
    const beta: f64 = if (u.args.len >= 2) asF64(u.args[1]) else 1.0;
    const x = gammaCore(u.state, alpha, 1.0);
    if (x == 0.0) return Value{ .float = 0.0 };
    const y = gammaCore(u.state, beta, 1.0);
    return Value{ .float = x / (x + y) };
}

fn vonmisesvariateFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    const mu: f64 = if (u.args.len >= 1) asF64(u.args[0]) else 0.0;
    const kappa: f64 = if (u.args.len >= 2) asF64(u.args[1]) else 1.0;
    if (kappa <= 1e-6) {
        return Value{ .float = 2.0 * std.math.pi * u.state.random().float(f64) };
    }
    // Best-Fisher algorithm (CPython's stdlib implementation)
    const s = 0.5 / kappa;
    const r = s + @sqrt(1.0 + s * s);
    var theta: f64 = 0;
    while (true) {
        const uu1 = u.state.random().float(f64);
        const z = @cos(std.math.pi * uu1);
        const d = z / (r + z);
        const uu2 = u.state.random().float(f64);
        if (uu2 < 1.0 - d * d or uu2 <= (1.0 - d) * @exp(d)) {
            const q = 1.0 / r;
            const f = (q + z) / (1.0 + q * z);
            const uu3 = u.state.random().float(f64);
            if (uu3 > 0.5) {
                theta = @mod(mu + std.math.acos(f), 2.0 * std.math.pi);
            } else {
                theta = @mod(mu - std.math.acos(f), 2.0 * std.math.pi);
            }
            break;
        }
    }
    if (theta < 0) theta += 2.0 * std.math.pi;
    return Value{ .float = theta };
}

fn paretovariateFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    const alpha: f64 = if (u.args.len >= 1) asF64(u.args[0]) else 1.0;
    const r = 1.0 - u.state.random().float(f64);
    return Value{ .float = std.math.pow(f64, r, -1.0 / alpha) };
}

fn weibullvariateFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    const alpha: f64 = if (u.args.len >= 1) asF64(u.args[0]) else 1.0;
    const beta: f64 = if (u.args.len >= 2) asF64(u.args[1]) else 1.0;
    const r = 1.0 - u.state.random().float(f64);
    return Value{ .float = alpha * std.math.pow(f64, -@log(r), 1.0 / beta) };
}

// ===== getstate / setstate =====

fn getstateFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    const a = interp.allocator;
    const t = try Tuple.init(a, 6);
    inline for (0..4) |i| {
        const x: u64 = u.state.prng.s[i];
        if (x <= std.math.maxInt(i64)) {
            t.items[i] = Value{ .small_int = @intCast(x) };
        } else {
            var bi = try std.math.big.int.Managed.initSet(a, x);
            errdefer bi.deinit();
            const bv = try BigInt.fromManaged(a, bi);
            t.items[i] = Value{ .big_int = bv };
        }
    }
    t.items[4] = Value{ .boolean = u.state.has_gauss_next };
    t.items[5] = Value{ .float = u.state.gauss_next };
    return Value{ .tuple = t };
}

fn u64FromValue(v: Value) u64 {
    return switch (v) {
        .small_int => |i| @bitCast(i),
        .big_int => |bi| blk: {
            // Best effort: try toInt(u64); fall back to lower bits.
            if (bi.inner.toInt(u64)) |x| break :blk x else |_| {}
            break :blk 0;
        },
        .boolean => |b| @intFromBool(b),
        else => 0,
    };
}

fn setstateFn(p: *anyopaque, raw: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const u = unpack(interp, raw);
    if (u.args.len != 1 or u.args[0] != .tuple) {
        try interp.typeError("setstate expects a tuple");
        return error.TypeError;
    }
    const t = u.args[0].tuple;
    if (t.items.len < 4) {
        try interp.raisePy("ValueError", "state vector too short");
        return error.PyException;
    }
    inline for (0..4) |i| {
        u.state.prng.s[i] = u64FromValue(t.items[i]);
    }
    if (t.items.len >= 5) u.state.has_gauss_next = t.items[4] == .boolean and t.items[4].boolean;
    if (t.items.len >= 6) u.state.gauss_next = asF64(t.items[5]);
    return Value.none;
}
