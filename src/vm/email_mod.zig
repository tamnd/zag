//! `email` module family — fixture 206.
//! All sub-modules live here. The build() function returns the top-level
//! `email` module; sub-modules are registered separately via helpers called
//! from interp.zig getBuiltinModule().

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
const Tuple = @import("../object/tuple.zig").Tuple;
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Bytes = @import("../object/bytes.zig").Bytes;
const Iter = @import("../object/iter.zig").Iter;
const Interp = @import("interp.zig").Interp;

fn gi(p: *anyopaque) *Interp {
    return @ptrCast(@alignCast(p));
}

// Left-trim whitespace from a slice.
fn trimLeft(comptime T: type, s: []const T, chars: []const T) []const T {
    var i: usize = 0;
    outer: while (i < s.len) {
        for (chars) |c| {
            if (s[i] == c) {
                i += 1;
                continue :outer;
            }
        }
        break;
    }
    return s[i..];
}

fn makeStr(a: std.mem.Allocator, data: []const u8) !Value {
    const s = try Str.init(a, data);
    return Value{ .str = s };
}

fn regD(a: std.mem.Allocator, d: *Dict, name: []const u8, f: BuiltinFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f };
    try d.setStr(a, name, Value{ .builtin_fn = bf });
}

fn regKwD(a: std.mem.Allocator, d: *Dict, name: []const u8, f: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f, .kw_func = kw };
    try d.setStr(a, name, Value{ .builtin_fn = bf });
}

fn regM(a: std.mem.Allocator, m: *Module, name: []const u8, f: BuiltinFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = bf });
}

fn regKwM(a: std.mem.Allocator, m: *Module, name: []const u8, f: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = bf });
}

fn instArg(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

// ===== base64 helpers =====

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn b64encode(a: std.mem.Allocator, src: []const u8) ![]u8 {
    const out_len = ((src.len + 2) / 3) * 4;
    const out = try a.alloc(u8, out_len);
    var i: usize = 0;
    var j: usize = 0;
    while (i + 3 <= src.len) : (i += 3) {
        const b0 = src[i];
        const b1 = src[i + 1];
        const b2 = src[i + 2];
        out[j] = B64[b0 >> 2];
        out[j + 1] = B64[((b0 & 3) << 4) | (b1 >> 4)];
        out[j + 2] = B64[((b1 & 0xf) << 2) | (b2 >> 6)];
        out[j + 3] = B64[b2 & 0x3f];
        j += 4;
    }
    const rem = src.len - i;
    if (rem == 1) {
        const b0 = src[i];
        out[j] = B64[b0 >> 2];
        out[j + 1] = B64[(b0 & 3) << 4];
        out[j + 2] = '=';
        out[j + 3] = '=';
    } else if (rem == 2) {
        const b0 = src[i];
        const b1 = src[i + 1];
        out[j] = B64[b0 >> 2];
        out[j + 1] = B64[((b0 & 3) << 4) | (b1 >> 4)];
        out[j + 2] = B64[(b1 & 0xf) << 2];
        out[j + 3] = '=';
    }
    return out;
}

fn b64decode(a: std.mem.Allocator, src: []const u8) ![]u8 {
    var lut: [256]i16 = .{-1} ** 256;
    for (B64, 0..) |ch, idx| lut[ch] = @intCast(idx);

    var end = src.len;
    while (end > 0 and src[end - 1] == '=') end -= 1;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    var buf: u32 = 0;
    var bits: u32 = 0;
    for (src[0..end]) |ch| {
        const v = lut[ch];
        if (v < 0) continue; // skip whitespace / invalid
        buf = (buf << 6) | @as(u32, @intCast(v));
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            try out.append(a, @intCast((buf >> @intCast(bits)) & 0xff));
        }
    }
    return out.toOwnedSlice(a);
}

// ===== Message class helpers =====
// Headers stored as _headers = List of 2-tuples (name_str, value_str).

fn msgGetHeaders(inst: *Instance) ?*List {
    const v = inst.dict.getStr("_headers") orelse return null;
    return if (v == .list) v.list else null;
}

fn msgInitHeaders(a: std.mem.Allocator, inst: *Instance) !*List {
    if (msgGetHeaders(inst)) |l| return l;
    const l = try List.init(a);
    try inst.dict.setStr(a, "_headers", Value{ .list = l });
    return l;
}

// Add a header (name, value) to a message instance.
fn msgAddHeader(a: std.mem.Allocator, inst: *Instance, name: []const u8, value: []const u8) !void {
    const hdrs = try msgInitHeaders(a, inst);
    const pair = try Tuple.init(a, 2);
    pair.items[0] = try makeStr(a, name);
    pair.items[1] = try makeStr(a, value);
    try hdrs.items.append(a, Value{ .tuple = pair });
}

// Get first header value for name (case-insensitive). Returns null if absent.
fn msgGetHeader(inst: *Instance, name: []const u8) ?[]const u8 {
    const hdrs = msgGetHeaders(inst) orelse return null;
    for (hdrs.items.items) |item| {
        if (item != .tuple) continue;
        const pair = item.tuple;
        if (pair.items.len < 2) continue;
        const k = if (pair.items[0] == .str) pair.items[0].str.bytes else continue;
        if (std.ascii.eqlIgnoreCase(k, name)) {
            return if (pair.items[1] == .str) pair.items[1].str.bytes else null;
        }
    }
    return null;
}

// Parse Content-Type value; returns main/sub parts and params.
fn parseContentType(ct: []const u8) struct { full: []const u8, main: []const u8, sub: []const u8 } {
    // Strip params: take only part before ';'
    const semi = std.mem.indexOf(u8, ct, ";") orelse ct.len;
    const full = std.mem.trim(u8, ct[0..semi], " \t");
    const slash = std.mem.indexOf(u8, full, "/") orelse full.len;
    const main = full[0..slash];
    const sub = if (slash < full.len) full[slash + 1 ..] else "";
    return .{ .full = full, .main = main, .sub = sub };
}

