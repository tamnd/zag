//! Pinhole `codecs`: enough surface for fixtures. Supports utf-8,
//! ascii, latin-1, hex_codec, base64_codec, and rot_13. Error
//! handlers, lookup/getencoder/getdecoder, iterencode/iterdecode,
//! BOM constants, and charmap_build.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Str = @import("../object/string.zig").Str;
const Tuple = @import("../object/tuple.zig").Tuple;
const List = @import("../object/list.zig").List;
const Iter = @import("../object/iter.zig").Iter;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "codecs");

    try setBytes(a, m, "BOM_UTF8", &.{ 0xef, 0xbb, 0xbf });
    try setBytes(a, m, "BOM_UTF16_BE", &.{ 0xfe, 0xff });
    try setBytes(a, m, "BOM_UTF16_LE", &.{ 0xff, 0xfe });
    try setBytes(a, m, "BOM_UTF32_BE", &.{ 0x00, 0x00, 0xfe, 0xff });
    try setBytes(a, m, "BOM_UTF32_LE", &.{ 0xff, 0xfe, 0x00, 0x00 });
    // Aliases CPython exposes
    try setBytes(a, m, "BOM", &.{ 0xff, 0xfe });
    try setBytes(a, m, "BOM_UTF16", &.{ 0xff, 0xfe });
    try setBytes(a, m, "BOM_UTF32", &.{ 0xff, 0xfe, 0x00, 0x00 });
    try setBytes(a, m, "BOM_LE", &.{ 0xff, 0xfe });
    try setBytes(a, m, "BOM_BE", &.{ 0xfe, 0xff });

    try regAndStore(interp, m, "strict_errors", strictErrorsFn);
    try regAndStore(interp, m, "ignore_errors", ignoreErrorsFn);
    try regAndStore(interp, m, "replace_errors", replaceErrorsFn);
    try regAndStore(interp, m, "xmlcharrefreplace_errors", xmlcharrefreplaceErrorsFn);
    try regAndStore(interp, m, "backslashreplace_errors", backslashreplaceErrorsFn);

    // Pre-populate the registry with the built-in handlers so
    // lookup_error('strict') is codecs.strict_errors.
    const reg = try Dict.init(a);
    try reg.setStr(a, "strict", m.attrs.getStr("strict_errors").?);
    try reg.setStr(a, "ignore", m.attrs.getStr("ignore_errors").?);
    try reg.setStr(a, "replace", m.attrs.getStr("replace_errors").?);
    try reg.setStr(a, "xmlcharrefreplace", m.attrs.getStr("xmlcharrefreplace_errors").?);
    try reg.setStr(a, "backslashreplace", m.attrs.getStr("backslashreplace_errors").?);
    try m.attrs.setStr(a, "__error_registry__", Value{ .dict = reg });

    try reg2(interp, m, "encode", encodeFn);
    try reg2(interp, m, "decode", decodeFn);
    try reg2(interp, m, "lookup", lookupFn);
    try reg2(interp, m, "getencoder", getencoderFn);
    try reg2(interp, m, "getdecoder", getdecoderFn);
    try reg2(interp, m, "register_error", registerErrorFn);
    try reg2(interp, m, "lookup_error", lookupErrorFn);
    try reg2(interp, m, "iterencode", iterencodeFn);
    try reg2(interp, m, "iterdecode", iterdecodeFn);
    try reg2(interp, m, "charmap_build", charmapBuildFn);

    return m;
}

fn setBytes(a: std.mem.Allocator, m: *Module, name: []const u8, data: []const u8) !void {
    const owned = try a.dupe(u8, data);
    const b = try Bytes.fromOwnedSlice(a, owned);
    try m.attrs.setStr(a, name, Value{ .bytes = b });
}

