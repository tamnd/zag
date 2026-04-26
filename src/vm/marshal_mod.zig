//! Pinhole `marshal`. Private binary format (ZMSH magic + type-tagged records).
//! Supports None, bool, int (arbitrary precision), float, complex,
//! str, bytes, tuple, list, dict, set, frozenset, Ellipsis.
//! All version arguments are accepted but produce the same encoding.

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
const Set = @import("../object/set.zig").Set;
const BigInt = @import("../object/bigint.zig").BigInt;
const Interp = @import("interp.zig").Interp;
const dunder = @import("dunder.zig");

// Type tags
const T_NONE: u8 = 'N';
const T_ELLIPSIS: u8 = '.';
const T_TRUE: u8 = 'T';
const T_FALSE: u8 = 'F';
const T_INT: u8 = 'i'; // i64 LE
const T_BIGINT: u8 = 'I'; // u32 len + decimal string
const T_FLOAT: u8 = 'f'; // f64 LE
const T_COMPLEX: u8 = 'x'; // f64 re + f64 im
const T_STR: u8 = 's'; // u32 len + utf8
const T_BYTES: u8 = 'b'; // u32 len + bytes
const T_TUPLE: u8 = 't'; // u32 len + items
const T_LIST: u8 = 'l'; // u32 len + items
const T_DICT: u8 = 'D'; // u32 pair_count + key/value pairs
const T_SET: u8 = 'S'; // u32 len + items
const T_FROZENSET: u8 = 'Z'; // u32 len + items

// ===== Writer =====

const Writer = struct {
    a: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *Writer) void {
        self.buf.deinit(self.a);
    }

    fn putByte(self: *Writer, b: u8) !void {
        try self.buf.append(self.a, b);
    }

    fn putBytes(self: *Writer, data: []const u8) !void {
        try self.buf.appendSlice(self.a, data);
    }

    fn putU32(self: *Writer, v: u32) !void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, v, .little);
        try self.putBytes(&tmp);
    }

    fn putI64(self: *Writer, v: i64) !void {
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(i64, &tmp, v, .little);
        try self.putBytes(&tmp);
    }

    fn putF64(self: *Writer, v: f64) !void {
        const bits: u64 = @bitCast(v);
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(u64, &tmp, bits, .little);
        try self.putBytes(&tmp);
    }
};

// ===== Reader =====

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn need(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return error.MarshalEOF;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn getByte(self: *Reader) !u8 {
        const s = try self.need(1);
        return s[0];
    }

    fn getU32(self: *Reader) !u32 {
        const s = try self.need(4);
        return std.mem.readInt(u32, s[0..4], .little);
    }

    fn getI64(self: *Reader) !i64 {
        const s = try self.need(8);
        return std.mem.readInt(i64, s[0..8], .little);
    }

    fn getF64(self: *Reader) !f64 {
        const s = try self.need(8);
        const bits = std.mem.readInt(u64, s[0..8], .little);
        return @bitCast(bits);
    }
};

// ===== Encode =====

fn encodeValue(a: std.mem.Allocator, w: *Writer, v: Value) !void {
    switch (v) {
        .none => try w.putByte(T_NONE),
        .ellipsis => try w.putByte(T_ELLIPSIS),
        .boolean => |b| try w.putByte(if (b) T_TRUE else T_FALSE),
        .small_int => |n| {
            try w.putByte(T_INT);
            try w.putI64(n);
        },
        .big_int => |bi| {
            const s = try bi.toString10(a);
            defer a.free(s);
            try w.putByte(T_BIGINT);
            try w.putU32(@intCast(s.len));
            try w.putBytes(s);
        },
        .float => |f| {
            try w.putByte(T_FLOAT);
            try w.putF64(f);
        },
        .complex_num => |c| {
            try w.putByte(T_COMPLEX);
            try w.putF64(c.re);
            try w.putF64(c.im);
        },
        .str => |s| {
            try w.putByte(T_STR);
            try w.putU32(@intCast(s.bytes.len));
            try w.putBytes(s.bytes);
        },
        .bytes => |b| {
            try w.putByte(T_BYTES);
            try w.putU32(@intCast(b.data.len));
            try w.putBytes(b.data);
        },
        .bytearray => |b| {
            try w.putByte(T_BYTES);
            try w.putU32(@intCast(b.data.items.len));
            try w.putBytes(b.data.items);
        },
        .tuple => |t| {
            try w.putByte(T_TUPLE);
            try w.putU32(@intCast(t.items.len));
            for (t.items) |x| try encodeValue(a, w, x);
        },
        .list => |l| {
            try w.putByte(T_LIST);
            try w.putU32(@intCast(l.items.items.len));
            for (l.items.items) |x| try encodeValue(a, w, x);
        },
        .dict => |d| {
            try w.putByte(T_DICT);
            try w.putU32(@intCast(d.pairs.items.len));
            for (d.pairs.items) |pair| {
                try encodeValue(a, w, pair.key);
                try encodeValue(a, w, pair.value);
            }
        },
        .set => |s| {
            try w.putByte(if (s.frozen) T_FROZENSET else T_SET);
            try w.putU32(@intCast(s.items.items.len));
            for (s.items.items) |x| try encodeValue(a, w, x);
        },
        else => return error.MarshalUnsupported,
    }
}