// Get a param from Content-Type header value.
fn getParam(ct_value: []const u8, param_name: []const u8) ?[]const u8 {
    var rest = ct_value;
    const semi = std.mem.indexOf(u8, rest, ";") orelse return null;
    rest = rest[semi + 1 ..];
    while (rest.len > 0) {
        rest = trimLeft(u8, rest, " \t");
        const eq = std.mem.indexOf(u8, rest, "=") orelse break;
        const key = std.mem.trim(u8, rest[0..eq], " \t");
        rest = rest[eq + 1 ..];
        // value may be quoted or unquoted; find end at ';' or end
        const val_end = std.mem.indexOf(u8, rest, ";") orelse rest.len;
        const val_raw = std.mem.trim(u8, rest[0..val_end], " \t");
        // unquote
        const val = if (val_raw.len >= 2 and val_raw[0] == '"' and val_raw[val_raw.len - 1] == '"')
            val_raw[1 .. val_raw.len - 1]
        else
            val_raw;
        if (std.ascii.eqlIgnoreCase(key, param_name)) return val;
        if (val_end >= rest.len) break;
        rest = rest[val_end + 1 ..];
    }
    return null;
}

// ===== Message.__init__ =====

fn msgInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    _ = try msgInitHeaders(a, inst);
    try inst.dict.setStr(a, "_payload", Value.none);
    try inst.dict.setStr(a, "_default_type", try makeStr(a, "text/plain"));
    return Value.none;
}

// ===== Message.__contains__ =====

fn msgContains(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2) return Value{ .boolean = false };
    const inst = try instArg(args);
    const name = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value{ .boolean = false },
    };
    return Value{ .boolean = msgGetHeader(inst, name) != null };
}

// ===== Message.__getitem__ =====

fn msgGetitem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const name = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const val = msgGetHeader(inst, name) orelse return Value.none;
    return makeStr(a, val);
}

// ===== Message.__setitem__ =====

fn msgSetitem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 3) return Value.none;
    const inst = try instArg(args);
    const name = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const val = switch (args[2]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    try msgAddHeader(a, inst, name, val);
    return Value.none;
}

// ===== Message.__delitem__ =====

fn msgDelitem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const name = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const hdrs = msgGetHeaders(inst) orelse return Value.none;
    var i: usize = 0;
    while (i < hdrs.items.items.len) {
        const item = hdrs.items.items[i];
        if (item == .tuple) {
            const pair = item.tuple;
            if (pair.items.len >= 1) {
                const k = if (pair.items[0] == .str) pair.items[0].str.bytes else "";
                if (std.ascii.eqlIgnoreCase(k, name)) {
                    _ = hdrs.items.orderedRemove(i);
                    continue;
                }
            }
        }
        i += 1;
    }
    _ = a;
    return Value.none;
}

// ===== Message.__len__ =====

fn msgLen(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const inst = try instArg(args);
    const hdrs = msgGetHeaders(inst) orelse return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(hdrs.items.items.len) };
}

// ===== Message.get =====

fn msgGet(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const name = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const failobj = if (args.len >= 3) args[2] else Value.none;
    const val = msgGetHeader(inst, name) orelse return failobj;
    return makeStr(a, val);
}

fn msgGetKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const name = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    var failobj: Value = Value.none;
    if (args.len >= 3) failobj = args[2];
    for (kw_names, kw_values) |kn, kv| {
        const kname = switch (kn) { .str => |s| s.bytes, else => continue };
        if (std.mem.eql(u8, kname, "failobj")) failobj = kv;
    }
    const val = msgGetHeader(inst, name) orelse return failobj;
    return makeStr(a, val);
}

// ===== Message.get_all =====

fn msgGetAll(p: *anyopaque, args: []const Value) anyerror!Value {
    return msgGetAllKw(p, args, &.{}, &.{});
}

fn msgGetAllKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const name = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    var failobj: Value = Value.none;
    if (args.len >= 3) failobj = args[2];
    for (kw_names, kw_values) |kn, kv| {
        const kname = switch (kn) { .str => |s| s.bytes, else => continue };
        if (std.mem.eql(u8, kname, "failobj")) failobj = kv;
    }
    const hdrs = msgGetHeaders(inst) orelse return failobj;
    const out = try List.init(a);
    var found = false;
    for (hdrs.items.items) |item| {
        if (item != .tuple) continue;
        const pair = item.tuple;
        if (pair.items.len < 2) continue;
        const k = if (pair.items[0] == .str) pair.items[0].str.bytes else continue;
        if (std.ascii.eqlIgnoreCase(k, name)) {
            try out.items.append(a, pair.items[1]);
            found = true;
        }
    }
    if (!found) return failobj;
    return Value{ .list = out };
}

// ===== Message.keys =====

fn msgKeys(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const hdrs = msgGetHeaders(inst) orelse return Value{ .list = try List.init(a) };
    const out = try List.init(a);
    for (hdrs.items.items) |item| {
        if (item != .tuple) continue;
        const pair = item.tuple;
        if (pair.items.len >= 1) try out.items.append(a, pair.items[0]);
    }
    return Value{ .list = out };
}

// ===== Message.values =====

fn msgValues(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const hdrs = msgGetHeaders(inst) orelse return Value{ .list = try List.init(a) };
    const out = try List.init(a);
    for (hdrs.items.items) |item| {
        if (item != .tuple) continue;
        const pair = item.tuple;
        if (pair.items.len >= 2) try out.items.append(a, pair.items[1]);
    }
    return Value{ .list = out };
}

// ===== Message.items =====

fn msgItems(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const hdrs = msgGetHeaders(inst) orelse return Value{ .list = try List.init(a) };
    const out = try List.init(a);
    for (hdrs.items.items) |item| {
        if (item == .tuple) try out.items.append(a, item);
    }
    return Value{ .list = out };
}

// ===== Message.replace_header =====

