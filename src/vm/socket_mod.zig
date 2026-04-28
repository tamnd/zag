//! `socket` module — POSIX socket wrapper for fixture 200.

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
const Bytes = @import("../object/bytes.zig").Bytes;
const Interp = @import("interp.zig").Interp;
const threading_mod = @import("threading_mod.zig");

// Socket fd type — use c_int to be portable across platforms (c.fd_t is *anyopaque on Windows)
const Fd = c_int;

// libc network helpers — conditional to avoid linker errors on Windows
const posix_net = if (builtin.os.tag != .windows) struct {
    pub extern "c" fn inet_pton(af: c_int, src: [*:0]const u8, dst: *anyopaque) c_int;
    pub extern "c" fn inet_ntop(af: c_int, src: *const anyopaque, dst: [*]u8, size: u32) ?[*:0]const u8;
    pub extern "c" fn inet_aton(cp: [*:0]const u8, addr: *u32) c_int;
    pub extern "c" fn inet_ntoa(in: u32) [*:0]u8;
    pub extern "c" fn gethostbyname(name: [*:0]const u8) ?*anyopaque;
    pub extern "c" fn getservbyname(name: [*:0]const u8, proto: ?[*:0]const u8) ?*anyopaque;
    pub extern "c" fn getprotobyname(name: [*:0]const u8) ?*anyopaque;
    pub extern "c" fn ntohs(n: u16) u16;
    pub extern "c" fn ntohl(n: u32) u32;
    pub extern "c" fn htons(n: u16) u16;
    pub extern "c" fn htonl(n: u32) u32;
} else struct {
    pub fn inet_pton(_: c_int, _: [*:0]const u8, _: *anyopaque) c_int { return -1; }
    pub fn inet_ntop(_: c_int, _: *const anyopaque, _: [*]u8, _: u32) ?[*:0]const u8 { return null; }
    pub fn inet_aton(_: [*:0]const u8, _: *u32) c_int { return 0; }
    pub fn inet_ntoa(_: u32) [*:0]u8 { return @constCast("0.0.0.0"); }
    pub fn gethostbyname(_: [*:0]const u8) ?*anyopaque { return null; }
    pub fn getservbyname(_: [*:0]const u8, _: ?[*:0]const u8) ?*anyopaque { return null; }
    pub fn getprotobyname(_: [*:0]const u8) ?*anyopaque { return null; }
    pub fn ntohs(n: u16) u16 { return @byteSwap(n); }
    pub fn ntohl(n: u32) u32 { return @byteSwap(n); }
    pub fn htons(n: u16) u16 { return @byteSwap(n); }
    pub fn htonl(n: u32) u32 { return @byteSwap(n); }
};

// macOS: MSG_DONTWAIT = 0x80, O_NONBLOCK = 0x20000
const MSG_DONTWAIT: c_int = 0x80;
const O_NONBLOCK: c_int = 0x20000;

// sockaddr_in6 layout on macOS (BSD)
const SockaddrIn6 = extern struct {
    len: u8 = 28,
    family: u8,
    port: u16,
    flowinfo: u32,
    addr: [16]u8,
    scope_id: u32,
};

fn gi(p: *anyopaque) *Interp {
    return @ptrCast(@alignCast(p));
}

