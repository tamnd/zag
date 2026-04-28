//! Pinhole `curses` module.
//! Provides a stub curses implementation for testing.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Tuple = @import("../object/tuple.zig").Tuple;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

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

fn regMKw(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr, kw_func: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw_func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

// ===== Window helpers =====

fn makeWindow(interp: *Interp, rows: i64, cols: i64, begy: i64, begx: i64) !Value {
    const a = interp.allocator;
    const cls = interp.curses_window_class orelse return error.RuntimeError;
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "rows", Value{ .small_int = rows });
    try inst.dict.setStr(a, "cols", Value{ .small_int = cols });
    try inst.dict.setStr(a, "begy", Value{ .small_int = begy });
    try inst.dict.setStr(a, "begx", Value{ .small_int = begx });
    try inst.dict.setStr(a, "cury", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "curx", Value{ .small_int = 0 });
    return Value{ .instance = inst };
}

// ===== Window methods =====

fn winGetmaxyxI(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const rows = if (inst.dict.getStr("rows")) |v| switch (v) { .small_int => |n| n, else => 24 } else 24;
    const cols = if (inst.dict.getStr("cols")) |v| switch (v) { .small_int => |n| n, else => 80 } else 80;
    const t = try Tuple.init(a, 2);
    t.items[0] = Value{ .small_int = rows };
    t.items[1] = Value{ .small_int = cols };
    return Value{ .tuple = t };
}

fn winGetbegyx(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const begy = if (inst.dict.getStr("begy")) |v| switch (v) { .small_int => |n| n, else => 0 } else 0;
    const begx = if (inst.dict.getStr("begx")) |v| switch (v) { .small_int => |n| n, else => 0 } else 0;
    const t = try Tuple.init(a, 2);
    t.items[0] = Value{ .small_int = begy };
    t.items[1] = Value{ .small_int = begx };
    return Value{ .tuple = t };
}

fn winGetyx(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const cury = if (inst.dict.getStr("cury")) |v| switch (v) { .small_int => |n| n, else => 0 } else 0;
    const curx = if (inst.dict.getStr("curx")) |v| switch (v) { .small_int => |n| n, else => 0 } else 0;
    const t = try Tuple.init(a, 2);
    t.items[0] = Value{ .small_int = cury };
    t.items[1] = Value{ .small_int = curx };
    return Value{ .tuple = t };
}