// ===== Decode =====

fn decodeValue(interp: *Interp, r: *Reader) !Value {
    const a = interp.allocator;
    const tag = try r.getByte();
    switch (tag) {
        T_NONE => return Value.none,
        T_ELLIPSIS => return Value{ .ellipsis = {} },
        T_TRUE => return Value{ .boolean = true },
        T_FALSE => return Value{ .boolean = false },
        T_INT => {
            const n = try r.getI64();
            return Value{ .small_int = n };
        },
        T_BIGINT => {
            const len = try r.getU32();
            const s = try r.need(len);
            var m: std.math.big.int.Managed = try .init(a);
            try m.setString(10, s);
            const bi = try BigInt.fromManaged(a, m);
            return Value{ .big_int = bi };
        },
        T_FLOAT => {
            const f = try r.getF64();
            return Value{ .float = f };
        },
        T_COMPLEX => {
            const re = try r.getF64();
            const im = try r.getF64();
            return Value{ .complex_num = .{ .re = re, .im = im } };
        },
        T_STR => {
            const len = try r.getU32();
            const bytes_slice = try r.need(len);
            const s = try Str.init(a, bytes_slice);
            return Value{ .str = s };
        },
        T_BYTES => {
            const len = try r.getU32();
            const bytes_slice = try r.need(len);
            const b = try Bytes.init(a, bytes_slice);
            return Value{ .bytes = b };
        },
        T_TUPLE => {
            const n = try r.getU32();
            const t = try Tuple.init(a, n);
            var i: u32 = 0;
            while (i < n) : (i += 1) t.items[i] = try decodeValue(interp, r);
            return Value{ .tuple = t };
        },
        T_LIST => {
            const n = try r.getU32();
            const l = try List.init(a);
            var i: u32 = 0;
            while (i < n) : (i += 1) try l.append(a, try decodeValue(interp, r));
            return Value{ .list = l };
        },
        T_DICT => {
            const n = try r.getU32();
            const d = try Dict.init(a);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const k = try decodeValue(interp, r);
                const val = try decodeValue(interp, r);
                if (k == .str) {
                    try d.setStr(a, k.str.bytes, val);
                } else {
                    try d.pairs.append(a, .{ .key = k, .value = val });
                }
            }
            return Value{ .dict = d };
        },
        T_SET => {
            const n = try r.getU32();
            const s = try Set.init(a);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const x = try decodeValue(interp, r);
                try s.add(a, x);
            }
            return Value{ .set = s };
        },
        T_FROZENSET => {
            const n = try r.getU32();
            const s = try Set.initFrozen(a);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const x = try decodeValue(interp, r);
                try s.add(a, x);
            }
            return Value{ .set = s };
        },
        else => return error.MarshalBadTag,
    }
}

