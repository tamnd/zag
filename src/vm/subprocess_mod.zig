//! `subprocess` module — run(), Popen, call(), check_call(),
//! check_output(), getoutput(), getstatusoutput(). Uses std.process.

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
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Bytes = @import("../object/bytes.zig").Bytes;
const Tuple = @import("../object/tuple.zig").Tuple;
const Interp = @import("interp.zig").Interp;

const PIPE_VAL: i64 = -1;
const DEVNULL_VAL: i64 = -2;
const STDOUT_VAL: i64 = -3;

fn gi(p: *anyopaque) *Interp {
    return @ptrCast(@alignCast(p));
}

fn instArg(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

fn sv(a: std.mem.Allocator, s: []const u8) !Value {
    return Value{ .str = try Str.init(a, s) };
}

fn regKwM(a: std.mem.Allocator, m: *Module, name: []const u8, f: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = bf });
}

fn regM(a: std.mem.Allocator, m: *Module, name: []const u8, f: BuiltinFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = bf });
}

fn regKwD(a: std.mem.Allocator, d: *Dict, name: []const u8, f: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f, .kw_func = kw };
    try d.setStr(a, name, Value{ .builtin_fn = bf });
}

fn regD(a: std.mem.Allocator, d: *Dict, name: []const u8, f: BuiltinFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f };
    try d.setStr(a, name, Value{ .builtin_fn = bf });
}

// ===== PopenState =====

const PopenState = struct {
    child: std.process.Child,
    text: bool = false,
    returncode: ?i64 = null,
};

fn statePtr(inst: *Instance) ?*PopenState {
    const sv_v = inst.dict.getStr("_state") orelse return null;
    if (sv_v != .small_int) return null;
    return @ptrFromInt(@as(usize, @intCast(sv_v.small_int)));
}

// ===== build argv =====

fn buildArgv(a: std.mem.Allocator, cmd_v: Value, shell: bool) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    if (shell) {
        try list.append(a, "sh");
        try list.append(a, "-c");
        switch (cmd_v) {
            .str => |s| try list.append(a, s.bytes),
            .list => |l| {
                var joined: std.ArrayListUnmanaged(u8) = .empty;
                defer joined.deinit(a);
                for (l.items.items, 0..) |item, i| {
                    if (i > 0) try joined.append(a, ' ');
                    if (item == .str) try joined.appendSlice(a, item.str.bytes);
                }
                try list.append(a, try a.dupe(u8, joined.items));
            },
            else => try list.append(a, ""),
        }
    } else {
        switch (cmd_v) {
            .list => |l| for (l.items.items) |item| {
                if (item == .str) try list.append(a, item.str.bytes);
            },
            .tuple => |t| for (t.items) |item| {
                if (item == .str) try list.append(a, item.str.bytes);
            },
            .str => |s| try list.append(a, s.bytes),
            else => {},
        }
    }
    return list.toOwnedSlice(a);
}

// ===== read all from child stdout/stderr =====

fn readChildPipe(a: std.mem.Allocator, io: std.Io, file: std.Io.File) ![]u8 {
    var data: std.ArrayListUnmanaged(u8) = .empty;
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = reader.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try data.appendSlice(a, chunk[0..n]);
    }
    return data.toOwnedSlice(a);
}

// ===== build environ map =====

fn buildEnvMap(a: std.mem.Allocator, d: *Dict) !std.process.Environ.Map {
    var m = std.process.Environ.Map.init(a);
    for (d.pairs.items) |pair| {
        if (pair.key == .str and pair.value == .str)
            try m.put(pair.key.str.bytes, pair.value.str.bytes);
    }
    return m;
}

// ===== term → returncode =====

fn termRc(term: std.process.Child.Term) i64 {
    return switch (term) {
        .exited => |c| @intCast(c),
        .signal => |s| -@as(i64, @intCast(@intFromEnum(s))),
        else => -1,
    };
}

// ===== core run =====

