//! Pinhole `xml.etree.ElementTree`: Element, SubElement, tostring, fromstring.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const BuiltinKwFnPtr = value_mod.BuiltinKwFnPtr;
const Module = @import("../object/module.zig").Module;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

fn methodReg(a: std.mem.Allocator, d: *Dict, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try d.setStr(a, name, Value{ .builtin_fn = f });
}

fn reg(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn regKw(a: std.mem.Allocator, m: *Module, name: []const u8, func: BuiltinFnPtr, kw: BuiltinKwFnPtr) !void {
    const f = try a.create(BuiltinFn);
    f.* = .{ .name = name, .func = func, .kw_func = kw };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = f });
}

fn ensureElementClass(interp: *Interp) !*Class {
    if (interp.xml_element_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try methodReg(a, d, "get", elemGet);
    try methodReg(a, d, "set", elemSet);
    try methodReg(a, d, "find", elemFind);
    try methodReg(a, d, "findall", elemFindall);
    try methodReg(a, d, "findtext", elemFindtext);
    try methodReg(a, d, "append", elemAppend);
    try methodReg(a, d, "remove", elemRemove);
    try methodReg(a, d, "iter", elemIterAll);
    try methodReg(a, d, "__len__", elemLen);
    try methodReg(a, d, "__iter__", elemIterSelf);
    try methodReg(a, d, "__getitem__", elemGetitem);
    const cls = try Class.init(a, "Element", &.{}, d);
    interp.xml_element_class = cls;
    return cls;
}

fn newElement(interp: *Interp, tag: []const u8, attrib: ?Value) !Value {
    const a = interp.allocator;
    _ = try ensureElementClass(interp);
    const cls = interp.xml_element_class.?;
    const inst = try Instance.init(a, cls);
    const tag_s = try Str.init(a, tag);
    try inst.dict.setStr(a, "tag", Value{ .str = tag_s });
    try inst.dict.setStr(a, "text", Value.none);
    try inst.dict.setStr(a, "tail", Value.none);
    const d = try Dict.init(a);
    if (attrib) |av| switch (av) {
        .dict => |src| for (src.pairs.items) |p| {
            if (p.key == .str) try d.setStr(a, p.key.str.bytes, p.value);
        },
        else => {},
    };
    try inst.dict.setStr(a, "attrib", Value{ .dict = d });
    const children = try List.init(a);
    try inst.dict.setStr(a, "_children", Value{ .list = children });
    return Value{ .instance = inst };
}

fn elementFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return elementKw(p, args, &.{}, &.{});
}

fn elementKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    const tag = args[0].str.bytes;
    var attrib: ?Value = if (args.len >= 2) args[1] else null;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "attrib")) attrib = kv;
    }
    return newElement(interp, tag, attrib);
}

fn subElementFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return subElementKw(p, args, &.{}, &.{});
}

fn subElementKw(p: *anyopaque, args: []const Value, kw_names: []const Value, kw_values: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const parent = args[0].instance;
    const tag = args[1].str.bytes;
    var attrib: ?Value = if (args.len >= 3) args[2] else null;
    for (kw_names, kw_values) |kn, kv| {
        if (kn == .str and std.mem.eql(u8, kn.str.bytes, "attrib")) attrib = kv;
    }
    const child = try newElement(interp, tag, attrib);
    const children_v = parent.dict.getStr("_children").?;
    try children_v.list.append(interp.allocator, child);
    return child;
}

fn elemGet(p: *anyopaque, args: []const Value) anyerror!Value {
    _ = p;
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const key = if (args[1] == .str) args[1].str.bytes else return Value.none;
    const attrib_v = inst.dict.getStr("attrib") orelse return Value.none;
    if (attrib_v != .dict) return Value.none;
    return attrib_v.dict.getStr(key) orelse (if (args.len >= 3) args[2] else Value.none);
}

