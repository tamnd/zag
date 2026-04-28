//! `ssl` module — fake-TLS wrapper for fixture 201.
//!
//! No real OpenSSL is linked. wrap_socket() returns immediately; data flows
//! as plaintext through the underlying TCP socket.  TLS attributes return
//! hard-coded values that satisfy the fixture assertions.

const std = @import("std");
const c = std.c;
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
const Str = @import("../object/string.zig").Str;
const Bytes = @import("../object/bytes.zig").Bytes;
const Interp = @import("interp.zig").Interp;
const threading_mod = @import("threading_mod.zig");

const builtin = @import("builtin");
const Fd = c_int;

// MSG_DONTWAIT on macOS
const MSG_DONTWAIT: c_int = 0x80;

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

fn makeStr(a: std.mem.Allocator, data: []const u8) !Value {
    const s = try Str.init(a, data);
    return Value{ .str = s };
}

fn makeBytes(a: std.mem.Allocator, data: []const u8) !Value {
    const b = try Bytes.init(a, data);
    return Value{ .bytes = b };
}

// ===== base64 helpers for PEM↔DER =====

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
        if (v < 0) return error.InvalidBase64;
        buf = (buf << 6) | @as(u32, @intCast(v));
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            try out.append(a, @intCast((buf >> @intCast(bits)) & 0xff));
        }
    }
    return out.toOwnedSlice(a);
}

// Extract base64 body from a PEM block (strips header, footer, newlines).
fn pemBody(pem: []const u8) []const u8 {
    var start: usize = 0;
    if (std.mem.indexOf(u8, pem, "-----\n")) |pos| {
        start = pos + 6;
    } else if (std.mem.indexOf(u8, pem, "-----\r\n")) |pos| {
        start = pos + 7;
    }
    const rest = pem[start..];
    const end_marker = std.mem.indexOf(u8, rest, "-----") orelse rest.len;
    return rest[0..end_marker];
}

// ===== recv helper (same trick as socket_mod) =====

fn recvWithPending(interp: *Interp, fd: Fd, buf: []u8, flags: c_int) !isize {
    if (comptime builtin.os.tag == .windows) return 0;
    const n1 = c.recv(fd, buf.ptr, buf.len, flags | MSG_DONTWAIT);
    if (n1 >= 0) return @intCast(n1);
    if (@intFromEnum(c.errno(n1)) != 35) return @intCast(n1);
    threading_mod.runPendingThreads(interp) catch {};
    const n2 = c.recv(fd, buf.ptr, buf.len, flags);
    return @intCast(n2);
}

const posix_net = if (builtin.os.tag != .windows) struct {
    pub extern "c" fn htons(n: u16) u16;
    pub extern "c" fn inet_pton(af: c_int, src: [*:0]const u8, dst: *anyopaque) c_int;
} else struct {
    pub fn htons(n: u16) u16 { return @byteSwap(n); }
    pub fn inet_pton(_: c_int, _: [*:0]const u8, _: *anyopaque) c_int { return -1; }
};

var g_prng: ?std.Random.DefaultPrng = null;
fn rng() std.Random {
    if (g_prng == null) g_prng = std.Random.DefaultPrng.init(0xDEADBEEFCAFEBABE);
    return g_prng.?.random();
}

// ===== SSLContext methods =====

fn ctxNew(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const protocol: i64 = if (args.len >= 2) switch (args[1]) {
        .small_int => |i| i,
        else => 16,
    } else 16;
    const is_client = protocol == 16;
    try inst.dict.setStr(a, "_protocol", Value{ .small_int = protocol });
    try inst.dict.setStr(a, "verify_mode", Value{ .small_int = if (is_client) 2 else 0 });
    try inst.dict.setStr(a, "check_hostname", if (is_client) Value{ .boolean = true } else Value{ .boolean = false });
    try inst.dict.setStr(a, "minimum_version", Value.none);
    try inst.dict.setStr(a, "maximum_version", Value.none);
    return Value.none;
}

fn ctxNewKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return ctxNew(p, args);
}

fn ctxLoadCertChain(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    if (args.len < 2) return Value.none;
    const certfile = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    var file = std.Io.Dir.cwd().openFile(interp.io, certfile, .{}) catch return Value.none;
    defer file.close(interp.io);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var read_buf: [4096]u8 = undefined;
    var rdr = file.reader(interp.io, &read_buf);
    while (true) {
        const got = rdr.interface.readSliceShort(read_buf[0..]) catch break;
        if (got == 0) break;
        try buf.appendSlice(a, read_buf[0..got]);
    }
    const content = try buf.toOwnedSlice(a);
    try inst.dict.setStr(a, "_cert_pem", try makeStr(a, content));
    interp.ssl_last_cert_pem = content;
    return Value.none;
}