fn reg2(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regAndStore(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

// ---- codec name normalization ----

const Codec = enum { utf8, ascii, latin1, hex_codec, base64_codec, rot13 };

fn canonicalName(c: Codec) []const u8 {
    return switch (c) {
        .utf8 => "utf-8",
        .ascii => "ascii",
        .latin1 => "iso8859-1",
        .hex_codec => "hex_codec",
        .base64_codec => "base64_codec",
        .rot13 => "rot_13",
    };
}

fn lookupCodec(name: []const u8) ?Codec {
    var buf: [64]u8 = undefined;
    if (name.len > 64) return null;
    for (name, 0..) |c, i| {
        var lc = std.ascii.toLower(c);
        if (lc == '_' or lc == ' ') lc = '-';
        buf[i] = lc;
    }
    const norm = buf[0..name.len];

    if (std.mem.eql(u8, norm, "utf-8") or std.mem.eql(u8, norm, "utf8") or
        std.mem.eql(u8, norm, "u8") or std.mem.eql(u8, norm, "utf"))
        return .utf8;
    if (std.mem.eql(u8, norm, "ascii") or std.mem.eql(u8, norm, "us-ascii") or
        std.mem.eql(u8, norm, "646"))
        return .ascii;
    if (std.mem.eql(u8, norm, "latin-1") or std.mem.eql(u8, norm, "iso-8859-1") or
        std.mem.eql(u8, norm, "iso8859-1") or std.mem.eql(u8, norm, "8859") or
        std.mem.eql(u8, norm, "cp819") or std.mem.eql(u8, norm, "l1") or
        std.mem.eql(u8, norm, "latin"))
        return .latin1;
    if (std.mem.eql(u8, norm, "hex") or std.mem.eql(u8, norm, "hex-codec"))
        return .hex_codec;
    if (std.mem.eql(u8, norm, "base64") or std.mem.eql(u8, norm, "base64-codec") or
        std.mem.eql(u8, norm, "base-64"))
        return .base64_codec;
    if (std.mem.eql(u8, norm, "rot-13") or std.mem.eql(u8, norm, "rot13"))
        return .rot13;
    return null;
}

// ---- error handler fns: receive (UnicodeError-like) instance, returns (replacement, new_pos) ----
// In our pinhole we keep the surface minimal: handlers are only called via the encode/decode
// paths below, never via Python user code dispatching them by hand. So they just have to be
// callable Values used for identity comparisons.

fn strictErrorsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    try interp.raisePy("UnicodeError", "strict error handler invoked");
    return error.PyException;
}
fn ignoreErrorsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value.none;
}
fn replaceErrorsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value.none;
}
fn xmlcharrefreplaceErrorsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value.none;
}
fn backslashreplaceErrorsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value.none;
}

// ---- encoding implementations ----

fn decodeUtf8FromBytes(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    const c0 = s[0];
    if (c0 < 0x80) return c0;
    if ((c0 & 0xE0) == 0xC0 and s.len >= 2) {
        return (@as(u32, c0 & 0x1F) << 6) | (s[1] & 0x3F);
    }
    if ((c0 & 0xF0) == 0xE0 and s.len >= 3) {
        return (@as(u32, c0 & 0x0F) << 12) | (@as(u32, s[1] & 0x3F) << 6) | (s[2] & 0x3F);
    }
    if ((c0 & 0xF8) == 0xF0 and s.len >= 4) {
        return (@as(u32, c0 & 0x07) << 18) | (@as(u32, s[1] & 0x3F) << 12) | (@as(u32, s[2] & 0x3F) << 6) | (s[3] & 0x3F);
    }
    return null;
}

fn utf8Length(c0: u8) usize {
    if (c0 < 0x80) return 1;
    if ((c0 & 0xE0) == 0xC0) return 2;
    if ((c0 & 0xF0) == 0xE0) return 3;
    if ((c0 & 0xF8) == 0xF0) return 4;
    return 1;
}

