//! Pinhole `glob`: escape/translate plus the actual filesystem
//! walker used by glob/iglob. We support `*`, `?`, character
//! classes, recursive `**`, hidden-file filtering, root_dir, and
//! trailing-slash directory-only mode.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const List = @import("../object/list.zig").List;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "glob");

    try reg(interp, m, "escape", escapeFn);
    try regKw(interp, m, "translate", translateFn, translateKwFn);
    try regKw(interp, m, "glob", globFn, globKwFn);
    try regKw(interp, m, "iglob", iglobFn, iglobKwFn);

    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

// ===== escape =====

fn escapeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const a = interp.allocator;
    const s = args[0].str.bytes;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (s) |c| {
        if (c == '*' or c == '?' or c == '[') {
            try out.append(a, '[');
            try out.append(a, c);
            try out.append(a, ']');
        } else {
            try out.append(a, c);
        }
    }
    return Value{ .str = try Str.fromOwnedSlice(a, try out.toOwnedSlice(a)) };
}

// ===== translate =====

fn translateFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return translateCommon(p, args, &.{}, &.{});
}

fn translateKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return translateCommon(p, args, kw_names, kw_values);
}

fn translateCommon(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const a = interp.allocator;
    const pat = args[0].str.bytes;

    var recursive = false;
    var include_hidden = false;
    for (kw_names, kw_values) |k, v| {
        if (k != .str) continue;
        const n = k.str.bytes;
        if (std.mem.eql(u8, n, "recursive") and v == .boolean) recursive = v.boolean;
        if (std.mem.eql(u8, n, "include_hidden") and v == .boolean) include_hidden = v.boolean;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    var i: usize = 0;
    var at_segment_start = true;

    while (i < pat.len) {
        const c = pat[i];
        const apply_hidden = at_segment_start and !include_hidden;

        if (c == '*') {
            if (recursive and i + 1 < pat.len and pat[i + 1] == '*') {
                if (i + 2 < pat.len and pat[i + 2] == '/') {
                    try out.appendSlice(a, "(?:.*/)?");
                    i += 3;
                } else {
                    try out.appendSlice(a, ".*");
                    i += 2;
                }
                at_segment_start = true;
                continue;
            }
            if (apply_hidden) {
                try out.appendSlice(a, "[^./][^/]*");
            } else {
                try out.appendSlice(a, "[^/]*");
            }
            i += 1;
            at_segment_start = false;
            continue;
        }
        if (c == '?') {
            if (apply_hidden) {
                try out.appendSlice(a, "[^./]");
            } else {
                try out.appendSlice(a, "[^/]");
            }
            i += 1;
            at_segment_start = false;
            continue;
        }
        if (c == '[') {
            try out.append(a, '[');
            var j = i + 1;
            if (j < pat.len and pat[j] == '!') {
                try out.append(a, '^');
                j += 1;
            }
            while (j < pat.len and pat[j] != ']') : (j += 1) {
                try out.append(a, pat[j]);
            }
            try out.append(a, ']');
            if (j < pat.len) j += 1;
            i = j;
            at_segment_start = false;
            continue;
        }
        if (c == '/') {
            try out.append(a, '/');
            i += 1;
            at_segment_start = true;
            continue;
        }
        if (c == '.' or c == '\\' or c == '+' or c == '(' or c == ')' or
            c == '{' or c == '}' or c == '|' or c == '^' or c == '$')
        {
            try out.append(a, '\\');
        }
        try out.append(a, c);
        i += 1;
        at_segment_start = false;
    }

    return Value{ .str = try Str.fromOwnedSlice(a, try out.toOwnedSlice(a)) };
}

// ===== glob / iglob =====

const GlobOpts = struct {
    recursive: bool = false,
    include_hidden: bool = false,
    root_dir: ?[]const u8 = null,
};

fn parseGlobOpts(kw_names: []const Value, kw_values: []const Value) GlobOpts {
    var opts: GlobOpts = .{};
    for (kw_names, kw_values) |k, v| {
        if (k != .str) continue;
        const n = k.str.bytes;
        if (std.mem.eql(u8, n, "recursive") and v == .boolean) opts.recursive = v.boolean;
        if (std.mem.eql(u8, n, "include_hidden") and v == .boolean) opts.include_hidden = v.boolean;
        if (std.mem.eql(u8, n, "root_dir") and v == .str) opts.root_dir = v.str.bytes;
    }
    return opts;
}

fn globFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return globCommon(p, args, &.{}, &.{});
}

fn globKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return globCommon(p, args, kw_names, kw_values);
}

fn iglobFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return globCommon(p, args, &.{}, &.{});
}

fn iglobKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    return globCommon(p, args, kw_names, kw_values);
}

