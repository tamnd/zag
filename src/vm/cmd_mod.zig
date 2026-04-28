//! Pinhole `cmd` module: cmd.Cmd base class.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const dunder = @import("dunder.zig");
const dispatch = @import("dispatch.zig");

var cmd_class: ?*Class = null;

fn reg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

// ===== stdout helpers =====

fn getStdout(inst: *Instance) Value {
    return inst.dict.getStr("stdout") orelse Value.none;
}

fn writeStdout(interp: *Interp, stdout: Value, s: []const u8) !void {
    if (stdout == .none) return;
    const sv = Value{ .str = try Str.init(interp.allocator, s) };
    _ = try dunder.call(interp, stdout, "write", &.{sv});
}

// ===== parseline =====
// Returns tuple (cmd_or_None, args_str, line).

fn identcharsContains(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn parselineImpl(interp: *Interp, self: Value, line_str: []const u8) !Value {
    const a = interp.allocator;
    const line = std.mem.trim(u8, line_str, " \t\r\n");

    const t = try Tuple.init(a, 3);

    if (line.len == 0) {
        t.items[0] = Value.none;
        t.items[1] = Value.none;
        t.items[2] = Value{ .str = try Str.init(a, line) };
        return Value{ .tuple = t };
    }

    var effective = line;

    if (line[0] == '?') {
        // '?' prefix maps to help
        const rest = std.mem.trim(u8, line[1..], " ");
        t.items[0] = Value{ .str = try Str.init(a, "help") };
        t.items[1] = Value{ .str = try Str.init(a, rest) };
        t.items[2] = Value{ .str = try Str.init(a, line) };
        return Value{ .tuple = t };
    }

    if (line[0] == '!') {
        // '!' prefix: check if do_shell exists
        const rest = line[1..];
        if (self == .instance) {
            if (self.instance.cls.lookup("do_shell") != null) {
                t.items[0] = Value{ .str = try Str.init(a, "shell") };
                t.items[1] = Value{ .str = try Str.init(a, rest) };
                t.items[2] = Value{ .str = try Str.init(a, line) };
                return Value{ .tuple = t };
            }
        }
        t.items[0] = Value.none;
        t.items[1] = Value.none;
        t.items[2] = Value{ .str = try Str.init(a, line) };
        return Value{ .tuple = t };
    }

    // Normal: scan identchars to find command word
    var i: usize = 0;
    while (i < effective.len and identcharsContains(effective[i])) : (i += 1) {}
    const cmd_word = effective[0..i];
    const args_part = std.mem.trim(u8, effective[i..], " \t");

    t.items[0] = Value{ .str = try Str.init(a, cmd_word) };
    t.items[1] = Value{ .str = try Str.init(a, args_part) };
    t.items[2] = Value{ .str = try Str.init(a, effective) };
    return Value{ .tuple = t };
}

fn cmdParselineFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return Value.none;
    const self = args[0];
    const line_str = if (args[1] == .str) args[1].str.bytes else "";
    return parselineImpl(interp, self, line_str);
}

// ===== default =====

fn cmdDefault(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const stdout = getStdout(inst);
    const line = if (args.len >= 2 and args[1] == .str) args[1].str.bytes else "";
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "*** Unknown syntax: {s}\n", .{line});
    try writeStdout(interp, stdout, msg);
    return Value.none;
}

// ===== onecmd =====

fn callMethodOnInstance(interp: *Interp, self: Value, method_name: []const u8, extra: []const Value) !Value {
    const method_val = dunder.lookup(self, method_name) orelse return Value.none;
    const a = interp.allocator;
    const total = extra.len + 1;
    var stack_buf: [8]Value = undefined;
    const call_args = if (total <= stack_buf.len) stack_buf[0..total] else try a.alloc(Value, total);
    defer if (total > stack_buf.len) a.free(call_args);
    call_args[0] = self;
    @memcpy(call_args[1..], extra);
    return dispatch.invoke(interp, method_val, call_args);
}

