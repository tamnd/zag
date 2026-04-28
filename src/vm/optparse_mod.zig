//! Pinhole `optparse` module.
//! Implements OptionParser, Values, Option, make_option,
//! add_option_group, OptionGroup, and exception classes.

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

// ===== helpers =====

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

fn regM(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn regMKw(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

// ===== Global state for module-level classes =====

const OptparseState = struct {
    values_class: ?*Class = null,
    option_class: ?*Class = null,
    option_group_class: ?*Class = null,
    parser_class: ?*Class = null,
    option_error_class: ?*Class = null,
    option_value_error_class: ?*Class = null,
    bad_option_error_class: ?*Class = null,
};

var global_state: OptparseState = .{};

fn getState() *OptparseState {
    return &global_state;
}

// ===== derive dest from long option string =====

fn deriveDest(a: std.mem.Allocator, long_opt: []const u8) ![]u8 {
    var s = long_opt;
    while (s.len > 0 and s[0] == '-') s = s[1..];
    const buf = try a.dupe(u8, s);
    for (buf) |*c| if (c.* == '-') { c.* = '_'; };
    return buf;
}

// ===== Values class =====

fn valuesInit(p: *anyopaque, args: []const Value) anyerror!Value {
    return valuesInitImpl(p, args, &.{}, &.{});
}

fn valuesInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return valuesInitImpl(p, args, kn, kv);
}

fn valuesInitImpl(p: *anyopaque, args: []const Value, _kn: []const Value, _kv: []const Value) anyerror!Value {
    _ = _kn;
    _ = _kv;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    // optional dict argument
    if (args.len >= 2 and args[1] == .dict) {
        for (args[1].dict.pairs.items) |pair| {
            try inst.dict.setKey(a, pair.key, pair.value);
        }
    }
    return Value.none;
}

fn valuesEnsureValue(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 3 or args[0] != .instance or args[1] != .str) return Value.none;
    const inst = args[0].instance;
    const key = args[1].str.bytes;
    const default_v = args[2];
    if (inst.dict.getStr(key)) |v| {
        if (v != .none) return v;
    }
    try inst.dict.setStr(a, key, default_v);
    return default_v;
}

fn getOrCreateValuesClass(interp: *Interp) !*Class {
    const st = getState();
    if (st.values_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try reg(a, d, "__init__", valuesInit);
    try reg(a, d, "ensure_value", valuesEnsureValue);
    const cls = try Class.init(a, "Values", &.{}, d);
    st.values_class = cls;
    return cls;
}

// ===== Option class =====

fn optionInit(p: *anyopaque, args: []const Value) anyerror!Value {
    return optionInitImpl(p, args, &.{}, &.{});
}

fn optionInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return optionInitImpl(p, args, kn, kv);
}

fn optionInitImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    // collect positional option strings
    for (args[1..]) |av| {
        if (av != .str) continue;
        const s = av.str.bytes;
        if (std.mem.startsWith(u8, s, "--")) {
            try inst.dict.setStr(a, "_long", av);
        } else if (std.mem.startsWith(u8, s, "-")) {
            try inst.dict.setStr(a, "_short", av);
        }
    }
    for (kn, kv) |k, v| {
        if (k != .str) continue;
        try inst.dict.setStr(a, k.str.bytes, v);
    }
    // compute dest if not set
    if (inst.dict.getStr("dest") == null) {
        if (inst.dict.getStr("_long")) |lv| {
            if (lv == .str) {
                const dest = try deriveDest(a, lv.str.bytes);
                defer a.free(dest);
                try inst.dict.setStr(a, "dest", Value{ .str = try Str.init(a, dest) });
            }
        } else if (inst.dict.getStr("_short")) |sv| {
            if (sv == .str) {
                const dest = try deriveDest(a, sv.str.bytes);
                defer a.free(dest);
                try inst.dict.setStr(a, "dest", Value{ .str = try Str.init(a, dest) });
            }
        }
    }
    return Value.none;
}

