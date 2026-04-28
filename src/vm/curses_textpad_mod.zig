//! Pinhole `curses.textpad` module.
//! Provides rectangle() stub and Textbox class.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

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

// ===== rectangle stub =====

fn rectangleFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

// ===== Textbox helpers =====

fn getBuf(inst: *Instance) []const u8 {
    const v = inst.dict.getStr("_buf") orelse return "";
    return switch (v) { .str => |s| s.bytes, else => "" };
}

fn getPos(inst: *Instance) i64 {
    const v = inst.dict.getStr("_pos") orelse return 0;
    return switch (v) { .small_int => |n| n, else => 0 };
}

// ===== Textbox methods =====

fn tbGather(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) {
        const s = try Str.init(a, "");
        return Value{ .str = s };
    }
    const inst = args[0].instance;
    const buf = getBuf(inst);
    const s = try Str.init(a, buf);
    return Value{ .str = s };
}

fn tbEdit(p: *anyopaque, args: []const Value) anyerror!Value {
    return tbGather(p, args);
}

fn tbEditKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return tbGather(p, args);
}

fn tbDoCommand(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const ch: i64 = switch (args[1]) { .small_int => |n| n, else => return Value.none };

    const buf = getBuf(inst);
    var pos = getPos(inst);
    if (pos < 0) pos = 0;

    if (ch >= 32 and ch <= 126) {
        // Insert printable char at cursor
        var new_buf = try a.alloc(u8, buf.len + 1);
        const upos: usize = @intCast(@min(pos, @as(i64, @intCast(buf.len))));
        @memcpy(new_buf[0..upos], buf[0..upos]);
        new_buf[upos] = @intCast(ch);
        @memcpy(new_buf[upos + 1 ..], buf[upos..]);
        const s = try Str.init(a, new_buf);
        a.free(new_buf);
        try inst.dict.setStr(a, "_buf", Value{ .str = s });
        try inst.dict.setStr(a, "_pos", Value{ .small_int = pos + 1 });
    } else if (ch == 1) {
        // Ctrl-A: move to start
        try inst.dict.setStr(a, "_pos", Value{ .small_int = 0 });
    } else if (ch == 5) {
        // Ctrl-E: move to end
        try inst.dict.setStr(a, "_pos", Value{ .small_int = @intCast(buf.len) });
    } else if (ch == 2) {
        // Ctrl-B: move back
        if (pos > 0) try inst.dict.setStr(a, "_pos", Value{ .small_int = pos - 1 });
    } else if (ch == 6) {
        // Ctrl-F: move forward
        if (pos < @as(i64, @intCast(buf.len))) try inst.dict.setStr(a, "_pos", Value{ .small_int = pos + 1 });
    } else if (ch == 4) {
        // Ctrl-D: delete char at cursor
        const upos: usize = @intCast(@min(pos, @as(i64, @intCast(buf.len))));
        if (upos < buf.len) {
            var new_buf = try a.alloc(u8, buf.len - 1);
            @memcpy(new_buf[0..upos], buf[0..upos]);
            @memcpy(new_buf[upos..], buf[upos + 1 ..]);
            const s = try Str.init(a, new_buf);
            a.free(new_buf);
            try inst.dict.setStr(a, "_buf", Value{ .str = s });
        }
    } else if (ch == 8 or ch == 263) {
        // Ctrl-H / Backspace: delete char before cursor
        const upos: usize = @intCast(@min(pos, @as(i64, @intCast(buf.len))));
        if (upos > 0) {
            var new_buf = try a.alloc(u8, buf.len - 1);
            @memcpy(new_buf[0 .. upos - 1], buf[0 .. upos - 1]);
            @memcpy(new_buf[upos - 1 ..], buf[upos..]);
            const s = try Str.init(a, new_buf);
            a.free(new_buf);
            try inst.dict.setStr(a, "_buf", Value{ .str = s });
            try inst.dict.setStr(a, "_pos", Value{ .small_int = pos - 1 });
        }
    } else if (ch == 11) {
        // Ctrl-K: kill to end
        const upos: usize = @intCast(@min(pos, @as(i64, @intCast(buf.len))));
        const s = try Str.init(a, buf[0..upos]);
        try inst.dict.setStr(a, "_buf", Value{ .str = s });
    } else if (ch == 7) {
        // Ctrl-G: terminate
        return Value{ .small_int = 0 };
    }
    // other: ignore
    return Value.none;
}

fn tbInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    // args[1] is win, args[2] is insert_mode (optional)
    const win = if (args.len >= 2) args[1] else Value.none;
    const insert_mode = if (args.len >= 3) args[2] else Value{ .boolean = false };
    try inst.dict.setStr(a, "_win", win);
    try inst.dict.setStr(a, "_insert_mode", insert_mode);
    const empty_str = try Str.init(a, "");
    try inst.dict.setStr(a, "_buf", Value{ .str = empty_str });
    try inst.dict.setStr(a, "_pos", Value{ .small_int = 0 });
    return Value.none;
}

fn getOrCreateTextboxClass(interp: *Interp) !*Class {
    if (interp.curses_textpad_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try reg(a, d, "__init__", tbInit);
    try reg(a, d, "gather", tbGather);
    try regKw(a, d, "edit", tbEdit, tbEditKw);
    try reg(a, d, "do_command", tbDoCommand);
    const cls = try Class.init(a, "Textbox", &.{}, d);
    interp.curses_textpad_class = cls;
    return cls;
}

// ===== Textbox constructor =====

fn textboxNew(p: *anyopaque, args: []const Value) anyerror!Value {
    return textboxNewKwImpl(p, args, &.{}, &.{});
}

fn textboxNewKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return textboxNewKwImpl(p, args, kn, kv);
}

fn textboxNewKwImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const cls = try getOrCreateTextboxClass(interp);
    const inst = try Instance.init(a, cls);
    const win = if (args.len >= 1) args[0] else Value.none;
    var insert_mode: Value = Value{ .boolean = false };
    if (args.len >= 2) insert_mode = args[1];
    for (kn, kv) |k, v| {
        if (k == .str and std.mem.eql(u8, k.str.bytes, "insert_mode")) insert_mode = v;
    }
    try inst.dict.setStr(a, "_win", win);
    try inst.dict.setStr(a, "_insert_mode", insert_mode);
    const empty_str = try Str.init(a, "");
    try inst.dict.setStr(a, "_buf", Value{ .str = empty_str });
    try inst.dict.setStr(a, "_pos", Value{ .small_int = 0 });
    return Value{ .instance = inst };
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "curses.textpad");

    _ = try getOrCreateTextboxClass(interp);
    const cls = interp.curses_textpad_class.?;

    // Expose Textbox as a kw-aware callable
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = "Textbox", .func = textboxNew, .kw_func = textboxNewKw };
    try m.attrs.setStr(a, "Textbox", Value{ .builtin_fn = f });

    // Also expose the class for isinstance checks
    try m.attrs.setStr(a, "_Textbox_class", Value{ .class = cls });

    try regM(a, m, "rectangle", rectangleFn);

    return m;
}
