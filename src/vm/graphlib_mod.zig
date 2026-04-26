//! Pinhole `graphlib` module. `TopologicalSorter` runs Kahn's
//! algorithm; `prepare` detects cycles via three-color DFS and
//! raises `CycleError` (a subclass of `ValueError`) when one
//! exists. The fixture only exercises hashable string nodes; we
//! key the per-node bookkeeping off zag's `Dict` so the same path
//! handles ints/tuples/etc. if a future fixture wants them.
//!
//! State lives on the instance dict: `_preds`, `_succs`,
//! `_pred_count`, `_state`, `_ready`, `_emitted`, `_all_nodes`,
//! `_prepared`, `_n_done`. add/done/get_ready/is_active/
//! static_order all read and update those fields.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

const STATE_WAITING: i64 = 0;
const STATE_READY: i64 = 1;
const STATE_EMITTED: i64 = 2;
const STATE_DONE: i64 = 3;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);
    const m = try Module.init(a, "graphlib");
    try m.attrs.setStr(a, "TopologicalSorter", Value{ .class = interp.graphlib_sorter_class.? });
    try m.attrs.setStr(a, "CycleError", Value{ .class = interp.graphlib_cycle_error_class.? });
    return m;
}

fn ensureClasses(interp: *Interp) !void {
    if (interp.graphlib_sorter_class != null) return;
    const a = interp.allocator;

    const value_error = interp.builtins.getStr("ValueError") orelse return error.TypeError;
    if (value_error != .class) return error.TypeError;
    const cycle_dict = try Dict.init(a);
    interp.graphlib_cycle_error_class = try Class.init(a, "CycleError", &.{value_error.class}, cycle_dict);

    const sorter_dict = try Dict.init(a);
    try reg(a, sorter_dict, "__init__", initFn);
    try reg(a, sorter_dict, "add", addFn);
    try reg(a, sorter_dict, "prepare", prepareFn);
    try reg(a, sorter_dict, "get_ready", getReadyFn);
    try reg(a, sorter_dict, "done", doneFn);
    try reg(a, sorter_dict, "is_active", isActiveFn);
    try reg(a, sorter_dict, "static_order", staticOrderFn);
    interp.graphlib_sorter_class = try Class.init(a, "TopologicalSorter", &.{}, sorter_dict);
}

fn reg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

// ===== state helpers =====

fn newDict(a: std.mem.Allocator) !*Dict {
    return try Dict.init(a);
}

fn newList(a: std.mem.Allocator) !*List {
    return try List.init(a);
}

fn ensureNode(a: std.mem.Allocator, inst: *Instance, node: Value) !void {
    const preds_v = inst.dict.getStr("_preds") orelse return error.TypeError;
    if (preds_v != .dict) return error.TypeError;
    if (preds_v.dict.getKey(node) == null) {
        const lst = try newList(a);
        try preds_v.dict.setKey(a, node, Value{ .list = lst });
        const succs_v = inst.dict.getStr("_succs").?.dict;
        const slst = try newList(a);
        try succs_v.setKey(a, node, Value{ .list = slst });
        const all_v = inst.dict.getStr("_all_nodes").?.list;
        try all_v.append(a, node);
    }
}

fn prepared(inst: *Instance) bool {
    const v = inst.dict.getStr("_prepared") orelse return false;
    return v == .boolean and v.boolean;
}

fn raiseValue(interp: *Interp, msg: []const u8) !void {
    try interp.raisePy("ValueError", msg);
}

// ===== __init__ =====

fn initFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) {
        try interp.typeError("TopologicalSorter.__init__ expects self");
        return error.TypeError;
    }
    const inst = args[0].instance;
    try inst.dict.setStr(a, "_preds", Value{ .dict = try newDict(a) });
    try inst.dict.setStr(a, "_succs", Value{ .dict = try newDict(a) });
    try inst.dict.setStr(a, "_pred_count", Value{ .dict = try newDict(a) });
    try inst.dict.setStr(a, "_state", Value{ .dict = try newDict(a) });
    try inst.dict.setStr(a, "_all_nodes", Value{ .list = try newList(a) });
    try inst.dict.setStr(a, "_ready", Value{ .list = try newList(a) });
    try inst.dict.setStr(a, "_emitted", Value{ .dict = try newDict(a) });
    try inst.dict.setStr(a, "_prepared", Value{ .boolean = false });
    try inst.dict.setStr(a, "_n_done", Value{ .small_int = 0 });

    if (args.len == 1) return Value.none;
    if (args.len > 2) {
        try interp.typeError("TopologicalSorter takes at most one argument");
        return error.TypeError;
    }
    const graph = args[1];
    if (graph == .none) return Value.none;
    if (graph != .dict) {
        try interp.typeError("TopologicalSorter graph must be a dict");
        return error.TypeError;
    }
    for (graph.dict.pairs.items) |pair| {
        try ensureNode(a, inst, pair.key);
        switch (pair.value) {
            .list => |l| for (l.items.items) |dep| try addOne(interp, inst, pair.key, dep),
            .tuple => |t| for (t.items) |dep| try addOne(interp, inst, pair.key, dep),
            .set => |s| for (s.items.items) |dep| try addOne(interp, inst, pair.key, dep),
            else => {
                try interp.typeError("Iterable expected for predecessors");
                return error.TypeError;
            },
        }
    }
    return Value.none;
}

