//! Pinhole `pprint`. Covers pformat / pprint / pp / saferepr /
//! isreadable / isrecursive plus a PrettyPrinter class with
//! pformat / pprint / format / isreadable / isrecursive methods.
//! Honors width, indent, depth, compact, sort_dicts.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;

const Options = struct {
    width: usize = 80,
    indent: usize = 1,
    depth: ?usize = null,
    compact: bool = false,
    sort_dicts: bool = true,
};

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    if (interp.pprint_pp_class == null) {
        const d = try Dict.init(a);
        try regI(a, d, "__init__", ppInitKw);
        try regC(a, d, "pformat", ppPformatFn);
        try regC(a, d, "pprint", ppPprintFn);
        try regC(a, d, "format", ppFormatFn);
        try regC(a, d, "isreadable", ppIsreadableFn);
        try regC(a, d, "isrecursive", ppIsrecursiveFn);
        interp.pprint_pp_class = try Class.init(a, "PrettyPrinter", &.{}, d);
    }
    const m = try Module.init(a, "pprint");
    try regKw(interp, m, "pformat", pformatKw);
    try regKw(interp, m, "pprint", pprintKw);
    try regKw(interp, m, "pp", ppKw);
    try regC(a, m.attrs, "saferepr", saferepFn);
    try regC(a, m.attrs, "isreadable", isreadableFn);
    try regC(a, m.attrs, "isrecursive", isrecursiveFn);
    try m.attrs.setStr(a, "PrettyPrinter", Value{ .class = interp.pprint_pp_class.? });
    return m;
}

