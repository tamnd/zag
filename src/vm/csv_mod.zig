//! Pinhole `csv`: reader/writer/DictReader/DictWriter. Targets that
//! receive `writerow` output use their `write` method; readers consume
//! any iterable of lines (lists, generators, file-like objects).

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const List = @import("../object/list.zig").List;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");
const dunder = @import("dunder.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "csv");
    try ensureClasses(interp);
    try regKw(interp, m, "reader", readerFn, null);
    try regKw(interp, m, "writer", writerFn, writerKw);
    try regKw(interp, m, "DictReader", dictReaderFn, dictReaderKw);
    try regKw(interp, m, "DictWriter", dictWriterFn, dictWriterKw);
    try m.attrs.setStr(interp.allocator, "QUOTE_MINIMAL", Value{ .small_int = 0 });
    try m.attrs.setStr(interp.allocator, "QUOTE_ALL", Value{ .small_int = 1 });
    try m.attrs.setStr(interp.allocator, "QUOTE_NONNUMERIC", Value{ .small_int = 2 });
    try m.attrs.setStr(interp.allocator, "QUOTE_NONE", Value{ .small_int = 3 });
    return m;
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: ?BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;
    if (interp.csv_writer_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "writerow", writerWriterow);
        try methodReg(a, d, "writerows", writerWriterows);
        interp.csv_writer_class = try Class.init(a, "_csv.writer", &.{}, d);
    }
    if (interp.csv_dict_writer_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "writeheader", dictWriterHeader);
        try methodReg(a, d, "writerow", dictWriterRow);
        try methodReg(a, d, "writerows", dictWriterRows);
        interp.csv_dict_writer_class = try Class.init(a, "DictWriter", &.{}, d);
    }
}

// --- dialect ---

fn dialectDelim(d: Value) u8 {
    if (d == .str) {
        const s = d.str.bytes;
        if (std.mem.eql(u8, s, "excel-tab")) return '\t';
    }
    return ',';
}

// --- reader ---

fn lineFromValue(v: Value) ![]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

fn stripEol(line: []const u8) []const u8 {
    var n = line.len;
    while (n > 0 and (line[n - 1] == '\n' or line[n - 1] == '\r')) n -= 1;
    return line[0..n];
}

fn parseCsvLine(a: std.mem.Allocator, raw: []const u8, delim: u8) !*List {
    const line = stripEol(raw);
    const out = try List.init(a);
    var field: std.ArrayList(u8) = .empty;
    defer field.deinit(a);
    var i: usize = 0;
    var in_quotes = false;
    var started = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_quotes) {
            if (c == '"') {
                if (i + 1 < line.len and line[i + 1] == '"') {
                    try field.append(a, '"');
                    i += 1;
                } else {
                    in_quotes = false;
                }
            } else {
                try field.append(a, c);
            }
        } else if (c == '"' and !started) {
            in_quotes = true;
            started = true;
        } else if (c == delim) {
            const s = try Str.init(a, field.items);
            try out.append(a, Value{ .str = s });
            field.clearRetainingCapacity();
            started = false;
        } else {
            try field.append(a, c);
            started = true;
        }
    }
    const s = try Str.init(a, field.items);
    try out.append(a, Value{ .str = s });
    return out;
}

fn collectLines(interp: *Interp, src: Value) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    switch (src) {
        .list => |l| for (l.items.items) |it| try out.append(interp.allocator, try lineFromValue(it)),
        .tuple => |t| for (t.items) |it| try out.append(interp.allocator, try lineFromValue(it)),
        else => {
            const it = try dispatch.makeIter(interp, src);
            const iv = Value{ .iter = it };
            while (try dispatch.iterStep(interp, iv)) |v| {
                try out.append(interp.allocator, try lineFromValue(v));
            }
        },
    }
    return out;
}

fn readerFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const delim: u8 = if (args.len >= 2) dialectDelim(args[1]) else ',';
    var lines = try collectLines(interp, args[0]);
    defer lines.deinit(a);
    const out = try List.init(a);
    for (lines.items) |line| {
        const row = try parseCsvLine(a, line, delim);
        try out.append(a, Value{ .list = row });
    }
    return Value{ .list = out };
}

// --- writer ---

fn fieldStr(a: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        .small_int => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        .boolean => |b| if (b) "True" else "False",
        .none => "",
        else => error.TypeError,
    };
}

fn writeCsvField(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8, delim: u8) !void {
    var needs_quote = false;
    for (s) |c| {
        if (c == delim or c == '"' or c == '\r' or c == '\n') {
            needs_quote = true;
            break;
        }
    }
    if (needs_quote) {
        try buf.append(a, '"');
        for (s) |c| {
            if (c == '"') try buf.append(a, '"');
            try buf.append(a, c);
        }
        try buf.append(a, '"');
    } else {
        try buf.appendSlice(a, s);
    }
}

fn buildRowStr(a: std.mem.Allocator, row: []const Value, delim: u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    for (row, 0..) |v, idx| {
        if (idx > 0) try buf.append(a, delim);
        const s = try fieldStr(a, v);
        try writeCsvField(a, &buf, s, delim);
    }
    try buf.append(a, '\r');
    try buf.append(a, '\n');
    return buf.toOwnedSlice(a);
}

