//! Decoder for CPython's marshal format, targeted at the subset
//! actually emitted by `python3.14 -m py_compile`. Complex types
//! (legacy ASCII float, complex) are handled for completeness.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;

const Str = @import("../object/string.zig").Str;
const Bytes = @import("../object/bytes.zig").Bytes;
const Tuple = @import("../object/tuple.zig").Tuple;
const List = @import("../object/list.zig").List;
const Dict = @import("../object/dict.zig").Dict;
const Code = @import("../object/code.zig").Code;
const Slice = @import("../object/slice.zig").Slice;

const FLAG_REF: u8 = 0x80;

const TypeByte = enum(u8) {
    none = 'N',
    false_ = 'F',
    true_ = 'T',
    stopiter = 'S',
    ellipsis = '.',
    null_ = '0',
    int32 = 'i',
    int64 = 'I',
    float_ascii = 'f',
    float_bin = 'g',
    complex_ascii = 'x',
    complex_bin = 'y',
    long_ = 'l',
    string = 's',
    interned = 't',
    ref = 'r',
    tuple = '(',
    list = '[',
    dict = '{',
    code = 'c',
    unicode = 'u',
    set = '<',
    frozenset = '>',
    ascii_ = 'a',
    ascii_interned = 'A',
    small_tuple = ')',
    short_ascii = 'z',
    short_ascii_interned = 'Z',
    slice = ':',
    _,
};