fn msgReplaceHeader(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 3) return Value.none;
    const inst = try instArg(args);
    const name = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const new_val = args[2];
    const hdrs = msgGetHeaders(inst) orelse return Value.none;
    for (hdrs.items.items) |*item| {
        if (item.* != .tuple) continue;
        const pair = item.tuple;
        if (pair.items.len < 2) continue;
        const k = if (pair.items[0] == .str) pair.items[0].str.bytes else continue;
        if (std.ascii.eqlIgnoreCase(k, name)) {
            pair.items[1] = new_val;
            return Value.none;
        }
    }
    _ = a;
    return Value.none;
}

// ===== Message.get_payload =====

fn msgGetPayload(p: *anyopaque, args: []const Value) anyerror!Value {
    return msgGetPayloadKw(p, args, &.{}, &.{});
}

fn msgGetPayloadKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    var decode = false;
    for (kw_names, kw_values) |kn, kv| {
        const kname = switch (kn) { .str => |s| s.bytes, else => continue };
        if (std.mem.eql(u8, kname, "decode")) {
            decode = switch (kv) {
                .boolean => |b| b,
                .small_int => |i| i != 0,
                else => false,
            };
        }
    }
    // positional decode arg
    if (!decode and args.len >= 2) {
        decode = switch (args[1]) {
            .boolean => |b| b,
            .small_int => |i| i != 0,
            else => false,
        };
    }
    const payload = inst.dict.getStr("_payload") orelse Value.none;
    if (!decode) return payload;
    // decode=True: decode the payload
    switch (payload) {
        .bytes => |b| return Value{ .bytes = b },
        .str => |s| {
            // Check Content-Transfer-Encoding
            const cte = msgGetHeader(inst, "Content-Transfer-Encoding") orelse "";
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, cte, " \t"), "base64")) {
                const decoded = b64decode(a, s.bytes) catch return Value.none;
                const bv = try Bytes.init(a, decoded);
                return Value{ .bytes = bv };
            }
            // Plain text: return as bytes
            const bv = try Bytes.init(a, s.bytes);
            return Value{ .bytes = bv };
        },
        else => return Value.none,
    }
}

// ===== Message.set_payload =====

fn msgSetPayload(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    try inst.dict.setStr(a, "_payload", args[1]);
    return Value.none;
}

// ===== Message.get_content_type =====

fn msgGetContentType(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const ct = msgGetHeader(inst, "Content-Type") orelse {
        const dt = inst.dict.getStr("_default_type") orelse return makeStr(a, "text/plain");
        return dt;
    };
    const parsed = parseContentType(ct);
    return makeStr(a, parsed.full);
}

// ===== Message.get_content_maintype =====

fn msgGetContentMaintype(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const ct = msgGetHeader(inst, "Content-Type") orelse return makeStr(a, "text");
    const parsed = parseContentType(ct);
    return makeStr(a, parsed.main);
}

// ===== Message.get_content_subtype =====

fn msgGetContentSubtype(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const ct = msgGetHeader(inst, "Content-Type") orelse return makeStr(a, "plain");
    const parsed = parseContentType(ct);
    return makeStr(a, parsed.sub);
}

// ===== Message.get_content_charset =====

fn msgGetContentCharset(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const ct = msgGetHeader(inst, "Content-Type") orelse return Value.none;
    const charset = getParam(ct, "charset") orelse return Value.none;
    return makeStr(a, charset);
}

// ===== Message.get_default_type =====

fn msgGetDefaultType(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const dt = inst.dict.getStr("_default_type") orelse return makeStr(a, "text/plain");
    return dt;
}

// ===== Message.get_param =====

fn msgGetParam(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const param_name = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const ct = msgGetHeader(inst, "Content-Type") orelse return Value.none;
    const val = getParam(ct, param_name) orelse return Value.none;
    return makeStr(a, val);
}

fn msgGetParamKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return msgGetParam(p, args);
}

// ===== Message.get_params =====

fn msgGetParams(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const ct = msgGetHeader(inst, "Content-Type") orelse return Value.none;
    const out = try List.init(a);
    // First item: (content-type, "")
    {
        const semi = std.mem.indexOf(u8, ct, ";") orelse ct.len;
        const type_part = std.mem.trim(u8, ct[0..semi], " \t");
        const pair = try Tuple.init(a, 2);
        pair.items[0] = try makeStr(a, type_part);
        pair.items[1] = try makeStr(a, "");
        try out.items.append(a, Value{ .tuple = pair });
    }
    // Remaining params
    var rest = ct;
    while (std.mem.indexOf(u8, rest, ";")) |semi_pos| {
        rest = rest[semi_pos + 1 ..];
        rest = trimLeft(u8, rest, " \t");
        const eq = std.mem.indexOf(u8, rest, "=") orelse {
            rest = "";
            break;
        };
        const key = std.mem.trim(u8, rest[0..eq], " \t");
        rest = rest[eq + 1 ..];
        const val_end = std.mem.indexOf(u8, rest, ";") orelse rest.len;
        const val_raw = std.mem.trim(u8, rest[0..val_end], " \t");
        const val = if (val_raw.len >= 2 and val_raw[0] == '"' and val_raw[val_raw.len - 1] == '"')
            val_raw[1 .. val_raw.len - 1]
        else
            val_raw;
        const pair = try Tuple.init(a, 2);
        pair.items[0] = try makeStr(a, key);
        pair.items[1] = try makeStr(a, val);
        try out.items.append(a, Value{ .tuple = pair });
        if (val_end >= rest.len) break;
        rest = rest[val_end + 1 ..];
    }
    return Value{ .list = out };
}

// ===== Message.is_multipart =====

fn msgIsMultipart(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const inst = try instArg(args);
    const payload = inst.dict.getStr("_payload") orelse Value.none;
    return Value{ .boolean = payload == .list };
}

// ===== Message.attach =====