fn instArg(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
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

fn makeBytes(a: std.mem.Allocator, data: []const u8) !Value {
    const b = try Bytes.init(a, data);
    return Value{ .bytes = b };
}

fn makeStr(a: std.mem.Allocator, data: []const u8) !Value {
    const s = try Str.init(a, data);
    return Value{ .str = s };
}

fn getFd(inst: *Instance) Fd {
    const v = inst.dict.getStr("_fd") orelse return -1;
    return switch (v) {
        .small_int => |i| @intCast(i),
        else => -1,
    };
}

fn getFamily(inst: *Instance) i32 {
    const v = inst.dict.getStr("family") orelse return 2;
    return switch (v) {
        .small_int => |i| @intCast(i),
        else => 2,
    };
}

// Build sockaddr from (host, port) tuple
fn buildSockaddr(a: std.mem.Allocator, addr_v: Value, family: i32) !struct { ptr: *anyopaque, len: c.socklen_t } {
    var host: []const u8 = "0.0.0.0";
    var port: u16 = 0;
    switch (addr_v) {
        .tuple => |t| {
            if (t.items.len >= 1 and t.items[0] == .str) host = t.items[0].str.bytes;
            if (t.items.len >= 2) port = switch (t.items[1]) {
                .small_int => |i| @intCast(i),
                else => 0,
            };
        },
        else => {},
    }
    if (family == 30) { // AF_INET6
        const s6 = try a.create(SockaddrIn6);
        s6.* = .{
            .family = 30,
            .port = posix_net.htons(port),
            .flowinfo = 0,
            .addr = [_]u8{0} ** 16,
            .scope_id = 0,
        };
        const host_z = try a.dupeZ(u8, host);
        _ = posix_net.inet_pton(30, host_z, &s6.addr);
        return .{ .ptr = s6, .len = @sizeOf(SockaddrIn6) };
    } else {
        const s4 = try a.create(c.sockaddr.in);
        s4.* = .{
            .family = c.AF.INET,
            .port = posix_net.htons(port),
            .addr = 0,
            .zero = [_]u8{0} ** 8,
        };
        if (host.len > 0) {
            const host_z = try a.dupeZ(u8, host);
            _ = posix_net.inet_pton(2, host_z, &s4.addr);
        }
        return .{ .ptr = s4, .len = @sizeOf(c.sockaddr.in) };
    }
}

fn parseSockaddr(a: std.mem.Allocator, sa: *c.sockaddr) !Value {
    const family: u8 = @intCast(sa.family & 0xff);
    if (family == 30) { // AF_INET6
        const s6: *SockaddrIn6 = @ptrCast(@alignCast(sa));
        var buf: [64]u8 = undefined;
        const r = posix_net.inet_ntop(30, &s6.addr, &buf, 64);
        const host_str = if (r) |p| std.mem.sliceTo(p, 0) else "::";
        const t = try Tuple.init(a, 4);
        t.items[0] = try makeStr(a, host_str);
        t.items[1] = Value{ .small_int = posix_net.ntohs(s6.port) };
        t.items[2] = Value{ .small_int = 0 };
        t.items[3] = Value{ .small_int = 0 };
        return Value{ .tuple = t };
    } else {
        const s4: *c.sockaddr.in = @ptrCast(@alignCast(sa));
        var buf: [16]u8 = undefined;
        const r = posix_net.inet_ntop(2, &s4.addr, &buf, 16);
        const host_str = if (r) |p| std.mem.sliceTo(p, 0) else "0.0.0.0";
        const t = try Tuple.init(a, 2);
        t.items[0] = try makeStr(a, host_str);
        t.items[1] = Value{ .small_int = posix_net.ntohs(s4.port) };
        return Value{ .tuple = t };
    }
}

// Try non-blocking recv; if EAGAIN, run pending threads, then blocking recv.
fn recvWithPending(interp: *Interp, fd: Fd, buf: []u8, flags: c_int) !isize {
    if (comptime builtin.os.tag == .windows) return 0;
    const n1 = c.recv(fd, buf.ptr, buf.len, flags | MSG_DONTWAIT);
    if (n1 >= 0) return @intCast(n1);
    if (@intFromEnum(c.errno(n1)) != 35) return @intCast(n1); // not EAGAIN
    threading_mod.runPendingThreads(interp) catch {};
    const n2 = c.recv(fd, buf.ptr, buf.len, flags);
    return @intCast(n2);
}

fn acceptWithPending(interp: *Interp, fd: Fd, addr: *c.sockaddr, addrlen: *c.socklen_t) Fd {
    if (comptime builtin.os.tag == .windows) return -1;
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F.SETFL, flags | O_NONBLOCK);
    const conn1 = c.accept(fd, addr, addrlen);
    _ = c.fcntl(fd, c.F.SETFL, flags);
    if (conn1 >= 0) return conn1;
    if (@intFromEnum(c.errno(conn1)) != 35) return conn1;
    threading_mod.runPendingThreads(interp) catch {};
    return c.accept(fd, addr, addrlen);
}

// ===== Socket methods =====

fn socketBind(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const fd = getFd(inst);
    const addr_v = if (args.len >= 2) args[1] else return Value.none;
    const family = getFamily(inst);
    const sa = try buildSockaddr(a, addr_v, family);
    _ = c.bind(fd, @ptrCast(@alignCast(sa.ptr)), sa.len);
    return Value.none;
}

fn socketListen(_: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const inst = try instArg(args);
    const fd = getFd(inst);
    const backlog: c_uint = if (args.len >= 2) switch (args[1]) {
        .small_int => |i| @intCast(i),
        else => 1,
    } else 1;
    _ = c.listen(fd, backlog);
    return Value.none;
}

fn socketAccept(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const fd = getFd(inst);
    var peer_addr: c.sockaddr = undefined;
    var peer_len: c.socklen_t = @sizeOf(c.sockaddr);
    const conn_fd = acceptWithPending(interp, fd, &peer_addr, &peer_len);
    if (conn_fd < 0) {
        try interp.raisePy("OSError", "accept failed");
        return error.PyException;
    }
    const conn_inst = try Instance.init(a, interp.socket_class.?);
    try conn_inst.dict.setStr(a, "_fd", Value{ .small_int = conn_fd });
    const family = getFamily(inst);
    try conn_inst.dict.setStr(a, "family", Value{ .small_int = family });
    try conn_inst.dict.setStr(a, "type", inst.dict.getStr("type") orelse Value{ .small_int = 1 });
    try conn_inst.dict.setStr(a, "_timeout", Value.none);
    const addr_v = try parseSockaddr(a, &peer_addr);
    const t = try Tuple.init(a, 2);
    t.items[0] = Value{ .instance = conn_inst };
    t.items[1] = addr_v;
    return Value{ .tuple = t };
}

