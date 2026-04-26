//! Pinhole `string` module: just the constants the fixture prints.
//! `string.Formatter` / `Template` etc. wait for a fixture.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Tuple = @import("../object/tuple.zig").Tuple;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const List = @import("../object/list.zig").List;
const Iter = @import("../object/iter.zig").Iter;
const Interp = @import("interp.zig").Interp;
const strmethods = @import("strmethods.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "string");
    const a = interp.allocator;
    try setStr(a, m, "ascii_lowercase", "abcdefghijklmnopqrstuvwxyz");
    try setStr(a, m, "ascii_uppercase", "ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    try setStr(a, m, "ascii_letters", "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ");
    try setStr(a, m, "digits", "0123456789");
    try setStr(a, m, "hexdigits", "0123456789abcdefABCDEF");
    try setStr(a, m, "octdigits", "01234567");
    try setStr(a, m, "punctuation", "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~");
    try setStr(a, m, "whitespace", " \t\n\r\x0b\x0c");
    // CPython: digits + letters + punctuation + whitespace.
    try setStr(a, m, "printable", "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~ \t\n\r\x0b\x0c");
    try reg(interp, m, "capwords", capwordsFn);

    try ensureFormatterClass(interp);
    try reg(interp, m, "Formatter", formatterCtor);

    try ensureTemplateClass(interp);
    try reg(interp, m, "Template", templateCtor);
    return m;
}

fn setStr(a: std.mem.Allocator, m: *Module, name: []const u8, val: []const u8) !void {
    const s = try Str.init(a, val);
    try m.attrs.setStr(a, name, Value{ .str = s });
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn isAsciiSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 11 or c == 12;
}

fn capitalize(out: *std.ArrayList(u8), a: std.mem.Allocator, word: []const u8) !void {
    if (word.len == 0) return;
    const first = word[0];
    const upper: u8 = if (first >= 'a' and first <= 'z') first - 32 else first;
    try out.append(a, upper);
    for (word[1..]) |c| {
        const lower: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
        try out.append(a, lower);
    }
}

// --- Formatter class ---

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn methodRegKw(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr, kw_func: value_mod.BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn ensureFormatterClass(interp: *Interp) !void {
    if (interp.string_formatter_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodRegKw(a, d, "format", formatterFormat, formatterFormatKw);
    try methodReg(a, d, "vformat", formatterVformat);
    try methodReg(a, d, "format_field", formatterFormatField);
    try methodReg(a, d, "convert_field", formatterConvertField);
    try methodReg(a, d, "parse", formatterParse);
    try methodReg(a, d, "get_value", formatterGetValue);
    try methodReg(a, d, "check_unused_args", formatterCheckUnusedArgs);
    interp.string_formatter_class = try Class.init(a, "Formatter", &.{}, d);
}

fn formatterCtor(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureFormatterClass(interp);
    const inst = try Instance.init(interp.allocator, interp.string_formatter_class.?);
    return Value{ .instance = inst };
}

fn formatterFormat(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[1] != .str) {
        try interp.typeError("Formatter.format expects a string");
        return error.TypeError;
    }
    return strmethods.formatTemplate(interp, args[1].str.bytes, args[2..], &.{}, &.{});
}

fn formatterFormatKw(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[1] != .str) {
        try interp.typeError("Formatter.format expects a string");
        return error.TypeError;
    }
    return strmethods.formatTemplate(interp, args[1].str.bytes, args[2..], kw_names, kw_values);
}

fn formatterVformat(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 4 or args[1] != .str) {
        try interp.typeError("vformat expects (template, args, kwargs)");
        return error.TypeError;
    }
    const template = args[1].str.bytes;
    const positional: []const Value = switch (args[2]) {
        .tuple => |t| t.items,
        .list => |l| l.items.items,
        else => &.{},
    };
    var kw_names: std.ArrayList(Value) = .empty;
    defer kw_names.deinit(interp.allocator);
    var kw_values: std.ArrayList(Value) = .empty;
    defer kw_values.deinit(interp.allocator);
    if (args[3] == .dict) {
        for (args[3].dict.pairs.items) |pair| {
            try kw_names.append(interp.allocator, pair.key);
            try kw_values.append(interp.allocator, pair.value);
        }
    }
    return strmethods.formatTemplate(interp, template, positional, kw_names.items, kw_values.items);
}