const RunArgs = struct {
    cmd_v: Value = Value.none,
    capture_stdout: bool = false,
    capture_stderr: bool = false,
    text: bool = false,
    input_bytes: ?[]const u8 = null,
    shell: bool = false,
    cwd_opt: ?[]const u8 = null,
    env_dict_opt: ?*Dict = null,
    check: bool = false,
    timeout_secs: f64 = -1.0,
    stdin_mode: i64 = 0,
    stdout_mode: i64 = 0,
    stderr_mode: i64 = 0,
};

fn parseRunArgs(args: []const Value, kn: []const Value, kv: []const Value) RunArgs {
    var r = RunArgs{};
    if (args.len >= 1) r.cmd_v = args[0];
    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        const k = nm.str.bytes;
        if (std.mem.eql(u8, k, "capture_output")) r.capture_stdout = vl == .boolean and vl.boolean;
        if (std.mem.eql(u8, k, "text")) r.text = vl == .boolean and vl.boolean;
        if (std.mem.eql(u8, k, "shell")) r.shell = vl == .boolean and vl.boolean;
        if (std.mem.eql(u8, k, "check")) r.check = vl == .boolean and vl.boolean;
        if (std.mem.eql(u8, k, "cwd") and vl == .str) r.cwd_opt = vl.str.bytes;
        if (std.mem.eql(u8, k, "env") and vl == .dict) r.env_dict_opt = vl.dict;
        if (std.mem.eql(u8, k, "timeout")) {
            if (vl == .float) r.timeout_secs = vl.float;
            if (vl == .small_int) r.timeout_secs = @floatFromInt(vl.small_int);
        }
        if (std.mem.eql(u8, k, "stdout") and vl == .small_int) r.stdout_mode = vl.small_int;
        if (std.mem.eql(u8, k, "stderr") and vl == .small_int) r.stderr_mode = vl.small_int;
        if (std.mem.eql(u8, k, "stdin") and vl == .small_int) r.stdin_mode = vl.small_int;
        if (std.mem.eql(u8, k, "input")) {
            if (vl == .str) r.input_bytes = vl.str.bytes;
            if (vl == .bytes) r.input_bytes = vl.bytes.data;
        }
    }
    if (r.capture_stdout) {
        r.stdout_mode = PIPE_VAL;
        r.stderr_mode = PIPE_VAL;
    }
    return r;
}

fn outVal(a: std.mem.Allocator, data: ?[]const u8, text: bool, captured: bool) !Value {
    if (!captured or data == null) return Value.none;
    if (text) return Value{ .str = try Str.init(a, data.?) };
    return Value{ .bytes = try Bytes.init(a, data.?) };
}