fn socketConnect(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const fd = getFd(inst);
    const addr_v = if (args.len >= 2) args[1] else return Value.none;
    const family = getFamily(inst);
    const sa = try buildSockaddr(a, addr_v, family);
    const r = c.connect(fd, @ptrCast(@alignCast(sa.ptr)), sa.len);
    if (r != 0) {
        const e = @intFromEnum(c.errno(r));
        if (e != 0) {
            try interp.raisePy("OSError", "connect failed");
            return error.PyException;
        }
    }
    return Value.none;
}

fn socketConnectEx(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value{ .small_int = 1 };
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const fd = getFd(inst);
    const addr_v = if (args.len >= 2) args[1] else return Value{ .small_int = 1 };
    const family = getFamily(inst);
    const sa = try buildSockaddr(a, addr_v, family);
    const r = c.connect(fd, @ptrCast(@alignCast(sa.ptr)), sa.len);
    if (r == 0) return Value{ .small_int = 0 };
    return Value{ .small_int = @intFromEnum(c.errno(r)) };
}

fn socketSendAll(_: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const inst = try instArg(args);
    const fd = getFd(inst);
    const data_v = if (args.len >= 2) args[1] else return Value.none;
    const data: []const u8 = switch (data_v) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        else => return Value.none,
    };
    var sent: usize = 0;
    while (sent < data.len) {
        const n = c.send(fd, data.ptr + sent, data.len - sent, 0);
        if (n < 0) break;
        sent += @intCast(n);
    }
    return Value.none;
}

fn socketSend(_: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value{ .small_int = 0 };
    const inst = try instArg(args);
    const fd = getFd(inst);
    const data_v = if (args.len >= 2) args[1] else return Value{ .small_int = 0 };
    const data: []const u8 = switch (data_v) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        else => return Value{ .small_int = 0 },
    };
    const n = c.send(fd, data.ptr, data.len, 0);
    return Value{ .small_int = if (n < 0) 0 else @intCast(n) };
}

fn socketRecv(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return makeBytes(std.heap.page_allocator, &.{});
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const fd = getFd(inst);
    const bufsize: usize = if (args.len >= 2) switch (args[1]) {
        .small_int => |i| @intCast(i),
        else => 4096,
    } else 4096;
    const buf = try a.alloc(u8, bufsize);
    const n = try recvWithPending(interp, fd, buf, 0);
    if (n < 0) return makeBytes(a, &.{});
    return makeBytes(a, buf[0..@intCast(n)]);
}

fn socketSendTo(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value{ .small_int = 0 };
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const fd = getFd(inst);
    const data_v = if (args.len >= 2) args[1] else return Value{ .small_int = 0 };
    const addr_v = if (args.len >= 3) args[2] else return Value{ .small_int = 0 };
    const data: []const u8 = switch (data_v) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        else => return Value{ .small_int = 0 },
    };
    const family = getFamily(inst);
    const sa = try buildSockaddr(a, addr_v, family);
    const n = c.sendto(fd, data.ptr, data.len, 0, @ptrCast(@alignCast(sa.ptr)), sa.len);
    return Value{ .small_int = if (n < 0) 0 else @intCast(n) };
}

fn socketRecvFrom(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const fd = getFd(inst);
    const bufsize: usize = if (args.len >= 2) switch (args[1]) {
        .small_int => |i| @intCast(i),
        else => 4096,
    } else 4096;
    const buf = try a.alloc(u8, bufsize);
    var peer: c.sockaddr = undefined;
    var peer_len: c.socklen_t = @sizeOf(c.sockaddr);
    const n = c.recvfrom(fd, buf.ptr, bufsize, 0, &peer, &peer_len);
    const data_v = if (n < 0) try makeBytes(a, &.{}) else try makeBytes(a, buf[0..@intCast(n)]);
    const addr_v = try parseSockaddr(a, &peer);
    const t = try Tuple.init(a, 2);
    t.items[0] = data_v;
    t.items[1] = addr_v;
    return Value{ .tuple = t };
}

fn socketClose(_: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const inst = try instArg(args);
    const fd = getFd(inst);
    if (fd >= 0) _ = c.close(fd);
    inst.dict.setStr(std.heap.page_allocator, "_fd", Value{ .small_int = -1 }) catch {};
    return Value.none;
}

