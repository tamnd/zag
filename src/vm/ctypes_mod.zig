//! Pinhole `ctypes` module.
//! Implements simple types, Structure, Union, CDLL, POINTER, etc.

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
const Bytes = @import("../object/bytes.zig").Bytes;
const Class = @import("../object/class.zig").Class;
const Instance = @import("../object/instance.zig").Instance;
const Interp = @import("interp.zig").Interp;

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

// ===== Simple type descriptors =====

const SimpleTypeDesc = struct {
    name: []const u8,
    size: i64,
    default: Value,
};

const SIMPLE_TYPES = &[_]SimpleTypeDesc{
    .{ .name = "c_int",        .size = 4,  .default = Value{ .small_int = 0 } },
    .{ .name = "c_double",     .size = 8,  .default = Value{ .float = 0.0 } },
    .{ .name = "c_bool",       .size = 1,  .default = Value{ .boolean = false } },
    .{ .name = "c_char",       .size = 1,  .default = Value{ .small_int = 0 } },
    .{ .name = "c_byte",       .size = 1,  .default = Value{ .small_int = 0 } },
    .{ .name = "c_ubyte",      .size = 1,  .default = Value{ .small_int = 0 } },
    .{ .name = "c_short",      .size = 2,  .default = Value{ .small_int = 0 } },
    .{ .name = "c_ushort",     .size = 2,  .default = Value{ .small_int = 0 } },
    .{ .name = "c_long",       .size = 8,  .default = Value{ .small_int = 0 } },
    .{ .name = "c_ulong",      .size = 8,  .default = Value{ .small_int = 0 } },
    .{ .name = "c_float",      .size = 4,  .default = Value{ .float = 0.0 } },
    .{ .name = "c_longlong",   .size = 8,  .default = Value{ .small_int = 0 } },
    .{ .name = "c_ulonglong",  .size = 8,  .default = Value{ .small_int = 0 } },
    .{ .name = "c_longdouble", .size = 16, .default = Value{ .float = 0.0 } },
    .{ .name = "c_size_t",     .size = 8,  .default = Value{ .small_int = 0 } },
    .{ .name = "c_ssize_t",    .size = 8,  .default = Value{ .small_int = 0 } },
    .{ .name = "c_char_p",     .size = 8,  .default = Value.none },
    .{ .name = "c_wchar_p",    .size = 8,  .default = Value.none },
    .{ .name = "c_void_p",     .size = 8,  .default = Value.none },
    .{ .name = "c_wchar",      .size = 4,  .default = Value{ .small_int = 0 } },
};

// ===== Global ctypes state =====

const CtypesState = struct {
    simple_classes: [SIMPLE_TYPES.len]?*Class,
    structure_class: ?*Class,
    union_class: ?*Class,
    cdll_class: ?*Class,
    errno_val: i64,

    fn init() CtypesState {
        var st: CtypesState = undefined;
        for (&st.simple_classes) |*p| p.* = null;
        st.structure_class = null;
        st.union_class = null;
        st.cdll_class = null;
        st.errno_val = 0;
        return st;
    }
};

var gstate: CtypesState = CtypesState.init();

// ===== Simple type __init__ =====

fn simpleTypeInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    // find default from class _sizeof and _default
    const def = inst.cls.dict.getStr("_default") orelse Value.none;
    var val: Value = if (args.len >= 2) args[1] else def;
    // for c_char, if given int, keep as int; if given bytes, keep
    const cls_name = inst.cls.name;
    if (std.mem.eql(u8, cls_name, "c_char")) {
        if (val == .none) val = Value{ .small_int = 0 };
    }
    try inst.dict.setStr(a, "value", val);
    return Value.none;
}

// ===== Structure/Union __init__ =====

