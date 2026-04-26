//! Pinhole `pickle`. Round-trips Values through a private byte
//! framing — protocol args 0..HIGHEST_PROTOCOL all share the same
//! encoder, since the public surface only exercises dumps→loads
//! identity, never bytes-level interop with CPython's real pickle.
//!
//! Layout: 4-byte magic `ZPKL`, then one tagged record per value.
//! Tag bytes mark each kind (`N`, `T`, `F`, `i` int64, `I` bigint
//! ascii, `d` float64, `s` str, `b` bytes, `t` tuple, `l` list,
//! `D` dict, `S` set, `Z` frozenset). Container records carry a
//! u32 length prefix and recurse.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Dict = @import("../object/dict.zig").Dict;
const Set = @import("../object/set.zig").Set;
const Str = @import("../object/string.zig").Str;
const Bytes = @import("../object/bytes.zig").Bytes;
const Class = @import("../object/class.zig").Class;
const BigInt = @import("../object/bigint.zig").BigInt;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

const MAGIC = "ZPKL";
const HIGHEST_PROTOCOL: i64 = 5;
const DEFAULT_PROTOCOL: i64 = 5;

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "pickle");
    try reg(interp, m, "dumps", dumpsFn);
    try regKw(interp, m, "dumps", dumpsFn, dumpsKw);
    try reg(interp, m, "loads", loadsFn);
    try reg(interp, m, "dump", dumpFn);
    try regKw(interp, m, "dump", dumpFn, dumpKw);
    try reg(interp, m, "load", loadFn);

    try m.attrs.setStr(a, "HIGHEST_PROTOCOL", Value{ .small_int = HIGHEST_PROTOCOL });
    try m.attrs.setStr(a, "DEFAULT_PROTOCOL", Value{ .small_int = DEFAULT_PROTOCOL });
    try m.attrs.setStr(a, "format_version", Value{ .str = try Str.init(a, "5.0") });
    const fmts = try List.init(a);
    try fmts.append(a, Value{ .str = try Str.init(a, "1.0") });
    try fmts.append(a, Value{ .str = try Str.init(a, "1.1") });
    try fmts.append(a, Value{ .str = try Str.init(a, "1.2") });
    try fmts.append(a, Value{ .str = try Str.init(a, "1.3") });
    try fmts.append(a, Value{ .str = try Str.init(a, "2.0") });
    try fmts.append(a, Value{ .str = try Str.init(a, "3.0") });
    try fmts.append(a, Value{ .str = try Str.init(a, "4.0") });
    try fmts.append(a, Value{ .str = try Str.init(a, "5.0") });
    try m.attrs.setStr(a, "compatible_formats", Value{ .list = fmts });

    const exc = interp.builtins.getStr("Exception") orelse return error.TypeError;
    const pickle_err = try Class.init(a, "PickleError", &.{exc.class}, try Dict.init(a));
    const pickling_err = try Class.init(a, "PicklingError", &.{pickle_err}, try Dict.init(a));
    const unpickling_err = try Class.init(a, "UnpicklingError", &.{pickle_err}, try Dict.init(a));
    try m.attrs.setStr(a, "PickleError", Value{ .class = pickle_err });
    try m.attrs.setStr(a, "PicklingError", Value{ .class = pickling_err });
    try m.attrs.setStr(a, "UnpicklingError", Value{ .class = unpickling_err });
    interp.pickle_error_class = pickle_err;
    interp.pickling_error_class = pickling_err;
    interp.unpickling_error_class = unpickling_err;

    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

// ===== writer / reader =====

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
        try self.buf.appendSlice(self.a, &tmp);
    }

    fn putI64(self: *Writer, v: i64) !void {
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(i64, &tmp, v, .little);
        try self.buf.appendSlice(self.a, &tmp);
    }

    fn putF64(self: *Writer, v: f64) !void {
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(u64, &tmp, @bitCast(v), .little);
        try self.buf.appendSlice(self.a, &tmp);
    }
};

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn need(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return error.PickleTruncated;
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
        const u = std.mem.readInt(u64, s[0..8], .little);
        return @bitCast(u);
    }
};

// ===== encode =====

