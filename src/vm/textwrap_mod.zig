//! Pinhole `textwrap` module. Implements the surface the fixtures
//! exercise: dedent, indent (with predicate), wrap/fill (with all
//! standard kwargs), shorten, and a TextWrapper class.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "textwrap");
    try reg(interp, m, "dedent", dedentFn);
    try regKw(interp, m, "indent", indentFn, indentKw);
    try regKw(interp, m, "wrap", wrapFn, wrapKw);
    try regKw(interp, m, "fill", fillFn, fillKw);
    try regKw(interp, m, "shorten", shortenFn, shortenKw);
    try regKw(interp, m, "TextWrapper", textWrapperFn, textWrapperKw);
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

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn methodRegKw(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn argStr(v: Value) ![]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

// --- dedent ---

fn dedentFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const text = try argStr(args[0]);

    var common: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (isBlankLine(line)) continue;
        const lead = leadingWs(line);
        if (common) |c| {
            common = commonPrefix(c, lead);
        } else {
            common = lead;
        }
    }
    const prefix_len: usize = if (common) |c| c.len else 0;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var first = true;
    var it2 = std.mem.splitScalar(u8, text, '\n');
    while (it2.next()) |line| {
        if (!first) try buf.append(a, '\n');
        first = false;
        if (isBlankLine(line)) {
            if (line.len >= prefix_len and std.mem.eql(u8, line[0..prefix_len], (common orelse ""))) {
                try buf.appendSlice(a, line[prefix_len..]);
            } else {
                try buf.appendSlice(a, line);
            }
        } else {
            try buf.appendSlice(a, line[prefix_len..]);
        }
    }
    const s = try Str.init(a, buf.items);
    return Value{ .str = s };
}

fn isBlankLine(line: []const u8) bool {
    for (line) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn leadingWs(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return line[0..i];
}

fn commonPrefix(a: []const u8, b: []const u8) []const u8 {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) : (i += 1) {}
    return a[0..i];
}

// --- indent ---

fn indentFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return indentKw(p, args, &.{}, &.{});
}

fn indentKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return error.TypeError;
    const text = try argStr(args[0]);
    const prefix = try argStr(args[1]);
    var predicate: ?Value = null;
    if (args.len >= 3) predicate = args[2];
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "predicate")) predicate = kv;
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);

    var i: usize = 0;
    while (i < text.len) {
        var j = i;
        while (j < text.len and text[j] != '\n') : (j += 1) {}
        const has_nl = j < text.len;
        const line_end = if (has_nl) j + 1 else j;
        const line = text[i..line_end];

        var apply: bool = false;
        if (predicate) |pred_v| {
            if (pred_v != .none) {
                const line_str = try Str.init(a, line);
                const r = try dispatch.invoke(interp, pred_v, &.{Value{ .str = line_str }});
                apply = r.isTruthy();
            } else {
                apply = !isBlankLineFull(line);
            }
        } else {
            apply = !isBlankLineFull(line);
        }

        if (apply) try buf.appendSlice(a, prefix);
        try buf.appendSlice(a, line);
        i = line_end;
    }

    const s = try Str.init(a, buf.items);
    return Value{ .str = s };
}

fn isBlankLineFull(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != 0x0b and c != 0x0c) return false;
    }
    return true;
}

// --- wrap / fill / shorten / TextWrapper ---

const WrapConfig = struct {
    width: usize = 70,
    initial_indent: []const u8 = "",
    subsequent_indent: []const u8 = "",
    expand_tabs: bool = true,
    tabsize: usize = 8,
    replace_whitespace: bool = true,
    drop_whitespace: bool = true,
    max_lines: ?usize = null,
    placeholder: []const u8 = " [...]",
    break_long_words: bool = true,
    break_on_hyphens: bool = true,
};