fn formatterFormatField(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 3 or args[2] != .str) {
        try interp.typeError("format_field expects (value, spec)");
        return error.TypeError;
    }
    return strmethods.formatOne(interp, args[1], args[2].str.bytes);
}

fn formatterConvertField(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 3) {
        try interp.typeError("convert_field expects (value, conv)");
        return error.TypeError;
    }
    if (args[2] == .none) return args[1];
    if (args[2] != .str or args[2].str.bytes.len != 1) {
        try interp.typeError("convert_field conversion must be a 1-char string or None");
        return error.TypeError;
    }
    return strmethods.convertField(interp, args[1], args[2].str.bytes[0]);
}

fn formatterParse(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[1] != .str) {
        try interp.typeError("parse expects a string");
        return error.TypeError;
    }
    const a = interp.allocator;
    const template = args[1].str.bytes;
    const out = try List.init(a);

    var lit_buf: std.ArrayList(u8) = .empty;
    defer lit_buf.deinit(a);

    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c == '{') {
            if (i + 1 < template.len and template[i + 1] == '{') {
                try lit_buf.append(a, '{');
                i += 2;
                continue;
            }
            // Flush a tuple for this field.
            const end = findClose(template, i + 1) orelse {
                try interp.typeError("unmatched '{' in format");
                return error.TypeError;
            };
            const body = template[i + 1 .. end];
            i = end + 1;
            // Split body into field_name, conversion, format_spec.
            var name_end = body.len;
            var conv_char: ?u8 = null;
            var spec_start: ?usize = null;
            var depth: usize = 0;
            var k: usize = 0;
            while (k < body.len) : (k += 1) {
                const bc = body[k];
                if (bc == '{') depth += 1
                else if (bc == '}') depth -= 1
                else if (depth == 0) {
                    if (bc == '!' and conv_char == null and spec_start == null) {
                        name_end = k;
                        if (k + 1 < body.len) conv_char = body[k + 1];
                    } else if (bc == ':' and spec_start == null) {
                        if (conv_char == null) name_end = k;
                        spec_start = k + 1;
                    }
                }
            }
            const literal_bytes = try a.dupe(u8, lit_buf.items);
            lit_buf.clearRetainingCapacity();
            const field_name = body[0..name_end];
            const spec_bytes = if (spec_start) |s| body[s..] else "";
            const tup = try Tuple.init(a, 4);
            tup.items[0] = Value{ .str = try Str.fromOwnedSlice(a, literal_bytes) };
            tup.items[1] = Value{ .str = try Str.init(a, field_name) };
            tup.items[2] = Value{ .str = try Str.init(a, spec_bytes) };
            tup.items[3] = if (conv_char) |cc|
                Value{ .str = try Str.init(a, &[_]u8{cc}) }
            else
                Value.none;
            try out.append(a, Value{ .tuple = tup });
        } else if (c == '}') {
            if (i + 1 < template.len and template[i + 1] == '}') {
                try lit_buf.append(a, '}');
                i += 2;
                continue;
            }
            try interp.typeError("single '}' in format");
            return error.TypeError;
        } else {
            try lit_buf.append(a, c);
            i += 1;
        }
    }
    if (lit_buf.items.len > 0) {
        const literal_bytes = try a.dupe(u8, lit_buf.items);
        const tup = try Tuple.init(a, 4);
        tup.items[0] = Value{ .str = try Str.fromOwnedSlice(a, literal_bytes) };
        tup.items[1] = Value.none;
        tup.items[2] = Value.none;
        tup.items[3] = Value.none;
        try out.append(a, Value{ .tuple = tup });
    }
    return Value{ .list = out };
}