fn elemSet(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 3 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const inst = args[0].instance;
    const key = args[1].str.bytes;
    const val = args[2];
    const attrib_v = inst.dict.getStr("attrib") orelse return Value.none;
    if (attrib_v != .dict) return Value.none;
    try attrib_v.dict.setStr(interp.allocator, key, val);
    return Value.none;
}

fn elemFind(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return Value.none;
    const inst = args[0].instance;
    const tag = args[1].str.bytes;
    const children_v = inst.dict.getStr("_children") orelse return Value.none;
    if (children_v != .list) return Value.none;
    for (children_v.list.items.items) |child| {
        if (child != .instance) continue;
        const child_tag = child.instance.dict.getStr("tag") orelse continue;
        if (child_tag == .str and std.mem.eql(u8, child_tag.str.bytes, tag)) return child;
    }
    return Value.none;
}

fn elemFindall(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return error.TypeError;
    const inst = args[0].instance;
    const tag = args[1].str.bytes;
    const out = try List.init(a);
    const children_v = inst.dict.getStr("_children") orelse return Value{ .list = out };
    if (children_v != .list) return Value{ .list = out };
    for (children_v.list.items.items) |child| {
        if (child != .instance) continue;
        const child_tag = child.instance.dict.getStr("tag") orelse continue;
        if (child_tag == .str and std.mem.eql(u8, child_tag.str.bytes, tag)) {
            try out.append(a, child);
        }
    }
    return Value{ .list = out };
}

fn elemFindtext(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2 or args[0] != .instance or args[1] != .str) return Value.none;
    const inst = args[0].instance;
    const tag = args[1].str.bytes;
    const children_v = inst.dict.getStr("_children") orelse return Value.none;
    if (children_v != .list) return Value.none;
    for (children_v.list.items.items) |child| {
        if (child != .instance) continue;
        const child_tag = child.instance.dict.getStr("tag") orelse continue;
        if (child_tag == .str and std.mem.eql(u8, child_tag.str.bytes, tag)) {
            return child.instance.dict.getStr("text") orelse Value.none;
        }
    }
    return Value.none;
}

fn elemAppend(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const child = args[1];
    const children_v = inst.dict.getStr("_children") orelse return Value.none;
    if (children_v != .list) return Value.none;
    try children_v.list.append(interp.allocator, child);
    return Value.none;
}

fn elemRemove(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const target = args[1];
    const children_v = inst.dict.getStr("_children") orelse return Value.none;
    if (children_v != .list) return Value.none;
    const items = &children_v.list.items;
    var i: usize = 0;
    while (i < items.items.len) {
        if (items.items[i].equals(target)) {
            _ = items.orderedRemove(i);
            return Value.none;
        }
        i += 1;
    }
    return Value.none;
}

fn elemLen(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const children_v = inst.dict.getStr("_children") orelse return Value{ .small_int = 0 };
    if (children_v != .list) return Value{ .small_int = 0 };
    return Value{ .small_int = @intCast(children_v.list.items.items.len) };
}

fn elemIterSelf(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const children_v = inst.dict.getStr("_children") orelse return Value.none;
    return children_v;
}

fn elemGetitem(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 2 or args[0] != .instance) return error.TypeError;
    const inst = args[0].instance;
    const idx: i64 = switch (args[1]) { .small_int => |i| i, else => return error.TypeError };
    const children_v = inst.dict.getStr("_children") orelse {
        try interp.raisePy("IndexError", "index out of range");
        return error.PyException;
    };
    if (children_v != .list) {
        try interp.raisePy("IndexError", "index out of range");
        return error.PyException;
    }
    const items = children_v.list.items.items;
    if (idx < 0 or idx >= @as(i64, @intCast(items.len))) {
        try interp.raisePy("IndexError", "index out of range");
        return error.PyException;
    }
    return items[@intCast(idx)];
}