fn parseWrapKw(cfg: *WrapConfig, kw_names: []const Value, kw_values: []const Value) void {
    for (kw_names, kw_values) |n, v| {
        if (n != .str) continue;
        const nm = n.str.bytes;
        if (std.mem.eql(u8, nm, "width")) {
            if (v == .small_int and v.small_int > 0) cfg.width = @intCast(v.small_int);
        } else if (std.mem.eql(u8, nm, "initial_indent")) {
            if (v == .str) cfg.initial_indent = v.str.bytes;
        } else if (std.mem.eql(u8, nm, "subsequent_indent")) {
            if (v == .str) cfg.subsequent_indent = v.str.bytes;
        } else if (std.mem.eql(u8, nm, "expand_tabs")) {
            cfg.expand_tabs = v.isTruthy();
        } else if (std.mem.eql(u8, nm, "tabsize")) {
            if (v == .small_int and v.small_int > 0) cfg.tabsize = @intCast(v.small_int);
        } else if (std.mem.eql(u8, nm, "replace_whitespace")) {
            cfg.replace_whitespace = v.isTruthy();
        } else if (std.mem.eql(u8, nm, "drop_whitespace")) {
            cfg.drop_whitespace = v.isTruthy();
        } else if (std.mem.eql(u8, nm, "max_lines")) {
            if (v == .small_int and v.small_int > 0) cfg.max_lines = @intCast(v.small_int);
        } else if (std.mem.eql(u8, nm, "placeholder")) {
            if (v == .str) cfg.placeholder = v.str.bytes;
        } else if (std.mem.eql(u8, nm, "break_long_words")) {
            cfg.break_long_words = v.isTruthy();
        } else if (std.mem.eql(u8, nm, "break_on_hyphens")) {
            cfg.break_on_hyphens = v.isTruthy();
        }
    }
}

fn parseWrapPositional(cfg: *WrapConfig, args: []const Value) void {
    if (args.len >= 2) {
        if (args[1] == .small_int and args[1].small_int > 0) cfg.width = @intCast(args[1].small_int);
    }
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

fn expandTabs(a: std.mem.Allocator, text: []const u8, tabsize: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var col: usize = 0;
    for (text) |c| {
        if (c == '\t') {
            const spaces = if (tabsize == 0) 0 else tabsize - (col % tabsize);
            try out.appendNTimes(a, ' ', spaces);
            col += spaces;
        } else if (c == '\n') {
            try out.append(a, c);
            col = 0;
        } else {
            try out.append(a, c);
            col += 1;
        }
    }
    return out.toOwnedSlice(a);
}

fn replaceWs(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try a.alloc(u8, text.len);
    for (text, 0..) |c, i| {
        out[i] = if (isSpace(c)) ' ' else c;
    }
    return out;
}

fn splitChunks(a: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        const is_sp = text[i] == ' ';
        while (i < text.len and (text[i] == ' ') == is_sp) : (i += 1) {}
        try out.append(a, text[start..i]);
    }
    return out.toOwnedSlice(a);
}

fn wrapCore(a: std.mem.Allocator, raw_text: []const u8, cfg: WrapConfig) ![][]u8 {
    var owned1: ?[]u8 = null;
    defer if (owned1) |o| a.free(o);
    var owned2: ?[]u8 = null;
    defer if (owned2) |o| a.free(o);

    var t: []const u8 = raw_text;
    if (cfg.expand_tabs) {
        const e = try expandTabs(a, t, cfg.tabsize);
        owned1 = e;
        t = e;
    }
    if (cfg.replace_whitespace) {
        const r = try replaceWs(a, t);
        owned2 = r;
        t = r;
    }

    const chunks = try splitChunks(a, t);
    defer a.free(chunks);

    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(a);
    var ci: usize = chunks.len;
    while (ci > 0) : (ci -= 1) try stack.append(a, chunks[ci - 1]);

    var lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (lines.items) |l| a.free(l);
        lines.deinit(a);
    }

    while (stack.items.len > 0) {
        const indent: []const u8 = if (lines.items.len == 0) cfg.initial_indent else cfg.subsequent_indent;
        const width: usize = if (cfg.width > indent.len) cfg.width - indent.len else 1;

        if (cfg.drop_whitespace and lines.items.len > 0 and stack.items.len > 0) {
            const top = stack.items[stack.items.len - 1];
            if (top.len > 0 and top[0] == ' ') _ = stack.pop();
        }

        var cur: std.ArrayList([]const u8) = .empty;
        defer cur.deinit(a);
        var cur_len: usize = 0;

        while (stack.items.len > 0) {
            const top = stack.items[stack.items.len - 1];
            if (cur_len + top.len <= width) {
                _ = stack.pop();
                try cur.append(a, top);
                cur_len += top.len;
            } else {
                break;
            }
        }

        // Long word handling.
        if (stack.items.len > 0 and stack.items[stack.items.len - 1].len > width and cfg.break_long_words) {
            const space_left: usize = if (width > cur_len) width - cur_len else 0;
            if (space_left > 0) {
                const top = stack.pop().?;
                const end = @min(space_left, top.len);
                try cur.append(a, top[0..end]);
                cur_len += end;
                if (end < top.len) try stack.append(a, top[end..]);
            }
        }

        if (cfg.drop_whitespace and cur.items.len > 0) {
            const last = cur.items[cur.items.len - 1];
            if (last.len > 0 and last[0] == ' ') {
                cur_len -= last.len;
                _ = cur.pop();
            }
        }

        if (cur.items.len == 0) continue;

        const max_reached = if (cfg.max_lines) |ml| (lines.items.len + 1 == ml and stack.items.len > 0) else false;

        if (!max_reached) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(a);
            try buf.appendSlice(a, indent);
            for (cur.items) |c| try buf.appendSlice(a, c);
            const owned = try buf.toOwnedSlice(a);
            try lines.append(a, owned);
            continue;
        }

        // max_lines exhausted: try to fit placeholder onto this line.
        var placed = false;
        while (cur.items.len > 0) {
            const last = cur.items[cur.items.len - 1];
            const last_blank = blk: {
                for (last) |c| if (c != ' ') break :blk false;
                break :blk true;
            };
            if (!last_blank and cur_len + cfg.placeholder.len <= width) {
                try cur.append(a, cfg.placeholder);
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(a);
                try buf.appendSlice(a, indent);
                for (cur.items) |c| try buf.appendSlice(a, c);
                const owned = try buf.toOwnedSlice(a);
                try lines.append(a, owned);
                placed = true;
                break;
            }
            cur_len -= last.len;
            _ = cur.pop();
        }

        if (!placed) {
            // Try appending placeholder to previous line.
            if (lines.items.len > 0) {
                const prev = lines.items[lines.items.len - 1];
                const trimmed = std.mem.trimEnd(u8, prev, " \t");
                if (trimmed.len + cfg.placeholder.len <= cfg.width) {
                    const np = try std.fmt.allocPrint(a, "{s}{s}", .{ trimmed, cfg.placeholder });
                    a.free(prev);
                    lines.items[lines.items.len - 1] = np;
                } else {
                    const ph_lstripped = std.mem.trimStart(u8, cfg.placeholder, " \t");
                    const owned = try a.dupe(u8, ph_lstripped);
                    try lines.append(a, owned);
                }
            } else {
                const ph_lstripped = std.mem.trimStart(u8, cfg.placeholder, " \t");
                const owned = try a.dupe(u8, ph_lstripped);
                try lines.append(a, owned);
            }
        }
        break;
    }

    return lines.toOwnedSlice(a);
}