fn regC(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regI(a: std.mem.Allocator, d: *Dict, name: []const u8, comptime kw_func: BuiltinKwFnPtr) !void {
    const Wrap = struct {
        fn call(p: *anyopaque, args: []const Value) anyerror!Value {
            return kw_func(p, args, &.{}, &.{});
        }
    };
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = Wrap.call, .kw_func = kw_func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, comptime kw_func: BuiltinKwFnPtr) !void {
    const Wrap = struct {
        fn call(p: *anyopaque, args: []const Value) anyerror!Value {
            return kw_func(p, args, &.{}, &.{});
        }
    };
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = Wrap.call, .kw_func = kw_func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn lessKey(_: void, a: Dict.Pair, b: Dict.Pair) bool {
    if (a.key == .str and b.key == .str) {
        return std.mem.order(u8, a.key.str.bytes, b.key.str.bytes) == .lt;
    }
    if (a.key == .small_int and b.key == .small_int) return a.key.small_int < b.key.small_int;
    return false;
}

fn isContainer(v: Value) bool {
    return switch (v) {
        .list, .dict, .tuple, .set => true,
        else => false,
    };
}

fn isEmptyContainer(v: Value) bool {
    return switch (v) {
        .list => |l| l.items.items.len == 0,
        .dict => |d| d.pairs.items.len == 0,
        .tuple => |t| t.items.len == 0,
        .set => |s| s.items.items.len == 0,
        else => true,
    };
}

fn writeSingle(w: *std.Io.Writer, v: Value, scratch: std.mem.Allocator, opts: Options, level: usize) anyerror!void {
    switch (v) {
        .dict => |d| {
            try w.writeAll("{");
            if (opts.depth) |maxd| if (level >= maxd) {
                try w.writeAll("...}");
                return;
            };
            const sorted = try scratch.dupe(Dict.Pair, d.pairs.items);
            defer scratch.free(sorted);
            if (opts.sort_dicts) std.sort.block(Dict.Pair, sorted, {}, lessKey);
            for (sorted, 0..) |pair, i| {
                if (i > 0) try w.writeAll(", ");
                try writeSingle(w, pair.key, scratch, opts, level);
                try w.writeAll(": ");
                try writeSingle(w, pair.value, scratch, opts, level + 1);
            }
            try w.writeAll("}");
        },
        .list => |l| {
            try w.writeAll("[");
            if (opts.depth) |maxd| if (level >= maxd) {
                try w.writeAll("...]");
                return;
            };
            for (l.items.items, 0..) |it, i| {
                if (i > 0) try w.writeAll(", ");
                try writeSingle(w, it, scratch, opts, level + 1);
            }
            try w.writeAll("]");
        },
        .tuple => |t| {
            try w.writeAll("(");
            if (opts.depth) |maxd| if (level >= maxd) {
                try w.writeAll("...)");
                return;
            };
            for (t.items, 0..) |it, i| {
                if (i > 0) try w.writeAll(", ");
                try writeSingle(w, it, scratch, opts, level + 1);
            }
            if (t.items.len == 1) try w.writeAll(",");
            try w.writeAll(")");
        },
        .set => |s| {
            if (s.items.items.len == 0) {
                try w.writeAll(if (s.frozen) "frozenset()" else "set()");
                return;
            }
            try w.writeAll(if (s.frozen) "frozenset({" else "{");
            for (s.items.items, 0..) |it, i| {
                if (i > 0) try w.writeAll(", ");
                try writeSingle(w, it, scratch, opts, level + 1);
            }
            try w.writeAll(if (s.frozen) "})" else "}");
        },
        else => try v.writeRepr(w),
    }
}

fn singleLineLen(scratch: std.mem.Allocator, v: Value, opts: Options, level: usize) !usize {
    var w = std.Io.Writer.Allocating.init(scratch);
    defer w.deinit();
    try writeSingle(&w.writer, v, scratch, opts, level);
    return w.written().len;
}

/// Recursive multi-line formatter. `column` is the cursor's current
/// column on the line where this rendering starts (so we can decide
/// whether the value still fits inline).
fn formatValue(
    out: *std.Io.Writer.Allocating,
    scratch: std.mem.Allocator,
    v: Value,
    column: usize,
    opts: Options,
    level: usize,
) anyerror!void {
    // Atomic / depth-limited / empty containers print inline regardless
    // of width.
    if (!isContainer(v) or isEmptyContainer(v)) {
        try writeSingle(&out.writer, v, scratch, opts, level);
        return;
    }
    if (opts.depth) |maxd| if (level >= maxd) {
        try writeSingle(&out.writer, v, scratch, opts, level);
        return;
    };
    const inline_len = try singleLineLen(scratch, v, opts, level);
    if (column + inline_len <= opts.width) {
        try writeSingle(&out.writer, v, scratch, opts, level);
        return;
    }

    switch (v) {
        .list => |l| try formatList(out, scratch, l.items.items, "[", "]", column, opts, level),
        .tuple => |t| try formatList(out, scratch, t.items, "(", ")", column, opts, level),
        .dict => |d| try formatDict(out, scratch, d.pairs.items, column, opts, level),
        .set => |s| {
            const open = if (s.frozen) "frozenset({" else "{";
            const close = if (s.frozen) "})" else "}";
            try formatList(out, scratch, s.items.items, open, close, column, opts, level);
        },
        else => unreachable,
    }
}

fn formatList(
    out: *std.Io.Writer.Allocating,
    scratch: std.mem.Allocator,
    items: []const Value,
    open: []const u8,
    close: []const u8,
    column: usize,
    opts: Options,
    level: usize,
) !void {
    try out.writer.writeAll(open);
    const item_indent = column + opts.indent;
    if (opts.compact) {
        var col = column + open.len;
        var line_start = true;
        for (items, 0..) |it, i| {
            const il = try singleLineLen(scratch, it, opts, level + 1);
            const sep_len: usize = if (i == 0) 0 else 2; // ", "
            if (!line_start and col + sep_len + il > opts.width) {
                try out.writer.writeAll(",\n");
                try writePad(&out.writer, item_indent);
                col = item_indent;
                line_start = true;
            } else if (i > 0) {
                try out.writer.writeAll(", ");
                col += 2;
            }
            try writeSingle(&out.writer, it, scratch, opts, level + 1);
            col += il;
            line_start = false;
        }
    } else {
        const first_pad: usize = if (opts.indent > open.len) opts.indent - open.len else 0;
        const first_col = column + open.len + first_pad;
        for (items, 0..) |it, i| {
            if (i > 0) {
                try out.writer.writeAll(",\n");
                try writePad(&out.writer, item_indent);
                try formatValue(out, scratch, it, item_indent, opts, level + 1);
            } else {
                if (first_pad > 0) try writePad(&out.writer, first_pad);
                try formatValue(out, scratch, it, first_col, opts, level + 1);
            }
        }
    }
    if (items.len == 1 and std.mem.eql(u8, open, "(")) try out.writer.writeAll(",");
    try out.writer.writeAll(close);
}

fn formatDict(
    out: *std.Io.Writer.Allocating,
    scratch: std.mem.Allocator,
    pairs: []const Dict.Pair,
    column: usize,
    opts: Options,
    level: usize,
) !void {
    try out.writer.writeAll("{");
    const sorted = try scratch.dupe(Dict.Pair, pairs);
    defer scratch.free(sorted);
    if (opts.sort_dicts) std.sort.block(Dict.Pair, sorted, {}, lessKey);
    const item_indent = column + opts.indent;
    for (sorted, 0..) |pair, i| {
        if (i > 0) {
            try out.writer.writeAll(",\n");
            try writePad(&out.writer, item_indent);
        }
        try writeSingle(&out.writer, pair.key, scratch, opts, level);
        try out.writer.writeAll(": ");
        // Column for the value: indent + key repr + 2 (": ").
        var key_w = std.Io.Writer.Allocating.init(scratch);
        defer key_w.deinit();
        try writeSingle(&key_w.writer, pair.key, scratch, opts, level);
        const val_col = (if (i == 0) column + 1 else item_indent) + key_w.written().len + 2;
        try formatValue(out, scratch, pair.value, val_col, opts, level + 1);
    }
    try out.writer.writeAll("}");
}

fn writePad(w: *std.Io.Writer, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeAll(" ");
}

fn extractOpts(kw_names: []const Value, kw_values: []const Value, base: Options) Options {
    var o = base;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const n = kn.str.bytes;
        if (std.mem.eql(u8, n, "width") and kv == .small_int) o.width = @intCast(kv.small_int);
        if (std.mem.eql(u8, n, "indent") and kv == .small_int) o.indent = @intCast(kv.small_int);
        if (std.mem.eql(u8, n, "depth") and kv == .small_int) o.depth = @intCast(kv.small_int);
        if (std.mem.eql(u8, n, "depth") and kv == .none) o.depth = null;
        if (std.mem.eql(u8, n, "compact") and kv == .boolean) o.compact = kv.boolean;
        if (std.mem.eql(u8, n, "sort_dicts") and kv == .boolean) o.sort_dicts = kv.boolean;
    }
    return o;
}

fn pformatStr(interp: *Interp, v: Value, opts: Options) ![]u8 {
    var out = std.Io.Writer.Allocating.init(interp.allocator);
    errdefer out.deinit();
    try formatValue(&out, interp.allocator, v, 0, opts, 0);
    return interp.allocator.dupe(u8, out.written());
}

fn pformatKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const opts = extractOpts(kw_names, kw_values, .{});
    const out = try pformatStr(interp, args[0], opts);
    defer interp.allocator.free(out);
    return Value{ .str = try Str.init(interp.allocator, out) };
}