fn appendUtf8(a: std.mem.Allocator, out: *std.ArrayList(u8), cp: u32) !void {
    if (cp < 0x80) {
        try out.append(a, @intCast(cp));
    } else if (cp < 0x800) {
        try out.append(a, @intCast(0xC0 | (cp >> 6)));
        try out.append(a, @intCast(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        try out.append(a, @intCast(0xE0 | (cp >> 12)));
        try out.append(a, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try out.append(a, @intCast(0x80 | (cp & 0x3F)));
    } else {
        try out.append(a, @intCast(0xF0 | (cp >> 18)));
        try out.append(a, @intCast(0x80 | ((cp >> 12) & 0x3F)));
        try out.append(a, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try out.append(a, @intCast(0x80 | (cp & 0x3F)));
    }
}

const ErrorMode = enum { strict, ignore, replace, xmlcharrefreplace, backslashreplace };

fn errorModeFor(name: []const u8) ?ErrorMode {
    if (std.mem.eql(u8, name, "strict")) return .strict;
    if (std.mem.eql(u8, name, "ignore")) return .ignore;
    if (std.mem.eql(u8, name, "replace")) return .replace;
    if (std.mem.eql(u8, name, "xmlcharrefreplace")) return .xmlcharrefreplace;
    if (std.mem.eql(u8, name, "backslashreplace")) return .backslashreplace;
    return null;
}

fn errorModeFromValue(interp: *Interp, v: Value) !ErrorMode {
    if (v == .str) {
        if (errorModeFor(v.str.bytes)) |m| return m;
    }
    if (v == .builtin_fn) {
        // identity match against built-in handlers
        const m = interp.codecs_module orelse return .strict;
        if (m.attrs.getStr("strict_errors")) |h| if (h.identityEq(v)) return .strict;
        if (m.attrs.getStr("ignore_errors")) |h| if (h.identityEq(v)) return .ignore;
        if (m.attrs.getStr("replace_errors")) |h| if (h.identityEq(v)) return .replace;
        if (m.attrs.getStr("xmlcharrefreplace_errors")) |h| if (h.identityEq(v)) return .xmlcharrefreplace;
        if (m.attrs.getStr("backslashreplace_errors")) |h| if (h.identityEq(v)) return .backslashreplace;
    }
    try interp.raisePy("LookupError", "unknown error handler");
    return error.PyException;
}

fn encodeAscii(a: std.mem.Allocator, s: []const u8, mode: ErrorMode, interp: *Interp) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    var i: usize = 0;
    while (i < s.len) {
        const len = utf8Length(s[i]);
        if (len == 1 and s[i] < 0x80) {
            try out.append(a, s[i]);
            i += 1;
            continue;
        }
        if (i + len > s.len) {
            // truncated input; treat the rest as opaque
            i = s.len;
            break;
        }
        const cp = decodeUtf8FromBytes(s[i .. i + len]) orelse {
            i += 1;
            continue;
        };
        switch (mode) {
            .strict => {
                try interp.raisePy("UnicodeEncodeError", "ascii codec can't encode character");
                return error.PyException;
            },
            .ignore => {},
            .replace => try out.append(a, '?'),
            .xmlcharrefreplace => {
                var buf: [16]u8 = undefined;
                const written = std.fmt.bufPrint(&buf, "&#{d};", .{cp}) catch unreachable;
                try out.appendSlice(a, written);
            },
            .backslashreplace => try writeBackslashEscape(a, &out, cp),
        }
        i += len;
    }
    return try out.toOwnedSlice(a);
}

fn writeBackslashEscape(a: std.mem.Allocator, out: *std.ArrayList(u8), cp: u32) !void {
    var buf: [16]u8 = undefined;
    const text = if (cp <= 0xFF)
        std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{cp}) catch unreachable
    else if (cp <= 0xFFFF)
        std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{cp}) catch unreachable
    else
        std.fmt.bufPrint(&buf, "\\U{x:0>8}", .{cp}) catch unreachable;
    try out.appendSlice(a, text);
}

fn encodeLatin1(a: std.mem.Allocator, s: []const u8, mode: ErrorMode, interp: *Interp) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    var i: usize = 0;
    while (i < s.len) {
        const len = utf8Length(s[i]);
        if (len == 1 and s[i] < 0x80) {
            try out.append(a, s[i]);
            i += 1;
            continue;
        }
        if (i + len > s.len) {
            i = s.len;
            break;
        }
        const cp = decodeUtf8FromBytes(s[i .. i + len]) orelse {
            i += 1;
            continue;
        };
        if (cp <= 0xFF) {
            try out.append(a, @intCast(cp));
        } else {
            switch (mode) {
                .strict => {
                    try interp.raisePy("UnicodeEncodeError", "latin-1 codec can't encode character");
                    return error.PyException;
                },
                .ignore => {},
                .replace => try out.append(a, '?'),
                .xmlcharrefreplace => {
                    var buf: [16]u8 = undefined;
                    const written = std.fmt.bufPrint(&buf, "&#{d};", .{cp}) catch unreachable;
                    try out.appendSlice(a, written);
                },
                .backslashreplace => try writeBackslashEscape(a, &out, cp),
            }
        }
        i += len;
    }
    return try out.toOwnedSlice(a);
}