fn runCore(interp: *Interp, ra: RunArgs) !Value {
    const a = interp.allocator;

    const argv = try buildArgv(a, ra.cmd_v, ra.shell);
    defer a.free(argv);

    const cwd_arg: std.process.Child.Cwd = if (ra.cwd_opt) |path| .{ .path = path } else .inherit;

    var env_map_opt: ?std.process.Environ.Map = if (ra.env_dict_opt) |d| try buildEnvMap(a, d) else null;
    defer if (env_map_opt) |*m| m.deinit();
    const env_ptr: ?*const std.process.Environ.Map = if (env_map_opt) |*m| m else null;

    const cap_stdout = ra.stdout_mode == PIPE_VAL;
    const cap_stderr = ra.stderr_mode == PIPE_VAL;

    var out_buf: ?[]u8 = null;
    var err_buf: ?[]u8 = null;
    var returncode: i64 = 0;

    defer if (out_buf) |b| a.free(b);
    defer if (err_buf) |b| a.free(b);

    if (ra.input_bytes != null or ra.stdin_mode == PIPE_VAL) {
        // Spawn + manage pipes
        const stdin_io: std.process.SpawnOptions.StdIo = if (ra.input_bytes != null or ra.stdin_mode == PIPE_VAL) .pipe else .inherit;
        const stdout_io: std.process.SpawnOptions.StdIo = if (cap_stdout) .pipe else if (ra.stdout_mode == DEVNULL_VAL) .ignore else .inherit;
        const stderr_io: std.process.SpawnOptions.StdIo = if (cap_stderr) .pipe else if (ra.stderr_mode == DEVNULL_VAL) .ignore else .inherit;

        var child = try std.process.spawn(interp.io, .{
            .argv = argv,
            .cwd = cwd_arg,
            .environ_map = env_ptr,
            .stdin = stdin_io,
            .stdout = stdout_io,
            .stderr = stderr_io,
        });

        if (child.stdin) |stdin_f| {
            if (ra.input_bytes) |inp| {
                var wbuf: [4096]u8 = undefined;
                var writer = stdin_f.writer(interp.io, &wbuf);
                writer.interface.writeAll(inp) catch {};
                writer.interface.flush() catch {};
            }
            stdin_f.close(interp.io);
            child.stdin = null;
        }

        if (cap_stdout) {
            if (child.stdout) |f| {
                out_buf = try readChildPipe(a, interp.io, f);
                f.close(interp.io);
                child.stdout = null;
            }
        }
        if (cap_stderr) {
            if (child.stderr) |f| {
                err_buf = try readChildPipe(a, interp.io, f);
                f.close(interp.io);
                child.stderr = null;
            }
        }

        const term = child.wait(interp.io) catch std.process.Child.Term{ .exited = 0 };
        returncode = termRc(term);
    } else {
        // Use std.process.run (handles stdout+stderr capture, timeout)
        const run_timeout: std.Io.Timeout = if (ra.timeout_secs > 0) blk: {
            const ns: i96 = @intFromFloat(ra.timeout_secs * 1e9);
            break :blk .{ .duration = .{ .raw = .{ .nanoseconds = ns }, .clock = .boot } };
        } else .none;

        const res = std.process.run(a, interp.io, .{
            .argv = argv,
            .cwd = cwd_arg,
            .environ_map = env_ptr,
            .timeout = run_timeout,
        }) catch |e| switch (e) {
            error.Timeout => {
                const exc = try Instance.init(a, interp.subprocess_timeout_class.?);
                try exc.dict.setStr(a, "cmd", ra.cmd_v);
                try exc.dict.setStr(a, "timeout", Value{ .float = ra.timeout_secs });
                try exc.dict.setStr(a, "output", Value.none);
                try exc.dict.setStr(a, "stderr", Value.none);
                interp.current_exc = Value{ .instance = exc };
                return error.PyException;
            },
            else => return e,
        };
        defer a.free(res.stdout);
        defer a.free(res.stderr);

        returncode = termRc(res.term);
        if (cap_stdout) out_buf = try a.dupe(u8, res.stdout);
        if (cap_stderr) err_buf = try a.dupe(u8, res.stderr);
    }

    if (ra.check and returncode != 0) {
        const exc = try Instance.init(a, interp.subprocess_called_proc_err_class.?);
        try exc.dict.setStr(a, "returncode", Value{ .small_int = returncode });
        try exc.dict.setStr(a, "cmd", ra.cmd_v);
        try exc.dict.setStr(a, "output", try outVal(a, out_buf, ra.text, cap_stdout));
        try exc.dict.setStr(a, "stderr", try outVal(a, err_buf, ra.text, cap_stderr));
        const t = try Tuple.init(a, 1);
        t.items[0] = Value{ .small_int = returncode };
        try exc.dict.setStr(a, "args", Value{ .tuple = t });
        interp.current_exc = Value{ .instance = exc };
        return error.PyException;
    }

    const cp = try Instance.init(a, interp.subprocess_completed_proc_class.?);
    try cp.dict.setStr(a, "args", ra.cmd_v);
    try cp.dict.setStr(a, "returncode", Value{ .small_int = returncode });
    const ov = try outVal(a, out_buf, ra.text, cap_stdout);
    const ev = try outVal(a, err_buf, ra.text, cap_stderr);
    try cp.dict.setStr(a, "stdout", ov);
    try cp.dict.setStr(a, "stderr", ev);

    out_buf = null; // prevent double-free (already duped into the Value)
    err_buf = null;

    return Value{ .instance = cp };
}

