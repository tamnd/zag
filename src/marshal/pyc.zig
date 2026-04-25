//! `.pyc` header reader. CPython 3.14's on-disk format is a 16-byte
//! header followed by a marshal stream whose top object is the
//! module's code object.

const std = @import("std");
const Reader = @import("reader.zig").Reader;
const Code = @import("../object/code.zig").Code;
const Value = @import("../object/value.zig").Value;

/// Magic number for CPython 3.14 bytecode. Little-endian u32
/// = 0x0a0d0e2b = 168_893_483.
pub const magic_314: [4]u8 = .{ 0x2b, 0x0e, 0x0d, 0x0a };

pub const PycError = error{
    ShortHeader,
    BadMagic,
    WrongTopLevelType,
};

pub fn loadBytes(allocator: std.mem.Allocator, data: []const u8) !*Code {
    if (data.len < 16) return error.ShortHeader;
    if (!std.mem.eql(u8, data[0..4], &magic_314)) return error.BadMagic;
    // Bytes [4:8]  = flags
    // Bytes [8:16] = mtime+size or source hash. Neither affects execution.
    var reader = Reader.init(allocator, data[16..]);
    defer reader.deinit();
    const top = try reader.readObject();
    switch (top) {
        .code => |c| return c,
        else => return error.WrongTopLevelType,
    }
}

pub fn loadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !*Code {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(data);
    return loadBytes(allocator, data);
}