fn decodeAscii(a: std.mem.Allocator, b: []const u8, mode: ErrorMode, interp: *Interp) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    for (b) |c| {
        if (c < 0x80) {
            try out.append(a, c);
        } else {
            switch (mode) {
                .strict => {
                    try interp.raisePy("UnicodeDecodeError", "ascii codec can't decode byte");
                    return error.PyException;
                },
                .ignore => {},
                .replace => try appendUtf8(a, &out, 0xFFFD),
                .xmlcharrefreplace => try appendUtf8(a, &out, 0xFFFD),
                .backslashreplace => {
                    var buf: [8]u8 = undefined;
                    const written = std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{c}) catch unreachable;
                    try out.appendSlice(a, written);
                },
            }
        }
    }
    return try out.toOwnedSlice(a);
}

fn decodeLatin1(a: std.mem.Allocator, b: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (b) |c| {
        try appendUtf8(a, &out, c);
    }
    return try out.toOwnedSlice(a);
}

fn encodeHex(a: std.mem.Allocator, b: []const u8) ![]u8 {
    const hex = "0123456789abcdef";
    const out = try a.alloc(u8, b.len * 2);
    for (b, 0..) |x, i| {
        out[i * 2] = hex[x >> 4];
        out[i * 2 + 1] = hex[x & 0xF];
    }
    return out;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn decodeHex(a: std.mem.Allocator, b: []const u8, interp: *Interp) ![]u8 {
    if (b.len % 2 != 0) {
        try interp.raisePy("ValueError", "non-hexadecimal number found");
        return error.PyException;
    }
    const out = try a.alloc(u8, b.len / 2);
    var i: usize = 0;
    while (i < b.len) : (i += 2) {
        const hi = hexNibble(b[i]) orelse {
            a.free(out);
            try interp.raisePy("ValueError", "non-hexadecimal number found");
            return error.PyException;
        };
        const lo = hexNibble(b[i + 1]) orelse {
            a.free(out);
            try interp.raisePy("ValueError", "non-hexadecimal number found");
            return error.PyException;
        };
        out[i / 2] = (hi << 4) | lo;
    }
    return out;
}

fn encodeBase64(a: std.mem.Allocator, b: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out_len = enc.calcSize(b.len);
    const out = try a.alloc(u8, out_len + 1);
    _ = enc.encode(out[0..out_len], b);
    out[out_len] = '\n';
    return out;
}

fn decodeBase64(a: std.mem.Allocator, b: []const u8, interp: *Interp) ![]u8 {
    // strip whitespace
    var trimmed: std.ArrayList(u8) = .empty;
    defer trimmed.deinit(a);
    for (b) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        try trimmed.append(a, c);
    }
    const dec = std.base64.standard.Decoder;
    const len = dec.calcSizeForSlice(trimmed.items) catch {
        try interp.raisePy("ValueError", "invalid base64");
        return error.PyException;
    };
    const out = try a.alloc(u8, len);
    dec.decode(out, trimmed.items) catch {
        a.free(out);
        try interp.raisePy("ValueError", "invalid base64");
        return error.PyException;
    };
    return out;
}

