//! `mailbox` module — in-memory mbox/Maildir for fixture 208.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Bytes = @import("../object/bytes.zig").Bytes;
const Interp = @import("interp.zig").Interp;

fn gi(p: *anyopaque) *Interp {
    return @ptrCast(@alignCast(p));
}

fn makeStr(a: std.mem.Allocator, data: []const u8) !Value {
    return Value{ .str = try Str.init(a, data) };
}

fn regD(a: std.mem.Allocator, d: *Dict, name: []const u8, f: BuiltinFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f };
    try d.setStr(a, name, Value{ .builtin_fn = bf });
}

fn instArg(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

// ===== Header parsing helper =====

// Parse headers from raw message text, look up header name case-insensitively.
fn getHeader(a: std.mem.Allocator, raw: []const u8, name: []const u8) !?[]const u8 {
    _ = a;
    // Split on \n\n to get only the header section
    const sep = std.mem.indexOf(u8, raw, "\n\n") orelse raw.len;
    const hdr_block = raw[0..sep];
    var lines = std.mem.splitScalar(u8, hdr_block, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOf(u8, line, ":") orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(key, name)) {
            const val_raw = std.mem.trim(u8, line[colon + 1 ..], " \t");
            // Strip trailing \r
            const val = if (val_raw.len > 0 and val_raw[val_raw.len - 1] == '\r')
                val_raw[0 .. val_raw.len - 1]
            else
                val_raw;
            return val;
        }
    }
    return null;
}

// ===== mboxMessage class =====

fn mboxMsgInit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value.none;
}

fn mboxMsgGetitem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const header_name = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const raw_v = inst.dict.getStr("_raw") orelse return Value.none;
    const raw = switch (raw_v) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const val = try getHeader(a, raw, header_name) orelse return Value.none;
    return makeStr(a, val);
}

fn buildMboxMessageClass(interp: *Interp) !*Class {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try regD(a, d, "__init__", mboxMsgInit);
    try regD(a, d, "__getitem__", mboxMsgGetitem);
    return Class.init(a, "mboxMessage", &.{}, d);
}

// ===== mbox class =====

// Get the messages dict from the mbox instance.
fn mboxMessages(inst: *Instance) ?*Dict {
    const v = inst.dict.getStr("_messages") orelse return null;
    return if (v == .dict) v.dict else null;
}

fn mboxNextKey(inst: *Instance) i64 {
    const v = inst.dict.getStr("_next_key") orelse return 0;
    return switch (v) {
        .small_int => |i| i,
        else => 0,
    };
}

fn mboxSetNextKey(a: std.mem.Allocator, inst: *Instance, key: i64) !void {
    try inst.dict.setStr(a, "_next_key", Value{ .small_int = key });
}

fn mboxInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const d = try Dict.init(a);
    try inst.dict.setStr(a, "_messages", Value{ .dict = d });
    try inst.dict.setStr(a, "_next_key", Value{ .small_int = 0 });
    return Value.none;
}

fn mboxAdd(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value{ .small_int = -1 };
    const inst = try instArg(args);
    const text = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value{ .small_int = -1 },
    };
    const d = mboxMessages(inst) orelse return Value{ .small_int = -1 };
    const key = mboxNextKey(inst);
    // Store key as string in dict (dict keys are strings internally)
    const key_str = try std.fmt.allocPrint(a, "{d}", .{key});
    try d.setStr(a, key_str, try makeStr(a, text));
    try mboxSetNextKey(a, inst, key + 1);
    return Value{ .small_int = key };
}

fn mboxLen(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    const inst = try instArg(args);
    const d = mboxMessages(inst) orelse return Value{ .small_int = 0 };
    var count: i64 = 0;
    for (d.pairs.items) |pair| {
        if (pair.key != .none) count += 1;
    }
    return Value{ .small_int = count };
}

fn mboxGetitem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const key: i64 = switch (args[1]) {
        .small_int => |i| i,
        else => return Value.none,
    };
    const d = mboxMessages(inst) orelse return Value.none;
    const key_str = try std.fmt.allocPrint(a, "{d}", .{key});
    const raw_v = d.getStr(key_str) orelse {
        try interp.raisePy("KeyError", key_str);
        return error.PyException;
    };
    const raw = switch (raw_v) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    // Build mboxMessage instance
    const msg_cls = interp.mailbox_mboxmsg_class orelse return Value.none;
    const msg_inst = try Instance.init(a, msg_cls);
    try msg_inst.dict.setStr(a, "_raw", try makeStr(a, raw));
    return Value{ .instance = msg_inst };
}