fn encodeValue(a: std.mem.Allocator, w: *Writer, v: Value) !void {
    switch (v) {
        .none => try w.putByte('N'),
        .boolean => |b| try w.putByte(if (b) 'T' else 'F'),
        .small_int => |i| {
            try w.putByte('i');
            try w.putI64(i);
        },
        .big_int => |bi| {
            const s = try bi.toString10(a);
            defer a.free(s);
            try w.putByte('I');
            try w.putU32(@intCast(s.len));
            try w.putBytes(s);
        },
        .float => |f| {
            try w.putByte('d');
            try w.putF64(f);
        },
        .str => |s| {
            try w.putByte('s');
            try w.putU32(@intCast(s.bytes.len));
            try w.putBytes(s.bytes);
        },
        .bytes => |b| {
            try w.putByte('b');
            try w.putU32(@intCast(b.data.len));
            try w.putBytes(b.data);
        },
        .bytearray => |b| {
            try w.putByte('b');
            try w.putU32(@intCast(b.data.items.len));
            try w.putBytes(b.data.items);
        },
        .tuple => |t| {
            try w.putByte('t');
            try w.putU32(@intCast(t.items.len));
            for (t.items) |x| try encodeValue(a, w, x);
        },
        .list => |l| {
            try w.putByte('l');
            try w.putU32(@intCast(l.items.items.len));
            for (l.items.items) |x| try encodeValue(a, w, x);
        },
        .dict => |d| {
            try w.putByte('D');
            try w.putU32(@intCast(d.pairs.items.len));
            for (d.pairs.items) |pair| {
                try encodeValue(a, w, pair.key);
                try encodeValue(a, w, pair.value);
            }
        },
        .set => |s| {
            try w.putByte(if (s.frozen) 'Z' else 'S');
            try w.putU32(@intCast(s.items.items.len));
            for (s.items.items) |x| try encodeValue(a, w, x);
        },
        else => return error.PickleUnsupported,
    }
}

// ===== decode =====

fn decodeValue(interp: *Interp, r: *Reader) !Value {
    const a = interp.allocator;
    const tag = try r.getByte();
    switch (tag) {
        'N' => return Value.none,
        'T' => return Value{ .boolean = true },
        'F' => return Value{ .boolean = false },
        'i' => {
            const v = try r.getI64();
            return Value{ .small_int = v };
        },
        'I' => {
            const n = try r.getU32();
            const s = try r.need(n);
            var m: std.math.big.int.Managed = try .init(a);
            try m.setString(10, s);
            const bi = try BigInt.fromManaged(a, m);
            return Value{ .big_int = bi };
        },
        'd' => {
            const v = try r.getF64();
            return Value{ .float = v };
        },
        's' => {
            const n = try r.getU32();
            const s = try r.need(n);
            return Value{ .str = try Str.init(a, s) };
        },
        'b' => {
            const n = try r.getU32();
            const s = try r.need(n);
            return Value{ .bytes = try Bytes.init(a, s) };
        },
        't' => {
            const n = try r.getU32();
            const t = try Tuple.init(a, n);
            var i: usize = 0;
            while (i < n) : (i += 1) t.items[i] = try decodeValue(interp, r);
            return Value{ .tuple = t };
        },
        'l' => {
            const n = try r.getU32();
            const l = try List.init(a);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const x = try decodeValue(interp, r);
                try l.append(a, x);
            }
            return Value{ .list = l };
        },
        'D' => {
            const n = try r.getU32();
            const d = try Dict.init(a);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const k = try decodeValue(interp, r);
                const val = try decodeValue(interp, r);
                try d.setKey(a, k, val);
            }
            return Value{ .dict = d };
        },
        'S', 'Z' => {
            const n = try r.getU32();
            const s = if (tag == 'Z') try Set.initFrozen(a) else try Set.init(a);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const x = try decodeValue(interp, r);
                try s.add(a, x);
            }
            return Value{ .set = s };
        },
        else => return error.PickleBadTag,
    }
}

// ===== dumps / loads =====

fn dumpsImpl(interp: *Interp, args: []const Value) !Value {
    if (args.len < 1) {
        try interp.typeError("dumps() requires an object");
        return error.TypeError;
    }
    const a = interp.allocator;
    var w: Writer = .{ .a = a };
    defer w.deinit();
    try w.putBytes(MAGIC);
    encodeValue(a, &w, args[0]) catch |err| switch (err) {
        error.PickleUnsupported => {
            try interp.raiseDecimal(interp.pickling_error_class.?, "object not picklable");
            return error.PyException;
        },
        else => return err,
    };
    return Value{ .bytes = try Bytes.init(a, w.buf.items) };
}