fn encodeRot13(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try a.dupe(u8, s);
    for (out) |*c| {
        const x = c.*;
        if (x >= 'a' and x <= 'z') c.* = 'a' + (x - 'a' + 13) % 26;
        if (x >= 'A' and x <= 'Z') c.* = 'A' + (x - 'A' + 13) % 26;
    }
    return out;
}

fn extractData(v: Value) ?[]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        else => null,
    };
}

fn extractErrors(interp: *Interp, args: []const Value, idx: usize) !ErrorMode {
    if (args.len > idx) return errorModeFromValue(interp, args[idx]);
    return .strict;
}

fn extractCodec(interp: *Interp, args: []const Value, idx: usize) !Codec {
    if (args.len <= idx or args[idx] != .str) return .utf8;
    const c = lookupCodec(args[idx].str.bytes);
    if (c) |cc| return cc;
    try interp.raisePy("LookupError", "unknown encoding");
    return error.PyException;
}

// Return the result of encode(input) where input is a str.
fn encodeOnce(interp: *Interp, codec: Codec, mode: ErrorMode, input: Value) !Value {
    const a = interp.allocator;
    switch (codec) {
        .utf8 => {
            const data = extractData(input) orelse {
                try interp.typeError("encode requires str");
                return error.TypeError;
            };
            const owned = try a.dupe(u8, data);
            return Value{ .bytes = try Bytes.fromOwnedSlice(a, owned) };
        },
        .ascii => {
            const data = extractData(input) orelse {
                try interp.typeError("encode requires str");
                return error.TypeError;
            };
            const out = try encodeAscii(a, data, mode, interp);
            return Value{ .bytes = try Bytes.fromOwnedSlice(a, out) };
        },
        .latin1 => {
            const data = extractData(input) orelse {
                try interp.typeError("encode requires str");
                return error.TypeError;
            };
            const out = try encodeLatin1(a, data, mode, interp);
            return Value{ .bytes = try Bytes.fromOwnedSlice(a, out) };
        },
        .hex_codec => {
            const data = extractData(input) orelse {
                try interp.typeError("encode requires bytes");
                return error.TypeError;
            };
            const out = try encodeHex(a, data);
            return Value{ .bytes = try Bytes.fromOwnedSlice(a, out) };
        },
        .base64_codec => {
            const data = extractData(input) orelse {
                try interp.typeError("encode requires bytes");
                return error.TypeError;
            };
            const out = try encodeBase64(a, data);
            return Value{ .bytes = try Bytes.fromOwnedSlice(a, out) };
        },
        .rot13 => {
            // rot_13 is a text transform: str -> str
            const data = extractData(input) orelse {
                try interp.typeError("encode requires str");
                return error.TypeError;
            };
            const out = try encodeRot13(a, data);
            return Value{ .str = try Str.fromOwnedSlice(a, out) };
        },
    }
}

