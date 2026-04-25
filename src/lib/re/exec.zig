//! Backtracking VM that executes a `Program` against an input slice.
//! Single live thread, explicit stack for alternatives.

const std = @import("std");
const program = @import("program.zig");

const Inst = program.Inst;
const Op = program.Op;
const Program = program.Program;

pub const NPOS: usize = std.math.maxInt(usize);

pub const Span = struct { start: usize, end: usize };

pub const Match = struct {
    spans: []Span,

    pub fn deinit(self: *Match, a: std.mem.Allocator) void {
        a.free(self.spans);
    }
};

pub fn match(a: std.mem.Allocator, prog: *const Program, input: []const u8) !?Match {
    return try run(a, prog, input, 0, .anchored);
}

pub fn fullmatch(a: std.mem.Allocator, prog: *const Program, input: []const u8) !?Match {
    return try run(a, prog, input, 0, .full);
}

pub fn search(a: std.mem.Allocator, prog: *const Program, input: []const u8, start: usize) !?Match {
    var i: usize = start;
    while (i <= input.len) : (i += 1) {
        if (try run(a, prog, input, i, .unanchored)) |m| return m;
    }
    return null;
}

const Mode = enum { anchored, unanchored, full };

const Thread = struct {
    pc: u32,
    sp: u32,
    saves: []usize,
};

fn run(a: std.mem.Allocator, prog: *const Program, input: []const u8, sp0: usize, mode: Mode) !?Match {
    const slot_count = 2 * (prog.group_count + 1);
    var stack: std.ArrayList(Thread) = .empty;
    defer {
        for (stack.items) |t| a.free(t.saves);
        stack.deinit(a);
    }

    const saves0 = try a.alloc(usize, slot_count);
    for (saves0) |*s| s.* = NPOS;

    var cur_pc: u32 = 0;
    var cur_sp: u32 = @intCast(sp0);
    var saves = saves0;

    while (true) {
        const pc = cur_pc;
        const sp = cur_sp;
        if (pc >= prog.code.len) {
            // dead
            if (try popThread(a, &stack, &cur_pc, &cur_sp, &saves)) continue;
            a.free(saves);
            return null;
        }
        const inst = prog.code[pc];
        switch (inst.op) {
            .char => {
                if (sp < input.len and input[sp] == @as(u8, @intCast(inst.a))) {
                    cur_pc = pc + 1;
                    cur_sp = sp + 1;
                } else if (try popThread(a, &stack, &cur_pc, &cur_sp, &saves)) {} else {
                    a.free(saves);
                    return null;
                }
            },
            .char_ci => {
                if (sp < input.len and asciiLower(input[sp]) == @as(u8, @intCast(inst.a))) {
                    cur_pc = pc + 1;
                    cur_sp = sp + 1;
                } else if (try popThread(a, &stack, &cur_pc, &cur_sp, &saves)) {} else {
                    a.free(saves);
                    return null;
                }
            },
            .any => {
                const dotall = prog.flags.dotall;
                if (sp < input.len and (dotall or input[sp] != '\n')) {
                    cur_pc = pc + 1;
                    cur_sp = sp + 1;
                } else if (try popThread(a, &stack, &cur_pc, &cur_sp, &saves)) {} else {
                    a.free(saves);
                    return null;
                }
            },
            .class => {
                const set = prog.classes[inst.a];
                if (sp < input.len and program.classContains(set, input[sp])) {
                    cur_pc = pc + 1;
                    cur_sp = sp + 1;
                } else if (try popThread(a, &stack, &cur_pc, &cur_sp, &saves)) {} else {
                    a.free(saves);
                    return null;
                }
            },
            .bol => {
                const ok = if (prog.flags.multiline)
                    (sp == 0 or input[sp - 1] == '\n')
                else
                    sp == 0;
                if (ok) {
                    cur_pc = pc + 1;
                } else if (try popThread(a, &stack, &cur_pc, &cur_sp, &saves)) {} else {
                    a.free(saves);
                    return null;
                }
            },
            .eol => {
                const ok = if (prog.flags.multiline)
                    (sp == input.len or input[sp] == '\n')
                else
                    sp == input.len;
                if (ok) {
                    cur_pc = pc + 1;
                } else if (try popThread(a, &stack, &cur_pc, &cur_sp, &saves)) {} else {
                    a.free(saves);
                    return null;
                }
            },
            .backref => {
                const gid = inst.a;
                const s_idx = 2 * gid;
                const e_idx = 2 * gid + 1;
                if (s_idx >= saves.len or saves[s_idx] == NPOS or saves[e_idx] == NPOS) {
                    if (try popThread(a, &stack, &cur_pc, &cur_sp, &saves)) continue;
                    a.free(saves);
                    return null;
                }
                const gs = saves[s_idx];
                const ge = saves[e_idx];
                const len = ge - gs;
                if (sp + len > input.len) {
                    if (try popThread(a, &stack, &cur_pc, &cur_sp, &saves)) continue;
                    a.free(saves);
                    return null;
                }
                var matched = true;
                if (prog.flags.ignore_case) {
                    var i: usize = 0;
                    while (i < len) : (i += 1) {
                        if (asciiLower(input[gs + i]) != asciiLower(input[sp + i])) {
                            matched = false;
                            break;
                        }
                    }
                } else {
                    matched = std.mem.eql(u8, input[gs..ge], input[sp .. sp + len]);
                }
                if (matched) {
                    cur_pc = pc + 1;
                    cur_sp = @intCast(sp + len);
                } else if (try popThread(a, &stack, &cur_pc, &cur_sp, &saves)) {} else {
                    a.free(saves);
                    return null;
                }
            },
            .save => {
                const slot = inst.a;
                if (slot < saves.len) saves[slot] = sp;
                cur_pc = pc + 1;
            },
            .jump => {
                cur_pc = inst.a;
            },
            .split => {
                // try a first; push b for backtrack.
                try pushThread(a, &stack, inst.b, sp, saves);
                cur_pc = inst.a;
            },
            .split_lazy => {
                // try b first; push a for backtrack.
                try pushThread(a, &stack, inst.a, sp, saves);
                cur_pc = inst.b;
            },
            .match => {
                if (mode == .full and sp != input.len) {
                    if (try popThread(a, &stack, &cur_pc, &cur_sp, &saves)) continue;
                    a.free(saves);
                    return null;
                }
                // Build the match. saves[0..1] is the whole match span.
                const spans = try a.alloc(Span, prog.group_count + 1);
                var g: u32 = 0;
                while (g <= prog.group_count) : (g += 1) {
                    const s = saves[2 * g];
                    const e = saves[2 * g + 1];
                    spans[g] = .{ .start = s, .end = e };
                }
                a.free(saves);
                return Match{ .spans = spans };
            },
        }
    }
}

fn pushThread(a: std.mem.Allocator, stack: *std.ArrayList(Thread), pc: u32, sp: u32, saves: []const usize) !void {
    const copy = try a.alloc(usize, saves.len);
    @memcpy(copy, saves);
    try stack.append(a, .{ .pc = pc, .sp = sp, .saves = copy });
}

fn popThread(a: std.mem.Allocator, stack: *std.ArrayList(Thread), cur_pc: *u32, cur_sp: *u32, saves: *[]usize) !bool {
    if (stack.items.len == 0) return false;
    const t = stack.pop().?;
    a.free(saves.*);
    cur_pc.* = t.pc;
    cur_sp.* = t.sp;
    saves.* = t.saves;
    return true;
}

fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