fn getOrCreateOptionClass(interp: *Interp) !*Class {
    const st = getState();
    if (st.option_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try regKw(a, d, "__init__", optionInit, optionInitKw);
    const cls = try Class.init(a, "Option", &.{}, d);
    st.option_class = cls;
    return cls;
}

// ===== make_option =====

fn makeOptionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return makeOptionImpl(p, args, &.{}, &.{});
}

fn makeOptionKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return makeOptionImpl(p, args, kn, kv);
}

fn makeOptionImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const cls = try getOrCreateOptionClass(interp);
    const inst = try Instance.init(a, cls);
    const inst_v = Value{ .instance = inst };
    // build args with self prepended
    var all_args = try a.alloc(Value, args.len + 1);
    defer a.free(all_args);
    all_args[0] = inst_v;
    @memcpy(all_args[1..], args);
    _ = try optionInitImpl(p, all_args, kn, kv);
    return inst_v;
}

// ===== OptionGroup class =====

fn optGroupInit(p: *anyopaque, args: []const Value) anyerror!Value {
    return optGroupInitImpl(p, args, &.{}, &.{});
}

fn optGroupInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return optGroupInitImpl(p, args, kn, kv);
}

fn optGroupInitImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    _ = kv;
    _ = kn;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    // args: self, parser, title
    const parser_v = if (args.len >= 2) args[1] else Value.none;
    const title_v = if (args.len >= 3) args[2] else Value.none;
    try inst.dict.setStr(a, "_parser", parser_v);
    try inst.dict.setStr(a, "title", title_v);
    const opts = try List.init(a);
    try inst.dict.setStr(a, "_options", Value{ .list = opts });
    return Value.none;
}

fn optGroupAddOption(p: *anyopaque, args: []const Value) anyerror!Value {
    return optGroupAddOptionImpl(p, args, &.{}, &.{});
}

fn optGroupAddOptionKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return optGroupAddOptionImpl(p, args, kn, kv);
}

fn optGroupAddOptionImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    // forward to parser's add_option
    const parser_v = inst.dict.getStr("_parser") orelse return Value.none;
    if (parser_v != .instance) return Value.none;
    // call parser add_option with remaining args
    const rest = args[1..];
    return parserAddOptionImpl(p, rest, kn, kv, parser_v.instance);
}

