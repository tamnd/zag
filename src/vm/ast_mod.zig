//! Pinhole `ast` module: literal_eval, parse, walk, get_docstring, node classes.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

// ===== literal_eval =====
// Safely evaluate a string containing a Python literal.

const Parser = struct {
    src: []const u8,
    pos: usize,

    fn init(src: []const u8) Parser {
        return .{ .src = src, .pos = 0 };
    }

    fn skip_ws(p: *Parser) void {
        while (p.pos < p.src.len and (p.src[p.pos] == ' ' or p.src[p.pos] == '\t' or p.src[p.pos] == '\n' or p.src[p.pos] == '\r')) {
            p.pos += 1;
        }
    }

    fn peek(p: *Parser) ?u8 {
        p.skip_ws();
        if (p.pos >= p.src.len) return null;
        return p.src[p.pos];
    }

    fn consume(p: *Parser) void {
        p.pos += 1;
    }

    fn parse_value(p: *Parser, a: std.mem.Allocator) anyerror!Value {
        const c = p.peek() orelse return error.SyntaxError;
        // String
        if (c == '"' or c == '\'') return p.parse_string(a);
        // Number (int or float)
        if (c == '-' or (c >= '0' and c <= '9')) return p.parse_number(a);
        // List
        if (c == '[') return p.parse_list(a);
        // Tuple
        if (c == '(') return p.parse_tuple(a);
        // Dict
        if (c == '{') return p.parse_dict(a);
        // Keywords: True, False, None
        if (p.starts_with("True")) { p.pos += 4; return Value{ .boolean = true }; }
        if (p.starts_with("False")) { p.pos += 5; return Value{ .boolean = false }; }
        if (p.starts_with("None")) { p.pos += 4; return Value.none; }
        return error.ValueError;
    }

    fn starts_with(p: *Parser, s: []const u8) bool {
        p.skip_ws();
        if (p.pos + s.len > p.src.len) return false;
        if (!std.mem.eql(u8, p.src[p.pos..p.pos + s.len], s)) return false;
        // Check that it's not a longer identifier
        const end = p.pos + s.len;
        if (end < p.src.len) {
            const ch = p.src[end];
            if (ch == '_' or (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9')) return false;
        }
        return true;
    }

    fn parse_string(p: *Parser, a: std.mem.Allocator) anyerror!Value {
        p.skip_ws();
        const quote = p.src[p.pos];
        p.pos += 1;
        // Triple quote check
        var triple = false;
        if (p.pos + 1 < p.src.len and p.src[p.pos] == quote and p.src[p.pos + 1] == quote) {
            p.pos += 2;
            triple = true;
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        while (p.pos < p.src.len) {
            const ch = p.src[p.pos];
            if (triple) {
                if (p.pos + 2 < p.src.len and ch == quote and p.src[p.pos+1] == quote and p.src[p.pos+2] == quote) {
                    p.pos += 3;
                    break;
                }
            } else {
                if (ch == quote) { p.pos += 1; break; }
            }
            if (ch == '\\' and p.pos + 1 < p.src.len) {
                p.pos += 1;
                const esc = p.src[p.pos];
                p.pos += 1;
                const unescaped: u8 = switch (esc) {
                    'n' => '\n', 't' => '\t', 'r' => '\r',
                    '\\' => '\\', '\'' => '\'', '"' => '"',
                    else => esc,
                };
                try buf.append(a, unescaped);
            } else {
                try buf.append(a, ch);
                p.pos += 1;
            }
        }
        return Value{ .str = try Str.init(a, buf.items) };
    }

    fn parse_number(p: *Parser, a: std.mem.Allocator) anyerror!Value {
        p.skip_ws();
        const start = p.pos;
        var is_float = false;
        if (p.pos < p.src.len and p.src[p.pos] == '-') p.pos += 1;
        while (p.pos < p.src.len and p.src[p.pos] >= '0' and p.src[p.pos] <= '9') p.pos += 1;
        if (p.pos < p.src.len and p.src[p.pos] == '.') {
            is_float = true;
            p.pos += 1;
            while (p.pos < p.src.len and p.src[p.pos] >= '0' and p.src[p.pos] <= '9') p.pos += 1;
        }
        if (p.pos < p.src.len and (p.src[p.pos] == 'e' or p.src[p.pos] == 'E')) {
            is_float = true;
            p.pos += 1;
            if (p.pos < p.src.len and (p.src[p.pos] == '+' or p.src[p.pos] == '-')) p.pos += 1;
            while (p.pos < p.src.len and p.src[p.pos] >= '0' and p.src[p.pos] <= '9') p.pos += 1;
        }
        const token = p.src[start..p.pos];
        _ = a;
        if (is_float) {
            const f = std.fmt.parseFloat(f64, token) catch return error.ValueError;
            return Value{ .float = f };
        }
        const i = std.fmt.parseInt(i64, token, 10) catch return error.ValueError;
        return Value{ .small_int = i };
    }

    fn parse_list(p: *Parser, a: std.mem.Allocator) anyerror!Value {
        p.skip_ws();
        p.pos += 1; // '['
        const lst = try List.init(a);
        p.skip_ws();
        if (p.pos < p.src.len and p.src[p.pos] == ']') { p.pos += 1; return Value{ .list = lst }; }
        while (true) {
            const v = try p.parse_value(a);
            try lst.items.append(a, v);
            p.skip_ws();
            if (p.pos >= p.src.len) break;
            if (p.src[p.pos] == ']') { p.pos += 1; break; }
            if (p.src[p.pos] == ',') { p.pos += 1; continue; }
            break;
        }
        return Value{ .list = lst };
    }

    fn parse_tuple(p: *Parser, a: std.mem.Allocator) anyerror!Value {
        p.skip_ws();
        p.pos += 1; // '('
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(a);
        p.skip_ws();
        if (p.pos < p.src.len and p.src[p.pos] == ')') {
            p.pos += 1;
            const t = try Tuple.init(a, 0);
            return Value{ .tuple = t };
        }
        while (true) {
            const v = try p.parse_value(a);
            try items.append(a, v);
            p.skip_ws();
            if (p.pos >= p.src.len) break;
            if (p.src[p.pos] == ')') { p.pos += 1; break; }
            if (p.src[p.pos] == ',') {
                p.pos += 1;
                p.skip_ws();
                if (p.pos < p.src.len and p.src[p.pos] == ')') { p.pos += 1; break; }
                continue;
            }
            break;
        }
        const t = try Tuple.init(a, items.items.len);
        @memcpy(t.items, items.items);
        return Value{ .tuple = t };
    }

    fn parse_dict(p: *Parser, a: std.mem.Allocator) anyerror!Value {
        p.skip_ws();
        p.pos += 1; // '{'
        const d = try Dict.init(a);
        p.skip_ws();
        if (p.pos < p.src.len and p.src[p.pos] == '}') { p.pos += 1; return Value{ .dict = d }; }
        while (true) {
            const k = try p.parse_value(a);
            p.skip_ws();
            if (p.pos >= p.src.len or p.src[p.pos] != ':') return error.SyntaxError;
            p.pos += 1;
            const v = try p.parse_value(a);
            if (k == .str) {
                try d.setStr(a, k.str.bytes, v);
            } else {
                try d.pairs.append(a, .{ .key = k, .value = v });
            }
            p.skip_ws();
            if (p.pos >= p.src.len) break;
            if (p.src[p.pos] == '}') { p.pos += 1; break; }
            if (p.src[p.pos] == ',') { p.pos += 1; continue; }
            break;
        }
        return Value{ .dict = d };
    }
};

fn literalEvalFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) {
        try interp.typeError("literal_eval() requires an argument");
        return error.TypeError;
    }
    const src: []const u8 = switch (args[0]) {
        .str => |s| s.bytes,
        else => {
            try interp.typeError("literal_eval() argument must be str");
            return error.TypeError;
        },
    };
    var par = Parser.init(src);
    const result = par.parse_value(a) catch {
        try interp.raisePy("ValueError", "malformed node or string in literal_eval");
        return error.PyException;
    };
    par.skip_ws();
    if (par.pos < par.src.len) {
        try interp.raisePy("ValueError", "malformed node or string in literal_eval");
        return error.PyException;
    }
    return result;
}

// ===== AST node classes =====

fn getAstClass(interp: *Interp, name: []const u8) !*Class {
    const m = interp.ast_module orelse return error.NameError;
    if (m.attrs.getStr(name)) |v| if (v == .class) return v.class;
    const a = interp.allocator;
    const d = try Dict.init(a);
    const cls = try Class.init(a, name, &.{}, d);
    try m.attrs.setStr(a, name, Value{ .class = cls });
    return cls;
}

fn makeAstNode(interp: *Interp, class_name: []const u8) !Value {
    const cls = try getAstClass(interp, class_name);
    const inst = try Instance.init(interp.allocator, cls);
    return Value{ .instance = inst };
}

// ===== parse =====
// Returns a Module AST node with a .body list of statement nodes.
// We do a very simple parse: recognize assignments and function defs.

fn parseFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .str) {
        try interp.typeError("parse() requires a str argument");
        return error.TypeError;
    }
    const src = args[0].str.bytes;

    const mod_node = try makeAstNode(interp, "Module");
    const body_list = try List.init(a);
    try mod_node.instance.dict.setStr(a, "body", Value{ .list = body_list });
    try mod_node.instance.dict.setStr(a, "type_ignores", Value{ .list = try List.init(a) });

    // Simple line-by-line parse
    var lines = std.mem.splitScalar(u8, src, '\n');
    var current_fn: ?Value = null;

    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;

        // Count indent
        const indent = line.len - trimmed.len;
        _ = indent;

        // Function definition
        if (std.mem.startsWith(u8, trimmed, "def ")) {
            const fn_node = try makeAstNode(interp, "FunctionDef");
            const fn_body = try List.init(a);
            try fn_node.instance.dict.setStr(a, "body", Value{ .list = fn_body });
            // Extract function name
            const after_def = trimmed[4..];
            const paren = std.mem.indexOfScalar(u8, after_def, '(') orelse after_def.len;
            const fname = std.mem.trim(u8, after_def[0..paren], " ");
            try fn_node.instance.dict.setStr(a, "name", Value{ .str = try Str.init(a, fname) });
            try body_list.items.append(a, fn_node);
            current_fn = fn_node;
            continue;
        }

        // Assignment: simple `x = ...`
        if (std.mem.indexOf(u8, trimmed, " = ")) |eq| {
            const lhs = std.mem.trim(u8, trimmed[0..eq], " ");
            const assign_node = try makeAstNode(interp, "Assign");
            const targets = try List.init(a);
            const name_node = try makeAstNode(interp, "Name");
            try name_node.instance.dict.setStr(a, "id", Value{ .str = try Str.init(a, lhs) });
            try targets.items.append(a, name_node);
            try assign_node.instance.dict.setStr(a, "targets", Value{ .list = targets });
            const rhs_str = std.mem.trim(u8, trimmed[eq + 3..], " ");
            // Parse RHS as a Constant or BinOp node
            const rhs_node = try parseExprNode(interp, rhs_str);
            try assign_node.instance.dict.setStr(a, "value", rhs_node);

            if (current_fn != null and current_fn.? == .instance) {
                // If we're inside a function and line is indented, add to fn body
                // (We use a simple heuristic: check if line starts with spaces)
                if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
                    const fn_body_v = current_fn.?.instance.dict.getStr("body") orelse Value.none;
                    if (fn_body_v == .list) {
                        try fn_body_v.list.items.append(a, Value{ .instance = assign_node.instance });
                    }
                    continue;
                }
            }
            try body_list.items.append(a, Value{ .instance = assign_node.instance });
            current_fn = null;
            continue;
        }

        // Docstring or expression statement
        if (trimmed.len > 0 and (trimmed[0] == '"' or trimmed[0] == '\'')) {
            const expr_node = try makeAstNode(interp, "Expr");
            var par2 = Parser.init(trimmed);
            const s = par2.parse_string(a) catch Value.none;
            const const_node = try makeAstNode(interp, "Constant");
            try const_node.instance.dict.setStr(a, "value", s);
            try expr_node.instance.dict.setStr(a, "value", const_node);
            // If inside function body
            if (current_fn != null and current_fn.? == .instance) {
                if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
                    const fn_body_v = current_fn.?.instance.dict.getStr("body") orelse Value.none;
                    if (fn_body_v == .list) {
                        try fn_body_v.list.items.append(a, expr_node);
                    }
                    continue;
                }
            }
            try body_list.items.append(a, expr_node);
            continue;
        }

        // pass / other statements
        if (std.mem.startsWith(u8, trimmed, "pass")) {
            const pass_node = try makeAstNode(interp, "Pass");
            if (current_fn != null and current_fn.? == .instance) {
                if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
                    const fn_body_v = current_fn.?.instance.dict.getStr("body") orelse Value.none;
                    if (fn_body_v == .list) {
                        try fn_body_v.list.items.append(a, pass_node);
                    }
                    continue;
                }
            }
            try body_list.items.append(a, pass_node);
            continue;
        }

        // Any other line: add generic Expr node
        const expr_node = try makeAstNode(interp, "Expr");
        try body_list.items.append(a, expr_node);
    }

    return mod_node;
}

