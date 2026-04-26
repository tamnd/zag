//! Pinhole `pathlib`: `PurePosixPath`/`PosixPath`/`Path` modeled as
//! Class+Instance pairs. The canonical normalised string lives on the
//! instance dict under `_str`. POSIX-only — Windows variants would
//! need a parallel implementation, but no fixture exercises them.

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
const Str = @import("../object/string.zig").Str;
const Bytes = @import("../object/bytes.zig").Bytes;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Descriptor = @import("../object/descriptor.zig").Descriptor;
const Interp = @import("interp.zig").Interp;
const fnmatch_mod = @import("fnmatch_mod.zig");

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);
    const m = try Module.init(a, "pathlib");
    try m.attrs.setStr(a, "PurePosixPath", Value{ .class = interp.pathlib_pure_posix_class.? });
    try m.attrs.setStr(a, "PurePath", Value{ .class = interp.pathlib_pure_posix_class.? });
    try m.attrs.setStr(a, "PosixPath", Value{ .class = interp.pathlib_posix_class.? });
    try m.attrs.setStr(a, "Path", Value{ .class = interp.pathlib_posix_class.? });
    return m;
}

fn ensureClasses(interp: *Interp) !void {
    if (interp.pathlib_pure_posix_class != null) return;
    const a = interp.allocator;

    // PurePosixPath
    {
        const d = try Dict.init(a);
        try methodReg(a, d, "__init__", initFn);
        try methodReg(a, d, "__repr__", reprFn);
        try methodReg(a, d, "__str__", strFn);
        try methodReg(a, d, "__eq__", eqFn);
        try methodReg(a, d, "__ne__", neFn);
        try methodReg(a, d, "__lt__", ltFn);
        try methodReg(a, d, "__le__", leFn);
        try methodReg(a, d, "__gt__", gtFn);
        try methodReg(a, d, "__ge__", geFn);
        try methodReg(a, d, "__hash__", hashFn);
        try methodReg(a, d, "__truediv__", truedivFn);
        try methodReg(a, d, "__rtruediv__", rtruedivFn);
        try methodReg(a, d, "__fspath__", strFn);
        try methodReg(a, d, "joinpath", joinpathFn);
        try methodReg(a, d, "is_absolute", isAbsoluteFn);
        try methodReg(a, d, "as_posix", strFn);
        try methodReg(a, d, "with_name", withNameFn);
        try methodReg(a, d, "with_stem", withStemFn);
        try methodReg(a, d, "with_suffix", withSuffixFn);
        try methodReg(a, d, "with_segments", withSegmentsFn);
        try methodReg(a, d, "relative_to", relativeToFn);
        try methodReg(a, d, "is_relative_to", isRelativeToFn);
        try methodReg(a, d, "match", matchFn);
        try addProperty(a, d, "name", nameProp);
        try addProperty(a, d, "stem", stemProp);
        try addProperty(a, d, "suffix", suffixProp);
        try addProperty(a, d, "suffixes", suffixesProp);
        try addProperty(a, d, "parent", parentProp);
        try addProperty(a, d, "parents", parentsProp);
        try addProperty(a, d, "drive", driveProp);
        try addProperty(a, d, "root", rootProp);
        try addProperty(a, d, "anchor", anchorProp);
        try addProperty(a, d, "parts", partsProp);
        interp.pathlib_pure_posix_class = try Class.init(a, "PurePosixPath", &.{}, d);
    }

    // PosixPath / Path — same surface plus filesystem methods.
    {
        const d = try Dict.init(a);
        try methodReg(a, d, "__init__", initFn);
        try methodReg(a, d, "__repr__", reprFn);
        try methodReg(a, d, "__str__", strFn);
        try methodReg(a, d, "__eq__", eqFn);
        try methodReg(a, d, "__ne__", neFn);
        try methodReg(a, d, "__lt__", ltFn);
        try methodReg(a, d, "__le__", leFn);
        try methodReg(a, d, "__gt__", gtFn);
        try methodReg(a, d, "__ge__", geFn);
        try methodReg(a, d, "__hash__", hashFn);
        try methodReg(a, d, "__truediv__", truedivFn);
        try methodReg(a, d, "__rtruediv__", rtruedivFn);
        try methodReg(a, d, "__fspath__", strFn);
        try methodReg(a, d, "joinpath", joinpathFn);
        try methodReg(a, d, "is_absolute", isAbsoluteFn);
        try methodReg(a, d, "as_posix", strFn);
        try methodReg(a, d, "with_name", withNameFn);
        try methodReg(a, d, "with_stem", withStemFn);
        try methodReg(a, d, "with_suffix", withSuffixFn);
        try methodReg(a, d, "with_segments", withSegmentsFn);
        try methodReg(a, d, "relative_to", relativeToFn);
        try methodReg(a, d, "is_relative_to", isRelativeToFn);
        try methodReg(a, d, "match", matchFn);
        try addProperty(a, d, "name", nameProp);
        try addProperty(a, d, "stem", stemProp);
        try addProperty(a, d, "suffix", suffixProp);
        try addProperty(a, d, "suffixes", suffixesProp);
        try addProperty(a, d, "parent", parentProp);
        try addProperty(a, d, "parents", parentsProp);
        try addProperty(a, d, "drive", driveProp);
        try addProperty(a, d, "root", rootProp);
        try addProperty(a, d, "anchor", anchorProp);
        try addProperty(a, d, "parts", partsProp);

        // Filesystem methods.
        try methodReg(a, d, "exists", existsFn);
        try methodReg(a, d, "is_file", isFileFn);
        try methodReg(a, d, "is_dir", isDirFn);
        try methodReg(a, d, "is_symlink", isSymlinkFn);
        try methodReg(a, d, "read_text", readTextFn);
        try methodReg(a, d, "read_bytes", readBytesFn);
        try methodReg(a, d, "write_text", writeTextFn);
        try methodReg(a, d, "write_bytes", writeBytesFn);
        try methodReg(a, d, "touch", touchFn);
        try methodRegKw(a, d, "mkdir", mkdirKw);
        try methodReg(a, d, "rmdir", rmdirFn);
        try methodRegKw(a, d, "unlink", unlinkKw);
        try methodReg(a, d, "rename", renameFn);
        try methodReg(a, d, "replace", renameFn);
        try methodReg(a, d, "iterdir", iterdirFn);
        try methodReg(a, d, "glob", globFn);
        try methodReg(a, d, "rglob", rglobFn);
        try methodReg(a, d, "stat", statFn);
        try methodReg(a, d, "lstat", statFn);
        try methodReg(a, d, "absolute", absoluteFn);
        try methodReg(a, d, "resolve", absoluteFn);
        try methodReg(a, d, "expanduser", expanduserFn);
        try methodReg(a, d, "readlink", readlinkFn);
        try methodReg(a, d, "symlink_to", symlinkToFn);
        try methodReg(a, d, "walk", walkFn);

        const cls = try Class.init(a, "PosixPath", &.{}, d);
        interp.pathlib_posix_class = cls;

        // Classmethods.
        try registerClassmethod(a, d, "cwd", cwdCls);
        try registerClassmethod(a, d, "home", homeCls);
    }

    // stat_result class — namespace with attributes set from os.stat call.
    {
        const d = try Dict.init(a);
        try methodReg(a, d, "__repr__", statResultReprFn);
        const cls = try Class.init(a, "stat_result", &.{}, d);
        interp.pathlib_stat_result_class = cls;
    }
}

