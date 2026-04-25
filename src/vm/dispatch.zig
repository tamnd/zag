//! The opcode dispatch loop. One `switch` head; every arm ends with
//! `continue :sw @enumFromInt(code[ip])` to keep the loop threaded
//! (Zig 0.16 labeled-continue, the analogue of GCC's computed goto).

const std = @import("std");

const op = @import("../op/opcode.zig");
const Opcode = op.Opcode;

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const Str = @import("../object/string.zig").Str;
const List = @import("../object/list.zig").List;
const Iter = @import("../object/iter.zig").Iter;
const Tuple = @import("../object/tuple.zig").Tuple;
const Code = @import("../object/code.zig").Code;
const FastKind = @import("../object/code.zig").FastKind;
const Function = @import("../object/function.zig").Function;
const Cell = @import("../object/cell.zig").Cell;
const Dict = @import("../object/dict.zig").Dict;
const Frame = @import("frame.zig").Frame;
const Interp = @import("interp.zig").Interp;
const strmethods = @import("strmethods.zig");
const listmethods = @import("listmethods.zig");
const dictmethods = @import("dictmethods.zig");

pub const DispatchError = error{
    UnknownOpcode,
    NameError,
    TypeError,
    AttributeError,
    IndexError,
    StackUnderflow,
    OutOfMemory,
    WriteFailed,
} || anyerror;

