//! `signal` module — POSIX signal handling for fixture 204.

const std = @import("std");
const c = std.c;
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

fn gi(p: *anyopaque) *Interp {
    return @ptrCast(@alignCast(p));
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

extern "c" fn strsignal(signum: c_int) ?[*:0]const u8;

// Handler table — indexed by signal number (0..64).
// SIG_DFL = small_int 0, SIG_IGN = small_int 1.
var g_handlers: [65]Value = [_]Value{Value{ .small_int = 0 }} ** 65;

fn getHandler(signum: i64) Value {
    if (signum < 0 or signum >= 65) return Value{ .small_int = 0 };
    return g_handlers[@intCast(signum)];
}

fn setHandler(signum: i64, h: Value) Value {
    if (signum < 0 or signum >= 65) return Value{ .small_int = 0 };
    const old = g_handlers[@intCast(signum)];
    g_handlers[@intCast(signum)] = h;
    return old;
}

// ===== strsignal(signum) =====

fn strsignalFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    const signum: c_int = switch (args[0]) {
        .small_int => |i| @intCast(i),
        else => return Value.none,
    };
    // Return None for out-of-range signals (macOS strsignal returns garbage string for them)
    if (signum <= 0 or signum > 31) return Value.none;
    const ptr = strsignal(signum) orelse return Value.none;
    const s = std.mem.sliceTo(ptr, 0);
    const sv = try Str.init(a, s);
    return Value{ .str = sv };
}

// ===== valid_signals() =====

fn validSignalsFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    // macOS signals 1..31
    const out = try List.init(a);
    for (1..32) |i| {
        try out.items.append(a, Value{ .small_int = @intCast(i) });
    }
    return Value{ .list = out };
}

// ===== default_int_handler(signum, frame) =====

fn defaultIntHandlerFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    try interp.raisePy("KeyboardInterrupt", "");
    return error.PyException;
}

// ===== getsignal(signum) =====

fn getsignalFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return Value{ .small_int = 0 };
    const signum: i64 = switch (args[0]) {
        .small_int => |i| i,
        else => return Value{ .small_int = 0 },
    };
    return getHandler(signum);
}

// ===== signal(signum, handler) =====

fn signalFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2) return Value{ .small_int = 0 };
    const signum: i64 = switch (args[0]) {
        .small_int => |i| i,
        else => return Value{ .small_int = 0 },
    };
    return setHandler(signum, args[1]);
}

// ===== raise_signal(signum) =====

fn raiseSignalFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    if (args.len < 1) return Value.none;
    const signum: i64 = switch (args[0]) {
        .small_int => |i| i,
        else => return Value.none,
    };
    const handler = getHandler(signum);
    switch (handler) {
        .small_int => |i| {
            if (i == 1) return Value.none; // SIG_IGN
            // SIG_DFL: send the real signal
            _ = c.raise(@enumFromInt(@as(u32, @intCast(signum))));
        },
        else => {
            // Callable handler: call synchronously with (signum, None)
            const sig_v = Value{ .small_int = signum };
            _ = try dispatch.invoke(interp, handler, &.{ sig_v, Value.none });
        },
    }
    return Value.none;
}

// ===== set_wakeup_fd(fd) =====

fn setWakeupFdFn(_: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    return Value{ .small_int = -1 };
}

fn setWakeupFdKw(_: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    _ = args;
    return Value{ .small_int = -1 };
}

// ===== alarm(seconds) =====

fn alarmFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const seconds: c_uint = if (args.len >= 1) switch (args[0]) {
        .small_int => |i| @intCast(i),
        else => 0,
    } else 0;
    const rem = c.alarm(seconds);
    return Value{ .small_int = rem };
}

// ===== pthread_sigmask(how, signals) =====

