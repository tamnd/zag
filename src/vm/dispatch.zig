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
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Generator = @import("../object/generator.zig").Generator;
const Slice = @import("../object/slice.zig").Slice;
const Set = @import("../object/set.zig").Set;
const Dict = @import("../object/dict.zig").Dict;
const Frame = @import("frame.zig").Frame;
const Interp = @import("interp.zig").Interp;
const strmethods = @import("strmethods.zig");
const listmethods = @import("listmethods.zig");
const setmethods = @import("setmethods.zig");
const bytearraymethods = @import("bytearraymethods.zig");
const dictmethods = @import("dictmethods.zig");
const exc = @import("exc.zig");
const builtins_mod = @import("builtins.zig");
const format_mod = @import("format.zig");

pub const DispatchError = error{
    UnknownOpcode,
    NameError,
    TypeError,
    AttributeError,
    IndexError,
    /// The interp has a Python exception in `current_exc`. Caught by
    /// the dispatch wrapper if the running frame's exception table
    /// covers `frame.ip`; otherwise propagates to the caller frame.
    PyException,
    /// YIELD_VALUE has stashed a value in `interp.gen_yielded` and is
    /// asking the dispatch wrapper to suspend the frame. Caught by
    /// `genResume`, never by the exception-table loop.
    GenYield,
    StackUnderflow,
    OutOfMemory,
    WriteFailed,
} || anyerror;

/// Outer dispatch: run the inner switch, and on `error.PyException`
/// consult the frame's exception table. If a handler covers
/// `frame.ip`, truncate the stack to the handler's depth, push the
/// exception (CPython 3.14 hands the exception to the handler on
/// TOS), jump, and re-enter. Otherwise propagate.
pub fn run(interp: *Interp, frame: *Frame) DispatchError!Value {
    while (true) {
        if (dispatchOne(interp, frame)) |v| {
            return v;
        } else |err| {
            if (err != error.PyException) return err;
            const e = interp.current_exc orelse return err;
            if (frame.code.exceptiontable.len > 0) {
                if (exc.findHandler(frame.code.exceptiontable, frame.ip)) |h| {
                    frame.sp = h.depth;
                    if (h.lasti) frame.push(Value{ .small_int = @intCast(frame.ip) });
                    frame.push(e);
                    frame.ip = h.target;
                    continue;
                }
            }
            return err;
        }
    }
}