fn pprintKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const opts = extractOpts(kw_names, kw_values, .{});
    const out = try pformatStr(interp, args[0], opts);
    defer interp.allocator.free(out);
    try interp.stdout.writeAll(out);
    try interp.stdout.writeAll("\n");
    return Value.none;
}

fn ppKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    const opts = extractOpts(kw_names, kw_values, .{ .sort_dicts = false });
    const out = try pformatStr(interp, args[0], opts);
    defer interp.allocator.free(out);
    try interp.stdout.writeAll(out);
    try interp.stdout.writeAll("\n");
    return Value.none;
}

// ===== isrecursive / isreadable =====

fn hasRecursion(v: Value, seen: *std.AutoHashMapUnmanaged(usize, void), a: std.mem.Allocator) anyerror!bool {
    const id: usize = switch (v) {
        .list => |l| @intFromPtr(l),
        .dict => |d| @intFromPtr(d),
        .tuple => |t| @intFromPtr(t),
        .set => |s| @intFromPtr(s),
        else => 0,
    };
    if (id != 0) {
        if (seen.contains(id)) return true;
        try seen.put(a, id, {});
    }
    defer if (id != 0) {
        _ = seen.remove(id);
    };
    switch (v) {
        .list => |l| for (l.items.items) |it| if (try hasRecursion(it, seen, a)) return true,
        .tuple => |t| for (t.items) |it| if (try hasRecursion(it, seen, a)) return true,
        .dict => |d| for (d.pairs.items) |pair| {
            if (try hasRecursion(pair.value, seen, a)) return true;
        },
        .set => |s| for (s.items.items) |it| if (try hasRecursion(it, seen, a)) return true,
        else => {},
    }
    return false;
}

