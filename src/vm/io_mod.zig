//! Pinhole `io`: StringIO and BytesIO. Both are growable byte/char
//! buffers with a position cursor. We back them with a managed
//! ArrayList stored on a side struct pointed at from the instance.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Str = @import("../object/string.zig").Str;
const List = @import("../object/list.zig").List;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

const Buf = struct {
    data: std.ArrayList(u8),
    pos: usize = 0,
    closed: bool = false,
};

var stringio_class: ?*Class = null;
var bytesio_class: ?*Class = null;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "io");
    try ensureClasses(interp);
    try regCtor(interp, m, "StringIO", stringIoCtor);
    try regCtor(interp, m, "BytesIO", bytesIoCtor);
    return m;
}

fn regCtor(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;
    if (stringio_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "write", strWrite);
        try methodReg(a, d, "writelines", strWritelines);
        try methodReg(a, d, "read", strRead);
        try methodReg(a, d, "readline", strReadline);
        try methodReg(a, d, "readlines", strReadlines);
        try methodReg(a, d, "getvalue", strGetvalue);
        try methodReg(a, d, "tell", ioTell);
        try methodReg(a, d, "seek", ioSeek);
        try methodReg(a, d, "close", ioClose);
        stringio_class = try Class.init(a, "StringIO", &.{}, d);
    }
    if (bytesio_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "write", bytesWrite);
        try methodReg(a, d, "read", bytesRead);
        try methodReg(a, d, "getvalue", bytesGetvalue);
        try methodReg(a, d, "tell", ioTell);
        try methodReg(a, d, "seek", ioSeek);
        try methodReg(a, d, "close", ioClose);
        bytesio_class = try Class.init(a, "BytesIO", &.{}, d);
    }
}

fn newBuf(a: std.mem.Allocator) !*Buf {
    const buf = try a.create(Buf);
    buf.* = .{ .data = .empty };
    return buf;
}

fn bufFromInstance(inst: *Instance) *Buf {
    const v = inst.dict.getStr("_buf").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn argInst(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

// --- constructors ---

fn stringIoCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, stringio_class.?);
    const buf = try newBuf(a);
    if (args.len >= 1 and args[0] == .str) {
        try buf.data.appendSlice(a, args[0].str.bytes);
    }
    try inst.dict.setStr(a, "_buf", Value{ .small_int = @intCast(@intFromPtr(buf)) });
    try inst.dict.setStr(a, "closed", Value{ .boolean = false });
    return Value{ .instance = inst };
}

fn bytesIoCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    const a = interp.allocator;
    const inst = try Instance.init(a, bytesio_class.?);
    const buf = try newBuf(a);
    if (args.len >= 1 and args[0] == .bytes) {
        try buf.data.appendSlice(a, args[0].bytes.data);
    }
    try inst.dict.setStr(a, "_buf", Value{ .small_int = @intCast(@intFromPtr(buf)) });
    try inst.dict.setStr(a, "closed", Value{ .boolean = false });
    return Value{ .instance = inst };
}

// --- shared methods ---

fn ioTell(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const inst = try argInst(args);
    const buf = bufFromInstance(inst);
    return Value{ .small_int = @intCast(buf.pos) };
}

fn ioSeek(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const inst = try argInst(args);
    const buf = bufFromInstance(inst);
    if (args.len < 2 or args[1] != .small_int) return error.TypeError;
    const offset = args[1].small_int;
    const whence: i64 = if (args.len >= 3 and args[2] == .small_int) args[2].small_int else 0;
    const new_pos: i64 = switch (whence) {
        0 => offset,
        1 => @as(i64, @intCast(buf.pos)) + offset,
        2 => @as(i64, @intCast(buf.data.items.len)) + offset,
        else => return error.ValueError,
    };
    if (new_pos < 0) return error.ValueError;
    buf.pos = @intCast(new_pos);
    return Value{ .small_int = new_pos };
}

