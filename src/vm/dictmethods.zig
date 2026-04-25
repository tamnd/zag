//! Methods on `dict`. Same name-keyed lookup pattern as
//! `strmethods` / `listmethods`. The fixture only forces `items()`.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;

const Interp = @import("interp.zig").Interp;
const Dict = @import("../object/dict.zig").Dict;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const List = @import("../object/list.zig").List;

/// Materialize a list of `(key, value)` 2-tuples in insertion
/// order. CPython returns a `dict_items` view object, but for the
/// only consumer this fixture has -- `sorted(kw.items())` -- a
/// plain list is indistinguishable.
pub fn itemsImpl(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1 or args[0] != .dict) {
        try interp.typeError("dict.items() takes no arguments");
        return error.TypeError;
    }
    const d = args[0].dict;
    const out = try List.init(interp.allocator);
    var i: usize = 0;
    while (i < d.keys.items.len) : (i += 1) {
        const k = d.keys.items[i];
        const v = d.getStr(k) orelse continue;
        const key_str = try Str.init(interp.allocator, k);
        const pair = try Tuple.init(interp.allocator, 2);
        pair.items[0] = Value{ .str = key_str };
        pair.items[1] = v;
        try out.append(interp.allocator, Value{ .tuple = pair });
    }
    return Value{ .list = out };
}

var items_entry = BuiltinFn{ .name = "items", .func = itemsImpl };

pub fn lookup(name: []const u8) ?*BuiltinFn {
    if (std.mem.eql(u8, name, "items")) return &items_entry;
    return null;
}