pub fn run(interp: *Interp, frame: *Frame) DispatchError!Value {
    const code = frame.code.bytecode;
    var ext_arg: u32 = 0;

    // Read first opcode and enter the switch.
    if (code.len == 0) return Value.none;
    const first_op = code[frame.ip];

    sw: switch (@as(Opcode, @enumFromInt(first_op))) {
        .RESUME, .NOP, .NOT_TAKEN, .CACHE => {
            continue :sw advance(frame, &ext_arg, 0);
        },

        .EXTENDED_ARG => {
            const arg = oparg(frame, ext_arg);
            ext_arg = arg << 8;
            frame.ip += 2;
            continue :sw @as(Opcode, @enumFromInt(code[frame.ip]));
        },

        .POP_TOP => {
            _ = frame.pop();
            continue :sw advance(frame, &ext_arg, 0);
        },

        .PUSH_NULL => {
            frame.push(Value.null_sentinel);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LOAD_CONST => {
            const arg = oparg(frame, ext_arg);
            frame.push(frame.code.consts[arg]);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LOAD_SMALL_INT => {
            const arg = oparg(frame, ext_arg);
            frame.push(Value{ .small_int = @intCast(arg) });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LOAD_NAME => {
            const arg = oparg(frame, ext_arg);
            const name = frame.code.names[arg];
            if (frame.locals.getStr(name)) |v| {
                frame.push(v);
            } else if (frame.globals.getStr(name)) |v| {
                frame.push(v);
            } else if (frame.builtins.getStr(name)) |v| {
                frame.push(v);
            } else {
                try interp.nameError(name);
                return error.NameError;
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .STORE_NAME => {
            const arg = oparg(frame, ext_arg);
            const name = frame.code.names[arg];
            try frame.locals.setStr(interp.allocator, name, frame.pop());
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LOAD_GLOBAL => {
            const arg = oparg(frame, ext_arg);
            const name_idx = arg >> 1;
            const push_null = (arg & 1) != 0;
            const name = frame.code.names[name_idx];
            if (frame.globals.getStr(name)) |v| {
                frame.push(v);
            } else if (frame.builtins.getStr(name)) |v| {
                frame.push(v);
            } else {
                try interp.nameError(name);
                return error.NameError;
            }
            if (push_null) frame.push(Value.null_sentinel);
            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.LOAD_GLOBAL)]);
        },

        .CALL => {
            const argc = oparg(frame, ext_arg);
            // Stack: [..., callable, self_or_null, arg0, ..., arg_{argc-1}]
            const args_start = frame.sp - argc;
            const self_slot = frame.stack[args_start - 1];
            const callable = frame.stack[args_start - 2];
            var n_real: u32 = argc;
            var args_base = args_start;
            if (self_slot != .null_sentinel) {
                // Bound-method form: self is an implicit first arg.
                n_real = argc + 1;
                args_base = args_start - 1;
            }
            const args = frame.stack[args_base .. args_base + n_real];
            const result = try invoke(interp, callable, args);
            // Pop argc + 2 (self slot + callable) then push result.
            frame.sp = args_start - 2;
            frame.push(result);
            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.CALL)]);
        },

        .LOAD_ATTR => {
            const arg = oparg(frame, ext_arg);
            const name_idx = arg >> 1;
            const is_method = (arg & 1) != 0;
            const name = frame.code.names[name_idx];
            const obj = frame.pop();
            if (is_method) {
                const method: ?*value_mod.BuiltinFn = switch (obj) {
                    .str => strmethods.lookup(name),
                    .list => listmethods.lookup(name),
                    .dict => dictmethods.lookup(name),
                    else => null,
                };
                if (method) |m| {
                    frame.push(Value{ .builtin_fn = m });
                    frame.push(obj);
                } else {
                    try interp.attributeError(obj.typeName(), name);
                    return error.AttributeError;
                }
            } else {
                try interp.attributeError(obj.typeName(), name);
                return error.AttributeError;
            }
            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.LOAD_ATTR)]);
        },

        .BINARY_OP => {
            const arg = oparg(frame, ext_arg);
            const b = frame.pop();
            const a = frame.pop();
            const result = try binaryOp(interp, a, b, arg);
            frame.push(result);
            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.BINARY_OP)]);
        },

        .CONTAINS_OP => {
            const arg = oparg(frame, ext_arg);
            const container = frame.pop();
            const item = frame.pop();
            const found = try containsOp(interp, item, container);
            const invert = (arg & 1) != 0;
            frame.push(Value{ .boolean = found != invert });
            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.CONTAINS_OP)]);
        },

        .BUILD_LIST => {
            const arg = oparg(frame, ext_arg);
            const list = try List.init(interp.allocator);
            const start = frame.sp - arg;
            var i: u32 = 0;
            while (i < arg) : (i += 1) {
                try list.append(interp.allocator, frame.stack[start + i]);
            }
            frame.sp = start;
            frame.push(Value{ .list = list });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LIST_EXTEND => {
            const arg = oparg(frame, ext_arg);
            const iterable = frame.pop();
            const list_val = frame.stack[frame.sp - arg];
            if (list_val != .list) {
                try interp.typeError("LIST_EXTEND target is not a list");
                return error.TypeError;
            }
            switch (iterable) {
                .tuple => |t| for (t.items) |it| try list_val.list.append(interp.allocator, it),
                .list => |l| for (l.items.items) |it| try list_val.list.append(interp.allocator, it),
                else => {
                    try interp.typeError("LIST_EXTEND requires an iterable");
                    return error.TypeError;
                },
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .COMPARE_OP => {
            const arg = oparg(frame, ext_arg);
            // 3.14 encoding: oparg >> 5 selects the comparison kind.
            const kind: u3 = @intCast((arg >> 5) & 0x7);
            const b = frame.pop();
            const a = frame.pop();
            const result = compareOp(interp, a, b, kind) catch |e| return e;
            frame.push(Value{ .boolean = result });
            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.COMPARE_OP)]);
        },

        .IS_OP => {
            const arg = oparg(frame, ext_arg);
            const b = frame.pop();
            const a = frame.pop();
            const same = a.identityEq(b);
            const invert = (arg & 1) != 0;
            frame.push(Value{ .boolean = same != invert });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .TO_BOOL => {
            const v = frame.pop();
            frame.push(Value{ .boolean = v.isTruthy() });
            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.TO_BOOL)]);
        },

        .COPY => {
            const arg = oparg(frame, ext_arg);
            // COPY arg pushes stack[sp-arg]; arg=1 duplicates TOS.
            frame.push(frame.stack[frame.sp - arg]);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .SWAP => {
            const arg = oparg(frame, ext_arg);
            // SWAP arg swaps TOS with stack[sp-arg]; arg=2 swaps top two.
            const top_idx = frame.sp - 1;
            const other = frame.sp - arg;
            const tmp = frame.stack[top_idx];
            frame.stack[top_idx] = frame.stack[other];
            frame.stack[other] = tmp;
            continue :sw advance(frame, &ext_arg, 0);
        },

        .POP_JUMP_IF_FALSE => {
            const arg = oparg(frame, ext_arg);
            const v = frame.pop();
            const cw = op.cache_width[@intFromEnum(Opcode.POP_JUMP_IF_FALSE)];
            frame.ip += 2 + 2 * @as(u32, cw);
            if (!v.isTruthy()) frame.ip += 2 * arg;
            ext_arg = 0;
            continue :sw @as(Opcode, @enumFromInt(code[frame.ip]));
        },

        .POP_JUMP_IF_TRUE => {
            const arg = oparg(frame, ext_arg);
            const v = frame.pop();
            const cw = op.cache_width[@intFromEnum(Opcode.POP_JUMP_IF_TRUE)];
            frame.ip += 2 + 2 * @as(u32, cw);
            if (v.isTruthy()) frame.ip += 2 * arg;
            ext_arg = 0;
            continue :sw @as(Opcode, @enumFromInt(code[frame.ip]));
        },

        .JUMP_FORWARD => {
            const arg = oparg(frame, ext_arg);
            frame.ip += 2 + 2 * arg;
            ext_arg = 0;
            continue :sw @as(Opcode, @enumFromInt(code[frame.ip]));
        },

        .STORE_SUBSCR => {
            const idx = frame.pop();
            const container = frame.pop();
            const value = frame.pop();
            try storeSubscr(interp, container, idx, value);
            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.STORE_SUBSCR)]);
        },

        .GET_ITER => {
            const v = frame.pop();
            const it = try makeIter(interp, v);
            frame.push(Value{ .iter = it });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .FOR_ITER => {
            const arg = oparg(frame, ext_arg);
            const cw = op.cache_width[@intFromEnum(Opcode.FOR_ITER)];
            // TOS is the iterator. Peek, don't pop.
            const it = frame.stack[frame.sp - 1];
            if (it != .iter) {
                try interp.typeError("FOR_ITER on non-iterator");
                return error.TypeError;
            }
            if (it.iter.next()) |v| {
                frame.push(v);
                frame.ip += 2 + 2 * @as(u32, cw);
            } else {
                // Exhausted: push the end-of-iter sentinel and jump.
                // END_FOR will pop the sentinel; POP_ITER pops the iter.
                frame.push(Value.null_sentinel);
                frame.ip += 2 + 2 * @as(u32, cw) + 2 * arg;
            }
            ext_arg = 0;
            continue :sw @as(Opcode, @enumFromInt(code[frame.ip]));
        },

        .END_FOR => {
            _ = frame.pop();
            continue :sw advance(frame, &ext_arg, 0);
        },

        .POP_ITER => {
            _ = frame.pop();
            continue :sw advance(frame, &ext_arg, 0);
        },

        .JUMP_BACKWARD, .JUMP_BACKWARD_NO_INTERRUPT => {
            const arg = oparg(frame, ext_arg);
            const cw = op.cache_width[@intFromEnum(Opcode.JUMP_BACKWARD)];
            frame.ip = frame.ip + 2 + 2 * @as(u32, cw) - 2 * arg;
            ext_arg = 0;
            continue :sw @as(Opcode, @enumFromInt(code[frame.ip]));
        },

        .LIST_APPEND => {
            const arg = oparg(frame, ext_arg);
            const v = frame.pop();
            const list_val = frame.stack[frame.sp - arg];
            try list_val.list.append(interp.allocator, v);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LOAD_FAST, .LOAD_FAST_BORROW, .LOAD_FAST_CHECK => {
            const arg = oparg(frame, ext_arg);
            frame.push(frame.fast[arg]);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LOAD_FAST_AND_CLEAR => {
            const arg = oparg(frame, ext_arg);
            frame.push(frame.fast[arg]);
            frame.fast[arg] = Value.null_sentinel;
            continue :sw advance(frame, &ext_arg, 0);
        },

        .STORE_FAST => {
            const arg = oparg(frame, ext_arg);
            frame.fast[arg] = frame.pop();
            continue :sw advance(frame, &ext_arg, 0);
        },

        .STORE_FAST_LOAD_FAST => {
            const arg = oparg(frame, ext_arg);
            const store_idx = (arg >> 4) & 0xF;
            const load_idx = arg & 0xF;
            frame.fast[store_idx] = frame.pop();
            frame.push(frame.fast[load_idx]);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LOAD_FAST_BORROW_LOAD_FAST_BORROW => {
            const arg = oparg(frame, ext_arg);
            const hi = (arg >> 4) & 0xF;
            const lo = arg & 0xF;
            frame.push(frame.fast[hi]);
            frame.push(frame.fast[lo]);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LOAD_FAST_LOAD_FAST => {
            const arg = oparg(frame, ext_arg);
            frame.push(frame.fast[(arg >> 4) & 0xF]);
            frame.push(frame.fast[arg & 0xF]);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .BUILD_TUPLE => {
            const n = oparg(frame, ext_arg);
            const t = try Tuple.init(interp.allocator, n);
            const base = frame.sp - n;
            @memcpy(t.items, frame.stack[base .. base + n]);
            frame.sp = base;
            frame.push(Value{ .tuple = t });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .MAKE_FUNCTION => {
            const code_val = frame.pop();
            if (code_val != .code) {
                try interp.typeError("MAKE_FUNCTION expects a code object");
                return error.TypeError;
            }
            const f = try Function.init(interp.allocator, code_val.code, frame.globals);
            frame.push(Value{ .function = f });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .SET_FUNCTION_ATTRIBUTE => {
            const arg = oparg(frame, ext_arg);
            const fn_val = frame.pop();
            const attr_val = frame.pop();
            if (fn_val != .function) {
                try interp.typeError("SET_FUNCTION_ATTRIBUTE on non-function");
                return error.TypeError;
            }
            switch (arg) {
                1 => fn_val.function.defaults = attr_val.tuple,
                8 => fn_val.function.closure = attr_val.tuple,
                else => {
                    try interp.stderr.print(
                        "zag: SET_FUNCTION_ATTRIBUTE arg {d} not supported\n",
                        .{arg},
                    );
                    try interp.stderr.flush();
                    return error.TypeError;
                },
            }
            frame.push(fn_val);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .MAKE_CELL => {
            const arg = oparg(frame, ext_arg);
            const existing = frame.fast[arg];
            const cell = try Cell.init(interp.allocator, existing);
            frame.fast[arg] = Value{ .cell = cell };
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LOAD_DEREF => {
            const arg = oparg(frame, ext_arg);
            const slot = frame.fast[arg];
            if (slot != .cell) {
                try interp.typeError("LOAD_DEREF on non-cell slot");
                return error.TypeError;
            }
            frame.push(slot.cell.value);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .STORE_DEREF => {
            const arg = oparg(frame, ext_arg);
            const slot = frame.fast[arg];
            if (slot != .cell) {
                try interp.typeError("STORE_DEREF on non-cell slot");
                return error.TypeError;
            }
            slot.cell.value = frame.pop();
            continue :sw advance(frame, &ext_arg, 0);
        },

        .COPY_FREE_VARS => {
            // The function's closure tuple is held by the running
            // function; we stashed it on the frame at call time.
            const n = oparg(frame, ext_arg);
            const closure = frame.closure orelse {
                try interp.typeError("COPY_FREE_VARS without closure");
                return error.TypeError;
            };
            // Free vars sit at the END of the fast array.
            const start = frame.fast.len - n;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                frame.fast[start + i] = closure.items[i];
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .CALL_KW => {
            const argc = oparg(frame, ext_arg);
            // Stack: [..., callable, self_or_null, arg0, ..., arg_{argc-1}, names_tuple]
            const names_val = frame.pop();
            if (names_val != .tuple) {
                try interp.typeError("CALL_KW: kw names not a tuple");
                return error.TypeError;
            }
            const names = names_val.tuple.items;
            const args_start = frame.sp - argc;
            const self_slot = frame.stack[args_start - 1];
            const callable = frame.stack[args_start - 2];

            var args_base = args_start;
            var n_real: u32 = argc;
            if (self_slot != .null_sentinel) {
                args_base = args_start - 1;
                n_real = argc + 1;
            }
            const all_args = frame.stack[args_base .. args_base + n_real];
            // Last `names.len` of `argc` (NOT n_real) are kw values.
            const n_kw: u32 = @intCast(names.len);
            const n_pos = n_real - n_kw;
            const positional = all_args[0..n_pos];
            const kw_values = all_args[n_pos..];

            const result = try invokeKw(interp, callable, positional, names, kw_values);
            frame.sp = args_start - 2;
            frame.push(result);
            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.CALL_KW)]);
        },

        .RETURN_VALUE => {
            return frame.pop();
        },

        else => {
            try interp.unsupportedOpcode(first_op, frame.ip);
            return error.UnknownOpcode;
        },
    }
}

inline fn oparg(frame: *Frame, ext_arg: u32) u32 {
    return @as(u32, frame.code.bytecode[frame.ip + 1]) | ext_arg;
}

/// Advance IP past the current 2-byte instruction plus `cw` cache
/// words, then return the next opcode for `continue :sw`. Also clears
/// the EXTENDED_ARG carry.
inline fn advance(frame: *Frame, ext_arg: *u32, cw: u8) Opcode {
    frame.ip += 2 + 2 * @as(u32, cw);
    ext_arg.* = 0;
    return @as(Opcode, @enumFromInt(frame.code.bytecode[frame.ip]));
}

/// CPython 3.14 BINARY_OP arg=26 -> NB_SUBSCR (the only flavor M4
/// forces). Other variants surface as TypeError so the next fixture
/// to need them prompts a fix instead of silently doing the wrong
/// thing.
fn binaryOp(interp: *Interp, a: Value, b: Value, arg: u32) !Value {
    return switch (arg) {
        0 => add(interp, a, b),
        5 => multiply(interp, a, b),
        6 => remainder(interp, a, b),
        10 => subtract(interp, a, b),
        13 => inplaceAdd(interp, a, b),
        26 => subscript(interp, a, b),
        else => blk: {
            try interp.stderr.print(
                "TypeError: zag: unsupported BINARY_OP arg {d}\n",
                .{arg},
            );
            try interp.stderr.flush();
            break :blk error.TypeError;
        },
    };
}

/// `+` for int+int and str+str. Other operand combos wait for a
/// fixture.
fn add(interp: *Interp, a: Value, b: Value) !Value {
    if (a == .small_int and b == .small_int) {
        return Value{ .small_int = a.small_int +% b.small_int };
    }
    if (a == .str and b == .str) {
        const buf = try interp.allocator.alloc(u8, a.str.bytes.len + b.str.bytes.len);
        @memcpy(buf[0..a.str.bytes.len], a.str.bytes);
        @memcpy(buf[a.str.bytes.len..], b.str.bytes);
        const s = try Str.fromOwnedSlice(interp.allocator, buf);
        return Value{ .str = s };
    }
    try interp.typeError("unsupported operand type(s) for +");
    return error.TypeError;
}

fn subtract(interp: *Interp, a: Value, b: Value) !Value {
    if (a == .small_int and b == .small_int) {
        return Value{ .small_int = a.small_int -% b.small_int };
    }
    try interp.typeError("unsupported operand type(s) for -");
    return error.TypeError;
}

fn multiply(interp: *Interp, a: Value, b: Value) !Value {
    if (a == .small_int and b == .small_int) {
        return Value{ .small_int = a.small_int *% b.small_int };
    }
    try interp.typeError("unsupported operand type(s) for *");
    return error.TypeError;
}

/// `int + int` for the BINARY_OP arg=13 (`NB_INPLACE_ADD`) path.
/// Ints are immutable, so "in-place" just means we return a fresh
/// small_int. Other operand combinations wait for a fixture.
fn inplaceAdd(interp: *Interp, a: Value, b: Value) !Value {
    if (a == .small_int and b == .small_int) {
        return Value{ .small_int = a.small_int +% b.small_int };
    }
    try interp.typeError("unsupported operand type(s) for +");
    return error.TypeError;
}

/// `int % int` with Python semantics: the result takes the sign of
/// the divisor, not the dividend (Zig's `@rem` takes the dividend's
/// sign). Cheap to do correctly even though the fixture only uses
/// positive operands.
fn remainder(interp: *Interp, a: Value, b: Value) !Value {
    if (a == .small_int and b == .small_int) {
        const x = a.small_int;
        const y = b.small_int;
        if (y == 0) {
            try interp.typeError("integer modulo by zero");
            return error.TypeError;
        }
        const r = @rem(x, y);
        const adjusted = if (r != 0 and ((r < 0) != (y < 0))) r + y else r;
        return Value{ .small_int = adjusted };
    }
    try interp.typeError("unsupported operand type(s) for %");
    return error.TypeError;
}

fn subscript(interp: *Interp, container: Value, key: Value) !Value {
    switch (container) {
        .str => |s| {
            const bytes = s.bytes;
            switch (key) {
                .small_int => |i| {
                    const n: i64 = @intCast(bytes.len);
                    var idx = i;
                    if (idx < 0) idx += n;
                    if (idx < 0 or idx >= n) {
                        try interp.indexError("string index out of range");
                        return error.IndexError;
                    }
                    const piece = try Str.init(interp.allocator, bytes[@intCast(idx) .. @intCast(idx + 1)]);
                    return Value{ .str = piece };
                },
                .slice => |sl| {
                    if (sl.step != .none) {
                        try interp.typeError("slice step != 1 not supported");
                        return error.TypeError;
                    }
                    const n: i64 = @intCast(bytes.len);
                    const start = clampSliceBound(sl.start, n, 0);
                    const stop = clampSliceBound(sl.stop, n, n);
                    const lo: usize = @intCast(start);
                    const hi: usize = @intCast(if (stop < start) start else stop);
                    const piece = try Str.init(interp.allocator, bytes[lo..hi]);
                    return Value{ .str = piece };
                },
                else => {
                    try interp.typeError("string indices must be integers or slices");
                    return error.TypeError;
                },
            }
        },
        .list => |l| {
            switch (key) {
                .small_int => |i| {
                    const n: i64 = @intCast(l.items.items.len);
                    var idx = i;
                    if (idx < 0) idx += n;
                    if (idx < 0 or idx >= n) {
                        try interp.indexError("list index out of range");
                        return error.IndexError;
                    }
                    return l.items.items[@intCast(idx)];
                },
                .slice => |sl| {
                    if (sl.step != .none) {
                        try interp.typeError("slice step != 1 not supported");
                        return error.TypeError;
                    }
                    const n: i64 = @intCast(l.items.items.len);
                    const start = clampSliceBound(sl.start, n, 0);
                    const stop = clampSliceBound(sl.stop, n, n);
                    const lo: usize = @intCast(start);
                    const hi: usize = @intCast(if (stop < start) start else stop);
                    const out = try List.init(interp.allocator);
                    for (l.items.items[lo..hi]) |it| try out.append(interp.allocator, it);
                    return Value{ .list = out };
                },
                else => {
                    try interp.typeError("list indices must be integers");
                    return error.TypeError;
                },
            }
        },
        else => {
            try interp.typeError("object is not subscriptable");
            return error.TypeError;
        },
    }
}

fn clampSliceBound(v: Value, n: i64, default_: i64) i64 {
    return switch (v) {
        .none => default_,
        .small_int => |i| blk: {
            var x = i;
            if (x < 0) x += n;
            if (x < 0) x = 0;
            if (x > n) x = n;
            break :blk x;
        },
        else => default_,
    };
}

fn storeSubscr(interp: *Interp, container: Value, key: Value, value: Value) !void {
    switch (container) {
        .list => |l| switch (key) {
            .small_int => |i| {
                const n: i64 = @intCast(l.items.items.len);
                var idx = i;
                if (idx < 0) idx += n;
                if (idx < 0 or idx >= n) {
                    try interp.indexError("list assignment index out of range");
                    return error.IndexError;
                }
                l.items.items[@intCast(idx)] = value;
            },
            else => {
                try interp.typeError("list indices must be integers");
                return error.TypeError;
            },
        },
        else => {
            try interp.typeError("object does not support item assignment");
            return error.TypeError;
        },
    }
}

fn makeIter(interp: *Interp, v: Value) !*Iter {
    return switch (v) {
        .list => |l| try Iter.init(interp.allocator, .{ .list = l }),
        .tuple => |t| try Iter.init(interp.allocator, .{ .tuple = t }),
        .iter => |it| it,
        else => {
            try interp.typeError("object is not iterable");
            return error.TypeError;
        },
    };
}

fn containsOp(interp: *Interp, item: Value, container: Value) !bool {
    switch (container) {
        .str => |s| {
            if (item != .str) {
                try interp.typeError("'in <string>' requires string as left operand");
                return error.TypeError;
            }
            return std.mem.indexOf(u8, s.bytes, item.str.bytes) != null;
        },
        .list => |l| {
            for (l.items.items) |it| if (it.equals(item)) return true;
            return false;
        },
        .tuple => |t| {
            for (t.items) |it| if (it.equals(item)) return true;
            return false;
        },
        else => {
            try interp.typeError("argument of type is not iterable");
            return error.TypeError;
        },
    }
}

/// CPython 3.14 COMPARE_OP kinds: 0 `<`, 1 `<=`, 2 `==`, 3 `!=`,
/// 4 `>`, 5 `>=`. `==` / `!=` accept any pair of types (mismatched
/// types compare unequal); ordering on unsupported types raises
/// TypeError.
fn compareOp(interp: *Interp, a: Value, b: Value, kind: u3) !bool {
    return switch (kind) {
        2 => a.equals(b),
        3 => !a.equals(b),
        else => blk: {
            const o = a.order(b) orelse {
                try interp.typeError("'<' not supported between these types");
                return error.TypeError;
            };
            break :blk switch (kind) {
                0 => o == .lt,
                1 => o != .gt,
                4 => o == .gt,
                5 => o != .lt,
                else => unreachable,
            };
        },
    };
}

fn invoke(interp: *Interp, callable: Value, args: []const Value) !Value {
    return invokeKw(interp, callable, args, &.{}, &.{});
}

fn invokeKw(
    interp: *Interp,
    callable: Value,
    positional: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) !Value {
    switch (callable) {
        .builtin_fn => |f| {
            if (kw_names.len != 0) {
                try interp.typeError("builtin does not take keyword arguments");
                return error.TypeError;
            }
            return try f.func(@ptrCast(interp), positional);
        },
        .function => |fn_val| return callPyFunction(interp, fn_val, positional, kw_names, kw_values),
        else => {
            try interp.typeError("object is not callable");
            return error.TypeError;
        },
    }
}

const CO_VARARGS: i32 = 0x04;
const CO_VARKEYWORDS: i32 = 0x08;

fn callPyFunction(
    interp: *Interp,
    fn_val: *Function,
    positional: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) !Value {
    const code = fn_val.code;
    const argcount: u32 = @intCast(code.argcount);
    const kwonly: u32 = @intCast(code.kwonlyargcount);
    const has_varargs = (code.flags & CO_VARARGS) != 0;
    const has_varkw = (code.flags & CO_VARKEYWORDS) != 0;

    const new_frame = try Frame.init(interp.allocator, code, fn_val.globals, interp.builtins, fn_val.globals);
    new_frame.closure = fn_val.closure;

    // 1. Bind positional args.
    const n_pos = positional.len;
    if (n_pos > argcount and !has_varargs) {
        try interp.typeError("too many positional arguments");
        return error.TypeError;
    }
    const fill = @min(n_pos, argcount);
    var i: usize = 0;
    while (i < fill) : (i += 1) {
        new_frame.fast[i] = positional[i];
    }
    // *args slot collects overflow.
    if (has_varargs) {
        const overflow_n = if (n_pos > argcount) n_pos - argcount else 0;
        const t = try Tuple.init(interp.allocator, overflow_n);
        var j: usize = 0;
        while (j < overflow_n) : (j += 1) t.items[j] = positional[argcount + j];
        new_frame.fast[argcount + kwonly] = Value{ .tuple = t };
    }
    // **kw slot starts as empty dict; populated below.
    const varkw_slot: ?u32 = if (has_varkw) argcount + kwonly + (@as(u32, if (has_varargs) 1 else 0)) else null;
    var kw_dict: ?*Dict = null;
    if (varkw_slot) |slot| {
        kw_dict = try Dict.init(interp.allocator);
        new_frame.fast[slot] = Value{ .dict = kw_dict.? };
    }

    // 2. Bind keyword args by name.
    var k: usize = 0;
    while (k < kw_names.len) : (k += 1) {
        const name = kw_names[k].str.bytes;
        const v = kw_values[k];
        var matched = false;
        var s: u32 = 0;
        while (s < argcount + kwonly) : (s += 1) {
            if (std.mem.eql(u8, code.localsplusnames[s], name)) {
                if (new_frame.fast[s] != .null_sentinel) {
                    try interp.typeError("got multiple values for argument");
                    return error.TypeError;
                }
                new_frame.fast[s] = v;
                matched = true;
                break;
            }
        }
        if (!matched) {
            if (kw_dict) |d| {
                try d.setStr(interp.allocator, name, v);
            } else {
                try interp.typeError("got an unexpected keyword argument");
                return error.TypeError;
            }
        }
    }

    // 3. Fill missing positional/kw-only slots from defaults.
    if (fn_val.defaults) |def_tuple| {
        const defaults = def_tuple.items;
        // Defaults align to the right of positional args.
        const default_start = argcount - defaults.len;
        var s: u32 = 0;
        while (s < argcount) : (s += 1) {
            if (new_frame.fast[s] == .null_sentinel and s >= default_start) {
                new_frame.fast[s] = defaults[s - default_start];
            }
        }
    }

    // 4. Verify all required positional/kw-only slots are filled.
    var s: u32 = 0;
    while (s < argcount + kwonly) : (s += 1) {
        if (new_frame.fast[s] == .null_sentinel) {
            try interp.typeError("missing required argument");
            return error.TypeError;
        }
    }

    const result = try run(interp, new_frame);
    new_frame.deinit(interp.allocator);
    return result;
}