fn socketSetSockOpt(_: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const inst = try instArg(args);
    const fd = getFd(inst);
    const level: i32 = if (args.len >= 2) switch (args[1]) {
        .small_int => |i| @intCast(i),
        else => 0,
    } else 0;
    const optname: u32 = if (args.len >= 3) switch (args[2]) {
        .small_int => |i| @intCast(i),
        else => 0,
    } else 0;
    const optval: c_int = if (args.len >= 4) switch (args[3]) {
        .small_int => |i| @intCast(i),
        .boolean => |b| if (b) 1 else 0,
        else => 0,
    } else 0;
    _ = c.setsockopt(fd, level, optname, &optval, @sizeOf(c_int));
    return Value.none;
}

fn socketGetSockOpt(_: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value{ .small_int = 0 };
    const inst = try instArg(args);
    const fd = getFd(inst);
    const level: i32 = if (args.len >= 2) switch (args[1]) {
        .small_int => |i| @intCast(i),
        else => 0,
    } else 0;
    const optname: u32 = if (args.len >= 3) switch (args[2]) {
        .small_int => |i| @intCast(i),
        else => 0,
    } else 0;
    var optval: c_int = 0;
    var optlen: c.socklen_t = @sizeOf(c_int);
    _ = c.getsockopt(fd, level, optname, &optval, &optlen);
    return Value{ .small_int = optval };
}

fn socketGetSockName(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const fd = getFd(inst);
    var addr: c.sockaddr = undefined;
    var addrlen: c.socklen_t = @sizeOf(c.sockaddr);
    _ = c.getsockname(fd, &addr, &addrlen);
    return parseSockaddr(a, &addr);
}

fn socketGetPeerName(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const fd = getFd(inst);
    var addr: c.sockaddr = undefined;
    var addrlen: c.socklen_t = @sizeOf(c.sockaddr);
    _ = c.getpeername(fd, &addr, &addrlen);
    return parseSockaddr(a, &addr);
}

fn socketSetBlocking(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const fd = getFd(inst);
    const blocking: bool = if (args.len >= 2) switch (args[1]) {
        .boolean => |b| b,
        .small_int => |i| i != 0,
        else => true,
    } else true;
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (blocking) {
        _ = c.fcntl(fd, c.F.SETFL, flags & ~O_NONBLOCK);
        try inst.dict.setStr(a, "_timeout", Value.none);
    } else {
        _ = c.fcntl(fd, c.F.SETFL, flags | O_NONBLOCK);
        try inst.dict.setStr(a, "_timeout", Value{ .float = 0.0 });
    }
    return Value.none;
}

fn socketGetBlocking(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    const timeout_v = inst.dict.getStr("_timeout") orelse Value.none;
    const is_blocking = timeout_v == .none or
        (timeout_v == .float and timeout_v.float != 0.0);
    return Value{ .boolean = is_blocking };
}

fn socketSetTimeout(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const fd = getFd(inst);
    const timeout_v = if (args.len >= 2) args[1] else Value.none;
    try inst.dict.setStr(a, "_timeout", timeout_v);
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    switch (timeout_v) {
        .none => _ = c.fcntl(fd, c.F.SETFL, flags & ~O_NONBLOCK),
        .float => |f| {
            if (f == 0.0) {
                _ = c.fcntl(fd, c.F.SETFL, flags | O_NONBLOCK);
            } else {
                _ = c.fcntl(fd, c.F.SETFL, flags & ~O_NONBLOCK);
            }
        },
        .small_int => |i| {
            if (i == 0) {
                _ = c.fcntl(fd, c.F.SETFL, flags | O_NONBLOCK);
            } else {
                _ = c.fcntl(fd, c.F.SETFL, flags & ~O_NONBLOCK);
            }
        },
        else => {},
    }
    return Value.none;
}

fn socketGetTimeout(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return inst.dict.getStr("_timeout") orelse Value.none;
}

fn socketShutdown(_: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const inst = try instArg(args);
    const fd = getFd(inst);
    const how: c_int = if (args.len >= 2) switch (args[1]) {
        .small_int => |i| @intCast(i),
        else => 2,
    } else 2;
    _ = c.shutdown(fd, how);
    return Value.none;
}

fn socketFileno(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return inst.dict.getStr("_fd") orelse Value{ .small_int = -1 };
}

// ===== Module-level functions =====

fn socketNew(p: *anyopaque, args: []const Value) anyerror!Value {
    return socketNewKw(p, args, &.{}, &.{});
}