fn pthreadSigmaskFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 3) return Value{ .list = try List.init(a) };
    const how: c_int = switch (args[1]) {
        .small_int => |i| @intCast(i),
        else => 0,
    };
    // Build new sigset from signal list
    var new_set: c.sigset_t = 0;
    const sig_list = args[2];
    const sig_items: []const Value = switch (sig_list) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => &.{},
    };
    for (sig_items) |sv| {
        const sn: u5 = switch (sv) {
            .small_int => |i| if (i >= 1 and i <= 31) @intCast(i) else continue,
            else => continue,
        };
        new_set |= @as(c.sigset_t, 1) << (sn - 1);
    }
    var old_set: c.sigset_t = 0;
    _ = c.pthread_sigmask(how, &new_set, &old_set);
    // Decode old_set into list of signal numbers
    const out = try List.init(a);
    for (1..32) |i| {
        const bit: c.sigset_t = @as(c.sigset_t, 1) << @intCast(i - 1);
        if (old_set & bit != 0) {
            try out.items.append(a, Value{ .small_int = @intCast(i) });
        }
    }
    return Value{ .list = out };
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "signal");

    // Initialize handler table to SIG_DFL
    for (&g_handlers) |*h| h.* = Value{ .small_int = 0 };

    // Constants (macOS signal numbers)
    try m.attrs.setStr(a, "SIG_DFL", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "SIG_IGN", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "SIGHUP", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "SIGINT", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "SIGQUIT", Value{ .small_int = 3 });
    try m.attrs.setStr(a, "SIGILL", Value{ .small_int = 4 });
    try m.attrs.setStr(a, "SIGTRAP", Value{ .small_int = 5 });
    try m.attrs.setStr(a, "SIGABRT", Value{ .small_int = 6 });
    try m.attrs.setStr(a, "SIGFPE", Value{ .small_int = 8 });
    try m.attrs.setStr(a, "SIGKILL", Value{ .small_int = 9 });
    try m.attrs.setStr(a, "SIGBUS", Value{ .small_int = 10 });
    try m.attrs.setStr(a, "SIGSEGV", Value{ .small_int = 11 });
    try m.attrs.setStr(a, "SIGPIPE", Value{ .small_int = 13 });
    try m.attrs.setStr(a, "SIGALRM", Value{ .small_int = 14 });
    try m.attrs.setStr(a, "SIGTERM", Value{ .small_int = 15 });
    try m.attrs.setStr(a, "SIGSTOP", Value{ .small_int = 17 });
    try m.attrs.setStr(a, "SIGTSTP", Value{ .small_int = 18 });
    try m.attrs.setStr(a, "SIGCONT", Value{ .small_int = 19 });
    try m.attrs.setStr(a, "SIGCHLD", Value{ .small_int = 20 });
    try m.attrs.setStr(a, "SIGTTIN", Value{ .small_int = 21 });
    try m.attrs.setStr(a, "SIGTTOU", Value{ .small_int = 22 });
    try m.attrs.setStr(a, "SIGXCPU", Value{ .small_int = 24 });
    try m.attrs.setStr(a, "SIGXFSZ", Value{ .small_int = 25 });
    try m.attrs.setStr(a, "SIGVTALRM", Value{ .small_int = 26 });
    try m.attrs.setStr(a, "SIGPROF", Value{ .small_int = 27 });
    try m.attrs.setStr(a, "SIGWINCH", Value{ .small_int = 28 });
    try m.attrs.setStr(a, "SIGUSR1", Value{ .small_int = 30 });
    try m.attrs.setStr(a, "SIGUSR2", Value{ .small_int = 31 });
    try m.attrs.setStr(a, "SIGRTMIN", Value{ .small_int = 0 }); // not on macOS, stub

    try m.attrs.setStr(a, "ITIMER_REAL", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "ITIMER_VIRTUAL", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "ITIMER_PROF", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "SIG_BLOCK", Value{ .small_int = 1 });
    try m.attrs.setStr(a, "SIG_UNBLOCK", Value{ .small_int = 2 });
    try m.attrs.setStr(a, "SIG_SETMASK", Value{ .small_int = 3 });

    // Functions
    try regM(a, m, "strsignal", strsignalFn);
    try regM(a, m, "valid_signals", validSignalsFn);
    try regM(a, m, "default_int_handler", defaultIntHandlerFn);
    try regM(a, m, "getsignal", getsignalFn);
    try regM(a, m, "signal", signalFn);
    try regM(a, m, "raise_signal", raiseSignalFn);
    try regKwM(a, m, "set_wakeup_fd", setWakeupFdFn, setWakeupFdKw);
    try regM(a, m, "alarm", alarmFn);
    try regM(a, m, "pthread_sigmask", pthreadSigmaskFn);

    interp.signal_module = m;
    return m;
}
