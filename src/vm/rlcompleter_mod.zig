//! Pinhole `rlcompleter`: a Completer class with `complete(text, state)`
//! that walks builtins, the optional namespace, and Python keywords
//! (with a small dotted-attribute path).

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const List = @import("../object/list.zig").List;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

const keywords = [_][]const u8{
    "False",   "None",     "True",   "and",     "as",      "assert", "async",
    "await",   "break",    "class",  "continue", "def",    "del",    "elif",
    "else",    "except",   "finally","for",     "from",    "global", "if",
    "import",  "in",       "is",     "lambda",  "nonlocal","not",    "or",
    "pass",    "raise",    "return", "try",     "while",   "with",   "yield",
    "match",   "case",     "type",
};

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "rlcompleter");
    try ensureClass(interp);
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = "Completer", .func = completerCtorFn };
    try m.attrs.setStr(a, "Completer", Value{ .builtin_fn = f });
    return m;
}

fn ensureClass(interp: *Interp) !void {
    if (interp.rlcompleter_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "complete", completeFn);
    interp.rlcompleter_class = try Class.init(a, "Completer", &.{}, d);
}

fn completerCtorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    try ensureClass(interp);
    const inst = try Instance.init(a, interp.rlcompleter_class.?);
    if (args.len >= 1 and args[0] != .none) {
        if (args[0] != .dict) {
            try interp.raisePy("TypeError", "namespace must be a dictionary");
            return error.PyException;
        }
        try inst.dict.setStr(a, "__namespace__", args[0]);
    }
    return Value{ .instance = inst };
}

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn isCallable(v: Value) bool {
    return switch (v) {
        .builtin_fn, .function, .bound_method, .class, .partial, .cached_fn => true,
        else => false,
    };
}

fn collectFromDict(a: std.mem.Allocator, list: *std.ArrayList([]const u8), seen: *std.StringHashMap(void), d: *const Dict, prefix: []const u8) !void {
    for (d.pairs.items) |pair| {
        if (pair.key != .str) continue;
        const name = pair.key.str.bytes;
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        if (seen.contains(name)) continue;
        try seen.put(name, {});
        var word: []const u8 = undefined;
        if (isCallable(pair.value)) {
            word = try std.fmt.allocPrint(a, "{s}(", .{name});
        } else {
            word = try a.dupe(u8, name);
        }
        try list.append(a, word);
    }
}

fn dictOf(v: Value) ?*Dict {
    return switch (v) {
        .module => |m| m.attrs,
        .class => |c| c.dict,
        .instance => |i| i.dict,
        .dict => |d| d,
        else => null,
    };
}

fn buildMatches(interp: *Interp, text: []const u8, ns: ?*Dict) ![][]const u8 {
    const a = interp.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| a.free(s);
        list.deinit(a);
    }

    if (std.mem.indexOfScalar(u8, text, '.')) |dot_idx| {
        const expr = text[0..dot_idx];
        const attr = text[dot_idx + 1 ..];
        var obj: ?Value = null;
        if (ns) |n| if (n.getStr(expr)) |v| {
            obj = v;
        };
        if (obj == null) if (interp.builtins.getStr(expr)) |v| {
            obj = v;
        };
        if (obj) |o| if (dictOf(o)) |d| {
            for (d.pairs.items) |pair| {
                if (pair.key != .str) continue;
                const name = pair.key.str.bytes;
                if (!std.mem.startsWith(u8, name, attr)) continue;
                const word = try std.fmt.allocPrint(a, "{s}.{s}", .{ expr, name });
                try list.append(a, word);
            }
        };
        return try list.toOwnedSlice(a);
    }

    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    try seen.put("__builtins__", {});

    for (keywords) |kw| {
        if (!std.mem.startsWith(u8, kw, text)) continue;
        if (seen.contains(kw)) continue;
        try seen.put(kw, {});
        const word = try std.fmt.allocPrint(a, "{s} ", .{kw});
        try list.append(a, word);
    }

    if (ns) |n| try collectFromDict(a, &list, &seen, n, text);
    try collectFromDict(a, &list, &seen, interp.builtins, text);

    return try list.toOwnedSlice(a);
}

fn completeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3 or args[0] != .instance or args[1] != .str) {
        try interp.raisePy("TypeError", "complete() requires text and state");
        return error.PyException;
    }
    const self = args[0].instance;
    const text = args[1].str.bytes;
    const state: i64 = switch (args[2]) {
        .small_int => |n| n,
        .boolean => |b| @intFromBool(b),
        else => {
            try interp.raisePy("TypeError", "complete() state must be int");
            return error.PyException;
        },
    };

    if (state == 0) {
        const ns: ?*Dict = if (self.dict.getStr("__namespace__")) |v|
            switch (v) {
                .dict => |d| d,
                else => null,
            }
        else
            null;
        if (self.dict.getStr("__matches__")) |old| if (old == .list) {
            for (old.list.items.items) |it| if (it == .str) a.free(it.str.bytes);
            old.list.items.deinit(a);
        };
        const matches = try buildMatches(interp, text, ns);
        defer a.free(matches);
        const lst = try List.init(a);
        for (matches) |m| {
            const s = try Str.init(a, m);
            try lst.items.append(a, Value{ .str = s });
            a.free(m);
        }
        try self.dict.setStr(a, "__matches__", Value{ .list = lst });
    }

    const cached = self.dict.getStr("__matches__") orelse return Value.none;
    if (cached != .list) return Value.none;
    if (state < 0 or state >= @as(i64, @intCast(cached.list.items.items.len))) return Value.none;
    return cached.list.items.items[@intCast(state)];
}