fn getOrCreateOptionGroupClass(interp: *Interp) !*Class {
    const st = getState();
    if (st.option_group_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try regKw(a, d, "__init__", optGroupInit, optGroupInitKw);
    try regKw(a, d, "add_option", optGroupAddOption, optGroupAddOptionKw);
    const cls = try Class.init(a, "OptionGroup", &.{}, d);
    st.option_group_class = cls;
    return cls;
}

// ===== OptionParser class =====

fn parserAddOptionImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value, parser_inst: *Instance) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;

    // create option object
    const opt_cls = try getOrCreateOptionClass(interp);
    const opt_inst = try Instance.init(a, opt_cls);
    const opt_v = Value{ .instance = opt_inst };

    // collect positional option strings
    for (args) |av| {
        if (av != .str) continue;
        const s = av.str.bytes;
        if (std.mem.startsWith(u8, s, "--")) {
            try opt_inst.dict.setStr(a, "_long", av);
        } else if (std.mem.startsWith(u8, s, "-")) {
            try opt_inst.dict.setStr(a, "_short", av);
        }
    }

    var dest_set = false;
    for (kn, kv) |k, v| {
        if (k != .str) continue;
        try opt_inst.dict.setStr(a, k.str.bytes, v);
        if (std.mem.eql(u8, k.str.bytes, "dest")) dest_set = true;
    }

    // compute dest if not explicitly set
    if (!dest_set) {
        if (opt_inst.dict.getStr("_long")) |lv| {
            if (lv == .str) {
                const dest = try deriveDest(a, lv.str.bytes);
                defer a.free(dest);
                try opt_inst.dict.setStr(a, "dest", Value{ .str = try Str.init(a, dest) });
            }
        } else if (opt_inst.dict.getStr("_short")) |sv| {
            if (sv == .str) {
                const dest = try deriveDest(a, sv.str.bytes);
                defer a.free(dest);
                try opt_inst.dict.setStr(a, "dest", Value{ .str = try Str.init(a, dest) });
            }
        }
    }

    // default action
    if (opt_inst.dict.getStr("action") == null) {
        try opt_inst.dict.setStr(a, "action", Value{ .str = try Str.init(a, "store") });
    }

    // set default for store_true/store_false if not provided
    const action_v = opt_inst.dict.getStr("action") orelse Value.none;
    if (action_v == .str) {
        const act = action_v.str.bytes;
        if (std.mem.eql(u8, act, "store_true")) {
            if (opt_inst.dict.getStr("default") == null)
                try opt_inst.dict.setStr(a, "default", Value{ .boolean = false });
        } else if (std.mem.eql(u8, act, "store_false")) {
            if (opt_inst.dict.getStr("default") == null)
                try opt_inst.dict.setStr(a, "default", Value{ .boolean = true });
        } else if (std.mem.eql(u8, act, "count")) {
            if (opt_inst.dict.getStr("default") == null)
                try opt_inst.dict.setStr(a, "default", Value{ .none = {} });
        } else if (std.mem.eql(u8, act, "append")) {
            if (opt_inst.dict.getStr("default") == null)
                try opt_inst.dict.setStr(a, "default", Value{ .none = {} });
        }
    }

    // add to parser's option list
    const opts_v = parser_inst.dict.getStr("_options") orelse return Value.none;
    if (opts_v == .list) try opts_v.list.append(a, opt_v);
    return Value.none;
}

fn parserAddOptionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return parserAddOptionKwImpl(p, args, &.{}, &.{});
}

fn parserAddOptionKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return parserAddOptionKwImpl(p, args, kn, kv);
}

fn parserAddOptionKwImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const parser_inst = args[0].instance;
    return parserAddOptionImpl(p, args[1..], kn, kv, parser_inst);
}

fn convertOptValue(a: std.mem.Allocator, val: Value, type_v: Value) !Value {
    if (val != .str) return val;
    if (type_v != .str) return val;
    const t = type_v.str.bytes;
    if (std.mem.eql(u8, t, "int")) {
        const n = std.fmt.parseInt(i64, val.str.bytes, 10) catch return val;
        return Value{ .small_int = n };
    }
    if (std.mem.eql(u8, t, "float")) {
        const f = std.fmt.parseFloat(f64, val.str.bytes) catch return val;
        return Value{ .float = f };
    }
    _ = a;
    return val;
}