fn isrecursiveFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen.deinit(interp.allocator);
    return Value{ .boolean = try hasRecursion(args[0], &seen, interp.allocator) };
}

fn isreadableFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    if (try isReadableValue(interp.allocator, args[0])) return Value{ .boolean = true };
    return Value{ .boolean = false };
}

fn isReadableValue(a: std.mem.Allocator, v: Value) !bool {
    var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen.deinit(a);
    return readableInner(a, v, &seen);
}

fn readableInner(a: std.mem.Allocator, v: Value, seen: *std.AutoHashMapUnmanaged(usize, void)) anyerror!bool {
    switch (v) {
        .none, .boolean, .small_int, .big_int, .float, .str, .bytes, .complex_num => return true,
        .list, .tuple, .dict, .set => {
            const id: usize = switch (v) {
                .list => |l| @intFromPtr(l),
                .tuple => |t| @intFromPtr(t),
                .dict => |d| @intFromPtr(d),
                .set => |s| @intFromPtr(s),
                else => 0,
            };
            if (seen.contains(id)) return false;
            try seen.put(a, id, {});
            defer _ = seen.remove(id);
            switch (v) {
                .list => |l| for (l.items.items) |it| if (!try readableInner(a, it, seen)) return false,
                .tuple => |t| for (t.items) |it| if (!try readableInner(a, it, seen)) return false,
                .dict => |d| for (d.pairs.items) |p| {
                    if (!try readableInner(a, p.key, seen)) return false;
                    if (!try readableInner(a, p.value, seen)) return false;
                },
                .set => |s| for (s.items.items) |it| if (!try readableInner(a, it, seen)) return false,
                else => {},
            }
            return true;
        },
        else => return false,
    }
}

// ===== saferepr =====

fn saferepFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return error.TypeError;
    var w = std.Io.Writer.Allocating.init(interp.allocator);
    defer w.deinit();
    var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen.deinit(interp.allocator);
    try saferepWrite(&w.writer, args[0], &seen, interp.allocator);
    return Value{ .str = try Str.init(interp.allocator, w.written()) };
}

fn saferepWrite(w: *std.Io.Writer, v: Value, seen: *std.AutoHashMapUnmanaged(usize, void), a: std.mem.Allocator) anyerror!void {
    const id: usize = switch (v) {
        .list => |l| @intFromPtr(l),
        .dict => |d| @intFromPtr(d),
        .tuple => |t| @intFromPtr(t),
        .set => |s| @intFromPtr(s),
        else => 0,
    };
    if (id != 0 and seen.contains(id)) {
        const tname = switch (v) {
            .list => "list",
            .dict => "dict",
            .tuple => "tuple",
            .set => |s| if (s.frozen) "frozenset" else "set",
            else => "object",
        };
        try w.print("<Recursion on {s} with id={d}>", .{ tname, id });
        return;
    }
    if (id != 0) try seen.put(a, id, {});
    defer if (id != 0) {
        _ = seen.remove(id);
    };
    switch (v) {
        .list => |l| {
            try w.writeAll("[");
            for (l.items.items, 0..) |it, i| {
                if (i > 0) try w.writeAll(", ");
                try saferepWrite(w, it, seen, a);
            }
            try w.writeAll("]");
        },
        .tuple => |t| {
            try w.writeAll("(");
            for (t.items, 0..) |it, i| {
                if (i > 0) try w.writeAll(", ");
                try saferepWrite(w, it, seen, a);
            }
            if (t.items.len == 1) try w.writeAll(",");
            try w.writeAll(")");
        },
        .dict => |d| {
            try w.writeAll("{");
            for (d.pairs.items, 0..) |p, i| {
                if (i > 0) try w.writeAll(", ");
                try saferepWrite(w, p.key, seen, a);
                try w.writeAll(": ");
                try saferepWrite(w, p.value, seen, a);
            }
            try w.writeAll("}");
        },
        .set => |s| {
            if (s.items.items.len == 0) {
                try w.writeAll(if (s.frozen) "frozenset()" else "set()");
                return;
            }
            try w.writeAll(if (s.frozen) "frozenset({" else "{");
            for (s.items.items, 0..) |it, i| {
                if (i > 0) try w.writeAll(", ");
                try saferepWrite(w, it, seen, a);
            }
            try w.writeAll(if (s.frozen) "})" else "}");
        },
        else => try v.writeRepr(w),
    }
}

