//! Pinhole `traceback` module: format_exc, print_exc, TracebackException,
//! extract_tb, format_tb. Leverages the synthetic traceback chain already
//! stored on exception instances by traceback.zig.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

// ===== Format a traceback chain and exception as a string =====

fn formatExcFromValue(interp: *Interp, exc: Value) ![]u8 {
    const a = interp.allocator;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "Traceback (most recent call last):\n");
    if (exc == .instance) {
        // Walk __traceback__ chain (outermost first -- our chain is innermost first)
        // For simplicity, just emit one frame
        if (exc.instance.dict.getStr("__traceback__")) |tb_v| {
            if (tb_v == .instance) {
                const tb = tb_v.instance;
                if (tb.dict.getStr("tb_frame")) |frame_v| {
                    if (frame_v == .instance) {
                        const fr = frame_v.instance;
                        const filename = if (fr.dict.getStr("f_code")) |code_v|
                            if (code_v == .instance) code_v.instance.dict.getStr("co_filename") orelse Value.none else Value.none
                        else Value.none;
                        const lineno = if (fr.dict.getStr("f_lineno")) |ln| ln else Value{ .small_int = 0 };
                        const fn_name = if (fr.dict.getStr("f_code")) |code_v|
                            if (code_v == .instance) code_v.instance.dict.getStr("co_name") orelse Value.none else Value.none
                        else Value.none;
                        const fname = if (filename == .str) filename.str.bytes else "<unknown>";
                        const lno: i64 = if (lineno == .small_int) lineno.small_int else 0;
                        const fn_s = if (fn_name == .str) fn_name.str.bytes else "<module>";
                        const line = try std.fmt.allocPrint(a, "  File \"{s}\", line {d}, in {s}\n", .{ fname, lno, fn_s });
                        defer a.free(line);
                        try buf.appendSlice(a, line);
                    }
                }
            }
        }
        // Exception type and message
        const cls_name = exc.instance.cls.name;
        if (exc.instance.dict.getStr("args")) |args_v| {
            if (args_v == .tuple and args_v.tuple.items.len > 0) {
                const msg = args_v.tuple.items[0];
                const line = switch (msg) {
                    .str => |s| try std.fmt.allocPrint(a, "{s}: {s}\n", .{ cls_name, s.bytes }),
                    .small_int => |i| try std.fmt.allocPrint(a, "{s}: {d}\n", .{ cls_name, i }),
                    else => try std.fmt.allocPrint(a, "{s}\n", .{cls_name}),
                };
                defer a.free(line);
                try buf.appendSlice(a, line);
            } else {
                const line = try std.fmt.allocPrint(a, "{s}\n", .{cls_name});
                defer a.free(line);
                try buf.appendSlice(a, line);
            }
        } else {
            const line = try std.fmt.allocPrint(a, "{s}\n", .{cls_name});
            defer a.free(line);
            try buf.appendSlice(a, line);
        }
    }
    return buf.toOwnedSlice(a);
}

// ===== format_exc =====

fn formatExcFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const exc = interp.handling_exc orelse {
        return Value{ .str = try Str.init(a, "NoneType: None\n") };
    };
    const s = try formatExcFromValue(interp, exc);
    const str = try Str.init(a, s);
    a.free(s);
    return Value{ .str = str };
}

// ===== print_exc =====

fn printExcKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    // Find file= kwarg
    var file_v: Value = Value.none;
    for (kn, kv) |k, v| {
        if (k == .str and std.mem.eql(u8, k.str.bytes, "file")) file_v = v;
    }
    _ = args;
    const text = try formatExcFn(p, &.{});
    const text_s = if (text == .str) text.str.bytes else "";
    // Write to file if given, else stdout
    if (file_v != .none and file_v == .instance) {
        // Try calling file_v.write(text)
        _ = try dispatch.invoke(interp, try dispatch.loadAttrValue(interp, file_v, "write"), &.{text});
    } else {
        try interp.stdout.writeAll(text_s);
        try interp.stdout.flush();
    }
    _ = a;
    return Value.none;
}

fn printExcFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return printExcKw(p, args, &.{}, &.{});
}

// ===== TracebackException =====

fn teFromExcFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    // args[0] = cls (classmethod injects class), args[1] = exc
    const exc = if (args.len >= 2) args[1] else if (args.len >= 1) args[0] else Value.none;
    const cls_name: []const u8 = if (exc == .instance) exc.instance.cls.name else "Exception";
    const te_cls = interp.traceback_te_class orelse blk: {
        const d = try Dict.init(a);
        const c = try Class.init(a, "TracebackException", &.{}, d);
        interp.traceback_te_class = c;
        break :blk c;
    };
    const te = try Instance.init(a, te_cls);
    try te.dict.setStr(a, "exc_type_str", Value{ .str = try Str.init(a, cls_name) });
    // Store the exception for format()
    if (exc == .instance) {
        try te.dict.setStr(a, "_exc", exc);
    }
    return Value{ .instance = te };
}