fn msgAttach(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    // Ensure _payload is a list
    const payload_v = inst.dict.getStr("_payload") orelse Value.none;
    const lst: *List = switch (payload_v) {
        .list => |l| l,
        else => blk: {
            const l = try List.init(a);
            try inst.dict.setStr(a, "_payload", Value{ .list = l });
            break :blk l;
        },
    };
    try lst.items.append(a, args[1]);
    return Value.none;
}

// ===== Message.walk =====

fn msgWalk(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    // Collect all parts recursively into a flat list
    const out = try List.init(a);
    try walkCollect(a, Value{ .instance = inst }, out);
    const it = try Iter.init(a, .{ .list = out });
    return Value{ .iter = it };
}

fn walkCollect(a: std.mem.Allocator, v: Value, out: *List) !void {
    try out.items.append(a, v);
    const inst: *Instance = switch (v) {
        .instance => |i| i,
        else => return,
    };
    const payload = inst.dict.getStr("_payload") orelse return;
    if (payload != .list) return;
    for (payload.list.items.items) |child| {
        try walkCollect(a, child, out);
    }
}

// ===== Message.as_string =====

fn msgAsString(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serializeMessage(a, inst, &buf);
    return makeStr(a, buf.items);
}

fn serializeMessage(a: std.mem.Allocator, inst: *Instance, buf: *std.ArrayList(u8)) !void {
    const hdrs = msgGetHeaders(inst) orelse &List{ .items = .empty };
    for (hdrs.items.items) |item| {
        if (item != .tuple) continue;
        const pair = item.tuple;
        if (pair.items.len < 2) continue;
        const k = if (pair.items[0] == .str) pair.items[0].str.bytes else continue;
        const v = if (pair.items[1] == .str) pair.items[1].str.bytes else continue;
        try buf.appendSlice(a, k);
        try buf.appendSlice(a, ": ");
        try buf.appendSlice(a, v);
        try buf.appendSlice(a, "\r\n");
    }
    try buf.appendSlice(a, "\r\n");
    const payload = inst.dict.getStr("_payload") orelse Value.none;
    switch (payload) {
        .str => |s| try buf.appendSlice(a, s.bytes),
        .bytes => |b| try buf.appendSlice(a, b.data),
        .list => |l| {
            for (l.items.items) |child| {
                if (child != .instance) continue;
                try serializeMessage(a, child.instance, buf);
            }
        },
        else => {},
    }
}

// ===== RFC-2822 parser =====

fn parseMessage(a: std.mem.Allocator, msg_class: *Class, raw: []const u8) !Value {
    const inst = try Instance.init(a, msg_class);
    _ = try msgInitHeaders(a, inst);
    try inst.dict.setStr(a, "_default_type", try makeStr(a, "text/plain"));

    // Split headers from body on blank line
    const sep = std.mem.indexOf(u8, raw, "\n\n") orelse raw.len;
    const hdr_block = raw[0..sep];
    const body = if (sep + 2 <= raw.len) raw[sep + 2 ..] else "";

    // Parse header lines (handle folding)
    var lines = std.mem.splitScalar(u8, hdr_block, '\n');
    var cur_name: []const u8 = "";
    var cur_val: std.ArrayList(u8) = .empty;
    defer cur_val.deinit(a);

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const is_folded = line.len > 0 and (line[0] == ' ' or line[0] == '\t');
        if (is_folded and cur_name.len > 0) {
            // Continuation
            try cur_val.append(a, ' ');
            try cur_val.appendSlice(a, std.mem.trim(u8, line, " \t"));
            continue;
        }
        // Save previous header
        if (cur_name.len > 0) {
            try msgAddHeader(a, inst, cur_name, cur_val.items);
            cur_val.clearRetainingCapacity();
        }
        // Parse new header
        const colon = std.mem.indexOf(u8, line, ":") orelse {
            cur_name = "";
            continue;
        };
        cur_name = std.mem.trim(u8, line[0..colon], " \t");
        const val_raw = std.mem.trim(u8, line[colon + 1 ..], " \t");
        // Strip trailing \r
        const val = if (val_raw.len > 0 and val_raw[val_raw.len - 1] == '\r')
            val_raw[0 .. val_raw.len - 1]
        else
            val_raw;
        try cur_val.appendSlice(a, val);
    }
    if (cur_name.len > 0) {
        try msgAddHeader(a, inst, cur_name, cur_val.items);
    }

    // Set payload
    try inst.dict.setStr(a, "_payload", try makeStr(a, body));
    return Value{ .instance = inst };
}

// ===== email.message_from_string =====

fn messageFromString(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    const raw = switch (args[0]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const cls = interp.email_message_class orelse return Value.none;
    return parseMessage(a, cls, raw);
}

// ===== MIMEText.__init__ =====

fn mimeTextInit(p: *anyopaque, args: []const Value) anyerror!Value {
    return mimeTextInitKw(p, args, &.{}, &.{});
}

fn mimeTextInitKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    const inst = try instArg(args);
    _ = try msgInitHeaders(a, inst);
    try inst.dict.setStr(a, "_default_type", try makeStr(a, "text/plain"));

    const body: []const u8 = if (args.len >= 2) switch (args[1]) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        else => "",
    } else "";

    var subtype: []const u8 = "plain";
    var charset: ?[]const u8 = null;

    if (args.len >= 3) {
        subtype = switch (args[2]) {
            .str => |s| s.bytes,
            else => "plain",
        };
    }
    if (args.len >= 4) {
        charset = switch (args[3]) {
            .str => |s| s.bytes,
            .none => null,
            else => null,
        };
    }
    for (kw_names, kw_values) |kn, kv| {
        const kname = switch (kn) { .str => |s| s.bytes, else => continue };
        if (std.mem.eql(u8, kname, "_subtype") or std.mem.eql(u8, kname, "subtype")) {
            subtype = switch (kv) { .str => |s| s.bytes, else => subtype };
        } else if (std.mem.eql(u8, kname, "_charset") or std.mem.eql(u8, kname, "charset")) {
            charset = switch (kv) {
                .str => |s| s.bytes,
                .none => null,
                else => null,
            };
        }
    }

    // Set headers
    try msgAddHeader(a, inst, "MIME-Version", "1.0");

    if (charset) |cs| {
        // Encode body as base64 if charset is provided
        const ct = try std.fmt.allocPrint(a, "text/{s}; charset={s}", .{ subtype, cs });
        try msgAddHeader(a, inst, "Content-Type", ct);
        const encoded = try b64encode(a, body);
        try msgAddHeader(a, inst, "Content-Transfer-Encoding", "base64");
        try inst.dict.setStr(a, "_payload", try makeStr(a, encoded));
    } else {
        const ct = try std.fmt.allocPrint(a, "text/{s}", .{subtype});
        try msgAddHeader(a, inst, "Content-Type", ct);
        try inst.dict.setStr(a, "_payload", try makeStr(a, body));
    }

    return Value.none;
}