fn methodReg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn methodRegKw(a: std.mem.Allocator, d: *Dict, name: []const u8, comptime kw_func: BuiltinKwFnPtr) !void {
    const Wrap = struct {
        fn call(p: *anyopaque, args: []const Value) anyerror!Value {
            return kw_func(p, args, &.{}, &.{});
        }
    };
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = Wrap.call, .kw_func = kw_func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn addProperty(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    const desc = try Descriptor.init(a, .property, Value{ .builtin_fn = f });
    try d.setStr(a, name, Value{ .descriptor = desc });
}

fn registerClassmethod(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    const desc = try Descriptor.init(a, .classmethod, Value{ .builtin_fn = f });
    try d.setStr(a, name, Value{ .descriptor = desc });
}

// ===== Path normalisation =====

/// Decompose a POSIX path string into (drive, root, tail).
/// drive is always empty on POSIX. root is "/" if absolute, else "".
/// tail is the list of non-empty, non-"." segments. ".." is preserved
/// in relative paths but collapsed against the leading "/" in absolute.
fn splitPath(a: std.mem.Allocator, path: []const u8) !struct {
    root: []const u8,
    tail: std.ArrayList([]const u8),
} {
    var tail: std.ArrayList([]const u8) = .empty;
    errdefer tail.deinit(a);

    const root: []const u8 = if (path.len > 0 and path[0] == '/') "/" else "";
    var i: usize = if (root.len > 0) 1 else 0;
    while (i < path.len) {
        while (i < path.len and path[i] == '/') i += 1;
        const start = i;
        while (i < path.len and path[i] != '/') i += 1;
        const seg = path[start..i];
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        try tail.append(a, seg);
    }
    return .{ .root = root, .tail = tail };
}

/// Join arbitrary path segments using POSIX semantics: any segment
/// starting with `/` resets the accumulated path.
fn joinSegments(a: std.mem.Allocator, segments: []const []const u8) ![]u8 {
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(a);
    for (segments) |seg| {
        if (seg.len == 0) continue;
        if (seg[0] == '/') {
            acc.clearRetainingCapacity();
            try acc.appendSlice(a, seg);
        } else if (acc.items.len == 0) {
            try acc.appendSlice(a, seg);
        } else {
            if (acc.items[acc.items.len - 1] != '/') try acc.append(a, '/');
            try acc.appendSlice(a, seg);
        }
    }
    return try a.dupe(u8, acc.items);
}

/// Canonicalise a raw joined path: collapse runs of '/', drop trailing
/// '/' (except when the entire path is '/'), drop '.' segments.
fn normalize(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0) return try a.dupe(u8, "");
    const sp = try splitPath(a, raw);
    defer {
        var t = sp.tail;
        t.deinit(a);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    if (sp.root.len > 0) try out.appendSlice(a, sp.root);
    for (sp.tail.items, 0..) |seg, idx| {
        if (idx > 0 or sp.root.len == 0) {
            if (idx > 0) try out.append(a, '/');
        }
        try out.appendSlice(a, seg);
    }
    if (out.items.len == 0) return try a.dupe(u8, "");
    return try a.dupe(u8, out.items);
}

fn pathStr(self: *Instance) []const u8 {
    const v = self.dict.getStr("_str") orelse return "";
    return switch (v) {
        .str => |s| s.bytes,
        else => "",
    };
}

fn newPath(interp: *Interp, cls: *Class, path_str: []const u8) !Value {
    const a = interp.allocator;
    const inst = try Instance.init(a, cls);
    const dup = try a.dupe(u8, path_str);
    const s = try Str.fromOwnedSlice(a, dup);
    try inst.dict.setStr(a, "_str", Value{ .str = s });
    return Value{ .instance = inst };
}

fn pathClassOf(v: Value) ?*Class {
    if (v != .instance) return null;
    return v.instance.cls;
}

fn isPathInstance(interp: *Interp, v: Value) bool {
    if (v != .instance) return false;
    const c = v.instance.cls;
    return c == interp.pathlib_pure_posix_class.? or c == interp.pathlib_posix_class.?;
}

// ===== __init__ =====

fn initFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;

    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(a);
    if (args.len > 1) {
        for (args[1..]) |arg| {
            switch (arg) {
                .str => |s| try segs.append(a, s.bytes),
                .instance => |inst| {
                    if (inst.cls == interp.pathlib_pure_posix_class.? or
                        inst.cls == interp.pathlib_posix_class.?)
                    {
                        try segs.append(a, pathStr(inst));
                    } else {
                        try interp.typeError("argument should be str or pathlib path");
                        return error.TypeError;
                    }
                },
                else => {
                    try interp.typeError("argument should be str or pathlib path");
                    return error.TypeError;
                },
            }
        }
    }

    const joined = if (segs.items.len == 0) try a.dupe(u8, "") else try joinSegments(a, segs.items);
    defer a.free(joined);
    const norm = try normalize(a, joined);
    const s = try Str.fromOwnedSlice(a, norm);
    try self.dict.setStr(a, "_str", Value{ .str = s });
    return Value.none;
}

