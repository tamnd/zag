//! csv module — reader/writer/DictReader/DictWriter/Sniffer/dialects.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const List = @import("../object/list.zig").List;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Tuple = @import("../object/tuple.zig").Tuple;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");
const dunder = @import("dunder.zig");

// ===== quoting constants =====
pub const QUOTE_MINIMAL: i64 = 0;
pub const QUOTE_ALL: i64 = 1;
pub const QUOTE_NONNUMERIC: i64 = 2;
pub const QUOTE_NONE: i64 = 3;
pub const QUOTE_STRINGS: i64 = 4;
pub const QUOTE_NOTNULL: i64 = 5;

// ===== Dialect struct =====
const DialectOpts = struct {
    delimiter: u8 = ',',
    quotechar: u8 = '"',
    doublequote: bool = true,
    skipinitialspace: bool = false,
    lineterminator: []const u8 = "\r\n",
    quoting: i64 = QUOTE_MINIMAL,
    escapechar: ?u8 = null,
};

// Global field_size_limit (default from CPython)
var g_field_size_limit: i64 = 131072;

// Global custom dialect registry: name -> DialectOpts
// We keep a simple fixed-size array for custom dialects.
const MAX_CUSTOM_DIALECTS = 32;
const CustomDialect = struct {
    name: [64]u8,
    name_len: usize,
    opts: DialectOpts,
};
var g_custom_dialects: [MAX_CUSTOM_DIALECTS]CustomDialect = undefined;
var g_custom_dialect_count: usize = 0;

fn findCustomDialect(name: []const u8) ?*CustomDialect {
    for (g_custom_dialects[0..g_custom_dialect_count]) |*cd| {
        if (std.mem.eql(u8, cd.name[0..cd.name_len], name)) return cd;
    }
    return null;
}

fn builtinDialect(name: []const u8) ?DialectOpts {
    if (std.mem.eql(u8, name, "excel")) return .{};
    if (std.mem.eql(u8, name, "excel-tab")) return .{ .delimiter = '\t' };
    if (std.mem.eql(u8, name, "unix")) return .{ .lineterminator = "\n", .quoting = QUOTE_ALL };
    return null;
}

fn resolveDialect(name: []const u8) ?DialectOpts {
    if (findCustomDialect(name)) |cd| return cd.opts;
    return builtinDialect(name);
}

fn dialectFromKw(base: DialectOpts, kw_names: []const Value, kw_values: []const Value) DialectOpts {
    var d = base;
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) continue;
        const k = kn.str.bytes;
        if (std.mem.eql(u8, k, "delimiter")) {
            if (kv == .str and kv.str.bytes.len > 0) d.delimiter = kv.str.bytes[0];
        } else if (std.mem.eql(u8, k, "quotechar")) {
            if (kv == .str and kv.str.bytes.len > 0) d.quotechar = kv.str.bytes[0];
        } else if (std.mem.eql(u8, k, "doublequote")) {
            if (kv == .boolean) d.doublequote = kv.boolean;
        } else if (std.mem.eql(u8, k, "skipinitialspace")) {
            if (kv == .boolean) d.skipinitialspace = kv.boolean;
        } else if (std.mem.eql(u8, k, "lineterminator")) {
            if (kv == .str) d.lineterminator = kv.str.bytes;
        } else if (std.mem.eql(u8, k, "quoting")) {
            if (kv == .small_int) d.quoting = kv.small_int;
        } else if (std.mem.eql(u8, k, "escapechar")) {
            if (kv == .str and kv.str.bytes.len > 0) d.escapechar = kv.str.bytes[0];
        }
    }
    return d;
}

// Determine dialect from positional arg 2 or keyword "dialect"
fn resolveDialectArg(args: []const Value, kw_names: []const Value, kw_values: []const Value) DialectOpts {
    var base: DialectOpts = .{};
    // positional dialect arg
    if (args.len >= 2 and args[1] == .str) {
        if (resolveDialect(args[1].str.bytes)) |d| base = d;
    }
    // keyword dialect
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "dialect")) {
            if (kv == .str) {
                if (resolveDialect(kv.str.bytes)) |d| base = d;
            }
        }
    }
    return dialectFromKw(base, kw_names, kw_values);
}