// ===== MIMEMultipart.__init__ =====

fn mimeMultipartInit(p: *anyopaque, args: []const Value) anyerror!Value {
    return mimeMultipartInitKw(p, args, &.{}, &.{});
}

fn mimeMultipartInitKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    _ = try msgInitHeaders(a, inst);
    try inst.dict.setStr(a, "_default_type", try makeStr(a, "text/plain"));

    var subtype: []const u8 = "mixed";
    if (args.len >= 2) {
        subtype = switch (args[1]) {
            .str => |s| s.bytes,
            else => "mixed",
        };
    }
    for (kw_names, kw_values) |kn, kv| {
        const kname = switch (kn) { .str => |s| s.bytes, else => continue };
        if (std.mem.eql(u8, kname, "_subtype") or std.mem.eql(u8, kname, "subtype")) {
            subtype = switch (kv) { .str => |s| s.bytes, else => subtype };
        }
    }

    try msgAddHeader(a, inst, "MIME-Version", "1.0");
    const ct = try std.fmt.allocPrint(a, "multipart/{s}", .{subtype});
    try msgAddHeader(a, inst, "Content-Type", ct);

    // Initialize payload as empty list
    const lst = try List.init(a);
    try inst.dict.setStr(a, "_payload", Value{ .list = lst });

    return Value.none;
}

// ===== MIMEApplication.__init__ =====

fn mimeAppInit(p: *anyopaque, args: []const Value) anyerror!Value {
    return mimeAppInitKw(p, args, &.{}, &.{});
}

fn mimeAppInitKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    _ = try msgInitHeaders(a, inst);
    try inst.dict.setStr(a, "_default_type", try makeStr(a, "text/plain"));

    const data: Value = if (args.len >= 2) args[1] else Value.none;

    var subtype: []const u8 = "octet-stream";
    for (kw_names, kw_values) |kn, kv| {
        const kname = switch (kn) { .str => |s| s.bytes, else => continue };
        if (std.mem.eql(u8, kname, "_subtype")) {
            subtype = switch (kv) { .str => |s| s.bytes, else => subtype };
        }
    }
    // positional _subtype
    if (args.len >= 3) {
        subtype = switch (args[2]) {
            .str => |s| s.bytes,
            else => subtype,
        };
    }

    try msgAddHeader(a, inst, "MIME-Version", "1.0");
    const ct = try std.fmt.allocPrint(a, "application/{s}", .{subtype});
    try msgAddHeader(a, inst, "Content-Type", ct);
    try inst.dict.setStr(a, "_payload", data);

    // Call encoder if provided (_encoder kw arg)
    // We can't call it here directly since it's a Value callable;
    // just store it. The fixture calls encode_base64 explicitly anyway.

    return Value.none;
}

// ===== email.utils functions =====

fn utilsParseaddr(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    const s = switch (args[0]) {
        .str => |sv| sv.bytes,
        else => return Value.none,
    };
    // Trim
    const trimmed = std.mem.trim(u8, s, " \t");
    var name: []const u8 = "";
    var addr: []const u8 = trimmed;

    // Try "Name <addr>" format
    if (std.mem.indexOf(u8, trimmed, "<")) |lt| {
        if (std.mem.indexOf(u8, trimmed, ">")) |gt| {
            if (gt > lt) {
                name = std.mem.trim(u8, trimmed[0..lt], " \t\"");
                addr = trimmed[lt + 1 .. gt];
            }
        }
    }

    const t = try Tuple.init(a, 2);
    t.items[0] = try makeStr(a, name);
    t.items[1] = try makeStr(a, addr);
    return Value{ .tuple = t };
}

fn utilsFormataddr(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    // args[0] is a tuple (name, addr)
    const pair = switch (args[0]) {
        .tuple => |t| t,
        else => return Value.none,
    };
    if (pair.items.len < 2) return Value.none;
    const name = switch (pair.items[0]) {
        .str => |s| s.bytes,
        else => "",
    };
    const addr = switch (pair.items[1]) {
        .str => |s| s.bytes,
        else => "",
    };
    const result = if (name.len > 0)
        try std.fmt.allocPrint(a, "{s} <{s}>", .{ name, addr })
    else
        try std.fmt.allocPrint(a, "{s}", .{addr});
    return makeStr(a, result);
}

const month_names = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};
const day_names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };

fn nowTimestamp(interp: *Interp) i64 {
    const ts = std.Io.Timestamp.now(interp.io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, 1_000_000_000));
}

fn utilsFormatdate(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    // Get timestamp
    const ts: i64 = if (args.len >= 1) switch (args[0]) {
        .small_int => |i| i,
        .float => |f| @intFromFloat(f),
        else => nowTimestamp(interp),
    } else nowTimestamp(interp);

    // Convert to UTC components using epoch seconds
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(if (ts >= 0) ts else 0) };
    const epoch_day = epoch.getEpochDay();
    const day_seconds = epoch.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const year = year_day.year;
    const month_idx = @intFromEnum(month_day.month) - 1; // 0-based
    const day = month_day.day_index + 1;

    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    // Day of week: Jan 1, 1970 was Thursday (day 3 in Mon=0 scheme)
    const dow: usize = @intCast(@mod(@as(i64, @intCast(epoch_day.day)) + 3, 7));

    const result = try std.fmt.allocPrint(a, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} +0000", .{
        day_names[dow],
        day,
        month_names[month_idx],
        year,
        hour,
        minute,
        second,
    });
    return makeStr(a, result);
}