fn cmdOnecmdFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2) return Value{ .boolean = false };
    const self = args[0];
    if (self != .instance) return Value{ .boolean = false };
    const inst = self.instance;
    const line_str = if (args[1] == .str) args[1].str.bytes else "";

    const parsed = try parselineImpl(interp, self, line_str);
    if (parsed != .tuple or parsed.tuple.items.len < 3) return Value{ .boolean = false };

    const cmd_val = parsed.tuple.items[0];
    const arg_val = parsed.tuple.items[1];

    // Empty or None command
    if (cmd_val == .none or (cmd_val == .str and cmd_val.str.bytes.len == 0)) {
        _ = try callMethodOnInstance(interp, self, "default", &.{Value{ .str = try Str.init(interp.allocator, line_str) }});
        return Value{ .boolean = false };
    }

    if (cmd_val != .str) return Value{ .boolean = false };
    const cmd_word = cmd_val.str.bytes;

    // Build "do_<cmd>" name
    var method_buf: [128]u8 = undefined;
    const method_name = try std.fmt.bufPrint(&method_buf, "do_{s}", .{cmd_word});

    // Store lastcmd
    try inst.dict.setStr(interp.allocator, "lastcmd", Value{ .str = try Str.init(interp.allocator, line_str) });

    if (inst.cls.lookup(method_name)) |method_val| {
        const call_args = [_]Value{ self, arg_val };
        const result = try dispatch.invoke(interp, method_val, &call_args);
        if (result == .boolean) return result;
        if (result == .none) return Value{ .boolean = false };
        return result;
    }

    // Not found: call default
    const line_v = Value{ .str = try Str.init(interp.allocator, line_str) };
    _ = try callMethodOnInstance(interp, self, "default", &.{line_v});
    return Value{ .boolean = false };
}

// ===== preloop / postloop / precmd / postcmd =====

fn cmdPreloopFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn cmdPostloopFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

fn cmdPrecmdFn(_: *anyopaque, args: []const Value) anyerror!Value {
    // Returns line unchanged
    if (args.len >= 2) return args[1];
    return Value.none;
}

fn cmdPostcmdFn(_: *anyopaque, args: []const Value) anyerror!Value {
    // Returns stop unchanged
    if (args.len >= 2) return args[1];
    return Value{ .boolean = false };
}

// ===== cmdloop =====

fn cmdCmdloopFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return cmdCmdloopImpl(p, args, &.{}, &.{});
}

fn cmdCmdloopKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return cmdCmdloopImpl(p, args, kn, kv);
}

fn cmdCmdloopImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const self = args[0];
    const inst = self.instance;
    const stdout = getStdout(inst);

    // Resolve intro: positional arg[1] or keyword "intro"
    var intro: Value = Value.none;
    if (args.len >= 2) intro = args[1];
    for (kn, kv) |nm, vl| {
        if (nm == .str and std.mem.eql(u8, nm.str.bytes, "intro")) {
            intro = vl;
        }
    }

    // Write intro if not None and not empty string
    if (intro != .none) {
        if (intro == .str) {
            const intro_s = intro.str.bytes;
            if (intro_s.len > 0) {
                const msg = try std.fmt.allocPrint(a, "{s}\n", .{intro_s});
                defer a.free(msg);
                try writeStdout(interp, stdout, msg);
            }
        }
    }

    // preloop
    _ = try callMethodOnInstance(interp, self, "preloop", &.{});

    // Main loop: consume cmdqueue (non-interactive)
    while (true) {
        const q_val = inst.dict.getStr("cmdqueue") orelse break;
        if (q_val != .list) break;
        const qlist = q_val.list;
        if (qlist.items.items.len == 0) break;

        const line_val = qlist.items.orderedRemove(0);
        const line_str = if (line_val == .str) line_val.str.bytes else "";

        // precmd(line) -> modified_line
        var modified_line = Value{ .str = try Str.init(a, line_str) };
        if (dunder.lookup(self, "precmd")) |m| {
            const precmd_args = [_]Value{ self, modified_line };
            modified_line = try dispatch.invoke(interp, m, &precmd_args);
        }
        const ml_str = if (modified_line == .str) modified_line.str.bytes else line_str;

        // onecmd(modified_line) -> stop
        const onecmd_val = dunder.lookup(self, "onecmd") orelse continue;
        const oc_args = [_]Value{ self, Value{ .str = try Str.init(a, ml_str) } };
        var stop = try dispatch.invoke(interp, onecmd_val, &oc_args);

        // postcmd(stop, modified_line) -> stop
        if (dunder.lookup(self, "postcmd")) |m| {
            const postcmd_args = [_]Value{ self, stop, modified_line };
            stop = try dispatch.invoke(interp, m, &postcmd_args);
        }

        if (stop == .boolean and stop.boolean) break;
        if (stop != .none and stop != .boolean) break;
    }

    // postloop
    _ = try callMethodOnInstance(interp, self, "postloop", &.{});

    return Value.none;
}

