//! plistlib module — XML and binary plist serialization/deserialization.

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
const Tuple = @import("../object/tuple.zig").Tuple;
const Bytes = @import("../object/bytes.zig").Bytes;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");
const datetime_mod = @import("datetime_mod.zig");

// ===== helpers =====

fn regFn(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: ?BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn getInt(inst: *Instance, key: []const u8) i64 {
    const v = inst.dict.getStr(key) orelse return 0;
    return switch (v) {
        .small_int => |i| i,
        else => 0,
    };
}

fn getFmtValue(v: Value) i64 {
    if (v != .instance) return 1; // default FMT_XML
    const inst = v.instance;
    const fv = inst.dict.getStr("value") orelse return 1;
    return switch (fv) {
        .small_int => |i| i,
        else => 1,
    };
}

// ===== class setup =====

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;

    if (interp.plist_fmt_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "__repr__", fmtReprFnInterp);
        interp.plist_fmt_class = try Class.init(a, "PlistFormat", &.{}, d);
    }

    if (interp.plist_uid_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "__repr__", uidReprFn);
        interp.plist_uid_class = try Class.init(a, "UID", &.{}, d);
    }

    if (interp.plist_error_class == null) {
        const d = try Dict.init(a);
        const exc_val = interp.builtins.getStr("Exception");
        if (exc_val != null and exc_val.? == .class) {
            interp.plist_error_class = try Class.init(a, "InvalidFileException", &.{exc_val.?.class}, d);
        } else {
            interp.plist_error_class = try Class.init(a, "InvalidFileException", &.{}, d);
        }
    }
}

fn makeFmtInst(interp: *Interp, name: []const u8, val: i64) !Value {
    const a = interp.allocator;
    const cls = interp.plist_fmt_class.?;
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "value", Value{ .small_int = val });
    try inst.dict.setStr(a, "_name", Value{ .str = try Str.init(a, name) });
    return Value{ .instance = inst };
}

fn fmtReprFnInterp(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .none = {} };
    const inst = args[0].instance;
    const name_v = inst.dict.getStr("_name") orelse return Value{ .none = {} };
    const val_v = inst.dict.getStr("value") orelse return Value{ .none = {} };
    if (name_v != .str or val_v != .small_int) return Value{ .none = {} };
    const s = try std.fmt.allocPrint(a, "<PlistFormat.{s}: {d}>", .{ name_v.str.bytes, val_v.small_int });
    defer a.free(s);
    return Value{ .str = try Str.init(a, s) };
}

fn uidReprFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .none = {} };
    const inst = args[0].instance;
    const data_v = inst.dict.getStr("data") orelse return Value{ .none = {} };
    const n: i64 = switch (data_v) {
        .small_int => |i| i,
        else => return Value{ .none = {} },
    };
    const s = try std.fmt.allocPrint(a, "UID({d})", .{n});
    defer a.free(s);
    return Value{ .str = try Str.init(a, s) };
}

fn uidInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    try ensureClasses(interp);
    const n: i64 = if (args.len >= 1) switch (args[0]) {
        .small_int => |i| i,
        else => 0,
    } else 0;
    const inst = try Instance.init(a, interp.plist_uid_class.?);
    try inst.dict.setStr(a, "data", Value{ .small_int = n });
    return Value{ .instance = inst };
}

fn isUid(interp: *Interp, v: Value) bool {
    if (v != .instance) return false;
    return v.instance.cls == interp.plist_uid_class.?;
}

fn isDatetime(interp: *Interp, v: Value) bool {
    if (interp.dt_datetime_class == null) return false;
    if (v != .instance) return false;
    return v.instance.cls == interp.dt_datetime_class.?;
}

// ===== XML special char escaping =====

fn xmlEscape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '&' => try buf.appendSlice(a, "&amp;"),
            '<' => try buf.appendSlice(a, "&lt;"),
            '>' => try buf.appendSlice(a, "&gt;"),
            '"' => try buf.appendSlice(a, "&quot;"),
            else => try buf.append(a, c),
        }
    }
    return buf.toOwnedSlice(a);
}