// Build a dialect instance with all attrs
fn makeDialectInst(interp: *Interp, opts: DialectOpts) !Value {
    const a = interp.allocator;
    const cls = interp.csv_dialect_class orelse return Value{ .none = {} };
    const inst = try Instance.init(a, cls);
    var delim_buf = [1]u8{opts.delimiter};
    try inst.dict.setStr(a, "delimiter", Value{ .str = try Str.init(a, &delim_buf) });
    var qc_buf = [1]u8{opts.quotechar};
    try inst.dict.setStr(a, "quotechar", Value{ .str = try Str.init(a, &qc_buf) });
    try inst.dict.setStr(a, "doublequote", Value{ .boolean = opts.doublequote });
    try inst.dict.setStr(a, "skipinitialspace", Value{ .boolean = opts.skipinitialspace });
    try inst.dict.setStr(a, "lineterminator", Value{ .str = try Str.init(a, opts.lineterminator) });
    try inst.dict.setStr(a, "quoting", Value{ .small_int = opts.quoting });
    return Value{ .instance = inst };
}

// ===== parsing =====

fn stripEol(line: []const u8) []const u8 {
    var n = line.len;
    while (n > 0 and (line[n - 1] == '\n' or line[n - 1] == '\r')) n -= 1;
    return line[0..n];
}

fn lineFromValue(v: Value) ?[]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        .bytes => |b| b.data,
        else => null,
    };
}

fn parseCsvLine(a: std.mem.Allocator, raw: []const u8, opts: DialectOpts) !*List {
    const line = stripEol(raw);
    const out = try List.init(a);
    var field: std.ArrayListUnmanaged(u8) = .empty;
    defer field.deinit(a);
    var i: usize = 0;
    var in_quotes = false;
    var started = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_quotes) {
            if (c == opts.quotechar) {
                if (opts.doublequote and i + 1 < line.len and line[i + 1] == opts.quotechar) {
                    try field.append(a, opts.quotechar);
                    i += 1;
                } else {
                    in_quotes = false;
                }
            } else {
                try field.append(a, c);
            }
        } else if (c == opts.quotechar and !started) {
            in_quotes = true;
            started = true;
        } else if (c == opts.delimiter) {
            const s = try Str.init(a, field.items);
            try out.append(a, Value{ .str = s });
            field.clearRetainingCapacity();
            started = false;
        } else {
            if (opts.skipinitialspace and !started and c == ' ') continue;
            try field.append(a, c);
            started = true;
        }
    }
    const s = try Str.init(a, field.items);
    try out.append(a, Value{ .str = s });
    return out;
}

fn collectLines(interp: *Interp, src: Value) !std.ArrayListUnmanaged([]const u8) {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const a = interp.allocator;
    switch (src) {
        .list => |l| for (l.items.items) |it| {
            const s = lineFromValue(it) orelse continue;
            try out.append(a, s);
        },
        .tuple => |t| for (t.items) |it| {
            const s = lineFromValue(it) orelse continue;
            try out.append(a, s);
        },
        else => {
            const it = try dispatch.makeIter(interp, src);
            const iv = Value{ .iter = it };
            while (try dispatch.iterStep(interp, iv)) |v| {
                const s = lineFromValue(v) orelse continue;
                try out.append(a, s);
            }
        },
    }
    return out;
}

// ===== CSV writing =====

fn fieldStr(a: std.mem.Allocator, v: Value) !?[]const u8 {
    return switch (v) {
        .str => |s| s.bytes,
        .small_int => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        .boolean => |b| if (b) "True" else "False",
        .none => null, // None -> empty (no quotes for QUOTE_NOTNULL)
        else => "",
    };
}

fn isNumericValue(v: Value) bool {
    return switch (v) {
        .small_int, .float => true,
        .big_int => true,
        else => false,
    };
}