// ===== run() =====

fn runFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return runKw(p, args, &.{}, &.{});
}

fn runKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const ra = parseRunArgs(args, kn, kv);
    return runCore(interp, ra);
}

// ===== CompletedProcess.check_returncode =====

fn cpCheckReturncode(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const rc_v = inst.dict.getStr("returncode") orelse Value{ .small_int = 0 };
    const rc: i64 = if (rc_v == .small_int) rc_v.small_int else 0;
    if (rc != 0) {
        const exc = try Instance.init(a, interp.subprocess_called_proc_err_class.?);
        try exc.dict.setStr(a, "returncode", Value{ .small_int = rc });
        try exc.dict.setStr(a, "cmd", inst.dict.getStr("args") orelse Value.none);
        try exc.dict.setStr(a, "output", Value.none);
        try exc.dict.setStr(a, "stderr", Value.none);
        const t = try Tuple.init(a, 1);
        t.items[0] = Value{ .small_int = rc };
        try exc.dict.setStr(a, "args", Value{ .tuple = t });
        interp.current_exc = Value{ .instance = exc };
        return error.PyException;
    }
    return Value.none;
}

// ===== CalledProcessError.__str__ / __repr__ =====

fn calledErrStr(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const rc_v = inst.dict.getStr("returncode") orelse Value{ .small_int = -1 };
    const rc: i64 = if (rc_v == .small_int) rc_v.small_int else -1;
    const s = try std.fmt.allocPrint(a, "Command returned non-zero exit status {d}", .{rc});
    return sv(a, s);
}

// ===== Popen =====

fn popenCtor(p: *anyopaque, args: []const Value) anyerror!Value {
    return popenCtorKw(p, args, &.{}, &.{});
}

fn popenCtorKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;

    const cmd_v: Value = if (args.len >= 1) args[0] else Value.none;
    var stdin_mode: i64 = 0;
    var stdout_mode: i64 = 0;
    var stderr_mode: i64 = 0;
    var shell = false;
    var text = false;
    var cwd_opt: ?[]const u8 = null;
    var env_dict_opt: ?*Dict = null;

    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        const k = nm.str.bytes;
        if (std.mem.eql(u8, k, "stdin") and vl == .small_int) stdin_mode = vl.small_int;
        if (std.mem.eql(u8, k, "stdout") and vl == .small_int) stdout_mode = vl.small_int;
        if (std.mem.eql(u8, k, "stderr") and vl == .small_int) stderr_mode = vl.small_int;
        if (std.mem.eql(u8, k, "shell")) shell = vl == .boolean and vl.boolean;
        if (std.mem.eql(u8, k, "text")) text = vl == .boolean and vl.boolean;
        if (std.mem.eql(u8, k, "cwd") and vl == .str) cwd_opt = vl.str.bytes;
        if (std.mem.eql(u8, k, "env") and vl == .dict) env_dict_opt = vl.dict;
    }

    const argv = try buildArgv(a, cmd_v, shell);
    defer a.free(argv);

    const cwd_arg: std.process.Child.Cwd = if (cwd_opt) |path| .{ .path = path } else .inherit;
    var env_map_opt: ?std.process.Environ.Map = if (env_dict_opt) |d| try buildEnvMap(a, d) else null;
    defer if (env_map_opt) |*m| m.deinit();
    const env_ptr: ?*const std.process.Environ.Map = if (env_map_opt) |*m| m else null;

    const stdin_io: std.process.SpawnOptions.StdIo = if (stdin_mode == PIPE_VAL) .pipe else .inherit;
    const stdout_io: std.process.SpawnOptions.StdIo = if (stdout_mode == PIPE_VAL) .pipe else if (stdout_mode == DEVNULL_VAL) .ignore else .inherit;
    const stderr_io: std.process.SpawnOptions.StdIo = if (stderr_mode == PIPE_VAL) .pipe else if (stderr_mode == DEVNULL_VAL) .ignore else .inherit;

    const child = try std.process.spawn(interp.io, .{
        .argv = argv,
        .cwd = cwd_arg,
        .environ_map = env_ptr,
        .stdin = stdin_io,
        .stdout = stdout_io,
        .stderr = stderr_io,
    });

    const state = try a.create(PopenState);
    state.* = .{ .child = child, .text = text };

    const inst = try Instance.init(a, interp.subprocess_popen_class.?);
    try inst.dict.setStr(a, "_state", Value{ .small_int = @intCast(@intFromPtr(state)) });
    try inst.dict.setStr(a, "args", cmd_v);
    try inst.dict.setStr(a, "returncode", Value.none);
    try inst.dict.setStr(a, "pid", Value{ .small_int = @intCast(child.id orelse 0) });
    return Value{ .instance = inst };
}

