//! Pinhole `contextlib` module.
//!
//! Implements: contextmanager, suppress, nullcontext, closing, ExitStack.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const Module = @import("../object/module.zig").Module;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Descriptor = @import("../object/descriptor.zig").Descriptor;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");
const io_mod = @import("io_mod.zig");

// ===== contextmanager =====
// contextmanager(fn) returns an Instance whose __call__ wraps the generator.
// When called, __call__ produces a _GeneratorContextManager instance with
// __enter__ (resume generator, return yielded value) and __exit__ (resume to
// end, swallow StopIteration).

fn contextmanagerBuiltin(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1) {
        try interp.typeError("contextmanager() takes one argument");
        return error.TypeError;
    }
    const cls = try getOrCreateCmClass(interp);
    const inst = try Instance.init(interp.allocator, cls);
    try inst.dict.setStr(interp.allocator, "__wrapped__", args[0]);
    return Value{ .instance = inst };
}

/// contextmanager wrapper class -- its __call__ creates a
/// _GeneratorContextManager for each with-block.
fn getOrCreateCmClass(interp: *Interp) !*Class {
    const m = interp.contextlib_module orelse return error.NameError;
    if (m.attrs.getStr("_cm_class")) |v| if (v == .class) return v.class;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const call_fn = try a.create(BuiltinFn);
    call_fn.* = .{ .name = "__call__", .func = cmWrapperCall };
    try d.setStr(a, "__call__", Value{ .builtin_fn = call_fn });
    const cls = try Class.init(a, "_CmWrapper", &.{}, d);
    try m.attrs.setStr(a, "_cm_class", Value{ .class = cls });
    return cls;
}

/// _CmWrapper.__call__(*args, **kw) -> _GeneratorContextManager instance.
fn cmWrapperCall(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) {
        try interp.typeError("contextmanager wrapper called without self");
        return error.TypeError;
    }
    const wrapped = args[0].instance.dict.getStr("__wrapped__") orelse {
        try interp.typeError("contextmanager wrapper missing __wrapped__");
        return error.TypeError;
    };
    // Call the original generator function with the remaining positional args.
    const inner_args = args[1..];
    const gen_val = try dispatch.invoke(interp, wrapped, inner_args);
    // gen_val should be a generator.
    if (gen_val != .generator) {
        try interp.typeError("contextmanager: wrapped function must return a generator");
        return error.TypeError;
    }
    const gcm_cls = try getOrCreateGcmClass(interp);
    const gcm = try Instance.init(interp.allocator, gcm_cls);
    try gcm.dict.setStr(interp.allocator, "_gen", gen_val);
    return Value{ .instance = gcm };
}

/// _GeneratorContextManager class with __enter__ and __exit__.
fn getOrCreateGcmClass(interp: *Interp) !*Class {
    const m = interp.contextlib_module orelse return error.NameError;
    if (m.attrs.getStr("_gcm_class")) |v| if (v == .class) return v.class;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const enter_fn = try a.create(BuiltinFn);
    enter_fn.* = .{ .name = "__enter__", .func = gcmEnter };
    try d.setStr(a, "__enter__", Value{ .builtin_fn = enter_fn });
    const exit_fn = try a.create(BuiltinFn);
    exit_fn.* = .{ .name = "__exit__", .func = gcmExit };
    try d.setStr(a, "__exit__", Value{ .builtin_fn = exit_fn });
    const cls = try Class.init(a, "_GeneratorContextManager", &.{}, d);
    try m.attrs.setStr(a, "_gcm_class", Value{ .class = cls });
    return cls;
}

fn gcmEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const gen_v = args[0].instance.dict.getStr("_gen") orelse return Value.none;
    if (gen_v != .generator) return Value.none;
    // Advance the generator to its first yield; return the yielded value.
    const yielded = try dispatch.genResume(interp, gen_v.generator, Value.none);
    return yielded orelse Value.none;
}

