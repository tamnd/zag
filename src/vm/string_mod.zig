//! Pinhole `string` module: just the constants the fixture prints.
//! `string.Formatter` / `Template` etc. wait for a fixture.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "string");
    const a = interp.allocator;
    try setStr(a, m, "ascii_lowercase", "abcdefghijklmnopqrstuvwxyz");
    try setStr(a, m, "ascii_uppercase", "ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    try setStr(a, m, "ascii_letters", "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ");
    try setStr(a, m, "digits", "0123456789");
    try setStr(a, m, "hexdigits", "0123456789abcdefABCDEF");
    try setStr(a, m, "octdigits", "01234567");
    try setStr(a, m, "punctuation", "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~");
    try setStr(a, m, "whitespace", " \t\n\r\x0b\x0c");
    // CPython: digits + letters + punctuation + whitespace.
    try setStr(a, m, "printable", "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~ \t\n\r\x0b\x0c");
    return m;
}

fn setStr(a: std.mem.Allocator, m: *Module, name: []const u8, val: []const u8) !void {
    const s = try Str.init(a, val);
    try m.attrs.setStr(a, name, Value{ .str = s });
}