fn wrapFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return wrapKw(p, args, &.{}, &.{});
}

fn wrapKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const text = try argStr(args[0]);
    var cfg = WrapConfig{};
    parseWrapPositional(&cfg, args);
    parseWrapKw(&cfg, kw_names, kw_values);

    const lines = try wrapCore(a, text, cfg);
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }

    const out = try List.init(a);
    for (lines) |line| {
        const s = try Str.init(a, line);
        try out.append(a, Value{ .str = s });
    }
    return Value{ .list = out };
}

fn fillFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return fillKw(p, args, &.{}, &.{});
}

fn fillKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const text = try argStr(args[0]);
    var cfg = WrapConfig{};
    parseWrapPositional(&cfg, args);
    parseWrapKw(&cfg, kw_names, kw_values);

    const lines = try wrapCore(a, text, cfg);
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    for (lines, 0..) |line, i| {
        if (i > 0) try buf.append(a, '\n');
        try buf.appendSlice(a, line);
    }
    const s = try Str.init(a, buf.items);
    return Value{ .str = s };
}

// shorten: collapse whitespace, then wrap with max_lines=1.
fn shortenFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return shortenKw(p, args, &.{}, &.{});
}

fn shortenKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const text = try argStr(args[0]);
    var cfg = WrapConfig{};
    parseWrapPositional(&cfg, args);
    parseWrapKw(&cfg, kw_names, kw_values);
    cfg.max_lines = 1;

    // Collapse runs of whitespace to single space and strip ends:
    // ' '.join(text.strip().split())
    var collapsed: std.ArrayList(u8) = .empty;
    defer collapsed.deinit(a);
    var i: usize = 0;
    while (i < text.len and isSpace(text[i])) : (i += 1) {}
    while (i < text.len) {
        if (isSpace(text[i])) {
            try collapsed.append(a, ' ');
            while (i < text.len and isSpace(text[i])) : (i += 1) {}
        } else {
            try collapsed.append(a, text[i]);
            i += 1;
        }
    }
    if (collapsed.items.len > 0 and collapsed.items[collapsed.items.len - 1] == ' ') {
        _ = collapsed.pop();
    }

    const lines = try wrapCore(a, collapsed.items, cfg);
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    for (lines, 0..) |line, j| {
        if (j > 0) try buf.append(a, '\n');
        try buf.appendSlice(a, line);
    }
    const s = try Str.init(a, buf.items);
    return Value{ .str = s };
}