fn gcmExit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    // args: (self, exc_type, exc_val, exc_tb)
    if (args.len < 1 or args[0] != .instance) return Value{ .boolean = false };
    const gen_v = args[0].instance.dict.getStr("_gen") orelse return Value{ .boolean = false };
    if (gen_v != .generator) return Value{ .boolean = false };
    const gen = gen_v.generator;
    if (gen.finished) return Value{ .boolean = false };
    // Check if there was an exception (exc_type != None).
    const has_exc = args.len >= 2 and args[1] != .none and args[1] != .null_sentinel;
    _ = has_exc;
    // Resume the generator to run the finally/cleanup code.
    // We ignore the return value; if generator raises StopIteration that's fine.
    _ = dispatch.genResume(interp, gen, Value.none) catch |err| {
        // StopIteration is expected -- the generator exited normally.
        if (err == error.PyException) {
            const exc = interp.current_exc;
            // If the exception is StopIteration, swallow it.
            if (exc) |e| {
                if (e == .instance) {
                    const cls_name = e.instance.cls.name;
                    if (std.mem.eql(u8, cls_name, "StopIteration")) {
                        interp.current_exc = null;
                    }
                }
            }
        }
    };
    // Don't suppress exceptions from the with-body.
    return Value{ .boolean = false };
}

// ===== suppress =====

fn suppressBuiltin(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const cls = try getOrCreateSuppressClass(interp);
    const inst = try Instance.init(interp.allocator, cls);
    // Store the exception types to suppress as a tuple.
    const t = try Tuple.init(interp.allocator, args.len);
    for (args, 0..) |a, i| t.items[i] = a;
    try inst.dict.setStr(interp.allocator, "_types", Value{ .tuple = t });
    return Value{ .instance = inst };
}

fn getOrCreateSuppressClass(interp: *Interp) !*Class {
    const m = interp.contextlib_module orelse return error.NameError;
    if (m.attrs.getStr("_suppress_class")) |v| if (v == .class) return v.class;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const enter_fn = try a.create(BuiltinFn);
    enter_fn.* = .{ .name = "__enter__", .func = suppressEnter };
    try d.setStr(a, "__enter__", Value{ .builtin_fn = enter_fn });
    const exit_fn = try a.create(BuiltinFn);
    exit_fn.* = .{ .name = "__exit__", .func = suppressExit };
    try d.setStr(a, "__exit__", Value{ .builtin_fn = exit_fn });
    const cls = try Class.init(a, "_Suppress", &.{}, d);
    try m.attrs.setStr(a, "_suppress_class", Value{ .class = cls });
    return cls;
}

fn suppressEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value.none;
}

fn suppressExit(p: *anyopaque, args: []const Value) anyerror!Value {
    // args: (self, exc_type, exc_val, exc_tb)
    _ = p;
    if (args.len < 2 or args[0] != .instance) return Value{ .boolean = false };
    const exc_type = args[1];
    if (exc_type == .none or exc_type == .null_sentinel) return Value{ .boolean = false };
    const types_v = args[0].instance.dict.getStr("_types") orelse return Value{ .boolean = false };
    if (types_v != .tuple) return Value{ .boolean = false };
    // Check if exc_type is in the suppressed types.
    // exc_type is a class; exc_val is the instance.
    // Walk the exception's MRO against the suppressed classes.
    const exc_val = if (args.len >= 3) args[2] else Value.none;
    if (exc_val == .instance) {
        for (types_v.tuple.items) |t| {
            if (t != .class) continue;
            for (exc_val.instance.cls.mro) |c| {
                if (c == t.class) return Value{ .boolean = true };
            }
        }
    }
    return Value{ .boolean = false };
}

// ===== nullcontext =====

fn nullcontextBuiltin(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const cls = try getOrCreateNullcontextClass(interp);
    const inst = try Instance.init(interp.allocator, cls);
    const enter_val = if (args.len >= 1) args[0] else Value.none;
    try inst.dict.setStr(interp.allocator, "_value", enter_val);
    return Value{ .instance = inst };
}

fn getOrCreateNullcontextClass(interp: *Interp) !*Class {
    const m = interp.contextlib_module orelse return error.NameError;
    if (m.attrs.getStr("_nc_class")) |v| if (v == .class) return v.class;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const enter_fn = try a.create(BuiltinFn);
    enter_fn.* = .{ .name = "__enter__", .func = ncEnter };
    try d.setStr(a, "__enter__", Value{ .builtin_fn = enter_fn });
    const exit_fn = try a.create(BuiltinFn);
    exit_fn.* = .{ .name = "__exit__", .func = ncExit };
    try d.setStr(a, "__exit__", Value{ .builtin_fn = exit_fn });
    const cls = try Class.init(a, "nullcontext", &.{}, d);
    try m.attrs.setStr(a, "_nc_class", Value{ .class = cls });
    return cls;
}

