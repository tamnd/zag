//! Pinhole `argparse` module.
//! Implements ArgumentParser, Namespace, add_argument, parse_args, and many extras.

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

fn getOrCreateNamespaceClass(interp: *Interp) !*Class {
    if (interp.argparse_namespace_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    // __contains__ for 'x in ns'
    try reg(a, d, "__contains__", namespaceContains);
    const cls = try Class.init(a, "Namespace", &.{}, d);
    interp.argparse_namespace_class = cls;
    return cls;
}

fn namespaceContains(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .instance) return Value{ .boolean = false };
    const self = args[0].instance;
    const key = args[1];
    if (key != .str) return Value{ .boolean = false };
    return Value{ .boolean = self.dict.getStr(key.str.bytes) != null };
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
    try regKwD(a, d, "add_argument", addArgumentFn, addArgumentKw);
    try reg(a, d, "parse_args", parseArgsFn);
    try reg(a, d, "parse_known_args", parseKnownArgsFn);
    try regKwD(a, d, "set_defaults", setDefaultsFn, setDefaultsKw);
    try reg(a, d, "get_default", getDefaultFn);
    try reg(a, d, "print_help", printHelpFn);
    try reg(a, d, "error", parserErrorFn);
    try reg(a, d, "format_usage", formatUsageFn);
    try reg(a, d, "format_help", formatHelpFn);
    try reg(a, d, "add_argument_group", addArgumentGroupFn);
    try reg(a, d, "add_mutually_exclusive_group", addMutuallyExclusiveGroupFn);
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
    // _overrides: Dict of set_defaults overrides
    const overrides = try Dict.init(a);
    try inst.dict.setStr(a, "_overrides", Value{ .dict = overrides });
    // Store keyword args (prog, description, etc.)
    for (kn, kv) |nm, vl| {
        if (nm == .str) try inst.dict.setStr(a, nm.str.bytes, vl);
    }
    return Value{ .instance = inst };
}

// ===== add_argument =====

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

    // Determine if optional (--xxx or -x) or positional
    const is_opt = std.mem.startsWith(u8, name, "-");
    try spec.setStr(a, "is_optional", Value{ .boolean = is_opt });

    // Compute dest from name: strip leading dashes, replace - with _
    var dest: []const u8 = if (is_opt) blk: {
        var s = name;
        while (s.len > 0 and s[0] == '-') s = s[1..];
        break :blk s;
    } else name;

    // Second positional name (e.g. '-f', '--foo')
    if (args.len >= 3 and args[2] == .str) {
        var s2 = args[2].str.bytes;
        if (std.mem.startsWith(u8, s2, "--")) {
            s2 = s2[2..];
            dest = s2;
        }
        try spec.setStr(a, "name2", args[2]);
    }

    // Replace dashes with underscores in dest
    const dest_buf = try a.dupe(u8, dest);
    for (dest_buf) |*c| if (c.* == '-') { c.* = '_'; };
    try spec.setStr(a, "dest", Value{ .str = try Str.init(a, dest_buf) });
    a.free(dest_buf);

    // Default kwargs
    var action: Value = Value{ .str = try Str.init(a, "store") };
    var default_v: Value = Value.none;
    var type_v: Value = Value.none;
    var nargs_v: Value = Value.none;
    var const_v: Value = Value.none;

    for (kn, kv) |nm, vl| {
        if (nm != .str) continue;
        if (std.mem.eql(u8, nm.str.bytes, "action")) action = vl;
        if (std.mem.eql(u8, nm.str.bytes, "default")) default_v = vl;
        if (std.mem.eql(u8, nm.str.bytes, "type")) type_v = vl;
        if (std.mem.eql(u8, nm.str.bytes, "nargs")) nargs_v = vl;
        if (std.mem.eql(u8, nm.str.bytes, "const")) const_v = vl;
        if (std.mem.eql(u8, nm.str.bytes, "dest")) {
            const dest_kv = vl;
            if (dest_kv == .str) try spec.setStr(a, "dest", dest_kv);
        }
        if (std.mem.eql(u8, nm.str.bytes, "choices")) {}
        if (std.mem.eql(u8, nm.str.bytes, "help")) {}
        if (std.mem.eql(u8, nm.str.bytes, "metavar")) {}
        if (std.mem.eql(u8, nm.str.bytes, "required")) {}
    }

    // Set sensible defaults per action
    if (action == .str) {
        if (std.mem.eql(u8, action.str.bytes, "store_true")) {
            if (default_v == .none) default_v = Value{ .boolean = false };
        } else if (std.mem.eql(u8, action.str.bytes, "store_false")) {
            if (default_v == .none) default_v = Value{ .boolean = true };
        } else if (std.mem.eql(u8, action.str.bytes, "count")) {
            if (default_v == .none) default_v = Value{ .small_int = 0 };
        } else if (std.mem.eql(u8, action.str.bytes, "append")) {
            if (default_v == .none) default_v = Value.none; // None initially, becomes list on first use
        }
    }

    try spec.setStr(a, "action", action);
    try spec.setStr(a, "default", default_v);
    try spec.setStr(a, "type", type_v);
    try spec.setStr(a, "nargs", nargs_v);
    try spec.setStr(a, "const", const_v);

    // Get the _args_list from the parser instance
    var args_list_v = self.dict.getStr("_args_list") orelse return Value.none;
    if (args_list_v != .list) return Value.none;
    try args_list_v.list.append(a, Value{ .dict = spec });
    return Value.none;
}