fn elemIterAll(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    const out = try List.init(a);
    var queue: std.ArrayListUnmanaged(Value) = .empty;
    defer queue.deinit(a);
    try queue.append(a, args[0]);
    while (queue.items.len > 0) {
        const elem = queue.orderedRemove(0);
        try out.append(a, elem);
        if (elem == .instance) {
            const cv = elem.instance.dict.getStr("_children") orelse continue;
            if (cv == .list) for (cv.list.items.items) |c| try queue.append(a, c);
        }
    }
    return Value{ .list = out };
}

fn toStringFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return toStringKw(p, args, &.{}, &.{});
}

fn toStringKw(p: *anyopaque, args: []const Value, _: []const Value, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return error.TypeError;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    try writeElement(a, &buf, args[0].instance);
    return Value{ .str = try Str.init(a, buf.items) };
}

fn writeElement(a: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), inst: *Instance) !void {
    const tag_v = inst.dict.getStr("tag") orelse return;
    if (tag_v != .str) return;
    const tag = tag_v.str.bytes;
    try buf.append(a, '<');
    try buf.appendSlice(a, tag);
    const attrib_v = inst.dict.getStr("attrib");
    if (attrib_v) |av| if (av == .dict) {
        for (av.dict.pairs.items) |p| {
            try buf.append(a, ' ');
            if (p.key == .str) try buf.appendSlice(a, p.key.str.bytes);
            try buf.appendSlice(a, "=\"");
            if (p.value == .str) try xmlEscape(a, buf, p.value.str.bytes);
            try buf.append(a, '"');
        }
    };
    const children_v = inst.dict.getStr("_children");
    const has_children = children_v != null and children_v.? == .list and children_v.?.list.items.items.len > 0;
    const text_v = inst.dict.getStr("text");
    const has_text = text_v != null and text_v.? == .str and text_v.?.str.bytes.len > 0;
    if (!has_children and !has_text) {
        try buf.appendSlice(a, " />");
    } else {
        try buf.append(a, '>');
        if (has_text) try xmlEscape(a, buf, text_v.?.str.bytes);
        if (has_children) for (children_v.?.list.items.items) |child| {
            if (child == .instance) try writeElement(a, buf, child.instance);
        };
        try buf.appendSlice(a, "</");
        try buf.appendSlice(a, tag);
        try buf.append(a, '>');
    }
    const tail_v = inst.dict.getStr("tail");
    if (tail_v) |tv| if (tv == .str and tv.str.bytes.len > 0) try xmlEscape(a, buf, tv.str.bytes);
}

fn xmlEscape(a: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try buf.appendSlice(a, "&lt;"),
        '>' => try buf.appendSlice(a, "&gt;"),
        '&' => try buf.appendSlice(a, "&amp;"),
        '"' => try buf.appendSlice(a, "&quot;"),
        else => try buf.append(a, c),
    };
}

const ParseState = struct {
    s: []const u8,
    pos: usize = 0,
    interp: *Interp,

    fn peek(self: *ParseState) ?u8 {
        if (self.pos < self.s.len) return self.s[self.pos];
        return null;
    }

    fn skipWs(self: *ParseState) void {
        while (self.pos < self.s.len and isWs(self.s[self.pos])) self.pos += 1;
    }

    fn expect(self: *ParseState, c: u8) bool {
        if (self.pos < self.s.len and self.s[self.pos] == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn readName(self: *ParseState) []const u8 {
        const start = self.pos;
        while (self.pos < self.s.len and isNameChar(self.s[self.pos])) self.pos += 1;
        return self.s[start..self.pos];
    }

    fn readAttrValue(self: *ParseState) []const u8 {
        const q = self.s[self.pos];
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.s.len and self.s[self.pos] != q) self.pos += 1;
        const val = self.s[start..self.pos];
        if (self.pos < self.s.len) self.pos += 1;
        return val;
    }
};

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == ':';
}

