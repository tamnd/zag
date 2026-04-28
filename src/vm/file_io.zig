//! Pinhole `open()`. Reads the file fully on open for `r`/`rb`; for
//! `w`/`wb` collects writes into a buffer and flushes on close /
//! __exit__. Enough for fixtures that round-trip through /tmp.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Str = @import("../object/string.zig").Str;
const Bytes = @import("../object/bytes.zig").Bytes;
const List = @import("../object/list.zig").List;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

var next_fd: i64 = 3;

const State = struct {
    path: []u8,
    data: std.ArrayList(u8),
    pos: usize = 0,
    write_mode: bool,
    binary: bool,
    readable_flag: bool,
    writable_flag: bool,
    closed: bool = false,
    fd: i64,
};

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn ensureClass(interp: *Interp) !*Class {
    if (interp.file_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "read", readFn);
    try methodReg(a, d, "readline", readlineFn);
    try methodReg(a, d, "readlines", readlinesFn);
    try methodReg(a, d, "write", writeFn);
    try methodReg(a, d, "writelines", writelinesFn);
    try methodReg(a, d, "seek", seekFn);
    try methodReg(a, d, "tell", tellFn);
    try methodReg(a, d, "truncate", truncateFn);
    try methodReg(a, d, "fileno", filenoFn);
    try methodReg(a, d, "isatty", isattyFn);
    try methodReg(a, d, "readable", readableFn);
    try methodReg(a, d, "writable", writableFn);
    try methodReg(a, d, "seekable", seekableFn);
    try methodReg(a, d, "flush", flushFn);
    try methodReg(a, d, "close", closeFn);
    try methodReg(a, d, "__enter__", enterFn);
    try methodReg(a, d, "__exit__", exitFn);
    try methodReg(a, d, "__iter__", iterSelfFn);
    try methodReg(a, d, "__next__", iterNextFn);
    const cls = try Class.init(a, "_File", &.{}, d);
    interp.file_class = cls;
    return cls;
}

fn stateFrom(inst: *Instance) *State {
    const v = inst.dict.getStr("_state").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

pub fn openFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("open expects (path, mode='r')");
        return error.TypeError;
    }
    const path = args[0].str.bytes;
    const mode_bytes: []const u8 = if (args.len >= 2 and args[1] == .str) args[1].str.bytes else "r";
    const write_mode = std.mem.indexOfScalar(u8, mode_bytes, 'w') != null or
        std.mem.indexOfScalar(u8, mode_bytes, 'a') != null;
    const binary = std.mem.indexOfScalar(u8, mode_bytes, 'b') != null;
    const has_plus = std.mem.indexOfScalar(u8, mode_bytes, '+') != null;
    const readable_flag = !write_mode or has_plus;
    const writable_flag = write_mode or has_plus;

    const a = interp.allocator;
    const cls = try ensureClass(interp);

    var data: std.ArrayList(u8) = .empty;
    if (!write_mode) {
        const path_z = try a.dupeZ(u8, path);
        defer a.free(path_z);
        var file = std.Io.Dir.cwd().openFile(interp.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try interp.raisePy("FileNotFoundError", path);
                return error.PyException;
            },
            else => return err,
        };
        defer file.close(interp.io);
        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(interp.io, &read_buf);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const got = reader.interface.readSliceShort(chunk[0..]) catch |err| switch (err) {
                error.ReadFailed => return err,
            };
            if (got == 0) break;
            try data.appendSlice(a, chunk[0..got]);
        }
    }

    const fd = next_fd;
    next_fd += 1;

    const state = try a.create(State);
    state.* = .{
        .path = try a.dupe(u8, path),
        .data = data,
        .write_mode = write_mode,
        .binary = binary,
        .readable_flag = readable_flag,
        .writable_flag = writable_flag,
        .fd = fd,
    };
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "_state", Value{ .small_int = @intCast(@intFromPtr(state)) });
    if (!binary) {
        try inst.dict.setStr(a, "encoding", Value{ .str = try Str.init(a, "utf-8") });
        try inst.dict.setStr(a, "errors", Value{ .str = try Str.init(a, "strict") });
    }
    return Value{ .instance = inst };
}

fn argInst(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

fn readFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const st = stateFrom(inst);
    const remaining = st.data.items.len - @min(st.pos, st.data.items.len);
    const want: usize = if (args.len >= 2 and args[1] == .small_int and args[1].small_int >= 0)
        @min(remaining, @as(usize, @intCast(args[1].small_int)))
    else
        remaining;
    const start = @min(st.pos, st.data.items.len);
    const slice = st.data.items[start .. start + want];
    st.pos = start + want;
    if (st.binary) {
        return Value{ .bytes = try Bytes.init(interp.allocator, slice) };
    }
    return Value{ .str = try Str.init(interp.allocator, slice) };
}