pub const Error = error{
    UnexpectedEof,
    UnknownTypeByte,
    BadRefIndex,
    CodeFieldMismatch,
    OutOfMemory,
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    buf: []const u8,
    pos: usize = 0,
    refs: std.ArrayList(Value),

    pub fn init(allocator: std.mem.Allocator, buf: []const u8) Reader {
        return .{
            .allocator = allocator,
            .buf = buf,
            .refs = .empty,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.refs.deinit(self.allocator);
    }

    fn need(self: *Reader, n: usize) !void {
        if (self.pos + n > self.buf.len) return error.UnexpectedEof;
    }

    fn readU8(self: *Reader) !u8 {
        try self.need(1);
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    fn readU32(self: *Reader) !u32 {
        try self.need(4);
        const v = std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    fn readI32(self: *Reader) !i32 {
        return @bitCast(try self.readU32());
    }

    fn readU64(self: *Reader) !u64 {
        try self.need(8);
        const v = std.mem.readInt(u64, self.buf[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    fn readBytes(self: *Reader, n: usize) ![]u8 {
        try self.need(n);
        const slice = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return self.allocator.dupe(u8, slice);
    }

    fn reserveRef(self: *Reader, have_flag: bool) !?usize {
        if (!have_flag) return null;
        try self.refs.append(self.allocator, Value.none);
        return self.refs.items.len - 1;
    }

    fn setRef(self: *Reader, idx: ?usize, v: Value) Value {
        if (idx) |i| self.refs.items[i] = v;
        return v;
    }

    /// Decode the next object. Returns `Value.null_sentinel` for the
    /// TYPE_NULL dict terminator so the dict reader can detect it
    /// without a separate sentinel path.
    pub fn readObject(self: *Reader) Error!Value {
        const raw = try self.readU8();
        const have_flag = (raw & FLAG_REF) != 0;
        const t: TypeByte = @enumFromInt(raw & 0x7f);

        switch (t) {
            .null_ => return Value.null_sentinel,
            .none => return Value.none,
            .true_ => return Value{ .boolean = true },
            .false_ => return Value{ .boolean = false },
            .ellipsis => return Value.none, // Ellipsis not modelled yet; treat as None for M1
            .stopiter => return Value.none, // same

            .int32 => {
                const v = try self.readI32();
                return self.setRef(try self.reserveRef(have_flag), Value{ .small_int = v });
            },
            .int64 => {
                const v: i64 = @bitCast(try self.readU64());
                return self.setRef(try self.reserveRef(have_flag), Value{ .small_int = v });
            },
            .long_ => return self.readLong(have_flag),
            .float_bin => {
                const bits = try self.readU64();
                const f: f64 = @bitCast(bits);
                return self.setRef(try self.reserveRef(have_flag), Value{ .float = f });
            },
            .float_ascii => {
                const n = try self.readU8();
                const raw_bytes = try self.readBytes(n);
                defer self.allocator.free(raw_bytes);
                const f = std.fmt.parseFloat(f64, raw_bytes) catch 0.0;
                return self.setRef(try self.reserveRef(have_flag), Value{ .float = f });
            },
            .complex_bin => {
                _ = try self.readU64(); // real
                _ = try self.readU64(); // imag
                return self.setRef(try self.reserveRef(have_flag), Value.none); // placeholder
            },
            .complex_ascii => {
                const nr = try self.readU8();
                self.pos += nr;
                const ni = try self.readU8();
                self.pos += ni;
                return self.setRef(try self.reserveRef(have_flag), Value.none);
            },

            .string => {
                const n = try self.readU32();
                const buf = try self.readBytes(n);
                const b = try Bytes.fromOwnedSlice(self.allocator, buf);
                return self.setRef(try self.reserveRef(have_flag), Value{ .bytes = b });
            },

            .unicode, .interned, .ascii_, .ascii_interned => {
                const n = try self.readU32();
                const buf = try self.readBytes(n);
                const s = try Str.fromOwnedSlice(self.allocator, buf);
                return self.setRef(try self.reserveRef(have_flag), Value{ .str = s });
            },

            .short_ascii, .short_ascii_interned => {
                const n = try self.readU8();
                const buf = try self.readBytes(n);
                const s = try Str.fromOwnedSlice(self.allocator, buf);
                return self.setRef(try self.reserveRef(have_flag), Value{ .str = s });
            },

            .small_tuple => {
                const n = try self.readU8();
                return self.readTuple(n, have_flag);
            },
            .tuple => {
                const n = try self.readU32();
                return self.readTuple(n, have_flag);
            },

            .list => {
                const n = try self.readU32();
                const list = try List.init(self.allocator);
                const ref = try self.reserveRef(have_flag);
                const v = Value{ .list = list };
                _ = self.setRef(ref, v);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const item = try self.readObject();
                    try list.append(self.allocator, item);
                }
                return v;
            },

            .dict => {
                const dict = try Dict.init(self.allocator);
                const ref = try self.reserveRef(have_flag);
                const v = Value{ .dict = dict };
                _ = self.setRef(ref, v);
                while (true) {
                    const k = try self.readObject();
                    if (k == .null_sentinel) break;
                    const val = try self.readObject();
                    switch (k) {
                        .str => |s| try dict.setStr(self.allocator, s.bytes, val),
                        else => {}, // non-str keys not modelled in M1
                    }
                }
                return v;
            },

            .set, .frozenset => {
                // Read but discard items; set is not needed for hello.
                const n = try self.readU32();
                const list = try List.init(self.allocator);
                const ref = try self.reserveRef(have_flag);
                const v = Value{ .list = list };
                _ = self.setRef(ref, v);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const item = try self.readObject();
                    try list.append(self.allocator, item);
                }
                return v;
            },

            .slice => {
                const ref = try self.reserveRef(have_flag);
                const start = try self.readObject();
                const stop = try self.readObject();
                const step = try self.readObject();
                const sl = try Slice.init(self.allocator, start, stop, step);
                return self.setRef(ref, Value{ .slice = sl });
            },

            .code => return self.readCode(have_flag),

            .ref => {
                const idx = try self.readU32();
                if (idx >= self.refs.items.len) return error.BadRefIndex;
                return self.refs.items[idx];
            },

            else => return error.UnknownTypeByte,
        }
    }

    fn readTuple(self: *Reader, n: usize, have_flag: bool) Error!Value {
        const tup = try Tuple.init(self.allocator, n);
        const ref = try self.reserveRef(have_flag);
        const v = Value{ .tuple = tup };
        _ = self.setRef(ref, v);
        for (tup.items) |*slot| {
            slot.* = try self.readObject();
        }
        return v;
    }

    fn readLong(self: *Reader, have_flag: bool) Error!Value {
        const n_raw = try self.readI32();
        const negative = n_raw < 0;
        const size: usize = @intCast(if (negative) -n_raw else n_raw);
        var acc: i128 = 0;
        var shift: u7 = 0;
        var i: usize = 0;
        while (i < size) : (i += 1) {
            try self.need(2);
            const d: u16 = @as(u16, self.buf[self.pos]) |
                (@as(u16, self.buf[self.pos + 1]) << 8);
            self.pos += 2;
            acc |= @as(i128, d) << shift;
            shift += 15;
            if (shift >= 120) break; // overflow protection; M1 ignores big ints
        }
        if (negative) acc = -acc;
        const clamped: i64 = @intCast(std.math.clamp(acc, std.math.minInt(i64), std.math.maxInt(i64)));
        return self.setRef(try self.reserveRef(have_flag), Value{ .small_int = clamped });
    }

    fn readCode(self: *Reader, have_flag: bool) Error!Value {
        const code = try Code.init(self.allocator);
        const ref = try self.reserveRef(have_flag);
        const v = Value{ .code = code };
        _ = self.setRef(ref, v);

        code.argcount = try self.readI32();
        code.posonlyargcount = try self.readI32();
        code.kwonlyargcount = try self.readI32();
        code.stacksize = try self.readI32();
        code.flags = try self.readI32();

        // Wrappers from readObject can be aliased through marshal's ref
        // table, so we don't free them here. The whole reader output is
        // expected to be arena-backed; freeing happens in one shot.

        const bc = try self.readObject();
        if (bc != .bytes) return error.CodeFieldMismatch;
        code.bytecode = bc.bytes.data;

        const consts = try self.readObject();
        if (consts != .tuple) return error.CodeFieldMismatch;
        code.consts = consts.tuple.items;

        code.names = try self.readStringTuple();
        code.localsplusnames = try self.readStringTuple();

        const kinds = try self.readObject();
        if (kinds != .bytes) return error.CodeFieldMismatch;
        code.localspluskinds = kinds.bytes.data;

        code.filename = try self.readOwnedStr();
        code.name = try self.readOwnedStr();
        code.qualname = try self.readOwnedStr();

        code.firstlineno = try self.readI32();

        const lt = try self.readObject();
        if (lt != .bytes) return error.CodeFieldMismatch;
        code.linetable = lt.bytes.data;

        const et = try self.readObject();
        if (et != .bytes) return error.CodeFieldMismatch;
        code.exceptiontable = et.bytes.data;

        code.deriveLocalCounts();
        return v;
    }

    fn readStringTuple(self: *Reader) Error![]const []const u8 {
        const val = try self.readObject();
        if (val != .tuple) return error.CodeFieldMismatch;
        const tup = val.tuple;
        const out = try self.allocator.alloc([]const u8, tup.items.len);
        for (tup.items, 0..) |it, i| {
            switch (it) {
                .str => |s| out[i] = s.bytes,
                else => return error.CodeFieldMismatch,
            }
        }
        return out;
    }

    fn readOwnedStr(self: *Reader) Error![]const u8 {
        const v = try self.readObject();
        switch (v) {
            .str => |s| return s.bytes,
            else => return error.CodeFieldMismatch,
        }
    }
};
