//! Pinhole `readline` module: in-memory history, line buffer, completer,
//! and stub hooks. The fixture exercises every public surface but never
//! crosses into a real terminal or init file.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

const default_delims = "\t\n !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";

const State = struct {
    history: std.ArrayList([]const u8) = .empty,
    history_length: i64 = -1,
    completer: ?Value = null,
    startup_hook: ?Value = null,
    pre_input_hook: ?Value = null,
    display_hook: ?Value = null,
    line_buffer: []const u8 = "",
    delims: []const u8 = default_delims,
};

var g_state: State = .{};
var g_alloc: ?std.mem.Allocator = null;

fn state(interp: *Interp) *State {
    g_alloc = interp.allocator;
    return &g_state;
}

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "readline");
    {
        const s = try Str.init(interp.allocator, "editline");
        try m.attrs.setStr(interp.allocator, "backend", Value{ .str = s });
    }
    try reg(interp, m, "parse_and_bind", parseAndBindFn);
    try reg(interp, m, "read_init_file", readInitFileFn);
    try reg(interp, m, "get_line_buffer", getLineBufferFn);
    try reg(interp, m, "insert_text", insertTextFn);
    try reg(interp, m, "redisplay", noneFn);
    try reg(interp, m, "read_history_file", noneFn);
    try reg(interp, m, "write_history_file", noneFn);
    try reg(interp, m, "append_history_file", noneFn);
    try reg(interp, m, "get_history_length", getHistoryLengthFn);
    try reg(interp, m, "set_history_length", setHistoryLengthFn);
    try reg(interp, m, "clear_history", clearHistoryFn);
    try reg(interp, m, "get_current_history_length", getCurrentHistoryLengthFn);
    try reg(interp, m, "get_history_item", getHistoryItemFn);
    try reg(interp, m, "remove_history_item", removeHistoryItemFn);
    try reg(interp, m, "replace_history_item", replaceHistoryItemFn);
    try reg(interp, m, "add_history", addHistoryFn);
    try reg(interp, m, "set_auto_history", noneFn);
    try reg(interp, m, "set_startup_hook", setStartupHookFn);
    try reg(interp, m, "set_pre_input_hook", setPreInputHookFn);
    try reg(interp, m, "set_completer", setCompleterFn);
    try reg(interp, m, "get_completer", getCompleterFn);
    try reg(interp, m, "get_completion_type", zeroFn);
    try reg(interp, m, "get_begidx", zeroFn);
    try reg(interp, m, "get_endidx", zeroFn);
    try reg(interp, m, "set_completer_delims", setCompleterDelimsFn);
    try reg(interp, m, "get_completer_delims", getCompleterDelimsFn);
    try reg(interp, m, "set_completion_display_matches_hook", setDisplayHookFn);
    return m;
}

fn reg(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn asInt(v: Value) ?i64 {
    return switch (v) {
        .small_int => |n| n,
        .boolean => |b| @intFromBool(b),
        else => null,
    };
}

fn isOptionalNone(args: []const Value) bool {
    return args.len == 0 or args[0] == .none;
}

fn noneFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn zeroFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .small_int = 0 };
}

fn parseAndBindFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn readInitFileFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try interp.raisePy("OSError", "[Errno -1] Unknown error: -1");
    return error.PyException;
}

fn getLineBufferFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try Str.init(interp.allocator, state(interp).line_buffer);
    return Value{ .str = s };
}

fn insertTextFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const st = state(interp);
    if (args.len > 0 and args[0] == .str) {
        const new_buf = try std.mem.concat(a, u8, &.{ st.line_buffer, args[0].str.bytes });
        if (st.line_buffer.len > 0) a.free(st.line_buffer);
        st.line_buffer = new_buf;
    }
    return Value.none;
}

fn getHistoryLengthFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .small_int = state(interp).history_length };
}

fn setHistoryLengthFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len > 0) if (asInt(args[0])) |n| {
        state(interp).history_length = n;
    };
    return Value.none;
}

fn clearHistoryFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const st = state(interp);
    for (st.history.items) |item| a.free(item);
    st.history.clearRetainingCapacity();
    return Value.none;
}

fn getCurrentHistoryLengthFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .small_int = @intCast(state(interp).history.items.len) };
}

fn getHistoryItemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.raisePy("TypeError", "get_history_item() missing argument");
        return error.PyException;
    }
    const n = asInt(args[0]) orelse {
        try interp.raisePy("TypeError", "get_history_item() argument must be int");
        return error.PyException;
    };
    const st = state(interp);
    const idx = n - 1; // 1-based
    if (idx < 0 or idx >= @as(i64, @intCast(st.history.items.len))) return Value.none;
    const s = try Str.init(a, st.history.items[@intCast(idx)]);
    return Value{ .str = s };
}

fn removeHistoryItemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.raisePy("TypeError", "remove_history_item() missing argument");
        return error.PyException;
    }
    const n = asInt(args[0]) orelse {
        try interp.raisePy("TypeError", "remove_history_item() argument must be int");
        return error.PyException;
    };
    const st = state(interp);
    if (n < 0 or n >= @as(i64, @intCast(st.history.items.len))) {
        try interp.raisePy("ValueError", "remove_history_item(): index out of range");
        return error.PyException;
    }
    const idx: usize = @intCast(n);
    a.free(st.history.items[idx]);
    _ = st.history.orderedRemove(idx);
    return Value.none;
}

fn replaceHistoryItemFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) {
        try interp.raisePy("TypeError", "replace_history_item() requires 2 arguments");
        return error.PyException;
    }
    const n = asInt(args[0]) orelse {
        try interp.raisePy("TypeError", "replace_history_item() first argument must be int");
        return error.PyException;
    };
    if (args[1] != .str) {
        try interp.raisePy("TypeError", "replace_history_item() second argument must be str");
        return error.PyException;
    }
    const st = state(interp);
    if (n < 0 or n >= @as(i64, @intCast(st.history.items.len))) {
        try interp.raisePy("ValueError", "replace_history_item(): index out of range");
        return error.PyException;
    }
    const idx: usize = @intCast(n);
    a.free(st.history.items[idx]);
    st.history.items[idx] = try a.dupe(u8, args[1].str.bytes);
    return Value.none;
}

fn addHistoryFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const st = state(interp);
    if (args.len > 0 and args[0] == .str) {
        const dup = try a.dupe(u8, args[0].str.bytes);
        try st.history.append(a, dup);
    }
    return Value.none;
}

fn setHook(slot: *?Value, args: []const Value) Value {
    if (isOptionalNone(args)) {
        slot.* = null;
    } else {
        slot.* = args[0];
    }
    return Value.none;
}

fn setStartupHookFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return setHook(&state(interp).startup_hook, args);
}

fn setPreInputHookFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return setHook(&state(interp).pre_input_hook, args);
}

fn setDisplayHookFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return setHook(&state(interp).display_hook, args);
}

fn setCompleterFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return setHook(&state(interp).completer, args);
}

fn getCompleterFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return state(interp).completer orelse Value.none;
}

fn setCompleterDelimsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const st = state(interp);
    if (args.len > 0 and args[0] == .str) {
        if (st.delims.ptr != default_delims.ptr) a.free(st.delims);
        st.delims = try a.dupe(u8, args[0].str.bytes);
    }
    return Value.none;
}

fn getCompleterDelimsFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try Str.init(interp.allocator, state(interp).delims);
    return Value{ .str = s };
}