fn ioClose(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try argInst(args);
    const buf = bufFromInstance(inst);
    if (!buf.closed) {
        buf.data.deinit(a);
        buf.closed = true;
    }
    try inst.dict.setStr(a, "closed", Value{ .boolean = true });
    return Value.none;
}

// --- StringIO methods ---

fn strWrite(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try argInst(args);
    const buf = bufFromInstance(inst);
    if (args.len < 2 or args[1] != .str) return error.TypeError;
    const data = args[1].str.bytes;
    try writeAt(a, buf, data);
    return Value{ .small_int = @intCast(data.len) };
}

fn strWritelines(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try argInst(args);
    const buf = bufFromInstance(inst);
    if (args.len < 2 or args[1] != .list) return error.TypeError;
    for (args[1].list.items.items) |it| {
        if (it != .str) return error.TypeError;
        try writeAt(a, buf, it.str.bytes);
    }
    return Value.none;
}

fn writeAt(a: std.mem.Allocator, buf: *Buf, data: []const u8) !void {
    if (buf.pos == buf.data.items.len) {
        try buf.data.appendSlice(a, data);
    } else {
        // overwrite from pos, growing if necessary.
        const need = buf.pos + data.len;
        if (need > buf.data.items.len) try buf.data.resize(a, need);
        @memcpy(buf.data.items[buf.pos..need], data);
    }
    buf.pos += data.len;
}

fn strRead(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try argInst(args);
    const buf = bufFromInstance(inst);
    const remaining = buf.data.items.len - buf.pos;
    const want: usize = if (args.len >= 2 and args[1] == .small_int and args[1].small_int >= 0)
        @min(remaining, @as(usize, @intCast(args[1].small_int)))
    else
        remaining;
    const slice = buf.data.items[buf.pos .. buf.pos + want];
    const s = try Str.init(a, slice);
    buf.pos += want;
    return Value{ .str = s };
}

fn strReadline(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try argInst(args);
    const buf = bufFromInstance(inst);
    const start = buf.pos;
    var i = start;
    while (i < buf.data.items.len and buf.data.items[i] != '\n') : (i += 1) {}
    if (i < buf.data.items.len) i += 1; // include newline
    const slice = buf.data.items[start..i];
    const s = try Str.init(a, slice);
    buf.pos = i;
    return Value{ .str = s };
}

fn strReadlines(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try argInst(args);
    const buf = bufFromInstance(inst);
    const out = try List.init(a);
    while (buf.pos < buf.data.items.len) {
        const start = buf.pos;
        var i = start;
        while (i < buf.data.items.len and buf.data.items[i] != '\n') : (i += 1) {}
        if (i < buf.data.items.len) i += 1;
        const s = try Str.init(a, buf.data.items[start..i]);
        try out.append(a, Value{ .str = s });
        buf.pos = i;
    }
    return Value{ .list = out };
}

fn strGetvalue(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try argInst(args);
    const buf = bufFromInstance(inst);
    const s = try Str.init(a, buf.data.items);
    return Value{ .str = s };
}

// --- BytesIO methods ---

fn bytesWrite(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try argInst(args);
    const buf = bufFromInstance(inst);
    if (args.len < 2 or args[1] != .bytes) return error.TypeError;
    const data = args[1].bytes.data;
    try writeAt(a, buf, data);
    return Value{ .small_int = @intCast(data.len) };
}

fn bytesRead(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try argInst(args);
    const buf = bufFromInstance(inst);
    const remaining = buf.data.items.len - buf.pos;
    const want: usize = if (args.len >= 2 and args[1] == .small_int and args[1].small_int >= 0)
        @min(remaining, @as(usize, @intCast(args[1].small_int)))
    else
        remaining;
    const slice = buf.data.items[buf.pos .. buf.pos + want];
    const b = try Bytes.init(a, slice);
    buf.pos += want;
    return Value{ .bytes = b };
}

fn bytesGetvalue(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const inst = try argInst(args);
    const buf = bufFromInstance(inst);
    const b = try Bytes.init(a, buf.data.items);
    return Value{ .bytes = b };
}