fn parseElement(ps: *ParseState) anyerror!Value {
    const interp = ps.interp;
    const a = interp.allocator;
    ps.skipWs();
    if (!ps.expect('<')) return error.ParseError;
    // Skip comments and PIs
    if (ps.pos < ps.s.len and ps.s[ps.pos] == '!') {
        while (ps.pos < ps.s.len and ps.s[ps.pos] != '>') ps.pos += 1;
        _ = ps.expect('>');
        return parseElement(ps);
    }
    if (ps.pos < ps.s.len and ps.s[ps.pos] == '?') {
        while (ps.pos < ps.s.len and ps.s[ps.pos] != '>') ps.pos += 1;
        _ = ps.expect('>');
        return parseElement(ps);
    }
    const tag = ps.readName();
    if (tag.len == 0) return error.ParseError;
    const attrib_dict = try Dict.init(a);
    while (true) {
        ps.skipWs();
        const c = ps.peek() orelse break;
        if (c == '>' or c == '/') break;
        const attr_name = ps.readName();
        if (attr_name.len == 0) break;
        ps.skipWs();
        if (!ps.expect('=')) break;
        ps.skipWs();
        const attr_val = ps.readAttrValue();
        const val_s = try Str.init(a, attr_val);
        try attrib_dict.setStr(a, attr_name, Value{ .str = val_s });
    }
    const elem = try newElement(interp, tag, Value{ .dict = attrib_dict });
    const elem_inst = elem.instance;
    if (ps.pos < ps.s.len and ps.s[ps.pos] == '/') {
        ps.pos += 1;
        _ = ps.expect('>');
        return elem;
    }
    _ = ps.expect('>');
    var text_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer text_buf.deinit(a);
    while (ps.pos < ps.s.len) {
        if (ps.s[ps.pos] == '<') {
            if (ps.pos + 1 < ps.s.len and ps.s[ps.pos + 1] == '/') {
                ps.pos += 2;
                while (ps.pos < ps.s.len and ps.s[ps.pos] != '>') ps.pos += 1;
                _ = ps.expect('>');
                break;
            } else {
                if (text_buf.items.len > 0) {
                    const text_s = try Str.init(a, text_buf.items);
                    try elem_inst.dict.setStr(a, "text", Value{ .str = text_s });
                    text_buf.clearRetainingCapacity();
                }
                const child = try parseElement(ps);
                const children_v = elem_inst.dict.getStr("_children").?;
                try children_v.list.append(a, child);
            }
        } else {
            try text_buf.append(a, ps.s[ps.pos]);
            ps.pos += 1;
        }
    }
    if (text_buf.items.len > 0) {
        const text_s = try Str.init(a, text_buf.items);
        try elem_inst.dict.setStr(a, "text", Value{ .str = text_s });
    }
    return elem;
}

fn fromStringFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    if (args.len < 1 or args[0] != .str) return error.TypeError;
    var ps = ParseState{ .s = args[0].str.bytes, .interp = interp };
    return parseElement(&ps);
}

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "xml.etree.ElementTree");
    interp.xml_etree_module = m;
    _ = try ensureElementClass(interp);

    try regKw(a, m, "Element", elementFn, elementKw);
    try regKw(a, m, "SubElement", subElementFn, subElementKw);
    try regKw(a, m, "tostring", toStringFn, toStringKw);
    try reg(a, m, "fromstring", fromStringFn);
    try reg(a, m, "fromString", fromStringFn);

    const etree_fn = try a.create(BuiltinFn);
    etree_fn.* = .{ .name = "ElementTree", .func = elementFn };
    try m.attrs.setStr(a, "ElementTree", Value{ .builtin_fn = etree_fn });

    return m;
}

pub fn buildEtreePackage(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "xml.etree");
    m.is_package = true;
    const et_mod = interp.xml_etree_module orelse try build(interp);
    try m.attrs.setStr(a, "ElementTree", Value{ .module = et_mod });
    return m;
}

pub fn buildXmlPackage(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "xml");
    m.is_package = true;
    const etree_mod = try buildEtreePackage(interp);
    try m.attrs.setStr(a, "etree", Value{ .module = etree_mod });
    return m;
}
