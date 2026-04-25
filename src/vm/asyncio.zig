//! A pinhole `asyncio` module: enough to run the fixture's
//! `asyncio.run(main())` with `await asyncio.sleep(0)` inside. There's
//! no event loop and no concurrency — `run` drives a single coroutine
//! to completion by repeatedly sending None, and `sleep` returns a
//! synthetic generator that's already finished so the await loop
//! short-circuits on first SEND.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const Module = @import("../object/module.zig").Module;
const Generator = @import("../object/generator.zig").Generator;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "asyncio");

    const sleep_fn = try interp.allocator.create(BuiltinFn);
    sleep_fn.* = .{ .name = "sleep", .func = sleepFn };
    try m.attrs.setStr(interp.allocator, "sleep", Value{ .builtin_fn = sleep_fn });

    const run_fn = try interp.allocator.create(BuiltinFn);
    run_fn.* = .{ .name = "run", .func = runFn };
    try m.attrs.setStr(interp.allocator, "run", Value{ .builtin_fn = run_fn });

    const gather_fn = try interp.allocator.create(BuiltinFn);
    gather_fn.* = .{ .name = "gather", .func = gatherFn };
    try m.attrs.setStr(interp.allocator, "gather", Value{ .builtin_fn = gather_fn });

    return m;
}

/// `asyncio.sleep(delay, result=None)` — ignore `delay` and hand back
/// an already-finished synthetic generator carrying `result` as its
/// return value. `await` SENDs once, hits StopIteration, and the
/// stop-value (i.e. `result`) becomes the await expression's value.
fn sleepFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const result: Value = if (args.len >= 2) args[1] else Value.none;
    const g = try interp.allocator.create(Generator);
    g.* = .{ .frame = undefined, .finished = true, .started = true, .return_value = result };
    return Value{ .generator = g };
}

/// `asyncio.run(coro)` — drive `coro` to completion by repeatedly
/// sending None. The loop is the same shape as `await`, just spelled
/// in Zig: when the coroutine yields, we keep going; when it raises
/// StopIteration, we return its value.
fn runFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.typeError("asyncio.run() takes exactly one argument");
        return error.TypeError;
    }
    const coro = switch (args[0]) {
        .generator => |g| g,
        else => {
            try interp.typeError("asyncio.run() argument must be a coroutine");
            return error.TypeError;
        },
    };
    while (try dispatch.genResume(interp, coro, Value.none)) |_| {}
    return coro.return_value;
}

/// `asyncio.gather(*coros)` — run each coroutine to completion, in
/// argument order, and hand back a synthetic finished Generator whose
/// `return_value` is the list of results. Real asyncio interleaves
/// these on an event loop; we don't have one, but the fixtures don't
/// observe interleaving — they only see the final list.
fn gatherFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    const List = @import("../object/list.zig").List;
    const out = try List.init(interp.allocator);
    for (args) |a| {
        const coro = switch (a) {
            .generator => |g| g,
            else => {
                try interp.typeError("asyncio.gather: argument is not awaitable");
                return error.TypeError;
            },
        };
        while (try dispatch.genResume(interp, coro, Value.none)) |_| {}
        try out.append(interp.allocator, coro.return_value);
    }
    const g = try interp.allocator.create(Generator);
    g.* = .{ .frame = undefined, .finished = true, .started = true, .return_value = Value{ .list = out } };
    return Value{ .generator = g };
}
