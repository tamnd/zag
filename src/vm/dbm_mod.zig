//! Pinhole `dbm` and `dbm.sqlite3`. Uses a private binary format (ZDBM
//! magic + fixed-size records). Keys and values are both raw bytes.
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
const Str = @import("../object/string.zig").Str;
const Bytes = @import("../object/bytes.zig").Bytes;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

const MAGIC = "ZDBM";

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "dbm");

    if (interp.dbm_class == null) try buildDbmClass(interp);

    try regFn(a, m, "open", dbmOpenFn, dbmOpenKw);
    try regFn(a, m, "whichdb", whichdbFn, null);

    // dbm.error is a tuple containing OSError
    const exc_t = try Tuple.init(a, 1);
    exc_t.items[0] = Value{ .small_int = 0 }; // placeholder
    try m.attrs.setStr(a, "error", Value{ .tuple = exc_t });

    // dbm.sqlite3 submodule (same backend)
    const sq = try Module.init(a, "dbm.sqlite3");
    try regFn(a, sq, "open", dbmOpenFn, dbmOpenKw);
    const sq_exc = try Tuple.init(a, 1);
    sq_exc.items[0] = Value{ .small_int = 0 };
    try sq.attrs.setStr(a, "error", Value{ .tuple = sq_exc });
    try m.attrs.setStr(a, "sqlite3", Value{ .module = sq });

    interp.dbm_module = m;
    return m;
}

fn regFn(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr, kw_func: ?BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

// ===== Db state =====

const Db = struct {
    path: []u8,
    // In-memory store: keys are []u8, values are []u8
    pairs: std.ArrayListUnmanaged(Pair),
    flag: u8, // 'c' 'n' 'r' 'w'
    closed: bool,

    const Pair = struct {
        key: []u8,
        val: []u8,
    };
};

fn newDb(a: std.mem.Allocator, path: []const u8, flag: u8) !*Db {
    const db = try a.create(Db);
    db.* = .{
        .path = try a.dupe(u8, path),
        .pairs = .empty,
        .flag = flag,
        .closed = false,
    };
    return db;
}

fn dbFromInst(inst: *Instance) *Db {
    const v = inst.dict.getStr("_db").?;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn argInst(args: []const Value) !*Instance {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    return args[0].instance;
}

// Convert str or bytes arg to raw bytes (caller borrows)
fn toKeyBytes(v: Value) ?[]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        else => null,
    };
}

fn toValBytes(v: Value) ?[]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        else => null,
    };
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

fn loadFromFile(interp: *Interp, db: *Db) !void {
    const a = interp.allocator;
    const contents = try readFileAlloc(interp, db.path);
    defer a.free(contents);
    if (contents.len < MAGIC.len or !std.mem.eql(u8, contents[0..MAGIC.len], MAGIC)) return;

    var pos: usize = MAGIC.len;
    while (pos + 4 <= contents.len) {
        const klen = std.mem.readInt(u32, contents[pos..][0..4], .little);
        pos += 4;
        if (klen == 0) break;
        if (pos + klen + 4 > contents.len) break;
        const key = contents[pos .. pos + klen];
        pos += klen;
        const vlen = std.mem.readInt(u32, contents[pos..][0..4], .little);
        pos += 4;
        if (pos + vlen > contents.len) break;
        const val = contents[pos .. pos + vlen];
        pos += vlen;

        // Check if key already exists; if so, update
        var found = false;
        for (db.pairs.items) |*p| {
            if (std.mem.eql(u8, p.key, key)) {
                a.free(p.val);
                p.val = try a.dupe(u8, val);
                found = true;
                break;
            }
        }
        if (!found) {
            try db.pairs.append(a, .{
                .key = try a.dupe(u8, key),
                .val = try a.dupe(u8, val),
            });
        }
    }
}

fn saveToFile(interp: *Interp, db: *Db) !void {
    const a = interp.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, MAGIC);

    for (db.pairs.items) |pair| {
        var klen: [4]u8 = undefined;
        var vlen: [4]u8 = undefined;
        std.mem.writeInt(u32, &klen, @intCast(pair.key.len), .little);
        std.mem.writeInt(u32, &vlen, @intCast(pair.val.len), .little);
        try buf.appendSlice(a, &klen);
        try buf.appendSlice(a, pair.key);
        try buf.appendSlice(a, &vlen);
        try buf.appendSlice(a, pair.val);
    }
    try buf.appendSlice(a, &[_]u8{ 0, 0, 0, 0 });
    try writeFileBytes(interp, db.path, buf.items);
}