// ===== do_help =====

fn getDocstring(v: Value) ?[]const u8 {
    if (v == .function) {
        const code = v.function.code;
        if (code.consts.len > 0 and code.consts[0] == .str) return code.consts[0].str.bytes;
        return null;
    }
    return null;
}

fn cmdDoHelpFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const self = args[0];
    const inst = self.instance;
    const stdout = getStdout(inst);

    const arg_str = if (args.len >= 2 and args[1] == .str) args[1].str.bytes else "";

    if (arg_str.len > 0) {
        // Help on specific command
        var method_buf: [128]u8 = undefined;
        const method_name = try std.fmt.bufPrint(&method_buf, "do_{s}", .{arg_str});
        if (inst.cls.lookup(method_name)) |method_val| {
            if (getDocstring(method_val)) |doc| {
                const msg = try std.fmt.allocPrint(a, "{s}\n", .{doc});
                defer a.free(msg);
                try writeStdout(interp, stdout, msg);
            } else {
                const msg = try std.fmt.allocPrint(a, "No help on {s}\n", .{arg_str});
                defer a.free(msg);
                try writeStdout(interp, stdout, msg);
            }
        } else {
            const msg = try std.fmt.allocPrint(a, "No help on {s}\n", .{arg_str});
            defer a.free(msg);
            try writeStdout(interp, stdout, msg);
        }
        return Value.none;
    }

    // List all do_* methods
    var documented: std.ArrayList([]const u8) = .empty;
    defer documented.deinit(a);
    var undocumented: std.ArrayList([]const u8) = .empty;
    defer undocumented.deinit(a);

    // Walk MRO and collect do_* names (deduplicated)
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(a);

    for (inst.cls.mro) |cls| {
        for (cls.dict.pairs.items) |pair| {
            if (pair.key != .str) continue;
            const name = pair.key.str.bytes;
            if (!std.mem.startsWith(u8, name, "do_")) continue;
            if (std.mem.eql(u8, name, "do_help")) continue;
            // Check if already seen
            var already = false;
            for (seen.items) |s| if (std.mem.eql(u8, s, name)) { already = true; break; };
            if (already) continue;
            try seen.append(a, name);

            const cmd_name = name[3..]; // strip "do_"
            const has_doc = getDocstring(pair.value) != null;
            if (has_doc) {
                try documented.append(a, cmd_name);
            } else {
                try undocumented.append(a, cmd_name);
            }
        }
    }

    // Sort for deterministic output
    std.sort.insertion([]const u8, documented.items, {}, strLt);
    std.sort.insertion([]const u8, undocumented.items, {}, strLt);

    const doc_header_v = inst.cls.lookup("doc_header") orelse inst.dict.getStr("doc_header") orelse Value.none;
    const doc_header = if (doc_header_v == .str) doc_header_v.str.bytes else "Documented commands (type help <topic>):";

    if (documented.items.len > 0) {
        const hdr = try std.fmt.allocPrint(a, "\n{s}\n", .{doc_header});
        defer a.free(hdr);
        try writeStdout(interp, stdout, hdr);

        // ruler line
        const ruler_v = inst.cls.lookup("ruler") orelse inst.dict.getStr("ruler") orelse Value.none;
        const ruler_ch: u8 = if (ruler_v == .str and ruler_v.str.bytes.len > 0) ruler_v.str.bytes[0] else '=';
        var ruler_buf: [80]u8 = undefined;
        const ruler_len = @min(doc_header.len, 79);
        @memset(ruler_buf[0..ruler_len], ruler_ch);
        ruler_buf[ruler_len] = '\n';
        try writeStdout(interp, stdout, ruler_buf[0 .. ruler_len + 1]);

        for (documented.items) |cmd_name| {
            const line_msg = try std.fmt.allocPrint(a, "{s}  ", .{cmd_name});
            defer a.free(line_msg);
            try writeStdout(interp, stdout, line_msg);
        }
        try writeStdout(interp, stdout, "\n");
    }

    const undoc_header_v = inst.cls.lookup("undoc_header") orelse inst.dict.getStr("undoc_header") orelse Value.none;
    const undoc_header = if (undoc_header_v == .str) undoc_header_v.str.bytes else "Undocumented commands:";

    if (undocumented.items.len > 0) {
        const hdr = try std.fmt.allocPrint(a, "\n{s}\n", .{undoc_header});
        defer a.free(hdr);
        try writeStdout(interp, stdout, hdr);

        for (undocumented.items) |cmd_name| {
            const line_msg = try std.fmt.allocPrint(a, "{s}  ", .{cmd_name});
            defer a.free(line_msg);
            try writeStdout(interp, stdout, line_msg);
        }
        try writeStdout(interp, stdout, "\n");
    }

    return Value.none;
}