fn findClose(s: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '{') depth += 1
        else if (c == '}') {
            if (depth == 0) return i;
            depth -= 1;
        }
    }
    return null;
}

fn formatterGetValue(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 4) {
        try interp.typeError("get_value expects (key, args, kwargs)");
        return error.TypeError;
    }
    const key = args[1];
    const args_v = args[2];
    const kwargs = args[3];
    if (key == .small_int or key == .boolean) {
        const idx: i64 = if (key == .boolean) @intFromBool(key.boolean) else key.small_int;
        const items: []const Value = switch (args_v) {
            .tuple => |t| t.items,
            .list => |l| l.items.items,
            else => &.{},
        };
        if (idx < 0 or idx >= @as(i64, @intCast(items.len))) {
            try interp.indexError("tuple index out of range");
            return error.IndexError;
        }
        return items[@intCast(idx)];
    }
    if (key == .str and kwargs == .dict) {
        if (kwargs.dict.getStr(key.str.bytes)) |v| return v;
        try interp.raisePy("KeyError", key.str.bytes);
        return error.PyException;
    }
    try interp.typeError("get_value: unsupported key type");
    return error.TypeError;
}

fn formatterCheckUnusedArgs(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

// --- Template class ---

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn ensureTemplateClass(interp: *Interp) !void {
    if (interp.string_template_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodRegKw(a, d, "substitute", templateSubstitute, templateSubstituteKw);
    try methodRegKw(a, d, "safe_substitute", templateSafeSubstitute, templateSafeSubstituteKw);
    try methodReg(a, d, "is_valid", templateIsValid);
    try methodReg(a, d, "get_identifiers", templateGetIdentifiers);
    interp.string_template_class = try Class.init(a, "Template", &.{}, d);
}

fn templateCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("Template expects a string");
        return error.TypeError;
    }
    try ensureTemplateClass(interp);
    const inst = try Instance.init(interp.allocator, interp.string_template_class.?);
    try inst.dict.setStr(interp.allocator, "template", args[0]);
    return Value{ .instance = inst };
}

fn templateText(args: []const Value) ?[]const u8 {
    if (args.len < 1 or args[0] != .instance) return null;
    const t = args[0].instance.dict.getStr("template") orelse return null;
    if (t != .str) return null;
    return t.str.bytes;
}

const SubMode = enum { strict, safe };

fn lookupKey(
    interp: *Interp,
    name: []const u8,
    mapping: ?Value,
    kw_names: []const Value,
    kw_values: []const Value,
    mode: SubMode,
) !?Value {
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, name)) return kv;
    }
    if (mapping) |m| {
        if (m == .dict) {
            if (m.dict.getStr(name)) |v| return v;
        }
    }
    if (mode == .strict) {
        try interp.raisePy("KeyError", name);
        return error.PyException;
    }
    return null;
}