fn socketNewKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) {
        try gi(p).raisePy("OSError", "socket not supported on Windows");
        return error.PyException;
    }
    const interp = gi(p);
    const a = interp.allocator;
    const family: c_uint = if (args.len >= 1) switch (args[0]) {
        .small_int => |i| @intCast(i),
        else => 2,
    } else 2;
    const typ: c_uint = if (args.len >= 2) switch (args[1]) {
        .small_int => |i| @intCast(i),
        else => 1,
    } else 1;
    const proto: c_uint = if (args.len >= 3) switch (args[2]) {
        .small_int => |i| @intCast(i),
        else => 0,
    } else 0;
    const fd = c.socket(family, typ, proto);
    if (fd < 0) {
        try interp.raisePy("OSError", "socket() failed");
        return error.PyException;
    }
    const inst = try Instance.init(a, interp.socket_class.?);
    try inst.dict.setStr(a, "_fd", Value{ .small_int = fd });
    try inst.dict.setStr(a, "family", Value{ .small_int = @as(i64, family) });
    try inst.dict.setStr(a, "type", Value{ .small_int = @as(i64, typ) });
    try inst.dict.setStr(a, "_timeout", Value.none);
    return Value{ .instance = inst };
}

fn socketInit(p: *anyopaque, args: []const Value) anyerror!Value {
    return socketInitKw(p, args, &.{}, &.{});
}

fn socketInitKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) {
        try gi(p).raisePy("OSError", "socket not supported on Windows");
        return error.PyException;
    }
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const family: c_uint = if (args.len >= 2) switch (args[1]) {
        .small_int => |i| @intCast(i),
        else => 2,
    } else 2;
    const typ: c_uint = if (args.len >= 3) switch (args[2]) {
        .small_int => |i| @intCast(i),
        else => 1,
    } else 1;
    const proto: c_uint = if (args.len >= 4) switch (args[3]) {
        .small_int => |i| @intCast(i),
        else => 0,
    } else 0;
    const fd = c.socket(family, typ, proto);
    if (fd < 0) {
        try interp.raisePy("OSError", "socket() failed");
        return error.PyException;
    }
    try inst.dict.setStr(a, "_fd", Value{ .small_int = fd });
    try inst.dict.setStr(a, "family", Value{ .small_int = @as(i64, family) });
    try inst.dict.setStr(a, "type", Value{ .small_int = @as(i64, typ) });
    try inst.dict.setStr(a, "_timeout", Value.none);
    return Value.none;
}

fn socketPairFn(p: *anyopaque, _: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) {
        try gi(p).raisePy("OSError", "socketpair not supported on Windows");
        return error.PyException;
    }
    const interp = gi(p);
    const a = interp.allocator;
    var fds: [2]Fd = undefined;
    const r = c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds);
    if (r != 0) {
        try interp.raisePy("OSError", "socketpair() failed");
        return error.PyException;
    }
    const mkSock = struct {
        fn f(alloc: std.mem.Allocator, cls: *Class, fd: Fd) !Value {
            const i = try Instance.init(alloc, cls);
            try i.dict.setStr(alloc, "_fd", Value{ .small_int = fd });
            try i.dict.setStr(alloc, "family", Value{ .small_int = 1 }); // AF_UNIX
            try i.dict.setStr(alloc, "type", Value{ .small_int = 1 }); // SOCK_STREAM
            try i.dict.setStr(alloc, "_timeout", Value.none);
            return Value{ .instance = i };
        }
    }.f;
    const s1 = try mkSock(a, interp.socket_class.?, fds[0]);
    const s2 = try mkSock(a, interp.socket_class.?, fds[1]);
    const t = try Tuple.init(a, 2);
    t.items[0] = s1;
    t.items[1] = s2;
    return Value{ .tuple = t };
}

fn createConnectionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return createConnectionKw(p, args, &.{}, &.{});
}

fn createConnectionKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) {
        try gi(p).raisePy("OSError", "socket not supported on Windows");
        return error.PyException;
    }
    const interp = gi(p);
    const a = interp.allocator;
    const addr_v = if (args.len >= 1) args[0] else return Value.none;
    const fd = c.socket(@intCast(c.AF.INET), @intCast(c.SOCK.STREAM), 0);
    if (fd < 0) {
        try interp.raisePy("OSError", "socket() failed");
        return error.PyException;
    }
    const inst = try Instance.init(a, interp.socket_class.?);
    try inst.dict.setStr(a, "_fd", Value{ .small_int = fd });
    try inst.dict.setStr(a, "family", Value{ .small_int = 2 });
    try inst.dict.setStr(a, "type", Value{ .small_int = 1 });
    try inst.dict.setStr(a, "_timeout", Value.none);
    const sa = try buildSockaddr(a, addr_v, 2);
    const r = c.connect(fd, @ptrCast(@alignCast(sa.ptr)), sa.len);
    if (r != 0) {
        _ = c.close(fd);
        try interp.raisePy("OSError", "connect failed");
        return error.PyException;
    }
    return Value{ .instance = inst };
}

fn gethostnameFn(p: *anyopaque, _: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return makeStr(gi(p).allocator, "localhost");
    const interp = gi(p);
    const a = interp.allocator;
    var buf: [256]u8 = undefined;
    _ = c.gethostname(&buf, buf.len);
    const name = std.mem.sliceTo(&buf, 0);
    return makeStr(a, name);
}

