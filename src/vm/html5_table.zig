// HTML5 entity table — loaded from a compact binary blob instead of source
// literals so it compiles in milliseconds rather than minutes.
//
// Format: alternating null-terminated key and value strings:
//   key\0val\0key\0val\0...

const raw = @embedFile("html5_data.bin");

pub const Entry = struct { name: []const u8, val: []const u8 };

pub fn iterator() Iterator {
    return .{ .pos = 0 };
}

pub const Iterator = struct {
    pos: usize,

    pub fn next(self: *Iterator) ?Entry {
        if (self.pos >= raw.len) return null;
        const key_start = self.pos;
        while (self.pos < raw.len and raw[self.pos] != 0) self.pos += 1;
        const key = raw[key_start..self.pos];
        if (self.pos < raw.len) self.pos += 1; // skip \0
        const val_start = self.pos;
        while (self.pos < raw.len and raw[self.pos] != 0) self.pos += 1;
        const val = raw[val_start..self.pos];
        if (self.pos < raw.len) self.pos += 1; // skip \0
        return .{ .name = key, .val = val };
    }
};