fn strLt(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ===== columnize =====

fn cmdColumnizeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const stdout = getStdout(inst);

    if (args.len < 2 or args[1] != .list) return Value.none;
    const items = args[1].list.items.items;

    for (items) |item| {
        if (item == .str) {
            const msg = try std.fmt.allocPrint(a, "{s}  ", .{item.str.bytes});
            defer a.free(msg);
            try writeStdout(interp, stdout, msg);
        }
    }
    if (items.len > 0) try writeStdout(interp, stdout, "\n");
    return Value.none;
}

// ===== __init__ =====

fn cmdInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return cmdInitImpl(p, args, &.{}, &.{});
}

fn cmdInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return cmdInitImpl(p, args, kn, kv);
}

fn cmdInitImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;

    // Default stdout is none (non-interactive)
    var stdout_val: Value = Value.none;
    for (kn, kv) |nm, vl| {
        if (nm == .str and std.mem.eql(u8, nm.str.bytes, "stdout")) stdout_val = vl;
    }
    try inst.dict.setStr(a, "stdout", stdout_val);

    // Initialize mutable instance attrs
    const q = try List.init(a);
    try inst.dict.setStr(a, "cmdqueue", Value{ .list = q });
    try inst.dict.setStr(a, "lastcmd", Value{ .str = try Str.init(a, "") });

    return Value.none;
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "cmd");

    cmd_class = null; // reset per interpreter

    const d = try Dict.init(a);

    // Class-level default attributes
    try d.setStr(a, "prompt", Value{ .str = try Str.init(a, "(Cmd) ") });
    try d.setStr(a, "ruler", Value{ .str = try Str.init(a, "=") });
    try d.setStr(a, "use_rawinput", Value{ .boolean = true });
    try d.setStr(a, "doc_header", Value{ .str = try Str.init(a, "Documented commands (type help <topic>):") });
    try d.setStr(a, "undoc_header", Value{ .str = try Str.init(a, "Undocumented commands:") });
    try d.setStr(a, "misc_header", Value{ .str = try Str.init(a, "Miscellaneous help topics:") });
    // identchars: letters + digits + '_'
    const identchars_str = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";
    try d.setStr(a, "identchars", Value{ .str = try Str.init(a, identchars_str) });

    // Methods
    try regKw(a, d, "__init__", cmdInitFn, cmdInitKw);
    try reg(a, d, "parseline", cmdParselineFn);
    try reg(a, d, "onecmd", cmdOnecmdFn);
    try regKw(a, d, "cmdloop", cmdCmdloopFn, cmdCmdloopKw);
    try reg(a, d, "default", cmdDefault);
    try reg(a, d, "do_help", cmdDoHelpFn);
    try reg(a, d, "preloop", cmdPreloopFn);
    try reg(a, d, "postloop", cmdPostloopFn);
    try reg(a, d, "precmd", cmdPrecmdFn);
    try reg(a, d, "postcmd", cmdPostcmdFn);
    try reg(a, d, "columnize", cmdColumnizeFn);

    const cls = try Class.init(a, "Cmd", &.{}, d);
    cmd_class = cls;

    try m.attrs.setStr(a, "Cmd", Value{ .class = cls });

    return m;
}