fn dbGet(db: *Db, key: []const u8) ?[]const u8 {
    for (db.pairs.items) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.val;
    }
    return null;
}

fn dbSet(a: std.mem.Allocator, db: *Db, key: []const u8, val: []const u8) !void {
    for (db.pairs.items) |*p| {
        if (std.mem.eql(u8, p.key, key)) {
            a.free(p.val);
            p.val = try a.dupe(u8, val);
            return;
        }
    }
    try db.pairs.append(a, .{
        .key = try a.dupe(u8, key),
        .val = try a.dupe(u8, val),
    });
}

fn dbDel(a: std.mem.Allocator, db: *Db, key: []const u8) bool {
    for (db.pairs.items, 0..) |p, i| {
        if (std.mem.eql(u8, p.key, key)) {
            a.free(p.key);
            a.free(p.val);
            _ = db.pairs.swapRemove(i);
            return true;
        }
    }
    return false;
}

// ===== Class =====

fn buildDbmClass(interp: *Interp) !void {
    const a = interp.allocator;
    const d = try Dict.init(a);
    const reg = struct {
        fn r(aa: std.mem.Allocator, dd: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
            const f = try aa.create(BuiltinFn);
            f.* = .{ .name = name, .func = func };
            try dd.setStr(aa, name, Value{ .builtin_fn = f });
        }
    }.r;
    try reg(a, d, "__getitem__", dbGetItem);
    try reg(a, d, "__setitem__", dbSetItem);
    try reg(a, d, "__delitem__", dbDelItem);
    try reg(a, d, "__contains__", dbContains);
    try reg(a, d, "__enter__", dbEnter);
    try reg(a, d, "__exit__", dbExit);
    try reg(a, d, "keys", dbKeys);
    try reg(a, d, "get", dbGetMethod);
    try reg(a, d, "setdefault", dbSetdefault);
    try reg(a, d, "clear", dbClear);
    try reg(a, d, "close", dbClose);
    interp.dbm_class = try Class.init(a, "dbm", &.{}, d);
}

fn checkOpen(interp: *Interp, db: *Db) !void {
    if (db.closed) {
        try interp.raisePy("ValueError", "I/O operation on closed database");
        return error.PyException;
    }
}

fn dbGetItem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const db = dbFromInst(inst);
    try checkOpen(interp, db);
    if (args.len < 2) {
        try interp.raisePy("TypeError", "dbm key required");
        return error.PyException;
    }
    const key = toKeyBytes(args[1]) orelse {
        try interp.raisePy("TypeError", "dbm key must be str or bytes");
        return error.PyException;
    };
    if (dbGet(db, key)) |val| {
        const b = try Bytes.init(interp.allocator, val);
        return Value{ .bytes = b };
    }
    try interp.raisePy("KeyError", key);
    return error.PyException;
}

fn dbSetItem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const db = dbFromInst(inst);
    try checkOpen(interp, db);
    if (db.flag == 'r') {
        try interp.raisePy("ValueError", "database is read-only");
        return error.PyException;
    }
    if (args.len < 3) {
        try interp.raisePy("TypeError", "dbm set requires key and value");
        return error.PyException;
    }
    const key = toKeyBytes(args[1]) orelse {
        try interp.raisePy("TypeError", "dbm key must be str or bytes");
        return error.PyException;
    };
    const val = toValBytes(args[2]) orelse {
        try interp.raisePy("TypeError", "dbm value must be str or bytes");
        return error.PyException;
    };
    try dbSet(interp.allocator, db, key, val);
    return Value.none;
}

fn dbDelItem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const db = dbFromInst(inst);
    try checkOpen(interp, db);
    if (args.len < 2) {
        try interp.raisePy("TypeError", "dbm del requires key");
        return error.PyException;
    }
    const key = toKeyBytes(args[1]) orelse {
        try interp.raisePy("TypeError", "dbm key must be str or bytes");
        return error.PyException;
    };
    if (!dbDel(interp.allocator, db, key)) {
        try interp.raisePy("KeyError", key);
        return error.PyException;
    }
    return Value.none;
}

fn dbContains(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const db = dbFromInst(inst);
    try checkOpen(interp, db);
    if (args.len < 2) return Value{ .boolean = false };
    const key = toKeyBytes(args[1]) orelse return Value{ .boolean = false };
    return Value{ .boolean = dbGet(db, key) != null };
}

fn dbEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1) return error.TypeError;
    return args[0];
}

fn dbExit(p: *anyopaque, args: []const Value) anyerror!Value {
    return dbClose(p, args);
}

