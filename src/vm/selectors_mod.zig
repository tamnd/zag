//! `selectors` module — I/O multiplexing for fixture 203.

const std = @import("std");
const c = std.c;
const builtin = @import("builtin");
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

fn gi(p: *anyopaque) *Interp {
    return @ptrCast(@alignCast(p));
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

fn makeStr(a: std.mem.Allocator, data: []const u8) !Value {
    const s = try Str.init(a, data);
    return Value{ .str = s };
}

// Extract POSIX fd from a socket instance or integer.
fn valueToFd(v: Value) c_int {
    switch (v) {
        .small_int => |i| return @intCast(i),
        .instance => |inst| {
            const fv = inst.dict.getStr("_fd") orelse return -1;
            return switch (fv) { .small_int => |i| @intCast(i), else => -1 };
        },
        else => return -1,
    }
}

// Build a SelectorKey instance.
fn makeKey(a: std.mem.Allocator, cls: *Class, fileobj: Value, fd: c_int, events: i64, data: Value) !Value {
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "fileobj", fileobj);
    try inst.dict.setStr(a, "fd", Value{ .small_int = fd });
    try inst.dict.setStr(a, "events", Value{ .small_int = events });
    try inst.dict.setStr(a, "data", data);
    return Value{ .instance = inst };
}

// fd → string key used in the internal _keys dict.
fn fdKey(buf: *[32]u8, fd: c_int) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{fd}) catch "0";
}

// Helpers to access selector instance internals.
fn getKeysDict(inst: *Instance) ?*Dict {
    const v = inst.dict.getStr("_keys") orelse return null;
    return if (v == .dict) v.dict else null;
}

fn isClosed(inst: *Instance) bool {
    const v = inst.dict.getStr("_closed") orelse return false;
    return v == .boolean and v.boolean;
}

// ===== DefaultSelector __init__ =====

fn selInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    try inst.dict.setStr(a, "_keys", Value{ .dict = try Dict.init(a) });
    try inst.dict.setStr(a, "_closed", Value{ .boolean = false });
    return Value.none;
}

// ===== register(fileobj, events, data=None) =====

fn selRegister(p: *anyopaque, args: []const Value) anyerror!Value {
    return selRegisterKw(p, args, &.{}, &.{});
}

fn selRegisterKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 3) return Value.none;
    const inst = switch (args[0]) { .instance => |i| i, else => return Value.none };
    const fileobj = args[1];
    const events: i64 = switch (args[2]) { .small_int => |i| i, else => 0 };
    var data: Value = Value.none;
    for (kw_names, kw_values) |kn, kv| {
        const kname = switch (kn) { .str => |s| s.bytes, else => continue };
        if (std.mem.eql(u8, kname, "data")) data = kv;
    }
    // positional data arg
    if (kw_names.len == 0 and args.len >= 4) data = args[3];

    const fd = valueToFd(fileobj);
    if (fd < 0) return Value.none;

    const key_cls = interp.selectors_selector_key_class orelse return Value.none;
    const key = try makeKey(a, key_cls, fileobj, fd, events, data);

    const keys_dict = getKeysDict(inst) orelse return Value.none;
    var buf: [32]u8 = undefined;
    try keys_dict.setStr(a, fdKey(&buf, fd), key);
    return key;
}

// ===== unregister(fileobj) =====

fn selUnregister(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    if (args.len < 2) return Value.none;
    const inst = switch (args[0]) { .instance => |i| i, else => return Value.none };
    const fd = valueToFd(args[1]);
    const keys_dict = getKeysDict(inst) orelse return Value.none;
    var buf: [32]u8 = undefined;
    const key_str = fdKey(&buf, fd);
    const key = keys_dict.getStr(key_str) orelse {
        try interp.raisePy("KeyError", "fd not registered");
        return error.PyException;
    };
    _ = keys_dict.delete(key_str);
    return key;
}

// ===== modify(fileobj, events, data=<keep>) =====