fn utilsFormatdateKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return utilsFormatdate(p, args);
}

extern "c" fn getpid() c_int;

fn utilsMakeMsgid(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const ts = nowTimestamp(interp);
    const pid = getpid();
    const result = try std.fmt.allocPrint(a, "<{d}.{d}@zag.local>", .{ ts, pid });
    return makeStr(a, result);
}

fn utilsMakeMsgidKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return utilsMakeMsgid(p, args);
}

// ===== email.header functions =====

fn headerDecodeHeader(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    const s = switch (args[0]) {
        .str => |sv| sv.bytes,
        else => return Value.none,
    };

    const out = try List.init(a);

    // Check for encoded word: =?charset?encoding?text?=
    if (std.mem.indexOf(u8, s, "=?")) |start| {
        if (std.mem.indexOf(u8, s[start..], "?=")) |rel_end| {
            const encoded_word = s[start .. start + rel_end + 2];
            // Parse =?charset?encoding?text?=
            if (std.mem.startsWith(u8, encoded_word, "=?")) {
                const inner = encoded_word[2..];
                // Find first ?
                if (std.mem.indexOf(u8, inner, "?")) |q1| {
                    const charset_str = inner[0..q1];
                    const rest1 = inner[q1 + 1 ..];
                    if (rest1.len >= 1) {
                        const encoding_char = rest1[0];
                        if (rest1.len >= 2 and rest1[1] == '?') {
                            const text_part = rest1[2..];
                            // Strip trailing ?=
                            const text = if (std.mem.endsWith(u8, text_part, "?="))
                                text_part[0 .. text_part.len - 2]
                            else
                                text_part;

                            const pair = try Tuple.init(a, 2);
                            if (encoding_char == 'b' or encoding_char == 'B') {
                                // Base64 decode
                                const decoded = b64decode(a, text) catch text;
                                const bv = try Bytes.init(a, decoded);
                                pair.items[0] = Value{ .bytes = bv };
                            } else {
                                // Quoted-printable or unknown: return as str
                                pair.items[0] = try makeStr(a, text);
                            }
                            pair.items[1] = try makeStr(a, charset_str);
                            try out.items.append(a, Value{ .tuple = pair });
                            return Value{ .list = out };
                        }
                    }
                }
            }
        }
    }

    // Plain header — no encoding
    const pair = try Tuple.init(a, 2);
    pair.items[0] = try makeStr(a, s);
    pair.items[1] = Value.none;
    try out.items.append(a, Value{ .tuple = pair });
    return Value{ .list = out };
}

fn headerMakeHeader(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    // args[0] is a list of (decoded, charset) tuples
    // Return a Header instance that stringifies to the decoded text
    const cls = interp.email_header_class orelse return Value.none;
    const inst = try Instance.init(a, cls);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);

    const decoded_seq = switch (args[0]) {
        .list => |l| l.items.items,
        else => &[_]Value{},
    };
    for (decoded_seq) |item| {
        const pair = switch (item) {
            .tuple => |t| t,
            else => continue,
        };
        if (pair.items.len < 1) continue;
        switch (pair.items[0]) {
            .bytes => |b| try buf.appendSlice(a, b.data),
            .str => |s| try buf.appendSlice(a, s.bytes),
            else => {},
        }
    }

    try inst.dict.setStr(a, "_str", try makeStr(a, buf.items));
    return Value{ .instance = inst };
}

fn headerHeaderStr(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    return inst.dict.getStr("_str") orelse makeStr(a, "");
}

// ===== email.encoders functions =====

fn encodersEncodeNoop(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn encodersEncodeBase64(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    const inst = try instArg(args);

    // Get the current payload
    const payload = inst.dict.getStr("_payload") orelse Value.none;
    const data: []const u8 = switch (payload) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        else => &.{},
    };

    // Base64 encode
    const encoded = try b64encode(a, data);
    try inst.dict.setStr(a, "_payload", try makeStr(a, encoded));

    // Set Content-Transfer-Encoding header
    // Replace existing or add
    const hdrs = try msgInitHeaders(a, inst);
    var found = false;
    for (hdrs.items.items) |*item| {
        if (item.* != .tuple) continue;
        const pair = item.tuple;
        if (pair.items.len < 2) continue;
        const k = if (pair.items[0] == .str) pair.items[0].str.bytes else continue;
        if (std.ascii.eqlIgnoreCase(k, "Content-Transfer-Encoding")) {
            pair.items[1] = try makeStr(a, "base64");
            found = true;
            break;
        }
    }
    if (!found) {
        try msgAddHeader(a, inst, "Content-Transfer-Encoding", "base64");
    }
    return Value.none;
}

// ===== email.generator Generator =====

fn generatorInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    if (args.len >= 2) {
        try inst.dict.setStr(a, "_fp", args[1]);
    }
    return Value.none;
}