fn readlineFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const st = stateFrom(inst);
    const start = @min(st.pos, st.data.items.len);
    var i = start;
    while (i < st.data.items.len and st.data.items[i] != '\n') : (i += 1) {}
    if (i < st.data.items.len) i += 1;
    const slice = st.data.items[start..i];
    st.pos = i;
    if (st.binary) {
        return Value{ .bytes = try Bytes.init(interp.allocator, slice) };
    }
    return Value{ .str = try Str.init(interp.allocator, slice) };
}

fn readlinesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const st = stateFrom(inst);
    const a = interp.allocator;
    const list = try List.init(a);
    while (st.pos < st.data.items.len) {
        const start = st.pos;
        var i = start;
        while (i < st.data.items.len and st.data.items[i] != '\n') : (i += 1) {}
        if (i < st.data.items.len) i += 1;
        const slice = st.data.items[start..i];
        st.pos = i;
        if (st.binary) {
            try list.append(a, Value{ .bytes = try Bytes.init(a, slice) });
        } else {
            try list.append(a, Value{ .str = try Str.init(a, slice) });
        }
    }
    return Value{ .list = list };
}

fn writeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const inst = try argInst(args);
    const st = stateFrom(inst);
    const a = interp.allocator;
    const bytes: []const u8 = switch (args[1]) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items[0..],
        else => {
            try interp.typeError("write expects str/bytes");
            return error.TypeError;
        },
    };
    try st.data.appendSlice(a, bytes);
    st.pos = st.data.items.len;
    return Value{ .small_int = @intCast(bytes.len) };
}

fn writelinesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return error.TypeError;
    const inst = try argInst(args);
    const st = stateFrom(inst);
    const a = interp.allocator;
    const writeItem = struct {
        fn f(st2: *State, alloc: std.mem.Allocator, v: Value) !void {
            const bytes: []const u8 = switch (v) {
                .str => |s| s.bytes,
                .bytes => |b| b.data,
                .bytearray => |b| b.data.items[0..],
                else => return error.TypeError,
            };
            try st2.data.appendSlice(alloc, bytes);
            st2.pos = st2.data.items.len;
        }
    }.f;
    switch (args[1]) {
        .list => |l| for (l.items.items) |it| try writeItem(st, a, it),
        .tuple => |t| for (t.items) |it| try writeItem(st, a, it),
        .iter => |it| while (it.next()) |v| try writeItem(st, a, v),
        .generator => |g| while (try dispatch.genResume(interp, g, Value.none)) |v| try writeItem(st, a, v),
        else => return error.TypeError,
    }
    return Value.none;
}

fn seekFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try argInst(args);
    const st = stateFrom(inst);
    if (args.len < 2 or args[1] != .small_int) return error.TypeError;
    const offset = args[1].small_int;
    const whence: i64 = if (args.len >= 3 and args[2] == .small_int) args[2].small_int else 0;
    const new_pos: i64 = switch (whence) {
        0 => offset,
        1 => @as(i64, @intCast(st.pos)) + offset,
        2 => @as(i64, @intCast(st.data.items.len)) + offset,
        else => return error.ValueError,
    };
    if (new_pos < 0) return error.ValueError;
    st.pos = @intCast(new_pos);
    return Value{ .small_int = new_pos };
}

fn tellFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try argInst(args);
    const st = stateFrom(inst);
    return Value{ .small_int = @intCast(st.pos) };
}

fn truncateFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const st = stateFrom(inst);
    const a = interp.allocator;
    const size: usize = if (args.len >= 2 and args[1] == .small_int and args[1].small_int >= 0)
        @intCast(args[1].small_int)
    else
        st.pos;
    if (size < st.data.items.len) {
        try st.data.resize(a, size);
    }
    return Value{ .small_int = @intCast(size) };
}

fn filenoFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try argInst(args);
    const st = stateFrom(inst);
    return Value{ .small_int = st.fd };
}

fn isattyFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .boolean = false };
}

fn readableFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try argInst(args);
    const st = stateFrom(inst);
    return Value{ .boolean = st.readable_flag };
}

fn writableFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try argInst(args);
    const st = stateFrom(inst);
    return Value{ .boolean = st.writable_flag };
}

fn seekableFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .boolean = true };
}

fn flushFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn closeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const st = stateFrom(inst);
    if (st.closed) return Value.none;
    st.closed = true;
    if (st.write_mode) {
        var file = std.Io.Dir.cwd().createFile(interp.io, st.path, .{}) catch |err| return err;
        defer file.close(interp.io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writer(interp.io, &write_buf);
        try writer.interface.writeAll(st.data.items);
        try writer.interface.flush();
    }
    st.data.deinit(interp.allocator);
    return Value.none;
}

fn enterFn(_: *anyopaque, args: []const Value) anyerror!Value {
    const inst = try argInst(args);
    return Value{ .instance = inst };
}

fn exitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = try closeFn(p, args[0..1]);
    return Value{ .boolean = false };
}

fn iterSelfFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    return args[0];
}

fn iterNextFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const st = stateFrom(inst);
    if (st.pos >= st.data.items.len) {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    }
    return readlineFn(p, args);
}