fn buildRowStrOpts(a: std.mem.Allocator, row: []const Value, opts: DialectOpts) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    for (row, 0..) |v, idx| {
        if (idx > 0) try buf.append(a, opts.delimiter);
        // Determine whether to quote this field
        const is_none = (v == .none);
        const is_numeric = isNumericValue(v);
        const raw_s = try fieldStr(a, v);
        const s: []const u8 = raw_s orelse "";
        const force_quote = switch (opts.quoting) {
            QUOTE_ALL => true,
            QUOTE_NONNUMERIC => !is_numeric,
            QUOTE_STRINGS => !is_numeric,
            QUOTE_NOTNULL => !is_none,
            QUOTE_NONE => false,
            else => false, // QUOTE_MINIMAL: quote only if needed
        };
        // For QUOTE_NOTNULL with None: emit empty unquoted field
        if (opts.quoting == QUOTE_NOTNULL and is_none) {
            // empty, no quotes
            continue;
        }
        if (force_quote) {
            try buf.append(a, opts.quotechar);
            for (s) |c| {
                if (c == opts.quotechar) try buf.append(a, opts.quotechar);
                try buf.append(a, c);
            }
            try buf.append(a, opts.quotechar);
        } else if (opts.quoting == QUOTE_NONE) {
            // escape delimiter if present
            for (s) |c| {
                if (c == opts.delimiter) {
                    if (opts.escapechar) |ec| try buf.append(a, ec);
                }
                try buf.append(a, c);
            }
        } else {
            // QUOTE_MINIMAL: quote only if needed
            var needs_quote = false;
            for (s) |c| {
                if (c == opts.delimiter or c == opts.quotechar or c == '\r' or c == '\n') {
                    needs_quote = true;
                    break;
                }
            }
            if (needs_quote) {
                try buf.append(a, opts.quotechar);
                for (s) |c| {
                    if (c == opts.quotechar) try buf.append(a, opts.quotechar);
                    try buf.append(a, c);
                }
                try buf.append(a, opts.quotechar);
            } else {
                try buf.appendSlice(a, s);
            }
        }
    }
    try buf.appendSlice(a, opts.lineterminator);
    return buf.toOwnedSlice(a);
}

fn writeToTarget(interp: *Interp, target: Value, payload: []const u8) !void {
    const s = try Str.init(interp.allocator, payload);
    _ = (try dunder.call(interp, target, "write", &.{Value{ .str = s }})) orelse {
        try interp.typeError("csv writer target has no write method");
        return error.TypeError;
    };
}

// ===== Reader object =====

const ReaderState = struct {
    rows: std.ArrayListUnmanaged(*List),
    pos: usize,
    line_num: usize,
    opts: DialectOpts,
    allocator: std.mem.Allocator,
    fn deinit(s: *ReaderState) void {
        s.rows.deinit(s.allocator);
        s.allocator.destroy(s);
    }
};

fn readerStateFrom(inst: *Instance) ?*ReaderState {
    const v = inst.dict.getStr("_rs") orelse return null;
    if (v != .small_int or v.small_int == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(v.small_int)));
}

fn readerIterFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return Value{ .none = {} };
    return args[0];
}

fn readerNextFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    }
    const state = readerStateFrom(args[0].instance) orelse {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    };
    if (state.pos >= state.rows.items.len) {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    }
    const row = state.rows.items[state.pos];
    state.pos += 1;
    state.line_num = state.pos;
    try args[0].instance.dict.setStr(interp.allocator, "line_num", Value{ .small_int = @intCast(state.line_num) });
    return Value{ .list = row };
}

fn readerFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return readerKw(p, args, &.{}, &.{});
}

fn readerKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    const opts = resolveDialectArg(args, kw_names, kw_values);
    // Also read skipinitialspace from kw
    var final_opts = opts;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "skipinitialspace") and kv == .boolean)
            final_opts.skipinitialspace = kv.boolean;
    }
    var lines = try collectLines(interp, args[0]);
    defer lines.deinit(a);
    const state = try a.create(ReaderState);
    state.* = .{ .rows = .empty, .pos = 0, .line_num = 0, .opts = final_opts, .allocator = a };
    for (lines.items) |line| {
        const row = try parseCsvLine(a, line, final_opts);
        try state.rows.append(a, row);
    }
    const cls = interp.csv_reader_class orelse return error.TypeError;
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "_rs", Value{ .small_int = @intCast(@intFromPtr(state)) });
    try inst.dict.setStr(a, "line_num", Value{ .small_int = 0 });
    const dial = try makeDialectInst(interp, final_opts);
    try inst.dict.setStr(a, "dialect", dial);
    return Value{ .instance = inst };
}