fn popenCommunicate(p: *anyopaque, args: []const Value) anyerror!Value {
    return popenCommunicateKw(p, args, &.{}, &.{});
}

fn popenCommunicateKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const state = statePtr(inst) orelse return Value.none;

    var input_bytes: ?[]const u8 = null;
    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        if (std.mem.eql(u8, nm.str.bytes, "input")) {
            if (vl == .str) input_bytes = vl.str.bytes;
            if (vl == .bytes) input_bytes = vl.bytes.data;
        }
    }
    if (args.len >= 2 and args[1] != .none) {
        if (args[1] == .str) input_bytes = args[1].str.bytes;
        if (args[1] == .bytes) input_bytes = args[1].bytes.data;
    }

    if (state.child.stdin) |stdin_f| {
        if (input_bytes) |inp| {
            var wbuf: [4096]u8 = undefined;
            var writer = stdin_f.writer(interp.io, &wbuf);
            writer.interface.writeAll(inp) catch {};
            writer.interface.flush() catch {};
        }
        stdin_f.close(interp.io);
        state.child.stdin = null;
    }

    var out_data: ?[]u8 = null;
    var err_data: ?[]u8 = null;
    defer if (out_data) |d| a.free(d);
    defer if (err_data) |d| a.free(d);

    if (state.child.stdout) |f| {
        out_data = try readChildPipe(a, interp.io, f);
        f.close(interp.io);
        state.child.stdout = null;
    }
    if (state.child.stderr) |f| {
        err_data = try readChildPipe(a, interp.io, f);
        f.close(interp.io);
        state.child.stderr = null;
    }

    if (state.returncode == null) {
        const rc: i64 = if (state.child.id != null) blk: {
            const term = state.child.wait(interp.io) catch std.process.Child.Term{ .exited = 0 };
            break :blk termRc(term);
        } else -9;
        state.returncode = rc;
        try inst.dict.setStr(a, "returncode", Value{ .small_int = rc });
    }

    const out_v = if (out_data) |d| try outVal2(a, d, state.text) else Value.none;
    const err_v = if (err_data) |d| try outVal2(a, d, state.text) else Value.none;

    out_data = null;
    err_data = null;

    const items = try a.alloc(Value, 2);
    items[0] = out_v;
    items[1] = err_v;
    return Value{ .tuple = try Tuple.fromSlice(a, items) };
}

fn outVal2(a: std.mem.Allocator, data: []const u8, text: bool) !Value {
    if (text) return Value{ .str = try Str.init(a, data) };
    return Value{ .bytes = try Bytes.init(a, data) };
}

fn popenPoll(p: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try instArg(args);
    _ = p;
    const state = statePtr(inst) orelse return Value.none;
    if (state.returncode) |rc| return Value{ .small_int = rc };
    return Value.none;
}

fn popenWait(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    const inst = try instArg(args);
    const state = statePtr(inst) orelse return Value{ .small_int = 0 };
    if (state.returncode) |rc| return Value{ .small_int = rc };
    const rc: i64 = if (state.child.id != null) blk: {
        const term = state.child.wait(interp.io) catch std.process.Child.Term{ .exited = 0 };
        break :blk termRc(term);
    } else -9;
    state.returncode = rc;
    try inst.dict.setStr(a, "returncode", Value{ .small_int = rc });
    return Value{ .small_int = rc };
}