// ===== Module =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "marshal");
    try m.attrs.setStr(a, "version", Value{ .small_int = 4 });

    const reg = struct {
        fn r(aa: std.mem.Allocator, mm: *Module, name: []const u8, func: BuiltinFnPtr, kw_func: ?BuiltinKwFnPtr) !void {
            const f = try aa.create(BuiltinFn);
            f.* = .{ .name = name, .func = func, .kw_func = kw_func };
            try mm.attrs.setStr(aa, name, Value{ .builtin_fn = f });
        }
    }.r;

    try reg(a, m, "dumps", dumpsFn, dumpsKw);
    try reg(a, m, "loads", loadsFn, null);
    try reg(a, m, "dump", dumpFn, dumpKw);
    try reg(a, m, "load", loadFn, null);
    return m;
}

// ===== dumps =====

fn dumpsImpl(interp: *Interp, args: []const Value) !Value {
    if (args.len < 1) {
        try interp.raisePy("TypeError", "dumps requires at least 1 argument");
        return error.PyException;
    }
    const a = interp.allocator;
    var w: Writer = .{ .a = a };
    defer w.deinit();
    encodeValue(a, &w, args[0]) catch |err| switch (err) {
        error.MarshalUnsupported => {
            try interp.raisePy("ValueError", "unmarshallable object");
            return error.PyException;
        },
        else => return err,
    };
    const b = try Bytes.init(a, w.buf.items);
    return Value{ .bytes = b };
}

fn dumpsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return dumpsImpl(interp, args);
}

fn dumpsKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_vals: []const Value) anyerror!Value {
    _ = kw_names;
    _ = kw_vals;
    const interp: *Interp = @ptrCast(@alignCast(p));
    return dumpsImpl(interp, args);
}

// ===== loads =====

fn loadsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) {
        try interp.raisePy("TypeError", "loads requires 1 argument");
        return error.PyException;
    }
    const data: []const u8 = switch (args[0]) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        else => {
            try interp.raisePy("TypeError", "loads argument must be bytes-like");
            return error.PyException;
        },
    };
    if (data.len == 0) {
        try interp.raisePy("EOFError", "EOF read where object expected");
        return error.PyException;
    }
    var r: Reader = .{ .data = data };
    return decodeValue(interp, &r) catch |err| switch (err) {
        error.MarshalEOF => {
            try interp.raisePy("EOFError", "EOF read where object expected");
            return error.PyException;
        },
        error.MarshalBadTag => {
            try interp.raisePy("ValueError", "bad marshal data");
            return error.PyException;
        },
        else => return err,
    };
}

// ===== dump =====

fn dumpImpl(interp: *Interp, args: []const Value) !Value {
    if (args.len < 2) {
        try interp.raisePy("TypeError", "dump requires (value, file)");
        return error.PyException;
    }
    const a = interp.allocator;
    var w: Writer = .{ .a = a };
    defer w.deinit();
    encodeValue(a, &w, args[0]) catch |err| switch (err) {
        error.MarshalUnsupported => {
            try interp.raisePy("ValueError", "unmarshallable object");
            return error.PyException;
        },
        else => return err,
    };
    const b = try Bytes.init(a, w.buf.items);
    _ = try dunder.call(interp, args[1], "write", &.{Value{ .bytes = b }});
    return Value.none;
}

fn dumpFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return dumpImpl(interp, args);
}

fn dumpKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_vals: []const Value) anyerror!Value {
    _ = kw_names;
    _ = kw_vals;
    const interp: *Interp = @ptrCast(@alignCast(p));
    return dumpImpl(interp, args);
}

// ===== load =====

fn loadFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) {
        try interp.raisePy("TypeError", "load requires 1 argument");
        return error.PyException;
    }
    const read_result = try dunder.call(interp, args[0], "read", &.{});
    const data: []const u8 = if (read_result) |rv| switch (rv) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        else => {
            try interp.raisePy("TypeError", "file.read() must return bytes");
            return error.PyException;
        },
    } else {
        try interp.raisePy("EOFError", "EOF read where object expected");
        return error.PyException;
    };
    if (data.len == 0) {
        try interp.raisePy("EOFError", "EOF read where object expected");
        return error.PyException;
    }
    var r: Reader = .{ .data = data };
    return decodeValue(interp, &r) catch |err| switch (err) {
        error.MarshalEOF => {
            try interp.raisePy("EOFError", "EOF read where object expected");
            return error.PyException;
        },
        error.MarshalBadTag => {
            try interp.raisePy("ValueError", "bad marshal data");
            return error.PyException;
        },
        else => return err,
    };
}