// ===== Writer object =====

fn writerFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return writerKw(p, args, &.{}, &.{});
}

fn writerKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    if (args.len < 1) return error.TypeError;
    const a = interp.allocator;
    const opts = resolveDialectArg(args, kw_names, kw_values);
    const inst = try Instance.init(a, interp.csv_writer_class.?);
    try inst.dict.setStr(a, "_target", args[0]);
    try inst.dict.setStr(a, "_delim", Value{ .small_int = @as(i64, opts.delimiter) });
    try inst.dict.setStr(a, "_quoting", Value{ .small_int = opts.quoting });
    try inst.dict.setStr(a, "_lineterminator", Value{ .str = try Str.init(a, opts.lineterminator) });
    if (opts.escapechar) |ec| {
        var ec_buf = [1]u8{ec};
        try inst.dict.setStr(a, "_escapechar", Value{ .str = try Str.init(a, &ec_buf) });
    }
    const dial = try makeDialectInst(interp, opts);
    try inst.dict.setStr(a, "dialect", dial);
    return Value{ .instance = inst };
}

fn writerOptsFrom(inst: *Instance) DialectOpts {
    var opts: DialectOpts = .{};
    if (inst.dict.getStr("_delim")) |v| {
        if (v == .small_int) opts.delimiter = @intCast(v.small_int);
    }
    if (inst.dict.getStr("_quoting")) |v| {
        if (v == .small_int) opts.quoting = v.small_int;
    }
    if (inst.dict.getStr("_lineterminator")) |v| {
        if (v == .str) opts.lineterminator = v.str.bytes;
    }
    if (inst.dict.getStr("_escapechar")) |v| {
        if (v == .str and v.str.bytes.len > 0) opts.escapechar = v.str.bytes[0];
    }
    return opts;
}

fn writerWriterow(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const target = inst.dict.getStr("_target").?;
    const opts = writerOptsFrom(inst);
    const items: []const Value = switch (args[1]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    const s = try buildRowStrOpts(a, items, opts);
    defer a.free(s);
    try writeToTarget(interp, target, s);
    return Value{ .small_int = @intCast(s.len) };
}

fn writerWriterows(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const target = inst.dict.getStr("_target").?;
    const opts = writerOptsFrom(inst);
    const rows: []const Value = switch (args[1]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    for (rows) |row| {
        const items: []const Value = switch (row) {
            .list => |l| l.items.items,
            .tuple => |t| t.items,
            else => return error.TypeError,
        };
        const s = try buildRowStrOpts(a, items, opts);
        defer a.free(s);
        try writeToTarget(interp, target, s);
    }
    return Value.none;
}

// ===== DictReader =====

fn dictReaderFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dictReaderKw(p, args, &.{}, &.{});
}

fn dictReaderKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    var lines = try collectLines(interp, args[0]);
    defer lines.deinit(a);

    var fieldnames_val: ?Value = null;
    if (args.len >= 2) fieldnames_val = args[1];
    var restval: Value = Value{ .str = try Str.init(a, "") };
    var restkey: []const u8 = "";
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str) {
            if (std.mem.eql(u8, kn.str.bytes, "fieldnames")) fieldnames_val = kv;
            if (std.mem.eql(u8, kn.str.bytes, "restval")) restval = kv;
            if (std.mem.eql(u8, kn.str.bytes, "restkey") and kv == .str) restkey = kv.str.bytes;
        }
    }

    var idx: usize = 0;
    var headers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer headers.deinit(a);
    if (fieldnames_val) |fv| switch (fv) {
        .list => |l| for (l.items.items) |it| {
            if (it != .str) continue;
            try headers.append(a, it.str.bytes);
        },
        .tuple => |t| for (t.items) |it| {
            if (it != .str) continue;
            try headers.append(a, it.str.bytes);
        },
        else => {},
    } else {
        if (lines.items.len == 0) return Value{ .list = try List.init(a) };
        const head_row = try parseCsvLine(a, lines.items[0], .{});
        for (head_row.items.items) |it| try headers.append(a, it.str.bytes);
        idx = 1;
    }

    // Build fieldnames list for the object
    const fn_list = try List.init(a);
    for (headers.items) |h| try fn_list.append(a, Value{ .str = try Str.init(a, h) });

    const out = try List.init(a);
    while (idx < lines.items.len) : (idx += 1) {
        const row = try parseCsvLine(a, lines.items[idx], .{});
        const d = try Dict.init(a);
        for (headers.items, 0..) |h, i| {
            const val: Value = if (i < row.items.items.len)
                row.items.items[i]
            else
                restval;
            try d.setStr(a, h, val);
        }
        // extra fields go to restkey list
        if (row.items.items.len > headers.items.len and restkey.len > 0) {
            const extras = try List.init(a);
            for (row.items.items[headers.items.len..]) |ev| {
                try extras.append(a, ev);
            }
            try d.setStr(a, restkey, Value{ .list = extras });
        }
        try out.append(a, Value{ .dict = d });
    }

    // Return an object with fieldnames and __iter__/__next__ attributes
    const cls = interp.csv_dict_reader_class orelse return Value{ .list = out };
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "_rows", Value{ .list = out });
    try inst.dict.setStr(a, "_pos", Value{ .small_int = 0 });
    try inst.dict.setStr(a, "fieldnames", Value{ .list = fn_list });
    return Value{ .instance = inst };
}

