#!/usr/bin/env python3.14
"""Emit src/op/opcode.zig from the current python3.14 opcode module.

Usage:
    python3.14 scripts/gen_opcode.py > src/op/opcode.zig
"""
import opcode

names_by_op: dict[int, str] = {}
for name, val in opcode.opmap.items():
    if val > 255:
        continue
    prior = names_by_op.get(val)
    if prior is None or len(name) < len(prior):
        names_by_op[val] = name

ice = opcode._inline_cache_entries  # dict[name, int] in 3.14

print("// This file is generated from python3.14's `opcode` module.")
print("// Regenerate with `python3.14 scripts/gen_opcode.py > src/op/opcode.zig`.")
print("// Do not edit by hand.")
print()
print("pub const Opcode = enum(u8) {")
for val in sorted(names_by_op.keys()):
    print(f"    {names_by_op[val]} = {val},")
print("    _,")
print("};")
print()
print("/// Inline cache width in 2-byte slots for each opcode. 0 means no")
print("/// cache follows the instruction. Values come from")
print("/// `python3.14 -c 'import opcode; print(opcode._inline_cache_entries)'`.")
print("pub const cache_width = blk: {")
print("    var w = [_]u8{0} ** 256;")
for name, n in sorted(ice.items()):
    if n == 0:
        continue
    if name in opcode.opmap and opcode.opmap[name] <= 255:
        print(f"    w[@intFromEnum(Opcode.{name})] = {n};")
print("    break :blk w;")
print("};")
print()
print("pub fn opcodeName(op: u8) []const u8 {")
print("    return switch (op) {")
for val in sorted(names_by_op.keys()):
    print(f'        {val} => "{names_by_op[val]}",')
print('        else => "<unknown>",')
print("    };")
print("}")