// ===== parse_args / parse_known_args =====

fn parseArgsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const result = try parseImpl(p, args);
    return result.ns;
}

fn parseKnownArgsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const result = try parseImpl(p, args);
    // Return (namespace, extra_list) as a tuple
    const t = try Tuple.init(a, 2);
    t.items[0] = result.ns;
    t.items[1] = Value{ .list = result.extra };
    return Value{ .tuple = t };
}

const ParseResult = struct {
    ns: Value,
    extra: *List,
};

fn parseImpl(p: *anyopaque, args: []const Value) anyerror!ParseResult {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const self = args[0].instance;

    // Get the list of string args to parse
    var argv: []Value = &.{};
    if (args.len >= 2 and args[1] == .list) {
        argv = args[1].list.items.items;
    }

    // Get argument specs
    const specs_v = self.dict.getStr("_args_list") orelse return error.TypeError;
    if (specs_v != .list) return error.TypeError;
    const specs = specs_v.list.items.items;

    // Get overrides from set_defaults
    const overrides_v = self.dict.getStr("_overrides");

    // Create namespace
    const ns_cls = try getOrCreateNamespaceClass(interp);
    const ns = try Instance.init(a, ns_cls);

    // Set defaults first
    for (specs) |sv| {
        if (sv != .dict) continue;
        const spec = sv.dict;
        const dest_v = spec.getStr("dest") orelse continue;
        if (dest_v != .str) continue;
        var default_v = spec.getStr("default") orelse Value.none;
        // nargs='*' default is [] when not specified
        if (default_v == .none) {
            const nv = spec.getStr("nargs") orelse Value.none;
            if (nv == .str and std.mem.eql(u8, nv.str.bytes, "*")) {
                default_v = Value{ .list = try List.init(a) };
            }
        }
        try ns.dict.setStr(a, dest_v.str.bytes, default_v);
    }

    // Apply set_defaults overrides
    if (overrides_v) |ov| {
        if (ov == .dict) {
            for (ov.dict.pairs.items) |pair| {
                if (pair.key == .str) {
                    try ns.dict.setStr(a, pair.key.str.bytes, pair.value);
                }
            }
        }
    }

    // Extra/unknown args
    const extra = try List.init(a);

    // Parse argv
    var i: usize = 0;
    var positional_idx: usize = 0;

    while (i < argv.len) {
        const arg = argv[i];
        if (arg != .str) { i += 1; continue; }
        var s = arg.str.bytes;

        if (std.mem.startsWith(u8, s, "-")) {
            // Handle --long=value syntax
            var eq_val: ?[]const u8 = null;
            if (std.mem.startsWith(u8, s, "--")) {
                if (std.mem.indexOfScalar(u8, s, '=')) |eq_pos| {
                    eq_val = s[eq_pos + 1..];
                    s = s[0..eq_pos];
                }
            }

            // Find matching spec
            var found = false;
            for (specs) |sv| {
                if (sv != .dict) continue;
                const spec = sv.dict;
                const name_v2 = spec.getStr("name") orelse continue;
                if (name_v2 != .str) continue;
                const spec_name = name_v2.str.bytes;
                const name2_v = spec.getStr("name2");
                const matches = std.mem.eql(u8, s, spec_name) or
                    (name2_v != null and name2_v.? == .str and std.mem.eql(u8, s, name2_v.?.str.bytes));
                if (!matches) continue;

                const dest_v = spec.getStr("dest") orelse continue;
                if (dest_v != .str) continue;
                const dest = dest_v.str.bytes;
                const action_v = spec.getStr("action") orelse Value.none;
                const action = if (action_v == .str) action_v.str.bytes else "store";
                const type_v = spec.getStr("type") orelse Value.none;
                const nargs_v = spec.getStr("nargs") orelse Value.none;
                const const_v = spec.getStr("const") orelse Value.none;

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
                } else if (std.mem.eql(u8, action, "store_const")) {
                    try ns.dict.setStr(a, dest, const_v);
                    found = true;
                    i += 1;
                    break;
                } else if (std.mem.eql(u8, action, "count")) {
                    const cur = ns.dict.getStr(dest) orelse Value{ .small_int = 0 };
                    const cur_int: i64 = if (cur == .small_int) cur.small_int else 0;
                    try ns.dict.setStr(a, dest, Value{ .small_int = cur_int + 1 });
                    found = true;
                    i += 1;
                    break;
                } else if (std.mem.eql(u8, action, "append")) {
                    // Get or create list
                    var lst_v = ns.dict.getStr(dest) orelse Value.none;
                    if (lst_v == .none) {
                        const nl = try List.init(a);
                        lst_v = Value{ .list = nl };
                        try ns.dict.setStr(a, dest, lst_v);
                    }
                    i += 1;
                    if (i < argv.len and argv[i] == .str) {
                        var val = argv[i];
                        i += 1;
                        if (type_v != .none) val = convertType(val, type_v) orelse val;
                        if (lst_v == .list) try lst_v.list.append(a, val);
                    }
                    found = true;
                    break;
                } else {
                    // "store" action with possible nargs
                    if (nargs_v == .str and std.mem.eql(u8, nargs_v.str.bytes, "?")) {
                        // Optional: if next token exists and doesn't start with -, use it; else use const
                        i += 1;
                        if (eq_val) |ev| {
                            var val = Value{ .str = try Str.init(a, ev) };
                            if (type_v != .none) val = convertType(val, type_v) orelse val;
                            try ns.dict.setStr(a, dest, val);
                        } else if (i < argv.len and argv[i] == .str and !std.mem.startsWith(u8, argv[i].str.bytes, "-")) {
                            var val = argv[i];
                            i += 1;
                            if (type_v != .none) val = convertType(val, type_v) orelse val;
                            try ns.dict.setStr(a, dest, val);
                        } else {
                            // Use const value
                            try ns.dict.setStr(a, dest, const_v);
                        }
                        found = true;
                        break;
                    } else {
                        // Normal store: consume next token
                        i += 1;
                        if (eq_val) |ev| {
                            var val = Value{ .str = try Str.init(a, ev) };
                            if (type_v != .none) val = convertType(val, type_v) orelse val;
                            try ns.dict.setStr(a, dest, val);
                        } else if (i < argv.len) {
                            var val = argv[i];
                            i += 1;
                            if (type_v != .none and val == .str) val = convertType(val, type_v) orelse val;
                            try ns.dict.setStr(a, dest, val);
                        }
                        found = true;
                        break;
                    }
                }
            }
            if (!found) {
                // Unknown flag
                try extra.append(a, arg);
                i += 1;
            }
        } else {
            // Positional argument: find nth positional spec
            var handled = false;
            var pos_count: usize = 0;
            for (specs) |sv| {
                if (sv != .dict) continue;
                const spec = sv.dict;
                const is_opt_v = spec.getStr("is_optional") orelse Value{ .boolean = false };
                const is_opt = is_opt_v == .boolean and is_opt_v.boolean;
                if (is_opt) continue;
                if (pos_count < positional_idx) { pos_count += 1; continue; }

                // This is the positional spec we need
                const dest_v = spec.getStr("dest") orelse { pos_count += 1; break; };
                if (dest_v != .str) { pos_count += 1; break; }
                const dest = dest_v.str.bytes;
                const type_v = spec.getStr("type") orelse Value.none;
                const nargs_v = spec.getStr("nargs") orelse Value.none;

                if (nargs_v == .str and (std.mem.eql(u8, nargs_v.str.bytes, "*") or std.mem.eql(u8, nargs_v.str.bytes, "+"))) {
                    // Collect all remaining non-flag args
                    const lst = try List.init(a);
                    while (i < argv.len) {
                        const cur = argv[i];
                        if (cur != .str or std.mem.startsWith(u8, cur.str.bytes, "-")) break;
                        var val = cur;
                        if (type_v != .none) val = convertType(val, type_v) orelse val;
                        try lst.append(a, val);
                        i += 1;
                    }
                    try ns.dict.setStr(a, dest, Value{ .list = lst });
                    positional_idx += 1;
                    handled = true;
                    break;
                } else if (nargs_v == .small_int) {
                    // Collect exactly N args
                    const n: usize = @intCast(nargs_v.small_int);
                    const lst = try List.init(a);
                    var count: usize = 0;
                    while (count < n and i < argv.len) {
                        var val = argv[i];
                        i += 1;
                        if (type_v != .none) val = convertType(val, type_v) orelse val;
                        try lst.append(a, val);
                        count += 1;
                    }
                    try ns.dict.setStr(a, dest, Value{ .list = lst });
                    positional_idx += 1;
                    handled = true;
                    break;
                } else {
                    // Single positional
                    var val = arg;
                    if (type_v != .none and val == .str) val = convertType(val, type_v) orelse val;
                    try ns.dict.setStr(a, dest, val);
                    positional_idx += 1;
                    i += 1;
                    handled = true;
                    break;
                }
            }
            if (!handled) {
                try extra.append(a, arg);
                i += 1;
            }
        }
    }

    return ParseResult{ .ns = Value{ .instance = ns }, .extra = extra };
}