fn dictReaderIterFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return Value{ .none = {} };
    return args[0];
}

fn dictReaderNextFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .instance) {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    }
    const inst = args[0].instance;
    const rows_v = inst.dict.getStr("_rows") orelse {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    };
    if (rows_v != .list) {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    }
    const pos_v = inst.dict.getStr("_pos") orelse Value{ .small_int = 0 };
    const pos: usize = @intCast(pos_v.small_int);
    const rows = rows_v.list.items.items;
    if (pos >= rows.len) {
        try interp.raisePy("StopIteration", "");
        return error.PyException;
    }
    try inst.dict.setStr(interp.allocator, "_pos", Value{ .small_int = @intCast(pos + 1) });
    return rows[pos];
}

// ===== DictWriter =====

fn dictWriterFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return dictWriterKw(p, args, &.{}, &.{});
}

fn dictWriterKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    try ensureClasses(interp);
    const a = interp.allocator;
    if (args.len < 1) return error.TypeError;
    var fieldnames_val: ?Value = if (args.len >= 2) args[1] else null;
    var extrasaction: []const u8 = "raise";
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str) {
            if (std.mem.eql(u8, kn.str.bytes, "fieldnames")) fieldnames_val = kv;
            if (std.mem.eql(u8, kn.str.bytes, "extrasaction") and kv == .str) extrasaction = kv.str.bytes;
        }
    }
    if (fieldnames_val == null) return error.TypeError;
    const opts = resolveDialectArg(args, kw_names, kw_values);
    const inst = try Instance.init(a, interp.csv_dict_writer_class.?);
    try inst.dict.setStr(a, "_target", args[0]);
    try inst.dict.setStr(a, "fieldnames", fieldnames_val.?);
    try inst.dict.setStr(a, "_delim", Value{ .small_int = @as(i64, opts.delimiter) });
    try inst.dict.setStr(a, "_quoting", Value{ .small_int = opts.quoting });
    try inst.dict.setStr(a, "_lineterminator", Value{ .str = try Str.init(a, opts.lineterminator) });
    try inst.dict.setStr(a, "_extrasaction", Value{ .str = try Str.init(a, extrasaction) });
    return Value{ .instance = inst };
}

fn dictWriterFieldnames(inst: *Instance) []const Value {
    const v = inst.dict.getStr("fieldnames").?;
    return switch (v) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => &.{},
    };
}