fn xmlUnescape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (std.mem.startsWith(u8, s[i..], "&amp;")) {
                try buf.append(a, '&');
                i += 5;
            } else if (std.mem.startsWith(u8, s[i..], "&lt;")) {
                try buf.append(a, '<');
                i += 4;
            } else if (std.mem.startsWith(u8, s[i..], "&gt;")) {
                try buf.append(a, '>');
                i += 4;
            } else if (std.mem.startsWith(u8, s[i..], "&quot;")) {
                try buf.append(a, '"');
                i += 6;
            } else if (std.mem.startsWith(u8, s[i..], "&apos;")) {
                try buf.append(a, '\'');
                i += 6;
            } else {
                try buf.append(a, s[i]);
                i += 1;
            }
        } else {
            try buf.append(a, s[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(a);
}

// ===== base64 =====

const B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64Encode(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i + 2 < data.len) : (i += 3) {
        const b0 = data[i];
        const b1 = data[i + 1];
        const b2 = data[i + 2];
        try buf.append(a, B64_CHARS[b0 >> 2]);
        try buf.append(a, B64_CHARS[((b0 & 3) << 4) | (b1 >> 4)]);
        try buf.append(a, B64_CHARS[((b1 & 15) << 2) | (b2 >> 6)]);
        try buf.append(a, B64_CHARS[b2 & 63]);
    }
    if (i + 1 == data.len) {
        const b0 = data[i];
        try buf.append(a, B64_CHARS[b0 >> 2]);
        try buf.append(a, B64_CHARS[(b0 & 3) << 4]);
        try buf.append(a, '=');
        try buf.append(a, '=');
    } else if (i + 2 == data.len) {
        const b0 = data[i];
        const b1 = data[i + 1];
        try buf.append(a, B64_CHARS[b0 >> 2]);
        try buf.append(a, B64_CHARS[((b0 & 3) << 4) | (b1 >> 4)]);
        try buf.append(a, B64_CHARS[(b1 & 15) << 2]);
        try buf.append(a, '=');
    }
    return buf.toOwnedSlice(a);
}

fn b64CharVal(c: u8) ?u8 {
    if (c >= 'A' and c <= 'Z') return c - 'A';
    if (c >= 'a' and c <= 'z') return c - 'a' + 26;
    if (c >= '0' and c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return null;
}

fn base64Decode(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    // strip whitespace
    var clean: std.ArrayListUnmanaged(u8) = .empty;
    defer clean.deinit(a);
    for (s) |c| {
        if (c != ' ' and c != '\n' and c != '\r' and c != '\t') {
            try clean.append(a, c);
        }
    }
    const src = clean.items;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i + 3 < src.len) : (i += 4) {
        const v0 = b64CharVal(src[i]) orelse continue;
        const v1 = b64CharVal(src[i + 1]) orelse continue;
        try buf.append(a, (v0 << 2) | (v1 >> 4));
        if (src[i + 2] != '=') {
            const v2 = b64CharVal(src[i + 2]) orelse continue;
            try buf.append(a, (v1 << 4) | (v2 >> 2));
            if (src[i + 3] != '=') {
                const v3 = b64CharVal(src[i + 3]) orelse continue;
                try buf.append(a, (v2 << 6) | v3);
            }
        }
    }
    return buf.toOwnedSlice(a);
}

// ===== XML writer =====

fn writeXmlValue(interp: *Interp, buf: *std.ArrayListUnmanaged(u8), v: Value, indent: usize, sort_keys: bool) anyerror!void {
    const a = interp.allocator;
    switch (v) {
        .boolean => |b| {
            if (b) {
                try buf.appendSlice(a, "<true/>");
            } else {
                try buf.appendSlice(a, "<false/>");
            }
        },
        .small_int => |n| {
            const s = try std.fmt.allocPrint(a, "<integer>{d}</integer>", .{n});
            defer a.free(s);
            try buf.appendSlice(a, s);
        },
        .big_int => |bi| {
            const bi_str = try bi.inner.toString(a, 10, .lower);
            defer a.free(bi_str);
            const s = try std.fmt.allocPrint(a, "<integer>{s}</integer>", .{bi_str});
            defer a.free(s);
            try buf.appendSlice(a, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(a, "<real>{d}</real>", .{f});
            defer a.free(s);
            try buf.appendSlice(a, s);
        },
        .str => |st| {
            const escaped = try xmlEscape(a, st.bytes);
            defer a.free(escaped);
            const s = try std.fmt.allocPrint(a, "<string>{s}</string>", .{escaped});
            defer a.free(s);
            try buf.appendSlice(a, s);
        },
        .bytes => |b| {
            const enc = try base64Encode(a, b.data);
            defer a.free(enc);
            const s = try std.fmt.allocPrint(a, "<data>{s}</data>", .{enc});
            defer a.free(s);
            try buf.appendSlice(a, s);
        },
        .bytearray => |ba| {
            const enc = try base64Encode(a, ba.data.items);
            defer a.free(enc);
            const s = try std.fmt.allocPrint(a, "<data>{s}</data>", .{enc});
            defer a.free(s);
            try buf.appendSlice(a, s);
        },
        .list => |lst| {
            try buf.appendSlice(a, "<array>\n");
            for (lst.items.items) |item| {
                try writeIndent(a, buf, indent + 1);
                try writeXmlValue(interp, buf, item, indent + 1, sort_keys);
                try buf.append(a, '\n');
            }
            try writeIndent(a, buf, indent);
            try buf.appendSlice(a, "</array>");
        },
        .tuple => |tup| {
            try buf.appendSlice(a, "<array>\n");
            for (tup.items) |item| {
                try writeIndent(a, buf, indent + 1);
                try writeXmlValue(interp, buf, item, indent + 1, sort_keys);
                try buf.append(a, '\n');
            }
            try writeIndent(a, buf, indent);
            try buf.appendSlice(a, "</array>");
        },
        .dict => |d| {
            try writeXmlDict(interp, buf, d, indent, sort_keys);
        },
        .instance => |inst| {
            if (isDatetime(interp, v)) {
                // format as ISO8601 UTC
                const y = getInt(inst, "year");
                const mo = getInt(inst, "month");
                const dy = getInt(inst, "day");
                const hh = getInt(inst, "hour");
                const mm = getInt(inst, "minute");
                const ss = getInt(inst, "second");
                const s = try std.fmt.allocPrint(a, "<date>{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z</date>", .{ @as(u64, @intCast(y)), @as(u64, @intCast(mo)), @as(u64, @intCast(dy)), @as(u64, @intCast(hh)), @as(u64, @intCast(mm)), @as(u64, @intCast(ss)) });
                defer a.free(s);
                try buf.appendSlice(a, s);
            } else if (isUid(interp, v)) {
                // UIDs are not representable in XML plist — write as integer
                const data_v = inst.dict.getStr("data") orelse Value{ .small_int = 0 };
                const n: i64 = switch (data_v) {
                    .small_int => |i| i,
                    else => 0,
                };
                const s = try std.fmt.allocPrint(a, "<integer>{d}</integer>", .{n});
                defer a.free(s);
                try buf.appendSlice(a, s);
            } else {
                try buf.appendSlice(a, "<string></string>");
            }
        },
        .none => {
            try buf.appendSlice(a, "<string></string>");
        },
        else => {
            try buf.appendSlice(a, "<string></string>");
        },
    }
}

fn writeIndent(a: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try buf.append(a, '\t');
    }
}

fn writeXmlDict(interp: *Interp, buf: *std.ArrayListUnmanaged(u8), d: *Dict, indent: usize, sort_keys: bool) anyerror!void {
    const a = interp.allocator;
    try buf.appendSlice(a, "<dict>\n");
    const pairs = d.pairs.items;

    if (sort_keys and pairs.len > 1) {
        // Collect key strings, sort them, then write in order
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer keys.deinit(a);
        for (pairs) |p| {
            const k = switch (p.key) {
                .str => |s| s.bytes,
                else => continue,
            };
            try keys.append(a, k);
        }
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn lessThan(_: void, aa: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, aa, b);
            }
        }.lessThan);
        for (keys.items) |k| {
            const val = d.getStr(k) orelse continue;
            const escaped_key = try xmlEscape(a, k);
            defer a.free(escaped_key);
            try writeIndent(a, buf, indent + 1);
            const ks = try std.fmt.allocPrint(a, "<key>{s}</key>\n", .{escaped_key});
            defer a.free(ks);
            try buf.appendSlice(a, ks);
            try writeIndent(a, buf, indent + 1);
            try writeXmlValue(interp, buf, val, indent + 1, sort_keys);
            try buf.append(a, '\n');
        }
    } else {
        for (pairs) |p| {
            const k = switch (p.key) {
                .str => |s| s.bytes,
                else => continue,
            };
            const escaped_key = try xmlEscape(a, k);
            defer a.free(escaped_key);
            try writeIndent(a, buf, indent + 1);
            const ks = try std.fmt.allocPrint(a, "<key>{s}</key>\n", .{escaped_key});
            defer a.free(ks);
            try buf.appendSlice(a, ks);
            try writeIndent(a, buf, indent + 1);
            try writeXmlValue(interp, buf, p.value, indent + 1, sort_keys);
            try buf.append(a, '\n');
        }
    }
    try writeIndent(a, buf, indent);
    try buf.appendSlice(a, "</dict>");
}