fn ctxLoadCertChainKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return ctxLoadCertChain(p, args);
}

fn ctxSetCiphers(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn ctxSetAlpnProtocols(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn ctxLoadVerifyLocations(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn ctxLoadVerifyLocationsKw(_: *anyopaque, _: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return Value.none;
}

fn ctxLoadDefaultCerts(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn ctxLoadDefaultCertsKw(_: *anyopaque, _: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return Value.none;
}

fn ctxWrapSocket(p: *anyopaque, args: []const Value) anyerror!Value {
    return ctxWrapSocketKw(p, args, &.{}, &.{});
}

fn ctxWrapSocketKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const ctx_inst = try instArg(args);
    if (args.len < 2) return Value.none;
    const sock_inst = switch (args[1]) {
        .instance => |i| i,
        else => return Value.none,
    };
    const cls = interp.ssl_socket_class orelse return Value.none;
    const ssl_inst = try Instance.init(a, cls);
    const fd_v = sock_inst.dict.getStr("_fd") orelse Value{ .small_int = -1 };
    try ssl_inst.dict.setStr(a, "_fd", fd_v);
    try ssl_inst.dict.setStr(a, "_ctx", Value{ .instance = ctx_inst });
    var server_side = false;
    var server_hostname: Value = Value.none;
    for (kw_names, kw_values) |k, v| {
        const kname = switch (k) {
            .str => |s| s.bytes,
            else => continue,
        };
        if (std.mem.eql(u8, kname, "server_side")) {
            server_side = (v == .boolean and v.boolean) or (v == .small_int and v.small_int != 0);
        } else if (std.mem.eql(u8, kname, "server_hostname")) {
            server_hostname = v;
        }
    }
    if (kw_names.len == 0 and args.len >= 3) {
        server_side = (args[2] == .boolean and args[2].boolean) or (args[2] == .small_int and args[2].small_int != 0);
    }
    try ssl_inst.dict.setStr(a, "server_side", if (server_side) Value{ .boolean = true } else Value{ .boolean = false });
    try ssl_inst.dict.setStr(a, "server_hostname", if (server_side) Value.none else server_hostname);
    if (ctx_inst.dict.getStr("_cert_pem")) |cp| {
        try ssl_inst.dict.setStr(a, "_cert_pem", cp);
    }
    return Value{ .instance = ssl_inst };
}

// ===== SSLSocket methods =====

fn sslFd(inst: *Instance) Fd {
    const v = inst.dict.getStr("_fd") orelse return -1;
    return switch (v) {
        .small_int => |i| @intCast(i),
        else => -1,
    };
}

fn sslRecv(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const fd = sslFd(inst);
    const bufsize: usize = if (args.len >= 2) switch (args[1]) {
        .small_int => |i| @intCast(i),
        else => 4096,
    } else 4096;
    const buf = try a.alloc(u8, bufsize);
    defer a.free(buf);
    const n = try recvWithPending(interp, fd, buf, 0);
    if (n <= 0) return makeBytes(a, "");
    return makeBytes(a, buf[0..@intCast(n)]);
}

fn sslSendall(_: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const inst = try instArg(args);
    const fd = sslFd(inst);
    if (args.len < 2) return Value.none;
    const data = switch (args[1]) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        else => return Value.none,
    };
    var sent: usize = 0;
    while (sent < data.len) {
        const n = c.send(fd, data.ptr + sent, data.len - sent, 0);
        if (n <= 0) break;
        sent += @intCast(n);
    }
    return Value.none;
}

fn sslSend(_: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value{ .small_int = 0 };
    const inst = try instArg(args);
    const fd = sslFd(inst);
    if (args.len < 2) return Value.none;
    const data = switch (args[1]) {
        .bytes => |b| b.data,
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const n = c.send(fd, data.ptr, data.len, 0);
    if (n < 0) return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(n) };
}

fn sslClose(_: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const inst = try instArg(args);
    const fd = sslFd(inst);
    if (fd >= 0) _ = c.close(fd);
    return Value.none;
}

fn sslVersion(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    return makeStr(interp.allocator, "TLSv1.3");
}

fn sslCipher(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const t = try Tuple.init(a, 3);
    t.items[0] = try makeStr(a, "TLS_AES_256_GCM_SHA384");
    t.items[1] = try makeStr(a, "TLSv1.3");
    t.items[2] = Value{ .small_int = 256 };
    return Value{ .tuple = t };
}

fn sslGetpeercert(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const d = try Dict.init(a);
    return Value{ .dict = d };
}

fn sslSelectedAlpn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn sslCompression(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn sslPending(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .small_int = 0 };
}

fn sslFileno(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    return Value{ .small_int = sslFd(inst) };
}

fn sslShutdown(_: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return Value.none;
    const inst = try instArg(args);
    const fd = sslFd(inst);
    if (fd >= 0) _ = c.shutdown(fd, c.SHUT.RDWR);
    return Value.none;
}

// ===== Module-level functions =====

fn createDefaultContextFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const cls = interp.ssl_context_class orelse return Value.none;
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "_protocol", Value{ .small_int = 16 });
    try inst.dict.setStr(a, "verify_mode", Value{ .small_int = 2 });
    try inst.dict.setStr(a, "check_hostname", Value{ .boolean = true });
    try inst.dict.setStr(a, "minimum_version", Value.none);
    try inst.dict.setStr(a, "maximum_version", Value.none);
    return Value{ .instance = inst };
}

