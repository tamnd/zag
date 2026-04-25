const std = @import("std");
const Value = @import("value.zig").Value;

/// CPython fast-local kind flags from `Include/cpython/code.h`.
/// localspluskinds is a bytes blob indexed by local-plus slot.
pub const FastKind = struct {
    pub const arg: u8 = 0x01;
    pub const hidden: u8 = 0x10;
    pub const local: u8 = 0x20;
    pub const cell: u8 = 0x40;
    pub const free: u8 = 0x80;
};

/// Python code object. One per function, module, class body,
/// comprehension. `bytecode`, `consts`, `names`, and the string
/// arrays are owned by the allocator passed at creation.
pub const Code = struct {
    argcount: i32,
    posonlyargcount: i32,
    kwonlyargcount: i32,
    stacksize: i32,
    flags: i32,

    bytecode: []const u8,
    consts: []Value, // tuple of constants
    names: []const []const u8, // module-level + global names

    localsplusnames: []const []const u8,
    localspluskinds: []const u8,

    filename: []const u8,
    name: []const u8,
    qualname: []const u8,

    firstlineno: i32,
    linetable: []const u8,
    exceptiontable: []const u8,

    // Derived from localspluskinds.
    n_locals: u32 = 0,
    n_cells: u32 = 0,
    n_frees: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !*Code {
        const self = try allocator.create(Code);
        self.* = std.mem.zeroInit(Code, .{});
        return self;
    }

    pub fn deinit(self: *Code, allocator: std.mem.Allocator) void {
        allocator.free(self.bytecode);
        allocator.free(self.consts);
        for (self.names) |n| allocator.free(n);
        allocator.free(self.names);
        for (self.localsplusnames) |n| allocator.free(n);
        allocator.free(self.localsplusnames);
        allocator.free(self.localspluskinds);
        allocator.free(self.filename);
        allocator.free(self.name);
        allocator.free(self.qualname);
        allocator.free(self.linetable);
        allocator.free(self.exceptiontable);
        allocator.destroy(self);
    }

    pub fn deriveLocalCounts(self: *Code) void {
        for (self.localspluskinds) |k| {
            if (k & FastKind.free != 0) {
                self.n_frees += 1;
            } else if (k & FastKind.cell != 0) {
                self.n_cells += 1;
            } else {
                self.n_locals += 1;
            }
        }
    }
};
