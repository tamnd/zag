//! `select` module — select()/poll() wrappers for fixture 202.

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

fn regKwM(a: std.mem.Allocator, m: *Module, name: []const u8, f: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = bf });
}

const FdEntry = struct { obj: Value, fd: c_int };

// Extract fd from a Value (socket instance or integer).
fn valueToFd(v: Value) c_int {
    switch (v) {
        .small_int => |i| return @intCast(i),
        .instance => |inst| {
            const fv = inst.dict.getStr("_fd") orelse return -1;
            return switch (fv) {
                .small_int => |i| @intCast(i),
                else => -1,
            };
        },
        else => return -1,
    }
}

fn collectFds(a: std.mem.Allocator, list_v: Value) !std.ArrayList(FdEntry) {
    var result: std.ArrayList(FdEntry) = .empty;
    const items: []const Value = switch (list_v) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => &.{},
    };
    for (items) |item| {
        const fd = valueToFd(item);
        if (fd >= 0) try result.append(a, .{ .obj = item, .fd = fd });
    }
    return result;
}

// Timeout value → poll milliseconds (-1 = block).
fn toMs(v: Value) c_int {
    return switch (v) {
        .none => -1,
        .small_int => |i| @intCast(i * 1000),
        .float => |f| @intFromFloat(f * 1000.0),
        else => -1,
    };
}

// ===== select.select(rlist, wlist, xlist[, timeout]) =====

fn selectFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return selectKw(p, args, &.{}, &.{});
}

fn selectKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;

    if (comptime builtin.os.tag == .windows) {
        const t = try Tuple.init(a, 3);
        t.items[0] = Value{ .list = try List.init(a) };
        t.items[1] = Value{ .list = try List.init(a) };
        t.items[2] = Value{ .list = try List.init(a) };
        return Value{ .tuple = t };
    }

    const rlist_v = if (args.len >= 1) args[0] else Value{ .list = try List.init(a) };
    const wlist_v = if (args.len >= 2) args[1] else Value{ .list = try List.init(a) };
    const xlist_v = if (args.len >= 3) args[2] else Value{ .list = try List.init(a) };
    const timeout_ms = toMs(if (args.len >= 4) args[3] else Value.none);

    var rfds = try collectFds(a, rlist_v);
    defer rfds.deinit(a);
    var wfds = try collectFds(a, wlist_v);
    defer wfds.deinit(a);
    var xfds = try collectFds(a, xlist_v);
    defer xfds.deinit(a);

    var pf: std.ArrayList(c.pollfd) = .empty;
    defer pf.deinit(a);

    for (rfds.items) |entry| {
        try pf.append(a, .{ .fd = entry.fd, .events = 1, .revents = 0 }); // POLLIN
    }
    const r_end = pf.items.len;
    for (wfds.items) |entry| {
        try pf.append(a, .{ .fd = entry.fd, .events = 4, .revents = 0 }); // POLLOUT
    }
    const w_end = pf.items.len;
    for (xfds.items) |entry| {
        try pf.append(a, .{ .fd = entry.fd, .events = 8, .revents = 0 }); // POLLERR
    }

    if (pf.items.len > 0) {
        _ = c.poll(pf.items.ptr, @intCast(pf.items.len), timeout_ms);
    }

    const rout = try List.init(a);
    for (rfds.items, 0..) |entry, i| {
        if (pf.items[i].revents != 0) try rout.items.append(a, entry.obj);
    }

    const wout = try List.init(a);
    for (wfds.items, 0..) |entry, i| {
        if (pf.items[r_end + i].revents != 0) try wout.items.append(a, entry.obj);
    }

    const xout = try List.init(a);
    for (xfds.items, 0..) |entry, i| {
        if (pf.items[w_end + i].revents != 0) try xout.items.append(a, entry.obj);
    }

    const t = try Tuple.init(a, 3);
    t.items[0] = Value{ .list = rout };
    t.items[1] = Value{ .list = wout };
    t.items[2] = Value{ .list = xout };
    return Value{ .tuple = t };
}

// ===== poll class =====

fn pollNew(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const d = try Dict.init(a);
    try inst.dict.setStr(a, "_fds", Value{ .dict = d });
    return Value.none;
}

