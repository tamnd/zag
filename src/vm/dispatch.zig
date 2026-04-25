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
const BigInt = @import("../object/bigint.zig").BigInt;
const Set = @import("../object/set.zig").Set;
const Dict = @import("../object/dict.zig").Dict;
const Frame = @import("frame.zig").Frame;
const Interp = @import("interp.zig").Interp;
const strmethods = @import("strmethods.zig");
const listmethods = @import("listmethods.zig");
const setmethods = @import("setmethods.zig");
const bytearraymethods = @import("bytearraymethods.zig");
const memoryviewmethods = @import("memoryviewmethods.zig");
const dictmethods = @import("dictmethods.zig");
const collmethods = @import("collections_methods.zig");
const exc = @import("exc.zig");
const builtins_mod = @import("builtins.zig");
const dunder = @import("dunder.zig");
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
    const traceback = @import("traceback.zig");
    const prev_frame = interp.current_frame;
    interp.current_frame = frame;
    defer interp.current_frame = prev_frame;
    while (true) {
        if (dispatchOne(interp, frame)) |v| {
            return v;
        } else |err| {
            if (err != error.PyException) return err;
            const e = interp.current_exc orelse return err;
            traceback.record(interp, frame) catch {};
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
                const has_fromlist_b = switch (fromlist) {
                    .tuple => |t| t.items.len > 0,
                    .list => |l| l.items.items.len > 0,
                    else => false,
                };
                var top_mod = m;
                if (std.mem.indexOfScalar(u8, abs_name, '.')) |first_dot| {
                    const top_name = abs_name[0..first_dot];
                    if (interp.getBuiltinModule(top_name)) |top| top_mod = top;
                }
                const result = if (has_fromlist_b) m else top_mod;
                frame.push(Value{ .module = result });
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

        .GET_AITER => {
            const obj = frame.pop();
            const r = (try dunder.call(interp, obj, "__aiter__", &.{})) orelse {
                try interp.typeError("'async for' requires __aiter__");
                return error.TypeError;
            };
            frame.push(r);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .GET_ANEXT => {
            const aiter = frame.stack[frame.sp - 1];
            const r = (try dunder.call(interp, aiter, "__anext__", &.{})) orelse {
                try interp.typeError("'async for' requires __anext__");
                return error.TypeError;
            };
            frame.push(r);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .END_ASYNC_FOR => {
            const e = frame.pop();
            _ = frame.pop();
            if (e == .instance) {
                const sai = interp.builtins.getStr("StopAsyncIteration") orelse {
                    interp.current_exc = e;
                    return error.PyException;
                };
                if (sai == .class) {
                    for (e.instance.cls.mro) |c| {
                        if (c == sai.class) {
                            interp.current_exc = null;
                            continue :sw advance(frame, &ext_arg, 0);
                        }
                    }
                }
            }
            interp.current_exc = e;
            return error.PyException;
        },

        .GET_AWAITABLE => {
            // Coroutines (modeled as generators) and finished sleep
            // generators pass through. User instances with `__await__`
            // call it; the result must itself be a generator/iterator.
            const v = frame.pop();
            switch (v) {
                .generator => frame.push(v),
                .instance => {
                    const r = (try dunder.call(interp, v, "__await__", &.{})) orelse {
                        try interp.typeError("object can't be used in 'await' expression");
                        return error.TypeError;
                    };
                    frame.push(r);
                },
                else => {
                    try interp.typeError("object can't be used in 'await' expression");
                    return error.TypeError;
                },
            }
            continue :sw advance(frame, &ext_arg, 0);
        },

        .BUILD_INTERPOLATION => {
            const arg = oparg(frame, ext_arg);
            const fmt_spec: ?Value = if (arg & 1 != 0) frame.pop() else null;
            const expr = frame.pop();
            const value = frame.pop();
            const conv_code: u32 = (arg >> 2) & 3;
            const conv_str: ?[]const u8 = switch (conv_code) {
                1 => "s",
                2 => "r",
                3 => "a",
                else => null,
            };
            const a = interp.allocator;
            if (interp.interpolation_class == null) {
                interp.interpolation_class = try @import("../object/class.zig").Class.init(a, "Interpolation", &.{}, try @import("../object/dict.zig").Dict.init(a));
            }
            const inst = try @import("../object/instance.zig").Instance.init(a, interp.interpolation_class.?);
            try inst.dict.setStr(a, "value", value);
            try inst.dict.setStr(a, "expression", expr);
            if (conv_str) |cs| {
                try inst.dict.setStr(a, "conversion", Value{ .str = try @import("../object/string.zig").Str.init(a, cs) });
            } else {
                try inst.dict.setStr(a, "conversion", Value.none);
            }
            if (fmt_spec) |fs| {
                try inst.dict.setStr(a, "format_spec", fs);
            } else {
                try inst.dict.setStr(a, "format_spec", Value{ .str = try @import("../object/string.zig").Str.init(a, "") });
            }
            frame.push(Value{ .instance = inst });
            continue :sw advance(frame, &ext_arg, 0);
        },

        .BUILD_TEMPLATE => {
            const interps = frame.pop();
            const strs = frame.pop();
            const a = interp.allocator;
            if (interp.template_class == null) {
                interp.template_class = try @import("../object/class.zig").Class.init(a, "Template", &.{}, try @import("../object/dict.zig").Dict.init(a));
            }
            const inst = try @import("../object/instance.zig").Instance.init(a, interp.template_class.?);
            try inst.dict.setStr(a, "strings", strs);
            try inst.dict.setStr(a, "interpolations", interps);
            // values = tuple of interp.value for each interpolation
            if (interps == .tuple) {
                const vt = try Tuple.init(a, interps.tuple.items.len);
                for (interps.tuple.items, 0..) |it, i| {
                    if (it == .instance) {
                        vt.items[i] = it.instance.dict.getStr("value") orelse Value.none;
                    } else vt.items[i] = Value.none;
                }
                try inst.dict.setStr(a, "values", Value{ .tuple = vt });
            }
            frame.push(Value{ .instance = inst });
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
                try dictSetKey(interp, dst_val.dict, p.key, p.value);
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
                .instance => blk: {
                    if (try @import("dunder.zig").call(interp, v, "__neg__", &.{})) |x| break :blk x;
                    try interp.typeError("bad operand type for unary -");
                    return error.TypeError;
                },
                else => {
                    try interp.typeError("bad operand type for unary -");
                    return error.TypeError;
                },
            };
            frame.push(r);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .UNARY_INVERT => {
            const v = frame.pop();
            const r: Value = switch (v) {
                .small_int => |i| Value{ .small_int = ~i },
                .boolean => |b| Value{ .small_int = ~@as(i64, @intFromBool(b)) },
                .instance => blk: {
                    if (try @import("dunder.zig").call(interp, v, "__invert__", &.{})) |x| break :blk x;
                    try interp.typeError("bad operand type for unary ~");
                    return error.TypeError;
                },
                else => {
                    try interp.typeError("bad operand type for unary ~");
                    return error.TypeError;
                },
            };
            frame.push(r);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .UNARY_NOT => {
            const v = frame.pop();
            frame.push(Value{ .boolean = !v.isTruthy() });
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
                16 => {}, // annotate function (CPython 3.14 PEP 649): ignored
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
                try setAddEq(interp, s, frame.stack[base + i]);
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
            for (drained.items.items) |it| try setAddEq(interp, set_val.set, it);
            continue :sw advance(frame, &ext_arg, 0);
        },

        .SET_ADD => {
            const v = frame.pop();
            const set_val = frame.stack[frame.sp - oparg(frame, ext_arg)];
            try setAddEq(interp, set_val.set, v);
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
                try dictSetKey(interp, d, k, v);
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
                .bytearray => |b| switch (key) {
                    .small_int => |i| {
                        const n: i64 = @intCast(b.data.items.len);
                        var idx = i;
                        if (idx < 0) idx += n;
                        if (idx < 0 or idx >= n) {
                            try interp.indexError("bytearray deletion index out of range");
                            return error.IndexError;
                        }
                        _ = b.data.orderedRemove(@intCast(idx));
                    },
                    .slice => |sl| {
                        const n: i64 = @intCast(b.data.items.len);
                        const r = try resolveSlice(interp, sl, n);
                        if (r.step != 1) {
                            try interp.typeError("extended bytearray slice deletion not supported");
                            return error.TypeError;
                        }
                        const lo: usize = @intCast(r.start);
                        try b.data.replaceRange(interp.allocator, lo, r.count, &.{});
                    },
                    else => {
                        try interp.typeError("bytearray indices must be integers or slices");
                        return error.TypeError;
                    },
                },
                .instance => {
                    if (try @import("dunder.zig").call(interp, container, "__delitem__", &.{key})) |_| {} else {
                        try interp.typeError("object does not support item deletion");
                        return error.TypeError;
                    }
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
            try dictSetKey(interp, dict_val.dict, k, v);
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
                .instance => |i| {
                    if (i.cls.lookup(name)) |descr| {
                        if (descr == .instance and dunder.lookup(descr, "__set__") != null) {
                            _ = try dunder.call(interp, descr, "__set__", &.{ obj, value });
                            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.STORE_ATTR)]);
                        }
                        if (descr == .descriptor and descr.descriptor.kind == .property) {
                            if (descr.descriptor.fset != .none) {
                                _ = try invoke(interp, descr.descriptor.fset, &.{ obj, value });
                                continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.STORE_ATTR)]);
                            }
                            try interp.attributeError(obj.typeName(), name);
                            return error.AttributeError;
                        }
                    }
                    try i.dict.setStr(interp.allocator, name, value);
                },
                .class => |c| try c.dict.setStr(interp.allocator, name, value),
                .module => |m| try m.attrs.setStr(interp.allocator, name, value),
                else => {
                    try interp.attributeError(obj.typeName(), name);
                    return error.AttributeError;
                },
            }
            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.STORE_ATTR)]);
        },

        .DELETE_ATTR => {
            const arg = oparg(frame, ext_arg);
            const name = frame.code.names[arg];
            const obj = frame.pop();
            switch (obj) {
                .instance => |i| {
                    if (i.cls.lookup(name)) |descr| {
                        if (descr == .instance and dunder.lookup(descr, "__delete__") != null) {
                            _ = try dunder.call(interp, descr, "__delete__", &.{obj});
                            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.DELETE_ATTR)]);
                        }
                        if (descr == .descriptor and descr.descriptor.kind == .property) {
                            if (descr.descriptor.fdel != .none) {
                                _ = try invoke(interp, descr.descriptor.fdel, &.{obj});
                                continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.DELETE_ATTR)]);
                            }
                            try interp.attributeError(obj.typeName(), name);
                            return error.AttributeError;
                        }
                    }
                    if (!i.dict.delete(name)) {
                        try interp.attributeError(obj.typeName(), name);
                        return error.AttributeError;
                    }
                },
                else => {
                    try interp.attributeError(obj.typeName(), name);
                    return error.AttributeError;
                },
            }
            continue :sw advance(frame, &ext_arg, op.cache_width[@intFromEnum(Opcode.DELETE_ATTR)]);
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
                5 => {
                    // INTRINSIC_UNARY_POSITIVE.
                    const v = frame.pop();
                    const r: Value = switch (v) {
                        .small_int, .float, .complex_num => v,
                        .boolean => |b| Value{ .small_int = @intFromBool(b) },
                        .instance => blk: {
                            if (try @import("dunder.zig").call(interp, v, "__pos__", &.{})) |x| break :blk x;
                            try interp.typeError("bad operand type for unary +");
                            return error.TypeError;
                        },
                        else => {
                            try interp.typeError("bad operand type for unary +");
                            return error.TypeError;
                        },
                    };
                    frame.push(r);
                },
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
            if (arg == 1 or arg == 2) {
                const cause: ?Value = if (arg == 2) frame.pop() else null;
                const v = frame.pop();
                const inst_val = switch (v) {
                    .class => |cls| try instantiate(interp, cls, &.{}, &.{}, &.{}),
                    .instance => v,
                    else => {
                        try interp.typeError("exceptions must derive from BaseException");
                        return error.TypeError;
                    },
                };
                if (inst_val == .instance) {
                    if (cause) |c| {
                        try inst_val.instance.dict.setStr(interp.allocator, "__cause__", c);
                        try inst_val.instance.dict.setStr(interp.allocator, "__suppress_context__", Value{ .boolean = true });
                    } else if (inst_val.instance.dict.getStr("__cause__") == null) {
                        try inst_val.instance.dict.setStr(interp.allocator, "__cause__", Value.none);
                    }
                    if (interp.handling_exc) |h| {
                        try inst_val.instance.dict.setStr(interp.allocator, "__context__", h);
                    } else if (inst_val.instance.dict.getStr("__context__") == null) {
                        try inst_val.instance.dict.setStr(interp.allocator, "__context__", Value.none);
                    }
                }
                interp.current_exc = inst_val;
                return error.PyException;
            }
            try interp.typeError("RAISE_VARARGS arg > 2 not supported");
            return error.TypeError;
        },

        .PUSH_EXC_INFO => {
            // Stack: [..., exc] -> [..., prev_exc_info, exc]. The
            // pushed `prev` slot is the previous `handling_exc`, so
            // POP_EXCEPT can restore it for sys.exc_info() and the
            // implicit `__context__` of any exception that escapes.
            const e = frame.pop();
            const prev = interp.handling_exc orelse Value.none;
            frame.push(prev);
            frame.push(e);
            interp.handling_exc = e;
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
            const prev = frame.pop();
            interp.handling_exc = if (prev == .none) null else prev;
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
            } else if (v == .instance) {
                const empty_str = try Str.init(interp.allocator, "");
                if (try @import("dunder.zig").call(interp, v, "__format__", &.{Value{ .str = empty_str }})) |r| {
                    frame.push(r);
                } else {
                    const bytes = try @import("builtins.zig").formatInstance(interp, v, .str);
                    const s = try Str.init(interp.allocator, bytes);
                    frame.push(Value{ .str = s });
                }
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
            if (v == .instance) {
                if (try @import("dunder.zig").call(interp, v, "__format__", &.{spec_v})) |r| {
                    frame.push(r);
                    continue :sw advance(frame, &ext_arg, 0);
                }
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
pub fn binaryOp(interp: *Interp, a: Value, b: Value, arg: u32) !Value {
    // User instances override arithmetic via dunders. Fall through to
    // the built-in dispatch only if neither operand defines the op.
    if (a == .instance or b == .instance) {
        // In-place ops (13-25) try `__i*__` first, then fall through
        // to the forward `__*__` if missing. Subscript (26) is a
        // single-sided lookup; everything else uses the standard
        // forward/reflected pair.
        const Pair = struct { op: []const u8, rop: []const u8, iop: []const u8 = "" };
        const pair: ?Pair = switch (arg) {
            0 => .{ .op = "__add__", .rop = "__radd__" },
            1 => .{ .op = "__and__", .rop = "__rand__" },
            2 => .{ .op = "__floordiv__", .rop = "__rfloordiv__" },
            3 => .{ .op = "__lshift__", .rop = "__rlshift__" },
            4 => .{ .op = "__matmul__", .rop = "__rmatmul__" },
            5 => .{ .op = "__mul__", .rop = "__rmul__" },
            6 => .{ .op = "__mod__", .rop = "__rmod__" },
            7 => .{ .op = "__or__", .rop = "__ror__" },
            8 => .{ .op = "__pow__", .rop = "__rpow__" },
            9 => .{ .op = "__rshift__", .rop = "__rrshift__" },
            10 => .{ .op = "__sub__", .rop = "__rsub__" },
            11 => .{ .op = "__truediv__", .rop = "__rtruediv__" },
            12 => .{ .op = "__xor__", .rop = "__rxor__" },
            13 => .{ .op = "__add__", .rop = "__radd__", .iop = "__iadd__" },
            14 => .{ .op = "__and__", .rop = "__rand__", .iop = "__iand__" },
            15 => .{ .op = "__floordiv__", .rop = "__rfloordiv__", .iop = "__ifloordiv__" },
            16 => .{ .op = "__lshift__", .rop = "__rlshift__", .iop = "__ilshift__" },
            17 => .{ .op = "__matmul__", .rop = "__rmatmul__", .iop = "__imatmul__" },
            18 => .{ .op = "__mul__", .rop = "__rmul__", .iop = "__imul__" },
            19 => .{ .op = "__mod__", .rop = "__rmod__", .iop = "__imod__" },
            20 => .{ .op = "__or__", .rop = "__ror__", .iop = "__ior__" },
            21 => .{ .op = "__pow__", .rop = "__rpow__", .iop = "__ipow__" },
            22 => .{ .op = "__rshift__", .rop = "__rrshift__", .iop = "__irshift__" },
            23 => .{ .op = "__sub__", .rop = "__rsub__", .iop = "__isub__" },
            24 => .{ .op = "__truediv__", .rop = "__rtruediv__", .iop = "__itruediv__" },
            25 => .{ .op = "__xor__", .rop = "__rxor__", .iop = "__ixor__" },
            26 => .{ .op = "__getitem__", .rop = "" },
            else => null,
        };
        if (pair) |p| {
            if (arg == 26) {
                if (a == .instance) {
                    if (try @import("dunder.zig").call(interp, a, p.op, &.{b})) |r| return r;
                }
            } else {
                if (p.iop.len > 0 and a == .instance) {
                    if (try @import("dunder.zig").call(interp, a, p.iop, &.{b})) |r| {
                        if (r != .not_implemented) return r;
                    }
                }
                if (try @import("dunder.zig").binop(interp, a, b, p.op, p.rop)) |r| return r;
            }
        }
    }
    return switch (arg) {
        0 => add(interp, a, b),
        1, 14 => bitwiseAnd(interp, a, b),
        2, 15 => floorDivide(interp, a, b),
        3, 16 => leftShift(interp, a, b),
        5, 18 => multiply(interp, a, b),
        6, 19 => remainder(interp, a, b),
        7, 20 => bitwiseOr(interp, a, b),
        8, 21 => powerOp(interp, a, b),
        9, 22 => rightShift(interp, a, b),
        10, 23 => subtract(interp, a, b),
        11, 24 => trueDivide(interp, a, b),
        12, 25 => bitwiseXor(interp, a, b),
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

fn powerOp(interp: *Interp, a: Value, b: Value) !Value {
    return @import("builtins.zig").powBuiltin(@ptrCast(interp), &.{ a, b });
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
pub fn binaryAdd(interp: *Interp, a: Value, b: Value) !Value {
    return add(interp, a, b);
}

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
    if (asIntLike(a)) |ai| if (asIntLike(b)) |bi| {
        return Value{ .small_int = ai | bi };
    };
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
    if (asIntLike(a)) |ai| if (asIntLike(b)) |bi| {
        return Value{ .small_int = ai & bi };
    };
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

fn asIntLike(v: Value) ?i64 {
    return switch (v) {
        .small_int => |i| i,
        .boolean => |b| @intFromBool(b),
        else => null,
    };
}

fn floorDivide(interp: *Interp, a: Value, b: Value) !Value {
    if (asIntLike(a)) |ai| if (asIntLike(b)) |bi| {
        if (bi == 0) {
            try interp.raisePy("ZeroDivisionError", "integer division or modulo by zero");
            return error.PyException;
        }
        return Value{ .small_int = @divFloor(ai, bi) };
    };
    if ((a == .float or b == .float) and asFloat(a) != null and asFloat(b) != null) {
        const af = asFloat(a).?;
        const bf = asFloat(b).?;
        if (bf == 0.0) {
            try interp.raisePy("ZeroDivisionError", "float floor division by zero");
            return error.PyException;
        }
        return Value{ .float = @floor(af / bf) };
    }
    try interp.typeError("unsupported operand type(s) for //");
    return error.TypeError;
}

fn leftShift(interp: *Interp, a: Value, b: Value) !Value {
    if (asIntLike(a)) |ai| if (asIntLike(b)) |bi| {
        if (bi < 0) {
            try interp.raisePy("ValueError", "negative shift count");
            return error.PyException;
        }
        // Determine whether result fits i64 to keep small_int when safe.
        if (ai == 0) return Value{ .small_int = 0 };
        const abs_a: u64 = @intCast(if (ai < 0) -ai else ai);
        const lz: u32 = @clz(abs_a);
        const top_bit: u64 = 64 - lz;
        if (bi <= 62 and (top_bit + @as(u64, @intCast(bi))) < 63) {
            const sh: u6 = @intCast(bi);
            return Value{ .small_int = ai << sh };
        }
        // Overflow path: build big_int = a << b.
        const allocator = interp.allocator;
        var managed = try std.math.big.int.Managed.initSet(allocator, ai);
        errdefer managed.deinit();
        try managed.shiftLeft(&managed, @intCast(bi));
        const big = try BigInt.fromManaged(allocator, managed);
        return Value{ .big_int = big };
    };
    try interp.typeError("unsupported operand type(s) for <<");
    return error.TypeError;
}

fn rightShift(interp: *Interp, a: Value, b: Value) !Value {
    if (asIntLike(a)) |ai| if (asIntLike(b)) |bi| {
        if (bi < 0) {
            try interp.raisePy("ValueError", "negative shift count");
            return error.PyException;
        }
        const sh: u6 = @intCast(@min(bi, 63));
        return Value{ .small_int = ai >> sh };
    };
    try interp.typeError("unsupported operand type(s) for >>");
    return error.TypeError;
}

fn bitwiseXor(interp: *Interp, a: Value, b: Value) !Value {
    if (asIntLike(a)) |ai| if (asIntLike(b)) |bi| {
        return Value{ .small_int = ai ^ bi };
    };
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
    // Sequence repetition: `[x] * n` / `n * [x]`. Same for tuple.
    const SeqOp = struct {
        fn intFrom(v: Value) ?i64 {
            return switch (v) {
                .small_int => |i| i,
                .boolean => |x| @intFromBool(x),
                else => null,
            };
        }
    };
    if (a == .list or b == .list) {
        const lst = if (a == .list) a.list else b.list;
        const n_opt = if (a == .list) SeqOp.intFrom(b) else SeqOp.intFrom(a);
        if (n_opt) |n| {
            const rep: usize = if (n < 0) 0 else @intCast(n);
            const out = try @import("../object/list.zig").List.init(interp.allocator);
            var i: usize = 0;
            while (i < rep) : (i += 1) {
                for (lst.items.items) |x| try out.append(interp.allocator, x);
            }
            return Value{ .list = out };
        }
    }
    if (a == .str or b == .str) {
        const SeqOp2 = struct {
            fn intFrom(v: Value) ?i64 {
                return switch (v) {
                    .small_int => |i| i,
                    .boolean => |x| @intFromBool(x),
                    else => null,
                };
            }
        };
        const s = if (a == .str) a.str else b.str;
        const n_opt = if (a == .str) SeqOp2.intFrom(b) else SeqOp2.intFrom(a);
        if (n_opt) |n| {
            const rep: usize = if (n < 0) 0 else @intCast(n);
            var buf = try interp.allocator.alloc(u8, s.bytes.len * rep);
            var i: usize = 0;
            while (i < rep) : (i += 1) {
                @memcpy(buf[i * s.bytes.len .. (i + 1) * s.bytes.len], s.bytes);
            }
            const new_s = try Str.fromOwnedSlice(interp.allocator, buf);
            return Value{ .str = new_s };
        }
    }
    if (a == .tuple or b == .tuple) {
        const tup = if (a == .tuple) a.tuple else b.tuple;
        const n_opt = if (a == .tuple) SeqOp.intFrom(b) else SeqOp.intFrom(a);
        if (n_opt) |n| {
            const rep: usize = if (n < 0) 0 else @intCast(n);
            const out = try @import("../object/tuple.zig").Tuple.init(interp.allocator, tup.items.len * rep);
            var i: usize = 0;
            while (i < rep) : (i += 1) {
                @memcpy(out.items[i * tup.items.len .. (i + 1) * tup.items.len], tup.items);
            }
            return Value{ .tuple = out };
        }
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
    // bytearray += bytes-like extends in place and returns the same
    // object. The caller stores the result back into the local, but
    // since we mutated in place that store is a no-op identity-wise.
    if (a == .bytearray) {
        const src: ?[]const u8 = switch (b) {
            .bytes => |x| x.data,
            .bytearray => |x| x.data.items,
            else => null,
        };
        if (src) |s| {
            try a.bytearray.data.appendSlice(interp.allocator, s);
            return a;
        }
    }
    return add(interp, a, b);
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

pub fn subscript(interp: *Interp, container: Value, key: Value) !Value {
    if (container == .class) {
        if (container.class.lookup("__class_getitem__")) |hook| {
            return try invoke(interp, hook, &.{ container, key });
        }
    }
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
        .memoryview => |m| switch (key) {
            .small_int => |i| {
                const n: i64 = @intCast(m.len);
                var idx = i;
                if (idx < 0) idx += n;
                if (idx < 0 or idx >= n) {
                    try interp.raisePy("IndexError", "index out of range");
                    return error.PyException;
                }
                return Value{ .small_int = @intCast(m.data()[@intCast(idx)]) };
            },
            .slice => |sl| {
                const n: i64 = @intCast(m.len);
                const r = try resolveSlice(interp, sl, n);
                if (r.step != 1) {
                    try interp.typeError("memoryview only supports step=1 slicing in zag");
                    return error.TypeError;
                }
                const sub = try m.slice(interp.allocator, @intCast(r.start), r.count);
                return Value{ .memoryview = sub };
            },
            else => {
                try interp.typeError("memoryview indices must be integers or slices");
                return error.TypeError;
            },
        },
        .dict => |d| {
            if (try dictGetKey(interp, d, key)) |v| return v;
            try interp.raisePy("KeyError", "key not found");
            return error.PyException;
        },
        .deque => |dq| switch (key) {
            .small_int => |i| {
                const n: i64 = @intCast(dq.items.items.items.len);
                var idx = i;
                if (idx < 0) idx += n;
                if (idx < 0 or idx >= n) {
                    try interp.raisePy("IndexError", "deque index out of range");
                    return error.PyException;
                }
                return dq.items.items.items[@intCast(idx)];
            },
            else => {
                try interp.typeError("sequence index must be integer");
                return error.TypeError;
            },
        },
        .counter => |c| {
            if (key != .str) {
                try interp.typeError("Counter only supports str keys");
                return error.TypeError;
            }
            return c.data.getStr(key.str.bytes) orelse Value{ .small_int = 0 };
        },
        .defaultdict => |dd| {
            if (key != .str) {
                try interp.typeError("defaultdict only supports str keys");
                return error.TypeError;
            }
            if (dd.data.getStr(key.str.bytes)) |v| return v;
            const v = if (dd.factory == .none) Value.none else try invoke(interp, dd.factory, &.{});
            try dd.data.setStr(interp.allocator, key.str.bytes, v);
            return v;
        },
        .ordered_dict => |od| {
            if (key != .str) {
                try interp.typeError("OrderedDict only supports str keys");
                return error.TypeError;
            }
            if (od.data.getStr(key.str.bytes)) |v| return v;
            try interp.raisePy("KeyError", key.str.bytes);
            return error.PyException;
        },
        .named_tuple => |nt| switch (key) {
            .small_int => |i| {
                const n: i64 = @intCast(nt.items.len);
                var idx = i;
                if (idx < 0) idx += n;
                if (idx < 0 or idx >= n) {
                    try interp.raisePy("IndexError", "tuple index out of range");
                    return error.PyException;
                }
                return nt.items[@intCast(idx)];
            },
            else => {
                try interp.typeError("tuple indices must be integers");
                return error.TypeError;
            },
        },
        .instance => {
            if (try @import("dunder.zig").call(interp, container, "__getitem__", &.{key})) |v| return v;
            try interp.typeError("object is not subscriptable");
            return error.TypeError;
        },
        else => {
            try interp.typeError("object is not subscriptable");
            return error.TypeError;
        },
    }
}

/// Interp-aware dict lookup: instance keys compare via `__eq__`,
/// other keys fall through to the linear `Value.equals` scan.
pub fn dictGetKey(interp: *Interp, d: *const @import("../object/dict.zig").Dict, key: Value) !?Value {
    for (d.pairs.items) |p| {
        if (try @import("dunder.zig").valuesEqual(interp, p.key, key)) return p.value;
    }
    return null;
}

/// Insert / overwrite a dict entry, comparing keys with `__eq__` for
/// instance keys. Mirrors Dict.setKey but interp-aware.
pub fn dictSetKey(
    interp: *Interp,
    d: *@import("../object/dict.zig").Dict,
    key: Value,
    value: Value,
) !void {
    for (d.pairs.items, 0..) |p, i| {
        if (try @import("dunder.zig").valuesEqual(interp, p.key, key)) {
            d.pairs.items[i].value = value;
            return;
        }
    }
    try d.pairs.append(interp.allocator, .{ .key = key, .value = value });
    if (key == .str) try d.keys.append(interp.allocator, key.str.bytes);
}

/// Insert into a Set with `__eq__` semantics for instance members.
pub fn setAddEq(
    interp: *Interp,
    s: *@import("../object/set.zig").Set,
    v: Value,
) !void {
    for (s.items.items) |it| {
        if (try @import("dunder.zig").valuesEqual(interp, it, v)) return;
    }
    try s.items.append(interp.allocator, v);
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

pub fn storeSubscr(interp: *Interp, container: Value, key: Value, value: Value) !void {
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
            try dictSetKey(interp, d, key, value);
        },
        .deque => |dq| {
            if (key != .small_int) {
                try interp.typeError("sequence index must be integer");
                return error.TypeError;
            }
            const n: i64 = @intCast(dq.items.items.items.len);
            var idx = key.small_int;
            if (idx < 0) idx += n;
            if (idx < 0 or idx >= n) {
                try interp.raisePy("IndexError", "deque index out of range");
                return error.PyException;
            }
            dq.items.items.items[@intCast(idx)] = value;
        },
        .counter => |c| {
            if (key != .str) {
                try interp.typeError("Counter only supports str keys");
                return error.TypeError;
            }
            try c.data.setStr(interp.allocator, key.str.bytes, value);
        },
        .defaultdict => |dd| {
            if (key != .str) {
                try interp.typeError("defaultdict only supports str keys");
                return error.TypeError;
            }
            try dd.data.setStr(interp.allocator, key.str.bytes, value);
        },
        .ordered_dict => |od| {
            if (key != .str) {
                try interp.typeError("OrderedDict only supports str keys");
                return error.TypeError;
            }
            try od.data.setStr(interp.allocator, key.str.bytes, value);
        },
        .instance => {
            if (try @import("dunder.zig").call(interp, container, "__setitem__", &.{ key, value })) |_| return;
            try interp.typeError("object does not support item assignment");
            return error.TypeError;
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
            .slice => |sl| {
                const n: i64 = @intCast(b.data.items.len);
                const r = try resolveSlice(interp, sl, n);
                if (r.step != 1) {
                    try interp.typeError("extended slice assignment not supported");
                    return error.TypeError;
                }
                const src: []const u8 = switch (value) {
                    .bytes => |x| x.data,
                    .bytearray => |x| x.data.items,
                    else => {
                        try interp.typeError("bytearray slice assignment requires bytes-like");
                        return error.TypeError;
                    },
                };
                const lo: usize = @intCast(r.start);
                try b.data.replaceRange(interp.allocator, lo, r.count, src);
            },
            else => {
                try interp.typeError("bytearray indices must be integers or slices");
                return error.TypeError;
            },
        },
        .memoryview => |m| {
            const buf = m.writableData() orelse {
                try interp.raisePy("TypeError", "cannot modify read-only memory");
                return error.PyException;
            };
            switch (key) {
                .small_int => |i| {
                    if (value != .small_int and value != .boolean) {
                        try interp.typeError("memoryview byte must be an integer");
                        return error.TypeError;
                    }
                    const v: i64 = if (value == .boolean) @intFromBool(value.boolean) else value.small_int;
                    if (v < 0 or v > 255) {
                        try interp.raisePy("ValueError", "memoryview: invalid value for byte");
                        return error.PyException;
                    }
                    const n: i64 = @intCast(buf.len);
                    var idx = i;
                    if (idx < 0) idx += n;
                    if (idx < 0 or idx >= n) {
                        try interp.indexError("memoryview assignment index out of range");
                        return error.IndexError;
                    }
                    buf[@intCast(idx)] = @intCast(v);
                },
                .slice => |sl| {
                    const n: i64 = @intCast(buf.len);
                    const r = try resolveSlice(interp, sl, n);
                    if (r.step != 1) {
                        try interp.typeError("memoryview slice assignment requires step=1");
                        return error.TypeError;
                    }
                    const src: []const u8 = switch (value) {
                        .bytes => |x| x.data,
                        .bytearray => |x| x.data.items,
                        .memoryview => |mv2| mv2.data(),
                        else => {
                            try interp.typeError("memoryview slice assignment requires bytes-like");
                            return error.TypeError;
                        },
                    };
                    if (src.len != r.count) {
                        try interp.raisePy("ValueError", "memoryview assignment: lvalue and rvalue have different sizes");
                        return error.PyException;
                    }
                    @memcpy(buf[@intCast(r.start) .. @as(usize, @intCast(r.start)) + r.count], src);
                },
                else => {
                    try interp.typeError("memoryview indices must be integers or slices");
                    return error.TypeError;
                },
            }
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
        .instance => {
            const r = @import("dunder.zig").call(interp, it, "__next__", &.{}) catch |e| switch (e) {
                error.PyException => {
                    if (interp.current_exc) |cur| {
                        if (cur == .instance and std.mem.eql(u8, cur.instance.cls.name, "StopIteration")) {
                            interp.current_exc = null;
                            return null;
                        }
                    }
                    return e;
                },
                else => return e,
            };
            return r;
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
        .str, .bytes, .bytearray, .memoryview, .dict, .generator, .enum_iter, .set, .deque, .counter, .defaultdict, .ordered_dict, .named_tuple => blk: {
            const lst = try @import("builtins.zig").materialize(interp, v);
            break :blk try Iter.init(interp.allocator, .{ .list = lst });
        },
        .instance => blk: {
            const it_v = try makeInstanceIter(interp, v);
            switch (it_v) {
                .iter => |it| break :blk it,
                .generator => {
                    // Drain generator into a fresh list, then iterate.
                    const lst = try List.init(interp.allocator);
                    while (try genResume(interp, it_v.generator, Value.none)) |x| {
                        try lst.append(interp.allocator, x);
                    }
                    break :blk try Iter.init(interp.allocator, .{ .list = lst });
                },
                else => {
                    try interp.typeError("__iter__ returned non-iterator");
                    return error.TypeError;
                },
            }
        },
        else => {
            try interp.typeError("object is not iterable");
            return error.TypeError;
        },
    };
}

pub fn containsOp(interp: *Interp, item: Value, container: Value) !bool {
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
            if (item == .instance) {
                for (d.pairs.items) |p| {
                    if (try @import("dunder.zig").valuesEqual(interp, p.key, item)) return true;
                }
                return false;
            }
            if (item != .str) return false;
            return d.contains(item.str.bytes);
        },
        .deque => |dq| {
            for (dq.items.items.items) |x| if (x.equals(item)) return true;
            return false;
        },
        .counter => |c| {
            if (item != .str) return false;
            return c.data.contains(item.str.bytes);
        },
        .defaultdict => |dd| {
            if (item != .str) return false;
            return dd.data.contains(item.str.bytes);
        },
        .ordered_dict => |od| {
            if (item != .str) return false;
            return od.data.contains(item.str.bytes);
        },
        .named_tuple => |nt| {
            for (nt.items) |x| if (x.equals(item)) return true;
            return false;
        },
        .set => |s| {
            for (s.items.items) |it| {
                if (try @import("dunder.zig").valuesEqual(interp, it, item)) return true;
            }
            return false;
        },
        .bytes => |b| return bytesContains(b.data, item),
        .bytearray => |b| return bytesContains(b.data.items, item),
        .memoryview => |m| return bytesContains(m.data(), item),
        .instance => {
            if (try @import("dunder.zig").call(interp, container, "__contains__", &.{item})) |r| {
                return r.isTruthy();
            }
            // Fall back to iterating the instance.
            const it_v = try makeInstanceIter(interp, container);
            while (try iterStep(interp, it_v)) |x| {
                if (try @import("dunder.zig").valuesEqual(interp, x, item)) return true;
            }
            return false;
        },
        else => {
            try interp.typeError("argument of type is not iterable");
            return error.TypeError;
        },
    }
}

/// Build an iterator over a user-defined instance, honoring `__iter__`
/// then falling back to the indexed `__getitem__` protocol (call with
/// 0, 1, 2, ... until IndexError).
fn makeInstanceIter(interp: *Interp, v: Value) !Value {
    if (try @import("dunder.zig").call(interp, v, "__iter__", &.{})) |it| {
        return it;
    }
    if (@import("dunder.zig").lookup(v, "__getitem__")) |_| {
        const out = try List.init(interp.allocator);
        var i: i64 = 0;
        while (true) : (i += 1) {
            const idx = Value{ .small_int = i };
            const r = @import("dunder.zig").call(interp, v, "__getitem__", &.{idx}) catch |e| switch (e) {
                error.PyException => {
                    // IndexError ends iteration; other exceptions propagate.
                    if (interp.current_exc) |cur| {
                        if (cur == .instance and std.mem.eql(u8, cur.instance.cls.name, "IndexError")) {
                            interp.current_exc = null;
                            return Value{ .iter = try Iter.init(interp.allocator, .{ .list = out }) };
                        }
                    }
                    return e;
                },
                else => return e,
            };
            try out.append(interp.allocator, r.?);
        }
    }
    try interp.typeError("object is not iterable");
    return error.TypeError;
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
pub fn compareOp(interp: *Interp, a: Value, b: Value, kind: u3) !bool {
    if (a == .instance or b == .instance) {
        if (try @import("dunder.zig").compare(interp, a, b, kind)) |result| return result;
        // Equality with no dunder falls back to identity, matching CPython.
        if (kind == 2) return a.identityEq(b);
        if (kind == 3) return !a.identityEq(b);
    }
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
                try interp.raisePy("TypeError", "'<' not supported between these types");
                return error.PyException;
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
    if (std.mem.eql(u8, name, "memoryview")) return subject == .memoryview;
    if (std.mem.eql(u8, name, "set")) return subject == .set and !subject.set.frozen;
    if (std.mem.eql(u8, name, "frozenset")) return subject == .set and subject.set.frozen;
    if (std.mem.eql(u8, name, "type")) return subject == .class;
    return false;
}

/// Pinhole `LOAD_ATTR` that returns the resolved Value rather than
/// pushing onto a frame. Enough for `operator.attrgetter` and
/// `operator.methodcaller`: instance attr/method, then built-in
/// method tables. Falls back to `AttributeError`.
pub fn loadAttrValue(interp: *Interp, obj: Value, name: []const u8) !Value {
    if (obj == .instance) {
        if (obj.instance.dict.getStr(name)) |v| return v;
        if (obj.instance.cls.lookup(name)) |v| {
            if (v == .function) {
                const BoundMethod = @import("../object/bound_method.zig").BoundMethod;
                const bm = try BoundMethod.init(interp.allocator, v, obj);
                return Value{ .bound_method = bm };
            }
            return v;
        }
    }
    if (obj == .module) {
        if (obj.module.attrs.getStr(name)) |v| return v;
    }
    const method: ?*value_mod.BuiltinFn = switch (obj) {
        .str => strmethods.lookup(name),
        .list => listmethods.lookup(name),
        .dict => dictmethods.lookup(name),
        .set => setmethods.lookup(name),
        .bytearray => bytearraymethods.lookup(name),
        .memoryview => memoryviewmethods.lookup(name),
        else => null,
    };
    if (method) |m| {
        const BoundMethod = @import("../object/bound_method.zig").BoundMethod;
        const bm = try BoundMethod.init(interp.allocator, Value{ .builtin_fn = m }, obj);
        return Value{ .bound_method = bm };
    }
    try interp.attributeError(obj.typeName(), name);
    return error.AttributeError;
}

fn loadAttr(interp: *Interp, frame: *Frame, obj: Value, name: []const u8, is_method: bool) !void {
    if (obj == .instance) {
        if (std.mem.eql(u8, name, "__dict__")) {
            const v = Value{ .dict = obj.instance.dict };
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        // Data descriptors on the class beat the instance dict.
        const class_v = obj.instance.cls.lookup(name);
        if (class_v) |v| {
            if (v == .instance and dunder.lookup(v, "__set__") != null) {
                if (try dunder.call(interp, v, "__get__", &.{ obj, Value{ .class = obj.instance.cls } })) |r| {
                    if (is_method) {
                        frame.push(r);
                        frame.push(Value.null_sentinel);
                    } else frame.push(r);
                    return;
                }
            }
        }
        if (obj.instance.dict.getStr(name)) |v| {
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        if (class_v) |v| {
            if (v == .cached_property) {
                const cp = v.cached_property;
                const result = try invoke(interp, cp.func, &.{obj});
                try obj.instance.dict.setStr(interp.allocator, name, result);
                if (is_method) {
                    frame.push(result);
                    frame.push(Value.null_sentinel);
                } else frame.push(result);
                return;
            }
            if (v == .descriptor) {
                try bindDescriptor(interp, frame, v.descriptor, obj, Value{ .class = obj.instance.cls }, is_method);
                return;
            }
            // Non-data descriptor: only `__get__`.
            if (v == .instance and dunder.lookup(v, "__get__") != null) {
                if (try dunder.call(interp, v, "__get__", &.{ obj, Value{ .class = obj.instance.cls } })) |r| {
                    if (is_method) {
                        frame.push(r);
                        frame.push(Value.null_sentinel);
                    } else frame.push(r);
                    return;
                }
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
            if (v == .instance and dunder.lookup(v, "__get__") != null) {
                const r = (try dunder.call(interp, v, "__get__", &.{ Value.none, obj })) orelse Value.none;
                if (is_method) {
                    frame.push(r);
                    frame.push(Value.null_sentinel);
                } else frame.push(r);
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
    if (obj == .builtin_fn) {
        if (std.mem.eql(u8, name, "__name__")) {
            const s = try Str.init(interp.allocator, obj.builtin_fn.name);
            const v = Value{ .str = s };
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        // `itertools.chain.from_iterable` -- a sibling builtin
        // exposed off the `chain` callable.
        if (std.mem.eql(u8, obj.builtin_fn.name, "chain") and std.mem.eql(u8, name, "from_iterable")) {
            const fi = @import("itertools_mod.zig").chainFromIterableEntry(interp);
            if (is_method) {
                frame.push(fi);
                frame.push(Value.null_sentinel);
            } else frame.push(fi);
            return;
        }
    }
    if (obj == .function) {
        const f = obj.function;
        if (std.mem.eql(u8, name, "__name__")) {
            const text = f.name_override orelse f.code.qualname;
            const s = try Str.init(interp.allocator, text);
            const v = Value{ .str = s };
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        if (std.mem.eql(u8, name, "__doc__")) {
            const v = f.doc_override orelse Value.none;
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        if (std.mem.eql(u8, name, "__wrapped__")) {
            const v = f.wrapped orelse Value.none;
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
    }
    if (obj == .cached_fn) {
        const c = obj.cached_fn;
        if (std.mem.eql(u8, name, "__name__")) {
            const text: []const u8 = blk: {
                if (c.name_override) |n| break :blk n;
                if (c.func == .function) {
                    if (c.func.function.name_override) |n2| break :blk n2;
                    break :blk c.func.function.code.qualname;
                }
                if (c.func == .builtin_fn) break :blk c.func.builtin_fn.name;
                break :blk "cached";
            };
            const s = try Str.init(interp.allocator, text);
            const v = Value{ .str = s };
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        if (std.mem.eql(u8, name, "__wrapped__")) {
            const v = c.func;
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        if (std.mem.eql(u8, name, "cache_info") or std.mem.eql(u8, name, "cache_clear")) {
            const meth: *value_mod.BuiltinFn = if (std.mem.eql(u8, name, "cache_info"))
                &cache_info_method
            else
                &cache_clear_method;
            if (is_method) {
                frame.push(Value{ .builtin_fn = meth });
                frame.push(obj);
            } else {
                const BoundMethod = @import("../object/bound_method.zig").BoundMethod;
                const bm = try BoundMethod.init(interp.allocator, Value{ .builtin_fn = meth }, obj);
                frame.push(Value{ .bound_method = bm });
            }
            return;
        }
    }
    if (obj == .descriptor and obj.descriptor.kind == .property) {
        const m: ?*value_mod.BuiltinFn = if (std.mem.eql(u8, name, "setter"))
            &property_setter_method
        else if (std.mem.eql(u8, name, "deleter"))
            &property_deleter_method
        else if (std.mem.eql(u8, name, "getter"))
            &property_getter_method
        else
            null;
        if (m) |meth| {
            if (is_method) {
                frame.push(Value{ .builtin_fn = meth });
                frame.push(obj);
            } else {
                const BoundMethod = @import("../object/bound_method.zig").BoundMethod;
                const bm = try BoundMethod.init(interp.allocator, Value{ .builtin_fn = meth }, obj);
                frame.push(Value{ .bound_method = bm });
            }
            return;
        }
    }
    if (obj == .generator) {
        const m: ?*value_mod.BuiltinFn = if (std.mem.eql(u8, name, "send"))
            &gen_send_method
        else if (std.mem.eql(u8, name, "close"))
            &gen_close_method
        else if (std.mem.eql(u8, name, "__await__"))
            &gen_await_method
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
    if (obj == .slice) {
        const sl = obj.slice;
        const v: ?Value = if (std.mem.eql(u8, name, "start"))
            sl.start
        else if (std.mem.eql(u8, name, "stop"))
            sl.stop
        else if (std.mem.eql(u8, name, "step"))
            sl.step
        else
            null;
        if (v) |val| {
            if (is_method) {
                frame.push(val);
                frame.push(Value.null_sentinel);
            } else frame.push(val);
            return;
        }
    }
    if (obj == .memoryview) {
        const mv = obj.memoryview;
        if (std.mem.eql(u8, name, "readonly")) {
            const v = Value{ .boolean = mv.readonly() };
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        if (std.mem.eql(u8, name, "nbytes")) {
            const v = Value{ .small_int = @intCast(mv.len) };
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        if (std.mem.eql(u8, name, "format")) {
            const s = try Str.init(interp.allocator, "B");
            const v = Value{ .str = s };
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
        if (std.mem.eql(u8, name, "itemsize")) {
            const v = Value{ .small_int = 1 };
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
    }
    // Special attributes on collections values that aren't methods.
    if (obj == .deque) {
        if (std.mem.eql(u8, name, "maxlen")) {
            const v: Value = if (obj.deque.maxlen) |ml| Value{ .small_int = @intCast(ml) } else Value.none;
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
    }
    if (obj == .defaultdict) {
        if (std.mem.eql(u8, name, "default_factory")) {
            const v = obj.defaultdict.factory;
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
    }
    if (obj == .named_tuple) {
        // Field access by name.
        if (collmethods.ntFieldIndex(obj.named_tuple, name)) |i| {
            const v = obj.named_tuple.items[i];
            if (is_method) {
                frame.push(v);
                frame.push(Value.null_sentinel);
            } else frame.push(v);
            return;
        }
    }
    if (obj == .named_tuple_factory and std.mem.eql(u8, name, "_fields")) {
        const f = obj.named_tuple_factory;
        const t = try Tuple.init(interp.allocator, f.fields.len);
        for (f.fields, 0..) |fname, i| {
            const s = try Str.init(interp.allocator, fname);
            t.items[i] = Value{ .str = s };
        }
        const v = Value{ .tuple = t };
        if (is_method) {
            frame.push(v);
            frame.push(Value.null_sentinel);
        } else frame.push(v);
        return;
    }

    // Built-in methods on str/list/dict and collections types.
    if (is_method) {
        var self_for_method = obj;
        const method: ?*value_mod.BuiltinFn = switch (obj) {
            .str => strmethods.lookup(name),
            .list => listmethods.lookup(name),
            .dict => dictmethods.lookup(name),
            .set => setmethods.lookup(name),
            .bytearray => bytearraymethods.lookup(name),
            .memoryview => memoryviewmethods.lookup(name),
            .deque => collmethods.dequeLookup(name),
            .counter => |c| blk: {
                if (collmethods.counterLookup(name)) |m| break :blk m;
                if (dictmethods.lookup(name)) |m| {
                    self_for_method = Value{ .dict = c.data };
                    break :blk m;
                }
                break :blk null;
            },
            .ordered_dict => |od| blk: {
                if (collmethods.orderedDictLookup(name)) |m| break :blk m;
                if (dictmethods.lookup(name)) |m| {
                    self_for_method = Value{ .dict = od.data };
                    break :blk m;
                }
                break :blk null;
            },
            .defaultdict => |dd| blk: {
                if (dictmethods.lookup(name)) |m| {
                    self_for_method = Value{ .dict = dd.data };
                    break :blk m;
                }
                break :blk null;
            },
            .named_tuple => collmethods.ntLookup(name),
            else => null,
        };
        if (method) |m| {
            frame.push(Value{ .builtin_fn = m });
            frame.push(self_for_method);
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

pub fn invokeKwPub(
    interp: *Interp,
    callable: Value,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) !Value {
    return invokeKw(interp, callable, args, kw_names, kw_values);
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
        .bound_method => |bm| {
            const buf = try interp.allocator.alloc(Value, positional.len + 1);
            defer interp.allocator.free(buf);
            buf[0] = bm.self;
            @memcpy(buf[1..], positional);
            return invokeKw(interp, bm.func, buf, kw_names, kw_values);
        },
        .partial => |p| {
            const merged_args = try interp.allocator.alloc(Value, p.args.len + positional.len);
            defer interp.allocator.free(merged_args);
            @memcpy(merged_args[0..p.args.len], p.args);
            @memcpy(merged_args[p.args.len..], positional);
            // Call-time kwargs override bound ones. Walk the bound list,
            // skip any name that the call also provides, then concat the
            // call-side names verbatim.
            var name_buf: std.ArrayList(Value) = .empty;
            defer name_buf.deinit(interp.allocator);
            var val_buf: std.ArrayList(Value) = .empty;
            defer val_buf.deinit(interp.allocator);
            for (p.kw_names, p.kw_values) |bn, bv| {
                var shadowed = false;
                for (kw_names) |cn| {
                    if (bn == .str and cn == .str and std.mem.eql(u8, bn.str.bytes, cn.str.bytes)) {
                        shadowed = true;
                        break;
                    }
                }
                if (!shadowed) {
                    try name_buf.append(interp.allocator, bn);
                    try val_buf.append(interp.allocator, bv);
                }
            }
            for (kw_names, kw_values) |cn, cv| {
                try name_buf.append(interp.allocator, cn);
                try val_buf.append(interp.allocator, cv);
            }
            return invokeKw(interp, p.func, merged_args, name_buf.items, val_buf.items);
        },
        .cached_fn => |c| {
            const CachedFn = @import("../object/cached_fn.zig").CachedFn;
            const key = try CachedFn.compositeKey(interp.allocator, positional, kw_names, kw_values);
            // Linear scan -- the cache holds at most `maxsize` entries
            // and the fixture sticks to small N. Found-index lets us
            // touch the LRU order without a second lookup.
            var found_idx: ?usize = null;
            for (c.cache.pairs.items, 0..) |p, i| {
                if (p.key.equals(key)) {
                    found_idx = i;
                    break;
                }
            }
            if (found_idx) |idx| {
                const hit = c.cache.pairs.items[idx].value;
                // LRU touch: move to the back of the ordered list.
                const pair = c.cache.pairs.items[idx];
                _ = c.cache.pairs.orderedRemove(idx);
                try c.cache.pairs.append(interp.allocator, pair);
                c.hits += 1;
                return hit;
            }
            c.misses += 1;
            const result = try invokeKw(interp, c.func, positional, kw_names, kw_values);
            // Evict LRU entry (the oldest) if at capacity.
            if (c.maxsize) |ms| {
                if (c.cache.pairs.items.len >= ms and ms > 0) {
                    _ = c.cache.pairs.orderedRemove(0);
                }
            }
            try c.cache.pairs.append(interp.allocator, .{ .key = key, .value = result });
            return result;
        },
        .function => |fn_val| return callPyFunction(interp, fn_val, positional, kw_names, kw_values, null),
        .class => |cls| return instantiate(interp, cls, positional, kw_names, kw_values),
        .named_tuple_factory => |f| {
            const NamedTuple = @import("../object/named_tuple.zig").NamedTuple;
            const items = try interp.allocator.alloc(Value, f.fields.len);
            var filled = try interp.allocator.alloc(bool, f.fields.len);
            defer interp.allocator.free(filled);
            for (filled) |*b| b.* = false;
            if (positional.len > f.fields.len) {
                try interp.raisePy("TypeError", "namedtuple: too many positional arguments");
                return error.PyException;
            }
            for (positional, 0..) |v, i| {
                items[i] = v;
                filled[i] = true;
            }
            for (kw_names, kw_values) |kn, kv| {
                if (kn != .str) continue;
                var matched = false;
                for (f.fields, 0..) |fname, i| {
                    if (std.mem.eql(u8, fname, kn.str.bytes)) {
                        if (filled[i]) {
                            try interp.raisePy("TypeError", "namedtuple: multiple values for field");
                            return error.PyException;
                        }
                        items[i] = kv;
                        filled[i] = true;
                        matched = true;
                        break;
                    }
                }
                if (!matched) {
                    try interp.raisePy("TypeError", "namedtuple: unexpected field");
                    return error.PyException;
                }
            }
            // Defaults align with the trailing fields. CPython:
            // `defaults` of length D applies to the last D fields.
            if (f.defaults.len > 0) {
                const start = f.fields.len - f.defaults.len;
                for (f.defaults, 0..) |dv, k| {
                    const i = start + k;
                    if (!filled[i]) {
                        items[i] = dv;
                        filled[i] = true;
                    }
                }
            }
            for (filled) |b| {
                if (!b) {
                    try interp.raisePy("TypeError", "namedtuple: missing field");
                    return error.PyException;
                }
            }
            const nt = try NamedTuple.init(interp.allocator, f, items);
            return Value{ .named_tuple = nt };
        },
        .instance => {
            if (try @import("dunder.zig").call(interp, callable, "__call__", positional)) |r| return r;
            try interp.typeError("object is not callable");
            return error.TypeError;
        },
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

pub fn genAwaitBuiltin(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .generator) return error.TypeError;
    return args[0];
}

var gen_await_method: value_mod.BuiltinFn = .{ .name = "__await__", .func = genAwaitBuiltin };

/// `prop.setter(fn)`, `prop.deleter(fn)`, `prop.getter(fn)`. Each
/// returns a new property descriptor with the corresponding slot
/// replaced. Bound-method form receives the property as args[0].
fn propertySetterImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2 or args[0] != .descriptor) {
        try interp.typeError("property.setter expects (self, fn)");
        return error.TypeError;
    }
    const old = args[0].descriptor;
    const Descriptor = @import("../object/descriptor.zig").Descriptor;
    const new = try Descriptor.init(interp.allocator, .property, old.func);
    new.fset = args[1];
    new.fdel = old.fdel;
    return Value{ .descriptor = new };
}

fn propertyDeleterImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2 or args[0] != .descriptor) {
        try interp.typeError("property.deleter expects (self, fn)");
        return error.TypeError;
    }
    const old = args[0].descriptor;
    const Descriptor = @import("../object/descriptor.zig").Descriptor;
    const new = try Descriptor.init(interp.allocator, .property, old.func);
    new.fset = old.fset;
    new.fdel = args[1];
    return Value{ .descriptor = new };
}

fn propertyGetterImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 2 or args[0] != .descriptor) {
        try interp.typeError("property.getter expects (self, fn)");
        return error.TypeError;
    }
    const old = args[0].descriptor;
    const Descriptor = @import("../object/descriptor.zig").Descriptor;
    const new = try Descriptor.init(interp.allocator, .property, args[1]);
    new.fset = old.fset;
    new.fdel = old.fdel;
    return Value{ .descriptor = new };
}

var property_setter_method: value_mod.BuiltinFn = .{ .name = "setter", .func = propertySetterImpl };
var property_deleter_method: value_mod.BuiltinFn = .{ .name = "deleter", .func = propertyDeleterImpl };
var property_getter_method: value_mod.BuiltinFn = .{ .name = "getter", .func = propertyGetterImpl };

pub fn complexConjugateBuiltin(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    _ = interp_opaque;
    if (args.len != 1 or args[0] != .complex_num) return error.TypeError;
    const c = args[0].complex_num;
    return Value{ .complex_num = .{ .re = c.re, .im = -c.im } };
}

var complex_conjugate_method: value_mod.BuiltinFn = .{ .name = "conjugate", .func = complexConjugateBuiltin };

fn cacheInfoImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1 or args[0] != .cached_fn) {
        try interp.typeError("cache_info expects cached function");
        return error.TypeError;
    }
    const c = args[0].cached_fn;
    const t = try Tuple.init(interp.allocator, 4);
    t.items[0] = Value{ .small_int = @intCast(c.hits) };
    t.items[1] = Value{ .small_int = @intCast(c.misses) };
    t.items[2] = if (c.maxsize) |m| Value{ .small_int = @intCast(m) } else Value.none;
    t.items[3] = Value{ .small_int = @intCast(c.cache.pairs.items.len) };
    return Value{ .tuple = t };
}

fn cacheClearImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1 or args[0] != .cached_fn) {
        try interp.typeError("cache_clear expects cached function");
        return error.TypeError;
    }
    const c = args[0].cached_fn;
    c.hits = 0;
    c.misses = 0;
    c.cache.pairs.clearRetainingCapacity();
    return Value.none;
}

var cache_info_method: value_mod.BuiltinFn = .{ .name = "cache_info", .func = cacheInfoImpl };
var cache_clear_method: value_mod.BuiltinFn = .{ .name = "cache_clear", .func = cacheClearImpl };

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
    return buildClassKw(interp_opaque, args, &.{}, &.{});
}

pub fn buildClassKw(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
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
    // PEP 487: notify descriptors of their owner+name, then notify any
    // parent class's `__init_subclass__` of the new subclass.
    for (ns.keys.items) |attr_name| {
        const v = ns.getStr(attr_name) orelse continue;
        if (v == .cached_property) {
            v.cached_property.name = attr_name;
            continue;
        }
        if (v != .instance) continue;
        if (dunder.lookup(v, "__set_name__") == null) continue;
        const name_str = try Str.init(interp.allocator, attr_name);
        _ = try dunder.call(interp, v, "__set_name__", &.{ Value{ .class = cls }, Value{ .str = name_str } });
    }
    if (n_bases > 0) {
        var i: usize = 1;
        while (i < cls.mro.len) : (i += 1) {
            if (cls.mro[i].dict.getStr("__init_subclass__")) |hook| {
                _ = try invokeKw(interp, hook, &.{Value{ .class = cls }}, kw_names, kw_values);
                break;
            }
        }
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