fn substituteCommon(
    interp: *Interp,
    template: []const u8,
    mapping: ?Value,
    kw_names: []const Value,
    kw_values: []const Value,
    mode: SubMode,
) !Value {
    const a = interp.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c != '$') {
            try out.append(a, c);
            i += 1;
            continue;
        }
        // c == '$'
        if (i + 1 >= template.len) {
            // Trailing '$'
            if (mode == .safe) {
                try out.append(a, '$');
                i += 1;
                continue;
            }
            try interp.raisePy("ValueError", "invalid placeholder in string");
            return error.PyException;
        }
        const n = template[i + 1];
        if (n == '$') {
            try out.append(a, '$');
            i += 2;
            continue;
        }
        if (n == '{') {
            const close = std.mem.indexOfScalarPos(u8, template, i + 2, '}') orelse {
                if (mode == .safe) {
                    try out.append(a, c);
                    i += 1;
                    continue;
                }
                try interp.raisePy("ValueError", "unmatched '{'");
                return error.PyException;
            };
            const name = template[i + 2 .. close];
            // CPython requires the inside to be a valid identifier.
            if (name.len == 0 or !isIdentStart(name[0])) {
                if (mode == .safe) {
                    try out.appendSlice(a, template[i .. close + 1]);
                    i = close + 1;
                    continue;
                }
                try interp.raisePy("ValueError", "invalid placeholder");
                return error.PyException;
            }
            for (name[1..]) |bc| {
                if (!isIdentCont(bc)) {
                    if (mode == .safe) {
                        try out.appendSlice(a, template[i .. close + 1]);
                        i = close + 1;
                        break;
                    }
                    try interp.raisePy("ValueError", "invalid placeholder");
                    return error.PyException;
                }
            } else {
                const v_opt = try lookupKey(interp, name, mapping, kw_names, kw_values, mode);
                if (v_opt) |v| {
                    try appendValueAsStr(interp, &out, v);
                } else {
                    try out.appendSlice(a, template[i .. close + 1]);
                }
                i = close + 1;
                continue;
            }
            // safe-mode break landed here:
            continue;
        }
        if (isIdentStart(n)) {
            var j = i + 2;
            while (j < template.len and isIdentCont(template[j])) j += 1;
            const name = template[i + 1 .. j];
            const v_opt = try lookupKey(interp, name, mapping, kw_names, kw_values, mode);
            if (v_opt) |v| {
                try appendValueAsStr(interp, &out, v);
            } else {
                try out.appendSlice(a, template[i..j]);
            }
            i = j;
            continue;
        }
        // '$' followed by non-identifier and non-'$' and non-'{'.
        if (mode == .safe) {
            try out.append(a, '$');
            i += 1;
            continue;
        }
        try interp.raisePy("ValueError", "invalid placeholder in string");
        return error.PyException;
    }
    const owned = try out.toOwnedSlice(a);
    return Value{ .str = try Str.fromOwnedSlice(a, owned) };
}

fn appendValueAsStr(interp: *Interp, out: *std.ArrayList(u8), v: Value) !void {
    const a = interp.allocator;
    if (v == .str) {
        try out.appendSlice(a, v.str.bytes);
        return;
    }
    // Fall back to str.format("{}", v) — same path the {} formatter uses.
    const piece = try strmethods.formatOne(interp, v, "");
    if (piece == .str) {
        try out.appendSlice(a, piece.str.bytes);
    }
}

fn templateSubstitute(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const t = templateText(args) orelse {
        try interp.typeError("substitute called on non-Template");
        return error.TypeError;
    };
    const mapping: ?Value = if (args.len >= 2) args[1] else null;
    return substituteCommon(interp, t, mapping, &.{}, &.{}, .strict);
}

fn templateSubstituteKw(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const t = templateText(args) orelse {
        try interp.typeError("substitute called on non-Template");
        return error.TypeError;
    };
    const mapping: ?Value = if (args.len >= 2) args[1] else null;
    return substituteCommon(interp, t, mapping, kw_names, kw_values, .strict);
}

fn templateSafeSubstitute(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const t = templateText(args) orelse {
        try interp.typeError("safe_substitute called on non-Template");
        return error.TypeError;
    };
    const mapping: ?Value = if (args.len >= 2) args[1] else null;
    return substituteCommon(interp, t, mapping, &.{}, &.{}, .safe);
}

fn templateSafeSubstituteKw(
    p: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const t = templateText(args) orelse {
        try interp.typeError("safe_substitute called on non-Template");
        return error.TypeError;
    };
    const mapping: ?Value = if (args.len >= 2) args[1] else null;
    return substituteCommon(interp, t, mapping, kw_names, kw_values, .safe);
}

