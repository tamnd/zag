//! Pinhole `filecmp`: BUFSIZE/DEFAULT_IGNORES, cmp/cmpfiles/clear_cache,
//! and a dircmp class with the attributes & report* methods CPython exposes.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const List = @import("../object/list.zig").List;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "filecmp");

    try m.attrs.setStr(a, "BUFSIZE", Value{ .small_int = 8192 });

    const ignores = try List.init(a);
    const names = [_][]const u8{ "RCS", "CVS", "tags", ".git", ".hg", ".bzr", "_darcs", "__pycache__" };
    for (names) |n| try ignores.items.append(a, Value{ .str = try Str.init(a, n) });
    try m.attrs.setStr(a, "DEFAULT_IGNORES", Value{ .list = ignores });

    try ensureClass(interp);
    try m.attrs.setStr(a, "dircmp", Value{ .class = interp.filecmp_dircmp_class.? });

    try reg(interp, m, "cmp", cmpFn);
    try reg(interp, m, "cmpfiles", cmpfilesFn);
    try reg(interp, m, "clear_cache", clearCacheFn);

    return m;
}

fn ensureClass(interp: *Interp) !void {
    if (interp.filecmp_dircmp_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodRegKw(a, d, "__init__", initFn, initKwFn);
    try methodReg(a, d, "report", reportFn);
    try methodReg(a, d, "report_partial_closure", reportPartialFn);
    try methodReg(a, d, "report_full_closure", reportFullFn);
    interp.filecmp_dircmp_class = try Class.init(a, "dircmp", &.{}, d);
}

fn methodReg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn methodRegKw(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

// ===== cmp / cmpfiles / clear_cache =====

fn cmpFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str or args[1] != .str) {
        try interp.typeError("filecmp.cmp(f1, f2[, shallow])");
        return error.TypeError;
    }
    const shallow = args.len < 3 or args[2] == .none or (args[2] == .boolean and args[2].boolean) or (args[2] == .small_int and args[2].small_int != 0);
    return Value{ .boolean = try filesEqual(interp, args[0].str.bytes, args[1].str.bytes, shallow) };
}

fn filesEqual(interp: *Interp, f1: []const u8, f2: []const u8, shallow: bool) !bool {
    const s1 = std.Io.Dir.cwd().statFile(interp.io, f1, .{}) catch return error.PyOsError;
    const s2 = std.Io.Dir.cwd().statFile(interp.io, f2, .{}) catch return error.PyOsError;
    if (s1.kind != .file or s2.kind != .file) return false;
    if (s1.size != s2.size) return false;
    if (shallow and s1.mtime.nanoseconds == s2.mtime.nanoseconds) return true;
    // Deep compare.
    return try contentsEqual(interp, f1, f2);
}

fn contentsEqual(interp: *Interp, f1: []const u8, f2: []const u8) !bool {
    const a = interp.allocator;
    const d1 = try readFileAlloc(interp, f1);
    defer a.free(d1);
    const d2 = try readFileAlloc(interp, f2);
    defer a.free(d2);
    return std.mem.eql(u8, d1, d2);
}

fn readFileAlloc(interp: *Interp, path: []const u8) ![]u8 {
    const a = interp.allocator;
    var file = try std.Io.Dir.cwd().openFile(interp.io, path, .{});
    defer file.close(interp.io);
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(a);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(interp.io, &read_buf);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const got = reader.interface.readSliceShort(chunk[0..]) catch |err| switch (err) {
            error.ReadFailed => return err,
        };
        if (got == 0) break;
        try data.appendSlice(a, chunk[0..got]);
    }
    return try data.toOwnedSlice(a);
}