// ===== __repr__ / __str__ =====

fn reprFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;
    const cname = self.cls.name;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, cname);
    try buf.appendSlice(a, "('");
    try buf.appendSlice(a, pathStr(self));
    try buf.appendSlice(a, "')");
    const s = try Str.init(a, buf.items);
    return Value{ .str = s };
}

fn strFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const s = try Str.init(interp.allocator, pathStr(self));
    return Value{ .str = s };
}

// ===== Comparisons =====

fn extractStr(v: Value) ?[]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        .instance => |inst| blk: {
            const found = inst.dict.getStr("_str") orelse break :blk null;
            if (found != .str) break :blk null;
            break :blk found.str.bytes;
        },
        else => null,
    };
}

fn eqFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    _ = opaque_interp;
    if (args.len != 2) return error.TypeError;
    if (args[0] != .instance) return Value{ .boolean = false };
    if (args[1] != .instance) return Value{ .boolean = false };
    const a_path = pathStr(args[0].instance);
    if (args[1].instance.cls != args[0].instance.cls) return Value{ .boolean = false };
    const b_path = pathStr(args[1].instance);
    return Value{ .boolean = std.mem.eql(u8, a_path, b_path) };
}

fn neFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const r = try eqFn(opaque_interp, args);
    return Value{ .boolean = !r.boolean };
}

fn cmpStr(args: []const Value) ?std.math.Order {
    if (args.len != 2) return null;
    const a_s = extractStr(args[0]) orelse return null;
    const b_s = extractStr(args[1]) orelse return null;
    return std.mem.order(u8, a_s, b_s);
}

fn ltFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const o = cmpStr(args) orelse return error.TypeError;
    return Value{ .boolean = o == .lt };
}