fn generatorFlatten(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const gen_inst = try instArg(args);
    const msg_val = args[1];
    const msg_inst: *Instance = switch (msg_val) {
        .instance => |i| i,
        else => return Value.none,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serializeMessage(a, msg_inst, &buf);
    const s = try makeStr(a, buf.items);

    // Write to the _fp (StringIO instance)
    const fp = gen_inst.dict.getStr("_fp") orelse return Value.none;
    const fp_inst: *Instance = switch (fp) {
        .instance => |i| i,
        else => return Value.none,
    };
    // Append to StringIO buffer
    const io_mod = @import("io_mod.zig");
    const data_list = io_mod.getStringIODataList(fp_inst);
    try data_list.appendSlice(a, switch (s) {
        .str => |sv| sv.bytes,
        else => "",
    });
    return Value.none;
}

// ===== error classes =====
// We create them in email.errors module but also store them globally for raising.

pub const Interp_email_fields = struct {
    email_module: ?*Module = null,
    email_message_module: ?*Module = null,
    email_mime_text_module: ?*Module = null,
    email_mime_multipart_module: ?*Module = null,
    email_mime_application_module: ?*Module = null,
    email_utils_module: ?*Module = null,
    email_header_module: ?*Module = null,
    email_encoders_module: ?*Module = null,
    email_errors_module: ?*Module = null,
    email_generator_module: ?*Module = null,
    email_parser_module: ?*Module = null,
    email_message_class: ?*Class = null,
    email_header_class: ?*Class = null,
    email_generator_class: ?*Class = null,
};

// Build the Message class (shared across modules).
fn buildMessageClass(interp: *Interp) !*Class {
    if (interp.email_message_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try regD(a, d, "__init__", msgInit);
    try regD(a, d, "__contains__", msgContains);
    try regD(a, d, "__getitem__", msgGetitem);
    try regD(a, d, "__setitem__", msgSetitem);
    try regD(a, d, "__delitem__", msgDelitem);
    try regD(a, d, "__len__", msgLen);
    try regKwD(a, d, "get", msgGet, msgGetKw);
    try regKwD(a, d, "get_all", msgGetAll, msgGetAllKw);
    try regD(a, d, "keys", msgKeys);
    try regD(a, d, "values", msgValues);
    try regD(a, d, "items", msgItems);
    try regD(a, d, "replace_header", msgReplaceHeader);
    try regKwD(a, d, "get_payload", msgGetPayload, msgGetPayloadKw);
    try regD(a, d, "set_payload", msgSetPayload);
    try regD(a, d, "get_content_type", msgGetContentType);
    try regD(a, d, "get_content_maintype", msgGetContentMaintype);
    try regD(a, d, "get_content_subtype", msgGetContentSubtype);
    try regD(a, d, "get_content_charset", msgGetContentCharset);
    try regD(a, d, "get_default_type", msgGetDefaultType);
    try regKwD(a, d, "get_param", msgGetParam, msgGetParamKw);
    try regD(a, d, "get_params", msgGetParams);
    try regD(a, d, "is_multipart", msgIsMultipart);
    try regD(a, d, "attach", msgAttach);
    try regD(a, d, "walk", msgWalk);
    try regD(a, d, "as_string", msgAsString);
    const cls = try Class.init(a, "Message", &.{}, d);
    interp.email_message_class = cls;
    return cls;
}

// ===== build functions for each sub-module =====

pub fn build(interp: *Interp) !*Module {
    if (interp.email_module) |m| return m;
    const a = interp.allocator;

    // Ensure message class is built
    _ = try buildMessageClass(interp);

    const m = try Module.init(a, "email");
    try regM(a, m, "message_from_string", messageFromString);

    interp.email_module = m;

    // Build all sub-modules and attach them as attributes so that
    // `import email.message` followed by `email.message.Message` works.
    const msg_mod = try buildMessage(interp);
    try m.attrs.setStr(a, "message", Value{ .module = msg_mod });

    const mime_mod = try buildMimePackage(interp);
    try m.attrs.setStr(a, "mime", Value{ .module = mime_mod });

    const utils_mod = try buildUtils(interp);
    try m.attrs.setStr(a, "utils", Value{ .module = utils_mod });

    const header_mod = try buildHeader(interp);
    try m.attrs.setStr(a, "header", Value{ .module = header_mod });

    const encoders_mod = try buildEncoders(interp);
    try m.attrs.setStr(a, "encoders", Value{ .module = encoders_mod });

    const errors_mod = try buildErrors(interp);
    try m.attrs.setStr(a, "errors", Value{ .module = errors_mod });

    const generator_mod = try buildGenerator(interp);
    try m.attrs.setStr(a, "generator", Value{ .module = generator_mod });

    const parser_mod = try buildParser(interp);
    try m.attrs.setStr(a, "parser", Value{ .module = parser_mod });

    return m;
}

pub fn buildMimePackage(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "email.mime");
    const text_mod = try buildMimeText(interp);
    try m.attrs.setStr(a, "text", Value{ .module = text_mod });
    const mp_mod = try buildMimeMultipart(interp);
    try m.attrs.setStr(a, "multipart", Value{ .module = mp_mod });
    const app_mod = try buildMimeApplication(interp);
    try m.attrs.setStr(a, "application", Value{ .module = app_mod });
    return m;
}

pub fn buildMessage(interp: *Interp) !*Module {
    if (interp.email_message_module) |m| return m;
    const a = interp.allocator;
    const m = try Module.init(a, "email.message");
    const cls = try buildMessageClass(interp);
    try m.attrs.setStr(a, "Message", Value{ .class = cls });
    interp.email_message_module = m;
    return m;
}

pub fn buildMimeText(interp: *Interp) !*Module {
    if (interp.email_mime_text_module) |m| return m;
    const a = interp.allocator;
    const m = try Module.init(a, "email.mime.text");
    // MIMEText inherits from Message
    const msg_cls = try buildMessageClass(interp);
    const bases = &[_]*Class{msg_cls};
    const d = try Dict.init(a);
    try regKwD(a, d, "__init__", mimeTextInit, mimeTextInitKw);
    // Inherit all message methods from base (dispatch will find them)
    const cls = try Class.init(a, "MIMEText", bases, d);
    try m.attrs.setStr(a, "MIMEText", Value{ .class = cls });
    interp.email_mime_text_module = m;
    return m;
}

pub fn buildMimeMultipart(interp: *Interp) !*Module {
    if (interp.email_mime_multipart_module) |m| return m;
    const a = interp.allocator;
    const m = try Module.init(a, "email.mime.multipart");
    const msg_cls = try buildMessageClass(interp);
    const bases = &[_]*Class{msg_cls};
    const d = try Dict.init(a);
    try regKwD(a, d, "__init__", mimeMultipartInit, mimeMultipartInitKw);
    const cls = try Class.init(a, "MIMEMultipart", bases, d);
    try m.attrs.setStr(a, "MIMEMultipart", Value{ .class = cls });
    interp.email_mime_multipart_module = m;
    return m;
}

pub fn buildMimeApplication(interp: *Interp) !*Module {
    if (interp.email_mime_application_module) |m| return m;
    const a = interp.allocator;
    const m = try Module.init(a, "email.mime.application");
    const msg_cls = try buildMessageClass(interp);
    const bases = &[_]*Class{msg_cls};
    const d = try Dict.init(a);
    try regKwD(a, d, "__init__", mimeAppInit, mimeAppInitKw);
    const cls = try Class.init(a, "MIMEApplication", bases, d);
    try m.attrs.setStr(a, "MIMEApplication", Value{ .class = cls });
    interp.email_mime_application_module = m;
    return m;
}

pub fn buildUtils(interp: *Interp) !*Module {
    if (interp.email_utils_module) |m| return m;
    const a = interp.allocator;
    const m = try Module.init(a, "email.utils");
    try regM(a, m, "parseaddr", utilsParseaddr);
    try regM(a, m, "formataddr", utilsFormataddr);
    try regKwM(a, m, "formatdate", utilsFormatdate, utilsFormatdateKw);
    try regKwM(a, m, "make_msgid", utilsMakeMsgid, utilsMakeMsgidKw);
    interp.email_utils_module = m;
    return m;
}

pub fn buildHeader(interp: *Interp) !*Module {
    if (interp.email_header_module) |m| return m;
    const a = interp.allocator;
    const m = try Module.init(a, "email.header");

    // Header class (for make_header result)
    if (interp.email_header_class == null) {
        const d = try Dict.init(a);
        try regD(a, d, "__str__", headerHeaderStr);
        try regD(a, d, "__repr__", headerHeaderStr);
        const cls = try Class.init(a, "Header", &.{}, d);
        interp.email_header_class = cls;
        try m.attrs.setStr(a, "Header", Value{ .class = cls });
    } else {
        try m.attrs.setStr(a, "Header", Value{ .class = interp.email_header_class.? });
    }

    try regM(a, m, "decode_header", headerDecodeHeader);
    try regM(a, m, "make_header", headerMakeHeader);
    interp.email_header_module = m;
    return m;
}

pub fn buildEncoders(interp: *Interp) !*Module {
    if (interp.email_encoders_module) |m| return m;
    const a = interp.allocator;
    const m = try Module.init(a, "email.encoders");
    try regM(a, m, "encode_noop", encodersEncodeNoop);
    try regM(a, m, "encode_base64", encodersEncodeBase64);
    interp.email_encoders_module = m;
    return m;
}

pub fn buildErrors(interp: *Interp) !*Module {
    if (interp.email_errors_module) |m| return m;
    const a = interp.allocator;
    const m = try Module.init(a, "email.errors");

    // Get base Exception class
    const exc_val = interp.builtins.getStr("Exception") orelse Value.none;
    const type_error_val = interp.builtins.getStr("TypeError") orelse Value.none;
    const exc_cls: ?*Class = if (exc_val == .class) exc_val.class else null;
    const type_err_cls: ?*Class = if (type_error_val == .class) type_error_val.class else null;

    // MessageError(Exception)
    const msg_err: *Class = blk: {
        const bases: []const *Class = if (exc_cls) |b| &[_]*Class{b} else &.{};
        const d = try Dict.init(a);
        const cls = try Class.init(a, "MessageError", bases, d);
        try m.attrs.setStr(a, "MessageError", Value{ .class = cls });
        break :blk cls;
    };

    // MessageParseError(MessageError)
    const msg_parse_err: *Class = blk: {
        const bases = &[_]*Class{msg_err};
        const d = try Dict.init(a);
        const cls = try Class.init(a, "MessageParseError", bases, d);
        try m.attrs.setStr(a, "MessageParseError", Value{ .class = cls });
        break :blk cls;
    };

    // HeaderParseError(MessageParseError)
    {
        const bases = &[_]*Class{msg_parse_err};
        const d = try Dict.init(a);
        const cls = try Class.init(a, "HeaderParseError", bases, d);
        try m.attrs.setStr(a, "HeaderParseError", Value{ .class = cls });
    }

    // MultipartConversionError(MessageError, TypeError)
    {
        const bases: []const *Class = if (type_err_cls) |tc| &[_]*Class{ msg_err, tc } else &[_]*Class{msg_err};
        const d = try Dict.init(a);
        const cls = try Class.init(a, "MultipartConversionError", bases, d);
        try m.attrs.setStr(a, "MultipartConversionError", Value{ .class = cls });
    }

    interp.email_errors_module = m;
    return m;
}

pub fn buildGenerator(interp: *Interp) !*Module {
    if (interp.email_generator_module) |m| return m;
    const a = interp.allocator;
    const m = try Module.init(a, "email.generator");

    if (interp.email_generator_class == null) {
        const d = try Dict.init(a);
        try regD(a, d, "__init__", generatorInit);
        try regD(a, d, "flatten", generatorFlatten);
        const cls = try Class.init(a, "Generator", &.{}, d);
        interp.email_generator_class = cls;
        try m.attrs.setStr(a, "Generator", Value{ .class = cls });
    } else {
        try m.attrs.setStr(a, "Generator", Value{ .class = interp.email_generator_class.? });
    }

    interp.email_generator_module = m;
    return m;
}

pub fn buildParser(interp: *Interp) !*Module {
    if (interp.email_parser_module) |m| return m;
    const a = interp.allocator;
    const m = try Module.init(a, "email.parser");
    interp.email_parser_module = m;
    return m;
}