fn getPollFds(inst: *Instance) ?*Dict {
    const v = inst.dict.getStr("_fds") orelse return null;
    return if (v == .dict) v.dict else null;
}

fn pollRegister(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const inst = switch (args[0]) {
        .instance => |i| i,
        else => return Value.none,
    };
    const fd = valueToFd(args[1]);
    const events: i64 = if (args.len >= 3) switch (args[2]) {
        .small_int => |i| i,
        else => 1,
    } else 1;
    const d = getPollFds(inst) orelse return Value.none;
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "{d}", .{fd});
    try d.setStr(a, key, Value{ .small_int = events });
    return Value.none;
}

fn pollUnregister(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2) return Value.none;
    const inst = switch (args[0]) {
        .instance => |i| i,
        else => return Value.none,
    };
    const fd = valueToFd(args[1]);
    const d = getPollFds(inst) orelse return Value.none;
    var key_buf: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{d}", .{fd}) catch return Value.none;
    _ = d.delete(key);
    return Value.none;
}

fn pollModify(p: *anyopaque, args: []const Value) anyerror!Value {
    return pollRegister(p, args);
}

fn pollPoll(p: *anyopaque, args: []const Value) anyerror!Value {
    return pollPollKw(p, args, &.{}, &.{});
}

fn pollPollKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const empty = Value{ .list = try List.init(a) };
    if (comptime builtin.os.tag == .windows) return empty;
    if (args.len < 1) return empty;
    const inst = switch (args[0]) {
        .instance => |i| i,
        else => return empty,
    };
    const timeout_ms: c_int = if (args.len >= 2) switch (args[1]) {
        .small_int => |i| @intCast(i),
        .float => |f| @intFromFloat(f),
        .none => -1,
        else => -1,
    } else -1;

    const d = getPollFds(inst) orelse return empty;
    var pf: std.ArrayList(c.pollfd) = .empty;
    defer pf.deinit(a);

    for (d.pairs.items) |pair| {
        const key = switch (pair.key) {
            .str => |s| s.bytes,
            else => continue,
        };
        const fd_int = std.fmt.parseInt(c_int, key, 10) catch continue;
        const events: i16 = switch (pair.value) {
            .small_int => |i| @intCast(i & 0x7fff),
            else => 1,
        };
        try pf.append(a, .{ .fd = fd_int, .events = events, .revents = 0 });
    }

    if (pf.items.len > 0) {
        _ = c.poll(pf.items.ptr, @intCast(pf.items.len), timeout_ms);
    }

    const out = try List.init(a);
    for (pf.items) |pfd| {
        if (pfd.revents != 0) {
            const t = try Tuple.init(a, 2);
            t.items[0] = Value{ .small_int = pfd.fd };
            t.items[1] = Value{ .small_int = pfd.revents };
            try out.items.append(a, Value{ .tuple = t });
        }
    }
    return Value{ .list = out };
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "select");

    // error alias = OSError
    const oserror_v = interp.builtins.getStr("OSError") orelse Value.none;
    try m.attrs.setStr(a, "error", oserror_v);

    // Constants
    try m.attrs.setStr(a, "POLLIN", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "POLLPRI", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "POLLOUT", Value{ .small_int = 4 });
    try m.attrs.setStr(a, "POLLERR", Value{ .small_int = 8 });
    try m.attrs.setStr(a, "POLLHUP", Value{ .small_int = 16 });
    try m.attrs.setStr(a, "POLLNVAL", Value{ .small_int = 32 });
    try m.attrs.setStr(a, "POLLRDNORM", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "POLLWRNORM", Value{ .small_int = 4 });

    // select() function
    try regKwM(a, m, "select", selectFn, selectKw);

    // poll class
    {
        const d = try Dict.init(a);
        interp.select_poll_class = try Class.init(a, "poll", &.{}, d);
        const cls = interp.select_poll_class.?;
        try regD(a, cls.dict, "__init__", pollNew);
        try regD(a, cls.dict, "register", pollRegister);
        try regD(a, cls.dict, "unregister", pollUnregister);
        try regD(a, cls.dict, "modify", pollModify);
        try regKwD(a, cls.dict, "poll", pollPoll, pollPollKw);
        try m.attrs.setStr(a, "poll", Value{ .class = cls });
    }

    interp.select_module = m;
    return m;
}
