//! Pinhole `shelve`. Uses a private binary format (ZSHV magic +
//! fixed-size records) stored at `path`. Every key is a str; every
//! value is encoded with the same framing as pickle_mod.zig.
//!
//! Record layout: [u32 key_len][key bytes][u32 val_len][val bytes]
//! File ends when key_len == 0.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Iter = @import("../object/iter.zig").Iter;
const Str = @import("../object/string.zig").Str;
const Bytes = @import("../object/bytes.zig").Bytes;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const pickle = @import("pickle_mod.zig");

const MAGIC = "ZSHV";
const DEFAULT_PROTOCOL: i64 = 5;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "shelve");

    try m.attrs.setStr(a, "DEFAULT_PROTOCOL", Value{ .small_int = DEFAULT_PROTOCOL });

    if (interp.shelve_class == null) {
        try buildShelfClass(interp);
    }
    try m.attrs.setStr(a, "Shelf", Value{ .class = interp.shelve_class.? });

    const f = try a.create(BuiltinFn);
    f.* = .{ .name = "open", .func = openFn, .kw_func = openKw };
    try m.attrs.setStr(a, "open", Value{ .builtin_fn = f });

    return m;
}

// ===== Shelf state =====

const Shelf = struct {
    path: []u8,
    data: *Dict,
    flag: u8, // 'c' 'n' 'r'
    writeback: bool,
    closed: bool,
};

fn newShelf(a: std.mem.Allocator) !*Shelf {
    const s = try a.create(Shelf);
    s.* = .{
        .path = undefined,
        .data = try Dict.init(a),
        .flag = 'c',
        .writeback = false,
        .closed = false,
    };
    return s;
}

fn shelfFromInst(inst: *Instance) *Shelf {
    const v = inst.dict.getStr("_shelf").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn argInst(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

// ===== File I/O =====

fn readFileAlloc(interp: *Interp, path: []const u8) ![]u8 {
    const a = interp.allocator;
    var file = std.Io.Dir.cwd().openFile(interp.io, path, .{}) catch return try a.alloc(u8, 0);
    defer file.close(interp.io);
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(a);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(interp.io, &read_buf);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const got = reader.interface.readSliceShort(chunk[0..]) catch break;
        if (got == 0) break;
        try data.appendSlice(a, chunk[0..got]);
    }
    return try data.toOwnedSlice(a);
}

fn writeFileBytes(interp: *Interp, path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(interp.io, path, .{ .truncate = true });
    defer file.close(interp.io);
    var write_buf: [4096]u8 = undefined;
    var w = file.writer(interp.io, &write_buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

fn loadFromFile(interp: *Interp, path: []const u8) !*Dict {
    const a = interp.allocator;
    const d = try Dict.init(a);
    const contents = try readFileAlloc(interp, path);
    defer a.free(contents);
    if (contents.len < MAGIC.len or !std.mem.eql(u8, contents[0..MAGIC.len], MAGIC)) return d;

    var pos: usize = MAGIC.len;
    while (pos + 4 <= contents.len) {
        const key_len = std.mem.readInt(u32, contents[pos..][0..4], .little);
        pos += 4;
        if (key_len == 0) break;
        if (pos + key_len + 4 > contents.len) break;
        const key_bytes = contents[pos .. pos + key_len];
        pos += key_len;
        const val_len = std.mem.readInt(u32, contents[pos..][0..4], .little);
        pos += 4;
        if (pos + val_len > contents.len) break;
        const val_bytes = contents[pos .. pos + val_len];
        pos += val_len;

        const v = try pickle.decodeFromBytes(interp, val_bytes);
        try d.setStr(a, key_bytes, v);
    }
    return d;
}

fn saveToFile(interp: *Interp, path: []const u8, d: *Dict) !void {
    const a = interp.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, MAGIC);

    for (d.pairs.items) |pair| {
        if (pair.key != .str) continue;
        const key = pair.key.str.bytes;
        const val_bytes = try pickle.encodeToBytes(a, pair.value);
        defer a.free(val_bytes);

        var klen: [4]u8 = undefined;
        var vlen: [4]u8 = undefined;
        std.mem.writeInt(u32, &klen, @intCast(key.len), .little);
        std.mem.writeInt(u32, &vlen, @intCast(val_bytes.len), .little);
        try buf.appendSlice(a, &klen);
        try buf.appendSlice(a, key);
        try buf.appendSlice(a, &vlen);
        try buf.appendSlice(a, val_bytes);
    }
    try buf.appendSlice(a, &[_]u8{ 0, 0, 0, 0 });
    try writeFileBytes(interp, path, buf.items);
}

// ===== open function =====

fn openImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    const a = interp.allocator;
    try ensureShelfClass(interp);

    if (args.len < 1 or args[0] != .str) {
        try interp.raisePy("TypeError", "shelve.open requires a path");
        return error.PyException;
    }
    const path = args[0].str.bytes;

    var flag: u8 = 'c';
    var writeback = false;
    // positional: open(path, flag='c', protocol=None, writeback=False)
    if (args.len >= 2 and args[1] == .str and args[1].str.bytes.len == 1) {
        flag = args[1].str.bytes[0];
    }
    if (args.len >= 4 and args[3] == .boolean) writeback = args[3].boolean;
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "flag") and v == .str and v.str.bytes.len == 1) flag = v.str.bytes[0];
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "writeback") and v == .boolean) writeback = v.boolean;
    }

    const s = try newShelf(a);
    const path_owned = try a.dupe(u8, path);
    s.path = path_owned;
    s.flag = flag;
    s.writeback = writeback;

    if (flag == 'n') {
        // start fresh — no loading
    } else {
        s.data = try loadFromFile(interp, path);
    }

    const inst = try Instance.init(a, interp.shelve_class.?);
    try inst.dict.setStr(a, "_shelf", Value{ .small_int = @intCast(@intFromPtr(s)) });
    return Value{ .instance = inst };
}

