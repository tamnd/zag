//! AST -> bytecode. Single linear walk, patching split/jump operands
//! after we know the body's pc.

const std = @import("std");
const ast = @import("ast.zig");
const program = @import("program.zig");
const parse = @import("parse.zig");

const Node = ast.Node;
const Op = program.Op;
const Inst = program.Inst;
const Program = program.Program;
const Flags = program.Flags;

pub fn compile(a: std.mem.Allocator, pattern: []const u8, flags: Flags) parse.Error!*Program {
    var parsed = try parse.parse(a, pattern, flags);
    defer parsed.deinit(a);

    var ctx = Ctx{
        .a = a,
        .code = .empty,
        .classes = .empty,
        .flags = flags,
    };
    errdefer {
        ctx.code.deinit(a);
        ctx.classes.deinit(a);
    }

    try ctx.emit(.{ .op = .save, .a = 0 });
    try ctx.compileNode(parsed.root);
    try ctx.emit(.{ .op = .save, .a = 1 });
    try ctx.emit(.{ .op = .match });

    const out = try a.create(Program);
    errdefer a.destroy(out);

    // Detach group_names from parsed; transfer ownership to the program.
    const names = parsed.group_names;
    parsed.group_names = &.{};

    out.* = .{
        .code = try ctx.code.toOwnedSlice(a),
        .classes = try ctx.classes.toOwnedSlice(a),
        .group_names = names,
        .group_count = parsed.group_count,
        .flags = flags,
    };
    return out;
}

const Ctx = struct {
    a: std.mem.Allocator,
    code: std.ArrayList(Inst),
    classes: std.ArrayList([4]u64),
    flags: Flags,

    fn here(self: *Ctx) u32 {
        return @intCast(self.code.items.len);
    }

    fn emit(self: *Ctx, inst: Inst) !void {
        try self.code.append(self.a, inst);
    }

    fn compileNode(self: *Ctx, node: *const Node) parse.Error!void {
        switch (node.*) {
            .literal => |c| {
                if (self.flags.ignore_case and isAlpha(c)) {
                    try self.emit(.{ .op = .char_ci, .a = lower(c) });
                } else {
                    try self.emit(.{ .op = .char, .a = c });
                }
            },
            .any => try self.emit(.{ .op = .any }),
            .bol => try self.emit(.{ .op = .bol }),
            .eol => try self.emit(.{ .op = .eol }),
            .wb => try self.emit(.{ .op = .wb }),
            .nwb => try self.emit(.{ .op = .nwb }),
            .class => |cls| {
                const id: u32 = @intCast(self.classes.items.len);
                try self.classes.append(self.a, cls.set);
                try self.emit(.{ .op = .class, .a = id });
            },
            .backref => |id| try self.emit(.{ .op = .backref, .a = id }),
            .concat => |xs| {
                for (xs) |*c| try self.compileNode(c);
            },
            .alt => |xs| try self.compileAlt(xs),
            .group => |g| {
                if (g.id == 0) {
                    try self.compileNode(g.inner);
                } else {
                    try self.emit(.{ .op = .save, .a = g.id * 2 });
                    try self.compileNode(g.inner);
                    try self.emit(.{ .op = .save, .a = g.id * 2 + 1 });
                }
            },
            .repeat => |r| try self.compileRepeat(r),
        }
    }

    fn compileAlt(self: *Ctx, branches: []const Node) parse.Error!void {
        const n = branches.len;
        if (n == 0) return;
        if (n == 1) {
            try self.compileNode(&branches[0]);
            return;
        }
        // For n branches we emit n-1 splits. Each split picks branch[i]
        // (a) or the next split / final branch (b). After each non-last
        // branch emit a `jump END`. Patch all unresolved operands at
        // the end.
        var split_pcs: std.ArrayList(u32) = .empty;
        defer split_pcs.deinit(self.a);
        var jump_pcs: std.ArrayList(u32) = .empty;
        defer jump_pcs.deinit(self.a);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const last = i == n - 1;
            if (!last) {
                try split_pcs.append(self.a, self.here());
                try self.emit(.{ .op = .split, .a = 0, .b = 0 });
            }
            const body_start = self.here();
            if (!last) self.code.items[split_pcs.items[split_pcs.items.len - 1]].a = body_start;
            try self.compileNode(&branches[i]);
            if (!last) {
                try jump_pcs.append(self.a, self.here());
                try self.emit(.{ .op = .jump, .a = 0 });
            }
        }
        const end_pc = self.here();

        // split[i].b = pc where the fail-over begins for branch i.
        // For i < n-2 that's split_pcs[i+1]; for i == n-2 it's the body
        // start of the last branch, which sits right after the jump
        // that follows split_pcs[n-2]. We can recover that as
        // jump_pcs[n-2] + 1.
        for (split_pcs.items, 0..) |spc, idx| {
            const fail_over: u32 = if (idx + 1 < split_pcs.items.len)
                split_pcs.items[idx + 1]
            else
                jump_pcs.items[idx] + 1;
            self.code.items[spc].b = fail_over;
        }
        for (jump_pcs.items) |jpc| self.code.items[jpc].a = end_pc;
    }

    fn compileRepeat(self: *Ctx, r: ast.Repeat) parse.Error!void {
        // Required copies (min).
        var i: u32 = 0;
        while (i < r.min) : (i += 1) try self.compileNode(r.inner);

        if (r.max == null) {
            // Open-ended: split L_body, L_end ; <inner> ; jump L_split ; L_end
            const split_pc = self.here();
            const op: Op = if (r.lazy) .split_lazy else .split;
            try self.emit(.{ .op = op, .a = 0, .b = 0 });
            const body_start = self.here();
            try self.compileNode(r.inner);
            try self.emit(.{ .op = .jump, .a = split_pc });
            const end_pc = self.here();
            self.code.items[split_pc].a = body_start;
            self.code.items[split_pc].b = end_pc;
        } else {
            const max = r.max.?;
            if (max < r.min) return error.BadPattern;
            // Each optional copy: split L_body, L_end ; <inner> ; L_end
            const optional = max - r.min;
            var split_pcs: std.ArrayList(u32) = .empty;
            defer split_pcs.deinit(self.a);
            var k: u32 = 0;
            while (k < optional) : (k += 1) {
                const split_pc = self.here();
                const op: Op = if (r.lazy) .split_lazy else .split;
                try self.emit(.{ .op = op, .a = 0, .b = 0 });
                try split_pcs.append(self.a, split_pc);
                const body_start = self.here();
                self.code.items[split_pc].a = body_start;
                try self.compileNode(r.inner);
            }
            const end_pc = self.here();
            for (split_pcs.items) |spc| self.code.items[spc].b = end_pc;
        }
    }
};

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