fn dumpsXml(interp: *Interp, obj: Value, sort_keys: bool) !Value {
    const a = interp.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(a, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try buf.appendSlice(a, "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n");
    try buf.appendSlice(a, "<plist version=\"1.0\">\n");
    try writeXmlValue(interp, &buf, obj, 0, sort_keys);
    try buf.append(a, '\n');
    try buf.appendSlice(a, "</plist>\n");
    const s = try buf.toOwnedSlice(a);
    const bytes = try Bytes.fromOwnedSlice(a, s);
    return Value{ .bytes = bytes };
}

// ===== XML parser =====

const XmlParser = struct {
    input: []const u8,
    pos: usize,
    interp: *Interp,

    fn init(interp: *Interp, input: []const u8) XmlParser {
        return .{ .input = input, .pos = 0, .interp = interp };
    }

    fn atEnd(self: *XmlParser) bool {
        return self.pos >= self.input.len;
    }

    fn skipWhitespace(self: *XmlParser) void {
        while (self.pos < self.input.len and
            (self.input[self.pos] == ' ' or self.input[self.pos] == '\t' or
            self.input[self.pos] == '\n' or self.input[self.pos] == '\r'))
        {
            self.pos += 1;
        }
    }

    // Skip <?...?> and <!...> processing instructions / doctype
    fn skipProlog(self: *XmlParser) void {
        while (!self.atEnd()) {
            self.skipWhitespace();
            if (self.atEnd()) break;
            if (!std.mem.startsWith(u8, self.input[self.pos..], "<")) break;
            if (std.mem.startsWith(u8, self.input[self.pos..], "<?")) {
                // Skip to ?>
                self.pos += 2;
                while (self.pos + 1 < self.input.len) {
                    if (std.mem.startsWith(u8, self.input[self.pos..], "?>")) {
                        self.pos += 2;
                        break;
                    }
                    self.pos += 1;
                }
            } else if (std.mem.startsWith(u8, self.input[self.pos..], "<!")) {
                // Skip to >
                self.pos += 2;
                while (self.pos < self.input.len and self.input[self.pos] != '>') {
                    self.pos += 1;
                }
                if (self.pos < self.input.len) self.pos += 1;
            } else {
                break;
            }
        }
    }

    // Read tag name (e.g. "dict", "/dict", "true/")
    fn readTagName(self: *XmlParser) []const u8 {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '>' or c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
            self.pos += 1;
        }
        return self.input[start..self.pos];
    }

    // Skip to end of current tag >
    fn skipToTagEnd(self: *XmlParser) void {
        while (self.pos < self.input.len and self.input[self.pos] != '>') {
            self.pos += 1;
        }
        if (self.pos < self.input.len) self.pos += 1;
    }

    // Read text content until '<'
    fn readText(self: *XmlParser) []const u8 {
        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != '<') {
            self.pos += 1;
        }
        return std.mem.trim(u8, self.input[start..self.pos], " \t\n\r");
    }

    // Consume opening '<', read tag name, skip rest of tag to '>'
    // Returns tag name (without '<' or '>')
    fn nextTag(self: *XmlParser) ?[]const u8 {
        self.skipWhitespace();
        if (self.atEnd() or self.input[self.pos] != '<') return null;
        self.pos += 1; // skip '<'
        const name = self.readTagName();
        self.skipToTagEnd();
        return name;
    }

    fn parseValue(self: *XmlParser, aware_datetime: bool) anyerror!Value {
        self.skipWhitespace();
        if (self.atEnd() or self.input[self.pos] != '<') return error.ParseError;
        self.pos += 1; // skip '<'
        const tag = self.readTagName();
        self.skipToTagEnd();

        const a = self.interp.allocator;

        if (std.mem.eql(u8, tag, "dict")) {
            return self.parseDict(aware_datetime);
        } else if (std.mem.eql(u8, tag, "array")) {
            return self.parseArray(aware_datetime);
        } else if (std.mem.eql(u8, tag, "string")) {
            const text = self.readText();
            const unesc = try xmlUnescape(a, text);
            defer a.free(unesc);
            _ = self.nextTag(); // consume </string>
            return Value{ .str = try Str.init(a, unesc) };
        } else if (std.mem.eql(u8, tag, "integer")) {
            const text = self.readText();
            _ = self.nextTag(); // consume </integer>
            const n = std.fmt.parseInt(i64, text, 10) catch blk: {
                // Try big int (large positive values)
                const n2 = std.fmt.parseInt(u64, text, 10) catch return Value{ .small_int = 0 };
                break :blk @as(i64, @bitCast(n2));
            };
            return Value{ .small_int = n };
        } else if (std.mem.eql(u8, tag, "real")) {
            const text = self.readText();
            _ = self.nextTag(); // consume </real>
            const f = std.fmt.parseFloat(f64, text) catch 0.0;
            return Value{ .float = f };
        } else if (std.mem.eql(u8, tag, "true/")) {
            return Value{ .boolean = true };
        } else if (std.mem.eql(u8, tag, "false/")) {
            return Value{ .boolean = false };
        } else if (std.mem.eql(u8, tag, "data")) {
            const text = self.readText();
            _ = self.nextTag(); // consume </data>
            const decoded = try base64Decode(a, text);
            const bytes = try Bytes.fromOwnedSlice(a, decoded);
            return Value{ .bytes = bytes };
        } else if (std.mem.eql(u8, tag, "date")) {
            const text = self.readText();
            _ = self.nextTag(); // consume </date>
            return try parseDatetimeStr(self.interp, text, aware_datetime);
        } else {
            return Value{ .none = {} };
        }
    }

    fn parseDict(self: *XmlParser, aware_datetime: bool) anyerror!Value {
        const a = self.interp.allocator;
        const d = try Dict.init(a);
        while (true) {
            self.skipWhitespace();
            if (self.atEnd()) break;
            if (std.mem.startsWith(u8, self.input[self.pos..], "</dict>")) {
                self.pos += 7;
                break;
            }
            // Expect <key>...</key>
            self.pos += 1; // skip '<'
            const tag = self.readTagName();
            self.skipToTagEnd();
            if (std.mem.eql(u8, tag, "/dict")) break;
            if (!std.mem.eql(u8, tag, "key")) {
                // skip unknown
                continue;
            }
            const key_text = self.readText();
            const key_unesc = try xmlUnescape(a, key_text);
            defer a.free(key_unesc);
            _ = self.nextTag(); // consume </key>
            const val = try self.parseValue(aware_datetime);
            try d.setStr(a, key_unesc, val);
        }
        return Value{ .dict = d };
    }

    fn parseArray(self: *XmlParser, aware_datetime: bool) anyerror!Value {
        const a = self.interp.allocator;
        const lst = try List.init(a);
        while (true) {
            self.skipWhitespace();
            if (self.atEnd()) break;
            if (std.mem.startsWith(u8, self.input[self.pos..], "</array>")) {
                self.pos += 8;
                break;
            }
            const val = try self.parseValue(aware_datetime);
            try lst.append(a, val);
        }
        return Value{ .list = lst };
    }
};

fn parseDatetimeStr(interp: *Interp, s: []const u8, aware: bool) !Value {
    // Format: YYYY-MM-DDTHH:MM:SSZ
    if (s.len < 19) return Value{ .none = {} };
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return Value{ .none = {} };
    const mo = std.fmt.parseInt(i64, s[5..7], 10) catch return Value{ .none = {} };
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return Value{ .none = {} };
    const hh = std.fmt.parseInt(i64, s[11..13], 10) catch return Value{ .none = {} };
    const mm = std.fmt.parseInt(i64, s[14..16], 10) catch return Value{ .none = {} };
    const ss = std.fmt.parseInt(i64, s[17..19], 10) catch return Value{ .none = {} };
    try datetime_mod.ensureClasses(interp);
    if (aware) {
        // Create UTC timezone
        const td = try datetime_mod.newTimedeltaPub(interp, 0, 0, 0);
        const a = interp.allocator;
        const tz_inst = try Instance.init(a, interp.dt_timezone_class.?);
        try tz_inst.dict.setStr(a, "_offset", td);
        const tz = Value{ .instance = tz_inst };
        return datetime_mod.newDatetimePub(interp, y, mo, d, hh, mm, ss, 0, tz, 0);
    } else {
        return datetime_mod.newDatetimePub(interp, y, mo, d, hh, mm, ss, 0, Value.none, 0);
    }
}

fn loadsXml(interp: *Interp, data: []const u8, aware_datetime: bool) !Value {
    var p = XmlParser.init(interp, data);
    p.skipProlog();
    // Expect <plist ...>
    const plist_tag = p.nextTag() orelse {
        try raiseInvalidFile(interp, "missing <plist> tag");
        return error.PyException;
    };
    if (!std.mem.startsWith(u8, plist_tag, "plist")) {
        try raiseInvalidFile(interp, "expected <plist> tag");
        return error.PyException;
    }
    // Parse inner value
    const val = p.parseValue(aware_datetime) catch {
        try raiseInvalidFile(interp, "invalid plist XML");
        return error.PyException;
    };
    return val;
}

