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

const State = struct {
    path: []u8,
    data: std.ArrayList(u8),
    pos: usize = 0,
    write_mode: bool,
    binary: bool,
    closed: bool = false,
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
    try methodReg(a, d, "readlines", readlinesFn);
    try methodReg(a, d, "write", writeFn);
    try methodReg(a, d, "close", closeFn);
    try methodReg(a, d, "__enter__", enterFn);
    try methodReg(a, d, "__exit__", exitFn);
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

    const state = try a.create(State);
    state.* = .{
        .path = try a.dupe(u8, path),
        .data = data,
        .write_mode = write_mode,
        .binary = binary,
    };
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "_state", Value{ .small_int = @intCast(@intFromPtr(state)) });
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
    const slice = st.data.items[st.pos..];
    st.pos = st.data.items.len;
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
    const slice = st.data.items[st.pos..];
    st.pos = st.data.items.len;
    var i: usize = 0;
    while (i < slice.len) {
        const start = i;
        while (i < slice.len and slice[i] != '\n') : (i += 1) {}
        if (i < slice.len) i += 1;
        const line = slice[start..i];
        if (st.binary) {
            try list.append(a, Value{ .bytes = try Bytes.init(a, line) });
        } else {
            try list.append(a, Value{ .str = try Str.init(a, line) });
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
    return Value{ .small_int = @intCast(bytes.len) };
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