fn parseExprNode(interp: *Interp, src: []const u8) !Value {
    // Try to parse as a constant first
    var par = Parser.init(src);
    if (par.parse_value(interp.allocator) catch null) |cv| {
        const const_node = try makeAstNode(interp, "Constant");
        try const_node.instance.dict.setStr(interp.allocator, "value", cv);
        return const_node;
    }
    // Check for binary op (contains +)
    if (std.mem.indexOf(u8, src, " + ")) |plus| {
        const binop = try makeAstNode(interp, "BinOp");
        const lhs_str = std.mem.trim(u8, src[0..plus], " ");
        const rhs_str = std.mem.trim(u8, src[plus + 3..], " ");
        const lhs = try parseExprNode(interp, lhs_str);
        const rhs = try parseExprNode(interp, rhs_str);
        try binop.instance.dict.setStr(interp.allocator, "left", lhs);
        try binop.instance.dict.setStr(interp.allocator, "right", rhs);
        return binop;
    }
    // Name reference
    const name_node = try makeAstNode(interp, "Name");
    try name_node.instance.dict.setStr(interp.allocator, "id", Value{ .str = try Str.init(interp.allocator, src) });
    return name_node;
}

// ===== walk =====
// Yield all nodes in the AST by BFS.

fn walkFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return Value{ .list = try List.init(a) };
    const root = args[0];
    const result = try List.init(a);
    var queue: std.ArrayList(Value) = .empty;
    defer queue.deinit(a);
    try queue.append(a, root);
    while (queue.items.len > 0) {
        const node = queue.orderedRemove(0);
        try result.items.append(a, node);
        if (node == .instance) {
            // Add all instance dict values that are also AST nodes
            for (node.instance.dict.pairs.items) |pair| {
                const v = pair.value;
                if (v == .instance) {
                    try queue.append(a, v);
                } else if (v == .list) {
                    for (v.list.items.items) |item| {
                        if (item == .instance) try queue.append(a, item);
                    }
                }
            }
        }
    }
    return Value{ .list = result };
}

