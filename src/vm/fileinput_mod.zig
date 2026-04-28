//! Pinhole `fileinput` module.
//! Implements FileInput class with iteration, lineno, filename, etc.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

// ===== helpers =====

fn reg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regM(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn regMKw(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

// ===== FileInput internal state =====

const FileState = struct {
    // list of filenames (owned slices)
    filenames: [][]u8,
    file_idx: usize = 0,
    // current file lines (owned)
    cur_lines: std.ArrayListUnmanaged([]u8),
    line_idx: usize = 0,
    // cumulative line number
    lineno: i64 = 0,
    // file-level line number
    filelineno: i64 = 0,
    closed: bool = false,
};

fn stateFrom(inst: *Instance) *FileState {
    const v = inst.dict.getStr("_state").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn loadFile(interp: *Interp, st: *FileState) !void {
    const a = interp.allocator;
    // free old lines
    for (st.cur_lines.items) |line| a.free(line);
    st.cur_lines.clearRetainingCapacity();
    st.line_idx = 0;
    st.filelineno = 0;

    if (st.file_idx >= st.filenames.len) return;

    const path = st.filenames[st.file_idx];
    var file = std.Io.Dir.cwd().openFile(interp.io, path, .{}) catch return;
    defer file.close(interp.io);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(interp.io, &read_buf);
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(a);

    var chunk: [4096]u8 = undefined;
    while (true) {
        const got = reader.interface.readSliceShort(chunk[0..]) catch break;
        if (got == 0) break;
        try data.appendSlice(a, chunk[0..got]);
    }

    // split into lines (keeping newline)
    var pos: usize = 0;
    while (pos < data.items.len) {
        var end = pos;
        while (end < data.items.len and data.items[end] != '\n') end += 1;
        if (end < data.items.len) end += 1; // include newline
        const line = try a.dupe(u8, data.items[pos..end]);
        try st.cur_lines.append(a, line);
        pos = end;
    }
}

fn nextLineFromState(interp: *Interp, st: *FileState) !?[]const u8 {
    while (true) {
        if (st.file_idx >= st.filenames.len) return null;
        if (st.line_idx < st.cur_lines.items.len) {
            const line = st.cur_lines.items[st.line_idx];
            st.line_idx += 1;
            st.lineno += 1;
            st.filelineno += 1;
            return line;
        }
        // advance to next file
        st.file_idx += 1;
        if (st.file_idx >= st.filenames.len) return null;
        try loadFile(interp, st);
    }
}

// ===== FileInput methods =====

fn fiInit(p: *anyopaque, args: []const Value) anyerror!Value {
    return fiInitImpl(p, args, &.{}, &.{});
}

fn fiInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return fiInitImpl(p, args, kn, kv);
}

fn fiInitImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;

    // collect files parameter
    var files_val: Value = Value.none;
    if (args.len >= 2) files_val = args[1];
    for (kn, kv) |k, v| {
        if (k == .str and std.mem.eql(u8, k.str.bytes, "files")) {
            files_val = v;
        }
    }

    // collect filename strings
    var name_list: std.ArrayListUnmanaged([]u8) = .empty;
    defer name_list.deinit(a);

    switch (files_val) {
        .str => |s| {
            try name_list.append(a, try a.dupe(u8, s.bytes));
        },
        .list => |l| {
            for (l.items.items) |item| {
                if (item == .str) try name_list.append(a, try a.dupe(u8, item.str.bytes));
            }
        },
        .tuple => |t| {
            for (t.items) |item| {
                if (item == .str) try name_list.append(a, try a.dupe(u8, item.str.bytes));
            }
        },
        else => {},
    }

    const owned_names = try name_list.toOwnedSlice(a);

    const st = try a.create(FileState);
    st.* = .{
        .filenames = owned_names,
        .cur_lines = .empty,
    };

    // load first file
    if (owned_names.len > 0) {
        try loadFile(interp, st);
    }

    try inst.dict.setStr(a, "_state", Value{ .small_int = @intCast(@intFromPtr(st)) });
    return Value.none;
}

fn fiLineno(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return Value{ .small_int = 0 };
    const st = stateFrom(args[0].instance);
    return Value{ .small_int = st.lineno };
}

fn fiFilelineno(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return Value{ .small_int = 0 };
    const st = stateFrom(args[0].instance);
    return Value{ .small_int = st.filelineno };
}

fn fiFilename(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const st = stateFrom(args[0].instance);
    if (st.file_idx >= st.filenames.len) return Value.none;
    return Value{ .str = try Str.init(a, st.filenames[st.file_idx]) };
}

fn fiIsfirstline(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return Value{ .boolean = false };
    const st = stateFrom(args[0].instance);
    return Value{ .boolean = st.filelineno == 1 };
}

fn fiIsstdin(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value{ .boolean = false };
}

fn fiNextfile(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const st = stateFrom(args[0].instance);
    st.file_idx += 1;
    if (st.file_idx < st.filenames.len) {
        try loadFile(interp, st);
    }
    return Value.none;
}

fn fiFileno(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return Value{ .small_int = 0 };
    _ = stateFrom(args[0].instance);
    return Value{ .small_int = 0 };
}

fn fiClose(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const st = stateFrom(args[0].instance);
    st.closed = true;
    return Value.none;
}

fn fiEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value.none;
    return args[0];
}