fn decodeOnce(interp: *Interp, codec: Codec, mode: ErrorMode, input: Value) !Value {
    const a = interp.allocator;
    switch (codec) {
        .utf8 => {
            const data = extractData(input) orelse {
                try interp.typeError("decode requires bytes");
                return error.TypeError;
            };
            const owned = try a.dupe(u8, data);
            return Value{ .str = try Str.fromOwnedSlice(a, owned) };
        },
        .ascii => {
            const data = extractData(input) orelse {
                try interp.typeError("decode requires bytes");
                return error.TypeError;
            };
            const out = try decodeAscii(a, data, mode, interp);
            return Value{ .str = try Str.fromOwnedSlice(a, out) };
        },
        .latin1 => {
            const data = extractData(input) orelse {
                try interp.typeError("decode requires bytes");
                return error.TypeError;
            };
            const out = try decodeLatin1(a, data);
            return Value{ .str = try Str.fromOwnedSlice(a, out) };
        },
        .hex_codec => {
            const data = extractData(input) orelse {
                try interp.typeError("decode requires bytes");
                return error.TypeError;
            };
            const out = try decodeHex(a, data, interp);
            return Value{ .bytes = try Bytes.fromOwnedSlice(a, out) };
        },
        .base64_codec => {
            const data = extractData(input) orelse {
                try interp.typeError("decode requires bytes");
                return error.TypeError;
            };
            const out = try decodeBase64(a, data, interp);
            return Value{ .bytes = try Bytes.fromOwnedSlice(a, out) };
        },
        .rot13 => {
            const data = extractData(input) orelse {
                try interp.typeError("decode requires str");
                return error.TypeError;
            };
            const out = try encodeRot13(a, data);
            return Value{ .str = try Str.fromOwnedSlice(a, out) };
        },
    }
}

// ---- module-level functions ----

fn encodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) {
        try interp.typeError("encode() missing required argument");
        return error.TypeError;
    }
    const codec = try extractCodec(interp, args, 1);
    const mode = try extractErrors(interp, args, 2);
    return encodeOnce(interp, codec, mode, args[0]);
}

fn decodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) {
        try interp.typeError("decode() missing required argument");
        return error.TypeError;
    }
    const codec = try extractCodec(interp, args, 1);
    const mode = try extractErrors(interp, args, 2);
    return decodeOnce(interp, codec, mode, args[0]);
}

fn lookupFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("lookup() requires a string");
        return error.TypeError;
    }
    const c = lookupCodec(args[0].str.bytes) orelse {
        try interp.raisePy("LookupError", "unknown encoding");
        return error.PyException;
    };
    try ensureCodecInfoClass(interp);
    const inst = try Instance.init(a, interp.codecs_codecinfo_class.?);
    try inst.dict.setStr(a, "name", Value{ .str = try Str.init(a, lookupName(c)) });
    try inst.dict.setStr(a, "_codec_tag", Value{ .small_int = @intCast(@intFromEnum(c)) });

    const enc = try a.create(BuiltinFn);
    enc.* = .{ .name = "encode", .func = codecInfoEncodeFn };
    try inst.dict.setStr(a, "encode", Value{ .builtin_fn = enc });

    const dec = try a.create(BuiltinFn);
    dec.* = .{ .name = "decode", .func = codecInfoDecodeFn };
    try inst.dict.setStr(a, "decode", Value{ .builtin_fn = dec });

    return Value{ .instance = inst };
}

fn lookupName(c: Codec) []const u8 {
    return switch (c) {
        .utf8 => "utf-8",
        .ascii => "ascii",
        .latin1 => "iso8859-1",
        .hex_codec => "hex_codec",
        .base64_codec => "base64_codec",
        .rot13 => "rot_13",
    };
}

fn ensureCodecInfoClass(interp: *Interp) !void {
    if (interp.codecs_codecinfo_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    interp.codecs_codecinfo_class = try Class.init(a, "CodecInfo", &.{}, d);
}

fn codecInfoTagFromArgs(args: []const Value) ?Codec {
    if (args.len < 1 or args[0] != .instance) return null;
    const tag = args[0].instance.dict.getStr("_codec_tag") orelse return null;
    if (tag != .small_int) return null;
    const n: usize = @intCast(tag.small_int);
    if (n > @intFromEnum(Codec.rot13)) return null;
    return @enumFromInt(n);
}

fn codecInfoEncodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const codec = codecInfoTagFromArgs(args) orelse {
        try interp.typeError("CodecInfo.encode missing self");
        return error.TypeError;
    };
    if (args.len < 2) {
        try interp.typeError("encode() requires input");
        return error.TypeError;
    }
    const mode = try extractErrors(interp, args, 2);
    const out = try encodeOnce(interp, codec, mode, args[1]);
    const len = countCodepointsValue(out);
    const t = try Tuple.init(a, 2);
    t.items[0] = out;
    t.items[1] = Value{ .small_int = @intCast(len) };
    return Value{ .tuple = t };
}