fn parserParseArgs(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const parser_inst = args[0].instance;

    var argv: []Value = &.{};
    if (args.len >= 2 and args[1] == .list) argv = args[1].list.items.items;

    const opts_v = parser_inst.dict.getStr("_options") orelse return Value.none;
    if (opts_v != .list) return Value.none;
    const option_list = opts_v.list.items.items;

    // build namespace with defaults
    const vals_cls = try getOrCreateValuesClass(interp);
    const vals_inst = try Instance.init(a, vals_cls);

    // apply set_defaults values
    if (parser_inst.dict.getStr("_defaults")) |dv| {
        if (dv == .dict) {
            for (dv.dict.pairs.items) |pair| {
                try vals_inst.dict.setKey(a, pair.key, pair.value);
            }
        }
    }

    // apply per-option defaults
    for (option_list) |ov| {
        if (ov != .instance) continue;
        const opt = ov.instance;
        const dest_v = opt.dict.getStr("dest") orelse continue;
        if (dest_v != .str) continue;
        const default_v = opt.dict.getStr("default") orelse Value.none;
        if (vals_inst.dict.getStr(dest_v.str.bytes) == null)
            try vals_inst.dict.setStr(a, dest_v.str.bytes, default_v);
    }

    const remaining = try List.init(a);
    var i: usize = 0;
    var end_of_options = false;

    while (i < argv.len) {
        const arg = argv[i];
        if (arg != .str) { i += 1; continue; }
        const s = arg.str.bytes;

        if (!end_of_options and std.mem.eql(u8, s, "--")) {
            end_of_options = true;
            i += 1;
            continue;
        }

        if (!end_of_options and std.mem.startsWith(u8, s, "-") and s.len > 1) {
            // could be --flag=value
            var flag_str = s;
            var inline_val: ?[]const u8 = null;
            if (std.mem.startsWith(u8, s, "--")) {
                if (std.mem.indexOfScalar(u8, s, '=')) |eq| {
                    flag_str = s[0..eq];
                    inline_val = s[eq + 1 ..];
                }
            }

            var found = false;
            for (option_list) |ov| {
                if (ov != .instance) continue;
                const opt = ov.instance;
                const long_v = opt.dict.getStr("_long") orelse Value.none;
                const short_v = opt.dict.getStr("_short") orelse Value.none;
                const matches = (long_v == .str and std.mem.eql(u8, long_v.str.bytes, flag_str)) or
                    (short_v == .str and std.mem.eql(u8, short_v.str.bytes, flag_str));
                if (!matches) continue;

                const dest_v = opt.dict.getStr("dest") orelse { found = true; i += 1; break; };
                if (dest_v != .str) { found = true; i += 1; break; }
                const dest = dest_v.str.bytes;
                const action_v = opt.dict.getStr("action") orelse Value{ .str = try Str.init(a, "store") };
                const action = if (action_v == .str) action_v.str.bytes else "store";
                const type_v = opt.dict.getStr("type") orelse Value.none;
                const const_v = opt.dict.getStr("const") orelse Value.none;

                if (std.mem.eql(u8, action, "store_true")) {
                    try vals_inst.dict.setStr(a, dest, Value{ .boolean = true });
                } else if (std.mem.eql(u8, action, "store_false")) {
                    try vals_inst.dict.setStr(a, dest, Value{ .boolean = false });
                } else if (std.mem.eql(u8, action, "store_const")) {
                    try vals_inst.dict.setStr(a, dest, const_v);
                } else if (std.mem.eql(u8, action, "count")) {
                    const cur = vals_inst.dict.getStr(dest) orelse Value{ .small_int = 0 };
                    const cur_n: i64 = if (cur == .small_int) cur.small_int else 0;
                    try vals_inst.dict.setStr(a, dest, Value{ .small_int = cur_n + 1 });
                } else if (std.mem.eql(u8, action, "append")) {
                    const raw_val: Value = if (inline_val) |iv|
                        Value{ .str = try Str.init(a, iv) }
                    else blk: {
                        i += 1;
                        if (i >= argv.len) break :blk Value.none;
                        break :blk argv[i];
                    };
                    const conv_val = try convertOptValue(a, raw_val, type_v);
                    const cur_list = vals_inst.dict.getStr(dest) orelse Value.none;
                    const lst = if (cur_list == .list) cur_list.list else try List.init(a);
                    try lst.append(a, conv_val);
                    try vals_inst.dict.setStr(a, dest, Value{ .list = lst });
                } else {
                    // store
                    const nargs_v = opt.dict.getStr("nargs") orelse Value.none;
                    if (nargs_v == .small_int and nargs_v.small_int > 0) {
                        const n: usize = @intCast(nargs_v.small_int);
                        const tup = try Tuple.init(a, n);
                        var j: usize = 0;
                        while (j < n) : (j += 1) {
                            i += 1;
                            const tv: Value = if (i < argv.len) argv[i] else Value.none;
                            tup.items[j] = try convertOptValue(a, tv, type_v);
                        }
                        try vals_inst.dict.setStr(a, dest, Value{ .tuple = tup });
                    } else {
                        const raw_val: Value = if (inline_val) |iv|
                            Value{ .str = try Str.init(a, iv) }
                        else blk: {
                            i += 1;
                            if (i >= argv.len) break :blk Value.none;
                            break :blk argv[i];
                        };
                        const conv_val = try convertOptValue(a, raw_val, type_v);
                        try vals_inst.dict.setStr(a, dest, conv_val);
                    }
                }
                found = true;
                i += 1;
                break;
            }
            if (!found) {
                // unknown option — skip
                i += 1;
            }
        } else {
            try remaining.append(a, arg);
            i += 1;
        }
    }

    const tup = try Tuple.init(a, 2);
    tup.items[0] = Value{ .instance = vals_inst };
    tup.items[1] = Value{ .list = remaining };
    return Value{ .tuple = tup };
}