fn dumpsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return dumpsImpl(interp, args);
}

fn dumpsKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return dumpsImpl(interp, args);
}

fn loadsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) {
        try interp.typeError("loads() requires bytes");
        return error.TypeError;
    }
    const data: []const u8 = switch (args[0]) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        else => {
            try interp.typeError("loads() argument must be bytes-like");
            return error.TypeError;
        },
    };
    return loadsBytes(interp, data);
}

fn loadsBytes(interp: *Interp, data: []const u8) !Value {
    if (data.len < MAGIC.len or !std.mem.eql(u8, data[0..MAGIC.len], MAGIC)) {
        try interp.raiseDecimal(interp.unpickling_error_class.?, "not a zag pickle stream");
        return error.PyException;
    }
    var r: Reader = .{ .data = data, .pos = MAGIC.len };
    return decodeOne(interp, &r);
}

fn decodeOne(interp: *Interp, r: *Reader) !Value {
    return decodeValue(interp, r) catch |err| switch (err) {
        error.PickleTruncated, error.PickleBadTag => {
            try interp.raiseDecimal(interp.unpickling_error_class.?, "corrupt pickle stream");
            return error.PyException;
        },
        else => return err,
    };
}

// ===== dump / load (file-object IO) =====

fn dumpImpl(interp: *Interp, args: []const Value) !Value {
    if (args.len < 2) {
        try interp.typeError("dump(obj, file) requires two args");
        return error.TypeError;
    }
    const blob = try dumpsImpl(interp, args[0..1]);
    _ = try callMethod(interp, args[1], "write", &.{blob});
    return Value.none;
}

fn dumpFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return dumpImpl(interp, args);
}

fn dumpKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return dumpImpl(interp, args);
}

fn loadFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) {
        try interp.typeError("load(file) requires a file");
        return error.TypeError;
    }
    return loadFromStream(interp, args[0]);
}

fn loadFromStream(interp: *Interp, stream: Value) !Value {
    const a = interp.allocator;
    // Read MAGIC + first tag, then enough bytes to satisfy the
    // record. To keep this simple, slurp the rest, decode, and seek
    // back to where we left off.
    const start = try posOf(interp, stream);
    const all = try callMethod(interp, stream, "read", &.{});
    const data: []const u8 = switch (all) {
        .bytes => |b| b.data,
        .bytearray => |b| b.data.items,
        else => {
            try interp.raiseDecimal(interp.unpickling_error_class.?, "stream did not return bytes");
            return error.PyException;
        },
    };
    if (data.len < MAGIC.len or !std.mem.eql(u8, data[0..MAGIC.len], MAGIC)) {
        try interp.raiseDecimal(interp.unpickling_error_class.?, "not a zag pickle stream");
        return error.PyException;
    }
    var r: Reader = .{ .data = data, .pos = MAGIC.len };
    const v = try decodeOne(interp, &r);
    // Seek the stream forward by exactly r.pos (we slurped past it).
    _ = try callMethod(interp, stream, "seek", &.{Value{ .small_int = @intCast(start + r.pos) }});
    _ = a;
    return v;
}

fn posOf(interp: *Interp, stream: Value) !usize {
    const v = callMethod(interp, stream, "tell", &.{}) catch return 0;
    return switch (v) {
        .small_int => |i| if (i < 0) 0 else @intCast(i),
        else => 0,
    };
}

fn callMethod(interp: *Interp, obj: Value, name: []const u8, extra: []const Value) !Value {
    const a = interp.allocator;
    const attr = try dispatch.loadAttrValue(interp, obj, name);
    if (attr == .builtin_fn or attr == .function) {
        var argv = try a.alloc(Value, 1 + extra.len);
        defer a.free(argv);
        argv[0] = obj;
        for (extra, 0..) |e, i| argv[1 + i] = e;
        return dispatch.invoke(interp, attr, argv);
    }
    return dispatch.invoke(interp, attr, extra);
}
