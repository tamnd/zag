//! XZ compress/decompress. Compress produces valid XZ using LZMA2
//! uncompressed (store) mode. Decompress uses std.compress.xz which handles
//! both compressed and uncompressed LZMA2 packets.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ===== LEB128 helpers =====

fn leb128Len(v: u64) usize {
    var x = v;
    var n: usize = 1;
    while (x >= 0x80) : (x >>= 7) n += 1;
    return n;
}

fn writeLeb128(buf: []u8, v: u64) usize {
    var x = v;
    var i: usize = 0;
    while (x >= 0x80) {
        buf[i] = @as(u8, @intCast((x & 0x7F) | 0x80));
        x >>= 7;
        i += 1;
    }
    buf[i] = @as(u8, @intCast(x));
    return i + 1;
}

fn appendU32Le(out: *std.ArrayListUnmanaged(u8), a: Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(a, &b);
}

fn appendU16Be(out: *std.ArrayListUnmanaged(u8), a: Allocator, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try out.appendSlice(a, &b);
}

// ===== XZ Compress (LZMA2 store mode, check=none) =====
//
// Stream layout: stream_header + block + index + stream_footer
// Block: block_header + LZMA2_data + block_padding (check=none → no check bytes)
// LZMA2 store: [0x01/0x02, size-1 BE u16, data]* ++ 0x00

pub fn compress(a: Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);

    // --- Stream header (12 bytes) ---
    const xz_magic = [_]u8{ 0xFD, '7', 'z', 'X', 'Z', 0x00 };
    try out.appendSlice(a, &xz_magic);
    const stream_flags = [_]u8{ 0x00, 0x00 }; // check=none
    try out.appendSlice(a, &stream_flags);
    try appendU32Le(&out, a, std.hash.Crc32.hash(&stream_flags));

    // --- Build LZMA2 uncompressed data ---
    var lzma2: std.ArrayListUnmanaged(u8) = .empty;
    defer lzma2.deinit(a);
    {
        var rem = data;
        var first = true;
        while (rem.len > 0) {
            const chunk_size = @min(rem.len, 65536);
            try lzma2.append(a, if (first) @as(u8, 0x01) else 0x02);
            first = false;
            try appendU16Be(&lzma2, a, @intCast(chunk_size - 1));
            try lzma2.appendSlice(a, rem[0..chunk_size]);
            rem = rem[chunk_size..];
        }
        try lzma2.append(a, 0x00); // end of LZMA2
    }
    const packed_size: u64 = lzma2.items.len;
    const unpacked_size: u64 = data.len;

    // --- Block header (8 bytes content + 4 bytes CRC32 = 12 bytes total) ---
    // size_indicator=2 → declared_header_size = 2*4 = 8 bytes
    // Layout: [size_indicator(1), flags(1), filter_id(1), props_size(1), dict_byte(1), pad(3)]
    const block_hdr = [_]u8{
        0x02, // size_indicator (2*4=8 bytes covered by CRC32)
        0x00, // flags: no optional size fields, single filter
        0x21, // LZMA2 filter ID (fits in 1 LEB128 byte)
        0x01, // filter properties size = 1
        0x00, // dict_byte: dict_size = 4096 (smallest)
        0x00, 0x00, 0x00, // padding to reach 8 bytes total
    };
    try out.appendSlice(a, &block_hdr);
    try appendU32Le(&out, a, std.hash.Crc32.hash(&block_hdr));

    // --- LZMA2 data ---
    try out.appendSlice(a, lzma2.items);

    // --- Block padding to 4-byte boundary ---
    // block_counter = declared_header_size(8) + packed_size
    const block_counter = 8 + packed_size;
    const block_pad = (4 - (block_counter % 4)) % 4;
    for (0..block_pad) |_| try out.append(a, 0x00);

    // --- Index ---
    const unpadded_block_size = 8 + packed_size; // header_content + LZMA2_data
    var lb: [10]u8 = undefined;
    const n1 = writeLeb128(&lb, 1); // record count
    const n2 = writeLeb128(&lb, unpadded_block_size);
    const n3 = writeLeb128(&lb, unpacked_size);
    const idx_content = 1 + n1 + n2 + n3; // 0x00 + record_count + unpadded + uncompressed
    const idx_pad = (4 - (idx_content % 4)) % 4;
    const idx_total: u64 = idx_content + idx_pad + 4; // +4 for CRC32

    var idx_crc: std.hash.Crc32 = .init();
    try out.append(a, 0x00);
    idx_crc.update(&[_]u8{0x00});
    {
        var lbuf: [10]u8 = undefined;
        const na = writeLeb128(&lbuf, 1);
        try out.appendSlice(a, lbuf[0..na]);
        idx_crc.update(lbuf[0..na]);
        const nb = writeLeb128(&lbuf, unpadded_block_size);
        try out.appendSlice(a, lbuf[0..nb]);
        idx_crc.update(lbuf[0..nb]);
        const nc = writeLeb128(&lbuf, unpacked_size);
        try out.appendSlice(a, lbuf[0..nc]);
        idx_crc.update(lbuf[0..nc]);
    }
    for (0..idx_pad) |_| {
        try out.append(a, 0x00);
        idx_crc.update(&[_]u8{0x00});
    }
    try appendU32Le(&out, a, idx_crc.final());

    // --- Stream footer ---
    const backward_size_field: u32 = @intCast(idx_total / 4 - 1);
    var bs_b: [4]u8 = undefined;
    std.mem.writeInt(u32, &bs_b, backward_size_field, .little);
    var foot_crc: std.hash.Crc32 = .init();
    foot_crc.update(&bs_b);
    foot_crc.update(&stream_flags);
    try appendU32Le(&out, a, foot_crc.final());
    try out.appendSlice(a, &bs_b);
    try out.appendSlice(a, &stream_flags);
    try out.appendSlice(a, &[_]u8{ 'Y', 'Z' });

    return out.toOwnedSlice(a);
}

// ===== XZ Decompress =====

pub fn decompress(a: Allocator, data: []const u8) !struct { out: []u8, consumed: usize } {
    if (data.len < 12) return error.InvalidData;
    if (!std.mem.eql(u8, data[0..6], &[_]u8{ 0xFD, '7', 'z', 'X', 'Z', 0x00 }))
        return error.InvalidData;

    // Pass a heap-allocated buffer so deinit can safely free it.
    const init_buf = try a.alloc(u8, 4096);
    // Note: deinit() frees xzd.reader.buffer which equals init_buf (or a realloc of it).
    var reader: std.Io.Reader = .fixed(data);
    var xzd = std.compress.xz.Decompress.init(&reader, a, init_buf) catch {
        a.free(init_buf);
        return error.InvalidData;
    };
    defer xzd.deinit();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);

    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = xzd.reader.readSliceShort(tmp[0..]) catch |err| switch (err) {
            error.ReadFailed => return error.InvalidData,
        };
        if (n == 0) break;
        try out.appendSlice(a, tmp[0..n]);
    }

    return .{ .out = try out.toOwnedSlice(a), .consumed = reader.seek };
}