// ===== get_docstring =====

fn getDocstringFn(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const node = args[0].instance;
    // Look for body[0] which should be an Expr node with a Constant string value
    const body_v = node.dict.getStr("body") orelse return Value.none;
    if (body_v != .list or body_v.list.items.items.len == 0) return Value.none;
    const first = body_v.list.items.items[0];
    if (first != .instance) return Value.none;
    const expr_body = first.instance.dict.getStr("value") orelse return Value.none;
    if (expr_body != .instance) return Value.none;
    const const_val = expr_body.instance.dict.getStr("value") orelse return Value.none;
    if (const_val == .str) return const_val;
    return Value.none;
}

fn reg(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "ast");
    interp.ast_module = m;

    try reg(a, m, "literal_eval", literalEvalFn);
    try reg(a, m, "parse", parseFn);
    try reg(a, m, "walk", walkFn);
    try reg(a, m, "get_docstring", getDocstringFn);

    // Pre-create commonly-used node classes
    _ = try getAstClass(interp, "Module");
    _ = try getAstClass(interp, "Assign");
    _ = try getAstClass(interp, "Name");
    _ = try getAstClass(interp, "FunctionDef");
    _ = try getAstClass(interp, "Expr");
    _ = try getAstClass(interp, "Constant");
    _ = try getAstClass(interp, "BinOp");
    _ = try getAstClass(interp, "Pass");

    return m;
}