fn raiseInvalidFile(interp: *Interp, msg: []const u8) !void {
    const a = interp.allocator;
    const cls = interp.plist_error_class orelse {
        try interp.raisePy("Exception", msg);
        return;
    };
    const inst = try Instance.init(a, cls);
    const t = try Tuple.init(a, 1);
    t.items[0] = Value{ .str = try Str.init(a, msg) };
    try inst.dict.setStr(a, "args", Value{ .tuple = t });
    interp.current_exc = Value{ .instance = inst };
}

// ===== Binary plist =====

// Reference size: 1 byte if < 256 objects, else 2 bytes
// We serialize all objects into a flat list first.

const BinWriter = struct {
    objects: std.ArrayListUnmanaged([]const u8), // serialized bytes for each object
    interp: *Interp,

    fn init() BinWriter {
        return .{ .objects = .empty, .interp = undefined };
    }

    fn deinit(self: *BinWriter, a: std.mem.Allocator) void {
        for (self.objects.items) |obj| {
            a.free(obj);
        }
        self.objects.deinit(a);
    }
};

fn binEncodeInt(a: std.mem.Allocator, n: i64) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (n >= 0 and n <= 255) {
        try buf.append(a, 0x10);
        try buf.append(a, @intCast(n));
    } else if (n >= 0 and n <= 65535) {
        try buf.append(a, 0x11);
        try buf.append(a, @intCast(n >> 8));
        try buf.append(a, @intCast(n & 0xFF));
    } else if (n >= 0 and n <= 0xFFFFFFFF) {
        try buf.append(a, 0x12);
        try buf.append(a, @intCast((n >> 24) & 0xFF));
        try buf.append(a, @intCast((n >> 16) & 0xFF));
        try buf.append(a, @intCast((n >> 8) & 0xFF));
        try buf.append(a, @intCast(n & 0xFF));
    } else {
        // 8-byte signed
        const u: u64 = @bitCast(n);
        try buf.append(a, 0x13);
        try buf.append(a, @intCast((u >> 56) & 0xFF));
        try buf.append(a, @intCast((u >> 48) & 0xFF));
        try buf.append(a, @intCast((u >> 40) & 0xFF));
        try buf.append(a, @intCast((u >> 32) & 0xFF));
        try buf.append(a, @intCast((u >> 24) & 0xFF));
        try buf.append(a, @intCast((u >> 16) & 0xFF));
        try buf.append(a, @intCast((u >> 8) & 0xFF));
        try buf.append(a, @intCast(u & 0xFF));
    }
    return buf.toOwnedSlice(a);
}

fn binWriteCount(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, marker_base: u8, count: usize, count_obj_bytes: []const u8) !void {
    if (count < 15) {
        try buf.append(a, marker_base | @as(u8, @intCast(count)));
    } else {
        try buf.append(a, marker_base | 0x0F);
        try buf.appendSlice(a, count_obj_bytes);
    }
}

// Collect all objects and return root index
fn collectObjects(
    interp: *Interp,
    v: Value,
    objects: *std.ArrayListUnmanaged([]const u8),
    sort_keys: bool,
) anyerror!usize {
    const a = interp.allocator;
    const idx = objects.items.len;

    switch (v) {
        .boolean => |b| {
            var obj = try a.alloc(u8, 1);
            obj[0] = if (b) 0x09 else 0x08;
            try objects.append(a, obj);
        },
        .small_int => |n| {
            const obj = try binEncodeInt(a, n);
            try objects.append(a, obj);
        },
        .big_int => |bi| {
            // big_int value — try to convert
            const n = bi.inner.toConst().toInt(i64) catch 0;
            const obj = try binEncodeInt(a, n);
            try objects.append(a, obj);
        },
        .float => |f| {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.append(a, 0x23);
            const bits: u64 = @bitCast(f);
            try buf.append(a, @intCast((bits >> 56) & 0xFF));
            try buf.append(a, @intCast((bits >> 48) & 0xFF));
            try buf.append(a, @intCast((bits >> 40) & 0xFF));
            try buf.append(a, @intCast((bits >> 32) & 0xFF));
            try buf.append(a, @intCast((bits >> 24) & 0xFF));
            try buf.append(a, @intCast((bits >> 16) & 0xFF));
            try buf.append(a, @intCast((bits >> 8) & 0xFF));
            try buf.append(a, @intCast(bits & 0xFF));
            try objects.append(a, try buf.toOwnedSlice(a));
        },
        .bytes => |b| {
            const data = b.data;
            try objects.append(a, try encodeBinData(a, data));
        },
        .bytearray => |ba| {
            const data = ba.data.items;
            try objects.append(a, try encodeBinData(a, data));
        },
        .str => |st| {
            try objects.append(a, try encodeBinString(a, st.bytes, objects));
        },
        .list => |lst| {
            // Reserve slot for array object
            try objects.append(a, &.{}); // placeholder
            const items = lst.items.items;
            var refs: std.ArrayListUnmanaged(usize) = .empty;
            defer refs.deinit(a);
            for (items) |item| {
                const ref = try collectObjects(interp, item, objects, sort_keys);
                try refs.append(a, ref);
            }
            // Build array object
            const count = refs.items.len;
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            const ref_size: u8 = if (objects.items.len < 256) 1 else 2;
            const cnt_bytes = try binEncodeInt(a, @intCast(count));
            defer a.free(cnt_bytes);
            try binWriteCount(&buf, a, 0xA0, count, cnt_bytes);
            for (refs.items) |r| {
                try appendRef(&buf, a, r, ref_size);
            }
            a.free(objects.items[idx]);
            objects.items[idx] = try buf.toOwnedSlice(a);
        },
        .tuple => |tup| {
            try objects.append(a, &.{}); // placeholder
            var refs: std.ArrayListUnmanaged(usize) = .empty;
            defer refs.deinit(a);
            for (tup.items) |item| {
                const ref = try collectObjects(interp, item, objects, sort_keys);
                try refs.append(a, ref);
            }
            const count = refs.items.len;
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            const ref_size: u8 = if (objects.items.len < 256) 1 else 2;
            const cnt_bytes = try binEncodeInt(a, @intCast(count));
            defer a.free(cnt_bytes);
            try binWriteCount(&buf, a, 0xA0, count, cnt_bytes);
            for (refs.items) |r| {
                try appendRef(&buf, a, r, ref_size);
            }
            a.free(objects.items[idx]);
            objects.items[idx] = try buf.toOwnedSlice(a);
        },
        .dict => |d| {
            try objects.append(a, &.{}); // placeholder
            const pairs = d.pairs.items;
            var key_refs: std.ArrayListUnmanaged(usize) = .empty;
            defer key_refs.deinit(a);
            var val_refs: std.ArrayListUnmanaged(usize) = .empty;
            defer val_refs.deinit(a);

            if (sort_keys and pairs.len > 1) {
                var keys: std.ArrayListUnmanaged([]const u8) = .empty;
                defer keys.deinit(a);
                for (pairs) |p| {
                    const k = switch (p.key) { .str => |s| s.bytes, else => continue };
                    try keys.append(a, k);
                }
                std.mem.sort([]const u8, keys.items, {}, struct {
                    fn lt(_: void, aa: []const u8, b: []const u8) bool {
                        return std.mem.lessThan(u8, aa, b);
                    }
                }.lt);
                for (keys.items) |k| {
                    const kr = try collectObjects(interp, Value{ .str = try Str.init(a, k) }, objects, sort_keys);
                    try key_refs.append(a, kr);
                    const vv = d.getStr(k) orelse Value.none;
                    const vr = try collectObjects(interp, vv, objects, sort_keys);
                    try val_refs.append(a, vr);
                }
            } else {
                for (pairs) |p| {
                    const kr = try collectObjects(interp, p.key, objects, sort_keys);
                    try key_refs.append(a, kr);
                    const vr = try collectObjects(interp, p.value, objects, sort_keys);
                    try val_refs.append(a, vr);
                }
            }

            const count = key_refs.items.len;
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            const ref_size: u8 = if (objects.items.len < 256) 1 else 2;
            const cnt_bytes = try binEncodeInt(a, @intCast(count));
            defer a.free(cnt_bytes);
            try binWriteCount(&buf, a, 0xD0, count, cnt_bytes);
            for (key_refs.items) |r| try appendRef(&buf, a, r, ref_size);
            for (val_refs.items) |r| try appendRef(&buf, a, r, ref_size);
            a.free(objects.items[idx]);
            objects.items[idx] = try buf.toOwnedSlice(a);
        },
        .instance => |inst| {
            if (isDatetime(interp, v)) {
                // Encode as date: seconds since 2001-01-01 00:00:00
                const y = getInt(inst, "year");
                const mo = getInt(inst, "month");
                const d = getInt(inst, "day");
                const hh = getInt(inst, "hour");
                const mm = getInt(inst, "minute");
                const ss = getInt(inst, "second");
                const secs = datetimeToAppleEpoch(y, mo, d, hh, mm, ss);
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                try buf.append(a, 0x33);
                const bits: u64 = @bitCast(secs);
                try buf.append(a, @intCast((bits >> 56) & 0xFF));
                try buf.append(a, @intCast((bits >> 48) & 0xFF));
                try buf.append(a, @intCast((bits >> 40) & 0xFF));
                try buf.append(a, @intCast((bits >> 32) & 0xFF));
                try buf.append(a, @intCast((bits >> 24) & 0xFF));
                try buf.append(a, @intCast((bits >> 16) & 0xFF));
                try buf.append(a, @intCast((bits >> 8) & 0xFF));
                try buf.append(a, @intCast(bits & 0xFF));
                try objects.append(a, try buf.toOwnedSlice(a));
            } else if (isUid(interp, v)) {
                const data_v = inst.dict.getStr("data") orelse Value{ .small_int = 0 };
                const n: u64 = switch (data_v) {
                    .small_int => |i| @intCast(if (i < 0) 0 else i),
                    else => 0,
                };
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                // byte_count = ceil(bits/8)
                const byte_count: u8 = if (n < 256) 1 else if (n < 65536) 2 else if (n < 0x1000000) 3 else 4;
                try buf.append(a, 0x80 | (byte_count - 1));
                var i: u8 = byte_count;
                while (i > 0) : (i -= 1) {
                    const shift: u6 = @intCast((i - 1) * 8);
                    try buf.append(a, @intCast((n >> shift) & 0xFF));
                }
                try objects.append(a, try buf.toOwnedSlice(a));
            } else {
                // fallback: null-like
                var obj = try a.alloc(u8, 1);
                obj[0] = 0x00;
                try objects.append(a, obj);
            }
        },
        .none => {
            var obj = try a.alloc(u8, 1);
            obj[0] = 0x00;
            try objects.append(a, obj);
        },
        else => {
            var obj = try a.alloc(u8, 1);
            obj[0] = 0x00;
            try objects.append(a, obj);
        },
    }
    return idx;
}