fn leFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const o = cmpStr(args) orelse return error.TypeError;
    return Value{ .boolean = o != .gt };
}

fn gtFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const o = cmpStr(args) orelse return error.TypeError;
    return Value{ .boolean = o == .gt };
}

fn geFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const o = cmpStr(args) orelse return error.TypeError;
    return Value{ .boolean = o != .lt };
}

fn hashFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len != 1 or args[0] != .instance) return error.TypeError;
    const s = pathStr(args[0].instance);
    var h: u64 = 1469598103934665603;
    for (s) |b| h = (h ^ b) *% 1099511628211;
    return Value{ .small_int = @bitCast(h) };
}

// ===== / and joinpath =====

fn truedivFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 2 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;
    const rhs = extractStr(args[1]) orelse {
        try interp.typeError("Path / arg must be str or Path");
        return error.TypeError;
    };
    const segs = [_][]const u8{ pathStr(self), rhs };
    const joined = try joinSegments(a, &segs);
    defer a.free(joined);
    const norm = try normalize(a, joined);
    defer a.free(norm);
    return newPath(interp, self.cls, norm);
}

fn rtruedivFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 2 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;
    const lhs = extractStr(args[1]) orelse return error.TypeError;
    const segs = [_][]const u8{ lhs, pathStr(self) };
    const joined = try joinSegments(a, &segs);
    defer a.free(joined);
    const norm = try normalize(a, joined);
    defer a.free(norm);
    return newPath(interp, self.cls, norm);
}

fn joinpathFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(a);
    try segs.append(a, pathStr(self));
    for (args[1..]) |arg| {
        const s = extractStr(arg) orelse {
            try interp.typeError("joinpath: arg must be str or Path");
            return error.TypeError;
        };
        try segs.append(a, s);
    }
    const joined = try joinSegments(a, segs.items);
    defer a.free(joined);
    const norm = try normalize(a, joined);
    defer a.free(norm);
    return newPath(interp, self.cls, norm);
}

// ===== is_absolute / as_posix =====

fn isAbsoluteFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const s = pathStr(self);
    return Value{ .boolean = s.len > 0 and s[0] == '/' };
}

// ===== Properties =====

fn nameProp(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const s = pathStr(self);
    if (s.len == 0) return Value{ .str = try Str.init(interp.allocator, "") };
    if (std.mem.eql(u8, s, "/")) return Value{ .str = try Str.init(interp.allocator, "") };
    const last_slash = std.mem.lastIndexOfScalar(u8, s, '/');
    const name = if (last_slash) |i| s[i + 1 ..] else s;
    return Value{ .str = try Str.init(interp.allocator, name) };
}

fn stemProp(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const s = pathStr(self);
    const last_slash = std.mem.lastIndexOfScalar(u8, s, '/');
    const name = if (last_slash) |i| s[i + 1 ..] else s;
    if (name.len == 0) return Value{ .str = try Str.init(interp.allocator, "") };
    // Find the rightmost dot that isn't a leading dot.
    var i: usize = name.len;
    while (i > 1) : (i -= 1) {
        if (name[i - 1] == '.') {
            return Value{ .str = try Str.init(interp.allocator, name[0 .. i - 1]) };
        }
    }
    return Value{ .str = try Str.init(interp.allocator, name) };
}

fn suffixProp(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const s = pathStr(self);
    const last_slash = std.mem.lastIndexOfScalar(u8, s, '/');
    const name = if (last_slash) |i| s[i + 1 ..] else s;
    if (name.len < 2) return Value{ .str = try Str.init(interp.allocator, "") };
    var i: usize = name.len;
    while (i > 1) : (i -= 1) {
        if (name[i - 1] == '.') {
            return Value{ .str = try Str.init(interp.allocator, name[i - 1 ..]) };
        }
    }
    return Value{ .str = try Str.init(interp.allocator, "") };
}

fn suffixesProp(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const a = interp.allocator;
    const self = args[0].instance;
    const s = pathStr(self);
    const last_slash = std.mem.lastIndexOfScalar(u8, s, '/');
    const name = if (last_slash) |i| s[i + 1 ..] else s;
    const out = try List.init(a);
    if (name.len < 2) return Value{ .list = out };
    // Trim leading dots.
    var trim_start: usize = 0;
    while (trim_start < name.len and name[trim_start] == '.') trim_start += 1;
    if (trim_start >= name.len) return Value{ .list = out };
    const stem = name[trim_start..];
    var pos: usize = 0;
    while (pos < stem.len) {
        if (stem[pos] == '.') {
            const start = pos;
            pos += 1;
            while (pos < stem.len and stem[pos] != '.') pos += 1;
            const piece = stem[start..pos];
            try out.append(a, Value{ .str = try Str.init(a, piece) });
        } else {
            pos += 1;
        }
    }
    return Value{ .list = out };
}