fn dbKeys(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const db = dbFromInst(inst);
    try checkOpen(interp, db);
    const l = try List.init(interp.allocator);
    for (db.pairs.items) |pair| {
        const b = try Bytes.init(interp.allocator, pair.key);
        try l.append(interp.allocator, Value{ .bytes = b });
    }
    return Value{ .list = l };
}

fn dbGetMethod(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const db = dbFromInst(inst);
    try checkOpen(interp, db);
    if (args.len < 2) return Value.none;
    const key = toKeyBytes(args[1]) orelse return Value.none;
    if (dbGet(db, key)) |val| {
        const b = try Bytes.init(interp.allocator, val);
        return Value{ .bytes = b };
    }
    if (args.len >= 3) return args[2];
    return Value.none;
}

fn dbSetdefault(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const db = dbFromInst(inst);
    try checkOpen(interp, db);
    if (args.len < 2) {
        try interp.raisePy("TypeError", "setdefault requires key");
        return error.PyException;
    }
    const key = toKeyBytes(args[1]) orelse {
        try interp.raisePy("TypeError", "dbm key must be str or bytes");
        return error.PyException;
    };
    if (dbGet(db, key)) |val| {
        const b = try Bytes.init(interp.allocator, val);
        return Value{ .bytes = b };
    }
    const default_val: []const u8 = if (args.len >= 3) (toValBytes(args[2]) orelse &.{}) else &.{};
    try dbSet(interp.allocator, db, key, default_val);
    const b = try Bytes.init(interp.allocator, default_val);
    return Value{ .bytes = b };
}

fn dbClear(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const db = dbFromInst(inst);
    try checkOpen(interp, db);
    const a = interp.allocator;
    for (db.pairs.items) |pair| {
        a.free(pair.key);
        a.free(pair.val);
    }
    db.pairs.clearRetainingCapacity();
    return Value.none;
}

fn dbClose(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const inst = try argInst(args);
    const db = dbFromInst(inst);
    if (!db.closed) {
        if (db.flag != 'r') try saveToFile(interp, db);
        db.closed = true;
    }
    return Value.none;
}

// ===== open =====

fn openImpl(interp: *Interp, args: []const Value, kw_names: []const Value, kw_vals: []const Value) !Value {
    const a = interp.allocator;
    try ensureDbmClass(interp);

    if (args.len < 1) {
        try interp.raisePy("TypeError", "dbm.open requires path");
        return error.PyException;
    }
    const path = toKeyBytes(args[0]) orelse {
        try interp.raisePy("TypeError", "path must be str");
        return error.PyException;
    };

    var flag: u8 = 'r';
    if (args.len >= 2) {
        if (toKeyBytes(args[1])) |fs| {
            if (fs.len > 0) flag = fs[0];
        }
    }
    for (kw_names, kw_vals) |kn, v| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "flag")) {
            if (toKeyBytes(v)) |fs| {
                if (fs.len > 0) flag = fs[0];
            }
        }
    }

    const db = try newDb(a, path, flag);

    if (flag != 'n') {
        loadFromFile(interp, db) catch {};
    }

    const inst = try Instance.init(a, interp.dbm_class.?);
    try inst.dict.setStr(a, "_db", Value{ .small_int = @intCast(@intFromPtr(db)) });
    return Value{ .instance = inst };
}

fn dbmOpenFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return openImpl(interp, args, &.{}, &.{});
}

fn dbmOpenKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_vals: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return openImpl(interp, args, kw_names, kw_vals);
}

fn ensureDbmClass(interp: *Interp) !void {
    if (interp.dbm_class == null) try buildDbmClass(interp);
}

// ===== whichdb =====

fn whichdbFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return Value.none;
    const path = toKeyBytes(args[0]) orelse return Value.none;

    // Check if file exists
    const file = std.Io.Dir.cwd().openFile(interp.io, path, .{}) catch {
        return Value.none;
    };
    // Read magic
    var read_buf: [8]u8 = undefined;
    var reader = file.reader(interp.io, &read_buf);
    var magic_buf: [4]u8 = undefined;
    const got = reader.interface.readSliceShort(magic_buf[0..]) catch {
        file.close(interp.io);
        const s = try Str.init(interp.allocator, "");
        return Value{ .str = s };
    };
    file.close(interp.io);

    if (got >= 4 and std.mem.eql(u8, magic_buf[0..4], MAGIC)) {
        const s = try Str.init(interp.allocator, "dbm.sqlite3");
        return Value{ .str = s };
    }
    const s = try Str.init(interp.allocator, "");
    return Value{ .str = s };
}