fn convertType(val: Value, type_v: Value) ?Value {
    if (val != .str) return null;
    const type_name: []const u8 = switch (type_v) {
        .class => |c| c.name,
        .builtin_fn => |f| f.name,
        else => return null,
    };
    if (std.mem.eql(u8, type_name, "int")) {
        const n = std.fmt.parseInt(i64, val.str.bytes, 10) catch return null;
        return Value{ .small_int = n };
    }
    if (std.mem.eql(u8, type_name, "float")) {
        const f = std.fmt.parseFloat(f64, val.str.bytes) catch return null;
        return Value{ .float = f };
    }
    if (std.mem.eql(u8, type_name, "str")) return val;
    return null;
}

// ===== set_defaults / get_default =====

fn setDefaultsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return setDefaultsImpl(p, args, &.{}, &.{});
}

fn setDefaultsKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return setDefaultsImpl(p, args, kn, kv);
}

fn setDefaultsImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const self = args[0].instance;

    const overrides_v = self.dict.getStr("_overrides") orelse return Value.none;
    if (overrides_v != .dict) return Value.none;
    const overrides = overrides_v.dict;

    for (kn, kv) |nm, vl| {
        if (nm == .str) try overrides.setStr(a, nm.str.bytes, vl);
    }

    // Also update defaults in existing specs
    const specs_v = self.dict.getStr("_args_list") orelse return Value.none;
    if (specs_v == .list) {
        for (specs_v.list.items.items) |sv| {
            if (sv != .dict) continue;
            const spec = sv.dict;
            const dest_v = spec.getStr("dest") orelse continue;
            if (dest_v != .str) continue;
            if (overrides.getStr(dest_v.str.bytes)) |ov| {
                try spec.setStr(a, "default", ov);
            }
        }
    }

    return Value.none;
}