fn getaddrinfoFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return getaddrinfoKw(p, args, &.{}, &.{});
}

fn getaddrinfoKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value{ .list = try List.init(gi(p).allocator) };
    const interp = gi(p);
    const a = interp.allocator;
    const host_v = if (args.len >= 1) args[0] else Value.none;
    const port_v = if (args.len >= 2) args[1] else Value.none;

    const host: []const u8 = switch (host_v) {
        .str => |s| s.bytes,
        else => "0.0.0.0",
    };
    const port: u16 = switch (port_v) {
        .small_int => |i| @intCast(i),
        .str => |s| std.fmt.parseInt(u16, s.bytes, 10) catch 0,
        else => 0,
    };

    const host_z = try a.dupeZ(u8, host);
    var port_buf: [8]u8 = undefined;
    const port_z = try std.fmt.bufPrintZ(&port_buf, "{}", .{port});

    var res: ?*c.addrinfo = null;
    const ret = c.getaddrinfo(host_z, port_z, null, &res);
    if (@intFromEnum(ret) != 0 or res == null) {
        return Value{ .list = try List.init(a) };
    }
    defer c.freeaddrinfo(res.?);

    const result = try List.init(a);
    var ai = res;
    while (ai) |info| {
        const fam: i64 = info.family;
        const typ: i64 = info.socktype;
        const proto: i64 = info.protocol;
        const canon: []const u8 = if (info.canonname) |cn| std.mem.sliceTo(cn, 0) else "";
        const sockaddr_v = if (info.addr) |addr| try parseSockaddr(a, addr) else Value.none;
        const entry = try Tuple.init(a, 5);
        entry.items[0] = Value{ .small_int = fam };
        entry.items[1] = Value{ .small_int = typ };
        entry.items[2] = Value{ .small_int = proto };
        entry.items[3] = try makeStr(a, canon);
        entry.items[4] = sockaddr_v;
        try result.append(a, Value{ .tuple = entry });
        ai = info.next;
    }
    return Value{ .list = result };
}

fn inetAtonFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const s: []const u8 = switch (if (args.len >= 1) args[0] else Value.none) {
        .str => |st| st.bytes,
        else => return makeBytes(a, &.{}),
    };
    const s_z = try a.dupeZ(u8, s);
    var result: u32 = 0;
    _ = posix_net.inet_aton(s_z, &result);
    return makeBytes(a, std.mem.asBytes(&result));
}

fn inetNtoaFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const data: []const u8 = switch (if (args.len >= 1) args[0] else Value.none) {
        .bytes => |b| b.data,
        else => return makeStr(a, "0.0.0.0"),
    };
    if (data.len < 4) return makeStr(a, "0.0.0.0");
    var addr_val: u32 = 0;
    @memcpy(std.mem.asBytes(&addr_val), data[0..4]);
    const p_str = posix_net.inet_ntoa(addr_val);
    return makeStr(a, std.mem.sliceTo(p_str, 0));
}

fn inetPtonFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const af: c_int = if (args.len >= 1) switch (args[0]) {
        .small_int => |i| @intCast(i),
        else => 2,
    } else 2;
    const s: []const u8 = if (args.len >= 2) switch (args[1]) {
        .str => |st| st.bytes,
        else => "",
    } else "";
    const s_z = try a.dupeZ(u8, s);
    if (af == 2) {
        var addr: u32 = 0;
        const r = posix_net.inet_pton(af, s_z, &addr);
        if (r <= 0) {
            try interp.raisePy("OSError", "inet_pton failed");
            return error.PyException;
        }
        return makeBytes(a, std.mem.asBytes(&addr));
    } else {
        var addr: [16]u8 = undefined;
        const r = posix_net.inet_pton(af, s_z, &addr);
        if (r <= 0) {
            try interp.raisePy("OSError", "inet_pton failed");
            return error.PyException;
        }
        return makeBytes(a, &addr);
    }
}

fn inetNtopFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const af: c_int = if (args.len >= 1) switch (args[0]) {
        .small_int => |i| @intCast(i),
        else => 2,
    } else 2;
    const data: []const u8 = if (args.len >= 2) switch (args[1]) {
        .bytes => |b| b.data,
        else => return makeStr(a, ""),
    } else return makeStr(a, "");
    var buf: [64]u8 = undefined;
    const r = posix_net.inet_ntop(af, data.ptr, &buf, 64);
    const str = if (r) |p2| std.mem.sliceTo(p2, 0) else "";
    return makeStr(a, str);
}

fn ntohsFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const n: u16 = if (args.len >= 1) switch (args[0]) {
        .small_int => |i| @intCast(@as(u64, @bitCast(i)) & 0xffff),
        else => 0,
    } else 0;
    return Value{ .small_int = posix_net.ntohs(n) };
}