fn parentProp(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const s = pathStr(self);
    const new_s = parentOf(s);
    return newPath(interp, self.cls, new_s);
}

fn parentOf(s: []const u8) []const u8 {
    if (s.len == 0) return "";
    if (std.mem.eql(u8, s, "/")) return "/";
    const last_slash = std.mem.lastIndexOfScalar(u8, s, '/') orelse return "";
    if (last_slash == 0) return "/";
    return s[0..last_slash];
}

fn parentsProp(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const a = interp.allocator;
    const self = args[0].instance;
    const cls = self.cls;
    const out = try List.init(a);
    var cur = pathStr(self);
    while (true) {
        const par = parentOf(cur);
        if (par.len == 0) break;
        if (std.mem.eql(u8, par, cur)) break;
        try out.append(a, try newPath(interp, cls, par));
        cur = par;
    }
    return Value{ .list = out };
}

fn driveProp(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    return Value{ .str = try Str.init(interp.allocator, "") };
}

fn rootProp(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const s = pathStr(self);
    const root: []const u8 = if (s.len > 0 and s[0] == '/') "/" else "";
    return Value{ .str = try Str.init(interp.allocator, root) };
}

fn anchorProp(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    return rootProp(opaque_interp, args);
}

fn partsProp(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const a = interp.allocator;
    const self = args[0].instance;
    const s = pathStr(self);
    const sp = try splitPath(a, s);
    defer {
        var t = sp.tail;
        t.deinit(a);
    }
    var n: usize = sp.tail.items.len;
    if (sp.root.len > 0) n += 1;
    const tup = try Tuple.init(a, n);
    var idx: usize = 0;
    if (sp.root.len > 0) {
        tup.items[idx] = Value{ .str = try Str.init(a, sp.root) };
        idx += 1;
    }
    for (sp.tail.items) |seg| {
        tup.items[idx] = Value{ .str = try Str.init(a, seg) };
        idx += 1;
    }
    return Value{ .tuple = tup };
}

// ===== with_name / with_stem / with_suffix / with_segments =====

fn withNameFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;
    const s = pathStr(self);
    const par = parentOf(s);
    const new_name = args[1].str.bytes;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    if (par.len > 0) {
        try buf.appendSlice(a, par);
        if (par.len > 0 and par[par.len - 1] != '/') try buf.append(a, '/');
    }
    try buf.appendSlice(a, new_name);
    return newPath(interp, self.cls, buf.items);
}

fn withStemFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;
    const s = pathStr(self);
    const last_slash = std.mem.lastIndexOfScalar(u8, s, '/');
    const name = if (last_slash) |i| s[i + 1 ..] else s;
    var suffix: []const u8 = "";
    if (name.len >= 2) {
        var i: usize = name.len;
        while (i > 1) : (i -= 1) {
            if (name[i - 1] == '.') {
                suffix = name[i - 1 ..];
                break;
            }
        }
    }
    const new_stem = args[1].str.bytes;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, new_stem);
    try buf.appendSlice(a, suffix);
    const new_name_arr = [_]Value{ args[0], Value{ .str = try Str.init(a, buf.items) } };
    return withNameFn(opaque_interp, &new_name_arr);
}

fn withSuffixFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len != 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;
    const s = pathStr(self);
    const last_slash = std.mem.lastIndexOfScalar(u8, s, '/');
    const name = if (last_slash) |i| s[i + 1 ..] else s;
    var stem_end: usize = name.len;
    if (name.len >= 2) {
        var i: usize = name.len;
        while (i > 1) : (i -= 1) {
            if (name[i - 1] == '.') {
                stem_end = i - 1;
                break;
            }
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, name[0..stem_end]);
    try buf.appendSlice(a, args[1].str.bytes);
    const new_name_arr = [_]Value{ args[0], Value{ .str = try Str.init(a, buf.items) } };
    return withNameFn(opaque_interp, &new_name_arr);
}

fn withSegmentsFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(a);
    for (args[1..]) |arg| {
        const s = extractStr(arg) orelse {
            try interp.typeError("with_segments: arg must be str or Path");
            return error.TypeError;
        };
        try segs.append(a, s);
    }
    const joined = try joinSegments(a, segs.items);
    defer a.free(joined);
    const norm = try normalize(a, joined);
    defer a.free(norm);
    return newPath(interp, self.cls, norm);
}

// ===== relative_to / is_relative_to =====

fn relativeToFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;
    const base = extractStr(args[1]) orelse {
        try interp.typeError("relative_to: arg must be str or Path");
        return error.TypeError;
    };
    const norm_base = try normalize(a, base);
    defer a.free(norm_base);
    const s = pathStr(self);
    if (!startsWithPath(s, norm_base)) {
        try interp.raisePy("ValueError", "is not in the subpath");
        return error.PyException;
    }
    var rest_start: usize = norm_base.len;
    if (rest_start < s.len and s[rest_start] == '/') rest_start += 1;
    return newPath(interp, self.cls, s[rest_start..]);
}