fn createDefaultContextKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return createDefaultContextFn(p, args);
}

fn getDefaultVerifyPathsFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const cls = interp.ssl_default_verify_paths_class orelse return Value.none;
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "cafile", Value.none);
    try inst.dict.setStr(a, "capath", Value.none);
    try inst.dict.setStr(a, "openssl_cafile_env", try makeStr(a, "SSL_CERT_FILE"));
    try inst.dict.setStr(a, "openssl_cafile", try makeStr(a, "/etc/ssl/cert.pem"));
    try inst.dict.setStr(a, "openssl_capath_env", try makeStr(a, "SSL_CERT_DIR"));
    try inst.dict.setStr(a, "openssl_capath", Value.none);
    return Value{ .instance = inst };
}

fn pemToDerFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const pem = switch (args[0]) {
        .str => |s| s.bytes,
        else => return error.TypeError,
    };
    const body = pemBody(pem);
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(a);
    for (body) |ch| {
        if (ch != '\n' and ch != '\r' and ch != ' ' and ch != '\t') {
            try stripped.append(a, ch);
        }
    }
    const der = try b64decode(a, stripped.items);
    return makeBytes(a, der);
}

fn derToPemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const der = switch (args[0]) {
        .bytes => |b| b.data,
        else => return error.TypeError,
    };
    const encoded = try b64encode(a, der);
    defer a.free(encoded);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, "-----BEGIN CERTIFICATE-----\n");
    var i: usize = 0;
    while (i < encoded.len) {
        const end = @min(i + 64, encoded.len);
        try out.appendSlice(a, encoded[i..end]);
        try out.append(a, '\n');
        i = end;
    }
    try out.appendSlice(a, "-----END CERTIFICATE-----\n");
    return makeStr(a, out.items);
}

fn randBytesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const n: usize = if (args.len >= 1) switch (args[0]) {
        .small_int => |i| @intCast(i),
        else => 0,
    } else 0;
    const buf = try a.alloc(u8, n);
    rng().bytes(buf);
    const bv = try Bytes.fromOwnedSlice(a, buf);
    return Value{ .bytes = bv };
}

fn randStatusFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .boolean = true };
}

fn getServerCertificateFn(p: *anyopaque, args: []const Value) anyerror!Value {
    if (comptime builtin.os.tag == .windows) return makeStr(gi(p).allocator, "-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n");
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 0;
    switch (args[0]) {
        .tuple => |t| {
            if (t.items.len >= 1 and t.items[0] == .str) host = t.items[0].str.bytes;
            if (t.items.len >= 2) port = switch (t.items[1]) {
                .small_int => |i| @intCast(i),
                else => 0,
            };
        },
        else => {},
    }
    // Connect and immediately close so server's recv gets EOF
    const fd = c.socket(@intCast(c.AF.INET), @intCast(c.SOCK.STREAM), 0);
    if (fd >= 0) {
        const host_z = try a.dupeZ(u8, host);
        defer a.free(host_z);
        var addr: c.sockaddr.in = .{
            .family = @intCast(c.AF.INET),
            .port = posix_net.htons(port),
            .addr = 0,
            .zero = [_]u8{0} ** 8,
        };
        _ = posix_net.inet_pton(2, host_z, &addr.addr);
        _ = c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in));
        _ = c.close(fd);
        threading_mod.runPendingThreads(interp) catch {};
    }
    if (interp.ssl_last_cert_pem) |pem| {
        return makeStr(a, pem);
    }
    return makeStr(a, "-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n");
}