fn structInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    // look up _fields_ via MRO so subclasses can define it
    const fields_v = inst.cls.lookup("_fields_") orelse return Value.none;
    if (fields_v != .list) return Value.none;
    const fields = fields_v.list.items.items;
    var pos_idx: usize = 1; // args[0] is self
    for (fields, 0..) |fv, fi| {
        _ = fi;
        // each field is a tuple (name, ctype) or (name, ctype, bits)
        var field_name: []const u8 = "";
        var field_type: Value = Value.none;
        switch (fv) {
            .tuple => |t| {
                if (t.items.len >= 1 and t.items[0] == .str) field_name = t.items[0].str.bytes;
                if (t.items.len >= 2) field_type = t.items[1];
            },
            .list => |l| {
                if (l.items.items.len >= 1 and l.items.items[0] == .str) field_name = l.items.items[0].str.bytes;
                if (l.items.items.len >= 2) field_type = l.items.items[1];
            },
            else => continue,
        }
        var field_val: Value = Value.none;
        // get default from type
        if (field_type == .class) {
            field_val = field_type.class.dict.getStr("_default") orelse Value.none;
        }
        // override with positional arg
        if (pos_idx < args.len) {
            field_val = args[pos_idx];
            pos_idx += 1;
        }
        if (field_name.len > 0) {
            try inst.dict.setStr(a, field_name, field_val);
        }
    }
    return Value.none;
}

// compute sizeof for Structure (sum) vs Union (max)
fn computeSizeofFromFields(fields_v: Value, is_union: bool) i64 {
    if (fields_v != .list) return 0;
    var total: i64 = 0;
    for (fields_v.list.items.items) |fv| {
        var field_type: Value = Value.none;
        switch (fv) {
            .tuple => |t| { if (t.items.len >= 2) field_type = t.items[1]; },
            .list => |l| { if (l.items.items.len >= 2) field_type = l.items.items[1]; },
            else => continue,
        }
        var fsize: i64 = 0;
        if (field_type == .class) {
            fsize = if (field_type.class.dict.getStr("_sizeof")) |sv|
                (if (sv == .small_int) sv.small_int else 0)
            else 0;
        }
        if (is_union) {
            if (fsize > total) total = fsize;
        } else {
            total += fsize;
        }
    }
    return total;
}

fn getOrCreateSimpleClass(interp: *Interp, idx: usize) !*Class {
    if (gstate.simple_classes[idx]) |c| return c;
    const a = interp.allocator;
    const desc = SIMPLE_TYPES[idx];
    const d = try Dict.init(a);
    try reg(a, d, "__init__", simpleTypeInit);
    try d.setStr(a, "_sizeof", Value{ .small_int = desc.size });
    try d.setStr(a, "_default", desc.default);
    // __name__ attribute
    try d.setStr(a, "__name__", Value{ .str = try Str.init(a, desc.name) });
    const cls = try Class.init(a, desc.name, &.{}, d);
    gstate.simple_classes[idx] = cls;
    return cls;
}

// ===== Structure class =====

fn getOrCreateStructureClass(interp: *Interp) !*Class {
    if (gstate.structure_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try reg(a, d, "__init__", structInit);
    try d.setStr(a, "_sizeof", Value{ .small_int = 0 });
    const cls = try Class.init(a, "Structure", &.{}, d);
    gstate.structure_class = cls;
    return cls;
}

fn getOrCreateUnionClass(interp: *Interp) !*Class {
    if (gstate.union_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try reg(a, d, "__init__", structInit);
    try d.setStr(a, "_sizeof", Value{ .small_int = 0 });
    const cls = try Class.init(a, "Union", &.{}, d);
    gstate.union_class = cls;
    return cls;
}

// ===== sizeof =====

fn isUnionBase(cls: *Class) bool {
    if (std.mem.eql(u8, cls.name, "Union")) return true;
    for (cls.bases) |b| {
        if (std.mem.eql(u8, b.name, "Union")) return true;
    }
    return false;
}

fn sizeofFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return Value{ .small_int = 0 };
    const arg = args[0];
    switch (arg) {
        .class => |cls| {
            // Check _fields_ in own dict first (Structure/Union subclasses)
            if (cls.dict.getStr("_fields_")) |fv| {
                const is_union = isUnionBase(cls);
                return Value{ .small_int = computeSizeofFromFields(fv, is_union) };
            }
            // Fall back to _sizeof from MRO (simple types like c_int)
            if (cls.lookup("_sizeof")) |sv| {
                if (sv == .small_int) return sv;
            }
            return Value{ .small_int = 0 };
        },
        .instance => |inst| {
            // Check _fields_ in class's own dict first
            if (inst.cls.dict.getStr("_fields_")) |fv| {
                const is_union = isUnionBase(inst.cls);
                return Value{ .small_int = computeSizeofFromFields(fv, is_union) };
            }
            if (inst.cls.lookup("_sizeof")) |sv| {
                if (sv == .small_int) return sv;
            }
            return Value{ .small_int = 0 };
        },
        else => return Value{ .small_int = 0 },
    }
}

// ===== create_string_buffer =====

fn createStringBufferFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return Value.none;

    // We create a simple instance with .value and .__len__
    const buf_cls_d = try Dict.init(a);
    try reg(a, buf_cls_d, "__len__", bufLen);
    const buf_cls = try Class.init(a, "create_string_buffer", &.{}, buf_cls_d);
    const inst = try Instance.init(a, buf_cls);

    switch (args[0]) {
        .small_int => |n| {
            try inst.dict.setStr(a, "value", Value{ .bytes = try Bytes.init(a, "") });
            try inst.dict.setStr(a, "_len", Value{ .small_int = n });
        },
        .bytes => |b| {
            try inst.dict.setStr(a, "value", Value{ .bytes = try Bytes.init(a, b.data) });
            try inst.dict.setStr(a, "_len", Value{ .small_int = @intCast(b.data.len) });
        },
        .str => |s| {
            try inst.dict.setStr(a, "value", Value{ .str = s });
            try inst.dict.setStr(a, "_len", Value{ .small_int = @intCast(s.bytes.len) });
        },
        else => {
            try inst.dict.setStr(a, "value", Value{ .bytes = try Bytes.init(a, "") });
            try inst.dict.setStr(a, "_len", Value{ .small_int = 0 });
        },
    }
    return Value{ .instance = inst };
}