// --- TextWrapper ---

fn ensureWrapperClass(interp: *Interp) !void {
    if (interp.textwrap_wrapper_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "wrap", twWrap);
    try methodReg(a, d, "fill", twFill);
    interp.textwrap_wrapper_class = try Class.init(a, "TextWrapper", &.{}, d);
}

fn textWrapperFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return textWrapperKw(p, args, &.{}, &.{});
}

fn textWrapperKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    try ensureWrapperClass(interp);
    const inst = try Instance.init(a, interp.textwrap_wrapper_class.?);

    var cfg = WrapConfig{};
    parseWrapKw(&cfg, kw_names, kw_values);

    try inst.dict.setStr(a, "width", Value{ .small_int = @intCast(cfg.width) });
    {
        const s = try Str.init(a, cfg.initial_indent);
        try inst.dict.setStr(a, "initial_indent", Value{ .str = s });
    }
    {
        const s = try Str.init(a, cfg.subsequent_indent);
        try inst.dict.setStr(a, "subsequent_indent", Value{ .str = s });
    }
    {
        const s = try Str.init(a, cfg.placeholder);
        try inst.dict.setStr(a, "placeholder", Value{ .str = s });
    }
    if (cfg.max_lines) |ml| {
        try inst.dict.setStr(a, "max_lines", Value{ .small_int = @intCast(ml) });
    } else {
        try inst.dict.setStr(a, "max_lines", Value.none);
    }
    try inst.dict.setStr(a, "expand_tabs", Value{ .boolean = cfg.expand_tabs });
    try inst.dict.setStr(a, "tabsize", Value{ .small_int = @intCast(cfg.tabsize) });
    try inst.dict.setStr(a, "replace_whitespace", Value{ .boolean = cfg.replace_whitespace });
    try inst.dict.setStr(a, "drop_whitespace", Value{ .boolean = cfg.drop_whitespace });
    try inst.dict.setStr(a, "break_long_words", Value{ .boolean = cfg.break_long_words });
    try inst.dict.setStr(a, "break_on_hyphens", Value{ .boolean = cfg.break_on_hyphens });
    return Value{ .instance = inst };
}

fn instanceWrapConfig(inst: *Instance) WrapConfig {
    var cfg = WrapConfig{};
    if (inst.dict.getStr("width")) |v| if (v == .small_int and v.small_int > 0) {
        cfg.width = @intCast(v.small_int);
    };
    if (inst.dict.getStr("initial_indent")) |v| if (v == .str) {
        cfg.initial_indent = v.str.bytes;
    };
    if (inst.dict.getStr("subsequent_indent")) |v| if (v == .str) {
        cfg.subsequent_indent = v.str.bytes;
    };
    if (inst.dict.getStr("placeholder")) |v| if (v == .str) {
        cfg.placeholder = v.str.bytes;
    };
    if (inst.dict.getStr("max_lines")) |v| {
        if (v == .small_int and v.small_int > 0) cfg.max_lines = @intCast(v.small_int)
        else if (v == .none) cfg.max_lines = null;
    }
    if (inst.dict.getStr("expand_tabs")) |v| cfg.expand_tabs = v.isTruthy();
    if (inst.dict.getStr("tabsize")) |v| if (v == .small_int and v.small_int > 0) {
        cfg.tabsize = @intCast(v.small_int);
    };
    if (inst.dict.getStr("replace_whitespace")) |v| cfg.replace_whitespace = v.isTruthy();
    if (inst.dict.getStr("drop_whitespace")) |v| cfg.drop_whitespace = v.isTruthy();
    if (inst.dict.getStr("break_long_words")) |v| cfg.break_long_words = v.isTruthy();
    if (inst.dict.getStr("break_on_hyphens")) |v| cfg.break_on_hyphens = v.isTruthy();
    return cfg;
}

fn twWrap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const text = try argStr(args[1]);
    const cfg = instanceWrapConfig(args[0].instance);
    const lines = try wrapCore(a, text, cfg);
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }
    const out = try List.init(a);
    for (lines) |line| {
        const s = try Str.init(a, line);
        try out.append(a, Value{ .str = s });
    }
    return Value{ .list = out };
}

fn twFill(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const text = try argStr(args[1]);
    const cfg = instanceWrapConfig(args[0].instance);
    const lines = try wrapCore(a, text, cfg);
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    for (lines, 0..) |line, i| {
        if (i > 0) try buf.append(a, '\n');
        try buf.appendSlice(a, line);
    }
    const s = try Str.init(a, buf.items);
    return Value{ .str = s };
}
