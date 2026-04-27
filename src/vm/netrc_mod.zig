const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Dict = @import("../object/dict.zig").Dict;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;
const Tuple = @import("../object/tuple.zig").Tuple;

// ===== Tokenizer with pending token =====

const Lexer = struct {
    input: []const u8,
    pos: usize,
    lineno: u32,
    pending: ?[]const u8,

    fn init(input: []const u8) Lexer {
        return .{ .input = input, .pos = 0, .lineno = 1, .pending = null };
    }

    fn skipWS(self: *Lexer) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\r') { self.pos += 1; continue; }
            if (c == '\n') { self.pos += 1; self.lineno += 1; continue; }
            if (c == '#') {
                while (self.pos < self.input.len and self.input[self.pos] != '\n') self.pos += 1;
                continue;
            }
            break;
        }
    }

    fn next(self: *Lexer, a: Allocator) !?[]const u8 {
        if (self.pending) |tok| { self.pending = null; return tok; }
        self.skipWS();
        if (self.pos >= self.input.len) return null;
        if (self.input[self.pos] == '"') {
            self.pos += 1;
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            while (self.pos < self.input.len and self.input[self.pos] != '"') {
                const c = self.input[self.pos];
                if (c == '\n') self.lineno += 1;
                try buf.append(a, c);
                self.pos += 1;
            }
            if (self.pos < self.input.len) self.pos += 1;
            return @as(?[]const u8, try buf.toOwnedSlice(a));
        }
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '#') break;
            if (c == '\n') {
                // Don't include \n in token but consume it and bump lineno
                // (matches shlex: lineno increments when \n terminates a token).
                const end = self.pos;
                self.pos += 1;
                self.lineno += 1;
                return @as(?[]const u8, try a.dupe(u8, self.input[start..end]));
            }
            self.pos += 1;
        }
        return @as(?[]const u8, try a.dupe(u8, self.input[start..self.pos]));
    }

    fn putBack(self: *Lexer, tok: []const u8) void {
        self.pending = tok;
    }

    fn skipNewline(self: *Lexer) void {
        if (self.pos < self.input.len and self.input[self.pos] == '\n') {
            self.pos += 1;
            self.lineno += 1;
        }
    }
};

fn raiseNetrcError(interp: *Interp, msg: []const u8, filename: []const u8, lineno: u32) !void {
    const a = interp.allocator;
    const cls = interp.netrc_error_class orelse {
        try interp.raisePy("Exception", msg);
        return;
    };
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "msg", Value{ .str = try Str.init(a, msg) });
    try inst.dict.setStr(a, "filename", Value{ .str = try Str.init(a, filename) });
    try inst.dict.setStr(a, "lineno", Value{ .small_int = lineno });
    const t = try Tuple.init(a, 1);
    t.items[0] = Value{ .str = try Str.init(a, msg) };
    try inst.dict.setStr(a, "args", Value{ .tuple = t });
    interp.current_exc = Value{ .instance = inst };
}

const TOPLEVEL_KEYWORDS = [_][]const u8{ "machine", "default", "macdef" };

fn isToplevel(tok: []const u8) bool {
    for (TOPLEVEL_KEYWORDS) |kw| if (std.mem.eql(u8, tok, kw)) return true;
    return false;
}

fn parseNetrc(interp: *Interp, inst: *Instance, content: []const u8, path: []const u8) !void {
    const a = interp.allocator;
    var lex = Lexer.init(content);

    const hosts_d = try Dict.init(a);
    const macros_d = try Dict.init(a);

    while (true) {
        const tok = try lex.next(a) orelse break;
        const ln = lex.lineno;

        if (std.mem.eql(u8, tok, "machine") or std.mem.eql(u8, tok, "default")) {
            const is_default = std.mem.eql(u8, tok, "default");
            const host_name: []const u8 = if (!is_default) blk: {
                break :blk try lex.next(a) orelse {
                    try raiseNetrcError(interp, "end of file after machine keyword", path, lex.lineno);
                    return error.PyException;
                };
            } else "default";

            var login: []const u8 = "";
            var account: []const u8 = "";
            var password: []const u8 = "";

            while (true) {
                const key = try lex.next(a) orelse break;
                if (isToplevel(key)) { lex.putBack(key); break; }
                if (std.mem.eql(u8, key, "login") or std.mem.eql(u8, key, "user")) {
                    login = try lex.next(a) orelse "";
                } else if (std.mem.eql(u8, key, "account")) {
                    account = try lex.next(a) orelse "";
                } else if (std.mem.eql(u8, key, "password")) {
                    password = try lex.next(a) orelse "";
                } else {
                    var errmsg_buf: [128]u8 = undefined;
                    const errmsg = try std.fmt.bufPrint(&errmsg_buf, "bad follower token '{s}'", .{key});
                    try raiseNetrcError(interp, try a.dupe(u8, errmsg), path, lex.lineno);
                    return error.PyException;
                }
            }

            const t = try Tuple.init(a, 3);
            t.items[0] = Value{ .str = try Str.init(a, login) };
            t.items[1] = Value{ .str = try Str.init(a, account) };
            t.items[2] = Value{ .str = try Str.init(a, password) };
            try hosts_d.setStr(a, host_name, Value{ .tuple = t });
        } else if (std.mem.eql(u8, tok, "macdef")) {
            const pre_ln = lex.lineno;
            const macro_name = try lex.next(a) orelse {
                try raiseNetrcError(interp, "end of file after macdef keyword", path, lex.lineno);
                return error.PyException;
            };
            // Skip rest of line only if next() didn't already consume the \n
            if (lex.lineno == pre_ln) {
                while (lex.pos < lex.input.len and lex.input[lex.pos] != '\n') lex.pos += 1;
                lex.skipNewline();
            }
            var lines: std.ArrayListUnmanaged([]const u8) = .empty;
            while (true) {
                if (lex.pos >= lex.input.len) break;
                var scan = lex.pos;
                while (scan < lex.input.len and (lex.input[scan] == ' ' or lex.input[scan] == '\t' or lex.input[scan] == '\r'))
                    scan += 1;
                if (scan >= lex.input.len or lex.input[scan] == '\n') {
                    if (scan < lex.input.len) { lex.pos = scan + 1; lex.lineno += 1; }
                    else lex.pos = scan;
                    break;
                }
                const line_start = lex.pos;
                while (lex.pos < lex.input.len and lex.input[lex.pos] != '\n') lex.pos += 1;
                const line = lex.input[line_start..lex.pos];
                var line_buf: std.ArrayListUnmanaged(u8) = .empty;
                try line_buf.appendSlice(a, line);
                try line_buf.append(a, '\n');
                try lines.append(a, try line_buf.toOwnedSlice(a));
                if (lex.pos < lex.input.len) { lex.pos += 1; lex.lineno += 1; }
            }
            const macro_list = try List.init(a);
            for (lines.items) |line| try macro_list.items.append(a, Value{ .str = try Str.init(a, line) });
            try macros_d.setStr(a, macro_name, Value{ .list = macro_list });
        } else {
            var errmsg_buf: [128]u8 = undefined;
            const errmsg = try std.fmt.bufPrint(&errmsg_buf, "bad toplevel token '{s}'", .{tok});
            try raiseNetrcError(interp, try a.dupe(u8, errmsg), path, ln);
            return error.PyException;
        }
    }

    try inst.dict.setStr(a, "hosts", Value{ .dict = hosts_d });
    try inst.dict.setStr(a, "macros", Value{ .dict = macros_d });
}