fn appendRef(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, ref: usize, ref_size: u8) !void {
    if (ref_size == 1) {
        try buf.append(a, @intCast(ref & 0xFF));
    } else {
        try buf.append(a, @intCast((ref >> 8) & 0xFF));
        try buf.append(a, @intCast(ref & 0xFF));
    }
}

fn encodeBinData(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const count = data.len;
    if (count < 15) {
        try buf.append(a, 0x40 | @as(u8, @intCast(count)));
    } else {
        try buf.append(a, 0x4F);
        // Encode count as int object inline
        const cnt_bytes = try binEncodeInt(a, @intCast(count));
        defer a.free(cnt_bytes);
        try buf.appendSlice(a, cnt_bytes);
    }
    try buf.appendSlice(a, data);
    return buf.toOwnedSlice(a);
}

fn encodeBinString(a: std.mem.Allocator, s: []const u8, _: *std.ArrayListUnmanaged([]const u8)) ![]const u8 {
    // Check if ASCII
    var is_ascii = true;
    for (s) |c| {
        if (c > 127) { is_ascii = false; break; }
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (is_ascii) {
        const count = s.len;
        if (count < 15) {
            try buf.append(a, 0x50 | @as(u8, @intCast(count)));
        } else {
            try buf.append(a, 0x5F);
            const cnt_bytes = try binEncodeInt(a, @intCast(count));
            defer a.free(cnt_bytes);
            try buf.appendSlice(a, cnt_bytes);
        }
        try buf.appendSlice(a, s);
    } else {
        // UTF-16 BE
        var utf16: std.ArrayListUnmanaged(u8) = .empty;
        defer utf16.deinit(a);
        var char_count: usize = 0;
        // Decode UTF-8 to code points and encode as UTF-16 BE
        var i: usize = 0;
        while (i < s.len) {
            const cp = decodeUtf8Codepoint(s, &i);
            char_count += 1;
            if (cp < 0x10000) {
                try utf16.append(a, @intCast((cp >> 8) & 0xFF));
                try utf16.append(a, @intCast(cp & 0xFF));
            } else {
                // surrogate pair
                const cp2 = cp - 0x10000;
                const hi: u16 = @intCast(0xD800 + (cp2 >> 10));
                const lo: u16 = @intCast(0xDC00 + (cp2 & 0x3FF));
                try utf16.append(a, @intCast((hi >> 8) & 0xFF));
                try utf16.append(a, @intCast(hi & 0xFF));
                try utf16.append(a, @intCast((lo >> 8) & 0xFF));
                try utf16.append(a, @intCast(lo & 0xFF));
                char_count += 1; // surrogate pair counts as 2 u16 units
            }
        }
        if (char_count < 15) {
            try buf.append(a, 0x60 | @as(u8, @intCast(char_count)));
        } else {
            try buf.append(a, 0x6F);
            const cnt_bytes = try binEncodeInt(a, @intCast(char_count));
            defer a.free(cnt_bytes);
            try buf.appendSlice(a, cnt_bytes);
        }
        try buf.appendSlice(a, utf16.items);
    }
    return buf.toOwnedSlice(a);
}

fn decodeUtf8Codepoint(s: []const u8, i: *usize) u32 {
    const b0 = s[i.*];
    if (b0 < 0x80) {
        i.* += 1;
        return b0;
    } else if (b0 < 0xE0) {
        if (i.* + 1 >= s.len) { i.* += 1; return b0; }
        const r = (@as(u32, b0 & 0x1F) << 6) | (s[i.* + 1] & 0x3F);
        i.* += 2;
        return r;
    } else if (b0 < 0xF0) {
        if (i.* + 2 >= s.len) { i.* += 1; return b0; }
        const r = (@as(u32, b0 & 0x0F) << 12) | (@as(u32, s[i.* + 1] & 0x3F) << 6) | (s[i.* + 2] & 0x3F);
        i.* += 3;
        return r;
    } else {
        if (i.* + 3 >= s.len) { i.* += 1; return b0; }
        const r = (@as(u32, b0 & 0x07) << 18) | (@as(u32, s[i.* + 1] & 0x3F) << 12) | (@as(u32, s[i.* + 2] & 0x3F) << 6) | (s[i.* + 3] & 0x3F);
        i.* += 4;
        return r;
    }
}

// Seconds from 2001-01-01 to the given datetime (UTC)
fn datetimeToAppleEpoch(y: i64, mo: i64, d: i64, hh: i64, mm: i64, ss: i64) f64 {
    // Days from 2001-01-01
    const total_days = ymdToDays(y, mo, d) - ymdToDays(2001, 1, 1);
    const secs: f64 = @floatFromInt(total_days * 86400 + hh * 3600 + mm * 60 + ss);
    return secs;
}

fn ymdToDays(y: i64, m: i64, d: i64) i64 {
    // Days since year 0 (proleptic Gregorian)
    var yy = y;
    var mm = m;
    if (mm <= 2) {
        yy -= 1;
        mm += 12;
    }
    const a_: i64 = @divFloor(yy, 100);
    const b_: i64 = 2 - a_ + @divFloor(a_, 4);
    return @intFromFloat(@floor(365.25 * @as(f64, @floatFromInt(yy + 4716))) +
        @floor(30.6001 * @as(f64, @floatFromInt(mm + 1))) +
        @as(f64, @floatFromInt(d + b_)) - 1524.5);
}

fn julDayToYmd(days_abs: i64) struct { y: i64, m: i64, d: i64 } {
    // days_abs is days since proleptic Gregorian epoch used by ymdToDays
    // Let's go back through Newton's method
    // Estimate year
    var y: i64 = @intFromFloat(@as(f64, @floatFromInt(days_abs)) / 365.2425);
    // adjust
    while (ymdToDays(y + 1, 1, 1) <= days_abs) y += 1;
    while (ymdToDays(y, 1, 1) > days_abs) y -= 1;
    // find month
    var m: i64 = 1;
    while (m < 12 and ymdToDays(y, m + 1, 1) <= days_abs) m += 1;
    // find day
    const d = days_abs - ymdToDays(y, m, 1) + 1;
    return .{ .y = y, .m = m, .d = d };
}

fn appleEpochToDatetime(interp: *Interp, secs_f: f64, aware: bool) !Value {
    const secs_total: i64 = @intFromFloat(@round(secs_f));
    const base_days = ymdToDays(2001, 1, 1);
    const days_offset = @divFloor(secs_total, 86400);
    const remaining = @mod(secs_total, 86400);
    const abs_days = base_days + days_offset;
    const ymd = julDayToYmd(abs_days);
    const hh = @divTrunc(remaining, @as(i64, 3600));
    const mm = @divTrunc(@mod(remaining, @as(i64, 3600)), @as(i64, 60));
    const ss = @mod(remaining, @as(i64, 60));
    try datetime_mod.ensureClasses(interp);
    if (aware) {
        const a = interp.allocator;
        const td = try datetime_mod.newTimedeltaPub(interp, 0, 0, 0);
        const tz_inst = try Instance.init(a, interp.dt_timezone_class.?);
        try tz_inst.dict.setStr(a, "_offset", td);
        const tz = Value{ .instance = tz_inst };
        return datetime_mod.newDatetimePub(interp, ymd.y, ymd.m, ymd.d, hh, mm, ss, 0, tz, 0);
    } else {
        return datetime_mod.newDatetimePub(interp, ymd.y, ymd.m, ymd.d, hh, mm, ss, 0, Value.none, 0);
    }
}

fn dumpsBinary(interp: *Interp, obj: Value, sort_keys: bool) !Value {
    const a = interp.allocator;
    var objects: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (objects.items) |o| a.free(o);
        objects.deinit(a);
    }

    const root_idx = try collectObjects(interp, obj, &objects, sort_keys);
    _ = root_idx;
    const n_objects = objects.items.len;
    const ref_size: u8 = if (n_objects < 256) 1 else 2;

    // Compute offsets
    var offsets: std.ArrayListUnmanaged(usize) = .empty;
    defer offsets.deinit(a);
    var offset: usize = 8; // after "bplist00"
    for (objects.items) |o| {
        try offsets.append(a, offset);
        offset += o.len;
    }

    const offset_table_start = offset;

    // Compute offset_size (bytes needed to represent offset_table_start + n_objects*offset_size)
    // A safe estimate: use enough bytes
    var offset_size: u8 = 1;
    if (offset_table_start + n_objects * 2 > 255) offset_size = 2;
    if (offset_table_start + n_objects * 4 > 65535) offset_size = 4;
    if (offset_table_start + n_objects * 8 > 0xFFFFFF) offset_size = 8;

    // Final offset_table_start depends on offset_size, compute properly
    // Actually after writing all objects, the offset_table starts at 'offset' (computed above)
    // This is correct as offset_table_start is the byte position of the first entry in the table

    // Build output
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a, "bplist00");
    for (objects.items) |o| {
        try out.appendSlice(a, o);
    }

    // Write offset table
    const real_offset_table_start = out.items.len;
    for (offsets.items) |off| {
        try writeUintBE(&out, a, off, offset_size);
    }

    // Write trailer (32 bytes)
    // 6 unused bytes
    try out.appendSlice(a, &[_]u8{ 0, 0, 0, 0, 0, 0 });
    // offset_size (1 byte)
    try out.append(a, offset_size);
    // ref_size (1 byte)
    try out.append(a, ref_size);
    // num_objects (8 bytes BE)
    try writeUint64BE(&out, a, n_objects);
    // top_object index (8 bytes BE)
    try writeUint64BE(&out, a, 0); // root is index 0
    // offset_table_offset (8 bytes BE)
    try writeUint64BE(&out, a, real_offset_table_start);

    const s = try out.toOwnedSlice(a);
    const bytes = try Bytes.fromOwnedSlice(a, s);
    return Value{ .bytes = bytes };
}