fn createUnicodeBufferFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    const n: i64 = if (args[0] == .small_int) args[0].small_int else 0;
    const buf_cls_d = try Dict.init(a);
    try reg(a, buf_cls_d, "__len__", bufLen);
    const buf_cls = try Class.init(a, "create_unicode_buffer", &.{}, buf_cls_d);
    const inst = try Instance.init(a, buf_cls);
    try inst.dict.setStr(a, "value", Value{ .str = try Str.init(a, "") });
    try inst.dict.setStr(a, "_len", Value{ .small_int = n });
    return Value{ .instance = inst };
}

fn bufLen(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .instance) return Value{ .small_int = 0 };
    const v = args[0].instance.dict.getStr("_len") orelse return Value{ .small_int = 0 };
    return v;
}

// ===== CDLL =====

fn cdllInitFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return cdllInitImpl(p, args, &.{}, &.{});
}

fn cdllInitKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return cdllInitImpl(p, args, kn, kv);
}

fn cdllInitImpl(p: *anyopaque, args: []const Value, _kn: []const Value, _kv: []const Value) anyerror!Value {
    _ = _kn;
    _ = _kv;
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const path = if (args.len >= 2 and args[1] == .str) args[1].str.bytes else "";
    try args[0].instance.dict.setStr(a, "_path", Value{ .str = try Str.init(a, path) });
    return Value.none;
}

fn getOrCreateCDLLClass(interp: *Interp) !*Class {
    if (gstate.cdll_class) |c| return c;
    const a = interp.allocator;
    const d = try Dict.init(a);
    try regKw(a, d, "__init__", cdllInitFn, cdllInitKw);
    const cls = try Class.init(a, "CDLL", &.{}, d);
    gstate.cdll_class = cls;
    return cls;
}

fn cdllFn(p: *anyopaque, args: []const Value) anyerror!Value {
    return cdllKwImpl(p, args, &.{}, &.{});
}

fn cdllKw(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    return cdllKwImpl(p, args, kn, kv);
}

fn cdllKwImpl(p: *anyopaque, args: []const Value, kn: []const Value, kv: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    const cls = try getOrCreateCDLLClass(interp);
    const inst = try Instance.init(a, cls);
    const inst_v = Value{ .instance = inst };
    var all_args = try a.alloc(Value, args.len + 1);
    defer a.free(all_args);
    all_args[0] = inst_v;
    @memcpy(all_args[1..], args);
    _ = try cdllInitImpl(p, all_args, kn, kv);
    return inst_v;
}

// ===== POINTER =====

