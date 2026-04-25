//! Synthetic traceback / frame / code wrappers. These let Python
//! probe `e.__traceback__.tb_frame.f_code.co_name` after a `raise`
//! without us reifying the full Python frame protocol.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const Class = @import("../object/class.zig").Class;
const Dict = @import("../object/dict.zig").Dict;
const Instance = @import("../object/instance.zig").Instance;
const Str = @import("../object/string.zig").Str;
const Frame = @import("frame.zig").Frame;
const Interp = @import("interp.zig").Interp;

fn ensureClass(a: std.mem.Allocator, slot: *?*Class, name: []const u8) !*Class {
    if (slot.*) |c| return c;
    const cls = try Class.init(a, name, &.{}, try Dict.init(a));
    slot.* = cls;
    return cls;
}

fn buildCode(interp: *Interp, frame: *Frame) !Value {
    const a = interp.allocator;
    const cls = try ensureClass(a, &interp.code_class, "code");
    const inst = try Instance.init(a, cls);
    const name = try Str.init(a, frame.code.name);
    const qual = try Str.init(a, frame.code.qualname);
    const file = try Str.init(a, frame.code.filename);
    try inst.dict.setStr(a, "co_name", Value{ .str = name });
    try inst.dict.setStr(a, "co_qualname", Value{ .str = qual });
    try inst.dict.setStr(a, "co_filename", Value{ .str = file });
    try inst.dict.setStr(a, "co_firstlineno", Value{ .small_int = frame.code.firstlineno });
    return Value{ .instance = inst };
}

fn buildFrame(interp: *Interp, frame: *Frame) !Value {
    const a = interp.allocator;
    const cls = try ensureClass(a, &interp.frame_class, "frame");
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "f_code", try buildCode(interp, frame));
    try inst.dict.setStr(a, "f_lineno", Value{ .small_int = frame.code.firstlineno });
    return Value{ .instance = inst };
}

/// Prepend a traceback wrapping `frame` to `current_exc.__traceback__`.
/// Idempotent on a single frame: if the head of the existing chain
/// already wraps `frame.code` we leave it alone, since each frame
/// records itself once on the way out of dispatch.
pub fn record(interp: *Interp, frame: *Frame) !void {
    const exc = interp.current_exc orelse return;
    if (exc != .instance) return;
    const a = interp.allocator;
    const tb_cls = try ensureClass(a, &interp.traceback_class, "traceback");
    const tb = try Instance.init(a, tb_cls);
    try tb.dict.setStr(a, "tb_frame", try buildFrame(interp, frame));
    try tb.dict.setStr(a, "tb_lineno", Value{ .small_int = frame.code.firstlineno });
    const prev = exc.instance.dict.getStr("__traceback__") orelse Value.none;
    try tb.dict.setStr(a, "tb_next", prev);
    try exc.instance.dict.setStr(a, "__traceback__", Value{ .instance = tb });
}