fn selModify(p: *anyopaque, args: []const Value) anyerror!Value {
    return selModifyKw(p, args, &.{}, &.{});
}

fn selModifyKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 3) return Value.none;
    const inst = switch (args[0]) { .instance => |i| i, else => return Value.none };
    const fileobj = args[1];
    const new_events: i64 = switch (args[2]) { .small_int => |i| i, else => 0 };

    const fd = valueToFd(fileobj);
    const keys_dict = getKeysDict(inst) orelse return Value.none;
    var buf: [32]u8 = undefined;
    const key_str = fdKey(&buf, fd);

    // Get existing data unless overridden by kwarg
    var new_data: Value = Value.none;
    var has_new_data = false;
    for (kw_names, kw_values) |kn, kv| {
        const kname = switch (kn) { .str => |s| s.bytes, else => continue };
        if (std.mem.eql(u8, kname, "data")) {
            new_data = kv;
            has_new_data = true;
        }
    }
    if (!has_new_data) {
        if (keys_dict.getStr(key_str)) |old_key| {
            if (old_key == .instance) {
                new_data = old_key.instance.dict.getStr("data") orelse Value.none;
            }
        }
    }

    const key_cls = interp.selectors_selector_key_class orelse return Value.none;
    const new_key = try makeKey(a, key_cls, fileobj, fd, new_events, new_data);
    try keys_dict.setStr(a, key_str, new_key);
    return new_key;
}

// ===== get_key(fileobj) =====

fn selGetKey(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    if (args.len < 2) return Value.none;
    const inst = switch (args[0]) { .instance => |i| i, else => return Value.none };
    const fd = valueToFd(args[1]);
    const keys_dict = getKeysDict(inst) orelse return Value.none;
    var buf: [32]u8 = undefined;
    return keys_dict.getStr(fdKey(&buf, fd)) orelse {
        try interp.raisePy("KeyError", "fd not registered");
        return error.PyException;
    };
}

// ===== get_map() =====

fn selGetMap(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return Value{ .dict = try Dict.init(a) };
    const inst = switch (args[0]) { .instance => |i| i, else => return Value{ .dict = try Dict.init(a) } };
    const keys_dict = getKeysDict(inst) orelse return Value{ .dict = try Dict.init(a) };
    // Return a copy with integer fd keys
    const out = try Dict.init(a);
    for (keys_dict.pairs.items) |pair| {
        const key_str = switch (pair.key) { .str => |s| s.bytes, else => continue };
        const fd_int = std.fmt.parseInt(c_int, key_str, 10) catch continue;
        try out.setKey(a, Value{ .small_int = fd_int }, pair.value);
    }
    return Value{ .dict = out };
}

// ===== select(timeout=None) =====

fn selSelect(p: *anyopaque, args: []const Value) anyerror!Value {
    return selSelectKw(p, args, &.{}, &.{});
}