fn dictWriterHeader(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const target = inst.dict.getStr("_target").?;
    const fields = dictWriterFieldnames(inst);
    const opts = writerOptsFrom(inst);
    const s = try buildRowStrOpts(a, fields, opts);
    defer a.free(s);
    try writeToTarget(interp, target, s);
    return Value.none;
}

fn dictWriterRow(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const target = inst.dict.getStr("_target").?;
    if (args[1] != .dict) return error.TypeError;
    const row_dict = args[1].dict;
    const fields = dictWriterFieldnames(inst);
    const opts = writerOptsFrom(inst);
    // Check extrasaction
    const ea_v = inst.dict.getStr("_extrasaction");
    const extrasaction: []const u8 = if (ea_v) |v| (if (v == .str) v.str.bytes else "raise") else "raise";
    if (std.mem.eql(u8, extrasaction, "raise")) {
        // Check if any keys in row_dict are not in fields
        // (simple check: count keys in row_dict vs fields)
        const n_fields = fields.len;
        const n_row = row_dict.count();
        if (n_row > n_fields) {
            try interp.raisePy("ValueError", "dict contains fields not in fieldnames");
            return error.PyException;
        }
    }
    var row_buf: std.ArrayListUnmanaged(Value) = .empty;
    defer row_buf.deinit(a);
    for (fields) |fv| {
        const key = if (fv == .str) fv.str.bytes else return error.TypeError;
        const val: Value = row_dict.getStr(key) orelse Value{ .str = try Str.init(a, "") };
        try row_buf.append(a, val);
    }
    const s = try buildRowStrOpts(a, row_buf.items, opts);
    defer a.free(s);
    try writeToTarget(interp, target, s);
    return Value.none;
}

fn dictWriterRows(p: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const rows: []const Value = switch (args[1]) {
        .list => |l| l.items.items,
        .tuple => |t| t.items,
        else => return error.TypeError,
    };
    for (rows) |row| {
        _ = try dictWriterRow(p, &.{ args[0], row });
    }
    return Value.none;
}

// ===== dialect registry functions =====

fn registerDialectFn(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) !Value {
    _ = p;
    if (args.len < 1 or args[0] != .str) return Value{ .none = {} };
    const name = args[0].str.bytes;
    if (name.len >= 64) return Value{ .none = {} };
    var cd: *CustomDialect = blk: {
        if (findCustomDialect(name)) |existing| break :blk existing;
        if (g_custom_dialect_count >= MAX_CUSTOM_DIALECTS) return Value{ .none = {} };
        const idx = g_custom_dialect_count;
        g_custom_dialect_count += 1;
        break :blk &g_custom_dialects[idx];
    };
    cd.name_len = name.len;
    @memcpy(cd.name[0..name.len], name);
    const base: DialectOpts = .{};
    cd.opts = dialectFromKw(base, kw_names, kw_values);
    return Value{ .none = {} };
}

fn registerDialectKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return registerDialectFn(p, args, kn, kv);
}
fn registerDialect(p: *anyopaque, args: []const Value) anyerror!Value {
    return registerDialectFn(p, args, &.{}, &.{});
}

fn unregisterDialectFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return Value{ .none = {} };
    const name = args[0].str.bytes;
    for (g_custom_dialects[0..g_custom_dialect_count], 0..) |cd, i| {
        if (std.mem.eql(u8, cd.name[0..cd.name_len], name)) {
            // Remove by shifting
            var j = i;
            while (j + 1 < g_custom_dialect_count) : (j += 1) {
                g_custom_dialects[j] = g_custom_dialects[j + 1];
            }
            g_custom_dialect_count -= 1;
            return Value{ .none = {} };
        }
    }
    // Not found — raise csv.Error
    const cls = interp.csv_error_class;
    if (cls) |c| {
        const inst = try Instance.init(interp.allocator, c);
        const t = try Tuple.init(interp.allocator, 1);
        t.items[0] = Value{ .str = try Str.init(interp.allocator, "unknown dialect") };
        try inst.dict.setStr(interp.allocator, "args", Value{ .tuple = t });
        interp.current_exc = Value{ .instance = inst };
    } else {
        try interp.raisePy("Error", "unknown dialect");
    }
    return error.PyException;
}

