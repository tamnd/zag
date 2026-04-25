//! Pinhole `shlex`: quote / join / split. POSIX rules — only the
//! corners the fixture probes.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "shlex");
    try reg(interp, m, "quote", quoteFn);
    try reg(interp, m, "join", joinFn);
    try reg(interp, m, "split", splitFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn safeChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '@' or c == '%' or c == '+' or
        c == '=' or c == ':' or c == ',' or c == '.' or c == '/' or c == '-' or c == '_';
}

fn quoteString(a: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len == 0) return try a.dupe(u8, "''");
    var safe = true;
    for (s) |c| if (!safeChar(c)) {
        safe = false;
        break;
    };
    if (safe) return try a.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.append(a, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(a, "'\"'\"'");
        } else {
            try out.append(a, c);
        }
    }
    try out.append(a, '\'');
    return out.toOwnedSlice(a);
}

fn quoteFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const out = try quoteString(a, args[0].str.bytes);
    const s = try Str.init(a, out);
    a.free(out);
    return Value{ .str = s };
}

fn joinFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const items: []const Value = switch (args[0]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for (items, 0..) |v, i| {
        if (v != .str) return error.TypeError;
        if (i > 0) try out.append(a, ' ');
        const q = try quoteString(a, v.str.bytes);
        defer a.free(q);
        try out.appendSlice(a, q);
    }
    const s = try Str.init(a, out.items);
    return Value{ .str = s };
}

fn splitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const src = args[0].str.bytes;
    const list = try List.init(a);
    var i: usize = 0;
    while (i < src.len) {
        while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\n')) i += 1;
        if (i >= src.len) break;
        var token: std.ArrayList(u8) = .empty;
        defer token.deinit(a);
        while (i < src.len and src[i] != ' ' and src[i] != '\t' and src[i] != '\n') {
            const c = src[i];
            if (c == '\'') {
                i += 1;
                while (i < src.len and src[i] != '\'') : (i += 1) try token.append(a, src[i]);
                if (i < src.len) i += 1;
            } else if (c == '"') {
                i += 1;
                while (i < src.len and src[i] != '"') {
                    if (src[i] == '\\' and i + 1 < src.len) {
                        i += 1;
                        try token.append(a, src[i]);
                        i += 1;
                    } else {
                        try token.append(a, src[i]);
                        i += 1;
                    }
                }
                if (i < src.len) i += 1;
            } else if (c == '\\' and i + 1 < src.len) {
                i += 1;
                try token.append(a, src[i]);
                i += 1;
            } else {
                try token.append(a, c);
                i += 1;
            }
        }
        const s = try Str.init(a, token.items);
        try list.append(a, Value{ .str = s });
    }
    return Value{ .list = list };
}