fn cmpfilesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3 or args[0] != .str or args[1] != .str or args[2] != .list) {
        try interp.typeError("filecmp.cmpfiles(a, b, common[, shallow])");
        return error.TypeError;
    }
    const left = args[0].str.bytes;
    const right = args[1].str.bytes;
    const common = args[2].list;
    const shallow = args.len < 4 or args[3] == .none or (args[3] == .boolean and args[3].boolean) or (args[3] == .small_int and args[3].small_int != 0);

    const matches = try List.init(a);
    const mismatches = try List.init(a);
    const errors = try List.init(a);

    for (common.items.items) |name_v| {
        if (name_v != .str) continue;
        const name = name_v.str.bytes;
        const left_path = try joinPath(a, left, name);
        defer a.free(left_path);
        const right_path = try joinPath(a, right, name);
        defer a.free(right_path);
        const eq = filesEqual(interp, left_path, right_path, shallow) catch {
            try errors.items.append(a, Value{ .str = try Str.init(a, name) });
            continue;
        };
        if (eq) {
            try matches.items.append(a, Value{ .str = try Str.init(a, name) });
        } else {
            try mismatches.items.append(a, Value{ .str = try Str.init(a, name) });
        }
    }
    const tup = try @import("../object/tuple.zig").Tuple.init(a, 3);
    tup.items[0] = Value{ .list = matches };
    tup.items[1] = Value{ .list = mismatches };
    tup.items[2] = Value{ .list = errors };
    return Value{ .tuple = tup };
}

fn clearCacheFn(_: *anyopaque, _: []const Value) anyerror!Value {
    // No-op: we don't memoize cmp() results.
    return Value.none;
}

fn joinPath(a: std.mem.Allocator, left: []const u8, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, left);
    if (left.len > 0 and left[left.len - 1] != '/') try out.append(a, '/');
    try out.appendSlice(a, name);
    return try out.toOwnedSlice(a);
}

// ===== dircmp =====

fn initFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return initImpl(p, args, Value.none, Value.none, Value{ .boolean = true });
}

fn initKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var ignore_v: Value = Value.none;
    var hide_v: Value = Value.none;
    var shallow_v: Value = Value{ .boolean = true };
    if (args.len >= 4) ignore_v = args[3];
    if (args.len >= 5) hide_v = args[4];
    if (args.len >= 6) shallow_v = args[5];
    for (kw_names, kw_values) |k, v| {
        if (k != .str) continue;
        if (std.mem.eql(u8, k.str.bytes, "ignore")) {
            ignore_v = v;
        } else if (std.mem.eql(u8, k.str.bytes, "hide")) {
            hide_v = v;
        } else if (std.mem.eql(u8, k.str.bytes, "shallow")) {
            shallow_v = v;
        } else {
            try interp.typeError("dircmp() got an unexpected keyword argument");
            return error.TypeError;
        }
    }
    return initImpl(p, args, ignore_v, hide_v, shallow_v);
}