// ===== PrettyPrinter class =====

fn ppOpts(self: *Instance) Options {
    var o: Options = .{};
    if (self.dict.getStr("_indent")) |v| if (v == .small_int) {
        o.indent = @intCast(v.small_int);
    };
    if (self.dict.getStr("_width")) |v| if (v == .small_int) {
        o.width = @intCast(v.small_int);
    };
    if (self.dict.getStr("_depth")) |v| {
        if (v == .small_int) o.depth = @intCast(v.small_int);
        if (v == .none) o.depth = null;
    }
    if (self.dict.getStr("_compact")) |v| if (v == .boolean) {
        o.compact = v.boolean;
    };
    if (self.dict.getStr("_sort_dicts")) |v| if (v == .boolean) {
        o.sort_dicts = v.boolean;
    };
    return o;
}

fn ppInitKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const a = interp.allocator;
    const inst = args[0].instance;
    try inst.dict.setStr(a, "_indent", Value{ .small_int = 1 });
    try inst.dict.setStr(a, "_width", Value{ .small_int = 80 });
    try inst.dict.setStr(a, "_depth", Value.none);
    try inst.dict.setStr(a, "_compact", Value{ .boolean = false });
    try inst.dict.setStr(a, "_sort_dicts", Value{ .boolean = true });
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const n = kn.str.bytes;
        if (std.mem.eql(u8, n, "indent")) try inst.dict.setStr(a, "_indent", kv);
        if (std.mem.eql(u8, n, "width")) try inst.dict.setStr(a, "_width", kv);
        if (std.mem.eql(u8, n, "depth")) try inst.dict.setStr(a, "_depth", kv);
        if (std.mem.eql(u8, n, "compact")) try inst.dict.setStr(a, "_compact", kv);
        if (std.mem.eql(u8, n, "sort_dicts")) try inst.dict.setStr(a, "_sort_dicts", kv);
    }
    return Value.none;
}

fn ppPformatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const opts = ppOpts(args[0].instance);
    const out = try pformatStr(interp, args[1], opts);
    defer interp.allocator.free(out);
    return Value{ .str = try Str.init(interp.allocator, out) };
}

fn ppPprintFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const opts = ppOpts(args[0].instance);
    const out = try pformatStr(interp, args[1], opts);
    defer interp.allocator.free(out);
    try interp.stdout.writeAll(out);
    try interp.stdout.writeAll("\n");
    return Value.none;
}

fn ppFormatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 5 or args[0] != .instance) return error.TypeError;
    const a = interp.allocator;
    var w = std.Io.Writer.Allocating.init(a);
    defer w.deinit();
    const opts: Options = .{};
    try writeSingle(&w.writer, args[1], a, opts, 0);
    const t = try Tuple.init(a, 3);
    t.items[0] = Value{ .str = try Str.init(a, w.written()) };
    t.items[1] = Value{ .boolean = try isReadableValue(a, args[1]) };
    var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen.deinit(a);
    t.items[2] = Value{ .boolean = try hasRecursion(args[1], &seen, a) };
    return Value{ .tuple = t };
}

fn ppIsreadableFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    return Value{ .boolean = try isReadableValue(interp.allocator, args[1]) };
}

fn ppIsrecursiveFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen.deinit(interp.allocator);
    return Value{ .boolean = try hasRecursion(args[1], &seen, interp.allocator) };
}