fn parserSetDefaults(p: *anyopaque, args: []const Value) anyerror!Value {
    return parserSetDefaultsKw(p, args, &.{}, &.{});
}

fn parserSetDefaultsKwImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const parser_inst = args[0].instance;
    var defaults_d: *Dict = undefined;
    if (parser_inst.dict.getStr("_defaults")) |dv| {
        if (dv == .dict) {
            defaults_d = dv.dict;
        } else {
            defaults_d = try Dict.init(a);
            try parser_inst.dict.setStr(a, "_defaults", Value{ .dict = defaults_d });
        }
    } else {
        defaults_d = try Dict.init(a);
        try parser_inst.dict.setStr(a, "_defaults", Value{ .dict = defaults_d });
    }
    for (kn, kv) |k, v| {
        if (k != .str) continue;
        try defaults_d.setStr(a, k.str.bytes, v);
    }
    return Value.none;
}

fn parserSetDefaultsKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return parserSetDefaultsKwImpl(p, args, kn, kv);
}

fn parserHasOption(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return Value{ .boolean = false };
    const parser_inst = args[0].instance;
    const name = args[1].str.bytes;
    const opts_v = parser_inst.dict.getStr("_options") orelse return Value{ .boolean = false };
    if (opts_v != .list) return Value{ .boolean = false };
    for (opts_v.list.items.items) |ov| {
        if (ov != .instance) continue;
        const opt = ov.instance;
        if (opt.dict.getStr("_long")) |lv| {
            if (lv == .str and std.mem.eql(u8, lv.str.bytes, name)) return Value{ .boolean = true };
        }
        if (opt.dict.getStr("_short")) |sv| {
            if (sv == .str and std.mem.eql(u8, sv.str.bytes, name)) return Value{ .boolean = true };
        }
    }
    return Value{ .boolean = false };
}

fn parserGetOption(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return Value.none;
    const parser_inst = args[0].instance;
    const name = args[1].str.bytes;
    const opts_v = parser_inst.dict.getStr("_options") orelse return Value.none;
    if (opts_v != .list) return Value.none;
    for (opts_v.list.items.items) |ov| {
        if (ov != .instance) continue;
        const opt = ov.instance;
        if (opt.dict.getStr("_long")) |lv| {
            if (lv == .str and std.mem.eql(u8, lv.str.bytes, name)) return ov;
        }
        if (opt.dict.getStr("_short")) |sv| {
            if (sv == .str and std.mem.eql(u8, sv.str.bytes, name)) return ov;
        }
    }
    return Value.none;
}

fn parserRemoveOption(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return Value.none;
    const parser_inst = args[0].instance;
    const name = args[1].str.bytes;
    const opts_v = parser_inst.dict.getStr("_options") orelse return Value.none;
    if (opts_v != .list) return Value.none;
    const items = opts_v.list.items.items;
    var idx: ?usize = null;
    for (items, 0..) |ov, ii| {
        if (ov != .instance) continue;
        const opt = ov.instance;
        if (opt.dict.getStr("_long")) |lv| {
            if (lv == .str and std.mem.eql(u8, lv.str.bytes, name)) { idx = ii; break; }
        }
        if (opt.dict.getStr("_short")) |sv| {
            if (sv == .str and std.mem.eql(u8, sv.str.bytes, name)) { idx = ii; break; }
        }
    }
    if (idx) |ii| _ = opts_v.list.items.orderedRemove(ii);
    return Value.none;
}