fn initImpl(p: *anyopaque, args: []const Value, ignore_v: Value, hide_v: Value, shallow_v: Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 3 or args[0] != .instance or args[1] != .str or args[2] != .str) {
        try interp.typeError("dircmp(left, right[, ignore[, hide]])");
        return error.TypeError;
    }
    const a = interp.allocator;
    const self = args[0].instance;
    const left = args[1].str.bytes;
    const right = args[2].str.bytes;

    const shallow = shallow_v != .boolean or shallow_v.boolean;

    try self.dict.setStr(a, "left", Value{ .str = try Str.init(a, left) });
    try self.dict.setStr(a, "right", Value{ .str = try Str.init(a, right) });

    const ignores = try effectiveIgnores(interp, ignore_v);
    const hides = try effectiveHides(interp, hide_v);
    try self.dict.setStr(a, "ignore", Value{ .list = ignores });
    try self.dict.setStr(a, "hide", Value{ .list = hides });

    // Build left_list / right_list (raw listing minus ignore+hide).
    const left_list = try filteredListing(interp, left, ignores, hides);
    const right_list = try filteredListing(interp, right, ignores, hides);
    try self.dict.setStr(a, "left_list", Value{ .list = left_list });
    try self.dict.setStr(a, "right_list", Value{ .list = right_list });

    // common: intersection. left_only / right_only: differences.
    const common = try List.init(a);
    const left_only = try List.init(a);
    const right_only = try List.init(a);
    for (left_list.items.items) |lv| {
        if (lv != .str) continue;
        const ln = lv.str.bytes;
        if (listContainsStr(right_list, ln)) {
            try common.items.append(a, Value{ .str = try Str.init(a, ln) });
        } else {
            try left_only.items.append(a, Value{ .str = try Str.init(a, ln) });
        }
    }
    for (right_list.items.items) |rv| {
        if (rv != .str) continue;
        const rn = rv.str.bytes;
        if (!listContainsStr(left_list, rn)) {
            try right_only.items.append(a, Value{ .str = try Str.init(a, rn) });
        }
    }
    try self.dict.setStr(a, "common", Value{ .list = common });
    try self.dict.setStr(a, "left_only", Value{ .list = left_only });
    try self.dict.setStr(a, "right_only", Value{ .list = right_only });

    // Classify common into common_files / common_dirs / common_funny.
    const common_files = try List.init(a);
    const common_dirs = try List.init(a);
    const common_funny = try List.init(a);
    for (common.items.items) |cv| {
        if (cv != .str) continue;
        const cn = cv.str.bytes;
        const lp = try joinPath(a, left, cn);
        defer a.free(lp);
        const rp = try joinPath(a, right, cn);
        defer a.free(rp);
        const ls = std.Io.Dir.cwd().statFile(interp.io, lp, .{ .follow_symlinks = false }) catch {
            try common_funny.items.append(a, Value{ .str = try Str.init(a, cn) });
            continue;
        };
        const rs = std.Io.Dir.cwd().statFile(interp.io, rp, .{ .follow_symlinks = false }) catch {
            try common_funny.items.append(a, Value{ .str = try Str.init(a, cn) });
            continue;
        };
        if (ls.kind != rs.kind) {
            try common_funny.items.append(a, Value{ .str = try Str.init(a, cn) });
        } else if (ls.kind == .directory) {
            try common_dirs.items.append(a, Value{ .str = try Str.init(a, cn) });
        } else if (ls.kind == .file) {
            try common_files.items.append(a, Value{ .str = try Str.init(a, cn) });
        } else {
            try common_funny.items.append(a, Value{ .str = try Str.init(a, cn) });
        }
    }
    try self.dict.setStr(a, "common_files", Value{ .list = common_files });
    try self.dict.setStr(a, "common_dirs", Value{ .list = common_dirs });
    try self.dict.setStr(a, "common_funny", Value{ .list = common_funny });

    // For common_files, run cmpfiles.
    const same_files = try List.init(a);
    const diff_files = try List.init(a);
    const funny_files = try List.init(a);
    for (common_files.items.items) |fv| {
        const fn_ = fv.str.bytes;
        const lp = try joinPath(a, left, fn_);
        defer a.free(lp);
        const rp = try joinPath(a, right, fn_);
        defer a.free(rp);
        const eq = filesEqual(interp, lp, rp, shallow) catch {
            try funny_files.items.append(a, Value{ .str = try Str.init(a, fn_) });
            continue;
        };
        if (eq) {
            try same_files.items.append(a, Value{ .str = try Str.init(a, fn_) });
        } else {
            try diff_files.items.append(a, Value{ .str = try Str.init(a, fn_) });
        }
    }
    try self.dict.setStr(a, "same_files", Value{ .list = same_files });
    try self.dict.setStr(a, "diff_files", Value{ .list = diff_files });
    try self.dict.setStr(a, "funny_files", Value{ .list = funny_files });

    // For each common_dir, recursively build a dircmp.
    const subdirs = try Dict.init(a);
    for (common_dirs.items.items) |dv| {
        const dn = dv.str.bytes;
        const lp = try joinPath(a, left, dn);
        defer a.free(lp);
        const rp = try joinPath(a, right, dn);
        defer a.free(rp);
        const child = try Instance.init(a, interp.filecmp_dircmp_class.?);
        const inner_args = [_]Value{
            Value{ .instance = child },
            Value{ .str = try Str.init(a, lp) },
            Value{ .str = try Str.init(a, rp) },
        };
        _ = try initImpl(@ptrCast(interp), inner_args[0..], ignore_v, hide_v, Value{ .boolean = shallow });
        try subdirs.setKey(a, Value{ .str = try Str.init(a, dn) }, Value{ .instance = child });
    }
    try self.dict.setStr(a, "subdirs", Value{ .dict = subdirs });

    return Value.none;
}

fn effectiveIgnores(interp: *Interp, v: Value) !*List {
    const a = interp.allocator;
    if (v == .list) return v.list;
    // Default: DEFAULT_IGNORES.
    const out = try List.init(a);
    const names = [_][]const u8{ "RCS", "CVS", "tags", ".git", ".hg", ".bzr", "_darcs", "__pycache__" };
    for (names) |n| try out.items.append(a, Value{ .str = try Str.init(a, n) });
    return out;
}

fn effectiveHides(interp: *Interp, v: Value) !*List {
    const a = interp.allocator;
    const out = try List.init(a);
    if (v == .list) {
        for (v.list.items.items) |x| try out.items.append(a, x);
    } else {
        // Default: ['.', '..']
        try out.items.append(a, Value{ .str = try Str.init(a, ".") });
        try out.items.append(a, Value{ .str = try Str.init(a, "..") });
    }
    return out;
}