fn popenKill(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const inst = try instArg(args);
    const state = statePtr(inst) orelse return Value.none;
    state.child.kill(interp.io);
    return Value.none;
}

fn popenEnter(_: *anyopaque, args: []const Value) anyerror!Value {
    return args[0];
}

fn popenExit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try popenWait(p, args);
    return Value{ .boolean = false };
}

// ===== call() check_call() check_output() =====

fn callFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return callKw(p, args, &.{}, &.{});
}

fn callKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const cp = try runKw(p, args, kn, kv);
    if (cp == .instance) {
        return cp.instance.dict.getStr("returncode") orelse Value{ .small_int = 0 };
    }
    return Value{ .small_int = 0 };
}

fn checkCallFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return checkCallKw(p, args, &.{}, &.{});
}

fn checkCallKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    var kn2: std.ArrayListUnmanaged(Value) = .empty;
    defer kn2.deinit(a);
    var kv2: std.ArrayListUnmanaged(Value) = .empty;
    defer kv2.deinit(a);
    for (kn) |nm| try kn2.append(a, nm);
    for (kv) |vl| try kv2.append(a, vl);
    try kn2.append(a, try sv(a, "check"));
    try kv2.append(a, Value{ .boolean = true });
    _ = try runKw(p, args, kn2.items, kv2.items);
    return Value{ .small_int = 0 };
}

fn checkOutputFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return checkOutputKw(p, args, &.{}, &.{});
}

fn checkOutputKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    var kn2: std.ArrayListUnmanaged(Value) = .empty;
    defer kn2.deinit(a);
    var kv2: std.ArrayListUnmanaged(Value) = .empty;
    defer kv2.deinit(a);
    for (kn) |nm| try kn2.append(a, nm);
    for (kv) |vl| try kv2.append(a, vl);
    try kn2.append(a, try sv(a, "capture_output"));
    try kv2.append(a, Value{ .boolean = true });
    try kn2.append(a, try sv(a, "check"));
    try kv2.append(a, Value{ .boolean = true });
    const cp = try runKw(p, args, kn2.items, kv2.items);
    if (cp == .instance) return cp.instance.dict.getStr("stdout") orelse Value.none;
    return Value.none;
}

// ===== getoutput() / getstatusoutput() =====

fn getoutputFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return sv(a, "");
    const ra = RunArgs{
        .cmd_v = args[0],
        .shell = true,
        .capture_stdout = true,
        .capture_stderr = false,
        .stdout_mode = PIPE_VAL,
        .text = true,
    };
    const cp = try runCore(interp, ra);
    if (cp == .instance) {
        const out_v = cp.instance.dict.getStr("stdout") orelse return sv(a, "");
        if (out_v == .str) {
            const trimmed = std.mem.trimEnd(u8,out_v.str.bytes, "\n\r");
            return sv(a, trimmed);
        }
        return out_v;
    }
    return sv(a, "");
}

fn getstatusoutputFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) {
        const items = try a.alloc(Value, 2);
        items[0] = Value{ .small_int = 0 };
        items[1] = try sv(a, "");
        return Value{ .tuple = try Tuple.fromSlice(a, items) };
    }
    const ra = RunArgs{
        .cmd_v = args[0],
        .shell = true,
        .capture_stdout = true,
        .capture_stderr = false,
        .stdout_mode = PIPE_VAL,
        .text = true,
    };
    const cp = runCore(interp, ra) catch {
        const items = try a.alloc(Value, 2);
        items[0] = Value{ .small_int = 1 };
        items[1] = try sv(a, "");
        return Value{ .tuple = try Tuple.fromSlice(a, items) };
    };

    const rc = if (cp == .instance) cp.instance.dict.getStr("returncode") orelse Value{ .small_int = 0 } else Value{ .small_int = 0 };
    const out = if (cp == .instance) cp.instance.dict.getStr("stdout") orelse try sv(a, "") else try sv(a, "");
    const out_trimmed = if (out == .str) try sv(a, std.mem.trimEnd(u8,out.str.bytes, "\n\r")) else out;
    const items = try a.alloc(Value, 2);
    items[0] = rc;
    items[1] = out_trimmed;
    return Value{ .tuple = try Tuple.fromSlice(a, items) };
}

