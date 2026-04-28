//! `quopri` module — quoted-printable encode/decode for fixture 212.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Bytes = @import("../object/bytes.zig").Bytes;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "quopri");
    try regKw(interp, m, "encodestring", encodestringFn, encodestringKw);
    try regKw(interp, m, "decodestring", decodestringFn, decodestringKw);
    return m;
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, f: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const bf = try interp.allocator.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f, .kw_func = kw };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = bf });
}

fn gi(p: *anyopaque) *Interp { return @ptrCast(@alignCast(p)); }

fn argBytes(v: Value) ![]const u8 {
    return switch (v) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        .str => |s| s.bytes,
        else => error.TypeError,
    };
}

fn kwBool(kw_names: []const Value, kw_values: []const Value, name: []const u8, def: bool) bool {
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, name)) return kv.isTruthy();
    }
    return def;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ── encodestring ─────────────────────────────────────────────────────────────

fn encodestringFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return encodestringKw(p, args, &.{}, &.{});
}

fn encodestringKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = argBytes(args[0]) catch {
        try interp.typeError("encodestring: expected bytes"); return error.TypeError;
    };
    const quotetabs = kwBool(kw_names, kw_values, "quotetabs", false);
    const header = kwBool(kw_names, kw_values, "header", false);
    const hex = "0123456789ABCDEF";

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    for (src) |c| {
        if (header and c == ' ') {
            try out.append(a,'_');
        } else if (c == '\n') {
            try out.append(a,'\n');
        } else if (c == '\r') {
            try out.append(a,'\r');
        } else if (c == '=') {
            try out.append(a,'='); try out.append(a,'3'); try out.append(a,'D');
        } else if ((c == ' ' or c == '\t') and quotetabs) {
            try out.append(a,'=');
            try out.append(a,hex[c >> 4]);
            try out.append(a,hex[c & 0xf]);
        } else if (c >= 0x21 and c <= 0x7e) {
            try out.append(a,c);
        } else if (c == ' ' or c == '\t') {
            try out.append(a,c);
        } else {
            try out.append(a,'=');
            try out.append(a,hex[c >> 4]);
            try out.append(a,hex[c & 0xf]);
        }
    }

    return Value{ .bytes = try Bytes.fromOwnedSlice(a, try out.toOwnedSlice(a)) };
}

// ── decodestring ─────────────────────────────────────────────────────────────

fn decodestringFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return decodestringKw(p, args, &.{}, &.{});
}

fn decodestringKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const src = argBytes(args[0]) catch {
        try interp.typeError("decodestring: expected bytes"); return error.TypeError;
    };
    const header = kwBool(kw_names, kw_values, "header", false);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (header and c == '_') {
            try out.append(a,' ');
            i += 1;
        } else if (c == '=' and i + 1 < src.len and src[i + 1] == '\n') {
            // soft line break — consume both
            i += 2;
        } else if (c == '=' and i + 2 < src.len) {
            const hi = hexNibble(src[i + 1]);
            const lo = hexNibble(src[i + 2]);
            if (hi != null and lo != null) {
                try out.append(a,(hi.? << 4) | lo.?);
                i += 3;
            } else {
                try out.append(a,c);
                i += 1;
            }
        } else {
            try out.append(a,c);
            i += 1;
        }
    }

    return Value{ .bytes = try Bytes.fromOwnedSlice(a, try out.toOwnedSlice(a)) };
}