fn listDialectsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    _ = args;
    const a = interp.allocator;
    const out = try List.init(a);
    try out.append(a, Value{ .str = try Str.init(a, "excel") });
    try out.append(a, Value{ .str = try Str.init(a, "excel-tab") });
    try out.append(a, Value{ .str = try Str.init(a, "unix") });
    for (g_custom_dialects[0..g_custom_dialect_count]) |cd| {
        try out.append(a, Value{ .str = try Str.init(a, cd.name[0..cd.name_len]) });
    }
    return Value{ .list = out };
}

fn getDialectFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return Value{ .none = {} };
    const name = args[0].str.bytes;
    if (resolveDialect(name)) |opts| {
        return makeDialectInst(interp, opts);
    }
    try interp.raisePy("csv.Error", "unknown dialect");
    return error.PyException;
}

// ===== field_size_limit =====

fn fieldSizeLimitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len >= 1 and args[0] == .small_int) {
        g_field_size_limit = args[0].small_int;
    }
    return Value{ .small_int = g_field_size_limit };
}

// ===== Error class =====

fn raiseCsvError(interp: *Interp, msg: []const u8) !void {
    const a = interp.allocator;
    const cls = interp.csv_error_class orelse {
        try interp.raisePy("csv.Error", msg);
        return;
    };
    const inst = try Instance.init(a, cls);
    const t = try Tuple.init(a, 1);
    t.items[0] = Value{ .str = try Str.init(a, msg) };
    try inst.dict.setStr(a, "args", Value{ .tuple = t });
    interp.current_exc = Value{ .instance = inst };
}

// ===== Sniffer =====

fn snifferInitFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .none = {} };
}

fn snifferSniffKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    _ = kw_names;
    _ = kw_values;
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[1] != .str) return Value{ .none = {} };
    const sample = args[1].str.bytes;
    // Count delimiters: try ',', '|', '\t', ';'
    const candidates = [_]u8{ ',', '|', '\t', ';' };
    var best: u8 = ',';
    var best_count: usize = 0;
    for (candidates) |c| {
        var count: usize = 0;
        for (sample) |ch| if (ch == c) { count += 1; };
        if (count > best_count) {
            best_count = count;
            best = c;
        }
    }
    var opts: DialectOpts = .{};
    opts.delimiter = best;
    return makeDialectInst(interp, opts);
}

fn snifferSniffFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return snifferSniffKw(p, args, &.{}, &.{});
}

fn isNumericField(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[i] == '-' or s[i] == '+') i += 1;
    var has_digit = false;
    while (i < s.len) : (i += 1) {
        if (std.ascii.isDigit(s[i])) { has_digit = true; continue; }
        if (s[i] == '.') continue;
        return false;
    }
    return has_digit;
}

fn snifferHasHeaderFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[1] != .str) return Value{ .boolean = false };
    const sample = args[1].str.bytes;
    var lines_iter = std.mem.splitScalar(u8, sample, '\n');
    const first_line_raw = lines_iter.next() orelse return Value{ .boolean = false };
    const first_line = stripEol(first_line_raw);
    const second_line_raw = lines_iter.next() orelse return Value{ .boolean = false };
    const second_line = stripEol(second_line_raw);
    // Count numeric fields in each row
    var first_numeric: usize = 0;
    var first_total: usize = 0;
    var f1 = std.mem.splitScalar(u8, first_line, ',');
    while (f1.next()) |field| {
        first_total += 1;
        if (isNumericField(field)) first_numeric += 1;
    }
    var second_numeric: usize = 0;
    var f2 = std.mem.splitScalar(u8, second_line, ',');
    while (f2.next()) |field| {
        if (isNumericField(field)) second_numeric += 1;
    }
    // Has header: first row has fewer numeric fields than second row
    return Value{ .boolean = first_numeric < second_numeric and first_total > 0 };
}

// ===== class setup =====