fn addOne(interp: *Interp, inst: *Instance, node: Value, pred: Value) !void {
    const a = interp.allocator;
    try ensureNode(a, inst, node);
    try ensureNode(a, inst, pred);
    const preds_d = inst.dict.getStr("_preds").?.dict;
    const succs_d = inst.dict.getStr("_succs").?.dict;
    const node_preds = preds_d.getKey(node).?.list;
    var seen = false;
    for (node_preds.items.items) |p| if (p.equals(pred)) {
        seen = true;
        break;
    };
    if (!seen) try node_preds.append(a, pred);

    const pred_succs = succs_d.getKey(pred).?.list;
    var seen2 = false;
    for (pred_succs.items.items) |s| if (s.equals(node)) {
        seen2 = true;
        break;
    };
    if (!seen2) try pred_succs.append(a, node);
}

// ===== add =====

fn addFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) {
        try interp.typeError("TopologicalSorter.add expects (self, node, *preds)");
        return error.TypeError;
    }
    const inst = args[0].instance;
    if (prepared(inst)) {
        try raiseValue(interp, "Nodes cannot be added after a call to prepare()");
        return error.PyException;
    }
    try ensureNode(a, inst, args[1]);
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        try addOne(interp, inst, args[1], args[i]);
    }
    return Value.none;
}

// ===== prepare =====

fn prepareFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len != 1 or args[0] != .instance) {
        try interp.typeError("prepare() expects self");
        return error.TypeError;
    }
    const inst = args[0].instance;
    if (prepared(inst)) {
        try raiseValue(interp, "graph already prepared");
        return error.PyException;
    }
    const all = inst.dict.getStr("_all_nodes").?.list;
    const preds_d = inst.dict.getStr("_preds").?.dict;
    const pred_count = inst.dict.getStr("_pred_count").?.dict;
    const state = inst.dict.getStr("_state").?.dict;
    const ready = inst.dict.getStr("_ready").?.list;

    // Initialize pred_count and state.
    for (all.items.items) |node| {
        const np = preds_d.getKey(node).?.list;
        try pred_count.setKey(a, node, Value{ .small_int = @intCast(np.items.items.len) });
        try state.setKey(a, node, Value{ .small_int = STATE_WAITING });
        if (np.items.items.len == 0) {
            try ready.append(a, node);
            try state.setKey(a, node, Value{ .small_int = STATE_READY });
        }
    }

    // Cycle detection via three-color DFS over the successor graph.
    if (try detectCycle(interp, inst)) |cycle_nodes| {
        const ce_cls = interp.graphlib_cycle_error_class.?;
        const ce_inst = try Instance.init(a, ce_cls);
        const t = try Tuple.init(a, 2);
        const msg = try Str.init(a, "nodes are in a cycle");
        t.items[0] = Value{ .str = msg };
        t.items[1] = Value{ .list = cycle_nodes };
        try ce_inst.dict.setStr(a, "args", Value{ .tuple = t });
        interp.current_exc = Value{ .instance = ce_inst };
        return error.PyException;
    }

    try inst.dict.setStr(a, "_prepared", Value{ .boolean = true });
    return Value.none;
}

fn detectCycle(interp: *Interp, inst: *Instance) !?*List {
    const a = interp.allocator;
    const all = inst.dict.getStr("_all_nodes").?.list;
    const succs_d = inst.dict.getStr("_succs").?.dict;
    const color = try Dict.init(a);

    // Three-color DFS. White: not visited. Gray: in current path.
    // Black: done. A gray neighbor signals the cycle.
    var path: std.ArrayList(Value) = .empty;
    defer path.deinit(a);

    for (all.items.items) |start| {
        if (color.getKey(start) != null) continue;
        if (try dfsFind(interp, succs_d, color, start, &path)) |cycle| return cycle;
    }
    return null;
}