fn ntohlFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const n: u32 = if (args.len >= 1) switch (args[0]) {
        .small_int => |i| @intCast(@as(u64, @bitCast(i)) & 0xffffffff),
        else => 0,
    } else 0;
    return Value{ .small_int = posix_net.ntohl(n) };
}

fn htonsFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const n: u16 = if (args.len >= 1) switch (args[0]) {
        .small_int => |i| @intCast(@as(u64, @bitCast(i)) & 0xffff),
        else => 0,
    } else 0;
    return Value{ .small_int = posix_net.htons(n) };
}

fn htonlFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const n: u32 = if (args.len >= 1) switch (args[0]) {
        .small_int => |i| @intCast(@as(u64, @bitCast(i)) & 0xffffffff),
        else => 0,
    } else 0;
    return Value{ .small_int = posix_net.htonl(n) };
}

fn gethostbynameFn(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return makeStr(gi(p).allocator, "127.0.0.1");
    const interp = gi(p);
    const a = interp.allocator;
    const name: []const u8 = if (args.len >= 1) switch (args[0]) {
        .str => |s| s.bytes,
        else => "localhost",
    } else "localhost";
    const name_z = try a.dupeZ(u8, name);
    var res: ?*c.addrinfo = null;
    const ret = c.getaddrinfo(name_z, null, null, &res);
    if (@intFromEnum(ret) != 0 or res == null) return makeStr(a, name);
    defer c.freeaddrinfo(res.?);
    if (res) |info| {
        if (info.addr) |addr| {
            const v = try parseSockaddr(a, addr);
            if (v == .tuple and v.tuple.items.len >= 1) return v.tuple.items[0];
        }
    }
    return makeStr(a, name);
}

fn getservbynameFn(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) {
        try gi(p).raisePy("OSError", "service not found");
        return error.PyException;
    }
    const interp = gi(p);
    const a = interp.allocator;
    const name: []const u8 = if (args.len >= 1) switch (args[0]) {
        .str => |s| s.bytes,
        else => "",
    } else "";
    // Well-known services
    const services = [_]struct { name: []const u8, port: i64 }{
        .{ .name = "http", .port = 80 },
        .{ .name = "https", .port = 443 },
        .{ .name = "ftp", .port = 21 },
        .{ .name = "ssh", .port = 22 },
        .{ .name = "smtp", .port = 25 },
        .{ .name = "dns", .port = 53 },
        .{ .name = "pop3", .port = 110 },
        .{ .name = "imap", .port = 143 },
    };
    for (services) |svc| {
        if (std.mem.eql(u8, svc.name, name)) return Value{ .small_int = svc.port };
    }
    const name_z = try a.dupeZ(u8, name);
    const sv = posix_net.getservbyname(name_z, null);
    if (sv) |sv_ptr| {
        const servent: *align(1) const extern struct {
            name: *const u8,
            aliases: *const ?*const u8,
            port: c_int,
            proto: *const u8,
        } = @ptrCast(@alignCast(sv_ptr));
        return Value{ .small_int = posix_net.ntohs(@intCast(servent.port)) };
    }
    try interp.raisePy("OSError", "service not found");
    return error.PyException;
}

fn getprotobynameFn(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) {
        try gi(p).raisePy("OSError", "protocol not found");
        return error.PyException;
    }
    const interp = gi(p);
    const a = interp.allocator;
    const name: []const u8 = if (args.len >= 1) switch (args[0]) {
        .str => |s| s.bytes,
        else => "",
    } else "";
    if (std.mem.eql(u8, name, "tcp")) return Value{ .small_int = 6 };
    if (std.mem.eql(u8, name, "udp")) return Value{ .small_int = 17 };
    if (std.mem.eql(u8, name, "icmp")) return Value{ .small_int = 1 };
    const name_z = try a.dupeZ(u8, name);
    const pv = posix_net.getprotobyname(name_z);
    if (pv) |pv_ptr| {
        const protoent: *align(1) const extern struct {
            name: *const u8,
            aliases: *const ?*const u8,
            proto: c_int,
        } = @ptrCast(@alignCast(pv_ptr));
        return Value{ .small_int = protoent.proto };
    }
    try interp.raisePy("OSError", "protocol not found");
    return error.PyException;
}

var default_timeout: Value = Value.none;

fn setdefaulttimeoutFn(_: *anyopaque, args: []const Value) anyerror!Value {
    default_timeout = if (args.len >= 1) args[0] else Value.none;
    return Value.none;
}

fn getdefaulttimeoutFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return default_timeout;
}