fn writeUintBE(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, val: usize, n_bytes: u8) !void {
    var tmp_buf: [8]u8 = undefined;
    var k: u8 = 0;
    while (k < n_bytes) : (k += 1) tmp_buf[k] = 0;
    // Write n_bytes big-endian
    var j: u8 = n_bytes;
    var v = val;
    while (j > 0) : (j -= 1) {
        tmp_buf[j - 1] = @intCast(v & 0xFF);
        v >>= 8;
    }
    try buf.appendSlice(a, tmp_buf[0..n_bytes]);
}

fn writeUint64BE(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, val: usize) !void {
    try writeUintBE(buf, a, val, 8);
}

// ===== Binary plist reader =====

const BinReader = struct {
    data: []const u8,
    n_objects: usize,
    ref_size: u8,
    offset_size: u8,
    offset_table_offset: usize,
    interp: *Interp,

    fn init(interp: *Interp, data: []const u8) !BinReader {
        if (data.len < 32) return error.ParseError;
        const trailer = data[data.len - 32 ..];
        const offset_size = trailer[6];
        const ref_size = trailer[7];
        const n_objects = readUint64(trailer[8..16]);
        const top_object = readUint64(trailer[16..24]);
        const offset_table_offset = readUint64(trailer[24..32]);
        _ = top_object;
        return BinReader{
            .data = data,
            .n_objects = n_objects,
            .ref_size = ref_size,
            .offset_size = offset_size,
            .offset_table_offset = offset_table_offset,
            .interp = interp,
        };
    }

    fn readUint64(b: []const u8) usize {
        var v: usize = 0;
        for (b[0..8]) |byte| {
            v = (v << 8) | byte;
        }
        return v;
    }

    fn readUintN(b: []const u8, n: u8) usize {
        var v: usize = 0;
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            v = (v << 8) | b[i];
        }
        return v;
    }

    fn offsetOf(self: *BinReader, idx: usize) usize {
        const entry = self.offset_table_offset + idx * self.offset_size;
        if (entry + self.offset_size > self.data.len) return 0;
        return readUintN(self.data[entry..], self.offset_size);
    }

    fn refAt(self: *BinReader, pos: usize) usize {
        if (pos + self.ref_size > self.data.len) return 0;
        return readUintN(self.data[pos..], self.ref_size);
    }

    fn parseObject(self: *BinReader, offset: usize, aware: bool) anyerror!Value {
        if (offset >= self.data.len) return error.ParseError;
        const a = self.interp.allocator;
        const marker = self.data[offset];
        const hi = marker >> 4;
        const lo = marker & 0x0F;

        switch (hi) {
            0x0 => {
                // bool / null
                switch (lo) {
                    0x8 => return Value{ .boolean = false },
                    0x9 => return Value{ .boolean = true },
                    else => return Value.none,
                }
            },
            0x1 => {
                // Integer
                const byte_count: usize = @as(usize, 1) << @intCast(lo);
                if (offset + 1 + byte_count > self.data.len) return error.ParseError;
                const bytes = self.data[offset + 1 .. offset + 1 + byte_count];
                // Read as unsigned for small sizes, signed for 8-byte
                if (byte_count == 8) {
                    var v: u64 = 0;
                    for (bytes) |b| v = (v << 8) | b;
                    return Value{ .small_int = @bitCast(v) };
                } else {
                    var v: i64 = 0;
                    for (bytes) |b| v = (v << 8) | b;
                    return Value{ .small_int = v };
                }
            },
            0x2 => {
                // Float
                if (lo == 3) {
                    // 8-byte double
                    if (offset + 9 > self.data.len) return error.ParseError;
                    var bits: u64 = 0;
                    for (self.data[offset + 1 .. offset + 9]) |b| bits = (bits << 8) | b;
                    return Value{ .float = @bitCast(bits) };
                }
                return error.ParseError;
            },
            0x3 => {
                // Date
                if (lo == 3) {
                    if (offset + 9 > self.data.len) return error.ParseError;
                    var bits: u64 = 0;
                    for (self.data[offset + 1 .. offset + 9]) |b| bits = (bits << 8) | b;
                    const secs_f: f64 = @bitCast(bits);
                    return appleEpochToDatetime(self.interp, secs_f, aware);
                }
                return error.ParseError;
            },
            0x4 => {
                // Data
                const count_and_start = try self.readCountedLen(offset, lo);
                const count = count_and_start.count;
                const data_start = count_and_start.data_start;
                if (data_start + count > self.data.len) return error.ParseError;
                const bytes = try Bytes.init(a, self.data[data_start .. data_start + count]);
                return Value{ .bytes = bytes };
            },
            0x5 => {
                // ASCII string
                const count_and_start = try self.readCountedLen(offset, lo);
                const count = count_and_start.count;
                const data_start = count_and_start.data_start;
                if (data_start + count > self.data.len) return error.ParseError;
                return Value{ .str = try Str.init(a, self.data[data_start .. data_start + count]) };
            },
            0x6 => {
                // UTF-16 BE string
                const count_and_start = try self.readCountedLen(offset, lo);
                const char_count = count_and_start.count;
                const data_start = count_and_start.data_start;
                const byte_count = char_count * 2;
                if (data_start + byte_count > self.data.len) return error.ParseError;
                const utf16_data = self.data[data_start .. data_start + byte_count];
                // Decode UTF-16 BE to UTF-8
                const decoded = try decodeUtf16BE(a, utf16_data);
                defer a.free(decoded);
                return Value{ .str = try Str.init(a, decoded) };
            },
            0x8 => {
                // UID: 0x80 | (byte_count-1)
                const byte_count: usize = (lo & 0x0F) + 1;
                if (offset + 1 + byte_count > self.data.len) return error.ParseError;
                var v: u64 = 0;
                for (self.data[offset + 1 .. offset + 1 + byte_count]) |b| v = (v << 8) | b;
                const inst = try Instance.init(a, self.interp.plist_uid_class.?);
                try inst.dict.setStr(a, "data", Value{ .small_int = @intCast(v) });
                return Value{ .instance = inst };
            },
            0xA => {
                // Array
                const count_and_start = try self.readCountedLen(offset, lo);
                const count = count_and_start.count;
                const data_start = count_and_start.data_start;
                const lst = try List.init(a);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const ref_pos = data_start + i * self.ref_size;
                    if (ref_pos + self.ref_size > self.data.len) break;
                    const ref = self.refAt(ref_pos);
                    const obj_offset = self.offsetOf(ref);
                    const item = try self.parseObject(obj_offset, aware);
                    try lst.append(a, item);
                }
                return Value{ .list = lst };
            },
            0xD => {
                // Dict
                const count_and_start = try self.readCountedLen(offset, lo);
                const count = count_and_start.count;
                const data_start = count_and_start.data_start;
                const d = try Dict.init(a);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const key_ref_pos = data_start + i * self.ref_size;
                    const val_ref_pos = data_start + (count + i) * self.ref_size;
                    if (key_ref_pos + self.ref_size > self.data.len) break;
                    if (val_ref_pos + self.ref_size > self.data.len) break;
                    const key_ref = self.refAt(key_ref_pos);
                    const val_ref = self.refAt(val_ref_pos);
                    const key_obj = try self.parseObject(self.offsetOf(key_ref), aware);
                    const val_obj = try self.parseObject(self.offsetOf(val_ref), aware);
                    switch (key_obj) {
                        .str => |s| try d.setStr(a, s.bytes, val_obj),
                        else => {
                            // non-string key: skip
                        },
                    }
                }
                return Value{ .dict = d };
            },
            else => return Value.none,
        }
    }

    const CountedLen = struct { count: usize, data_start: usize };

    fn readCountedLen(self: *BinReader, offset: usize, lo: u8) !CountedLen {
        if (lo < 15) {
            return .{ .count = lo, .data_start = offset + 1 };
        } else {
            // Next byte is an int object encoding the count
            if (offset + 1 >= self.data.len) return error.ParseError;
            const int_marker = self.data[offset + 1];
            const int_hi = int_marker >> 4;
            const int_lo = int_marker & 0x0F;
            if (int_hi != 0x1) return error.ParseError;
            const byte_count: usize = @as(usize, 1) << @intCast(int_lo);
            if (offset + 2 + byte_count > self.data.len) return error.ParseError;
            var count: usize = 0;
            for (self.data[offset + 2 .. offset + 2 + byte_count]) |b| {
                count = (count << 8) | b;
            }
            return .{ .count = count, .data_start = offset + 2 + byte_count };
        }
    }
};