fn globCommon(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) !Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const a = interp.allocator;
    const pattern = args[0].str.bytes;
    const opts = parseGlobOpts(kw_names, kw_values);

    const list = try List.init(a);

    var pat = pattern;
    var base_dir: []const u8 = ".";
    var prefix: []const u8 = "";

    if (pat.len > 0 and pat[0] == '/') {
        base_dir = "/";
        prefix = "/";
        pat = pat[1..];
    } else if (opts.root_dir) |rd| {
        base_dir = rd;
    }

    var dir_only = false;
    if (pat.len > 0 and pat[pat.len - 1] == '/') {
        pat = pat[0 .. pat.len - 1];
        dir_only = true;
    }

    if (pat.len == 0) return Value{ .list = list };

    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(a);
    var it = std.mem.splitScalar(u8, pat, '/');
    while (it.next()) |seg| try segs.append(a, seg);

    try walkSegments(interp, base_dir, segs.items, prefix, opts, dir_only, list);
    return Value{ .list = list };
}

fn walkSegments(
    interp: *Interp,
    dir: []const u8,
    segs: []const []const u8,
    prefix: []const u8,
    opts: GlobOpts,
    dir_only: bool,
    out: *List,
) anyerror!void {
    if (segs.len == 0) return;
    const a = interp.allocator;
    const seg = segs[0];
    const rest = segs[1..];

    if (opts.recursive and std.mem.eql(u8, seg, "**")) {
        if (rest.len == 0) {
            // ** alone — emit every reachable item below `dir`.
            try walkAll(interp, dir, prefix, opts, dir_only, out);
            return;
        }
        // ** with rest — try zero dirs (rest from current dir), then
        // each subdir at any depth (** stays in segs).
        try walkSegments(interp, dir, rest, prefix, opts, dir_only, out);
        var d = std.Io.Dir.cwd().openDir(interp.io, dir, .{ .iterate = true }) catch return;
        defer d.close(interp.io);
        var entries: std.ArrayList([]u8) = .empty;
        defer {
            for (entries.items) |e| a.free(e);
            entries.deinit(a);
        }
        var it = d.iterate();
        while (it.next(interp.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (!opts.include_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
            const name_dup = a.dupe(u8, entry.name) catch continue;
            entries.append(a, name_dup) catch {
                a.free(name_dup);
                continue;
            };
        }
        for (entries.items) |entry_name| {
            const new_dir = try joinPath(a, dir, entry_name);
            defer a.free(new_dir);
            const new_prefix = try joinPath(a, prefix, entry_name);
            defer a.free(new_prefix);
            try walkSegments(interp, new_dir, segs, new_prefix, opts, dir_only, out);
        }
        return;
    }

    // Treat ** as * when recursive=False.
    const effective_seg: []const u8 = if (std.mem.eql(u8, seg, "**")) "*" else seg;

    if (hasMagic(effective_seg)) {
        var d = std.Io.Dir.cwd().openDir(interp.io, dir, .{ .iterate = true }) catch return;
        defer d.close(interp.io);
        var entries: std.ArrayList([]u8) = .empty;
        defer {
            for (entries.items) |e| a.free(e);
            entries.deinit(a);
        }
        var kinds: std.ArrayList(std.Io.File.Kind) = .empty;
        defer kinds.deinit(a);
        var it = d.iterate();
        while (it.next(interp.io) catch null) |entry| {
            if (!matchSegment(entry.name, effective_seg, opts.include_hidden)) continue;
            const name_dup = a.dupe(u8, entry.name) catch continue;
            entries.append(a, name_dup) catch {
                a.free(name_dup);
                continue;
            };
            kinds.append(a, entry.kind) catch {};
        }
        for (entries.items, 0..) |entry_name, i| {
            const kind = kinds.items[i];
            const new_prefix = try joinPath(a, prefix, entry_name);
            const new_dir = try joinPath(a, dir, entry_name);
            defer a.free(new_dir);
            if (rest.len == 0) {
                if (dir_only) {
                    if (kind == .directory) {
                        const with_slash = try concat(a, new_prefix, "/");
                        defer a.free(new_prefix);
                        try out.items.append(a, Value{ .str = try Str.fromOwnedSlice(a, with_slash) });
                    } else {
                        a.free(new_prefix);
                    }
                } else {
                    try out.items.append(a, Value{ .str = try Str.fromOwnedSlice(a, new_prefix) });
                }
            } else {
                if (kind == .directory) {
                    try walkSegments(interp, new_dir, rest, new_prefix, opts, dir_only, out);
                }
                a.free(new_prefix);
            }
        }
        return;
    }

    // Literal segment.
    const new_dir = try joinPath(a, dir, seg);
    defer a.free(new_dir);
    const new_prefix = try joinPath(a, prefix, seg);
    if (rest.len == 0) {
        if (dir_only) {
            const ok = isDir(interp, new_dir);
            if (ok) {
                const with_slash = try concat(a, new_prefix, "/");
                defer a.free(new_prefix);
                try out.items.append(a, Value{ .str = try Str.fromOwnedSlice(a, with_slash) });
            } else {
                a.free(new_prefix);
            }
        } else if (pathExists(interp, new_dir)) {
            try out.items.append(a, Value{ .str = try Str.fromOwnedSlice(a, new_prefix) });
        } else {
            a.free(new_prefix);
        }
    } else {
        if (isDir(interp, new_dir)) {
            try walkSegments(interp, new_dir, rest, new_prefix, opts, dir_only, out);
        }
        a.free(new_prefix);
    }
}

fn walkAll(
    interp: *Interp,
    dir: []const u8,
    prefix: []const u8,
    opts: GlobOpts,
    dir_only: bool,
    out: *List,
) anyerror!void {
    const a = interp.allocator;
    var d = std.Io.Dir.cwd().openDir(interp.io, dir, .{ .iterate = true }) catch return;
    defer d.close(interp.io);
    var entries: std.ArrayList([]u8) = .empty;
    defer {
        for (entries.items) |e| a.free(e);
        entries.deinit(a);
    }
    var kinds: std.ArrayList(std.Io.File.Kind) = .empty;
    defer kinds.deinit(a);
    var it = d.iterate();
    while (it.next(interp.io) catch null) |entry| {
        if (!opts.include_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
        const name_dup = a.dupe(u8, entry.name) catch continue;
        entries.append(a, name_dup) catch {
            a.free(name_dup);
            continue;
        };
        kinds.append(a, entry.kind) catch {};
    }
    for (entries.items, 0..) |entry_name, i| {
        const kind = kinds.items[i];
        const new_prefix = try joinPath(a, prefix, entry_name);
        const new_dir = try joinPath(a, dir, entry_name);
        defer a.free(new_dir);
        if (dir_only) {
            if (kind == .directory) {
                const with_slash = try concat(a, new_prefix, "/");
                defer a.free(new_prefix);
                try out.items.append(a, Value{ .str = try Str.fromOwnedSlice(a, with_slash) });
            } else {
                a.free(new_prefix);
            }
        } else {
            try out.items.append(a, Value{ .str = try Str.init(a, new_prefix) });
        }
        if (kind == .directory) {
            try walkAll(interp, new_dir, new_prefix, opts, dir_only, out);
        }
        a.free(new_prefix);
    }
}

// ===== helpers =====

fn hasMagic(s: []const u8) bool {
    for (s) |c| if (c == '*' or c == '?' or c == '[') return true;
    return false;
}

fn matchSegment(name: []const u8, pat: []const u8, include_hidden: bool) bool {
    if (!include_hidden and name.len > 0 and name[0] == '.') {
        if (pat.len == 0 or pat[0] != '.') return false;
    }
    return matchPattern(name, pat);
}

fn matchPattern(s: []const u8, pat: []const u8) bool {
    var si: usize = 0;
    var pi: usize = 0;
    var star_si: ?usize = null;
    var star_pi: usize = 0;
    while (si < s.len) {
        const got_pat_char = pi < pat.len;
        if (got_pat_char) {
            const pc = pat[pi];
            if (pc == '*') {
                star_pi = pi;
                star_si = si;
                pi += 1;
                continue;
            }
            if (pc == '?') {
                pi += 1;
                si += 1;
                continue;
            }
            if (pc == '[') {
                var j = pi + 1;
                var negate = false;
                if (j < pat.len and pat[j] == '!') {
                    negate = true;
                    j += 1;
                }
                const start = j;
                while (j < pat.len and pat[j] != ']') : (j += 1) {}
                if (j < pat.len) {
                    const class = pat[start..j];
                    var matched = false;
                    var k: usize = 0;
                    while (k < class.len) {
                        if (k + 2 < class.len and class[k + 1] == '-') {
                            if (s[si] >= class[k] and s[si] <= class[k + 2]) matched = true;
                            k += 3;
                        } else {
                            if (s[si] == class[k]) matched = true;
                            k += 1;
                        }
                    }
                    if (matched != negate) {
                        pi = j + 1;
                        si += 1;
                        continue;
                    }
                }
            } else if (pc == s[si]) {
                pi += 1;
                si += 1;
                continue;
            }
        }
        if (star_si) |sse| {
            pi = star_pi + 1;
            star_si = sse + 1;
            si = sse + 1;
            continue;
        }
        return false;
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

fn joinPath(a: std.mem.Allocator, parent: []const u8, child: []const u8) ![]u8 {
    if (parent.len == 0) return try a.dupe(u8, child);
    if (child.len == 0) return try a.dupe(u8, parent);
    if (std.mem.eql(u8, parent, "/")) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.append(a, '/');
        try out.appendSlice(a, child);
        return try out.toOwnedSlice(a);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, parent);
    if (parent[parent.len - 1] != '/') try out.append(a, '/');
    try out.appendSlice(a, child);
    return try out.toOwnedSlice(a);
}

fn concat(a: std.mem.Allocator, p1: []const u8, p2: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, p1);
    try out.appendSlice(a, p2);
    return try out.toOwnedSlice(a);
}

fn pathExists(interp: *Interp, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(interp.io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn isDir(interp: *Interp, path: []const u8) bool {
    const s = std.Io.Dir.cwd().statFile(interp.io, path, .{ .follow_symlinks = true }) catch return false;
    return s.kind == .directory;
}