fn dfsFind(
    interp: *Interp,
    succs_d: *Dict,
    color: *Dict,
    start: Value,
    path: *std.ArrayList(Value),
) anyerror!?*List {
    const a = interp.allocator;
    // Iterative DFS with an explicit stack of (node, iter_index).
    var stack: std.ArrayList(struct { node: Value, idx: usize }) = .empty;
    defer stack.deinit(a);
    try stack.append(a, .{ .node = start, .idx = 0 });
    try color.setKey(a, start, Value{ .small_int = 1 }); // gray
    try path.append(a, start);

    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        const succs = succs_d.getKey(top.node).?.list;
        if (top.idx >= succs.items.items.len) {
            // Pop: mark black, drop from path.
            try color.setKey(a, top.node, Value{ .small_int = 2 });
            _ = path.pop();
            _ = stack.pop();
            continue;
        }
        const next = succs.items.items[top.idx];
        top.idx += 1;
        const c = color.getKey(next);
        if (c == null) {
            try color.setKey(a, next, Value{ .small_int = 1 });
            try path.append(a, next);
            try stack.append(a, .{ .node = next, .idx = 0 });
            continue;
        }
        if (c.? == .small_int and c.?.small_int == 1) {
            // Cycle detected. Build the cycle slice from path.
            const out = try List.init(interp.allocator);
            var i: usize = 0;
            while (i < path.items.len) : (i += 1) if (path.items[i].equals(next)) break;
            while (i < path.items.len) : (i += 1) try out.append(interp.allocator, path.items[i]);
            try out.append(interp.allocator, next);
            return out;
        }
        // Black neighbor: skip.
    }
    return null;
}

// ===== get_ready =====

fn getReadyFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len != 1 or args[0] != .instance) {
        try interp.typeError("get_ready() expects self");
        return error.TypeError;
    }
    const inst = args[0].instance;
    if (!prepared(inst)) {
        try raiseValue(interp, "prepare() must be called first");
        return error.PyException;
    }
    const ready = inst.dict.getStr("_ready").?.list;
    const state = inst.dict.getStr("_state").?.dict;
    const emitted = inst.dict.getStr("_emitted").?.dict;
    const out = try List.init(a);
    for (ready.items.items) |node| {
        try out.append(a, node);
        try state.setKey(a, node, Value{ .small_int = STATE_EMITTED });
        try emitted.setKey(a, node, Value{ .boolean = true });
    }
    ready.items.clearRetainingCapacity();
    // Result is conventionally a tuple; CPython returns one. Either
    // works for the fixture (only sorted/list/iter) -- return tuple
    // to mirror CPython.
    const t = try Tuple.init(a, out.items.items.len);
    @memcpy(t.items, out.items.items);
    return Value{ .tuple = t };
}

// ===== done =====

fn doneFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) {
        try interp.typeError("done() expects self");
        return error.TypeError;
    }
    const inst = args[0].instance;
    if (!prepared(inst)) {
        try raiseValue(interp, "prepare() must be called first");
        return error.PyException;
    }
    const succs_d = inst.dict.getStr("_succs").?.dict;
    const pred_count = inst.dict.getStr("_pred_count").?.dict;
    const state = inst.dict.getStr("_state").?.dict;
    const emitted = inst.dict.getStr("_emitted").?.dict;
    const ready = inst.dict.getStr("_ready").?.list;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const node = args[i];
        if (emitted.getKey(node) == null) {
            try raiseValue(interp, "node was not passed out (still not ready) or was already marked done");
            return error.PyException;
        }
        _ = emitted.removeKeyWrap(node);
        try state.setKey(a, node, Value{ .small_int = STATE_DONE });
        const succs = succs_d.getKey(node).?.list;
        for (succs.items.items) |s| {
            const cur = pred_count.getKey(s).?.small_int;
            const next_count = cur - 1;
            try pred_count.setKey(a, s, Value{ .small_int = next_count });
            if (next_count == 0) {
                try ready.append(a, s);
                try state.setKey(a, s, Value{ .small_int = STATE_READY });
            }
        }
        const cur_done = inst.dict.getStr("_n_done").?.small_int;
        try inst.dict.setStr(a, "_n_done", Value{ .small_int = cur_done + 1 });
    }
    return Value.none;
}

// ===== is_active =====

fn isActiveFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1 or args[0] != .instance) {
        try interp.typeError("is_active() expects self");
        return error.TypeError;
    }
    const inst = args[0].instance;
    if (!prepared(inst)) {
        try raiseValue(interp, "prepare() must be called first");
        return error.PyException;
    }
    const ready = inst.dict.getStr("_ready").?.list;
    const emitted = inst.dict.getStr("_emitted").?.dict;
    return Value{ .boolean = ready.items.items.len > 0 or emitted.pairs.items.len > 0 };
}

// ===== static_order =====

fn staticOrderFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len != 1 or args[0] != .instance) {
        try interp.typeError("static_order() expects self");
        return error.TypeError;
    }
    const inst = args[0].instance;
    _ = try prepareFn(p, args);
    const out = try List.init(a);
    while (true) {
        const r = try getReadyFn(p, &.{Value{ .instance = inst }});
        if (r != .tuple) return error.TypeError;
        if (r.tuple.items.len == 0) break;
        for (r.tuple.items) |x| try out.append(a, x);
        // done() takes (self, *nodes); build the arg buffer.
        var buf = try a.alloc(Value, r.tuple.items.len + 1);
        defer a.free(buf);
        buf[0] = Value{ .instance = inst };
        for (r.tuple.items, 0..) |x, i| buf[i + 1] = x;
        _ = try doneFn(p, buf);
    }
    return Value{ .list = out };
}