fn decodeUtf16BE(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i + 1 < data.len) {
        const hi: u16 = data[i];
        const lo_byte: u16 = data[i + 1];
        const unit: u16 = (hi << 8) | lo_byte;
        i += 2;
        var cp: u32 = unit;
        if (unit >= 0xD800 and unit < 0xDC00) {
            // High surrogate
            if (i + 1 < data.len) {
                const hi2: u16 = data[i];
                const lo2: u16 = data[i + 1];
                const unit2: u16 = (hi2 << 8) | lo2;
                i += 2;
                cp = 0x10000 + (@as(u32, unit - 0xD800) << 10) + (unit2 - 0xDC00);
            }
        }
        // Encode cp as UTF-8
        if (cp < 0x80) {
            try buf.append(a, @intCast(cp));
        } else if (cp < 0x800) {
            try buf.append(a, @intCast(0xC0 | (cp >> 6)));
            try buf.append(a, @intCast(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            try buf.append(a, @intCast(0xE0 | (cp >> 12)));
            try buf.append(a, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try buf.append(a, @intCast(0x80 | (cp & 0x3F)));
        } else {
            try buf.append(a, @intCast(0xF0 | (cp >> 18)));
            try buf.append(a, @intCast(0x80 | ((cp >> 12) & 0x3F)));
            try buf.append(a, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try buf.append(a, @intCast(0x80 | (cp & 0x3F)));
        }
    }
    return buf.toOwnedSlice(a);
}

fn loadsBinary(interp: *Interp, data: []const u8, aware: bool) !Value {
    try ensureClasses(interp);
    var reader = BinReader.init(interp, data) catch {
        try raiseInvalidFile(interp, "invalid binary plist");
        return error.PyException;
    };
    const root_offset = reader.offsetOf(0);
    return reader.parseObject(root_offset, aware) catch {
        try raiseInvalidFile(interp, "invalid binary plist");
        return error.PyException;
    };
}

// ===== public API functions =====

fn dumpsKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    if (args.len < 1) {
        try interp.raisePy("TypeError", "dumps() requires an argument");
        return error.PyException;
    }
    const obj = args[0];
    var fmt_val: i64 = 1; // FMT_XML
    var sort_keys: bool = true;

    // positional fmt
    if (args.len >= 2) {
        fmt_val = getFmtValue(args[1]);
    }

    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "fmt")) {
            fmt_val = getFmtValue(kv);
        } else if (std.mem.eql(u8, kn.str.bytes, "sort_keys")) {
            if (kv == .boolean) sort_keys = kv.boolean;
        }
    }

    if (fmt_val == 2) {
        return dumpsBinary(interp, obj, sort_keys);
    } else {
        return dumpsXml(interp, obj, sort_keys);
    }
}