fn openFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return openImpl(interp, args, &.{}, &.{});
}

fn openKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_vals: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return openImpl(interp, args, kw_names, kw_vals);
}

// ===== Shelf class methods =====

fn buildShelfClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "__getitem__", shelfGet);
    try methodReg(a, d, "__setitem__", shelfSet);
    try methodReg(a, d, "__delitem__", shelfDel);
    try methodReg(a, d, "__contains__", shelfContains);
    try methodReg(a, d, "__len__", shelfLen);
    try methodReg(a, d, "__iter__", shelfIter);
    try methodReg(a, d, "__enter__", shelfEnter);
    try methodReg(a, d, "__exit__", shelfExit);
    try methodReg(a, d, "keys", shelfKeys);
    try methodReg(a, d, "values", shelfValues);
    try methodReg(a, d, "items", shelfItems);
    try methodReg(a, d, "get", shelfGetMethod);
    try methodReg(a, d, "pop", shelfPop);
    try methodReg(a, d, "setdefault", shelfSetdefault);
    try methodReg(a, d, "update", shelfUpdate);
    try methodReg(a, d, "sync", shelfSync);
    try methodReg(a, d, "close", shelfClose);
    interp.shelve_class = try Class.init(a, "Shelf", &.{}, d);
}

fn ensureShelfClass(interp: *Interp) !void {
    if (interp.shelve_class == null) try buildShelfClass(interp);
}

fn methodReg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn checkOpen(interp: *Interp, s: *Shelf) !void {
    if (s.closed) {
        try interp.raisePy("ValueError", "I/O operation on closed shelf");
        return error.PyException;
    }
}

fn shelfGet(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const s = shelfFromInst(inst);
    try checkOpen(interp, s);
    if (args.len < 2 or args[1] != .str) {
        try interp.raisePy("TypeError", "shelf key must be str");
        return error.PyException;
    }
    const key = args[1].str.bytes;
    if (s.data.getStr(key)) |v| {
        if (s.writeback) {
            // Return original value; mutations will be visible
        }
        return v;
    }
    try interp.raisePy("KeyError", key);
    return error.PyException;
}

fn shelfSet(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const s = shelfFromInst(inst);
    try checkOpen(interp, s);
    if (s.flag == 'r') {
        try interp.raisePy("ValueError", "shelf is read-only");
        return error.PyException;
    }
    if (args.len < 3 or args[1] != .str) {
        try interp.raisePy("TypeError", "shelf key must be str");
        return error.PyException;
    }
    try s.data.setStr(interp.allocator, args[1].str.bytes, args[2]);
    return Value.none;
}