fn codecInfoDecodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const codec = codecInfoTagFromArgs(args) orelse {
        try interp.typeError("CodecInfo.decode missing self");
        return error.TypeError;
    };
    if (args.len < 2) {
        try interp.typeError("decode() requires input");
        return error.TypeError;
    }
    const mode = try extractErrors(interp, args, 2);
    const out = try decodeOnce(interp, codec, mode, args[1]);

    // Length here is the input length (CPython semantics: bytes consumed).
    const inlen = switch (args[1]) {
        .bytes => |b| b.data.len,
        .bytearray => |b| b.data.items.len,
        .str => |s| std.unicode.utf8CountCodepoints(s.bytes) catch s.bytes.len,
        else => 0,
    };
    const t = try Tuple.init(a, 2);
    t.items[0] = out;
    t.items[1] = Value{ .small_int = @intCast(inlen) };
    return Value{ .tuple = t };
}

fn countCodepointsValue(v: Value) usize {
    return switch (v) {
        .str => |s| std.unicode.utf8CountCodepoints(s.bytes) catch s.bytes.len,
        .bytes => |b| b.data.len,
        .bytearray => |b| b.data.items.len,
        else => 0,
    };
}

// getencoder / getdecoder return a callable that takes (input[, errors])
// and returns (output, length). We synthesize a builtin_fn whose closure
// embeds the codec via a cached_fn-style instance is cleaner... but we
// can store the codec tag as the function name suffix. Simpler:
// return a small Instance with a builtin_fn that reads the tag.

fn getencoderFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("getencoder() requires a string");
        return error.TypeError;
    }
    const codec = lookupCodec(args[0].str.bytes) orelse {
        try interp.raisePy("LookupError", "unknown encoding");
        return error.PyException;
    };
    try ensureEncoderClass(interp);
    const inst = try Instance.init(a, interp.codecs_encoder_class.?);
    try inst.dict.setStr(a, "_codec_tag", Value{ .small_int = @intCast(@intFromEnum(codec)) });
    return Value{ .instance = inst };
}

fn getdecoderFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("getdecoder() requires a string");
        return error.TypeError;
    }
    const codec = lookupCodec(args[0].str.bytes) orelse {
        try interp.raisePy("LookupError", "unknown encoding");
        return error.PyException;
    };
    try ensureDecoderClass(interp);
    const inst = try Instance.init(a, interp.codecs_decoder_class.?);
    try inst.dict.setStr(a, "_codec_tag", Value{ .small_int = @intCast(@intFromEnum(codec)) });
    return Value{ .instance = inst };
}

fn ensureEncoderClass(interp: *Interp) !void {
    if (interp.codecs_encoder_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = "__call__", .func = encoderCallFn };
    try d.setStr(a, "__call__", Value{ .builtin_fn = f });
    interp.codecs_encoder_class = try Class.init(a, "Encoder", &.{}, d);
}

fn ensureDecoderClass(interp: *Interp) !void {
    if (interp.codecs_decoder_class != null) return;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = "__call__", .func = decoderCallFn };
    try d.setStr(a, "__call__", Value{ .builtin_fn = f });
    interp.codecs_decoder_class = try Class.init(a, "Decoder", &.{}, d);
}

fn encoderCallFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const codec = codecInfoTagFromArgs(args) orelse {
        try interp.typeError("encoder missing self");
        return error.TypeError;
    };
    if (args.len < 2) {
        try interp.typeError("encoder requires input");
        return error.TypeError;
    }
    const mode = try extractErrors(interp, args, 2);
    const out = try encodeOnce(interp, codec, mode, args[1]);
    const len = countCodepointsValue(args[1]);
    const t = try Tuple.init(a, 2);
    t.items[0] = out;
    t.items[1] = Value{ .small_int = @intCast(len) };
    return Value{ .tuple = t };
}