fn templateIsValid(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const t = templateText(args) orelse return Value{ .boolean = false };
    var i: usize = 0;
    while (i < t.len) {
        const c = t[i];
        if (c != '$') {
            i += 1;
            continue;
        }
        if (i + 1 >= t.len) return Value{ .boolean = false };
        const n = t[i + 1];
        if (n == '$') {
            i += 2;
            continue;
        }
        if (n == '{') {
            const close = std.mem.indexOfScalarPos(u8, t, i + 2, '}') orelse return Value{ .boolean = false };
            const name = t[i + 2 .. close];
            if (name.len == 0 or !isIdentStart(name[0])) return Value{ .boolean = false };
            for (name[1..]) |bc| if (!isIdentCont(bc)) return Value{ .boolean = false };
            i = close + 1;
            continue;
        }
        if (isIdentStart(n)) {
            var j = i + 2;
            while (j < t.len and isIdentCont(t[j])) j += 1;
            i = j;
            continue;
        }
        return Value{ .boolean = false };
    }
    return Value{ .boolean = true };
}

fn templateGetIdentifiers(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const t = templateText(args) orelse {
        try interp.typeError("get_identifiers called on non-Template");
        return error.TypeError;
    };
    const out = try List.init(a);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(a);
    var i: usize = 0;
    while (i < t.len) {
        const c = t[i];
        if (c != '$') {
            i += 1;
            continue;
        }
        if (i + 1 >= t.len) {
            try interp.raisePy("ValueError", "invalid placeholder");
            return error.PyException;
        }
        const n = t[i + 1];
        if (n == '$') {
            i += 2;
            continue;
        }
        var name: []const u8 = undefined;
        if (n == '{') {
            const close = std.mem.indexOfScalarPos(u8, t, i + 2, '}') orelse {
                try interp.raisePy("ValueError", "unmatched '{'");
                return error.PyException;
            };
            name = t[i + 2 .. close];
            i = close + 1;
        } else if (isIdentStart(n)) {
            var j = i + 2;
            while (j < t.len and isIdentCont(t[j])) j += 1;
            name = t[i + 1 .. j];
            i = j;
        } else {
            try interp.raisePy("ValueError", "invalid placeholder");
            return error.PyException;
        }
        // Dedupe in encounter order.
        var found = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try seen.append(a, name);
            try out.append(a, Value{ .str = try Str.init(a, name) });
        }
    }
    return Value{ .list = out };
}

fn capwordsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("capwords expects a string");
        return error.TypeError;
    }
    const s = args[0].str.bytes;
    const sep_opt: ?[]const u8 = if (args.len >= 2 and args[1] == .str) args[1].str.bytes else null;
    const a = interp.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    if (sep_opt) |sep| {
        // Split on `sep` exactly, capitalize each part, join with same `sep`.
        var first = true;
        var i: usize = 0;
        while (i <= s.len) {
            const at = if (sep.len == 0)
                s.len
            else
                std.mem.indexOfPos(u8, s, i, sep) orelse s.len;
            const word = s[i..at];
            if (!first) try out.appendSlice(a, sep);
            try capitalize(&out, a, word);
            first = false;
            if (at == s.len) break;
            i = at + sep.len;
        }
    } else {
        // sep=None: split on runs of ASCII whitespace, drop leading/
        // trailing empties, join with single space.
        var first = true;
        var i: usize = 0;
        while (i < s.len) {
            while (i < s.len and isAsciiSpace(s[i])) i += 1;
            if (i >= s.len) break;
            const start = i;
            while (i < s.len and !isAsciiSpace(s[i])) i += 1;
            if (!first) try out.append(a, ' ');
            try capitalize(&out, a, s[start..i]);
            first = false;
        }
    }

    const owned = try out.toOwnedSlice(a);
    const new_s = try Str.fromOwnedSlice(a, owned);
    return Value{ .str = new_s };
}