// ===== Class setup =====

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;

    if (interp.socket_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "__init__", socketInit, socketInitKw);
        try regD(a, d, "bind", socketBind);
        try regD(a, d, "listen", socketListen);
        try regD(a, d, "accept", socketAccept);
        try regD(a, d, "connect", socketConnect);
        try regD(a, d, "connect_ex", socketConnectEx);
        try regD(a, d, "sendall", socketSendAll);
        try regD(a, d, "send", socketSend);
        try regD(a, d, "recv", socketRecv);
        try regD(a, d, "sendto", socketSendTo);
        try regD(a, d, "recvfrom", socketRecvFrom);
        try regD(a, d, "close", socketClose);
        try regD(a, d, "setsockopt", socketSetSockOpt);
        try regD(a, d, "getsockopt", socketGetSockOpt);
        try regD(a, d, "getsockname", socketGetSockName);
        try regD(a, d, "getpeername", socketGetPeerName);
        try regD(a, d, "setblocking", socketSetBlocking);
        try regD(a, d, "getblocking", socketGetBlocking);
        try regD(a, d, "settimeout", socketSetTimeout);
        try regD(a, d, "gettimeout", socketGetTimeout);
        try regD(a, d, "shutdown", socketShutdown);
        try regD(a, d, "fileno", socketFileno);
        interp.socket_class = try Class.init(a, "socket", &.{}, d);
    }

    if (interp.socket_error_class == null) {
        const oserror_v = interp.builtins.getStr("OSError") orelse Value.none;
        const base: ?*Class = if (oserror_v == .class) oserror_v.class else null;
        const bases: []const *Class = if (base) |b| &[_]*Class{b} else &.{};
        const d = try Dict.init(a);
        interp.socket_error_class = try Class.init(a, "error", bases, d);
    }

    if (interp.socket_timeout_class == null) {
        const bases: []const *Class = if (interp.socket_error_class) |b| &[_]*Class{b} else &.{};
        const d = try Dict.init(a);
        interp.socket_timeout_class = try Class.init(a, "timeout", bases, d);
    }

    if (interp.socket_gaierror_class == null) {
        const bases: []const *Class = if (interp.socket_error_class) |b| &[_]*Class{b} else &.{};
        const d = try Dict.init(a);
        interp.socket_gaierror_class = try Class.init(a, "gaierror", bases, d);
    }

    if (interp.socket_herror_class == null) {
        const bases: []const *Class = if (interp.socket_error_class) |b| &[_]*Class{b} else &.{};
        const d = try Dict.init(a);
        interp.socket_herror_class = try Class.init(a, "herror", bases, d);
    }
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    try ensureClasses(interp);

    const m = try Module.init(a, "socket");

    try regKwM(a, m, "socket", socketNew, socketNewKw);
    try regM(a, m, "socketpair", socketPairFn);
    try regKwM(a, m, "create_connection", createConnectionFn, createConnectionKw);
    try regM(a, m, "gethostname", gethostnameFn);
    try regKwM(a, m, "getaddrinfo", getaddrinfoFn, getaddrinfoKw);
    try regM(a, m, "inet_aton", inetAtonFn);
    try regM(a, m, "inet_ntoa", inetNtoaFn);
    try regM(a, m, "inet_pton", inetPtonFn);
    try regM(a, m, "inet_ntop", inetNtopFn);
    try regM(a, m, "ntohs", ntohsFn);
    try regM(a, m, "ntohl", ntohlFn);
    try regM(a, m, "htons", htonsFn);
    try regM(a, m, "htonl", htonlFn);
    try regM(a, m, "gethostbyname", gethostbynameFn);
    try regM(a, m, "getservbyname", getservbynameFn);
    try regM(a, m, "getprotobyname", getprotobynameFn);
    try regM(a, m, "setdefaulttimeout", setdefaulttimeoutFn);
    try regM(a, m, "getdefaulttimeout", getdefaulttimeoutFn);

    try m.attrs.setStr(a, "socket", Value{ .class = interp.socket_class.? });
    try m.attrs.setStr(a, "error", Value{ .class = interp.socket_error_class.? });
    try m.attrs.setStr(a, "timeout", Value{ .class = interp.socket_timeout_class.? });
    try m.attrs.setStr(a, "gaierror", Value{ .class = interp.socket_gaierror_class.? });
    try m.attrs.setStr(a, "herror", Value{ .class = interp.socket_herror_class.? });

    try m.attrs.setStr(a, "AF_INET", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "AF_INET6", Value{ .small_int = 30 });
    try m.attrs.setStr(a, "AF_UNIX", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "SOCK_STREAM", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "SOCK_DGRAM", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "IPPROTO_TCP", Value{ .small_int = 6 });
    try m.attrs.setStr(a, "IPPROTO_UDP", Value{ .small_int = 17 });
    try m.attrs.setStr(a, "SOL_SOCKET", Value{ .small_int = 65535 });
    try m.attrs.setStr(a, "SO_REUSEADDR", Value{ .small_int = 4 });
    try m.attrs.setStr(a, "SHUT_RD", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "SHUT_WR", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "SHUT_RDWR", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "INADDR_ANY", Value{ .small_int = 0 });

    return m;
}