fn parserAddOptionGroup(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value.none;
    const parser_v = args[0];
    const title_v = args[1];
    const grp_cls = try getOrCreateOptionGroupClass(interp);
    const grp_inst = try Instance.init(a, grp_cls);
    try grp_inst.dict.setStr(a, "_parser", parser_v);
    try grp_inst.dict.setStr(a, "title", title_v);
    const opts = try List.init(a);
    try grp_inst.dict.setStr(a, "_options", Value{ .list = opts });
    return Value{ .instance = grp_inst };
}

fn parserGetDefaultValues(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const parser_inst = args[0].instance;
    const vals_cls = try getOrCreateValuesClass(interp);
    const vals_inst = try Instance.init(a, vals_cls);
    if (parser_inst.dict.getStr("_defaults")) |dv| {
        if (dv == .dict) {
            for (dv.dict.pairs.items) |pair| {
                try vals_inst.dict.setKey(a, pair.key, pair.value);
            }
        }
    }
    const opts_v = parser_inst.dict.getStr("_options") orelse return Value{ .instance = vals_inst };
    if (opts_v == .list) {
        for (opts_v.list.items.items) |ov| {
            if (ov != .instance) continue;
            const opt = ov.instance;
            const dest_v = opt.dict.getStr("dest") orelse continue;
            if (dest_v != .str) continue;
            const default_v = opt.dict.getStr("default") orelse Value.none;
            try vals_inst.dict.setStr(a, dest_v.str.bytes, default_v);
        }
    }
    return Value{ .instance = vals_inst };
}

fn parserFormatHelp(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .str = try Str.init(a, "") };
    const parser_inst = args[0].instance;
    const prog = if (parser_inst.dict.getStr("prog")) |pv| (if (pv == .str) pv.str.bytes else "") else "";
    const desc = if (parser_inst.dict.getStr("description")) |dv| (if (dv == .str) dv.str.bytes else "") else "";
    const help_str = try std.fmt.allocPrint(a, "Usage: {s}\n\n{s}\n", .{ prog, desc });
    defer a.free(help_str);
    return Value{ .str = try Str.init(a, help_str) };
}

fn parserFormatUsage(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .str = try Str.init(a, "") };
    const parser_inst = args[0].instance;
    const prog = if (parser_inst.dict.getStr("prog")) |pv| (if (pv == .str) pv.str.bytes else "") else "";
    const usage_str = try std.fmt.allocPrint(a, "Usage: {s}\n", .{prog});
    defer a.free(usage_str);
    return Value{ .str = try Str.init(a, usage_str) };
}

fn parserInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return parserInitImpl(p, args, &.{}, &.{});
}

fn parserInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return parserInitImpl(p, args, kn, kv);
}

fn parserInitImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const opts = try List.init(a);
    try inst.dict.setStr(a, "_options", Value{ .list = opts });
    for (kn, kv) |k, v| {
        if (k != .str) continue;
        try inst.dict.setStr(a, k.str.bytes, v);
    }
    return Value.none;
}

fn getOrCreateParserClass(interp: *Interp) !*Class {
    const st = getState();
    if (st.parser_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try regKw(a, d, "__init__", parserInitFn, parserInitKw);
    try regKw(a, d, "add_option", parserAddOptionFn, parserAddOptionKw);
    try reg(a, d, "parse_args", parserParseArgs);
    try regKw(a, d, "set_defaults", parserSetDefaults, parserSetDefaultsKwImpl);
    try reg(a, d, "has_option", parserHasOption);
    try reg(a, d, "get_option", parserGetOption);
    try reg(a, d, "remove_option", parserRemoveOption);
    try reg(a, d, "add_option_group", parserAddOptionGroup);
    try reg(a, d, "get_default_values", parserGetDefaultValues);
    try reg(a, d, "format_help", parserFormatHelp);
    try reg(a, d, "format_usage", parserFormatUsage);
    const cls = try Class.init(a, "OptionParser", &.{}, d);
    st.parser_class = cls;
    return cls;
}

// ===== OptionParser constructor (module-level) =====

fn optionParserFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return optionParserImpl(p, args, &.{}, &.{});
}