fn isRelativeToFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;
    const base = extractStr(args[1]) orelse return error.TypeError;
    const norm_base = try normalize(a, base);
    defer a.free(norm_base);
    return Value{ .boolean = startsWithPath(pathStr(self), norm_base) };
}

fn startsWithPath(path: []const u8, base: []const u8) bool {
    if (base.len == 0) return true;
    if (!std.mem.startsWith(u8, path, base)) return false;
    if (path.len == base.len) return true;
    if (path[base.len] == '/') return true;
    // base ends in '/'.
    if (base[base.len - 1] == '/') return true;
    return false;
}

// ===== match =====

fn matchFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    _ = opaque_interp;
    if (args.len != 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const self = args[0].instance;
    const s = pathStr(self);
    const pattern = args[1].str.bytes;
    const has_slash = std.mem.indexOfScalar(u8, pattern, '/') != null;
    const target = if (has_slash) s else blk: {
        const ls = std.mem.lastIndexOfScalar(u8, s, '/');
        break :blk if (ls) |i| s[i + 1 ..] else s;
    };
    return Value{ .boolean = fnmatch_mod.matchOne(target, pattern) };
}

// ===== Filesystem methods =====

fn pathBytesZ(a: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return try a.dupeZ(u8, path);
}

fn existsFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const path = pathStr(self);
    _ = std.Io.Dir.cwd().statFile(interp.io, path, .{}) catch {
        return Value{ .boolean = false };
    };
    return Value{ .boolean = true };
}

fn isFileFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const path = pathStr(self);
    const st = std.Io.Dir.cwd().statFile(interp.io, path, .{}) catch return Value{ .boolean = false };
    return Value{ .boolean = st.kind == .file };
}

fn isDirFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const path = pathStr(self);
    const st = std.Io.Dir.cwd().statFile(interp.io, path, .{}) catch return Value{ .boolean = false };
    return Value{ .boolean = st.kind == .directory };
}

fn isSymlinkFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const path = pathStr(self);
    var buf: [4096]u8 = undefined;
    _ = std.Io.Dir.cwd().readLink(interp.io, path, &buf) catch
        return Value{ .boolean = false };
    return Value{ .boolean = true };
}

fn readTextFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const a = interp.allocator;
    const path = pathStr(self);
    const data = try readFileAlloc(interp, path);
    const s = try Str.fromOwnedSlice(a, data);
    return Value{ .str = s };
}

fn readBytesFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const a = interp.allocator;
    const path = pathStr(self);
    const data = try readFileAlloc(interp, path);
    defer a.free(data);
    return Value{ .bytes = try Bytes.init(a, data) };
}

fn readFileAlloc(interp: *Interp, path: []const u8) ![]u8 {
    const a = interp.allocator;
    var file = std.Io.Dir.cwd().openFile(interp.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", path);
            return error.PyException;
        },
        else => return err,
    };
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

fn writeTextFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const self = args[0].instance;
    const path = pathStr(self);
    const data = args[1].str.bytes;
    try writeFileAll(interp, path, data);
    return Value{ .small_int = @intCast(data.len) };
}

fn writeBytesFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const path = pathStr(self);
    const data: []const u8 = switch (args[1]) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        .str => |s| s.bytes,
        else => return error.TypeError,
    };
    try writeFileAll(interp, path, data);
    return Value{ .small_int = @intCast(data.len) };
}

fn writeFileAll(interp: *Interp, path: []const u8, data: []const u8) !void {
    var file = std.Io.Dir.cwd().createFile(interp.io, path, .{}) catch |err| return err;
    defer file.close(interp.io);
    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(interp.io, &write_buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

fn touchFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const path = pathStr(self);
    if (std.Io.Dir.cwd().statFile(interp.io, path, .{})) |_| {
        return Value.none;
    } else |_| {}
    var file = std.Io.Dir.cwd().createFile(interp.io, path, .{}) catch |err| return err;
    file.close(interp.io);
    return Value.none;
}

fn mkdirKw(
    opaque_interp: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const path = pathStr(self);
    var parents = false;
    var exist_ok = false;
    for (kw_names, 0..) |name, i| {
        if (name != .str) continue;
        const k = name.str.bytes;
        const v = kw_values[i];
        if (std.mem.eql(u8, k, "parents")) {
            parents = v != .boolean or v.boolean;
            if (v == .boolean) parents = v.boolean;
        } else if (std.mem.eql(u8, k, "exist_ok")) {
            exist_ok = v != .boolean or v.boolean;
            if (v == .boolean) exist_ok = v.boolean;
        }
    }
    const make_result = if (parents) makeDirAll(interp, path) else makeDir(interp, path);
    make_result catch |err| switch (err) {
        error.PathAlreadyExists => {
            if (!exist_ok) {
                try interp.raisePy("FileExistsError", path);
                return error.PyException;
            }
        },
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", path);
            return error.PyException;
        },
        else => return err,
    };
    return Value.none;
}