fn methodReg(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn methodRegKw(a: std.mem.Allocator, dict: *Dict, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try dict.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(interp: *Interp, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: ?BuiltinKwFnPtr) !void {
    const f = try interp.allocator.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(interp.allocator, name, Value{ .builtin_fn = f });
}

fn ensureClasses(interp: *Interp) !void {
    const a = interp.allocator;
    if (interp.csv_dialect_class == null) {
        const d = try Dict.init(a);
        interp.csv_dialect_class = try Class.init(a, "Dialect", &.{}, d);
    }
    if (interp.csv_error_class == null) {
        const d = try Dict.init(a);
        const exc_val = interp.builtins.getStr("Exception");
        if (exc_val != null and exc_val.? == .class) {
            interp.csv_error_class = try Class.init(a, "Error", &.{exc_val.?.class}, d);
        } else {
            interp.csv_error_class = try Class.init(a, "Error", &.{}, d);
        }
    }
    if (interp.csv_reader_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "__iter__", readerIterFn);
        try methodReg(a, d, "__next__", readerNextFn);
        interp.csv_reader_class = try Class.init(a, "reader", &.{}, d);
    }
    if (interp.csv_writer_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "writerow", writerWriterow);
        try methodReg(a, d, "writerows", writerWriterows);
        interp.csv_writer_class = try Class.init(a, "_csv.writer", &.{}, d);
    }
    if (interp.csv_dict_reader_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "__iter__", dictReaderIterFn);
        try methodReg(a, d, "__next__", dictReaderNextFn);
        interp.csv_dict_reader_class = try Class.init(a, "DictReader", &.{}, d);
    }
    if (interp.csv_dict_writer_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "writeheader", dictWriterHeader);
        try methodReg(a, d, "writerow", dictWriterRow);
        try methodReg(a, d, "writerows", dictWriterRows);
        interp.csv_dict_writer_class = try Class.init(a, "DictWriter", &.{}, d);
    }
    if (interp.csv_sniffer_class == null) {
        const d = try Dict.init(a);
        try methodReg(a, d, "__init__", snifferInitFn);
        try methodRegKw(a, d, "sniff", snifferSniffFn, snifferSniffKw);
        try methodReg(a, d, "has_header", snifferHasHeaderFn);
        interp.csv_sniffer_class = try Class.init(a, "Sniffer", &.{}, d);
    }
}

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "csv");
    try ensureClasses(interp);
    try regKw(interp, m, "reader", readerFn, readerKw);
    try regKw(interp, m, "writer", writerFn, writerKw);
    try regKw(interp, m, "DictReader", dictReaderFn, dictReaderKw);
    try regKw(interp, m, "DictWriter", dictWriterFn, dictWriterKw);
    try regKw(interp, m, "register_dialect", registerDialect, registerDialectKw);
    try regKw(interp, m, "unregister_dialect", unregisterDialectFn, null);
    try regKw(interp, m, "list_dialects", listDialectsFn, null);
    try regKw(interp, m, "get_dialect", getDialectFn, null);
    try regKw(interp, m, "field_size_limit", fieldSizeLimitFn, null);
    try m.attrs.setStr(interp.allocator, "QUOTE_MINIMAL", Value{ .small_int = QUOTE_MINIMAL });
    try m.attrs.setStr(interp.allocator, "QUOTE_ALL", Value{ .small_int = QUOTE_ALL });
    try m.attrs.setStr(interp.allocator, "QUOTE_NONNUMERIC", Value{ .small_int = QUOTE_NONNUMERIC });
    try m.attrs.setStr(interp.allocator, "QUOTE_NONE", Value{ .small_int = QUOTE_NONE });
    try m.attrs.setStr(interp.allocator, "QUOTE_STRINGS", Value{ .small_int = QUOTE_STRINGS });
    try m.attrs.setStr(interp.allocator, "QUOTE_NOTNULL", Value{ .small_int = QUOTE_NOTNULL });
    try m.attrs.setStr(interp.allocator, "Error", Value{ .class = interp.csv_error_class.? });
    try m.attrs.setStr(interp.allocator, "Sniffer", Value{ .class = interp.csv_sniffer_class.? });
    _ = raiseCsvError;
    return m;
}