fn decoderCallFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const codec = codecInfoTagFromArgs(args) orelse {
        try interp.typeError("decoder missing self");
        return error.TypeError;
    };
    if (args.len < 2) {
        try interp.typeError("decoder requires input");
        return error.TypeError;
    }
    const mode = try extractErrors(interp, args, 2);
    const out = try decodeOnce(interp, codec, mode, args[1]);
    const inlen = switch (args[1]) {
        .bytes => |b| b.data.len,
        .bytearray => |b| b.data.items.len,
        .str => |s| s.bytes.len,
        else => 0,
    };
    const t = try Tuple.init(a, 2);
    t.items[0] = out;
    t.items[1] = Value{ .small_int = @intCast(inlen) };
    return Value{ .tuple = t };
}

// ---- error handler registry ----

fn errorRegistry(interp: *Interp) !*Dict {
    const m = interp.codecs_module orelse return error.RuntimeError;
    if (m.attrs.getStr("__error_registry__")) |v| {
        if (v == .dict) return v.dict;
    }
    return error.RuntimeError;
}

fn registerErrorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .str) {
        try interp.typeError("register_error() requires a name and handler");
        return error.TypeError;
    }
    const reg = try errorRegistry(interp);
    try reg.setStr(interp.allocator, args[0].str.bytes, args[1]);
    return Value.none;
}

fn lookupErrorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("lookup_error() requires a string");
        return error.TypeError;
    }
    const reg = try errorRegistry(interp);
    if (reg.getStr(args[0].str.bytes)) |v| return v;
    try interp.raisePy("LookupError", "unknown error handler");
    return error.PyException;
}

// ---- iterencode / iterdecode ----

fn iterencodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.typeError("iterencode() missing required argument");
        return error.TypeError;
    }
    const codec = try extractCodec(interp, args, 1);
    const mode = try extractErrors(interp, args, 2);
    const lst = try List.init(a);
    var idx: usize = 0;
    const src = args[0];
    while (try iterableNextValue(interp, src, &idx)) |chunk| {
        const enc = try encodeOnce(interp, codec, mode, chunk);
        try lst.items.append(a, enc);
    }
    const it = try Iter.init(a, .{ .list = lst });
    return Value{ .iter = it };
}

fn iterdecodeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.typeError("iterdecode() missing required argument");
        return error.TypeError;
    }
    const codec = try extractCodec(interp, args, 1);
    const mode = try extractErrors(interp, args, 2);
    const lst = try List.init(a);
    var idx: usize = 0;
    const src = args[0];
    while (try iterableNextValue(interp, src, &idx)) |chunk| {
        const dec = try decodeOnce(interp, codec, mode, chunk);
        try lst.items.append(a, dec);
    }
    const it = try Iter.init(a, .{ .list = lst });
    return Value{ .iter = it };
}

fn iterableNextValue(interp: *Interp, src: Value, idx: *usize) !?Value {
    _ = interp;
    switch (src) {
        .list => |l| {
            if (idx.* >= l.items.items.len) return null;
            const v = l.items.items[idx.*];
            idx.* += 1;
            return v;
        },
        .tuple => |t| {
            if (idx.* >= t.items.len) return null;
            const v = t.items[idx.*];
            idx.* += 1;
            return v;
        },
        else => return null,
    }
}

// ---- charmap_build ----

fn charmapBuildFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("charmap_build() requires a string");
        return error.TypeError;
    }
    const s = args[0].str.bytes;
    const d = try Dict.init(a);
    var i: usize = 0;
    var idx: i64 = 0;
    while (i < s.len) {
        const len = utf8Length(s[i]);
        if (i + len > s.len) break;
        const cp = decodeUtf8FromBytes(s[i .. i + len]) orelse {
            i += 1;
            continue;
        };
        try d.setKey(a, Value{ .small_int = @intCast(cp) }, Value{ .small_int = idx });
        i += len;
        idx += 1;
    }
    return Value{ .dict = d };
}