fn getDefaultFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return Value.none;
    const self = args[0].instance;
    const dest_name = args[1].str.bytes;

    // Check overrides first
    if (self.dict.getStr("_overrides")) |ov| {
        if (ov == .dict) {
            if (ov.dict.getStr(dest_name)) |v| return v;
        }
    }

    // Check specs
    const specs_v = self.dict.getStr("_args_list") orelse return Value.none;
    if (specs_v == .list) {
        for (specs_v.list.items.items) |sv| {
            if (sv != .dict) continue;
            const spec = sv.dict;
            const dest_v = spec.getStr("dest") orelse continue;
            if (dest_v == .str and std.mem.eql(u8, dest_v.str.bytes, dest_name)) {
                return spec.getStr("default") orelse Value.none;
            }
        }
    }
    return Value.none;
}

// ===== format_usage / format_help =====

fn formatUsageFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = args;
    return Value{ .str = try Str.init(a, "usage: prog\n") };
}

fn formatHelpFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = args;
    return Value{ .str = try Str.init(a, "usage: prog\n\nA test\n") };
}

// ===== add_argument_group / add_mutually_exclusive_group =====
// These return a proxy object that delegates add_argument to the parent parser.
// The group class has an add_argument that reads _parent from the instance dict.

var group_class: ?*Class = null;