fn ncEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    return args[0].instance.dict.getStr("_value") orelse Value.none;
}

fn ncExit(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value{ .boolean = false };
}

// ===== closing =====

fn closingBuiltin(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len != 1) {
        try interp.typeError("closing() takes one argument");
        return error.TypeError;
    }
    const cls = try getOrCreateClosingClass(interp);
    const inst = try Instance.init(interp.allocator, cls);
    try inst.dict.setStr(interp.allocator, "_thing", args[0]);
    return Value{ .instance = inst };
}

fn getOrCreateClosingClass(interp: *Interp) !*Class {
    const m = interp.contextlib_module orelse return error.NameError;
    if (m.attrs.getStr("_closing_class")) |v| if (v == .class) return v.class;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const enter_fn = try a.create(BuiltinFn);
    enter_fn.* = .{ .name = "__enter__", .func = closingEnter };
    try d.setStr(a, "__enter__", Value{ .builtin_fn = enter_fn });
    const exit_fn = try a.create(BuiltinFn);
    exit_fn.* = .{ .name = "__exit__", .func = closingExit };
    try d.setStr(a, "__exit__", Value{ .builtin_fn = exit_fn });
    const cls = try Class.init(a, "closing", &.{}, d);
    try m.attrs.setStr(a, "_closing_class", Value{ .class = cls });
    return cls;
}

fn closingEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    return args[0].instance.dict.getStr("_thing") orelse Value.none;
}

fn closingExit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return Value{ .boolean = false };
    const thing = args[0].instance.dict.getStr("_thing") orelse return Value{ .boolean = false };
    // Call thing.close()
    _ = dispatch.loadAttrValue(interp, thing, "close") catch return Value{ .boolean = false };
    if (dispatch.loadAttrValue(interp, thing, "close")) |close_fn| {
        _ = dispatch.invoke(interp, close_fn, &.{}) catch {};
    } else |_| {}
    return Value{ .boolean = false };
}

// ===== ExitStack =====

fn getOrCreateExitStackClass(interp: *Interp) !*Class {
    const m = interp.contextlib_module orelse return error.NameError;
    if (m.attrs.getStr("_exitstack_class")) |v| if (v == .class) return v.class;
    const a = interp.allocator;
    const d = try Dict.init(a);

    const enter_fn = try a.create(BuiltinFn);
    enter_fn.* = .{ .name = "__enter__", .func = esEnter };
    try d.setStr(a, "__enter__", Value{ .builtin_fn = enter_fn });

    const exit_fn = try a.create(BuiltinFn);
    exit_fn.* = .{ .name = "__exit__", .func = esExit };
    try d.setStr(a, "__exit__", Value{ .builtin_fn = exit_fn });

    const enter_ctx_fn = try a.create(BuiltinFn);
    enter_ctx_fn.* = .{ .name = "enter_context", .func = esEnterContext };
    try d.setStr(a, "enter_context", Value{ .builtin_fn = enter_ctx_fn });

    const callback_fn = try a.create(BuiltinFn);
    callback_fn.* = .{ .name = "callback", .func = esCallback };
    try d.setStr(a, "callback", Value{ .builtin_fn = callback_fn });

    const cls = try Class.init(a, "ExitStack", &.{}, d);
    try m.attrs.setStr(a, "_exitstack_class", Value{ .class = cls });
    return cls;
}

fn exitStackBuiltin(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const cls = try getOrCreateExitStackClass(interp);
    const inst = try Instance.init(interp.allocator, cls);
    // _callbacks: list of (exit_fn, ctx_instance_or_null) pairs stored as flat list
    // We store a List of Values; each entry is a tuple (exit_callable, args_tuple)
    const cb_list = try List.init(interp.allocator);
    try inst.dict.setStr(interp.allocator, "_callbacks", Value{ .list = cb_list });
    return Value{ .instance = inst };
}