fn readFile(interp: *Interp, path: []const u8) ![]u8 {
    const a = interp.allocator;
    var file = std.Io.Dir.cwd().openFile(interp.io, path, .{}) catch return error.FileNotFound;
    defer file.close(interp.io);
    var data: std.ArrayListUnmanaged(u8) = .empty;
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(interp.io, &read_buf);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const got = reader.interface.readSliceShort(chunk[0..]) catch break;
        if (got == 0) break;
        try data.appendSlice(a, chunk[0..got]);
    }
    return data.toOwnedSlice(a);
}

fn netrcInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) {
        try interp.raisePy("TypeError", "netrc() requires a path argument");
        return error.PyException;
    }
    const path = args[1].str.bytes;
    const content = readFile(interp, path) catch |err| {
        const msg = try std.fmt.allocPrint(a, "could not open {s}: {}", .{ path, err });
        try interp.raisePy("IOError", msg);
        return error.PyException;
    };
    try parseNetrc(interp, args[0].instance, content, path);
    return Value.none;
}

fn netrcAuthenticators(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return Value.none;
    const self = args[0].instance;
    const host = args[1].str.bytes;
    const hosts_v = self.dict.getStr("hosts") orelse return Value.none;
    if (hosts_v != .dict) return Value.none;
    const hosts = hosts_v.dict;
    if (hosts.getStr(host)) |entry| return entry;
    if (hosts.getStr("default")) |entry| return entry;
    return Value.none;
}

fn netrcRepr(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value{ .str = try Str.init(a, "netrc()") };
    const self = args[0].instance;
    const hosts_v = self.dict.getStr("hosts") orelse return Value{ .str = try Str.init(a, "netrc()") };
    if (hosts_v != .dict) return Value{ .str = try Str.init(a, "netrc()") };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (hosts_v.dict.pairs.items) |pair| {
        const key = if (pair.key == .str) pair.key.str.bytes else continue;
        if (std.mem.eql(u8, key, "default")) {
            try buf.appendSlice(a, "default");
        } else {
            try buf.appendSlice(a, "machine ");
            try buf.appendSlice(a, key);
        }
        const t = pair.value;
        if (t == .tuple and t.tuple.items.len >= 3) {
            const login = if (t.tuple.items[0] == .str) t.tuple.items[0].str.bytes else "";
            const account = if (t.tuple.items[1] == .str) t.tuple.items[1].str.bytes else "";
            const password = if (t.tuple.items[2] == .str) t.tuple.items[2].str.bytes else "";
            try buf.appendSlice(a, " login ");
            try buf.appendSlice(a, login);
            if (account.len > 0) { try buf.appendSlice(a, " account "); try buf.appendSlice(a, account); }
            try buf.appendSlice(a, " password ");
            try buf.appendSlice(a, password);
        }
        try buf.append(a, '\n');
    }
    return Value{ .str = try Str.init(a, try buf.toOwnedSlice(a)) };
}

fn reg(a: Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "netrc");

    if (interp.netrc_error_class == null) {
        const ed = try Dict.init(a);
        if (interp.builtins.getStr("Exception")) |exc_val| {
            interp.netrc_error_class = try Class.init(a, "NetrcParseError", &.{exc_val.class}, ed);
        } else {
            interp.netrc_error_class = try Class.init(a, "NetrcParseError", &.{}, ed);
        }
    }

    if (interp.netrc_class == null) {
        const cd = try Dict.init(a);
        try reg(a, cd, "__init__", netrcInit);
        try reg(a, cd, "authenticators", netrcAuthenticators);
        try reg(a, cd, "__repr__", netrcRepr);
        interp.netrc_class = try Class.init(a, "netrc", &.{}, cd);
    }

    try m.attrs.setStr(a, "NetrcParseError", Value{ .class = interp.netrc_error_class.? });
    try m.attrs.setStr(a, "netrc", Value{ .class = interp.netrc_class.? });
    return m;
}