fn writeToTarget(interp: *Interp, target: Value, payload: []const u8) !void {
    const s = try Str.init(interp.allocator, payload);
    _ = (try dunder.call(interp, target, "write", &.{Value{ .str = s }})) orelse {
        try interp.typeError("csv writer target has no write method");
        return error.TypeError;
    };
}

fn writerFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return writerKw(p, args, &.{}, &.{});
}

fn writerKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    if (args.len < 1) return error.TypeError;
    const a = interp.allocator;
    const inst = try Instance.init(a, interp.csv_writer_class.?);
    try inst.dict.setStr(a, "_target", args[0]);
    const delim: u8 = if (args.len >= 2) dialectDelim(args[1]) else ',';
    try inst.dict.setStr(a, "_delim", Value{ .small_int = @as(i64, delim) });
    return Value{ .instance = inst };
}

fn writerDelim(inst: *Instance) u8 {
    const v = inst.dict.getStr("_delim").?;
    return @intCast(v.small_int);
}

fn writerWriterow(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const target = inst.dict.getStr("_target").?;
    const delim = writerDelim(inst);
    const items: []const Value = switch (args[1]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    const s = try buildRowStr(a, items, delim);
    defer a.free(s);
    try writeToTarget(interp, target, s);
    return Value{ .small_int = @intCast(s.len) };
}

fn writerWriterows(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const target = inst.dict.getStr("_target").?;
    const delim = writerDelim(inst);
    const rows: []const Value = switch (args[1]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    for (rows) |row| {
        const items: []const Value = switch (row) {
            .list => |l| l.items.items,
            .tuple => |t| t.items,
            else => return error.TypeError,
        };
        const s = try buildRowStr(a, items, delim);
        defer a.free(s);
        try writeToTarget(interp, target, s);
    }
    return Value.none;
}

// --- DictReader ---

fn dictReaderFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dictReaderKw(p, args, &.{}, &.{});
}

fn dictReaderKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    var lines = try collectLines(interp, args[0]);
    defer lines.deinit(a);

    var fieldnames_val: ?Value = null;
    if (args.len >= 2) fieldnames_val = args[1];
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "fieldnames")) fieldnames_val = kv;
    }

    var idx: usize = 0;
    var headers: std.ArrayList([]const u8) = .empty;
    defer headers.deinit(a);
    if (fieldnames_val) |fv| switch (fv) {
        .list => |l| for (l.items.items) |it| {
            if (it != .str) return error.TypeError;
            try headers.append(a, it.str.bytes);
        },
        .tuple => |t| for (t.items) |it| {
            if (it != .str) return error.TypeError;
            try headers.append(a, it.str.bytes);
        },
        else => {},
    } else {
        if (lines.items.len == 0) return Value{ .list = try List.init(a) };
        const head_row = try parseCsvLine(a, lines.items[0], ',');
        for (head_row.items.items) |it| try headers.append(a, it.str.bytes);
        idx = 1;
    }

    const out = try List.init(a);
    while (idx < lines.items.len) : (idx += 1) {
        const row = try parseCsvLine(a, lines.items[idx], ',');
        const d = try Dict.init(a);
        for (headers.items, 0..) |h, i| {
            const val: Value = if (i < row.items.items.len)
                row.items.items[i]
            else
                Value{ .str = try Str.init(a, "") };
            try d.setStr(a, h, val);
        }
        try out.append(a, Value{ .dict = d });
    }
    return Value{ .list = out };
}

// --- DictWriter ---

fn dictWriterFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dictWriterKw(p, args, &.{}, &.{});
}

fn dictWriterKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const inst = try Instance.init(a, interp.csv_dict_writer_class.?);
    try inst.dict.setStr(a, "_target", args[0]);
    try inst.dict.setStr(a, "fieldnames", args[1]);
    try inst.dict.setStr(a, "_delim", Value{ .small_int = ',' });
    return Value{ .instance = inst };
}

fn dictWriterFieldnames(inst: *Instance) []const Value {
    const v = inst.dict.getStr("fieldnames").?;
    return switch (v) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => &.{},
    };
}

fn dictWriterHeader(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const target = inst.dict.getStr("_target").?;
    const fields = dictWriterFieldnames(inst);
    const s = try buildRowStr(a, fields, ',');
    defer a.free(s);
    try writeToTarget(interp, target, s);
    return Value.none;
}

fn dictWriterRow(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const target = inst.dict.getStr("_target").?;
    if (args[1] != .dict) return error.TypeError;
    const row_dict = args[1].dict;
    const fields = dictWriterFieldnames(inst);
    var row_buf: std.ArrayList(Value) = .empty;
    defer row_buf.deinit(a);
    for (fields) |fv| {
        const key = if (fv == .str) fv.str.bytes else return error.TypeError;
        const val: Value = row_dict.getStr(key) orelse Value{ .str = try Str.init(a, "") };
        try row_buf.append(a, val);
    }
    const s = try buildRowStr(a, row_buf.items, ',');
    defer a.free(s);
    try writeToTarget(interp, target, s);
    return Value.none;
}

fn dictWriterRows(p: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const rows: []const Value = switch (args[1]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    for (rows) |row| {
        _ = try dictWriterRow(p, &.{ args[0], row });
    }
    return Value.none;
}
