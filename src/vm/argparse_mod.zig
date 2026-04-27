//! Pinhole `argparse` module.
//! Implements ArgumentParser, Namespace, add_argument, parse_args.

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

fn reg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKwD(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn regM(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKwM(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

// ===== Namespace class =====
// Simple attribute container

fn getOrCreateNamespaceClass(interp: *Interp) !*Class {
    if (interp.argparse_namespace_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const cls = try Class.init(a, "Namespace", &.{}, d);
    interp.argparse_namespace_class = cls;
    return cls;
}

fn namespaceBuiltin(p: *anyopaque, args: []const Value) anyerror!Value {
    return namespaceImpl(p, args, &.{}, &.{});
}

fn namespaceKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return namespaceImpl(p, args, kn, kv);
}

fn namespaceImpl(p: *anyopaque, _args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    _ = _args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const cls = try getOrCreateNamespaceClass(interp);
    const inst = try Instance.init(a, cls);
    for (kn, kv) |nm, vl| {
        if (nm == .str) try inst.dict.setStr(a, nm.str.bytes, vl);
    }
    return Value{ .instance = inst };
}

// ===== ArgumentParser class =====

fn getOrCreateParserClass(interp: *Interp) !*Class {
    if (interp.argparse_parser_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try reg(a, d, "add_argument", addArgumentFn);
    try regKwD(a, d, "add_argument", addArgumentFn, addArgumentKw);
    try reg(a, d, "parse_args", parseArgsFn);
    try reg(a, d, "set_defaults", setDefaultsFn);
    try reg(a, d, "print_help", printHelpFn);
    try reg(a, d, "error", parserErrorFn);
    // add_argument registered as kw-aware
    const f2 = try a.create(BuiltinFn);
    f2.* = .{ .name = "add_argument", .func = addArgumentFn, .kw_func = addArgumentKw };
    try d.setStr(a, "add_argument", Value{ .builtin_fn = f2 });
    const cls = try Class.init(a, "ArgumentParser", &.{}, d);
    interp.argparse_parser_class = cls;
    return cls;
}

fn argumentParserBuiltin(p: *anyopaque, args: []const Value) anyerror!Value {
    return argumentParserImpl(p, args, &.{}, &.{});
}

fn argumentParserKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return argumentParserImpl(p, args, kn, kv);
}

fn argumentParserImpl(p: *anyopaque, _args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    _ = _args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const cls = try getOrCreateParserClass(interp);
    const inst = try Instance.init(a, cls);
    // _args_list: List of argument specs (each is a Dict)
    const args_list = try List.init(a);
    try inst.dict.setStr(a, "_args_list", Value{ .list = args_list });
    // Store description etc.
    for (kn, kv) |nm, vl| {
        if (nm == .str) try inst.dict.setStr(a, nm.str.bytes, vl);
    }
    return Value{ .instance = inst };
}

// add_argument: self, name, [type=..., default=..., action=..., dest=..., nargs=...]
fn addArgumentFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return addArgumentImpl(p, args, &.{}, &.{});
}

fn addArgumentKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return addArgumentImpl(p, args, kn, kv);
}

fn addArgumentImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value.none;
    const self = args[0].instance;
    const name_v = args[1];
    if (name_v != .str) return Value.none;
    const name = name_v.str.bytes;

    const spec = try Dict.init(a);
    try spec.setStr(a, "name", name_v);

    // Determine if optional (--xxx) or positional
    const is_opt = std.mem.startsWith(u8, name, "-");
    try spec.setStr(a, "is_optional", Value{ .boolean = is_opt });

    // Also handle second positional name arg (e.g. add_argument('-f', '--foo'))
    var dest: []const u8 = if (is_opt) blk: {
        // strip leading dashes and replace - with _
        var s = name;
        while (s.len > 0 and s[0] == '-') s = s[1..];
        break :blk s;
    } else name;

    if (args.len >= 3 and args[2] == .str) {
        // second name, e.g. '-f', '--foo'
        var s2 = args[2].str.bytes;
        if (std.mem.startsWith(u8, s2, "--")) {
            s2 = s2[2..];
            dest = s2;
        }
        try spec.setStr(a, "name2", args[2]);
    }

    // dest with dashes replaced by underscores
    const dest_buf = try a.dupe(u8, dest);
    for (dest_buf) |*c| if (c.* == '-') { c.* = '_'; };
    try spec.setStr(a, "dest", Value{ .str = try Str.init(a, dest_buf) });
    a.free(dest_buf);

    // Default kwargs
    var action: Value = Value{ .str = try Str.init(a, "store") };
    var default_v: Value = Value.none;
    var type_v: Value = Value.none; // type callable
    var nargs_v: Value = Value.none;

    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        if (std.mem.eql(u8, nm.str.bytes, "action")) action = vl;
        if (std.mem.eql(u8, nm.str.bytes, "default")) default_v = vl;
        if (std.mem.eql(u8, nm.str.bytes, "type")) type_v = vl;
        if (std.mem.eql(u8, nm.str.bytes, "nargs")) nargs_v = vl;
        if (std.mem.eql(u8, nm.str.bytes, "dest")) {
            try spec.setStr(a, "dest", vl);
        }
        if (std.mem.eql(u8, nm.str.bytes, "choices")) {}
        if (std.mem.eql(u8, nm.str.bytes, "help")) {}
    }

    // store_true: default is False
    if (action == .str and std.mem.eql(u8, action.str.bytes, "store_true")) {
        if (default_v == .none) default_v = Value{ .boolean = false };
    }
    if (action == .str and std.mem.eql(u8, action.str.bytes, "store_false")) {
        if (default_v == .none) default_v = Value{ .boolean = true };
    }

    try spec.setStr(a, "action", action);
    try spec.setStr(a, "default", default_v);
    try spec.setStr(a, "type", type_v);
    try spec.setStr(a, "nargs", nargs_v);

    const args_list_v = self.dict.getStr("_args_list") orelse return Value.none;
    if (args_list_v == .list) try args_list_v.list.append(a, Value{ .dict = spec });
    return Value.none;
}