fn filteredListing(interp: *Interp, path: []const u8, ignores: *List, hides: *List) !*List {
    const a = interp.allocator;
    const out = try List.init(a);
    var dir = try std.Io.Dir.cwd().openDir(interp.io, path, .{ .iterate = true });
    defer dir.close(interp.io);
    var it = dir.iterate();
    while (try it.next(interp.io)) |entry| {
        if (listContainsStr(ignores, entry.name)) continue;
        if (listContainsStr(hides, entry.name)) continue;
        const dup = try a.dupe(u8, entry.name);
        try out.items.append(a, Value{ .str = try Str.fromOwnedSlice(a, dup) });
    }
    return out;
}

fn listContainsStr(l: *List, name: []const u8) bool {
    for (l.items.items) |v| {
        if (v == .str and std.mem.eql(u8, v.str.bytes, name)) return true;
    }
    return false;
}

// ===== dircmp.report* =====

fn reportFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const left_v = self.dict.getStr("left").?;
    const right_v = self.dict.getStr("right").?;
    const w = interp.stdout;
    try w.print("diff {s} {s}\n", .{ left_v.str.bytes, right_v.str.bytes });
    try printSection(interp, w, "Only in", left_v.str.bytes, "left_only", self);
    try printSection(interp, w, "Only in", right_v.str.bytes, "right_only", self);
    try printSimpleSection(interp, w, "Identical files", "same_files", self);
    try printSimpleSection(interp, w, "Differing files", "diff_files", self);
    try printSimpleSection(interp, w, "Trouble with common files", "funny_files", self);
    try printSimpleSection(interp, w, "Common subdirectories", "common_dirs", self);
    try printSimpleSection(interp, w, "Common funny cases", "common_funny", self);
    try w.flush();
    return Value.none;
}

fn printSection(_: *Interp, w: anytype, label: []const u8, dir_path: []const u8, attr: []const u8, self: *Instance) !void {
    const v = self.dict.getStr(attr) orelse return;
    if (v != .list or v.list.items.items.len == 0) return;
    sortStrList(v.list);
    try w.print("{s} {s} : ", .{ label, dir_path });
    try writeListRepr(w, v.list);
    try w.writeByte('\n');
}

fn printSimpleSection(_: *Interp, w: anytype, label: []const u8, attr: []const u8, self: *Instance) !void {
    const v = self.dict.getStr(attr) orelse return;
    if (v != .list or v.list.items.items.len == 0) return;
    sortStrList(v.list);
    try w.print("{s} : ", .{label});
    try writeListRepr(w, v.list);
    try w.writeByte('\n');
}

fn writeListRepr(w: anytype, l: *List) !void {
    try w.writeByte('[');
    for (l.items.items, 0..) |it, i| {
        if (i > 0) try w.writeAll(", ");
        if (it == .str) {
            try w.writeByte('\'');
            try w.writeAll(it.str.bytes);
            try w.writeByte('\'');
        } else {
            try it.writeRepr(w);
        }
    }
    try w.writeByte(']');
}

fn sortStrList(l: *List) void {
    std.mem.sort(Value, l.items.items, {}, lessThanStr);
}

fn lessThanStr(_: void, a: Value, b: Value) bool {
    if (a != .str or b != .str) return false;
    return std.mem.lessThan(u8, a.str.bytes, b.str.bytes);
}

fn reportPartialFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    _ = try reportFn(p, args);
    const subs_v = self.dict.getStr("subdirs") orelse return Value.none;
    if (subs_v != .dict) return Value.none;
    for (subs_v.dict.pairs.items) |pair| {
        try interp.stdout.writeByte('\n');
        const sub_args = [_]Value{pair.value};
        _ = try reportFn(p, sub_args[0..]);
    }
    return Value.none;
}

fn reportFullFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    _ = try reportFn(p, args);
    const subs_v = self.dict.getStr("subdirs") orelse return Value.none;
    if (subs_v != .dict) return Value.none;
    for (subs_v.dict.pairs.items) |pair| {
        try interp.stdout.writeByte('\n');
        const sub_args = [_]Value{pair.value};
        _ = try reportFullFn(p, sub_args[0..]);
    }
    return Value.none;
}