fn dumpsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dumpsKw(p, args, &.{}, &.{});
}

fn loadsKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    if (args.len < 1) {
        try interp.raisePy("TypeError", "loads() requires an argument");
        return error.PyException;
    }
    const data: []const u8 = switch (args[0]) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        else => {
            try raiseInvalidFile(interp, "loads() argument must be bytes");
            return error.PyException;
        },
    };

    var fmt_val: i64 = 0; // auto
    var aware_datetime: bool = false;

    if (args.len >= 2 and args[1] != .none) {
        fmt_val = getFmtValue(args[1]);
    }

    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "fmt")) {
            if (kv != .none) fmt_val = getFmtValue(kv);
        } else if (std.mem.eql(u8, kn.str.bytes, "aware_datetime")) {
            if (kv == .boolean) aware_datetime = kv.boolean;
        }
    }

    // Auto-detect if fmt not specified
    if (fmt_val == 0) {
        if (std.mem.startsWith(u8, data, "bplist00")) {
            fmt_val = 2;
        } else if (std.mem.startsWith(u8, data, "<?xml") or std.mem.startsWith(u8, data, "<!DOCTYPE") or std.mem.startsWith(u8, data, "<plist")) {
            fmt_val = 1;
        } else {
            try raiseInvalidFile(interp, "not a valid plist file");
            return error.PyException;
        }
    }

    if (fmt_val == 2) {
        return loadsBinary(interp, data, aware_datetime);
    } else {
        return loadsXml(interp, data, aware_datetime);
    }
}

fn loadsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return loadsKw(p, args, &.{}, &.{});
}

fn dumpKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) {
        try interp.raisePy("TypeError", "dump() requires obj and fp arguments");
        return error.PyException;
    }
    const obj = args[0];
    const fp = args[1];

    var fmt_val: i64 = 1;
    var sort_keys: bool = true;

    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        if (std.mem.eql(u8, kn.str.bytes, "fmt")) {
            fmt_val = getFmtValue(kv);
        } else if (std.mem.eql(u8, kn.str.bytes, "sort_keys")) {
            if (kv == .boolean) sort_keys = kv.boolean;
        }
    }

    const new_args = [_]Value{ obj };
    const fmt_v = if (interp.plist_fmt_class != null) blk: {
        const inst = try Instance.init(interp.allocator, interp.plist_fmt_class.?);
        try inst.dict.setStr(interp.allocator, "value", Value{ .small_int = fmt_val });
        break :blk Value{ .instance = inst };
    } else Value{ .small_int = fmt_val };

    var kw_n = [_]Value{
        Value{ .str = try Str.init(interp.allocator, "fmt") },
        Value{ .str = try Str.init(interp.allocator, "sort_keys") },
    };
    var kw_v = [_]Value{
        fmt_v,
        Value{ .boolean = sort_keys },
    };
    const data = try dumpsKw(p, &new_args, &kw_n, &kw_v);

    // Write to fp via .write()
    const write_attr = try dispatch.loadAttrValue(interp, fp, "write");
    _ = try dispatch.invoke(interp, write_attr, &.{data});
    return Value.none;
}

fn dumpFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dumpKw(p, args, &.{}, &.{});
}

fn loadKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) {
        try interp.raisePy("TypeError", "load() requires a file object");
        return error.PyException;
    }
    const fp = args[0];
    const read_attr = try dispatch.loadAttrValue(interp, fp, "read");
    const data = try dispatch.invoke(interp, read_attr, &.{});
    // Pass to loads
    var new_args: [1]Value = .{data};
    return loadsKw(p, &new_args, kw_names, kw_values);
}

fn loadFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return loadKw(p, args, &.{}, &.{});
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);

    const m = try Module.init(a, "plistlib");

    // FMT_XML = PlistFormat(1), FMT_BINARY = PlistFormat(2)
    const fmt_xml = try makeFmtInst(interp, "FMT_XML", 1);
    const fmt_bin = try makeFmtInst(interp, "FMT_BINARY", 2);
    try m.attrs.setStr(a, "FMT_XML", fmt_xml);
    try m.attrs.setStr(a, "FMT_BINARY", fmt_bin);

    // Classes
    try m.attrs.setStr(a, "PlistFormat", Value{ .class = interp.plist_fmt_class.? });
    try m.attrs.setStr(a, "InvalidFileException", Value{ .class = interp.plist_error_class.? });
    try m.attrs.setStr(a, "UID", Value{ .class = interp.plist_uid_class.? });

    // Register UID constructor as a callable function
    try regFn(interp, m, "UID", uidInitFn, null);

    // Functions
    try regFn(interp, m, "dumps", dumpsFn, dumpsKw);
    try regFn(interp, m, "loads", loadsFn, loadsKw);
    try regFn(interp, m, "dump", dumpFn, dumpKw);
    try regFn(interp, m, "load", loadFn, loadKw);

    // Store in interp
    interp.plistlib_module = m;

    return m;
}