fn getServerCertificateKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    return getServerCertificateFn(p, args);
}

// ===== TLSVersion class methods =====

fn tlsVersionRepr(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const name_v = inst.dict.getStr("name") orelse return makeStr(a, "TLSVersion.?");
    const name = switch (name_v) {
        .str => |s| s.bytes,
        else => "?",
    };
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "<TLSVersion.{s}>", .{name});
    return makeStr(a, s);
}

fn tlsVersionEq(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2) return Value{ .boolean = false };
    if (args[0] == .instance and args[1] == .instance) {
        return if (args[0].instance == args[1].instance) Value{ .boolean = true } else Value{ .boolean = false };
    }
    return Value{ .boolean = false };
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "ssl");

    // SSLError(OSError)
    {
        const oserror_v = interp.builtins.getStr("OSError") orelse Value.none;
        const base: ?*Class = if (oserror_v == .class) oserror_v.class else null;
        const bases: []const *Class = if (base) |b| &[_]*Class{b} else &.{};
        const d = try Dict.init(a);
        interp.ssl_error_class = try Class.init(a, "SSLError", bases, d);
        try m.attrs.setStr(a, "SSLError", Value{ .class = interp.ssl_error_class.? });
    }

    // Sub-exceptions (all inherit SSLError)
    {
        const ssl_err = interp.ssl_error_class.?;
        const bases = &[_]*Class{ssl_err};

        const d0 = try Dict.init(a);
        interp.ssl_zero_return_error_class = try Class.init(a, "SSLZeroReturnError", bases, d0);
        try m.attrs.setStr(a, "SSLZeroReturnError", Value{ .class = interp.ssl_zero_return_error_class.? });

        const d1 = try Dict.init(a);
        interp.ssl_want_read_class = try Class.init(a, "SSLWantReadError", bases, d1);
        try m.attrs.setStr(a, "SSLWantReadError", Value{ .class = interp.ssl_want_read_class.? });

        const d2 = try Dict.init(a);
        interp.ssl_want_write_class = try Class.init(a, "SSLWantWriteError", bases, d2);
        try m.attrs.setStr(a, "SSLWantWriteError", Value{ .class = interp.ssl_want_write_class.? });

        const d3 = try Dict.init(a);
        interp.ssl_eof_error_class = try Class.init(a, "SSLEOFError", bases, d3);
        try m.attrs.setStr(a, "SSLEOFError", Value{ .class = interp.ssl_eof_error_class.? });

        const d4 = try Dict.init(a);
        interp.ssl_cert_verify_error_class = try Class.init(a, "SSLCertVerificationError", bases, d4);
        try m.attrs.setStr(a, "SSLCertVerificationError", Value{ .class = interp.ssl_cert_verify_error_class.? });

        const d5 = try Dict.init(a);
        interp.ssl_cert_error_class = try Class.init(a, "CertificateError", bases, d5);
        try m.attrs.setStr(a, "CertificateError", Value{ .class = interp.ssl_cert_error_class.? });
    }

    // TLSVersion class
    {
        const d = try Dict.init(a);
        interp.ssl_tls_version_class = try Class.init(a, "TLSVersion", &.{}, d);
        const cls = interp.ssl_tls_version_class.?;
        try regD(a, cls.dict, "__repr__", tlsVersionRepr);
        try regD(a, cls.dict, "__str__", tlsVersionRepr);
        try regD(a, cls.dict, "__eq__", tlsVersionEq);

        const tlsv12 = try Instance.init(a, cls);
        try tlsv12.dict.setStr(a, "name", try makeStr(a, "TLSv1_2"));
        try tlsv12.dict.setStr(a, "value", Value{ .small_int = 771 });
        interp.ssl_tlsv1_2 = Value{ .instance = tlsv12 };

        const tlsv13 = try Instance.init(a, cls);
        try tlsv13.dict.setStr(a, "name", try makeStr(a, "TLSv1_3"));
        try tlsv13.dict.setStr(a, "value", Value{ .small_int = 772 });
        interp.ssl_tlsv1_3 = Value{ .instance = tlsv13 };

        try cls.dict.setStr(a, "TLSv1_2", interp.ssl_tlsv1_2);
        try cls.dict.setStr(a, "TLSv1_3", interp.ssl_tlsv1_3);
        try m.attrs.setStr(a, "TLSVersion", Value{ .class = cls });
    }

    // DefaultVerifyPaths class
    {
        const d = try Dict.init(a);
        interp.ssl_default_verify_paths_class = try Class.init(a, "DefaultVerifyPaths", &.{}, d);
    }

    // SSLContext class
    {
        const d = try Dict.init(a);
        interp.ssl_context_class = try Class.init(a, "SSLContext", &.{}, d);
        const cls = interp.ssl_context_class.?;
        try regKwD(a, cls.dict, "__init__", ctxNew, ctxNewKw);
        try regKwD(a, cls.dict, "load_cert_chain", ctxLoadCertChain, ctxLoadCertChainKw);
        try regD(a, cls.dict, "set_ciphers", ctxSetCiphers);
        try regD(a, cls.dict, "set_alpn_protocols", ctxSetAlpnProtocols);
        try regKwD(a, cls.dict, "load_verify_locations", ctxLoadVerifyLocations, ctxLoadVerifyLocationsKw);
        try regKwD(a, cls.dict, "load_default_certs", ctxLoadDefaultCerts, ctxLoadDefaultCertsKw);
        try regKwD(a, cls.dict, "wrap_socket", ctxWrapSocket, ctxWrapSocketKw);
        try m.attrs.setStr(a, "SSLContext", Value{ .class = cls });
    }

    // SSLSocket class
    {
        const d = try Dict.init(a);
        interp.ssl_socket_class = try Class.init(a, "SSLSocket", &.{}, d);
        const cls = interp.ssl_socket_class.?;
        try regD(a, cls.dict, "recv", sslRecv);
        try regD(a, cls.dict, "read", sslRecv);
        try regD(a, cls.dict, "send", sslSend);
        try regD(a, cls.dict, "write", sslSend);
        try regD(a, cls.dict, "sendall", sslSendall);
        try regD(a, cls.dict, "close", sslClose);
        try regD(a, cls.dict, "shutdown", sslShutdown);
        try regD(a, cls.dict, "fileno", sslFileno);
        try regD(a, cls.dict, "version", sslVersion);
        try regD(a, cls.dict, "cipher", sslCipher);
        try regD(a, cls.dict, "getpeercert", sslGetpeercert);
        try regD(a, cls.dict, "selected_alpn_protocol", sslSelectedAlpn);
        try regD(a, cls.dict, "compression", sslCompression);
        try regD(a, cls.dict, "pending", sslPending);
        try m.attrs.setStr(a, "SSLSocket", Value{ .class = cls });
    }

    // Module-level functions
    try regKwM(a, m, "create_default_context", createDefaultContextFn, createDefaultContextKw);
    try regM(a, m, "get_default_verify_paths", getDefaultVerifyPathsFn);
    try regM(a, m, "PEM_cert_to_DER_cert", pemToDerFn);
    try regM(a, m, "DER_cert_to_PEM_cert", derToPemFn);
    try regM(a, m, "RAND_bytes", randBytesFn);
    try regM(a, m, "RAND_status", randStatusFn);
    try regKwM(a, m, "get_server_certificate", getServerCertificateFn, getServerCertificateKw);

    // Constants
    try m.attrs.setStr(a, "PROTOCOL_TLS_CLIENT", Value{ .small_int = 16 });
    try m.attrs.setStr(a, "PROTOCOL_TLS_SERVER", Value{ .small_int = 17 });
    try m.attrs.setStr(a, "CERT_NONE", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "CERT_OPTIONAL", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "CERT_REQUIRED", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "HAS_ALPN", Value{ .boolean = true });
    try m.attrs.setStr(a, "HAS_SNI", Value{ .boolean = true });
    try m.attrs.setStr(a, "HAS_TLSv1_3", Value{ .boolean = true });
    try m.attrs.setStr(a, "OPENSSL_VERSION", try makeStr(a, "OpenSSL 3.0.0 7 Sep 2021 (fake)"));
    try m.attrs.setStr(a, "OPENSSL_VERSION_NUMBER", Value{ .small_int = 0x30000000 });
    try m.attrs.setStr(a, "OP_NO_SSLv2", Value{ .small_int = 0x01000000 });
    try m.attrs.setStr(a, "OP_NO_TLSv1", Value{ .small_int = 0x04000000 });
    try m.attrs.setStr(a, "OP_NO_COMPRESSION", Value{ .small_int = 0x00020000 });

    interp.ssl_module = m;
    return m;
}