// ===== ensureClasses =====

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;

    if (interp.subprocess_completed_proc_class == null) {
        const d = try Dict.init(a);
        try regD(a, d, "check_returncode", cpCheckReturncode);
        interp.subprocess_completed_proc_class = try Class.init(a, "CompletedProcess", &.{}, d);
    }

    if (interp.subprocess_error_class == null) {
        const d = try Dict.init(a);
        interp.subprocess_error_class = try Class.init(a, "SubprocessError", &.{}, d);
        try interp.builtins.setStr(a, "SubprocessError", Value{ .class = interp.subprocess_error_class.? });
    }

    if (interp.subprocess_called_proc_err_class == null) {
        const d = try Dict.init(a);
        try regD(a, d, "__str__", calledErrStr);
        try regD(a, d, "__repr__", calledErrStr);
        interp.subprocess_called_proc_err_class = try Class.init(a, "CalledProcessError", &.{interp.subprocess_error_class.?}, d);
        try interp.builtins.setStr(a, "CalledProcessError", Value{ .class = interp.subprocess_called_proc_err_class.? });
    }

    if (interp.subprocess_timeout_class == null) {
        const d = try Dict.init(a);
        interp.subprocess_timeout_class = try Class.init(a, "TimeoutExpired", &.{interp.subprocess_error_class.?}, d);
        try interp.builtins.setStr(a, "TimeoutExpired", Value{ .class = interp.subprocess_timeout_class.? });
    }

    if (interp.subprocess_popen_class == null) {
        const d = try Dict.init(a);
        try regKwD(a, d, "__init__", popenCtor, popenCtorKw);
        try regKwD(a, d, "communicate", popenCommunicate, popenCommunicateKw);
        try regD(a, d, "poll", popenPoll);
        try regD(a, d, "wait", popenWait);
        try regD(a, d, "kill", popenKill);
        try regD(a, d, "__enter__", popenEnter);
        try regD(a, d, "__exit__", popenExit);
        interp.subprocess_popen_class = try Class.init(a, "Popen", &.{}, d);
    }
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "subprocess");
    interp.subprocess_module = m;

    interp.subprocess_completed_proc_class = null;
    interp.subprocess_called_proc_err_class = null;
    interp.subprocess_timeout_class = null;
    interp.subprocess_error_class = null;
    interp.subprocess_popen_class = null;

    try ensureClasses(interp);

    try regKwM(a, m, "run", runFn, runKw);
    try regKwM(a, m, "Popen", popenCtor, popenCtorKw);
    try regKwM(a, m, "call", callFn, callKw);
    try regKwM(a, m, "check_call", checkCallFn, checkCallKw);
    try regKwM(a, m, "check_output", checkOutputFn, checkOutputKw);
    try regM(a, m, "getoutput", getoutputFn);
    try regM(a, m, "getstatusoutput", getstatusoutputFn);

    try m.attrs.setStr(a, "PIPE", Value{ .small_int = PIPE_VAL });
    try m.attrs.setStr(a, "DEVNULL", Value{ .small_int = DEVNULL_VAL });
    try m.attrs.setStr(a, "STDOUT", Value{ .small_int = STDOUT_VAL });

    try m.attrs.setStr(a, "CompletedProcess", Value{ .class = interp.subprocess_completed_proc_class.? });
    try m.attrs.setStr(a, "CalledProcessError", Value{ .class = interp.subprocess_called_proc_err_class.? });
    try m.attrs.setStr(a, "TimeoutExpired", Value{ .class = interp.subprocess_timeout_class.? });
    try m.attrs.setStr(a, "SubprocessError", Value{ .class = interp.subprocess_error_class.? });

    return m;
}