fn getOrCreateGroupClass(interp: *Interp) !*Class {
    if (group_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try regKwD(a, d, "add_argument", groupAddArgumentFn, groupAddArgumentKw);
    const cls = try Class.init(a, "_ArgGroup", &.{}, d);
    group_class = cls;
    return cls;
}

fn addArgumentGroupFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return makeGroupProxy(p, args);
}

fn addMutuallyExclusiveGroupFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return makeGroupProxy(p, args);
}

fn makeGroupProxy(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const parent = args[0];

    const cls = try getOrCreateGroupClass(interp);
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "_parent", parent);
    return Value{ .instance = inst };
}

fn groupAddArgumentFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return groupAddArgumentImpl(p, args, &.{}, &.{});
}

fn groupAddArgumentKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return groupAddArgumentImpl(p, args, kn, kv);
}

fn groupAddArgumentImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const grp = args[0].instance;
    const parent = grp.dict.getStr("_parent") orelse return Value.none;

    // Build new args with the parent parser as self
    var new_args = try a.alloc(Value, args.len);
    defer a.free(new_args);
    new_args[0] = parent;
    @memcpy(new_args[1..], args[1..]);
    return addArgumentImpl(p, new_args, kn, kv);
}

// ===== print_help / error =====

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

// ===== Stub formatter classes =====

fn makeStubClass(a: std.mem.Allocator, name: []const u8) !*Class {
    const d = try Dict.init(a);
    return try Class.init(a, name, &.{}, d);
}

// ===== FileType callable =====

fn fileTypeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    _ = args;
    // Return a stub callable
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = "FileType_instance", .func = fileTypeCallFn };
    return Value{ .builtin_fn = f };
}

fn fileTypeCallFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    _ = args;
    return Value.none;
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "argparse");

    try regKwM(a, m, "ArgumentParser", argumentParserBuiltin, argumentParserKw);
    try regKwM(a, m, "Namespace", namespaceBuiltin, namespaceKw);

    // Constants
    try m.attrs.setStr(a, "SUPPRESS", Value{ .str = try Str.init(a, "==SUPPRESS==") });
    try m.attrs.setStr(a, "REMAINDER", Value{ .str = try Str.init(a, "...") });

    // Formatter classes (stubs)
    const help_fmt = try makeStubClass(a, "HelpFormatter");
    try m.attrs.setStr(a, "HelpFormatter", Value{ .class = help_fmt });
    const raw_desc_fmt = try makeStubClass(a, "RawDescriptionHelpFormatter");
    try m.attrs.setStr(a, "RawDescriptionHelpFormatter", Value{ .class = raw_desc_fmt });
    const raw_text_fmt = try makeStubClass(a, "RawTextHelpFormatter");
    try m.attrs.setStr(a, "RawTextHelpFormatter", Value{ .class = raw_text_fmt });
    const arg_def_fmt = try makeStubClass(a, "ArgumentDefaultsHelpFormatter");
    try m.attrs.setStr(a, "ArgumentDefaultsHelpFormatter", Value{ .class = arg_def_fmt });
    const metavar_fmt = try makeStubClass(a, "MetavarTypeHelpFormatter");
    try m.attrs.setStr(a, "MetavarTypeHelpFormatter", Value{ .class = metavar_fmt });

    // FileType callable
    const ft = try a.create(BuiltinFn);
    ft.* = .{ .name = "FileType", .func = fileTypeFn };
    try m.attrs.setStr(a, "FileType", Value{ .builtin_fn = ft });

    // ArgumentError and ArgumentTypeError - subclass Exception
    const exc_base: []const *Class = if (interp.builtins.getStr("Exception")) |ev|
        if (ev == .class) &[_]*Class{ev.class} else &.{}
    else &.{};

    const argument_error_cls = try Class.init(a, "ArgumentError", exc_base, try Dict.init(a));
    try m.attrs.setStr(a, "ArgumentError", Value{ .class = argument_error_cls });

    const argument_type_error_cls = try Class.init(a, "ArgumentTypeError", exc_base, try Dict.init(a));
    try m.attrs.setStr(a, "ArgumentTypeError", Value{ .class = argument_type_error_cls });

    return m;
}