fn makeDir(interp: *Interp, path: []const u8) !void {
    try std.Io.Dir.cwd().createDir(interp.io, path, .default_dir);
}

fn makeDirAll(interp: *Interp, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(interp.io, path);
}

fn rmdirFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const path = pathStr(self);
    std.Io.Dir.cwd().deleteDir(interp.io, path) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", path);
            return error.PyException;
        },
        else => return err,
    };
    return Value.none;
}

fn unlinkKw(
    opaque_interp: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const path = pathStr(self);
    var missing_ok = false;
    for (kw_names, 0..) |name, i| {
        if (name != .str) continue;
        if (std.mem.eql(u8, name.str.bytes, "missing_ok")) {
            const v = kw_values[i];
            if (v == .boolean) missing_ok = v.boolean;
        }
    }
    if (args.len >= 2 and args[1] == .boolean) missing_ok = args[1].boolean;
    std.Io.Dir.cwd().deleteFile(interp.io, path) catch |err| switch (err) {
        error.FileNotFound => {
            if (!missing_ok) {
                try interp.raisePy("FileNotFoundError", path);
                return error.PyException;
            }
        },
        else => return err,
    };
    return Value.none;
}

fn renameFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const a = interp.allocator;
    const src = pathStr(self);
    const dst = extractStr(args[1]) orelse {
        try interp.typeError("rename: target must be str or Path");
        return error.TypeError;
    };
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(src, cwd, dst, interp.io);
    const norm = try normalize(a, dst);
    defer a.free(norm);
    return newPath(interp, self.cls, norm);
}

fn iterdirFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const a = interp.allocator;
    const path = pathStr(self);
    const out = try List.init(a);

    var dir = try std.Io.Dir.cwd().openDir(interp.io, path, .{ .iterate = true });
    defer dir.close(interp.io);
    var it = dir.iterate();
    while (try it.next(interp.io)) |entry| {
        const name = entry.name;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try buf.appendSlice(a, path);
        if (path.len > 0 and path[path.len - 1] != '/') try buf.append(a, '/');
        try buf.appendSlice(a, name);
        try out.append(a, try newPath(interp, self.cls, buf.items));
    }
    return Value{ .list = out };
}

fn globImpl(interp: *Interp, base: []const u8, base_cls: *Class, pattern: []const u8, recursive: bool) !Value {
    const a = interp.allocator;
    const out = try List.init(a);
    try collectGlob(interp, base, base, base_cls, pattern, recursive, out);
    return Value{ .list = out };
}

fn collectGlob(
    interp: *Interp,
    base: []const u8,
    cur: []const u8,
    cls: *Class,
    pattern: []const u8,
    recursive: bool,
    out: *List,
) !void {
    _ = base;
    const a = interp.allocator;
    var dir = std.Io.Dir.cwd().openDir(interp.io, cur, .{ .iterate = true }) catch return;
    defer dir.close(interp.io);
    var it = dir.iterate();
    while (try it.next(interp.io)) |entry| {
        const name = entry.name;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try buf.appendSlice(a, cur);
        if (cur.len > 0 and cur[cur.len - 1] != '/') try buf.append(a, '/');
        try buf.appendSlice(a, name);
        if (fnmatch_mod.matchOne(name, pattern)) {
            try out.append(a, try newPath(interp, cls, buf.items));
        }
        if (recursive and entry.kind == .directory) {
            try collectGlob(interp, cur, buf.items, cls, pattern, recursive, out);
        }
    }
}

fn globFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const self = args[0].instance;
    return globImpl(interp, pathStr(self), self.cls, args[1].str.bytes, false);
}

fn rglobFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const self = args[0].instance;
    return globImpl(interp, pathStr(self), self.cls, args[1].str.bytes, true);
}

fn statFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const a = interp.allocator;
    const path = pathStr(self);
    const st = std.Io.Dir.cwd().statFile(interp.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", path);
            return error.PyException;
        },
        else => return err,
    };
    const inst = try Instance.init(a, interp.pathlib_stat_result_class.?);
    var mode: i64 = 0o644;
    if (st.kind == .directory) mode |= 0o040000 else mode |= 0o100000;
    try inst.dict.setStr(a, "st_mode", Value{ .small_int = mode });
    try inst.dict.setStr(a, "st_size", Value{ .small_int = @intCast(st.size) });
    try inst.dict.setStr(a, "st_ino", Value{ .small_int = @intCast(st.inode) });
    try inst.dict.setStr(a, "st_nlink", Value{ .small_int = @intCast(st.nlink) });
    try inst.dict.setStr(a, "st_uid", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "st_gid", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "st_dev", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "st_atime", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "st_mtime", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "st_ctime", Value{ .small_int = 0 });
    return Value{ .instance = inst };
}

