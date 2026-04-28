//! Pinhole `curses.panel` module with a per-interpreter panel stack.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

fn reg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regM(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn stackFind(interp: *Interp, v: Value) ?usize {
    if (v != .instance) return null;
    for (interp.curses_panel_stack.items, 0..) |item, i| {
        if (item == .instance and item.instance == v.instance) return i;
    }
    return null;
}

fn isHidden(v: Value) bool {
    if (v != .instance) return false;
    const hv = v.instance.dict.getStr("_hidden") orelse return false;
    return hv == .boolean and hv.boolean;
}

// ===== Panel methods =====

fn panelWindow(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value.none;
    return args[0].instance.dict.getStr("_window") orelse Value.none;
}

fn panelHidden(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value{ .boolean = false };
    const v = args[0].instance.dict.getStr("_hidden") orelse return Value{ .boolean = false };
    return v;
}

fn panelHide(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return Value.none;
    try args[0].instance.dict.setStr(interp.allocator, "_hidden", Value{ .boolean = true });
    return Value.none;
}

fn panelShow(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return Value.none;
    try args[0].instance.dict.setStr(interp.allocator, "_hidden", Value{ .boolean = false });
    return Value.none;
}

fn panelSetUserptr(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return Value.none;
    try args[0].instance.dict.setStr(interp.allocator, "_userptr", args[1]);
    return Value.none;
}

fn panelUserptr(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value.none;
    return args[0].instance.dict.getStr("_userptr") orelse Value.none;
}

fn panelReplace(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return Value.none;
    try args[0].instance.dict.setStr(interp.allocator, "_window", args[1]);
    return Value.none;
}

fn panelMove(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn panelTop(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const self = args[0];
    if (stackFind(interp, self)) |idx| {
        _ = interp.curses_panel_stack.orderedRemove(idx);
        try interp.curses_panel_stack.append(a, self);
    }
    return Value.none;
}

fn panelBottom(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const self = args[0];
    if (stackFind(interp, self)) |idx| {
        _ = interp.curses_panel_stack.orderedRemove(idx);
        try interp.curses_panel_stack.insert(a, 0, self);
    }
    return Value.none;
}

fn panelAbove(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const self = args[0];
    if (stackFind(interp, self)) |idx| {
        if (idx + 1 < interp.curses_panel_stack.items.len) return interp.curses_panel_stack.items[idx + 1];
    }
    return Value.none;
}

fn panelBelow(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const self = args[0];
    if (stackFind(interp, self)) |idx| {
        if (idx > 0) return interp.curses_panel_stack.items[idx - 1];
    }
    return Value.none;
}

fn getOrCreatePanelClass(interp: *Interp) !*Class {
    if (interp.curses_panel_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try reg(a, d, "window", panelWindow);
    try reg(a, d, "hidden", panelHidden);
    try reg(a, d, "hide", panelHide);
    try reg(a, d, "show", panelShow);
    try reg(a, d, "set_userptr", panelSetUserptr);
    try reg(a, d, "userptr", panelUserptr);
    try reg(a, d, "replace", panelReplace);
    try reg(a, d, "above", panelAbove);
    try reg(a, d, "below", panelBelow);
    try reg(a, d, "move", panelMove);
    try reg(a, d, "top", panelTop);
    try reg(a, d, "bottom", panelBottom);
    const cls = try Class.init(a, "panel", &.{}, d);
    interp.curses_panel_class = cls;
    return cls;
}

// ===== Module-level functions =====

fn newPanelFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const win = if (args.len >= 1) args[0] else Value.none;
    const cls = try getOrCreatePanelClass(interp);
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "_window", win);
    try inst.dict.setStr(a, "_hidden", Value{ .boolean = false });
    const v = Value{ .instance = inst };
    try interp.curses_panel_stack.append(a, v);
    return v;
}

fn topPanelFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var i = interp.curses_panel_stack.items.len;
    while (i > 0) {
        i -= 1;
        if (!isHidden(interp.curses_panel_stack.items[i])) return interp.curses_panel_stack.items[i];
    }
    return Value.none;
}

fn bottomPanelFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    for (interp.curses_panel_stack.items) |item| {
        if (!isHidden(item)) return item;
    }
    return Value.none;
}

fn updatePanelsFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "curses.panel");

    interp.curses_panel_class = null;
    interp.curses_panel_stack = .empty;

    const cls = try getOrCreatePanelClass(interp);
    try m.attrs.setStr(a, "panel", Value{ .class = cls });

    try regM(a, m, "new_panel", newPanelFn);
    try regM(a, m, "top_panel", topPanelFn);
    try regM(a, m, "bottom_panel", bottomPanelFn);
    try regM(a, m, "update_panels", updatePanelsFn);

    return m;
}