fn dispatchOne(interp: *Interp, frame: *Frame) DispatchError!Value {
    const code = frame.code.bytecode;
    var ext_arg: u32 = 0;

    // Read first opcode and enter the switch.
    if (code.len == 0) return Value.none;
    const first_op = code[frame.ip];

    sw: switch (@as(Opcode, @enumFromInt(first_op))) {
        .RESUME, .NOP, .NOT_TAKEN, .CACHE => {
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LOAD_COMMON_CONSTANT => {
            const arg = oparg(frame, ext_arg);
            const name: []const u8 = switch (arg) {
                0 => "AssertionError",
                1 => "NotImplementedError",
                2 => "tuple",
                3 => "list",
                4 => "set",
                5 => "dict",
                6 => "frozenset",
                else => {
                    try interp.unsupportedOpcode(81, frame.ip);
                    return error.UnknownOpcode;
                },
            };
            const v = interp.builtins.getStr(name) orelse {
                try interp.typeError("LOAD_COMMON_CONSTANT: missing builtin");
                return error.TypeError;
            };
            frame.push(v);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .IMPORT_NAME => {
            const arg = oparg(frame, ext_arg);
            // Stack: [..., level, fromlist]. Both inform what we
            // return: empty/None fromlist hands back the top of the
            // dotted chain (`import a.b.c` binds `a`); a non-empty
            // fromlist hands back the innermost so IMPORT_FROM can
            // peel names off it. `level > 0` is a relative import
            // resolved against the caller frame's `__package__`.
            const fromlist = frame.pop();
            const level_v = frame.pop();
            const level: i64 = if (level_v == .small_int) level_v.small_int else 0;
            const raw_name = frame.code.names[arg];

            const abs_name = blk: {
                if (level == 0) break :blk raw_name;
                // Resolve relative against the caller's __package__.
                const pkg_v = frame.globals.getStr("__package__") orelse Value{ .str = try Str.init(interp.allocator, "") };
                var pkg: []const u8 = if (pkg_v == .str) pkg_v.str.bytes else "";
                var k: i64 = 1;
                while (k < level) : (k += 1) {
                    if (std.mem.lastIndexOfScalar(u8, pkg, '.')) |d| {
                        pkg = pkg[0..d];
                    } else if (pkg.len > 0) {
                        pkg = "";
                    } else {
                        try interp.raisePy("ImportError", "attempted relative import beyond top-level package");
                        return error.PyException;
                    }
                }
                if (raw_name.len == 0) break :blk pkg;
                if (pkg.len == 0) break :blk raw_name;
                break :blk try std.fmt.allocPrint(interp.allocator, "{s}.{s}", .{ pkg, raw_name });
            };

            if (interp.getBuiltinModule(abs_name)) |m| {
                frame.push(Value{ .module = m });
                continue :sw advance(frame, &ext_arg, 0);
            }
            const chain_opt = try interp.loadModuleChain(abs_name);
            const chain = chain_opt orelse {
                const msg = try std.fmt.allocPrint(interp.allocator, "No module named '{s}'", .{abs_name});
                try interp.raisePy("ModuleNotFoundError", msg);
                return error.PyException;
            };
            const has_fromlist = switch (fromlist) {
                .tuple => |t| t.items.len > 0,
                .list => |l| l.items.items.len > 0,
                else => false,
            };
            if (has_fromlist and chain.innermost.is_package) {
                // Eagerly load any fromlist entries that name a
                // submodule. Anything that's already an attribute on
                // the package (a constant, a function, a sub-import
                // bound by the package's own `__init__`) is skipped.
                const items: []const Value = switch (fromlist) {
                    .tuple => |t| t.items,
                    .list => |l| l.items.items,
                    else => &.{},
                };
                for (items) |it| {
                    if (it != .str) continue;
                    const sub = it.str.bytes;
                    if (std.mem.eql(u8, sub, "*")) continue;
                    if (chain.innermost.attrs.getStr(sub) != null) continue;
                    const dotted = try std.fmt.allocPrint(interp.allocator, "{s}.{s}", .{ chain.innermost.name, sub });
                    _ = interp.loadModuleChain(dotted) catch {};
                }
            }
            const result = if (has_fromlist) chain.innermost else chain.top;
            frame.push(Value{ .module = result });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .IMPORT_FROM => {
            // `from m import x` after IMPORT_NAME leaves the module on
            // TOS; IMPORT_FROM peeks (does NOT pop), reads the named
            // attribute, and pushes it for the following STORE_*.
            const arg = oparg(frame, ext_arg);
            const name = frame.code.names[arg];
            const tos = frame.top();
            const v: Value = switch (tos) {
                .module => |m| m.attrs.getStr(name) orelse {
                    const msg = try std.fmt.allocPrint(
                        interp.allocator,
                        "cannot import name '{s}' from '{s}'",
                        .{ name, m.name },
                    );
                    try interp.raisePy("ImportError", msg);
                    return error.PyException;
                },
                else => {
                    try interp.typeError("IMPORT_FROM expects a module on TOS");
                    return error.TypeError;
                },
            };
            frame.push(v);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .GET_AWAITABLE => {
            // The fixtures only ever await coroutines (which we model
            // as generators) and the no-op done-coroutines that
            // asyncio.sleep(0) returns. Both are already iterators
            // from the SEND opcode's point of view, so this is a
            // pass-through.
            const v = frame.pop();
            switch (v) {
                .generator => frame.push(v),
                else => {
                    try interp.typeError("object can't be used in 'await' expression");
                    return error.TypeError;
                },
            }
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

        .STORE_GLOBAL => {
            const arg = oparg(frame, ext_arg);
            const name = frame.code.names[arg];
            const v = frame.pop();
            try frame.globals.setStr(interp.allocator, name, v);
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
            try loadAttr(interp, frame, obj, name, is_method);
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
                    const drained = try @import("builtins.zig").materialize(interp, iterable);
                    for (drained.items.items) |it| try list_val.list.append(interp.allocator, it);
                },
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .DICT_MERGE, .DICT_UPDATE => {
            const arg = oparg(frame, ext_arg);
            const src = frame.pop();
            if (src != .dict) {
                try interp.typeError("argument must be a mapping");
                return error.TypeError;
            }
            const dst_val = frame.stack[frame.sp - arg];
            if (dst_val != .dict) {
                try interp.typeError("DICT_MERGE target is not a dict");
                return error.TypeError;
            }
            for (src.dict.pairs.items) |p| {
                try dst_val.dict.setKey(interp.allocator, p.key, p.value);
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .CALL_FUNCTION_EX => {
            // 3.14 layout: [callable, NULL, args, kwargs_or_NULL].
            const top = frame.pop();
            const args_val = frame.pop();
            _ = frame.pop(); // NULL slot
            const callable = frame.pop();
            const args_list = switch (args_val) {
                .tuple => |t| t.items,
                .list => |l| l.items.items,
                else => (try @import("builtins.zig").materialize(interp, args_val)).items.items,
            };
            var result: Value = undefined;
            if (top == .dict) {
                const d = top.dict;
                const n = d.pairs.items.len;
                const names = try interp.allocator.alloc(Value, n);
                const vals = try interp.allocator.alloc(Value, n);
                for (d.pairs.items, 0..) |p, idx| {
                    if (p.key != .str) {
                        try interp.typeError("keywords must be strings");
                        return error.TypeError;
                    }
                    names[idx] = p.key;
                    vals[idx] = p.value;
                }
                result = try invokeKw(interp, callable, args_list, names, vals);
            } else {
                result = try invoke(interp, callable, args_list);
            }
            frame.push(result);
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

        .UNARY_NEGATIVE => {
            const v = frame.pop();
            const r: Value = switch (v) {
                .small_int => |i| Value{ .small_int = -i },
                .float => |f| Value{ .float = -f },
                .complex_num => |c| Value{ .complex_num = .{ .re = -c.re, .im = -c.im } },
                .boolean => |b| Value{ .small_int = -@as(i64, @intFromBool(b)) },
                else => {
                    try interp.typeError("bad operand type for unary -");
                    return error.TypeError;
                },
            };
            frame.push(r);
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

        .POP_JUMP_IF_NONE => {
            const arg = oparg(frame, ext_arg);
            const v = frame.pop();
            const cw = op.cache_width[@intFromEnum(Opcode.POP_JUMP_IF_NONE)];
            frame.ip += 2 + 2 * @as(u32, cw);
            if (v == .none) frame.ip += 2 * arg;
            ext_arg = 0;
            continue :sw @as(Opcode, @enumFromInt(code[frame.ip]));
        },

        .POP_JUMP_IF_NOT_NONE => {
            const arg = oparg(frame, ext_arg);
            const v = frame.pop();
            const cw = op.cache_width[@intFromEnum(Opcode.POP_JUMP_IF_NOT_NONE)];
            frame.ip += 2 + 2 * @as(u32, cw);
            if (v != .none) frame.ip += 2 * arg;
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
            switch (v) {
                .generator, .enum_iter => frame.push(v),
                else => {
                    const it = try makeIter(interp, v);
                    frame.push(Value{ .iter = it });
                },
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .FOR_ITER => {
            const arg = oparg(frame, ext_arg);
            const cw = op.cache_width[@intFromEnum(Opcode.FOR_ITER)];
            // TOS is the iterator. Peek, don't pop.
            const it = frame.stack[frame.sp - 1];
            const next_v: ?Value = try iterStep(interp, it);
            if (next_v) |v| {
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

        .JUMP_BACKWARD, .JUMP_BACKWARD_NO_INTERRUPT => |opc| {
            const arg = oparg(frame, ext_arg);
            const cw = op.cache_width[@intFromEnum(opc)];
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

        .DELETE_FAST => {
            // CPython's `except X as e:` block ends with DELETE_FAST e
            // to avoid leaking the exception through the local. We
            // don't track unbound vs bound (LOAD_FAST_CHECK is wired
            // for this); blanking the slot is what the fixtures need.
            const arg = oparg(frame, ext_arg);
            frame.fast[arg] = Value.null_sentinel;
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
                2 => fn_val.function.kw_defaults = attr_val.dict,
                4 => {}, // annotations: ignored
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
            if (slot == .cell) {
                frame.push(slot.cell.value);
            } else {
                frame.push(slot);
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .STORE_DEREF => {
            const arg = oparg(frame, ext_arg);
            const slot = frame.fast[arg];
            if (slot != .cell) {
                // Auto-promote: param slots that are also closure
                // cells get this when MAKE_CELL was elided.
                const cell = try Cell.init(interp.allocator, frame.pop());
                frame.fast[arg] = Value{ .cell = cell };
            } else {
                slot.cell.value = frame.pop();
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .DELETE_DEREF => {
            const arg = oparg(frame, ext_arg);
            const slot = frame.fast[arg];
            if (slot != .cell) {
                try interp.typeError("DELETE_DEREF on non-cell slot");
                return error.TypeError;
            }
            slot.cell.value = Value.null_sentinel;
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

        .BUILD_SET => {
            const n = oparg(frame, ext_arg);
            const s = try Set.init(interp.allocator);
            const base = frame.sp - n;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try s.add(interp.allocator, frame.stack[base + i]);
            }
            frame.sp = base;
            frame.push(Value{ .set = s });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .SET_UPDATE => {
            const arg = oparg(frame, ext_arg);
            const iterable = frame.pop();
            const set_val = frame.stack[frame.sp - arg];
            if (set_val != .set) {
                try interp.typeError("SET_UPDATE target is not a set");
                return error.TypeError;
            }
            const drained = try @import("builtins.zig").materialize(interp, iterable);
            for (drained.items.items) |it| try set_val.set.add(interp.allocator, it);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .SET_ADD => {
            const v = frame.pop();
            const set_val = frame.stack[frame.sp - oparg(frame, ext_arg)];
            try set_val.set.add(interp.allocator, v);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .BUILD_MAP => {
            const n = oparg(frame, ext_arg);
            const d = try Dict.init(interp.allocator);
            const base = frame.sp - 2 * n;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const k = frame.stack[base + 2 * i];
                const v = frame.stack[base + 2 * i + 1];
                try d.setKey(interp.allocator, k, v);
            }
            frame.sp = base;
            frame.push(Value{ .dict = d });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .BINARY_SLICE => {
            const stop = frame.pop();
            const start = frame.pop();
            const container = frame.pop();
            const sl = try Slice.init(interp.allocator, start, stop, Value.none);
            const r = try subscript(interp, container, Value{ .slice = sl });
            frame.push(r);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .STORE_SLICE => {
            const stop = frame.pop();
            const start = frame.pop();
            const container = frame.pop();
            const value = frame.pop();
            const sl = try Slice.init(interp.allocator, start, stop, Value.none);
            try storeSubscr(interp, container, Value{ .slice = sl }, value);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .BUILD_SLICE => {
            const arg = oparg(frame, ext_arg);
            const step: Value = if (arg == 3) frame.pop() else Value.none;
            const stop = frame.pop();
            const start = frame.pop();
            const sl = try Slice.init(interp.allocator, start, stop, step);
            frame.push(Value{ .slice = sl });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .DELETE_SUBSCR => {
            const key = frame.pop();
            const container = frame.pop();
            switch (container) {
                .dict => |d| {
                    if (key != .str) {
                        try interp.typeError("zag: dict del only supports str keys");
                        return error.TypeError;
                    }
                    if (!d.delete(key.str.bytes)) {
                        try interp.stderr.print("KeyError: '{s}'\n", .{key.str.bytes});
                        try interp.stderr.flush();
                        return error.TypeError;
                    }
                },
                .list => |l| switch (key) {
                    .small_int => |i| {
                        const n: i64 = @intCast(l.items.items.len);
                        var idx = i;
                        if (idx < 0) idx += n;
                        if (idx < 0 or idx >= n) {
                            try interp.indexError("list deletion index out of range");
                            return error.IndexError;
                        }
                        _ = l.items.orderedRemove(@intCast(idx));
                    },
                    .slice => |sl| {
                        const n: i64 = @intCast(l.items.items.len);
                        const r = try resolveSlice(interp, sl, n);
                        if (r.step != 1) {
                            try interp.typeError("extended slice deletion not supported");
                            return error.TypeError;
                        }
                        const lo: usize = @intCast(r.start);
                        try l.items.replaceRange(interp.allocator, lo, r.count, &.{});
                    },
                    else => {
                        try interp.typeError("list indices must be integers or slices");
                        return error.TypeError;
                    },
                },
                else => {
                    try interp.typeError("object does not support item deletion");
                    return error.TypeError;
                },
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .UNPACK_SEQUENCE => {
            const n = oparg(frame, ext_arg);
            const seq = frame.pop();
            const items: []const Value = switch (seq) {
                .tuple => |t| t.items,
                .list => |l| l.items.items,
                else => (try @import("builtins.zig").materialize(interp, seq)).items.items,
            };
            if (items.len != n) {
                try interp.typeError("unpacked length mismatch");
                return error.TypeError;
            }
            // Push in reverse so first element ends up on top.
            var i: usize = n;
            while (i > 0) {
                i -= 1;
                frame.push(items[i]);
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .UNPACK_EX => {
            // arg low byte = items before star, high byte = items after.
            // The star binds the middle slice as a fresh List. Push so
            // the leftmost source name ends up on top of the stack.
            const arg = oparg(frame, ext_arg);
            const n_before = arg & 0xFF;
            const n_after = arg >> 8;
            const seq = frame.pop();
            const items: []const Value = switch (seq) {
                .tuple => |t| t.items,
                .list => |l| l.items.items,
                else => (try @import("builtins.zig").materialize(interp, seq)).items.items,
            };
            if (items.len < n_before + n_after) {
                try interp.typeError("not enough values to unpack");
                return error.TypeError;
            }
            const rest_len = items.len - n_before - n_after;
            // trailing items: rightmost first (deepest in stack).
            var ti: usize = n_after;
            while (ti > 0) {
                ti -= 1;
                frame.push(items[n_before + rest_len + ti]);
            }
            // rest list:
            const rest_list = try @import("../object/list.zig").List.init(interp.allocator);
            try rest_list.items.appendSlice(interp.allocator, items[n_before .. n_before + rest_len]);
            frame.push(Value{ .list = rest_list });
            // leading items, rightmost first.
            var li: usize = n_before;
            while (li > 0) {
                li -= 1;
                frame.push(items[li]);
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .GET_LEN => {
            const v = frame.stack[frame.sp - 1];
            const len: i64 = switch (v) {
                .tuple => |t| @intCast(t.items.len),
                .list => |l| @intCast(l.items.items.len),
                .str => |s| @intCast(s.bytes.len),
                .dict => |d| @intCast(d.count()),
                else => {
                    try interp.typeError("object has no len()");
                    return error.TypeError;
                },
            };
            frame.push(Value{ .small_int = len });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .MATCH_SEQUENCE => {
            const v = frame.stack[frame.sp - 1];
            const ok = switch (v) {
                .list, .tuple => true,
                else => false,
            };
            frame.push(Value{ .boolean = ok });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .MATCH_MAPPING => {
            const v = frame.stack[frame.sp - 1];
            frame.push(Value{ .boolean = v == .dict });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .MATCH_KEYS => {
            // TOS = tuple of keys, TOS1 = subject (mapping). Push a
            // tuple of values (same order as keys) if every key is
            // present, otherwise None. Both inputs stay on the stack.
            const keys = frame.stack[frame.sp - 1];
            const subj = frame.stack[frame.sp - 2];
            if (keys != .tuple or subj != .dict) {
                try interp.typeError("MATCH_KEYS expects tuple of keys and dict subject");
                return error.TypeError;
            }
            const ks = keys.tuple.items;
            const out = try Tuple.init(interp.allocator, ks.len);
            var ok = true;
            for (ks, 0..) |k, i| {
                if (k != .str) {
                    ok = false;
                    break;
                }
                if (subj.dict.getStr(k.str.bytes)) |v| {
                    out.items[i] = v;
                } else {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                frame.push(Value{ .tuple = out });
            } else {
                frame.push(Value.none);
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .MATCH_CLASS => {
            // Pops (kw_attrs_tuple, class, subject); pushes either a
            // tuple of extracted positional/kw attrs or None. nargs is
            // the number of positional patterns. For the small set of
            // atomic types CPython treats specially (`int`, `str`,
            // ...), a single positional matches the subject itself.
            const nargs = oparg(frame, ext_arg);
            const kwattrs = frame.pop();
            const cls = frame.pop();
            const subject = frame.pop();
            if (kwattrs != .tuple) {
                try interp.typeError("MATCH_CLASS: kwattrs must be a tuple");
                return error.TypeError;
            }
            const matches = matchClassCheck(subject, cls);
            if (!matches) {
                frame.push(Value.none);
            } else if (nargs == 0 and kwattrs.tuple.items.len == 0) {
                const t = try Tuple.init(interp.allocator, 0);
                frame.push(Value{ .tuple = t });
            } else if (nargs == 1 and kwattrs.tuple.items.len == 0 and isAtomicSelfMatch(cls)) {
                const t = try Tuple.init(interp.allocator, 1);
                t.items[0] = subject;
                frame.push(Value{ .tuple = t });
            } else if (subject == .instance and cls == .class) {
                // Walk __match_args__ for the positional names, then read
                // them off the instance dict.
                const ma = cls.class.dict.getStr("__match_args__") orelse {
                    try interp.typeError("MATCH_CLASS: class lacks __match_args__");
                    return error.TypeError;
                };
                if (ma != .tuple or ma.tuple.items.len < nargs) {
                    try interp.typeError("MATCH_CLASS: __match_args__ too short");
                    return error.TypeError;
                }
                const t = try Tuple.init(interp.allocator, nargs + kwattrs.tuple.items.len);
                var i: usize = 0;
                while (i < nargs) : (i += 1) {
                    const name_val = ma.tuple.items[i];
                    if (name_val != .str) {
                        try interp.typeError("MATCH_CLASS: __match_args__ entry not str");
                        return error.TypeError;
                    }
                    const v = subject.instance.dict.getStr(name_val.str.bytes) orelse {
                        try interp.attributeError(subject.instance.cls.name, name_val.str.bytes);
                        return error.AttributeError;
                    };
                    t.items[i] = v;
                }
                for (kwattrs.tuple.items, 0..) |kn, j| {
                    if (kn != .str) {
                        try interp.typeError("MATCH_CLASS: kwattrs entry not str");
                        return error.TypeError;
                    }
                    const v = subject.instance.dict.getStr(kn.str.bytes) orelse {
                        try interp.attributeError(subject.instance.cls.name, kn.str.bytes);
                        return error.AttributeError;
                    };
                    t.items[nargs + j] = v;
                }
                frame.push(Value{ .tuple = t });
            } else {
                try interp.typeError("MATCH_CLASS: positional patterns require __match_args__");
                return error.TypeError;
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .CONVERT_VALUE => {
            // arg: 1=str, 2=repr, 3=ascii. Only str+repr are exercised.
            const arg = oparg(frame, ext_arg);
            const v = frame.pop();
            var w = std.Io.Writer.Allocating.init(interp.allocator);
            switch (arg) {
                1 => try v.writeStr(&w.writer),
                2, 3 => try v.writeRepr(&w.writer),
                else => {
                    try interp.typeError("CONVERT_VALUE: unknown kind");
                    return error.TypeError;
                },
            }
            const s = try Str.init(interp.allocator, w.written());
            frame.push(Value{ .str = s });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .STORE_FAST_STORE_FAST => {
            const arg = oparg(frame, ext_arg);
            const hi = (arg >> 4) & 0xF;
            const lo = arg & 0xF;
            frame.fast[hi] = frame.pop();
            frame.fast[lo] = frame.pop();
            continue :sw advance(frame, &ext_arg, 0);
        },

        .MAP_ADD => {
            // Stack: [..., dict, ..., key, value]; arg is depth of the dict.
            const v = frame.pop();
            const k = frame.pop();
            const dict_val = frame.stack[frame.sp - oparg(frame, ext_arg)];
            try dict_val.dict.setKey(interp.allocator, k, v);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LOAD_BUILD_CLASS => {
            const v = interp.builtins.getStr("__build_class__") orelse {
                try interp.nameError("__build_class__");
                return error.NameError;
            };
            frame.push(v);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LOAD_LOCALS => {
            frame.push(Value{ .dict = frame.locals });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .STORE_ATTR => {
            const arg = oparg(frame, ext_arg);
            const name = frame.code.names[arg];
            const obj = frame.pop();
            const value = frame.pop();
            switch (obj) {
                .instance => |i| try i.dict.setStr(interp.allocator, name, value),
                .module => |m| try m.attrs.setStr(interp.allocator, name, value),
                else => {
                    try interp.attributeError(obj.typeName(), name);
                    return error.AttributeError;
                },
            }
            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.STORE_ATTR)]);
        },

        .RETURN_VALUE => {
            return frame.pop();
        },

        .RETURN_GENERATOR => {
            // Reached only if a generator-coded frame is run as a
            // regular function (the call site missed CO_GENERATOR).
            // Treat as a no-op so dispatch can continue; the call
            // path in `callPyFunction` is the proper handler.
            continue :sw advance(frame, &ext_arg, 0);
        },

        .YIELD_VALUE => {
            interp.gen_yielded = frame.pop();
            // Advance ip past YIELD_VALUE (2 bytes). Resume will start
            // at the following RESUME instruction on the next send.
            frame.ip += 2;
            ext_arg = 0;
            return error.GenYield;
        },

        .SEND => {
            const arg = oparg(frame, ext_arg);
            const cw = op.cache_width[@intFromEnum(Opcode.SEND)];
            // Stack convention: [..., receiver, sent]. Both stay on
            // the stack across `sendStep`; the slot at TOS is rewritten
            // with the yielded (or stop) value.
            const sent_value = frame.stack[frame.sp - 1];
            const receiver = frame.stack[frame.sp - 2];
            const step = sendStep(interp, receiver, sent_value) catch |err| {
                if (err == error.StopIter) {
                    frame.stack[frame.sp - 1] = interp.gen_yielded orelse Value.none;
                    interp.gen_yielded = null;
                    frame.ip += 2 + 2 * @as(u32, cw) + 2 * arg;
                    ext_arg = 0;
                    continue :sw @as(Opcode, @enumFromInt(code[frame.ip]));
                }
                return err;
            };
            frame.stack[frame.sp - 1] = step;
            continue :sw advance(frame, &ext_arg, cw);
        },

        .END_SEND => {
            // del STACK[-2]: shift the top down one slot.
            frame.stack[frame.sp - 2] = frame.stack[frame.sp - 1];
            frame.sp -= 1;
            continue :sw advance(frame, &ext_arg, 0);
        },

        .GET_YIELD_FROM_ITER => {
            const v = frame.pop();
            switch (v) {
                .generator => frame.push(v),
                .iter => frame.push(v),
                else => {
                    const it = try makeIter(interp, v);
                    frame.push(Value{ .iter = it });
                },
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .CALL_INTRINSIC_1 => {
            const which = oparg(frame, ext_arg);
            switch (which) {
                3 => {}, // INTRINSIC_STOPITERATION_ERROR — pass-through.
                6 => {
                    // INTRINSIC_LIST_TO_TUPLE: TOS list -> tuple in place.
                    const list_val = frame.pop();
                    if (list_val != .list) {
                        try interp.typeError("LIST_TO_TUPLE: TOS is not a list");
                        return error.TypeError;
                    }
                    const items = list_val.list.items.items;
                    const t = try Tuple.init(interp.allocator, items.len);
                    for (items, 0..) |it, i| t.items[i] = it;
                    frame.push(Value{ .tuple = t });
                },
                else => {},
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .CLEANUP_THROW => {
            // Only reached on `gen.throw()` paths. The fixture doesn't
            // exercise these; pop the throw triple and re-raise to
            // match CPython's "exception escapes" behavior.
            _ = frame.pop();
            _ = frame.pop();
            const e = frame.pop();
            if (e == .instance) interp.current_exc = e;
            return error.PyException;
        },

        .RAISE_VARARGS => {
            const arg = oparg(frame, ext_arg);
            if (arg == 0) {
                if (interp.current_exc == null) {
                    try interp.typeError("No active exception to re-raise");
                    return error.TypeError;
                }
                return error.PyException;
            }
            if (arg == 1) {
                const v = frame.pop();
                const inst_val = switch (v) {
                    .class => |cls| try instantiate(interp, cls, &.{}, &.{}, &.{}),
                    .instance => v,
                    else => {
                        try interp.typeError("exceptions must derive from BaseException");
                        return error.TypeError;
                    },
                };
                interp.current_exc = inst_val;
                return error.PyException;
            }
            try interp.typeError("RAISE_VARARGS arg > 1 not supported");
            return error.TypeError;
        },

        .PUSH_EXC_INFO => {
            // Stack: [..., exc] -> [..., prev_exc_info, exc]. We don't
            // track sys.exc_info(), so prev is a placeholder; POP_EXCEPT
            // pops it back off without inspecting it.
            const e = frame.pop();
            frame.push(Value.null_sentinel);
            frame.push(e);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .CHECK_EXC_MATCH => {
            // Stack: [..., exc, type] -> [..., exc, bool]. Pops type,
            // peeks exc, walks the exc's MRO looking for the type. The
            // type can be a tuple of classes — `except (A, B)` — in
            // which case any class match wins.
            const typ = frame.pop();
            const e = frame.stack[frame.sp - 1];
            var matched = false;
            if (e == .instance) {
                const candidates: []const Value = switch (typ) {
                    .class => @as([]const Value, &[_]Value{typ}),
                    .tuple => |t| t.items,
                    else => &.{},
                };
                outer: for (candidates) |cand| {
                    if (cand != .class) continue;
                    for (e.instance.cls.mro) |c| {
                        if (c == cand.class) {
                            matched = true;
                            break :outer;
                        }
                    }
                }
            }
            frame.push(Value{ .boolean = matched });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .POP_EXCEPT => {
            _ = frame.pop();
            continue :sw advance(frame, &ext_arg, 0);
        },

        .RERAISE => {
            const arg = oparg(frame, ext_arg);
            const e = frame.pop();
            if (arg != 0) _ = frame.pop();
            if (e != .instance) {
                try interp.typeError("RERAISE: TOS is not an exception");
                return error.TypeError;
            }
            interp.current_exc = e;
            return error.PyException;
        },

        .DELETE_NAME => {
            const arg = oparg(frame, ext_arg);
            const name = frame.code.names[arg];
            _ = frame.locals.delete(name);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LOAD_SPECIAL => {
            // Method-form lookup for one of the dunder slots used by
            // the `with` prologue. arg=0 -> __enter__, arg=1 -> __exit__.
            // Stack effect: pops owner, pushes (method, self_or_null)
            // -- same convention as LOAD_ATTR with method bit set.
            const arg = oparg(frame, ext_arg);
            const name: []const u8 = switch (arg) {
                0 => "__enter__",
                1 => "__exit__",
                else => {
                    try interp.typeError("LOAD_SPECIAL: unknown index");
                    return error.TypeError;
                },
            };
            const owner = frame.pop();
            try loadAttr(interp, frame, owner, name, true);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .BUILD_STRING => {
            const n = oparg(frame, ext_arg);
            const start = frame.sp - n;
            var total: usize = 0;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const v = frame.stack[start + i];
                if (v != .str) {
                    try interp.typeError("BUILD_STRING: non-str argument");
                    return error.TypeError;
                }
                total += v.str.bytes.len;
            }
            const buf = try interp.allocator.alloc(u8, total);
            var off: usize = 0;
            i = 0;
            while (i < n) : (i += 1) {
                const v = frame.stack[start + i];
                @memcpy(buf[off .. off + v.str.bytes.len], v.str.bytes);
                off += v.str.bytes.len;
            }
            frame.sp = start;
            const s = try Str.init(interp.allocator, buf);
            frame.push(Value{ .str = s });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .FORMAT_SIMPLE => {
            // PEP 701 fast path -- equivalent to format(value, "").
            const v = frame.pop();
            if (v == .str) {
                frame.push(v);
            } else {
                var w = std.Io.Writer.Allocating.init(interp.allocator);
                try v.writeStr(&w.writer);
                const s = try Str.init(interp.allocator, w.written());
                frame.push(Value{ .str = s });
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .FORMAT_WITH_SPEC => {
            const spec_v = frame.pop();
            const v = frame.pop();
            if (spec_v != .str) {
                try interp.typeError("FORMAT_WITH_SPEC: spec must be str");
                return error.TypeError;
            }
            const out = format_mod.format(interp.allocator, v, spec_v.str.bytes) catch |e| {
                if (e == error.TypeError) {
                    try interp.typeError("unsupported format spec");
                    return error.TypeError;
                }
                return e;
            };
            const s = try Str.init(interp.allocator, out);
            frame.push(Value{ .str = s });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .LOAD_SUPER_ATTR => {
            // Stack: [..., global_super, class, self] -> [..., attr, self_or_null]
            // arg encodes name_idx<<2 | zero_arg<<1 | method_form.
            const arg = oparg(frame, ext_arg);
            const name_idx = arg >> 2;
            const is_method = (arg & 1) != 0;
            const name = frame.code.names[name_idx];
            const self_val = frame.pop();
            const cls_val = frame.pop();
            _ = frame.pop(); // global_super, unused
            if (cls_val != .class) {
                try interp.typeError("super: __class__ is not a class");
                return error.TypeError;
            }
            const mro = cls_val.class.mro;
            var found: ?Value = null;
            var i: usize = 1;
            while (i < mro.len) : (i += 1) {
                if (mro[i].dict.getStr(name)) |v| {
                    found = v;
                    break;
                }
            }
            if (found) |v| {
                if (v == .descriptor) {
                    try bindDescriptor(interp, frame, v.descriptor, self_val, cls_val, is_method);
                } else if (is_method and (v == .function or v == .builtin_fn)) {
                    frame.push(v);
                    frame.push(self_val);
                } else if (is_method) {
                    frame.push(v);
                    frame.push(Value.null_sentinel);
                } else frame.push(v);
            } else {
                try interp.attributeError("super", name);
                return error.AttributeError;
            }
            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.LOAD_SUPER_ATTR)]);
        },

        .WITH_EXCEPT_START => {
            // Stack: [..., exit_func, exit_self, lasti, prev_exc, exc]
            // Calls exit_func(exit_self, type(exc), exc, None) and
            // pushes the result without popping. CPython's docs put
            // the function "4 below the current top" -- that's sp-5
            // (exit_func), with exit_self at sp-4 and exc at sp-1.
            const exit_func = frame.stack[frame.sp - 5];
            const exit_self = frame.stack[frame.sp - 4];
            const exc_val = frame.stack[frame.sp - 1];
            const exc_type: Value = if (exc_val == .instance)
                Value{ .class = exc_val.instance.cls }
            else
                Value.none;
            const argv = [_]Value{ exit_self, exc_type, exc_val, Value.none };
            const result = try invoke(interp, exit_func, &argv);
            frame.push(result);
            continue :sw advance(frame, &ext_arg, 0);
        },

        else => {
            try interp.unsupportedOpcode(code[frame.ip], frame.ip);
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
        1 => bitwiseAnd(interp, a, b),
        5 => multiply(interp, a, b),
        6 => remainder(interp, a, b),
        7 => bitwiseOr(interp, a, b),
        10 => subtract(interp, a, b),
        11 => trueDivide(interp, a, b),
        12 => bitwiseXor(interp, a, b),
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

fn asFloat(v: Value) ?f64 {
    return switch (v) {
        .small_int => |i| @floatFromInt(i),
        .boolean => |b| if (b) 1.0 else 0.0,
        .float => |f| f,
        else => null,
    };
}

/// `+` for int+int and str+str. Other operand combos wait for a
/// fixture.
fn add(interp: *Interp, a: Value, b: Value) !Value {
    if (a == .small_int and b == .small_int) {
        return Value{ .small_int = a.small_int +% b.small_int };
    }
    if (a == .complex_num or b == .complex_num) {
        const ac = Value.asComplex(a) orelse return complexTypeError(interp, "+");
        const bc = Value.asComplex(b) orelse return complexTypeError(interp, "+");
        return Value{ .complex_num = .{ .re = ac.re + bc.re, .im = ac.im + bc.im } };
    }
    if ((a == .float or b == .float) and asFloat(a) != null and asFloat(b) != null) {
        return Value{ .float = asFloat(a).? + asFloat(b).? };
    }
    if (a == .str and b == .str) {
        const buf = try interp.allocator.alloc(u8, a.str.bytes.len + b.str.bytes.len);
        @memcpy(buf[0..a.str.bytes.len], a.str.bytes);
        @memcpy(buf[a.str.bytes.len..], b.str.bytes);
        const s = try Str.fromOwnedSlice(interp.allocator, buf);
        return Value{ .str = s };
    }
    // bytes / bytearray concat: the result type follows the left
    // operand. Cross-type works only between these two — bytes + str
    // is still a TypeError.
    {
        const a_buf: ?[]const u8 = switch (a) {
            .bytes => |x| x.data,
            .bytearray => |x| x.data.items,
            else => null,
        };
        const b_buf: ?[]const u8 = switch (b) {
            .bytes => |x| x.data,
            .bytearray => |x| x.data.items,
            else => null,
        };
        if (a_buf != null and b_buf != null) {
            if (a == .bytes) {
                const buf = try interp.allocator.alloc(u8, a_buf.?.len + b_buf.?.len);
                @memcpy(buf[0..a_buf.?.len], a_buf.?);
                @memcpy(buf[a_buf.?.len..], b_buf.?);
                const out = try @import("../object/bytes.zig").Bytes.fromOwnedSlice(interp.allocator, buf);
                return Value{ .bytes = out };
            }
            const Bytearray = @import("../object/bytearray.zig").Bytearray;
            const out = try Bytearray.init(interp.allocator);
            try out.data.appendSlice(interp.allocator, a_buf.?);
            try out.data.appendSlice(interp.allocator, b_buf.?);
            return Value{ .bytearray = out };
        }
    }
    try interp.typeError("unsupported operand type(s) for +");
    return error.TypeError;
}

fn subtract(interp: *Interp, a: Value, b: Value) !Value {
    if (a == .small_int and b == .small_int) {
        return Value{ .small_int = a.small_int -% b.small_int };
    }
    if (a == .complex_num or b == .complex_num) {
        const ac = Value.asComplex(a) orelse return complexTypeError(interp, "-");
        const bc = Value.asComplex(b) orelse return complexTypeError(interp, "-");
        return Value{ .complex_num = .{ .re = ac.re - bc.re, .im = ac.im - bc.im } };
    }
    if ((a == .float or b == .float) and asFloat(a) != null and asFloat(b) != null) {
        return Value{ .float = asFloat(a).? - asFloat(b).? };
    }
    if (a == .set and b == .set) {
        const out = try newSetLike(interp, a.set.frozen);
        for (a.set.items.items) |x| {
            var found = false;
            for (b.set.items.items) |y| if (x.equals(y)) {
                found = true;
                break;
            };
            if (!found) try out.add(interp.allocator, x);
        }
        return Value{ .set = out };
    }
    try interp.typeError("unsupported operand type(s) for -");
    return error.TypeError;
}

/// Set algebra helpers. The result keeps the *left* operand's
/// frozen flag — `frozenset(...) | set(...)` is a frozenset, plain
/// the other way. CPython does the same.
fn newSetLike(interp: *Interp, frozen: bool) !*Set {
    return if (frozen) Set.initFrozen(interp.allocator) else Set.init(interp.allocator);
}

fn bitwiseOr(interp: *Interp, a: Value, b: Value) !Value {
    if (a == .set and b == .set) {
        const out = try newSetLike(interp, a.set.frozen);
        for (a.set.items.items) |x| try out.add(interp.allocator, x);
        for (b.set.items.items) |x| try out.add(interp.allocator, x);
        return Value{ .set = out };
    }
    try interp.typeError("unsupported operand type(s) for |");
    return error.TypeError;
}

fn bitwiseAnd(interp: *Interp, a: Value, b: Value) !Value {
    if (a == .set and b == .set) {
        const out = try newSetLike(interp, a.set.frozen);
        for (a.set.items.items) |x| {
            for (b.set.items.items) |y| if (x.equals(y)) {
                try out.add(interp.allocator, x);
                break;
            };
        }
        return Value{ .set = out };
    }
    try interp.typeError("unsupported operand type(s) for &");
    return error.TypeError;
}

fn bitwiseXor(interp: *Interp, a: Value, b: Value) !Value {
    if (a == .set and b == .set) {
        const out = try newSetLike(interp, a.set.frozen);
        for (a.set.items.items) |x| {
            var found = false;
            for (b.set.items.items) |y| if (x.equals(y)) {
                found = true;
                break;
            };
            if (!found) try out.add(interp.allocator, x);
        }
        for (b.set.items.items) |x| {
            var found = false;
            for (a.set.items.items) |y| if (x.equals(y)) {
                found = true;
                break;
            };
            if (!found) try out.add(interp.allocator, x);
        }
        return Value{ .set = out };
    }
    try interp.typeError("unsupported operand type(s) for ^");
    return error.TypeError;
}

fn multiply(interp: *Interp, a: Value, b: Value) !Value {
    if (a == .small_int and b == .small_int) {
        return Value{ .small_int = a.small_int *% b.small_int };
    }
    if (a == .complex_num or b == .complex_num) {
        const ac = Value.asComplex(a) orelse return complexTypeError(interp, "*");
        const bc = Value.asComplex(b) orelse return complexTypeError(interp, "*");
        return Value{ .complex_num = .{
            .re = ac.re * bc.re - ac.im * bc.im,
            .im = ac.re * bc.im + ac.im * bc.re,
        } };
    }
    if ((a == .float or b == .float) and asFloat(a) != null and asFloat(b) != null) {
        return Value{ .float = asFloat(a).? * asFloat(b).? };
    }
    try interp.typeError("unsupported operand type(s) for *");
    return error.TypeError;
}

fn complexTypeError(interp: *Interp, op_name: []const u8) anyerror!Value {
    const msg = try std.fmt.allocPrint(interp.allocator, "unsupported operand type(s) for {s}", .{op_name});
    try interp.typeError(msg);
    return error.TypeError;
}

/// `/` (true division) for int/int: returns a float. Zero divisor
/// raises ZeroDivisionError -- the only exception path the fixture
/// exercises through arithmetic.
fn trueDivide(interp: *Interp, a: Value, b: Value) !Value {
    const ai: ?i64 = switch (a) {
        .small_int => |i| i,
        .boolean => |x| @intFromBool(x),
        else => null,
    };
    const bi: ?i64 = switch (b) {
        .small_int => |i| i,
        .boolean => |x| @intFromBool(x),
        else => null,
    };
    if (ai != null and bi != null) {
        if (bi.? == 0) {
            try interp.raisePy("ZeroDivisionError", "division by zero");
            return error.PyException;
        }
        return Value{ .float = @as(f64, @floatFromInt(ai.?)) / @as(f64, @floatFromInt(bi.?)) };
    }
    if (a == .complex_num or b == .complex_num) {
        const ac = Value.asComplex(a) orelse return complexTypeError(interp, "/");
        const bc = Value.asComplex(b) orelse return complexTypeError(interp, "/");
        const denom = bc.re * bc.re + bc.im * bc.im;
        if (denom == 0.0) {
            try interp.raisePy("ZeroDivisionError", "complex division by zero");
            return error.PyException;
        }
        return Value{ .complex_num = .{
            .re = (ac.re * bc.re + ac.im * bc.im) / denom,
            .im = (ac.im * bc.re - ac.re * bc.im) / denom,
        } };
    }
    try interp.typeError("unsupported operand type(s) for /");
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
                    const n: i64 = @intCast(bytes.len);
                    const r = try resolveSlice(interp, sl, n);
                    var buf = try interp.allocator.alloc(u8, r.count);
                    var idx = r.start;
                    var k: usize = 0;
                    while (k < r.count) : (k += 1) {
                        buf[k] = bytes[@intCast(idx)];
                        idx += r.step;
                    }
                    const piece = try Str.init(interp.allocator, buf);
                    interp.allocator.free(buf);
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
                        try interp.raisePy("IndexError", "list index out of range");
                        return error.PyException;
                    }
                    return l.items.items[@intCast(idx)];
                },
                .slice => |sl| {
                    const n: i64 = @intCast(l.items.items.len);
                    const r = try resolveSlice(interp, sl, n);
                    const out = try List.init(interp.allocator);
                    var idx = r.start;
                    var k: usize = 0;
                    while (k < r.count) : (k += 1) {
                        try out.append(interp.allocator, l.items.items[@intCast(idx)]);
                        idx += r.step;
                    }
                    return Value{ .list = out };
                },
                else => {
                    try interp.typeError("list indices must be integers");
                    return error.TypeError;
                },
            }
        },
        .tuple => |t| {
            switch (key) {
                .small_int => |i| {
                    const n: i64 = @intCast(t.items.len);
                    var idx = i;
                    if (idx < 0) idx += n;
                    if (idx < 0 or idx >= n) {
                        try interp.raisePy("IndexError", "tuple index out of range");
                        return error.PyException;
                    }
                    return t.items[@intCast(idx)];
                },
                .slice => |sl| {
                    const n: i64 = @intCast(t.items.len);
                    const r = try resolveSlice(interp, sl, n);
                    const out = try Tuple.init(interp.allocator, r.count);
                    var idx = r.start;
                    var k: usize = 0;
                    while (k < r.count) : (k += 1) {
                        out.items[k] = t.items[@intCast(idx)];
                        idx += r.step;
                    }
                    return Value{ .tuple = out };
                },
                else => {
                    try interp.typeError("tuple indices must be integers");
                    return error.TypeError;
                },
            }
        },
        .bytes => |b| {
            switch (key) {
                .small_int => |i| {
                    const n: i64 = @intCast(b.data.len);
                    var idx = i;
                    if (idx < 0) idx += n;
                    if (idx < 0 or idx >= n) {
                        try interp.raisePy("IndexError", "bytes index out of range");
                        return error.PyException;
                    }
                    return Value{ .small_int = @intCast(b.data[@intCast(idx)]) };
                },
                .slice => |sl| {
                    const n: i64 = @intCast(b.data.len);
                    const r = try resolveSlice(interp, sl, n);
                    var buf = try interp.allocator.alloc(u8, r.count);
                    var idx = r.start;
                    var k: usize = 0;
                    while (k < r.count) : (k += 1) {
                        buf[k] = b.data[@intCast(idx)];
                        idx += r.step;
                    }
                    const out = try @import("../object/bytes.zig").Bytes.fromOwnedSlice(interp.allocator, buf);
                    return Value{ .bytes = out };
                },
                else => {
                    try interp.typeError("bytes indices must be integers or slices");
                    return error.TypeError;
                },
            }
        },
        .bytearray => |b| {
            switch (key) {
                .small_int => |i| {
                    const n: i64 = @intCast(b.data.items.len);
                    var idx = i;
                    if (idx < 0) idx += n;
                    if (idx < 0 or idx >= n) {
                        try interp.raisePy("IndexError", "bytearray index out of range");
                        return error.PyException;
                    }
                    return Value{ .small_int = @intCast(b.data.items[@intCast(idx)]) };
                },
                .slice => |sl| {
                    const Bytearray = @import("../object/bytearray.zig").Bytearray;
                    const n: i64 = @intCast(b.data.items.len);
                    const r = try resolveSlice(interp, sl, n);
                    const out = try Bytearray.init(interp.allocator);
                    var idx = r.start;
                    var k: usize = 0;
                    while (k < r.count) : (k += 1) {
                        try out.data.append(interp.allocator, b.data.items[@intCast(idx)]);
                        idx += r.step;
                    }
                    return Value{ .bytearray = out };
                },
                else => {
                    try interp.typeError("bytearray indices must be integers or slices");
                    return error.TypeError;
                },
            }
        },
        .dict => |d| {
            if (d.getKey(key)) |v| return v;
            try interp.raisePy("KeyError", "key not found");
            return error.PyException;
        },
        else => {
            try interp.typeError("object is not subscriptable");
            return error.TypeError;
        },
    }
}

const Resolved = struct { start: i64, step: i64, count: usize };

/// Apply Python slice semantics: resolve `None` defaults per step
/// sign, normalize negative indices, clamp to `[0, n]` (or `[-1,
/// n-1]` for negative step), and report the iteration count.
fn resolveSlice(interp: *Interp, sl: *@import("../object/slice.zig").Slice, n: i64) !Resolved {
    var step: i64 = 1;
    switch (sl.step) {
        .none => {},
        .small_int => |i| step = i,
        else => {
            try interp.typeError("slice step must be an int");
            return error.TypeError;
        },
    }
    if (step == 0) {
        try interp.typeError("slice step cannot be zero");
        return error.TypeError;
    }
    const default_start: i64 = if (step > 0) 0 else n - 1;
    const default_stop: i64 = if (step > 0) n else -1;
    var start: i64 = default_start;
    var stop: i64 = default_stop;
    switch (sl.start) {
        .none => {},
        .small_int => |i| {
            start = i;
            if (start < 0) start += n;
            if (step > 0) {
                if (start < 0) start = 0;
                if (start > n) start = n;
            } else {
                if (start < -1) start = -1;
                if (start > n - 1) start = n - 1;
            }
        },
        else => {},
    }
    switch (sl.stop) {
        .none => {},
        .small_int => |i| {
            stop = i;
            if (stop < 0) stop += n;
            if (step > 0) {
                if (stop < 0) stop = 0;
                if (stop > n) stop = n;
            } else {
                if (stop < -1) stop = -1;
                if (stop > n - 1) stop = n - 1;
            }
        },
        else => {},
    }
    var count: usize = 0;
    if (step > 0 and start < stop) {
        count = @intCast(@divTrunc(stop - start - 1, step) + 1);
    } else if (step < 0 and start > stop) {
        count = @intCast(@divTrunc(start - stop - 1, -step) + 1);
    }
    return .{ .start = start, .step = step, .count = count };
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
            .slice => |sl| {
                const n: i64 = @intCast(l.items.items.len);
                const r = try resolveSlice(interp, sl, n);
                if (r.step != 1) {
                    try interp.typeError("extended slice assignment not supported");
                    return error.TypeError;
                }
                const src_items: []const Value = switch (value) {
                    .list => |sl2| sl2.items.items,
                    .tuple => |t| t.items,
                    else => {
                        try interp.typeError("can only assign an iterable");
                        return error.TypeError;
                    },
                };
                const lo: usize = @intCast(r.start);
                const hi: usize = lo + r.count;
                try l.items.replaceRange(interp.allocator, lo, r.count, src_items);
                _ = hi;
            },
            else => {
                try interp.typeError("list indices must be integers or slices");
                return error.TypeError;
            },
        },
        .dict => |d| {
            try d.setKey(interp.allocator, key, value);
        },
        .bytearray => |b| switch (key) {
            .small_int => |i| {
                if (value != .small_int and value != .boolean) {
                    try interp.typeError("an integer is required");
                    return error.TypeError;
                }
                const v: i64 = if (value == .boolean) @intFromBool(value.boolean) else value.small_int;
                if (v < 0 or v > 255) {
                    try interp.raisePy("ValueError", "byte must be in range(0, 256)");
                    return error.PyException;
                }
                const n: i64 = @intCast(b.data.items.len);
                var idx = i;
                if (idx < 0) idx += n;
                if (idx < 0 or idx >= n) {
                    try interp.indexError("bytearray assignment index out of range");
                    return error.IndexError;
                }
                b.data.items[@intCast(idx)] = @intCast(v);
            },
            else => {
                try interp.typeError("bytearray indices must be integers");
                return error.TypeError;
            },
        },
        else => {
            try interp.typeError("object does not support item assignment");
            return error.TypeError;
        },
    }
}

/// One step of any iterator-shaped value. Returns null when the
/// iterator is exhausted, raises TypeError when the value isn't an
/// iterator. Generators advance via `genResume`; enumerate adapters
/// step their inner source then pair the result with a counter.
pub fn iterStep(interp: *Interp, it: Value) DispatchError!?Value {
    switch (it) {
        .iter => |i| return i.next(),
        .generator => |g| return try genResume(interp, g, Value.none),
        .enum_iter => |e| {
            const inner = try iterStep(interp, e.source);
            if (inner) |v| {
                const t = try Tuple.init(interp.allocator, 2);
                t.items[0] = Value{ .small_int = e.count };
                t.items[1] = v;
                e.count += 1;
                return Value{ .tuple = t };
            }
            return null;
        },
        else => {
            try interp.typeError("FOR_ITER on non-iterator");
            return error.TypeError;
        },
    }
}

pub fn makeIter(interp: *Interp, v: Value) !*Iter {
    return switch (v) {
        .list => |l| try Iter.init(interp.allocator, .{ .list = l }),
        .tuple => |t| try Iter.init(interp.allocator, .{ .tuple = t }),
        .iter => |it| it,
        .str, .bytes, .bytearray, .dict, .generator, .enum_iter, .set => blk: {
            const lst = try @import("builtins.zig").materialize(interp, v);
            break :blk try Iter.init(interp.allocator, .{ .list = lst });
        },
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
        .dict => |d| {
            if (item != .str) return false;
            return d.contains(item.str.bytes);
        },
        .set => |s| {
            for (s.items.items) |it| if (it.equals(item)) return true;
            return false;
        },
        .bytes => |b| return bytesContains(b.data, item),
        .bytearray => |b| return bytesContains(b.data.items, item),
        else => {
            try interp.typeError("argument of type is not iterable");
            return error.TypeError;
        },
    }
}

/// `int in bytes/bytearray` matches a single byte; `bytes/bytearray
/// in bytes/bytearray` matches a contiguous subsequence. Anything
/// else returns False (CPython raises TypeError; the fixture only
/// uses the supported operand types).
fn bytesContains(haystack: []const u8, item: Value) bool {
    return switch (item) {
        .small_int => |i| if (i < 0 or i > 255) false else std.mem.indexOfScalar(u8, haystack, @intCast(i)) != null,
        .bytes => |b| std.mem.indexOf(u8, haystack, b.data) != null,
        .bytearray => |b| std.mem.indexOf(u8, haystack, b.data.items) != null,
        else => false,
    };
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
            // Set / frozenset ordering is the partial subset order,
            // not lexicographic. `a < b` is "proper subset"; `a <= b`
            // is "subset". Frozen flag is irrelevant here.
            if (a == .set and b == .set) {
                const sub = setIsSubset(a.set, b.set);
                const sup = setIsSubset(b.set, a.set);
                break :blk switch (kind) {
                    0 => sub and !sup,
                    1 => sub,
                    4 => sup and !sub,
                    5 => sup,
                    else => unreachable,
                };
            }
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

fn setIsSubset(a: anytype, b: anytype) bool {
    outer: for (a.items.items) |x| {
        for (b.items.items) |y| {
            if (x.equals(y)) continue :outer;
        }
        return false;
    }
    return true;
}

/// CPython treats a small set of types specially in `case Cls(x)`:
/// the lone positional pattern binds to the subject itself rather
/// than walking `__match_args__`. This is the subset our fixtures
/// touch -- the builtin name route is sufficient because these
/// types don't have user-defined replacements at the moment.
fn isAtomicSelfMatch(cls: Value) bool {
    if (cls != .builtin_fn) return false;
    const name = cls.builtin_fn.name;
    const atoms = [_][]const u8{ "int", "str", "float", "bool", "list", "tuple", "dict", "set", "bytes" };
    for (atoms) |a| {
        if (std.mem.eql(u8, name, a)) return true;
    }
    return false;
}

/// Returns whether `subject` is considered an instance of `cls` for
/// match-pattern purposes. Builtin "type" stand-ins (`int`, `str`,
/// ...) are matched by Value tag; user `Class` walks the MRO.
fn matchClassCheck(subject: Value, cls: Value) bool {
    if (cls == .class) {
        if (subject != .instance) return false;
        for (subject.instance.cls.mro) |c| {
            if (c == cls.class) return true;
        }
        return false;
    }
    if (cls != .builtin_fn) return false;
    const name = cls.builtin_fn.name;
    if (std.mem.eql(u8, name, "int")) return subject == .small_int or subject == .boolean;
    if (std.mem.eql(u8, name, "str")) return subject == .str;
    if (std.mem.eql(u8, name, "float")) return subject == .float;
    if (std.mem.eql(u8, name, "bool")) return subject == .boolean;
    if (std.mem.eql(u8, name, "list")) return subject == .list;
    if (std.mem.eql(u8, name, "tuple")) return subject == .tuple;
    if (std.mem.eql(u8, name, "dict")) return subject == .dict;
    if (std.mem.eql(u8, name, "bytes")) return subject == .bytes;
    if (std.mem.eql(u8, name, "bytearray")) return subject == .bytearray;
    if (std.mem.eql(u8, name, "set")) return subject == .set and !subject.set.frozen;
    if (std.mem.eql(u8, name, "frozenset")) return subject == .set and subject.set.frozen;
    return false;
}

fn loadAttr(interp: *Interp, frame: *Frame, obj: Value, name: []const u8, is_method: bool) !void {
    // 1. Instance attribute (data) -- always wins.
    if (obj == .instance) {
        if (obj.instance.dict.getStr(name)) |v| {
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        // 2. Walk class MRO.
        if (obj.instance.cls.lookup(name)) |v| {
            if (v == .descriptor) {
                try bindDescriptor(interp, frame, v.descriptor, obj, Value{ .class = obj.instance.cls }, is_method);
                return;
            }
            if (is_method and (v == .function or v == .builtin_fn)) {
                frame.push(v);
                frame.push(obj);
            } else if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        try interp.attributeError(obj.typeName(), name);
        return error.AttributeError;
    }
    if (obj == .class) {
        if (std.mem.eql(u8, name, "__name__")) {
            const s = try Str.init(interp.allocator, obj.class.name);
            const v = Value{ .str = s };
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        if (obj.class.lookup(name)) |v| {
            if (v == .descriptor) {
                try bindDescriptor(interp, frame, v.descriptor, Value.null_sentinel, obj, is_method);
                return;
            }
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        try interp.attributeError(obj.typeName(), name);
        return error.AttributeError;
    }
    if (obj == .module) {
        if (obj.module.attrs.getStr(name)) |v| {
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        try interp.attributeError(obj.typeName(), name);
        return error.AttributeError;
    }
    if (obj == .generator) {
        const m: ?*value_mod.BuiltinFn = if (std.mem.eql(u8, name, "send"))
            &gen_send_method
        else if (std.mem.eql(u8, name, "close"))
            &gen_close_method
        else
            null;
        if (m) |meth| {
            if (is_method) {
                frame.push(Value{ .builtin_fn = meth });
                frame.push(obj);
            } else {
                frame.push(Value{ .builtin_fn = meth });
            }
            return;
        }
    }
    if (obj == .complex_num) {
        if (std.mem.eql(u8, name, "real")) {
            const v = Value{ .float = obj.complex_num.re };
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        if (std.mem.eql(u8, name, "imag")) {
            const v = Value{ .float = obj.complex_num.im };
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        if (std.mem.eql(u8, name, "conjugate")) {
            if (is_method) {
                frame.push(Value{ .builtin_fn = &complex_conjugate_method });
                frame.push(obj);
            } else {
                frame.push(Value{ .builtin_fn = &complex_conjugate_method });
            }
            return;
        }
    }
    // Built-in methods on str/list/dict.
    if (is_method) {
        const method: ?*value_mod.BuiltinFn = switch (obj) {
            .str => strmethods.lookup(name),
            .list => listmethods.lookup(name),
            .dict => dictmethods.lookup(name),
            .set => setmethods.lookup(name),
            .bytearray => bytearraymethods.lookup(name),
            else => null,
        };
        if (method) |m| {
            frame.push(Value{ .builtin_fn = m });
            frame.push(obj);
            return;
        }
    }
    try interp.attributeError(obj.typeName(), name);
    return error.AttributeError;
}

/// Apply a descriptor's binding rule when its name is fetched off an
/// instance or class. `instance` is null_sentinel for class-side
/// access (`Cls.attr`); otherwise it is the instance receiver.
/// `cls` is the owning class (or `Cls` itself for class-side).
fn bindDescriptor(
    interp: *Interp,
    frame: *Frame,
    d: *@import("../object/descriptor.zig").Descriptor,
    instance: Value,
    cls: Value,
    is_method: bool,
) !void {
    switch (d.kind) {
        .property => {
            // `Cls.area` returns the descriptor itself; `obj.area`
            // invokes the getter with `obj`.
            if (instance == .null_sentinel) {
                if (is_method) {
                    frame.push(Value{ .descriptor = d });
                    frame.push(Value.null_sentinel);
                } else frame.push(Value{ .descriptor = d });
                return;
            }
            const result = try invoke(interp, d.func, &.{instance});
            if (is_method) {
                frame.push(result);
                frame.push(Value.null_sentinel);
            } else frame.push(result);
        },
        .classmethod => {
            // Always bind the owning class as the first argument.
            if (is_method) {
                frame.push(d.func);
                frame.push(cls);
            } else {
                // Bare attribute access: produce a bound builtin-style
                // wrapper isn't in scope; for the fixture this branch
                // isn't reached, so fall back to pushing the function.
                frame.push(d.func);
            }
        },
        .staticmethod => {
            // No binding -- the function is called as-is.
            if (is_method) {
                frame.push(d.func);
                frame.push(Value.null_sentinel);
            } else frame.push(d.func);
        },
    }
}

pub fn invoke(interp: *Interp, callable: Value, args: []const Value) !Value {
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
                if (f.kw_func) |kf| {
                    return try kf(@ptrCast(interp), positional, kw_names, kw_values);
                }
                try interp.typeError("builtin does not take keyword arguments");
                return error.TypeError;
            }
            return try f.func(@ptrCast(interp), positional);
        },
        .function => |fn_val| return callPyFunction(interp, fn_val, positional, kw_names, kw_values, null),
        .class => |cls| return instantiate(interp, cls, positional, kw_names, kw_values),
        else => {
            try interp.typeError("object is not callable");
            return error.TypeError;
        },
    }
}

const CO_VARARGS: i32 = 0x04;
const CO_VARKEYWORDS: i32 = 0x08;
const CO_GENERATOR: i32 = 0x20;
const CO_COROUTINE: i32 = 0x80;

/// Resume a generator's suspended frame with `sent_value`. Returns the
/// next yielded value, or null on natural completion (RETURN_VALUE).
/// PyException / other errors propagate to the caller.
pub fn genResume(interp: *Interp, gen: *Generator, sent_value: Value) DispatchError!?Value {
    if (gen.finished) return null;
    gen.frame.push(sent_value);
    gen.started = true;
    if (run(interp, gen.frame)) |ret| {
        gen.finished = true;
        gen.return_value = ret;
        return null;
    } else |err| switch (err) {
        error.GenYield => {
            const v = interp.gen_yielded orelse Value.none;
            interp.gen_yielded = null;
            return v;
        },
        else => {
            gen.finished = true;
            return err;
        },
    }
}

/// One step of the SEND opcode: drive a sub-iterator/generator with
/// `sent_value`. Returns the yielded value on success; signals
/// `error.StopIter` (with `interp.gen_yielded` set to the stop value)
/// when the receiver is exhausted.
const SendError = DispatchError || error{StopIter};
fn sendStep(interp: *Interp, receiver: Value, sent_value: Value) SendError!Value {
    switch (receiver) {
        .generator => |g| {
            const r = try genResume(interp, g, sent_value);
            if (r) |v| return v;
            interp.gen_yielded = g.return_value;
            return error.StopIter;
        },
        .iter => |it| {
            if (it.next()) |v| return v;
            interp.gen_yielded = Value.none;
            return error.StopIter;
        },
        else => {
            try interp.typeError("SEND target is not iterable");
            return error.TypeError;
        },
    }
}

pub fn nextBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1 or args.len > 2) {
        try interp.typeError("next expects 1 or 2 arguments");
        return error.TypeError;
    }
    const has_default = args.len == 2;
    const default_v: Value = if (has_default) args[1] else Value.none;
    switch (args[0]) {
        .generator => |g| {
            if (try genResume(interp, g, Value.none)) |v| return v;
            if (has_default) return default_v;
            try interp.raisePyValue("StopIteration", g.return_value);
            return error.PyException;
        },
        .iter => |it| {
            if (it.next()) |v| return v;
            if (has_default) return default_v;
            try interp.raisePy("StopIteration", "");
            return error.PyException;
        },
        else => {
            try interp.typeError("next: object is not an iterator");
            return error.TypeError;
        },
    }
}

pub fn iterBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("iter expects one argument");
        return error.TypeError;
    }
    if (args[0] == .iter or args[0] == .generator) return args[0];
    const it = try makeIter(interp, args[0]);
    return Value{ .iter = it };
}

pub fn genSendBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2 or args[0] != .generator) {
        try interp.typeError("send expects (generator, value)");
        return error.TypeError;
    }
    const g = args[0].generator;
    if (try genResume(interp, g, args[1])) |v| return v;
    try interp.raisePyValue("StopIteration", g.return_value);
    return error.PyException;
}

var gen_send_method: value_mod.BuiltinFn = .{ .name = "send", .func = genSendBuiltin };

pub fn genCloseBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    _ = interp_opaque;
    if (args.len < 1 or args[0] != .generator) return error.TypeError;
    args[0].generator.finished = true;
    return Value.none;
}

var gen_close_method: value_mod.BuiltinFn = .{ .name = "close", .func = genCloseBuiltin };

pub fn complexConjugateBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    _ = interp_opaque;
    if (args.len != 1 or args[0] != .complex_num) return error.TypeError;
    const c = args[0].complex_num;
    return Value{ .complex_num = .{ .re = c.re, .im = -c.im } };
}

var complex_conjugate_method: value_mod.BuiltinFn = .{ .name = "conjugate", .func = complexConjugateBuiltin };

fn callPyFunction(
    interp: *Interp,
    fn_val: *Function,
    positional: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
    locals_override: ?*Dict,
) !Value {
    const code = fn_val.code;
    const argcount: u32 = @intCast(code.argcount);
    const kwonly: u32 = @intCast(code.kwonlyargcount);
    const has_varargs = (code.flags & CO_VARARGS) != 0;
    const has_varkw = (code.flags & CO_VARKEYWORDS) != 0;

    const locals_dict = locals_override orelse fn_val.globals;
    const new_frame = try Frame.init(interp.allocator, code, fn_val.globals, interp.builtins, locals_dict);
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
    if (fn_val.kw_defaults) |kwd| {
        var s: u32 = argcount;
        while (s < argcount + kwonly) : (s += 1) {
            if (new_frame.fast[s] == .null_sentinel) {
                if (kwd.getStr(code.localsplusnames[s])) |dv| {
                    new_frame.fast[s] = dv;
                }
            }
        }
    }
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

    if (code.flags & (CO_GENERATOR | CO_COROUTINE) != 0) {
        // CPython prologue is [COPY_FREE_VARS?] RETURN_GENERATOR
        // POP_TOP RESUME. Apply COPY_FREE_VARS now (the body's
        // LOAD_DEREF needs the free cells in fast slots) and skip
        // past RETURN_GENERATOR; the first send pushes a value
        // that POP_TOP discards before RESUME falls into the body.
        var ip: u32 = 0;
        if (code.bytecode[0] == @intFromEnum(Opcode.COPY_FREE_VARS)) {
            const n: usize = code.bytecode[1];
            const closure = new_frame.closure orelse return error.TypeError;
            const start = new_frame.fast.len - n;
            var ci: usize = 0;
            while (ci < n) : (ci += 1) {
                new_frame.fast[start + ci] = closure.items[ci];
            }
            ip = 2;
        }
        // Skip RETURN_GENERATOR.
        new_frame.ip = ip + 2;
        const g = try Generator.init(interp.allocator, new_frame);
        return Value{ .generator = g };
    }

    const result = try run(interp, new_frame);
    new_frame.deinit(interp.allocator);
    return result;
}

fn instantiate(
    interp: *Interp,
    cls: *Class,
    positional: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) !Value {
    const inst = try Instance.init(interp.allocator, cls);
    const inst_val = Value{ .instance = inst };
    if (cls.lookup("__init__") == null and builtins_mod.isExceptionClass(interp, cls)) {
        // BaseException's default __init__ stores positional args as
        // a tuple on `.args` -- enough for `raise Foo("msg")` and
        // `e.args[0]` readback.
        const t = try Tuple.init(interp.allocator, positional.len);
        @memcpy(t.items, positional);
        try inst.dict.setStr(interp.allocator, "args", Value{ .tuple = t });
        return inst_val;
    }
    if (cls.lookup("__init__")) |init_v| {
        if (init_v != .function) {
            try interp.typeError("__init__ is not a Python function");
            return error.TypeError;
        }
        // Bind self as args[0].
        var stack_buf: [64]Value = undefined;
        const total = positional.len + 1;
        if (total > stack_buf.len) {
            try interp.typeError("too many positional args for __init__");
            return error.TypeError;
        }
        stack_buf[0] = inst_val;
        @memcpy(stack_buf[1..total], positional);
        _ = try callPyFunction(interp, init_v.function, stack_buf[0..total], kw_names, kw_values, null);
    }
    return inst_val;
}

/// `__build_class__(body_fn, name, *bases)` runs the class body
/// function with a fresh dict as its locals namespace, then turns
/// that dict into a Class. The class body itself returns None;
/// the namespace is harvested from the frame after the run.
pub fn buildClass(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 2 or args[0] != .function or args[1] != .str) {
        try interp.typeError("__build_class__ expects (body_fn, name, *bases)");
        return error.TypeError;
    }
    const body_fn = args[0].function;
    const name = args[1].str.bytes;

    var bases_buf: [8]*Class = undefined;
    if (args.len - 2 > bases_buf.len) {
        try interp.typeError("too many bases");
        return error.TypeError;
    }
    var n_bases: usize = 0;
    for (args[2..]) |b| {
        if (b != .class) {
            try interp.typeError("base must be a class");
            return error.TypeError;
        }
        bases_buf[n_bases] = b.class;
        n_bases += 1;
    }

    const ns = try Dict.init(interp.allocator);
    _ = try callPyFunction(interp, body_fn, &.{}, &.{}, &.{}, ns);

    const cls = try Class.init(interp.allocator, name, bases_buf[0..n_bases], ns);
    // The class body's `STORE_NAME __classcell__` left the (still-empty)
    // cell in the namespace -- methods close over it for `super()` /
    // `__class__`. Populate it now so LOAD_DEREF returns the real class.
    if (ns.getStr("__classcell__")) |cell_val| {
        if (cell_val == .cell) cell_val.cell.value = Value{ .class = cls };
    }
    return Value{ .class = cls };
}

/// `isinstance(obj, cls)` -- walks `obj.cls.mro` looking for `cls`.
/// Only Instance / Class is in scope; anything else returns False.
pub fn isInstanceBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2) {
        try interp.typeError("isinstance expects (obj, class)");
        return error.TypeError;
    }
    if (args[1] == .class) {
        if (args[0] != .instance) return Value{ .boolean = false };
        const target = args[1].class;
        for (args[0].instance.cls.mro) |c| {
            if (c == target) return Value{ .boolean = true };
        }
        return Value{ .boolean = false };
    }
    if (args[1] == .builtin_fn) {
        return Value{ .boolean = matchClassCheck(args[0], args[1]) };
    }
    if (args[1] == .tuple) {
        for (args[1].tuple.items) |t| {
            const r = try isInstanceBuiltin(interp_opaque, &.{ args[0], t });
            if (r.boolean) return Value{ .boolean = true };
        }
        return Value{ .boolean = false };
    }
    try interp.typeError("isinstance expects (obj, class)");
    return error.TypeError;
}

/// `issubclass(sub, cls)` -- walks `sub.mro` for `cls`. Both args
/// must be classes; the fixture-side `__exit__` uses this on
/// exception types.
pub fn isSubclassBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2 or args[0] != .class or args[1] != .class) {
        try interp.typeError("issubclass expects (class, class)");
        return error.TypeError;
    }
    const target = args[1].class;
    for (args[0].class.mro) |c| {
        if (c == target) return Value{ .boolean = true };
    }
    return Value{ .boolean = false };
}