fn pointerFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    const ctype = args[0];
    // create a new class named LP_<ctype.__name__>
    var base_name: []const u8 = "unknown";
    if (ctype == .class) base_name = ctype.class.name;
    const name = try std.fmt.allocPrint(a, "LP_{s}", .{base_name});
    defer a.free(name);
    const d = try Dict.init(a);
    try reg(a, d, "__init__", ptrTypeInit);
    const cls = try Class.init(a, try a.dupe(u8, name), &.{}, d);
    try cls.dict.setStr(a, "__name__", Value{ .str = try Str.init(a, cls.name) });
    return Value{ .class = cls };
}

fn ptrTypeInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const contents = if (args.len >= 2) args[1] else Value.none;
    try args[0].instance.dict.setStr(a, "contents", contents);
    return Value.none;
}

// ===== pointer(inst) =====

fn pointerInstFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    const inst_val = args[0];
    // create a generic pointer instance
    const d = try Dict.init(a);
    const cls = try Class.init(a, "pointer_inst", &.{}, d);
    const ptr_inst = try Instance.init(a, cls);
    try ptr_inst.dict.setStr(a, "contents", inst_val);
    return Value{ .instance = ptr_inst };
}

// ===== byref =====

fn byrefFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    // return a wrapper instance
    const d = try Dict.init(a);
    const cls = try Class.init(a, "byref", &.{}, d);
    const inst = try Instance.init(a, cls);
    try inst.dict.setStr(a, "_obj", args[0]);
    return Value{ .instance = inst };
}

// ===== addressof =====

fn addressofFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1) return Value{ .small_int = 1 };
    // return a fake non-zero address
    return Value{ .small_int = @intCast(@intFromPtr(&args[0])) };
}

// ===== cast =====

fn castFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const src = args[0];
    const dst_type = args[1];
    if (dst_type != .class) return src;
    const inst = try Instance.init(a, dst_type.class);
    // copy value if available
    const val = switch (src) {
        .instance => |si| si.dict.getStr("value") orelse Value.none,
        else => src,
    };
    try inst.dict.setStr(a, "value", val);
    return Value{ .instance = inst };
}

// ===== get_errno / set_errno =====

fn getErrnoFn(_: *anyopaque, _: []const Value) anyerror!Value {
    return Value{ .small_int = gstate.errno_val };
}

fn setErrnoFn(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len >= 1 and args[0] == .small_int) gstate.errno_val = args[0].small_int;
    return Value.none;
}

// ===== string_at =====

fn stringAtFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(p));
    return Value{ .bytes = try Bytes.init(interp.allocator, "") };
}

// ===== Build simple type constructor (module-level callable) =====

fn makeSimpleTypeCtor(interp: *Interp, idx: usize) !Value {
    const a = interp.allocator;
    const cls = try getOrCreateSimpleClass(interp, idx);
    // return the class itself (calling class creates instance via dispatch)
    _ = a;
    return Value{ .class = cls };
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "ctypes");

    gstate = CtypesState.init();

    // simple types
    for (SIMPLE_TYPES, 0..) |desc, i| {
        const v = try makeSimpleTypeCtor(interp, i);
        try m.attrs.setStr(a, desc.name, v);
    }

    // Structure and Union
    const struct_cls = try getOrCreateStructureClass(interp);
    try m.attrs.setStr(a, "Structure", Value{ .class = struct_cls });
    const union_cls = try getOrCreateUnionClass(interp);
    try m.attrs.setStr(a, "Union", Value{ .class = union_cls });

    // CDLL
    try m.attrs.setStr(a, "CDLL", blk: {
        const cls = try getOrCreateCDLLClass(interp);
        break :blk Value{ .class = cls };
    });

    // module functions
    try regM(a, m, "sizeof", sizeofFn);
    try regM(a, m, "create_string_buffer", createStringBufferFn);
    try regM(a, m, "create_unicode_buffer", createUnicodeBufferFn);
    try regM(a, m, "POINTER", pointerFn);
    try regM(a, m, "pointer", pointerInstFn);
    try regM(a, m, "byref", byrefFn);
    try regM(a, m, "addressof", addressofFn);
    try regM(a, m, "cast", castFn);
    try regM(a, m, "get_errno", getErrnoFn);
    try regM(a, m, "set_errno", setErrnoFn);
    try regM(a, m, "string_at", stringAtFn);

    // constants
    try m.attrs.setStr(a, "RTLD_LOCAL", Value{ .small_int = 0 });
    try m.attrs.setStr(a, "RTLD_GLOBAL", Value{ .small_int = 256 });


    return m;
}