fn optionParserKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return optionParserImpl(p, args, kn, kv);
}

fn optionParserImpl(p: *anyopaque, _args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    _ = _args;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const cls = try getOrCreateParserClass(interp);
    const inst = try Instance.init(a, cls);
    const opts = try List.init(a);
    try inst.dict.setStr(a, "_options", Value{ .list = opts });
    for (kn, kv) |k, v| {
        if (k != .str) continue;
        try inst.dict.setStr(a, k.str.bytes, v);
    }
    return Value{ .instance = inst };
}

// ===== Values constructor (module-level) =====

fn valuesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return valuesKwImpl(p, args, &.{}, &.{});
}

fn valuesKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return valuesKwImpl(p, args, kn, kv);
}

fn valuesKwImpl(p: *anyopaque, args: []const Value, _kn: []const Value, _kv: []const Value) anyerror!Value {
    _ = _kn;
    _ = _kv;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const cls = try getOrCreateValuesClass(interp);
    const inst = try Instance.init(a, cls);
    if (args.len >= 1 and args[0] == .dict) {
        for (args[0].dict.pairs.items) |pair| {
            try inst.dict.setKey(a, pair.key, pair.value);
        }
    }
    return Value{ .instance = inst };
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "optparse");

    // reset state each build
    global_state = .{};

    try regMKw(a, m, "OptionParser", optionParserFn, optionParserKw);
    try regMKw(a, m, "Values", valuesFn, valuesKw);
    try regMKw(a, m, "make_option", makeOptionFn, makeOptionKw);

    // expose classes
    const opt_cls = try getOrCreateOptionClass(interp);
    try m.attrs.setStr(a, "Option", Value{ .class = opt_cls });
    const grp_cls = try getOrCreateOptionGroupClass(interp);
    try m.attrs.setStr(a, "OptionGroup", Value{ .class = grp_cls });
    const parser_cls = try getOrCreateParserClass(interp);
    try m.attrs.setStr(a, "OptionParser", Value{ .class = parser_cls });

    // SUPPRESS_HELP constant
    try m.attrs.setStr(a, "SUPPRESS_HELP", Value{ .str = try Str.init(a, "SUPPRESS HELP") });
    try m.attrs.setStr(a, "SUPPRESS_USAGE", Value{ .str = try Str.init(a, "SUPPRESS USAGE") });

    // exception classes — inherit from Exception so issubclass(_, Exception) is True
    const exc_base: []const *Class = if (interp.builtins.getStr("Exception")) |ev|
        if (ev == .class) &[_]*Class{ev.class} else &.{}
    else &.{};

    const exc_d = try Dict.init(a);
    const option_error_cls = try Class.init(a, "OptionError", exc_base, exc_d);
    getState().option_error_class = option_error_cls;
    try m.attrs.setStr(a, "OptionError", Value{ .class = option_error_cls });

    const ovc_d = try Dict.init(a);
    const option_value_error_cls = try Class.init(a, "OptionValueError", &.{option_error_cls}, ovc_d);
    getState().option_value_error_class = option_value_error_cls;
    try m.attrs.setStr(a, "OptionValueError", Value{ .class = option_value_error_cls });

    const boe_d = try Dict.init(a);
    const bad_option_error_cls = try Class.init(a, "BadOptionError", &.{option_error_cls}, boe_d);
    getState().bad_option_error_class = bad_option_error_cls;
    try m.attrs.setStr(a, "BadOptionError", Value{ .class = bad_option_error_cls });

    return m;
}