// parse_args: self, args_list (or None for sys.argv)
fn parseArgsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const self = args[0].instance;

    // Get the list of string args to parse
    var argv: []Value = &.{};
    const argv_owned: ?[]Value = null;
    if (args.len >= 2 and args[1] == .list) {
        argv = args[1].list.items.items;
    }
    defer if (argv_owned) |o| a.free(o);

    // Get argument specs
    const specs_v = self.dict.getStr("_args_list") orelse return Value.none;
    if (specs_v != .list) return Value.none;
    const specs = specs_v.list.items.items;

    // Create namespace
    const ns_cls = try getOrCreateNamespaceClass(interp);
    const ns = try Instance.init(a, ns_cls);

    // Set defaults first
    for (specs) |sv| {
        if (sv != .dict) continue;
        const spec = sv.dict;
        const dest_v = spec.getStr("dest") orelse continue;
        if (dest_v != .str) continue;
        const default_v = spec.getStr("default") orelse Value.none;
        try ns.dict.setStr(a, dest_v.str.bytes, default_v);
    }

    // Parse argv
    var i: usize = 0;
    var positional_idx: usize = 0;
    while (i < argv.len) {
        const arg = argv[i];
        if (arg != .str) { i += 1; continue; }
        const s = arg.str.bytes;
        if (std.mem.startsWith(u8, s, "-")) {
            // Optional argument
            // Find matching spec by --name or -n
            var found = false;
            for (specs) |sv| {
                if (sv != .dict) continue;
                const spec = sv.dict;
                const name_v = spec.getStr("name") orelse continue;
                if (name_v != .str) continue;
                const spec_name = name_v.str.bytes;
                const name2_v = spec.getStr("name2");
                const matches = std.mem.eql(u8, s, spec_name) or
                    (name2_v != null and name2_v.? == .str and std.mem.eql(u8, s, name2_v.?.str.bytes));
                if (!matches) continue;

                const dest_v = spec.getStr("dest") orelse continue;
                if (dest_v != .str) continue;
                const dest = dest_v.str.bytes;
                const action_v = spec.getStr("action") orelse Value.none;
                const action = if (action_v == .str) action_v.str.bytes else "store";

                if (std.mem.eql(u8, action, "store_true")) {
                    try ns.dict.setStr(a, dest, Value{ .boolean = true });
                    found = true;
                    i += 1;
                    break;
                } else if (std.mem.eql(u8, action, "store_false")) {
                    try ns.dict.setStr(a, dest, Value{ .boolean = false });
                    found = true;
                    i += 1;
                    break;
                } else {
                    // store: consume next token as value
                    if (i + 1 >= argv.len) { i += 1; found = true; break; }
                    i += 1;
                    var val = argv[i];
                    i += 1;
                    // Apply type conversion
                    const type_v = spec.getStr("type") orelse Value.none;
                    if (type_v != .none and val == .str) {
                        // Try to call type(val)
                        val = convertType(val, type_v) orelse val;
                    }
                    try ns.dict.setStr(a, dest, val);
                    found = true;
                    break;
                }
            }
            if (!found) i += 1; // Unknown flag, skip
        } else {
            // Positional argument: find nth positional spec
            var pos_count: usize = 0;
            for (specs) |sv| {
                if (sv != .dict) continue;
                const spec = sv.dict;
                const is_opt_v = spec.getStr("is_optional") orelse Value{ .boolean = false };
                const is_opt = is_opt_v == .boolean and is_opt_v.boolean;
                if (is_opt) continue;
                if (pos_count == positional_idx) {
                    const dest_v = spec.getStr("dest") orelse { pos_count += 1; break; };
                    if (dest_v == .str) {
                        var val = arg;
                        const type_v = spec.getStr("type") orelse Value.none;
                        if (type_v != .none and val == .str) {
                            val = convertType(val, type_v) orelse val;
                        }
                        try ns.dict.setStr(a, dest_v.str.bytes, val);
                    }
                    break;
                }
                pos_count += 1;
            }
            positional_idx += 1;
            i += 1;
        }
    }

    return Value{ .instance = ns };
}

fn convertType(val: Value, type_v: Value) ?Value {
    if (val != .str) return null;
    if (type_v == .class) {
        const name = type_v.class.name;
        if (std.mem.eql(u8, name, "int")) {
            const n = std.fmt.parseInt(i64, val.str.bytes, 10) catch return null;
            return Value{ .small_int = n };
        }
        if (std.mem.eql(u8, name, "float")) {
            const f = std.fmt.parseFloat(f64, val.str.bytes) catch return null;
            return Value{ .float = f };
        }
        if (std.mem.eql(u8, name, "str")) return val;
    }
    return null;
}

fn setDefaultsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value.none;
}

fn printHelpFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value.none;
}

fn parserErrorFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const msg = if (args.len >= 2 and args[1] == .str) args[1].str.bytes else "error";
    try interp.raisePy("SystemExit", msg);
    return error.PyException;
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "argparse");

    try regKwM(a, m, "ArgumentParser", argumentParserBuiltin, argumentParserKw);
    try regKwM(a, m, "Namespace", namespaceBuiltin, namespaceKw);

    // Common action constants
    try m.attrs.setStr(a, "SUPPRESS", Value{ .str = try Str.init(a, "==SUPPRESS==") });
    try m.attrs.setStr(a, "REMAINDER", Value{ .str = try Str.init(a, "A...") });

    return m;
}