fn fiExit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try fiClose(p, args[0..1]);
    return Value{ .boolean = false };
}

fn fiIter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return Value.none;
    return args[0];
}

fn fiNext(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    }
    const st = stateFrom(args[0].instance);
    if (st.closed) {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    }
    const line = try nextLineFromState(interp, st) orelse {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    };
    return Value{ .str = try Str.init(a, line) };
}

var fileinput_class: ?*Class = null;

fn getOrCreateClass(interp: *Interp) !*Class {
    if (fileinput_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try regKw(a, d, "__init__", fiInit, fiInitKw);
    try reg(a, d, "lineno", fiLineno);
    try reg(a, d, "filelineno", fiFilelineno);
    try reg(a, d, "filename", fiFilename);
    try reg(a, d, "isfirstline", fiIsfirstline);
    try reg(a, d, "isstdin", fiIsstdin);
    try reg(a, d, "nextfile", fiNextfile);
    try reg(a, d, "fileno", fiFileno);
    try reg(a, d, "close", fiClose);
    try reg(a, d, "__enter__", fiEnter);
    try reg(a, d, "__exit__", fiExit);
    try reg(a, d, "__iter__", fiIter);
    try reg(a, d, "__next__", fiNext);
    const cls = try Class.init(a, "FileInput", &.{}, d);
    fileinput_class = cls;
    return cls;
}

// ===== module-level functions =====

// global FileInput instance for module-level functions
var global_fi: ?*Instance = null;

fn inputFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return inputKwImpl(p, args, &.{}, &.{});
}

fn inputKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return inputKwImpl(p, args, kn, kv);
}

fn inputKwImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const cls = try getOrCreateClass(interp);
    const inst = try Instance.init(a, cls);
    const inst_v = Value{ .instance = inst };
    // init with args (minus "self")
    var all_args = try a.alloc(Value, args.len + 1);
    defer a.free(all_args);
    all_args[0] = inst_v;
    @memcpy(all_args[1..], args);
    _ = try fiInitImpl(p, all_args, kn, kv);
    global_fi = inst;
    return inst_v;
}

fn modFilenameFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const fi = global_fi orelse return Value.none;
    const a = interp.allocator;
    const st = stateFrom(fi);
    if (st.file_idx >= st.filenames.len) return Value.none;
    return Value{ .str = try Str.init(a, st.filenames[st.file_idx]) };
}

fn modLinenoFn(_: *anyopaque, _: []const Value) anyerror!Value {
    const fi = global_fi orelse return Value{ .small_int = 0 };
    return Value{ .small_int = stateFrom(fi).lineno };
}

fn modFilelinenoFn(_: *anyopaque, _: []const Value) anyerror!Value {
    const fi = global_fi orelse return Value{ .small_int = 0 };
    return Value{ .small_int = stateFrom(fi).filelineno };
}

fn hookEncodedFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    // return a stub callable (a builtin_fn)
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = "hook_encoded_callable", .func = stubCallable };
    return Value{ .builtin_fn = f };
}

fn stubCallable(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn hookCompressedFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

// ===== FileInput constructor (module-level) =====

fn fileInputFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return fileInputKwImpl(p, args, &.{}, &.{});
}

fn fileInputKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return fileInputKwImpl(p, args, kn, kv);
}

fn fileInputKwImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const cls = try getOrCreateClass(interp);
    const inst = try Instance.init(a, cls);
    const inst_v = Value{ .instance = inst };
    var all_args = try a.alloc(Value, args.len + 1);
    defer a.free(all_args);
    all_args[0] = inst_v;
    @memcpy(all_args[1..], args);
    _ = try fiInitImpl(p, all_args, kn, kv);
    return inst_v;
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "fileinput");

    fileinput_class = null;
    global_fi = null;

    const cls = try getOrCreateClass(interp);
    try m.attrs.setStr(a, "FileInput", Value{ .class = cls });

    try regMKw(a, m, "input", inputFn, inputKw);
    try regMKw(a, m, "FileInput", fileInputFn, fileInputKw);
    try regM(a, m, "filename", modFilenameFn);
    try regM(a, m, "lineno", modLinenoFn);
    try regM(a, m, "filelineno", modFilelinenoFn);
    try regM(a, m, "hook_encoded", hookEncodedFn);

    // hook_compressed as a callable attribute
    const hc = try a.create(BuiltinFn);
    hc.* = .{ .name = "hook_compressed", .func = hookCompressedFn };
    try m.attrs.setStr(a, "hook_compressed", Value{ .builtin_fn = hc });

    return m;
}