fn mboxKeys(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const d = mboxMessages(inst) orelse return Value{ .list = try List.init(a) };
    const out = try List.init(a);
    for (d.pairs.items) |pair| {
        if (pair.key == .none) continue;
        const key_s = switch (pair.key) {
            .str => |s| s.bytes,
            else => continue,
        };
        const key_int = std.fmt.parseInt(i64, key_s, 10) catch continue;
        try out.items.append(a, Value{ .small_int = key_int });
    }
    // Sort keys numerically
    std.sort.insertion(Value, out.items.items, {}, struct {
        fn lessThan(_: void, lhs: Value, rhs: Value) bool {
            const l = switch (lhs) { .small_int => |i| i, else => 0 };
            const r = switch (rhs) { .small_int => |i| i, else => 0 };
            return l < r;
        }
    }.lessThan);
    return Value{ .list = out };
}

fn mboxRemove(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const key: i64 = switch (args[1]) {
        .small_int => |i| i,
        else => return Value.none,
    };
    const d = mboxMessages(inst) orelse return Value.none;
    const key_str = try std.fmt.allocPrint(a, "{d}", .{key});
    if (d.getStr(key_str) == null) {
        try interp.raisePy("KeyError", key_str);
        return error.PyException;
    }
    _ = d.delete(key_str);
    return Value.none;
}

fn mboxDiscard(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const key: i64 = switch (args[1]) {
        .small_int => |i| i,
        else => return Value.none,
    };
    const d = mboxMessages(inst) orelse return Value.none;
    const key_str = try std.fmt.allocPrint(a, "{d}", .{key});
    _ = d.delete(key_str);
    return Value.none;
}

fn mboxFlush(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn mboxClose(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn mboxContains(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value{ .boolean = false };
    const inst = try instArg(args);
    const key: i64 = switch (args[1]) {
        .small_int => |i| i,
        else => return Value{ .boolean = false },
    };
    const d = mboxMessages(inst) orelse return Value{ .boolean = false };
    const key_str = try std.fmt.allocPrint(a, "{d}", .{key});
    return Value{ .boolean = d.getStr(key_str) != null };
}

fn mboxClear(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const new_d = try Dict.init(a);
    try inst.dict.setStr(a, "_messages", Value{ .dict = new_d });
    try inst.dict.setStr(a, "_next_key", Value{ .small_int = 0 });
    return Value.none;
}

fn mboxGetString(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const key: i64 = switch (args[1]) {
        .small_int => |i| i,
        else => return Value.none,
    };
    const d = mboxMessages(inst) orelse return Value.none;
    const key_str = try std.fmt.allocPrint(a, "{d}", .{key});
    const raw_v = d.getStr(key_str) orelse {
        try interp.raisePy("KeyError", key_str);
        return error.PyException;
    };
    return raw_v;
}

fn mboxGetBytes(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const key: i64 = switch (args[1]) {
        .small_int => |i| i,
        else => return Value.none,
    };
    const d = mboxMessages(inst) orelse return Value.none;
    const key_str = try std.fmt.allocPrint(a, "{d}", .{key});
    const raw_v = d.getStr(key_str) orelse {
        try interp.raisePy("KeyError", key_str);
        return error.PyException;
    };
    const raw = switch (raw_v) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const bv = try Bytes.init(a, raw);
    return Value{ .bytes = bv };
}

// ===== Maildir class =====

fn maildirInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const d = try Dict.init(a);
    try inst.dict.setStr(a, "_messages", Value{ .dict = d });
    try inst.dict.setStr(a, "_next_key", Value{ .small_int = 0 });
    return Value.none;
}

fn maildirAdd(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const text = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const d = mboxMessages(inst) orelse return Value.none;
    const key_int = mboxNextKey(inst);
    const key_str = try std.fmt.allocPrint(a, "{d}", .{key_int});
    try d.setStr(a, key_str, try makeStr(a, text));
    try mboxSetNextKey(a, inst, key_int + 1);
    return makeStr(a, key_str);
}

fn maildirLen(p: *anyopaque, args: []const Value) anyerror!Value {
    return mboxLen(p, args);
}

fn maildirGetitem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const key_s = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const d = mboxMessages(inst) orelse return Value.none;
    const raw_v = d.getStr(key_s) orelse {
        try interp.raisePy("KeyError", key_s);
        return error.PyException;
    };
    const raw = switch (raw_v) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const msg_cls = interp.mailbox_mboxmsg_class orelse return Value.none;
    const msg_inst = try Instance.init(a, msg_cls);
    try msg_inst.dict.setStr(a, "_raw", try makeStr(a, raw));
    return Value{ .instance = msg_inst };
}