fn selSelectKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (comptime builtin.os.tag == .windows) return Value{ .list = try List.init(a) };
    if (args.len < 1) return Value{ .list = try List.init(a) };
    const inst = switch (args[0]) { .instance => |i| i, else => return Value{ .list = try List.init(a) } };

    if (isClosed(inst)) {
        try interp.raisePy("ValueError", "selector is closed");
        return error.PyException;
    }

    var timeout_v: Value = Value.none;
    for (kw_names, kw_values) |kn, kv| {
        const kname = switch (kn) { .str => |s| s.bytes, else => continue };
        if (std.mem.eql(u8, kname, "timeout")) timeout_v = kv;
    }
    if (kw_names.len == 0 and args.len >= 2) timeout_v = args[1];

    const timeout_ms: c_int = switch (timeout_v) {
        .none => -1,
        .small_int => |i| @intCast(i * 1000),
        .float => |f| @intFromFloat(f * 1000.0),
        else => -1,
    };

    const keys_dict = getKeysDict(inst) orelse return Value{ .list = try List.init(a) };

    var pf: std.ArrayList(c.pollfd) = .empty;
    defer pf.deinit(a);
    var key_vals: std.ArrayList(Value) = .empty;
    defer key_vals.deinit(a);

    for (keys_dict.pairs.items) |pair| {
        const key_str = switch (pair.key) { .str => |s| s.bytes, else => continue };
        const fd_int = std.fmt.parseInt(c_int, key_str, 10) catch continue;
        const key_inst = switch (pair.value) { .instance => |i| i, else => continue };
        const ev_v = key_inst.dict.getStr("events") orelse continue;
        const ev: i64 = switch (ev_v) { .small_int => |i| i, else => 0 };
        // EVENT_READ=1→POLLIN=1, EVENT_WRITE=2→POLLOUT=4
        var poll_ev: i16 = 0;
        if (ev & 1 != 0) poll_ev |= 1;  // POLLIN
        if (ev & 2 != 0) poll_ev |= 4;  // POLLOUT
        try pf.append(a, .{ .fd = fd_int, .events = poll_ev, .revents = 0 });
        try key_vals.append(a, pair.value);
    }

    if (pf.items.len > 0) {
        _ = c.poll(pf.items.ptr, @intCast(pf.items.len), timeout_ms);
    }

    const out = try List.init(a);
    for (pf.items, 0..) |pfd, i| {
        if (pfd.revents == 0) continue;
        var ready_ev: i64 = 0;
        if (pfd.revents & 1 != 0) ready_ev |= 1;  // POLLIN → EVENT_READ
        if (pfd.revents & 4 != 0) ready_ev |= 2;  // POLLOUT → EVENT_WRITE
        if (pfd.revents & 8 != 0) ready_ev |= 1;  // POLLERR → EVENT_READ (report as read)
        if (pfd.revents & 16 != 0) ready_ev |= 1; // POLLHUP → EVENT_READ
        if (ready_ev == 0) ready_ev = 1;
        const t = try Tuple.init(a, 2);
        t.items[0] = key_vals.items[i];
        t.items[1] = Value{ .small_int = ready_ev };
        try out.items.append(a, Value{ .tuple = t });
    }
    return Value{ .list = out };
}

// ===== close / __enter__ / __exit__ =====

fn selClose(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    try args[0].instance.dict.setStr(a, "_closed", Value{ .boolean = true });
    return Value.none;
}

fn selEnter(_: *anyopaque, args: []const Value) anyerror!Value {
    return if (args.len >= 1) args[0] else Value.none;
}

fn selExit(p: *anyopaque, args: []const Value) anyerror!Value {
    return selClose(p, args);
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "selectors");

    // Constants
    try m.attrs.setStr(a, "EVENT_READ", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "EVENT_WRITE", Value{ .small_int = 2 });

    // SelectorKey class
    {
        const d = try Dict.init(a);
        interp.selectors_selector_key_class = try Class.init(a, "SelectorKey", &.{}, d);
        try m.attrs.setStr(a, "SelectorKey", Value{ .class = interp.selectors_selector_key_class.? });
    }

    // DefaultSelector class
    {
        const d = try Dict.init(a);
        interp.selectors_default_selector_class = try Class.init(a, "DefaultSelector", &.{}, d);
        const cls = interp.selectors_default_selector_class.?;
        try regD(a, cls.dict, "__init__", selInit);
        try regKwD(a, cls.dict, "register", selRegister, selRegisterKw);
        try regD(a, cls.dict, "unregister", selUnregister);
        try regKwD(a, cls.dict, "modify", selModify, selModifyKw);
        try regD(a, cls.dict, "get_key", selGetKey);
        try regD(a, cls.dict, "get_map", selGetMap);
        try regKwD(a, cls.dict, "select", selSelect, selSelectKw);
        try regD(a, cls.dict, "close", selClose);
        try regD(a, cls.dict, "__enter__", selEnter);
        try regD(a, cls.dict, "__exit__", selExit);
        try m.attrs.setStr(a, "DefaultSelector", Value{ .class = cls });
    }

    interp.selectors_module = m;
    return m;
}