fn esEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    return Value{ .instance = args[0].instance };
}

fn esEnterContext(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    // args: (self, cm)
    if (args.len < 2 or args[0] != .instance) return Value.none;
    const self = args[0].instance;
    const cm = args[1];
    // Call cm.__enter__() -- pass cm as self since loadAttrValue doesn't bind builtins.
    const enter_fn = dispatch.loadAttrValue(interp, cm, "__enter__") catch return Value.none;
    const enter_val = try callWithSelf(interp, enter_fn, cm);
    // Push cm.__exit__ onto the callback stack (we store cm + exit_fn together).
    const exit_fn = dispatch.loadAttrValue(interp, cm, "__exit__") catch return Value.none;
    const cb_list_v = self.dict.getStr("_callbacks") orelse return Value.none;
    if (cb_list_v != .list) return Value.none;
    // Store (exit_fn, cm) so we can call exit_fn(cm, None, None, None) later.
    const entry = try Tuple.init(interp.allocator, 3);
    entry.items[0] = exit_fn;
    entry.items[1] = cm; // the context manager (self for __exit__)
    entry.items[2] = Value{ .boolean = true }; // marks as __exit__ style
    try cb_list_v.list.items.append(interp.allocator, Value{ .tuple = entry });
    return enter_val;
}

fn esCallback(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    // args: (self, callback, *cb_args)
    if (args.len < 2 or args[0] != .instance) return Value.none;
    const self = args[0].instance;
    const cb = args[1];
    const cb_args = args[2..];
    const cb_list_v = self.dict.getStr("_callbacks") orelse return Value.none;
    if (cb_list_v != .list) return Value.none;
    // Store as a tuple (callback, args_tuple) where args_tuple holds cb_args.
    const entry = try Tuple.init(interp.allocator, 2);
    entry.items[0] = cb;
    // Pack callback args.
    const t = try Tuple.init(interp.allocator, cb_args.len);
    @memcpy(t.items, cb_args);
    entry.items[1] = Value{ .tuple = t };
    try cb_list_v.list.items.append(interp.allocator, Value{ .tuple = entry });
    return Value.none;
}

fn esExit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return Value{ .boolean = false };
    const self = args[0].instance;
    const cb_list_v = self.dict.getStr("_callbacks") orelse return Value{ .boolean = false };
    if (cb_list_v != .list) return Value{ .boolean = false };
    // Run callbacks in reverse order (LIFO).
    const items = cb_list_v.list.items.items;
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        const entry = items[i];
        if (entry != .tuple) continue;
        const t = entry.tuple.items;
        if (t.len >= 3 and t[2] == .boolean and t[2].boolean) {
            // __exit__ style: tuple is (exit_fn, cm, true)
            const exit_fn = t[0];
            const cm = t[1];
            _ = callWithSelfAndArgs(interp, exit_fn, cm, &.{ Value.none, Value.none, Value.none }) catch {};
        } else if (t.len >= 2) {
            // callback style: tuple is (callback, args_tuple)
            const callable = t[0];
            const cb_args_v = t[1];
            if (cb_args_v == .tuple) {
                _ = dispatch.invoke(interp, callable, cb_args_v.tuple.items) catch {};
            } else {
                _ = dispatch.invoke(interp, callable, &.{}) catch {};
            }
        }
    }
    return Value{ .boolean = false };
}

/// Call `callable` with `self` prepended only when `callable` is a
/// raw `builtin_fn` (not already a bound_method). This is needed because
/// `loadAttrValue` doesn't bind builtin_fn methods to the instance.
fn callWithSelf(interp: *Interp, callable: Value, self: Value) !Value {
    switch (callable) {
        .builtin_fn => return try dispatch.invoke(interp, callable, &.{self}),
        .bound_method => return try dispatch.invoke(interp, callable, &.{}),
        else => return try dispatch.invoke(interp, callable, &.{self}),
    }
}