fn shelfDel(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const s = shelfFromInst(inst);
    try checkOpen(interp, s);
    if (args.len < 2 or args[1] != .str) {
        try interp.raisePy("TypeError", "shelf key must be str");
        return error.PyException;
    }
    const key = args[1].str.bytes;
    if (!s.data.delete(key)) {
        try interp.raisePy("KeyError", key);
        return error.PyException;
    }
    return Value.none;
}

fn shelfContains(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const s = shelfFromInst(inst);
    try checkOpen(interp, s);
    if (args.len < 2 or args[1] != .str) return Value{ .boolean = false };
    return Value{ .boolean = s.data.getStr(args[1].str.bytes) != null };
}

fn shelfLen(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const s = shelfFromInst(inst);
    try checkOpen(interp, s);
    return Value{ .small_int = @intCast(s.data.count()) };
}

fn shelfIter(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const s = shelfFromInst(inst);
    try checkOpen(interp, s);
    const l = try List.init(interp.allocator);
    for (s.data.pairs.items) |pair| {
        if (pair.key == .str) try l.append(interp.allocator, pair.key);
    }
    return Value{ .iter = try Iter.init(interp.allocator, .{ .list = l }) };
}

fn shelfEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return error.TypeError;
    return args[0];
}

fn shelfExit(p: *anyopaque, args: []const Value) anyerror!Value {
    return shelfClose(p, args);
}

fn shelfKeys(p: *anyopaque, args: []const Value) anyerror!Value {
    return shelfIter(p, args);
}

fn shelfValues(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const s = shelfFromInst(inst);
    try checkOpen(interp, s);
    const l = try List.init(interp.allocator);
    for (s.data.pairs.items) |pair| {
        try l.append(interp.allocator, pair.value);
    }
    return Value{ .list = l };
}

fn shelfItems(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const s = shelfFromInst(inst);
    try checkOpen(interp, s);
    const a = interp.allocator;
    const l = try List.init(a);
    for (s.data.pairs.items) |pair| {
        if (pair.key != .str) continue;
        const t = try Tuple.init(a, 2);
        t.items[0] = pair.key;
        t.items[1] = pair.value;
        try l.append(a, Value{ .tuple = t });
    }
    return Value{ .list = l };
}

fn shelfGetMethod(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const s = shelfFromInst(inst);
    try checkOpen(interp, s);
    if (args.len < 2 or args[1] != .str) return Value.none;
    const key = args[1].str.bytes;
    if (s.data.getStr(key)) |v| return v;
    if (args.len >= 3) return args[2];
    return Value.none;
}

fn shelfPop(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const s = shelfFromInst(inst);
    try checkOpen(interp, s);
    if (args.len < 2 or args[1] != .str) {
        try interp.raisePy("TypeError", "shelf.pop key must be str");
        return error.PyException;
    }
    const key = args[1].str.bytes;
    if (s.data.getStr(key)) |v| {
        _ = s.data.delete(key);
        return v;
    }
    if (args.len >= 3) return args[2];
    try interp.raisePy("KeyError", key);
    return error.PyException;
}

fn shelfSetdefault(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const s = shelfFromInst(inst);
    try checkOpen(interp, s);
    if (args.len < 2 or args[1] != .str) {
        try interp.raisePy("TypeError", "shelf.setdefault key must be str");
        return error.PyException;
    }
    const key = args[1].str.bytes;
    if (s.data.getStr(key)) |v| return v;
    const dflt = if (args.len >= 3) args[2] else Value.none;
    try s.data.setStr(interp.allocator, key, dflt);
    return dflt;
}

fn shelfUpdate(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const s = shelfFromInst(inst);
    try checkOpen(interp, s);
    if (args.len >= 2 and args[1] == .dict) {
        const d = args[1].dict;
        for (d.pairs.items) |pair| {
            if (pair.key != .str) continue;
            try s.data.setStr(interp.allocator, pair.key.str.bytes, pair.value);
        }
    }
    return Value.none;
}

fn shelfSync(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const s = shelfFromInst(inst);
    if (s.closed) return Value.none;
    try saveToFile(interp, s.path, s.data);
    return Value.none;
}

fn shelfClose(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const s = shelfFromInst(inst);
    if (!s.closed) {
        try saveToFile(interp, s.path, s.data);
        s.closed = true;
    }
    return Value.none;
}
