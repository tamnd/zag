//! The opcode dispatch loop. One `switch` head; every arm ends with
//! `continue :sw @enumFromInt(code[ip])` to keep the loop threaded
//! (Zig 0.16 labeled-continue, the analogue of GCC's computed goto).

const std = @import("std");

const op = @import("../op/opcode.zig");
const Opcode = op.Opcode;

const Value = @import("../object/value.zig").Value;
const Frame = @import("frame.zig").Frame;
const Interp = @import("interp.zig").Interp;

pub const DispatchError = error{
    UnknownOpcode,
    NameError,
    TypeError,
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
    switch (callable) {
        .builtin_fn => |f| return try f.func(@ptrCast(interp), args),
        else => {
            try interp.typeError("object is not callable");
            return error.TypeError;
        },
    }
}