fn callWithSelfAndArgs(interp: *Interp, callable: Value, self: Value, extra: []const Value) !Value {
    switch (callable) {
        .builtin_fn => {
            const buf = try interp.allocator.alloc(Value, extra.len + 1);
            defer interp.allocator.free(buf);
            buf[0] = self;
            @memcpy(buf[1..], extra);
            return try dispatch.invoke(interp, callable, buf);
        },
        .bound_method => return try dispatch.invoke(interp, callable, extra),
        else => {
            const buf = try interp.allocator.alloc(Value, extra.len + 1);
            defer interp.allocator.free(buf);
            buf[0] = self;
            @memcpy(buf[1..], extra);
            return try dispatch.invoke(interp, callable, buf);
        },
    }
}

// ===== redirect_stdout =====

fn redirectStdoutBuiltin(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const cls = try getOrCreateRedirectStdoutClass(interp);
    const inst = try Instance.init(interp.allocator, cls);
    if (args.len >= 1) try inst.dict.setStr(interp.allocator, "_target", args[0]);
    return Value{ .instance = inst };
}

fn getOrCreateRedirectStdoutClass(interp: *Interp) !*Class {
    const m = interp.contextlib_module orelse return error.NameError;
    if (m.attrs.getStr("_redirect_stdout_class")) |v| if (v == .class) return v.class;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const enter_fn = try a.create(BuiltinFn);
    enter_fn.* = .{ .name = "__enter__", .func = redirectStdoutEnter };
    try d.setStr(a, "__enter__", Value{ .builtin_fn = enter_fn });
    const exit_fn = try a.create(BuiltinFn);
    exit_fn.* = .{ .name = "__exit__", .func = redirectStdoutExit };
    try d.setStr(a, "__exit__", Value{ .builtin_fn = exit_fn });
    const cls = try Class.init(a, "_RedirectStdout", &.{}, d);
    try m.attrs.setStr(a, "_redirect_stdout_class", Value{ .class = cls });
    return cls;
}

fn redirectStdoutEnter(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const self = args[0].instance;
    const target = self.dict.getStr("_target") orelse return Value.none;
    if (target != .instance) return Value.none;

    const data_list = io_mod.getStringIODataList(target.instance);

    // Allocate a growable writer backed by the StringIO's ArrayList
    const aw = try interp.allocator.create(std.Io.Writer.Allocating);
    aw.* = std.Io.Writer.Allocating.fromArrayList(interp.allocator, data_list);

    // Save old stdout pointer and store new allocating writer pointer
    try self.dict.setStr(interp.allocator, "_old_stdout", Value{ .small_int = @intCast(@intFromPtr(interp.stdout)) });
    try self.dict.setStr(interp.allocator, "_aw_ptr", Value{ .small_int = @intCast(@intFromPtr(aw)) });

    interp.stdout = &aw.writer;
    return Value.none;
}

fn redirectStdoutExit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return Value{ .boolean = false };
    const self = args[0].instance;

    // Flush before restoring
    interp.stdout.flush() catch {};

    // Get the allocating writer and move data back to StringIO
    const aw_v = self.dict.getStr("_aw_ptr") orelse return Value{ .boolean = false };
    const aw: *std.Io.Writer.Allocating = @ptrFromInt(@as(usize, @intCast(aw_v.small_int)));

    const target = self.dict.getStr("_target") orelse return Value{ .boolean = false };
    if (target == .instance) {
        const data_list = io_mod.getStringIODataList(target.instance);
        data_list.* = aw.toArrayList();
    } else {
        aw.deinit();
    }
    interp.allocator.destroy(aw);

    // Restore old stdout
    const old_v = self.dict.getStr("_old_stdout") orelse return Value{ .boolean = false };
    if (old_v == .small_int) {
        interp.stdout = @ptrFromInt(@as(usize, @intCast(old_v.small_int)));
    }

    return Value{ .boolean = false };
}

fn reg(a: std.mem.Allocator, m: *Module, name: []const u8, func: value_mod.BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "contextlib");
    interp.contextlib_module = m;

    try reg(a, m, "contextmanager", contextmanagerBuiltin);
    try reg(a, m, "suppress", suppressBuiltin);
    try reg(a, m, "nullcontext", nullcontextBuiltin);
    try reg(a, m, "closing", closingBuiltin);
    try reg(a, m, "ExitStack", exitStackBuiltin);
    try reg(a, m, "redirect_stdout", redirectStdoutBuiltin);

    return m;
}