fn maildirKeys(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const d = mboxMessages(inst) orelse return Value{ .list = try List.init(a) };
    const out = try List.init(a);
    for (d.pairs.items) |pair| {
        if (pair.key == .none) continue;
        try out.items.append(a, pair.key);
    }
    return Value{ .list = out };
}

fn maildirRemove(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const key_s = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const d = mboxMessages(inst) orelse return Value.none;
    if (d.getStr(key_s) == null) {
        try interp.raisePy("KeyError", key_s);
        return error.PyException;
    }
    _ = a;
    _ = d.delete(key_s);
    return Value.none;
}

fn maildirDiscard(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2) return Value.none;
    const inst = try instArg(args);
    const key_s = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const d = mboxMessages(inst) orelse return Value.none;
    _ = d.delete(key_s);
    return Value.none;
}

fn maildirClose(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn maildirContains(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2) return Value{ .boolean = false };
    const inst = try instArg(args);
    const key_s = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value{ .boolean = false },
    };
    const d = mboxMessages(inst) orelse return Value{ .boolean = false };
    return Value{ .boolean = d.getStr(key_s) != null };
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "mailbox");

    // Error classes
    const exc_val = interp.builtins.getStr("Exception") orelse Value.none;
    const exc_cls: ?*Class = if (exc_val == .class) exc_val.class else null;
    const err_bases: []const *Class = if (exc_cls) |b| &[_]*Class{b} else &.{};

    const err_cls: *Class = blk: {
        const d = try Dict.init(a);
        const cls = try Class.init(a, "Error", err_bases, d);
        try m.attrs.setStr(a, "Error", Value{ .class = cls });
        break :blk cls;
    };

    {
        const bases = &[_]*Class{err_cls};
        const d = try Dict.init(a);
        const cls = try Class.init(a, "NoSuchMailboxError", bases, d);
        try m.attrs.setStr(a, "NoSuchMailboxError", Value{ .class = cls });
    }

    {
        const bases = &[_]*Class{err_cls};
        const d = try Dict.init(a);
        const cls = try Class.init(a, "FormatError", bases, d);
        try m.attrs.setStr(a, "FormatError", Value{ .class = cls });
    }

    // mboxMessage class
    const mboxmsg_cls = try buildMboxMessageClass(interp);
    interp.mailbox_mboxmsg_class = mboxmsg_cls;
    try m.attrs.setStr(a, "mboxMessage", Value{ .class = mboxmsg_cls });

    // mbox class
    {
        const d = try Dict.init(a);
        try regD(a, d, "__init__", mboxInit);
        try regD(a, d, "add", mboxAdd);
        try regD(a, d, "__len__", mboxLen);
        try regD(a, d, "__getitem__", mboxGetitem);
        try regD(a, d, "keys", mboxKeys);
        try regD(a, d, "remove", mboxRemove);
        try regD(a, d, "discard", mboxDiscard);
        try regD(a, d, "flush", mboxFlush);
        try regD(a, d, "close", mboxClose);
        try regD(a, d, "__contains__", mboxContains);
        try regD(a, d, "clear", mboxClear);
        try regD(a, d, "get_string", mboxGetString);
        try regD(a, d, "get_bytes", mboxGetBytes);
        const cls = try Class.init(a, "mbox", &.{}, d);
        try m.attrs.setStr(a, "mbox", Value{ .class = cls });
    }

    // Maildir class
    {
        const d = try Dict.init(a);
        try regD(a, d, "__init__", maildirInit);
        try regD(a, d, "add", maildirAdd);
        try regD(a, d, "__len__", maildirLen);
        try regD(a, d, "__getitem__", maildirGetitem);
        try regD(a, d, "keys", maildirKeys);
        try regD(a, d, "remove", maildirRemove);
        try regD(a, d, "discard", maildirDiscard);
        try regD(a, d, "close", maildirClose);
        try regD(a, d, "__contains__", maildirContains);
        const cls = try Class.init(a, "Maildir", &.{}, d);
        try m.attrs.setStr(a, "Maildir", Value{ .class = cls });
    }

    interp.mailbox_module = m;
    return m;
}