fn winAddstr(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winAddch(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winMove(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const y = switch (args[1]) { .small_int => |n| n, else => 0 };
    const x = switch (args[2]) { .small_int => |n| n, else => 0 };
    try inst.dict.setStr(a, "cury", Value{ .small_int = y });
    try inst.dict.setStr(a, "curx", Value{ .small_int = x });
    return Value.none;
}

fn winClear(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winRefresh(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winGetch(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .small_int = -1 };
}

fn winGetkey(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try Str.init(interp.allocator, "");
    return Value{ .str = s };
}

fn winKeypad(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winTimeout(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winInch(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .small_int = 0 };
}

fn winBorder(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winBox(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winSubwin(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 5) return Value.none;
    const nlines = switch (args[1]) { .small_int => |n| n, else => 24 };
    const ncols = switch (args[2]) { .small_int => |n| n, else => 80 };
    const begy = switch (args[3]) { .small_int => |n| n, else => 0 };
    const begx = switch (args[4]) { .small_int => |n| n, else => 0 };
    return makeWindow(interp, nlines, ncols, begy, begx);
}

fn winNodelay(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winScrollok(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winIdlok(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winLeaveok(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winErase(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winClrtobot(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winClrtoeol(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winAttron(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winAttroff(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winAttrset(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winNoutrefresh(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winDerwin(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 5) return Value.none;
    const nlines = switch (args[1]) { .small_int => |n| n, else => 24 };
    const ncols = switch (args[2]) { .small_int => |n| n, else => 80 };
    const begy = switch (args[3]) { .small_int => |n| n, else => 0 };
    const begx = switch (args[4]) { .small_int => |n| n, else => 0 };
    return makeWindow(interp, nlines, ncols, begy, begx);
}

fn winMvaddstr(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winMvaddch(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winMvwin(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const y = switch (args[1]) { .small_int => |n| n, else => 0 };
    const x = switch (args[2]) { .small_int => |n| n, else => 0 };
    try inst.dict.setStr(a, "begy", Value{ .small_int = y });
    try inst.dict.setStr(a, "begx", Value{ .small_int = x });
    return Value.none;
}

fn winGetstr(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try Str.init(interp.allocator, "");
    return Value{ .str = s };
}

fn winInstr(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const s = try Str.init(interp.allocator, "");
    return Value{ .str = s };
}

fn winHline(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn winVline(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn getOrCreateWindowClass(interp: *Interp) !*Class {
    if (interp.curses_window_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try reg(a, d, "getmaxyx", winGetmaxyxI);
    try reg(a, d, "getbegyx", winGetbegyx);
    try reg(a, d, "getyx", winGetyx);
    try reg(a, d, "addstr", winAddstr);
    try reg(a, d, "addch", winAddch);
    try reg(a, d, "move", winMove);
    try reg(a, d, "clear", winClear);
    try reg(a, d, "refresh", winRefresh);
    try reg(a, d, "getch", winGetch);
    try reg(a, d, "getkey", winGetkey);
    try reg(a, d, "keypad", winKeypad);
    try reg(a, d, "timeout", winTimeout);
    try reg(a, d, "inch", winInch);
    try reg(a, d, "border", winBorder);
    try reg(a, d, "box", winBox);
    try reg(a, d, "subwin", winSubwin);
    try reg(a, d, "nodelay", winNodelay);
    try reg(a, d, "scrollok", winScrollok);
    try reg(a, d, "idlok", winIdlok);
    try reg(a, d, "leaveok", winLeaveok);
    try reg(a, d, "erase", winErase);
    try reg(a, d, "clrtobot", winClrtobot);
    try reg(a, d, "clrtoeol", winClrtoeol);
    try reg(a, d, "attron", winAttron);
    try reg(a, d, "attroff", winAttroff);
    try reg(a, d, "attrset", winAttrset);
    try reg(a, d, "noutrefresh", winNoutrefresh);
    try reg(a, d, "derwin", winDerwin);
    try reg(a, d, "mvaddstr", winMvaddstr);
    try reg(a, d, "mvaddch", winMvaddch);
    try reg(a, d, "mvwin", winMvwin);
    try reg(a, d, "getstr", winGetstr);
    try reg(a, d, "instr", winInstr);
    try reg(a, d, "hline", winHline);
    try reg(a, d, "vline", winVline);
    const cls = try Class.init(a, "window", &.{}, d);
    interp.curses_window_class = cls;
    return cls;
}

// ===== Module functions =====

fn initscr(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return makeWindow(interp, 24, 80, 0, 0);
}

fn endwin(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn newwinFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const nlines = if (args.len >= 1) switch (args[0]) { .small_int => |n| n, else => 24 } else 24;
    const ncols = if (args.len >= 2) switch (args[1]) { .small_int => |n| n, else => 80 } else 80;
    const begy = if (args.len >= 3) switch (args[2]) { .small_int => |n| n, else => 0 } else 0;
    const begx = if (args.len >= 4) switch (args[3]) { .small_int => |n| n, else => 0 } else 0;
    return makeWindow(interp, nlines, ncols, begy, begx);
}

fn newwinKwFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    var nlines: i64 = 24;
    var ncols: i64 = 80;
    var begy: i64 = 0;
    var begx: i64 = 0;
    if (args.len >= 1) nlines = switch (args[0]) { .small_int => |n| n, else => 24 };
    if (args.len >= 2) ncols = switch (args[1]) { .small_int => |n| n, else => 80 };
    if (args.len >= 3) begy = switch (args[2]) { .small_int => |n| n, else => 0 };
    if (args.len >= 4) begx = switch (args[3]) { .small_int => |n| n, else => 0 };
    for (kw_names, 0..) |kn, i| {
        if (i >= kw_values.len) break;
        const kname = switch (kn) { .str => |s| s.bytes, else => continue };
        const kval = kw_values[i];
        if (std.mem.eql(u8, kname, "nlines")) nlines = switch (kval) { .small_int => |n| n, else => nlines };
        if (std.mem.eql(u8, kname, "ncols")) ncols = switch (kval) { .small_int => |n| n, else => ncols };
        if (std.mem.eql(u8, kname, "begin_y")) begy = switch (kval) { .small_int => |n| n, else => begy };
        if (std.mem.eql(u8, kname, "begin_x")) begx = switch (kval) { .small_int => |n| n, else => begx };
    }
    return makeWindow(interp, nlines, ncols, begy, begx);
}

fn wrapperFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1) return Value.none;
    const func = args[0];
    const stdscr = try makeWindow(interp, 24, 80, 0, 0);
    return dispatch.invoke(interp, func, &.{stdscr});
}

fn startColor(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn hasColors(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .boolean = false };
}

fn colorPair(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return Value{ .small_int = 0 };
    return switch (args[0]) { .small_int => args[0], else => Value{ .small_int = 0 } };
}

fn initPair(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn isendwin(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .boolean = true };
}

fn cbreak(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn noecho(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn echo(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn cursSet(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn flash(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn beep(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn doupdate(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn napms(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn mousemask(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .small_int = 0 };
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "curses");
    m.is_package = true;

    // Ensure the window class is set up.
    _ = try getOrCreateWindowClass(interp);

    // Constants
    const int_consts = &[_]struct { []const u8, i64 }{
        .{ "A_NORMAL", 0 },
        .{ "A_BOLD", 1 },
        .{ "A_UNDERLINE", 2 },
        .{ "A_REVERSE", 4 },
        .{ "A_DIM", 8 },
        .{ "A_BLINK", 16 },
        .{ "A_STANDOUT", 32 },
        .{ "COLOR_BLACK", 0 },
        .{ "COLOR_RED", 1 },
        .{ "COLOR_GREEN", 2 },
        .{ "COLOR_YELLOW", 3 },
        .{ "COLOR_BLUE", 4 },
        .{ "COLOR_MAGENTA", 5 },
        .{ "COLOR_CYAN", 6 },
        .{ "COLOR_WHITE", 7 },
        .{ "KEY_UP", 259 },
        .{ "KEY_DOWN", 258 },
        .{ "KEY_LEFT", 260 },
        .{ "KEY_RIGHT", 261 },
        .{ "KEY_ENTER", 343 },
        .{ "KEY_BACKSPACE", 263 },
        .{ "ERR", -1 },
        .{ "OK", 0 },
        .{ "COLS", 80 },
        .{ "LINES", 24 },
        .{ "ACS_HLINE", 45 },
        .{ "ACS_VLINE", 124 },
        .{ "ACS_ULCORNER", 43 },
        .{ "ACS_LRCORNER", 43 },
        .{ "ACS_URCORNER", 43 },
        .{ "ACS_LLCORNER", 43 },
        .{ "ACS_PLUS", 43 },
    };
    for (int_consts) |pr| try m.attrs.setStr(a, pr[0], Value{ .small_int = pr[1] });

    // Exception class: curses.error (inherits from Exception)
    const err_dict = try Dict.init(a);
    const exc_base: []const *Class = if (interp.builtins.getStr("Exception")) |ev|
        if (ev == .class) &[_]*Class{ev.class} else &.{}
    else &.{};
    const err_cls = try Class.init(a, "error", exc_base, err_dict);
    try m.attrs.setStr(a, "error", Value{ .class = err_cls });

    // Window class
    const win_cls = interp.curses_window_class.?;
    try m.attrs.setStr(a, "window", Value{ .class = win_cls });

    // Module functions
    try regM(a, m, "initscr", initscr);
    try regM(a, m, "endwin", endwin);
    try regMKw(a, m, "newwin", newwinFn, newwinKwFn);
    try regM(a, m, "wrapper", wrapperFn);
    try regM(a, m, "start_color", startColor);
    try regM(a, m, "has_colors", hasColors);
    try regM(a, m, "color_pair", colorPair);
    try regM(a, m, "init_pair", initPair);
    try regM(a, m, "isendwin", isendwin);
    try regM(a, m, "cbreak", cbreak);
    try regM(a, m, "noecho", noecho);
    try regM(a, m, "echo", echo);
    try regM(a, m, "curs_set", cursSet);
    try regM(a, m, "flash", flash);
    try regM(a, m, "beep", beep);
    try regM(a, m, "doupdate", doupdate);
    try regM(a, m, "napms", napms);
    try regM(a, m, "mousemask", mousemask);

    // Sub-modules
    if (interp.getBuiltinModule("curses.ascii")) |am| try m.attrs.setStr(a, "ascii", Value{ .module = am });
    if (interp.getBuiltinModule("curses.panel")) |pm| try m.attrs.setStr(a, "panel", Value{ .module = pm });
    if (interp.getBuiltinModule("curses.textpad")) |tm| try m.attrs.setStr(a, "textpad", Value{ .module = tm });

    return m;
}