fn statResultReprFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    _ = args;
    return Value{ .str = try Str.init(interp.allocator, "os.stat_result(...)") };
}

fn absoluteFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const a = interp.allocator;
    const s = pathStr(self);
    if (s.len > 0 and s[0] == '/') {
        const norm = try normalize(a, s);
        defer a.free(norm);
        return newPath(interp, self.cls, norm);
    }
    const cwd = try getCwdAlloc(interp);
    defer a.free(cwd);
    const segs = [_][]const u8{ cwd, s };
    const joined = try joinSegments(a, &segs);
    defer a.free(joined);
    const norm = try normalize(a, joined);
    defer a.free(norm);
    return newPath(interp, self.cls, norm);
}

fn expanduserFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const a = interp.allocator;
    const s = pathStr(self);
    if (s.len == 0 or s[0] != '~') {
        return newPath(interp, self.cls, s);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, interp.home);
    if (s.len > 1) try buf.appendSlice(a, s[1..]);
    return newPath(interp, self.cls, buf.items);
}

fn readlinkFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const path = pathStr(self);
    var buf: [4096]u8 = undefined;
    const n = std.Io.Dir.cwd().readLink(interp.io, path, &buf) catch |err| switch (err) {
        error.FileNotFound => {
            try interp.raisePy("FileNotFoundError", path);
            return error.PyException;
        },
        else => return err,
    };
    return newPath(interp, self.cls, buf[0..n]);
}

fn symlinkToFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;
    const link_path = pathStr(self);
    const target = extractStr(args[1]) orelse {
        try interp.typeError("symlink_to: target must be str or Path");
        return error.TypeError;
    };
    try std.Io.Dir.cwd().symLink(interp.io, target, link_path, .{});
    return Value.none;
}

fn walkFn(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    const self = args[0].instance;
    const a = interp.allocator;
    const path = pathStr(self);
    const out = try List.init(a);
    try walkImpl(interp, self.cls, path, out);
    return Value{ .list = out };
}

fn walkImpl(interp: *Interp, cls: *Class, path: []const u8, out: *List) !void {
    const a = interp.allocator;
    var dir = std.Io.Dir.cwd().openDir(interp.io, path, .{ .iterate = true }) catch return;
    defer dir.close(interp.io);
    var subdirs: std.ArrayList([]u8) = .empty;
    defer {
        for (subdirs.items) |s| a.free(s);
        subdirs.deinit(a);
    }
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |s| a.free(s);
        files.deinit(a);
    }
    var it = dir.iterate();
    while (try it.next(interp.io)) |entry| {
        const name_dup = try a.dupe(u8, entry.name);
        if (entry.kind == .directory) {
            try subdirs.append(a, name_dup);
        } else {
            try files.append(a, name_dup);
        }
    }
    const tup = try Tuple.init(a, 3);
    tup.items[0] = try newPath(interp, cls, path);
    const subdir_list = try List.init(a);
    for (subdirs.items) |s| try subdir_list.append(a, Value{ .str = try Str.init(a, s) });
    tup.items[1] = Value{ .list = subdir_list };
    const files_list = try List.init(a);
    for (files.items) |s| try files_list.append(a, Value{ .str = try Str.init(a, s) });
    tup.items[2] = Value{ .list = files_list };
    try out.append(a, Value{ .tuple = tup });

    for (subdirs.items) |sub| {
        var child_buf: std.ArrayList(u8) = .empty;
        defer child_buf.deinit(a);
        try child_buf.appendSlice(a, path);
        if (path.len > 0 and path[path.len - 1] != '/') try child_buf.append(a, '/');
        try child_buf.appendSlice(a, sub);
        try walkImpl(interp, cls, child_buf.items, out);
    }
}

// ===== Classmethods =====

fn cwdCls(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    _ = args;
    const a = interp.allocator;
    const cwd = try getCwdAlloc(interp);
    defer a.free(cwd);
    return newPath(interp, interp.pathlib_posix_class.?, cwd);
}

fn homeCls(opaque_interp: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(opaque_interp));
    _ = args;
    return newPath(interp, interp.pathlib_posix_class.?, interp.home);
}

pub fn getCwdAlloc(interp: *Interp) ![]u8 {
    var buf: [4096]u8 = undefined;
    const n = try std.process.currentPath(interp.io, &buf);
    return try interp.allocator.dupe(u8, buf[0..n]);
}