fn teFormatFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .list = try List.init(a) };
    const self = args[0].instance;
    const exc_v = self.dict.getStr("_exc") orelse Value.none;
    const formatted = try formatExcFromValue(interp, exc_v);
    const str_v = Value{ .str = try Str.init(a, formatted) };
    a.free(formatted);
    const lst = try List.init(a);
    try lst.items.append(a, str_v);
    return Value{ .list = lst };
}

// ===== extract_tb / format_tb =====

fn extractTbFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const lst = try List.init(a);
    if (args.len < 1 or args[0] == .none) return Value{ .list = lst };
    var tb_v = args[0];
    while (tb_v == .instance) {
        const tb = tb_v.instance;
        // Create FrameSummary-like tuple (filename, lineno, name, text)
        const t = try Tuple.init(a, 4);
        const filename = blk: {
            if (tb.dict.getStr("tb_frame")) |fr_v| {
                if (fr_v == .instance) {
                    if (fr_v.instance.dict.getStr("f_code")) |cd| {
                        if (cd == .instance) {
                            if (cd.instance.dict.getStr("co_filename")) |f| break :blk f;
                        }
                    }
                }
            }
            break :blk Value{ .str = try Str.init(a, "<unknown>") };
        };
        const lineno = if (tb.dict.getStr("tb_lineno")) |ln| ln else Value{ .small_int = 0 };
        const fn_name = blk: {
            if (tb.dict.getStr("tb_frame")) |fr_v| {
                if (fr_v == .instance) {
                    if (fr_v.instance.dict.getStr("f_code")) |cd| {
                        if (cd == .instance) {
                            if (cd.instance.dict.getStr("co_name")) |f| break :blk f;
                        }
                    }
                }
            }
            break :blk Value{ .str = try Str.init(a, "<module>") };
        };
        t.items[0] = filename;
        t.items[1] = lineno;
        t.items[2] = fn_name;
        t.items[3] = Value.none;
        try lst.items.append(a, Value{ .tuple = t });
        tb_v = tb.dict.getStr("tb_next") orelse Value.none;
    }
    return Value{ .list = lst };
}

fn formatTbFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const frames_v = try extractTbFn(p, args);
    const lst = try List.init(a);
    if (frames_v == .list) {
        for (frames_v.list.items.items) |frame| {
            if (frame == .tuple and frame.tuple.items.len >= 3) {
                const fn_s = if (frame.tuple.items[2] == .str) frame.tuple.items[2].str.bytes else "<module>";
                const line_s = if (frame.tuple.items[1] == .small_int)
                    try std.fmt.allocPrint(a, "  File ..., line {d}, in {s}\n", .{ frame.tuple.items[1].small_int, fn_s })
                else
                    try a.dupe(u8, "  File ...\n");
                defer a.free(line_s);
                try lst.items.append(a, Value{ .str = try Str.init(a, line_s) });
            }
        }
    }
    return Value{ .list = lst };
}

fn reg(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "traceback");

    try reg(a, m, "format_exc", formatExcFn);
    try regKw(a, m, "print_exc", printExcFn, printExcKw);
    try reg(a, m, "extract_tb", extractTbFn);
    try reg(a, m, "format_tb", formatTbFn);

    // TracebackException class
    const te_cls = interp.traceback_te_class orelse blk: {
        const d = try Dict.init(a);
        const c = try Class.init(a, "TracebackException", &.{}, d);
        interp.traceback_te_class = c;
        break :blk c;
    };
    // from_exception classmethod
    {
        const f = try a.create(BuiltinFn);
        f.* = .{ .name = "from_exception", .func = teFromExcFn };
        const Descriptor = @import("../object/descriptor.zig").Descriptor;
        const desc = try Descriptor.init(a, .classmethod, Value{ .builtin_fn = f });
        try te_cls.dict.setStr(a, "from_exception", Value{ .descriptor = desc });
    }
    // format() instance method
    {
        const f = try a.create(BuiltinFn);
        f.* = .{ .name = "format", .func = teFormatFn };
        try te_cls.dict.setStr(a, "format", Value{ .builtin_fn = f });
    }
    // exc_type property stub (deprecated in 3.13+, replaced by exc_type_str)
    try m.attrs.setStr(a, "TracebackException", Value{ .class = te_cls });

    // StackSummary = list alias
    // format_list stub
    try reg(a, m, "format_list", formatTbFn);

    // sys reference
    const sys_m = interp.getBuiltinModule("sys") orelse return error.ModuleNotFound;
    try m.attrs.setStr(a, "sys", Value{ .module = sys_m });

    return m;
}
