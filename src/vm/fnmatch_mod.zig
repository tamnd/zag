//! Pinhole `fnmatch`: glob-style matching with *, ?, [..], [!..].

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
    const m = try Module.init(interp.allocator, "fnmatch");
    try reg(interp, m, "fnmatch", fnmatchFn);
    try reg(interp, m, "fnmatchcase", fnmatchcaseFn);
    try reg(interp, m, "filter", filterFn);
    try reg(interp, m, "translate", translateFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

pub fn matchOne(s: []const u8, pat: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    var star_i: ?usize = null;
    var star_j: usize = 0;
    while (i < s.len) {
        if (j < pat.len) {
            const pc = pat[j];
            if (pc == '*') {
                star_i = i;
                star_j = j;
                j += 1;
                continue;
            } else if (pc == '?') {
                i += 1;
                j += 1;
                continue;
            } else if (pc == '[') {
                // Find closing bracket.
                var k: usize = j + 1;
                var negate = false;
                if (k < pat.len and (pat[k] == '!' or pat[k] == '^')) {
                    negate = true;
                    k += 1;
                }
                const class_start = k;
                while (k < pat.len and pat[k] != ']') k += 1;
                if (k >= pat.len) {
                    // unclosed, treat as literal
                    if (pc == s[i]) {
                        i += 1;
                        j += 1;
                        continue;
                    }
                } else {
                    const class = pat[class_start..k];
                    var matched = false;
                    var ci: usize = 0;
                    while (ci < class.len) {
                        if (ci + 2 < class.len and class[ci + 1] == '-') {
                            if (s[i] >= class[ci] and s[i] <= class[ci + 2]) matched = true;
                            ci += 3;
                        } else {
                            if (s[i] == class[ci]) matched = true;
                            ci += 1;
                        }
                    }
                    if (matched != negate) {
                        i += 1;
                        j = k + 1;
                        continue;
                    }
                }
            } else if (pc == s[i]) {
                i += 1;
                j += 1;
                continue;
            }
        }
        if (star_i) |si| {
            star_i = si + 1;
            i = si + 1;
            j = star_j + 1;
        } else {
            return false;
        }
    }
    while (j < pat.len and pat[j] == '*') j += 1;
    return j == pat.len;
}

fn fnmatchcaseFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .str or args[1] != .str) return error.TypeError;
    return Value{ .boolean = matchOne(args[0].str.bytes, args[1].str.bytes) };
}

fn fnmatchFn(p: *anyopaque, args: []const Value) anyerror!Value {
    // POSIX behaviour: case-sensitive on Linux/macOS. We ape that.
    return fnmatchcaseFn(p, args);
}

fn translateFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const pat = args[0].str.bytes;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, "(?s:");
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        const c = pat[i];
        switch (c) {
            '*' => try out.appendSlice(a, ".*"),
            '?' => try out.append(a, '.'),
            '[' => {
                try out.append(a, '[');
                var j = i + 1;
                if (j < pat.len and pat[j] == '!') {
                    try out.append(a, '^');
                    j += 1;
                }
                while (j < pat.len and pat[j] != ']') : (j += 1) try out.append(a, pat[j]);
                try out.append(a, ']');
                i = j;
            },
            else => {
                if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_') {
                    try out.append(a, c);
                } else {
                    try out.append(a, '\\');
                    try out.append(a, c);
                }
            },
        }
    }
    try out.appendSlice(a, ")\\Z");
    const s = try Str.init(a, out.items);
    return Value{ .str = s };
}

fn filterFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const items: []const Value = switch (args[0]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    if (args[1] != .str) return error.TypeError;
    const pat = args[1].str.bytes;
    const out = try List.init(a);
    for (items) |v| {
        if (v != .str) continue;
        if (matchOne(v.str.bytes, pat)) {
            const s = try Str.init(a, v.str.bytes);
            try out.append(a, Value{ .str = s });
        }
    }
    return Value{ .list = out };
}
