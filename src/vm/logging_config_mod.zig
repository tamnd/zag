//! Pinhole `logging.config`: dictConfig, fileConfig, listen, stopListening.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");
const logging_mod = @import("logging_mod.zig");

fn regMod(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn regModKw(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: value_mod.BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

// Extract the *Dict from a value that might be a .dict or .instance.
fn asDict(v: Value) ?*Dict {
    return switch (v) {
        .dict => |d| d,
        .instance => |i| i.dict,
        else => null,
    };
}

fn strVal(v: Value) []const u8 {
    return if (v == .str) v.str.bytes else "";
}

fn levelFromValue(v: Value) i64 {
    if (v == .small_int) return v.small_int;
    if (v != .str) return 0;
    const s = v.str.bytes;
    if (std.mem.eql(u8, s, "DEBUG")) return 10;
    if (std.mem.eql(u8, s, "INFO")) return 20;
    if (std.mem.eql(u8, s, "WARNING") or std.mem.eql(u8, s, "WARN")) return 30;
    if (std.mem.eql(u8, s, "ERROR")) return 40;
    if (std.mem.eql(u8, s, "CRITICAL") or std.mem.eql(u8, s, "FATAL")) return 50;
    return 0;
}

fn buildHandler(interp: *Interp, hcfg: *Dict) !?*Instance {
    const a = interp.allocator;
    const class_val = hcfg.getStr("class") orelse return null;
    if (class_val != .str) return null;
    const cls_name = class_val.str.bytes;

    var is_file = false;
    var is_null = false;
    if (std.mem.eql(u8, cls_name, "logging.FileHandler") or
        std.mem.eql(u8, cls_name, "FileHandler"))
    {
        is_file = true;
    } else if (std.mem.eql(u8, cls_name, "logging.NullHandler") or
        std.mem.eql(u8, cls_name, "NullHandler"))
    {
        is_null = true;
    }
    // all unknown → NullHandler
    if (!is_file) is_null = true;

    const cls: *Class = if (is_file)
        interp.logging_file_handler_class orelse return null
    else
        interp.logging_null_handler_class orelse return null;

    const inst = try Instance.init(a, cls);

    if (is_null) {
        try inst.dict.setStr(a, "_null", Value{ .boolean = true });
        try inst.dict.setStr(a, "_level", Value{ .small_int = 0 });
        try inst.dict.setStr(a, "level", Value{ .small_int = 0 });
        try inst.dict.setStr(a, "_formatter", Value.none);
        try inst.dict.setStr(a, "_filters", Value{ .list = try List.init(a) });
        return inst;
    }

    // FileHandler
    const fv = hcfg.getStr("filename") orelse return null;
    if (fv != .str) return null;
    const mode = if (hcfg.getStr("mode")) |mv| strVal(mv) else "a";
    try logging_mod.fileHandlerOpen(interp, inst, fv.str.bytes, mode);

    const level: i64 = if (hcfg.getStr("level")) |lv| levelFromValue(lv) else 0;
    try inst.dict.setStr(a, "_level", Value{ .small_int = level });
    try inst.dict.setStr(a, "level", Value{ .small_int = level });
    try inst.dict.setStr(a, "_formatter", Value.none);
    try inst.dict.setStr(a, "_filters", Value{ .list = try List.init(a) });
    return inst;
}

fn ensureFilterClass(interp: *Interp) !*Class {
    if (interp.logging_filter_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    interp.logging_filter_class = try Class.init(a, "Filter", &.{}, d);
    return interp.logging_filter_class.?;
}

fn dictConfigFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    const cfg_dict = asDict(args[0]) orelse return Value.none;

    // incremental: skip
    if (cfg_dict.getStr("incremental")) |iv| {
        if (iv == .boolean and iv.boolean) return Value.none;
        if (iv == .small_int and iv.small_int != 0) return Value.none;
    }

    // Ensure logging state
    if (interp.logging_state == null) {
        const gs = try a.create(logging_mod.LoggingState);
        gs.* = .{ .a = a };
        interp.logging_state = gs;
    }

    // Collect formatter fmt strings: name -> fmt_str
    var fmt_map = std.StringHashMap([]const u8).init(a);
    defer fmt_map.deinit();
    if (cfg_dict.getStr("formatters")) |fmts_v| {
        if (asDict(fmts_v)) |fd| {
            for (fd.pairs.items) |pr| {
                if (pr.key != .str) continue;
                if (asDict(pr.value)) |fc| {
                    if (fc.getStr("format")) |fv| {
                        if (fv == .str) try fmt_map.put(pr.key.str.bytes, fv.str.bytes);
                    }
                }
            }
        }
    }

    // Collect filter instances: name -> *Instance
    var filter_map = std.StringHashMap(*Instance).init(a);
    defer filter_map.deinit();
    if (cfg_dict.getStr("filters")) |filts_v| {
        if (asDict(filts_v)) |fd| {
            for (fd.pairs.items) |pr| {
                if (pr.key != .str) continue;
                if (asDict(pr.value)) |fc| {
                    const filt_name = if (fc.getStr("name")) |nv| strVal(nv) else "";
                    const fc_cls = try ensureFilterClass(interp);
                    const fi = try Instance.init(a, fc_cls);
                    try fi.dict.setStr(a, "_filter_name", Value{ .str = try Str.init(a, filt_name) });
                    try fi.dict.setStr(a, "name", Value{ .str = try Str.init(a, filt_name) });
                    try filter_map.put(pr.key.str.bytes, fi);
                }
            }
        }
    }

    // Build handler instances: name -> *Instance
    var handler_map = std.StringHashMap(*Instance).init(a);
    defer handler_map.deinit();
    if (cfg_dict.getStr("handlers")) |hdls_v| {
        if (asDict(hdls_v)) |hd| {
            for (hd.pairs.items) |pr| {
                if (pr.key != .str) continue;
                if (asDict(pr.value)) |hc| {
                    const hi = try buildHandler(interp, hc) orelse continue;
                    // Formatter
                    if (hc.getStr("formatter")) |fref| {
                        if (fref == .str) {
                            if (fmt_map.get(fref.str.bytes)) |fs| {
                                const fi = try Instance.init(a, interp.logging_formatter_class.?);
                                try fi.dict.setStr(a, "_fmt", Value{ .str = try Str.init(a, fs) });
                                try hi.dict.setStr(a, "_formatter", Value{ .instance = fi });
                            }
                        }
                    }
                    // Filters list
                    if (hc.getStr("filters")) |fils| {
                        if (fils == .list) {
                            for (fils.list.items.items) |fn_v| {
                                if (fn_v == .str) {
                                    if (filter_map.get(fn_v.str.bytes)) |fi| {
                                        if (hi.dict.getStr("_filters")) |flv| {
                                            if (flv == .list) try flv.list.append(a, Value{ .instance = fi });
                                        }
                                    }
                                }
                            }
                        }
                    }
                    try handler_map.put(pr.key.str.bytes, hi);
                }
            }
        }
    }

    // Configure named loggers
    if (cfg_dict.getStr("loggers")) |logs_v| {
        if (asDict(logs_v)) |ld| {
            for (ld.pairs.items) |pr| {
                if (pr.key != .str) continue;
                if (asDict(pr.value)) |lc| {
                    try applyLoggerConfig(interp, pr.key.str.bytes, lc, &handler_map);
                }
            }
        }
    }

    // Configure root
    if (cfg_dict.getStr("root")) |root_v| {
        if (asDict(root_v)) |rc| {
            try applyLoggerConfig(interp, "root", rc, &handler_map);
        }
    }

    return Value.none;
}

fn applyLoggerConfig(
    interp: *Interp,
    logger_name: []const u8,
    lcfg: *Dict,
    hmap: *std.StringHashMap(*Instance),
) !void {
    const a = interp.allocator;
    const gs = interp.logging_state.?;
    const ls = try gs.getOrCreate(logger_name);

    if (lcfg.getStr("level")) |lv| ls.level = levelFromValue(lv);

    if (lcfg.getStr("propagate")) |pv| {
        ls.propagate = switch (pv) {
            .boolean => |b| b,
            .small_int => |i| i != 0,
            else => true,
        };
    }

    if (lcfg.getStr("handlers")) |hvl| {
        if (hvl == .list) {
            // Reset handlers
            ls.handlers.clearRetainingCapacity();
            for (hvl.list.items.items) |hname| {
                if (hname == .str) {
                    if (hmap.get(hname.str.bytes)) |hi| {
                        try ls.handlers.append(a, hi);
                    }
                }
            }
        }
    }

    // Update cached instance if it exists
    if (gs.instances.get(ls.name)) |inst| {
        try inst.dict.setStr(a, "level", Value{ .small_int = ls.level });
        try inst.dict.setStr(a, "propagate", Value{ .boolean = ls.propagate });
        if (inst.dict.getStr("handlers")) |hlist| {
            if (hlist == .list) {
                hlist.list.items.clearRetainingCapacity();
                for (ls.handlers.items) |hi| {
                    try hlist.list.append(a, Value{ .instance = hi });
                }
            }
        }
    }
}

fn fileConfigFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) return Value.none;
    const filename = args[0].str.bytes;

    if (interp.logging_state == null) {
        const gs = try a.create(logging_mod.LoggingState);
        gs.* = .{ .a = a };
        interp.logging_state = gs;
    }
    const gs = interp.logging_state.?;

    // Read file
    var file = std.Io.Dir.cwd().openFile(interp.io, filename, .{}) catch return Value.none;
    defer file.close(interp.io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(interp.io, &buf);
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(a);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const got = reader.interface.readSliceShort(chunk[0..]) catch break;
        if (got == 0) break;
        try content.appendSlice(a, chunk[0..got]);
    }

    // Parse INI into sections
    var sections = std.StringHashMap(std.StringHashMap([]const u8)).init(a);
    defer {
        var sit = sections.iterator();
        while (sit.next()) |se| se.value_ptr.deinit();
        sections.deinit();
    }

    var current: ?[]u8 = null;
    var lines = std.mem.splitScalar(u8, content.items, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            current = try a.dupe(u8, line[1..end]);
            if (!sections.contains(current.?)) {
                try sections.put(current.?, std.StringHashMap([]const u8).init(a));
            }
        } else if (current != null) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = std.mem.trim(u8, line[0..eq], " \t");
            const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (sections.getPtr(current.?)) |sp| try sp.put(k, v);
        }
    }

    // Apply root logger
    if (sections.get("logger_root")) |rs| {
        const ls = try gs.getOrCreate("root");
        if (rs.get("level")) |lv| ls.level = levelFromStr(lv);
        // Update cached root if it exists
        if (gs.instances.get("root")) |inst| {
            try inst.dict.setStr(a, "level", Value{ .small_int = ls.level });
        }
    }

    // Apply named loggers
    if (sections.get("loggers")) |lg_sec| {
        if (lg_sec.get("keys")) |keys| {
            var kit = std.mem.splitScalar(u8, keys, ',');
            while (kit.next()) |raw_key| {
                const key = std.mem.trim(u8, raw_key, " \t");
                if (std.mem.eql(u8, key, "root")) continue;
                const sec_name = try std.fmt.allocPrint(a, "logger_{s}", .{key});
                defer a.free(sec_name);
                if (sections.get(sec_name)) |lsec| {
                    const qualname = lsec.get("qualname") orelse key;
                    const ls = try gs.getOrCreate(qualname);
                    if (lsec.get("level")) |lv| ls.level = levelFromStr(lv);
                    // Handlers
                    if (lsec.get("handlers")) |hstr| {
                        var hit = std.mem.splitScalar(u8, hstr, ',');
                        while (hit.next()) |rh| {
                            const hname = std.mem.trim(u8, rh, " \t");
                            if (hname.len == 0) continue;
                            const hsec = try std.fmt.allocPrint(a, "handler_{s}", .{hname});
                            defer a.free(hsec);
                            if (sections.get(hsec)) |hc| {
                                _ = hc; // NullHandler attachment
                                const nh = try Instance.init(a, interp.logging_null_handler_class.?);
                                try nh.dict.setStr(a, "_null", Value{ .boolean = true });
                                try nh.dict.setStr(a, "_level", Value{ .small_int = 0 });
                                try nh.dict.setStr(a, "_formatter", Value.none);
                                try nh.dict.setStr(a, "_filters", Value{ .list = try List.init(a) });
                                try ls.handlers.append(a, nh);
                            }
                        }
                    }
                    if (lsec.get("propagate")) |pv| {
                        ls.propagate = !std.mem.eql(u8, pv, "0");
                    }
                    if (gs.instances.get(ls.name)) |inst| {
                        try inst.dict.setStr(a, "level", Value{ .small_int = ls.level });
                        try inst.dict.setStr(a, "propagate", Value{ .boolean = ls.propagate });
                        if (inst.dict.getStr("handlers")) |hlist| {
                            if (hlist == .list) {
                                for (ls.handlers.items) |hi| {
                                    try hlist.list.append(a, Value{ .instance = hi });
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return Value.none;
}

fn levelFromStr(s: []const u8) i64 {
    if (std.mem.eql(u8, s, "DEBUG")) return 10;
    if (std.mem.eql(u8, s, "INFO")) return 20;
    if (std.mem.eql(u8, s, "WARNING") or std.mem.eql(u8, s, "WARN")) return 30;
    if (std.mem.eql(u8, s, "ERROR")) return 40;
    if (std.mem.eql(u8, s, "CRITICAL") or std.mem.eql(u8, s, "FATAL")) return 50;
    return 0;
}

fn fileConfigKw(
    p: *anyopaque,
    args: []const Value,
    _: []const Value,
    _: []const Value,
) anyerror!Value {
    return fileConfigFn(p, args);
}

fn listenFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const d = try Dict.init(a);
    const cls = try Class.init(a, "_ListenThread", &.{}, d);
    const inst = try Instance.init(a, cls);
    return Value{ .instance = inst };
}

fn stopListeningFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value.none;
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "logging.config");
    try regMod(a, m, "dictConfig", dictConfigFn);
    try regModKw(a, m, "fileConfig", fileConfigFn, fileConfigKw);
    try regMod(a, m, "listen", listenFn);
    try regMod(a, m, "stopListening", stopListeningFn);
    return m;
}
