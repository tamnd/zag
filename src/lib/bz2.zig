//! Real bzip2 compress/decompress. No external dependencies.
//! Wire format: "BZh" + level + blocks + end_magic + stream_crc.
//! Block pipeline: RLE-1 → BWT → MTF+RLE-2 → Huffman.

const std = @import("std");
const Allocator = std.mem.Allocator;

const block_magic: u64 = 0x314159265359;
const end_magic: u64 = 0x177245385090;
const group_size: usize = 50;
const max_huff_len: usize = 20;

// ===== CRC-32 (poly 0x04C11DB7, MSB-first, unreflected) =====

const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var r: u32 = @as(u32, @intCast(i)) << 24;
        var j: usize = 0;
        while (j < 8) : (j += 1) {
            if (r & 0x80000000 != 0) {
                r = (r << 1) ^ 0x04c11db7;
            } else {
                r <<= 1;
            }
        }
        t[i] = r;
    }
    break :blk t;
};

fn blockCrc(data: []const u8) u32 {
    var crc: u32 = 0xffffffff;
    for (data) |b| {
        crc = (crc << 8) ^ crc_table[((crc >> 24) ^ @as(u32, b)) & 0xff];
    }
    return ~crc;
}

// ===== RLE-1 encode/decode =====


fn rle1Encode(a: Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < data.len) {
        var j: usize = i + 1;
        while (j < data.len and data[j] == data[i] and j - i < 255) : (j += 1) {}
        const run = j - i;
        if (run >= 4) {
            try out.appendNTimes(a, data[i], 4);
            try out.append(a, @intCast(run - 4));
        } else {
            try out.appendSlice(a, data[i..j]);
        }
        i = j;
    }
    return out.toOwnedSlice(a);
}

fn rle1Decode(a: Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < data.len) {
        const b = data[i];
        var run: usize = 1;
        while (i + run < data.len and data[i + run] == b and run < 4) : (run += 1) {}
        if (run < 4) {
            try out.appendSlice(a, data[i .. i + run]);
            i += run;
        } else {
            if (i + 4 >= data.len) {
                try out.appendNTimes(a, b, 4);
                i += 4;
            } else {
                const extra: usize = data[i + 4];
                try out.appendNTimes(a, b, 4 + extra);
                i += 5;
            }
        }
    }
    return out.toOwnedSlice(a);
}

// ===== BWT (forward, suffix-array doubling) =====

fn countingSortBy(a: Allocator, idx: []usize, key: []usize, alphabet: usize) !void {
    const n = idx.len;
    const cnt = try a.alloc(usize, alphabet + 1);
    defer a.free(cnt);
    @memset(cnt, 0);
    for (idx) |x| cnt[key[x]] += 1;
    var sum: usize = 0;
    for (cnt[0..alphabet]) |*c| {
        const old = c.*;
        c.* = sum;
        sum += old;
    }
    const tmp = try a.alloc(usize, n);
    defer a.free(tmp);
    for (idx) |x| {
        tmp[cnt[key[x]]] = x;
        cnt[key[x]] += 1;
    }
    @memcpy(idx, tmp);
}

fn bwtForward(a: Allocator, data: []const u8) !struct { transformed: []u8, orig_ptr: usize } {
    const n = data.len;
    if (n == 0) return .{ .transformed = try a.dupe(u8, &.{}), .orig_ptr = 0 };
    if (n == 1) return .{ .transformed = try a.dupe(u8, data), .orig_ptr = 0 };

    const idx = try a.alloc(usize, n);
    defer a.free(idx);
    const rank = try a.alloc(usize, n);
    defer a.free(rank);
    const new_rank = try a.alloc(usize, n);
    defer a.free(new_rank);
    const secondary = try a.alloc(usize, n);
    defer a.free(secondary);

    for (0..n) |i| {
        idx[i] = i;
        rank[i] = data[i];
    }

    try countingSortBy(a, idx, rank, 256);
    new_rank[idx[0]] = 0;
    for (1..n) |i| {
        new_rank[idx[i]] = new_rank[idx[i - 1]];
        if (rank[idx[i]] != rank[idx[i - 1]]) new_rank[idx[i]] += 1;
    }
    @memcpy(rank, new_rank);

    var k: usize = 1;
    while (k < n and rank[idx[n - 1]] != n - 1) : (k *= 2) {
        for (0..n) |i| secondary[i] = rank[(i + k) % n];
        try countingSortBy(a, idx, secondary, n);
        try countingSortBy(a, idx, rank, n);
        new_rank[idx[0]] = 0;
        for (1..n) |i| {
            new_rank[idx[i]] = new_rank[idx[i - 1]];
            if (rank[idx[i - 1]] != rank[idx[i]] or secondary[idx[i - 1]] != secondary[idx[i]])
                new_rank[idx[i]] += 1;
        }
        @memcpy(rank, new_rank);
    }

    const out = try a.alloc(u8, n);
    for (idx, 0..) |s, i| out[i] = data[(s + n - 1) % n];
    var orig_ptr: usize = 0;
    for (idx, 0..) |s, i| if (s == 0) {
        orig_ptr = i;
        break;
    };
    return .{ .transformed = out, .orig_ptr = orig_ptr };
}

fn bwtInverse(a: Allocator, bwt_data: []const u8, orig_ptr: usize) ![]u8 {
    const n = bwt_data.len;
    if (n == 0) return try a.dupe(u8, &.{});

    var cnt: [256]usize = @splat(0);
    for (bwt_data) |b| cnt[b] += 1;

    var first: [256]usize = undefined;
    var sum: usize = 0;
    for (0..256) |c| {
        first[c] = sum;
        sum += cnt[c];
    }

    const nxt = try a.alloc(usize, n);
    defer a.free(nxt);
    var pos: [256]usize = first;
    for (bwt_data, 0..) |b, i| {
        nxt[pos[b]] = i;
        pos[b] += 1;
    }

    const out = try a.alloc(u8, n);
    var cur = nxt[orig_ptr];
    for (0..n) |i| {
        out[i] = bwt_data[cur];
        cur = nxt[cur];
    }
    return out;
}

// ===== MTF + RLE-2 (encode) =====

fn emitZeroRun(syms: *std.ArrayListUnmanaged(u16), a: Allocator, run: usize) !void {
    var r = run;
    while (r > 0) {
        r -= 1;
        try syms.append(a, @intCast(r & 1));
        r >>= 1;
    }
}

fn mtfRle2Encode(a: Allocator, data: []const u8, sym_map: []const u8) ![]u16 {
    const nsym = sym_map.len;
    const list = try a.dupe(u8, sym_map);
    defer a.free(list);

    var syms: std.ArrayListUnmanaged(u16) = .empty;
    errdefer syms.deinit(a);

    var zero_run: usize = 0;
    for (data) |b| {
        var idx: usize = 0;
        while (idx < nsym and list[idx] != b) : (idx += 1) {}
        if (idx > 0) {
            const c = list[idx];
            std.mem.copyBackwards(u8, list[1 .. idx + 1], list[0..idx]);
            list[0] = c;
        }
        if (idx == 0) {
            zero_run += 1;
        } else {
            if (zero_run > 0) {
                try emitZeroRun(&syms, a, zero_run);
                zero_run = 0;
            }
            try syms.append(a, @intCast(idx + 1));
        }
    }
    if (zero_run > 0) try emitZeroRun(&syms, a, zero_run);
    try syms.append(a, @intCast(nsym + 1)); // EOB
    return syms.toOwnedSlice(a);
}

// ===== MTF + RLE-2 (decode) =====

fn mtfRle2Decode(a: Allocator, syms: []const u16, sym_map: []const u8) ![]u8 {
    const nsym = sym_map.len;
    const list = try a.dupe(u8, sym_map);
    defer a.free(list);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);

    const eob: u16 = @intCast(nsym + 1);
    var i: usize = 0;
    while (i < syms.len) {
        const s = syms[i];
        if (s == eob) break;
        if (s == 0 or s == 1) {
            var run_len: usize = 0;
            var bit_pos: u6 = 0;
            while (i < syms.len and (syms[i] == 0 or syms[i] == 1)) : (i += 1) {
                run_len += (@as(usize, syms[i]) + 1) << bit_pos;
                bit_pos += 1;
            }
            try out.appendNTimes(a, list[0], run_len);
        } else {
            const midx = s - 1;
            const b = list[midx];
            if (midx > 0) {
                std.mem.copyBackwards(u8, list[1 .. midx + 1], list[0..midx]);
                list[0] = b;
            }
            try out.append(a, b);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

// ===== Huffman (build + canonical codes) =====

const HufNode = struct { weight: usize, parent: i32 };

fn buildHuffman(a: Allocator, freqs: []const usize) ![]u8 {
    const n = freqs.len;
    // Assign weight ≥ 1 to every symbol (bzip2 needs full alphabet)
    const weights = try a.alloc(usize, n);
    defer a.free(weights);
    for (freqs, weights) |f, *w| w.* = if (f == 0) 1 else f;

    while (true) {
        const lens = try huffmanLengths(a, weights);
        var over: usize = 0;
        for (lens) |l| if (l > over) { over = l; };
        if (over <= max_huff_len) return lens;
        a.free(lens);
        for (weights) |*w| w.* = (w.* >> 1) | 1;
    }
}

fn huffmanLengths(a: Allocator, weights: []const usize) ![]u8 {
    const n = weights.len;
    if (n == 0) return try a.dupe(u8, &.{});
    if (n == 1) {
        const l = try a.alloc(u8, 1);
        l[0] = 1;
        return l;
    }

    // nodes: leaf nodes first, then internal nodes as we merge
    const nodes = try a.alloc(HufNode, 2 * n);
    defer a.free(nodes);
    @memset(nodes, .{ .weight = 0, .parent = -1 });
    for (weights, 0..) |w, i| nodes[i] = .{ .weight = w, .parent = -1 };

    // active: sorted (by weight) list of node indices
    const active = try a.alloc(usize, 2 * n);
    defer a.free(active);
    for (0..n) |i| active[i] = i;
    std.mem.sort(usize, active[0..n], nodes, struct {
        fn lt(ns: []HufNode, aa: usize, bb: usize) bool {
            return ns[aa].weight < ns[bb].weight;
        }
    }.lt);

    var active_len: usize = n;
    var node_count: usize = n;

    while (active_len > 1) {
        const aa = active[0];
        const bb = active[1];
        std.mem.copyForwards(usize, active[0 .. active_len - 2], active[2..active_len]);
        active_len -= 2;

        const parent = node_count;
        node_count += 1;
        nodes[parent] = .{ .weight = nodes[aa].weight + nodes[bb].weight, .parent = -1 };
        nodes[aa].parent = @intCast(parent);
        nodes[bb].parent = @intCast(parent);

        // Insert parent into sorted active list (binary search)
        const pw = nodes[parent].weight;
        var ins: usize = 0;
        while (ins < active_len and nodes[active[ins]].weight <= pw) : (ins += 1) {}
        // shift right and insert
        var j = active_len;
        while (j > ins) : (j -= 1) active[j] = active[j - 1];
        active[ins] = parent;
        active_len += 1;
    }

    const lens = try a.alloc(u8, n);
    for (0..n) |i| {
        var depth: u8 = 0;
        var p = nodes[i].parent;
        while (p != -1) {
            depth += 1;
            p = nodes[@intCast(p)].parent;
        }
        if (depth == 0) depth = 1;
        lens[i] = depth;
    }
    return lens;
}

fn canonicalCodes(a: Allocator, lens: []const u8) ![]u32 {
    const n = lens.len;
    const codes = try a.alloc(u32, n);
    @memset(codes, 0);

    const order = try a.alloc(usize, n);
    defer a.free(order);
    for (0..n) |i| order[i] = i;
    std.mem.sort(usize, order, lens, struct {
        fn lt(ls: []const u8, aa: usize, bb: usize) bool {
            if (ls[aa] != ls[bb]) return ls[aa] < ls[bb];
            return aa < bb;
        }
    }.lt);

    var code: u32 = 0;
    var prev_len: u8 = 0;
    for (order) |s| {
        if (lens[s] == 0) continue;
        if (prev_len == 0) {
            code = 0;
            prev_len = lens[s];
        } else if (lens[s] > prev_len) {
            code <<= @intCast(lens[s] - prev_len);
            prev_len = lens[s];
        }
        codes[s] = code;
        code += 1;
    }
    return codes;
}

// ===== Selector refinement (K-means, 3 iterations) =====

fn pickNumTrees(num_syms: usize) usize {
    return if (num_syms < 200) 2 else if (num_syms < 600) 3 else if (num_syms < 1200) 4 else if (num_syms < 2400) 5 else 6;
}

fn refineSelectors(
    a: Allocator,
    syms: []const u16,
    alpha_size: usize,
    num_trees: usize,
) !struct { selectors: []usize, lens_per_tree: [][]u8 } {
    const num_groups = if (syms.len == 0) 1 else (syms.len + group_size - 1) / group_size;

    const selectors = try a.alloc(usize, num_groups);
    for (selectors, 0..) |*s, g| s.* = g % num_trees;

    const lens_per_tree = try a.alloc([]u8, num_trees);
    for (lens_per_tree) |*l| l.* = &.{};

    for (0..3) |_| {
        // build freq tables
        const freqs_per_tree = try a.alloc([]usize, num_trees);
        defer {
            for (freqs_per_tree) |f| a.free(f);
            a.free(freqs_per_tree);
        }
        for (freqs_per_tree) |*f| {
            f.* = try a.alloc(usize, alpha_size);
            @memset(f.*, 0);
        }
        for (selectors, 0..) |t, g| {
            const start = g * group_size;
            const end = @min(start + group_size, syms.len);
            for (syms[start..end]) |s| freqs_per_tree[t][@intCast(s)] += 1;
        }

        // build Huffman per tree
        var fallback: i32 = -1;
        for (0..num_trees) |t| {
            var any = false;
            for (freqs_per_tree[t]) |f| if (f > 0) { any = true; break; };
            if (any) {
                if (lens_per_tree[t].len > 0) a.free(lens_per_tree[t]);
                lens_per_tree[t] = try buildHuffman(a, freqs_per_tree[t]);
                if (fallback < 0) fallback = @intCast(t);
            }
        }
        // fill empty trees from fallback
        for (0..num_trees) |t| {
            if (lens_per_tree[t].len == 0) {
                if (fallback >= 0) {
                    lens_per_tree[t] = try a.dupe(u8, lens_per_tree[@intCast(fallback)]);
                } else {
                    lens_per_tree[t] = try a.alloc(u8, alpha_size);
                    @memset(lens_per_tree[t], 15);
                }
            }
        }

        // re-assign groups
        for (selectors, 0..) |*sel, g| {
            const start = g * group_size;
            const end = @min(start + group_size, syms.len);
            var best_t: usize = 0;
            var best_cost: usize = std.math.maxInt(usize);
            for (0..num_trees) |t| {
                var cost: usize = 0;
                for (syms[start..end]) |s| cost += lens_per_tree[t][@intCast(s)];
                if (cost < best_cost) { best_cost = cost; best_t = t; }
            }
            sel.* = best_t;
        }
    }

    return .{ .selectors = selectors, .lens_per_tree = lens_per_tree };
}

// ===== Bit writer =====

const BitWriter = struct {
    buf: std.ArrayListUnmanaged(u8),
    current: u64,
    n_bits: u8,

    fn init() BitWriter {
        return .{ .buf = .empty, .current = 0, .n_bits = 0 };
    }

    fn writeBits(w: *BitWriter, a: Allocator, value: u64, n: u8) !void {
        const mask: u64 = if (n == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(n)) - 1;
        w.current = (w.current << @intCast(n)) | (value & mask);
        w.n_bits += n;
        while (w.n_bits >= 8) {
            w.n_bits -= 8;
            try w.buf.append(a, @intCast(w.current >> @intCast(w.n_bits)));
            w.current &= (@as(u64, 1) << @intCast(w.n_bits)) - 1;
        }
    }

    fn flush(w: *BitWriter, a: Allocator) !void {
        if (w.n_bits > 0) {
            try w.buf.append(a, @intCast(w.current << @intCast(8 - w.n_bits)));
            w.current = 0;
            w.n_bits = 0;
        }
    }

    fn deinit(w: *BitWriter, a: Allocator) void {
        w.buf.deinit(a);
    }
};

// ===== Bit reader =====

const BitReader = struct {
    data: []const u8,
    pos: usize, // byte position
    current: u64,
    n_bits: u8,

    fn init(data: []const u8) BitReader {
        return .{ .data = data, .pos = 0, .current = 0, .n_bits = 0 };
    }

    fn readBit(r: *BitReader) !u1 {
        if (r.n_bits == 0) {
            if (r.pos >= r.data.len) return error.EndOfStream;
            r.current = r.data[r.pos];
            r.pos += 1;
            r.n_bits = 8;
        }
        r.n_bits -= 1;
        return @intCast((r.current >> @intCast(r.n_bits)) & 1);
    }

    fn readBits(r: *BitReader, n: u8) !u64 {
        var val: u64 = 0;
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            val = (val << 1) | try r.readBit();
        }
        return val;
    }

    fn bytesConsumed(r: *BitReader) usize {
        // pos = bytes fully read; if partial byte in flight, that byte is consumed too
        return if (r.n_bits > 0) r.pos else r.pos;
    }
};

// ===== Block encode =====

fn encodeBlock(a: Allocator, w: *BitWriter, block: []const u8, crc: u32) !void {
    const rle = try rle1Encode(a, block);
    defer a.free(rle);

    const bwt_result = try bwtForward(a, rle);
    defer a.free(bwt_result.transformed);
    const orig_ptr = bwt_result.orig_ptr;
    const transformed = bwt_result.transformed;

    // Build symbol map
    var present = [_]bool{false} ** 256;
    for (rle) |b| present[b] = true;
    var sym_map_list: std.ArrayListUnmanaged(u8) = .empty;
    defer sym_map_list.deinit(a);
    for (0..256) |i| if (present[i]) try sym_map_list.append(a, @intCast(i));
    if (sym_map_list.items.len == 0) try sym_map_list.append(a, 0);
    const sym_map = sym_map_list.items;

    const syms = try mtfRle2Encode(a, transformed, sym_map);
    defer a.free(syms);

    const alpha_size = sym_map.len + 2;
    const num_trees = pickNumTrees(syms.len);

    const refined = try refineSelectors(a, syms, alpha_size, num_trees);
    defer {
        for (refined.lens_per_tree) |l| a.free(l);
        a.free(refined.lens_per_tree);
        a.free(refined.selectors);
    }
    const selectors = refined.selectors;
    const lens_per_tree = refined.lens_per_tree;

    const codes_per_tree = try a.alloc([]u32, num_trees);
    defer {
        for (codes_per_tree) |c| a.free(c);
        a.free(codes_per_tree);
    }
    for (0..num_trees) |t| codes_per_tree[t] = try canonicalCodes(a, lens_per_tree[t]);

    // Block header
    try w.writeBits(a, block_magic, 48);
    try w.writeBits(a, crc, 32);
    try w.writeBits(a, 0, 1); // not randomised
    try w.writeBits(a, orig_ptr, 24);

    // Symbol map: 2-level bitmap
    var map_big: u16 = 0;
    var map_small = [_]u16{0} ** 16;
    for (sym_map) |b| {
        const g: usize = b >> 4;
        map_big |= @as(u16, 1) << @intCast(15 - g);
        map_small[g] |= @as(u16, 1) << @intCast(15 - @as(usize, b & 0xf));
    }
    try w.writeBits(a, map_big, 16);
    for (0..16) |g| {
        if (map_big & (@as(u16, 1) << @intCast(15 - g)) != 0) {
            try w.writeBits(a, map_small[g], 16);
        }
    }

    try w.writeBits(a, num_trees, 3);
    try w.writeBits(a, selectors.len, 15);

    // MTF-encoded selectors (unary)
    var mtf_list = try a.alloc(usize, num_trees);
    defer a.free(mtf_list);
    for (0..num_trees) |i| mtf_list[i] = i;
    for (selectors) |sel| {
        var p: usize = 0;
        while (p < num_trees and mtf_list[p] != sel) : (p += 1) {}
        if (p > 0) {
            const v = mtf_list[p];
            std.mem.copyBackwards(usize, mtf_list[1 .. p + 1], mtf_list[0..p]);
            mtf_list[0] = v;
        }
        for (0..p) |_| try w.writeBits(a, 1, 1);
        try w.writeBits(a, 0, 1);
    }

    // Tree lengths (delta-coded)
    for (0..num_trees) |t| {
        const lens = lens_per_tree[t];
        var cur: i32 = lens[0];
        try w.writeBits(a, @intCast(cur), 5);
        for (lens) |l| {
            const target: i32 = l;
            while (cur < target) : (cur += 1) try w.writeBits(a, 0b10, 2);
            while (cur > target) : (cur -= 1) try w.writeBits(a, 0b11, 2);
            try w.writeBits(a, 0, 1);
        }
    }

    // Huffman-coded symbols
    const num_groups = selectors.len;
    for (0..num_groups) |g| {
        const t = selectors[g];
        const lens = lens_per_tree[t];
        const codes = codes_per_tree[t];
        const start = g * group_size;
        const end = @min(start + group_size, syms.len);
        for (syms[start..end]) |s| {
            try w.writeBits(a, codes[@intCast(s)], @intCast(lens[@intCast(s)]));
        }
    }
}

// ===== Compress =====

pub fn compress(a: Allocator, data: []const u8, level: usize) ![]u8 {
    const lvl: usize = @max(1, @min(9, level));
    var w = BitWriter.init();
    errdefer w.deinit(a);

    try w.writeBits(a, 'B', 8);
    try w.writeBits(a, 'Z', 8);
    try w.writeBits(a, 'h', 8);
    try w.writeBits(a, @as(u64, '0') + @as(u64, lvl), 8);

    const block_size = lvl * 100_000;
    var combined: u32 = 0;

    if (data.len == 0) {
        try w.writeBits(a, end_magic, 48);
        try w.writeBits(a, 0, 32);
        try w.flush(a);
        return w.buf.toOwnedSlice(a);
    }

    var i: usize = 0;
    while (i < data.len) {
        const end = @min(i + block_size, data.len);
        const block = data[i..end];
        const crc = blockCrc(block);
        combined = ((combined << 1) | (combined >> 31)) ^ crc;
        try encodeBlock(a, &w, block, crc);
        i = end;
    }

    try w.writeBits(a, end_magic, 48);
    try w.writeBits(a, combined, 32);
    try w.flush(a);
    return w.buf.toOwnedSlice(a);
}

// ===== Huffman decoder =====

const HuffDecoder = struct {
    // sorted_syms: symbols in (len asc, sym asc) canonical order
    sorted_syms: []u16,
    min_len: u8,
    max_len: u8,
    // first_code[l]: canonical code of first symbol at length l
    first_code: [max_huff_len + 1]u32,
    // start[l]: index into sorted_syms where length-l symbols begin
    start: [max_huff_len + 1]usize,
    count: [max_huff_len + 1]usize,

    fn build(a: Allocator, lens: []const u8) !HuffDecoder {
        const n = lens.len;
        var cnt = [_]usize{0} ** (max_huff_len + 1);
        for (lens) |l| if (l > 0 and l <= max_huff_len) { cnt[l] += 1; };

        var min_len: u8 = 0;
        var max_len: u8 = 0;
        for (1..max_huff_len + 1) |l| {
            if (cnt[l] > 0) {
                if (min_len == 0) min_len = @intCast(l);
                max_len = @intCast(l);
            }
        }
        if (min_len == 0) min_len = 1;

        // canonical codes
        var first_code = [_]u32{0} ** (max_huff_len + 1);
        var start = [_]usize{0} ** (max_huff_len + 1);
        var code: u32 = 0;
        var idx: usize = 0;
        for (1..max_huff_len + 1) |l| {
            first_code[l] = code;
            start[l] = idx;
            idx += cnt[l];
            code = (code + @as(u32, @intCast(cnt[l]))) << 1;
        }

        // sorted_syms in canonical order
        const sorted = try a.alloc(u16, n);
        var pos = [_]usize{0} ** (max_huff_len + 1);
        for (1..max_huff_len + 1) |l| pos[l] = start[l];
        // sort: for each length, add symbols in symbol order
        for (0..n) |s| {
            const l = lens[s];
            if (l == 0 or l > max_huff_len) continue;
            sorted[pos[l]] = @intCast(s);
            pos[l] += 1;
        }

        return .{
            .sorted_syms = sorted,
            .min_len = min_len,
            .max_len = max_len,
            .first_code = first_code,
            .start = start,
            .count = cnt,
        };
    }

    fn decode(d: *const HuffDecoder, r: *BitReader) !u16 {
        var val: u32 = 0;
        var l: u8 = 0;
        while (l < d.min_len) : (l += 1) val = (val << 1) | try r.readBit();
        while (l <= d.max_len) {
            if (d.count[l] > 0) {
                const offset = val -% d.first_code[l];
                if (offset < d.count[l]) {
                    return d.sorted_syms[d.start[l] + offset];
                }
            }
            val = (val << 1) | try r.readBit();
            l += 1;
        }
        return error.InvalidData;
    }

    fn deinit(d: *HuffDecoder, a: Allocator) void {
        a.free(d.sorted_syms);
    }
};

// ===== Block decode =====

fn decodeBlock(a: Allocator, r: *BitReader) !struct {
    out: []u8,
    crc: u32,
} {
    const stored_crc: u32 = @intCast(try r.readBits(32));
    const randomised = try r.readBits(1);
    _ = randomised;
    const orig_ptr: usize = @intCast(try r.readBits(24));

    // Symbol map
    const map_big: u16 = @intCast(try r.readBits(16));
    var sym_map_list: std.ArrayListUnmanaged(u8) = .empty;
    defer sym_map_list.deinit(a);
    for (0..16) |g| {
        if (map_big & (@as(u16, 1) << @intCast(15 - g)) != 0) {
            const sub: u16 = @intCast(try r.readBits(16));
            for (0..16) |k| {
                if (sub & (@as(u16, 1) << @intCast(15 - k)) != 0) {
                    try sym_map_list.append(a, @intCast(g * 16 + k));
                }
            }
        }
    }
    if (sym_map_list.items.len == 0) try sym_map_list.append(a, 0);
    const sym_map = sym_map_list.items;
    const nsym = sym_map.len;
    const alpha_size: usize = nsym + 2;

    const num_trees: usize = @intCast(try r.readBits(3));
    const num_selectors: usize = @intCast(try r.readBits(15));

    // Read selectors (MTF-encoded unary)
    var mtf_list = try a.alloc(usize, num_trees);
    defer a.free(mtf_list);
    for (0..num_trees) |i| mtf_list[i] = i;

    const selectors = try a.alloc(usize, num_selectors);
    defer a.free(selectors);
    for (selectors) |*sel| {
        var p: usize = 0;
        while (try r.readBit() == 1) : (p += 1) {
            if (p >= num_trees) return error.InvalidData;
        }
        const v = mtf_list[p];
        if (p > 0) {
            std.mem.copyBackwards(usize, mtf_list[1 .. p + 1], mtf_list[0..p]);
            mtf_list[0] = v;
        }
        sel.* = v;
    }

    // Read tree lengths (delta-coded)
    const decoders = try a.alloc(HuffDecoder, num_trees);
    defer {
        for (decoders) |*d| d.deinit(a);
        a.free(decoders);
    }
    for (0..num_trees) |t| {
        var cur: i32 = @intCast(try r.readBits(5));
        const lens = try a.alloc(u8, alpha_size);
        defer a.free(lens);
        for (lens) |*l| {
            while (true) {
                const b = try r.readBit();
                if (b == 0) break;
                const dir = try r.readBit();
                if (dir == 0) cur += 1 else cur -= 1;
                if (cur < 1 or cur > @as(i32, max_huff_len)) return error.InvalidData;
            }
            l.* = @intCast(cur);
        }
        decoders[t] = try HuffDecoder.build(a, lens);
    }

    // Decode symbols
    var raw_syms: std.ArrayListUnmanaged(u16) = .empty;
    defer raw_syms.deinit(a);

    const eob: u16 = @intCast(alpha_size - 1);
    var group: usize = 0;
    var in_group: usize = 0;
    var cur_tree: usize = if (selectors.len > 0) selectors[0] else 0;

    while (true) {
        if (in_group == group_size) {
            group += 1;
            in_group = 0;
            if (group < selectors.len) cur_tree = selectors[group];
        }
        const s = try decoders[cur_tree].decode(r);
        in_group += 1;
        if (s == eob) break;
        try raw_syms.append(a, s);
    }

    // Reverse pipeline
    const mtf_out = try mtfRle2Decode(a, raw_syms.items, sym_map);
    defer a.free(mtf_out);

    const bwt_out = try bwtInverse(a, mtf_out, orig_ptr);
    defer a.free(bwt_out);

    const out = try rle1Decode(a, bwt_out);

    // Verify CRC
    const computed_crc = blockCrc(out);
    if (computed_crc != stored_crc) {
        a.free(out);
        return error.CrcMismatch;
    }

    return .{ .out = out, .crc = stored_crc };
}

// ===== Decompress =====

pub fn decompress(a: Allocator, data: []const u8) !struct {
    out: []u8,
    consumed: usize,
} {
    if (data.len < 4) return error.InvalidData;
    if (data[0] != 'B' or data[1] != 'Z' or data[2] != 'h') return error.InvalidData;
    const lvl_char = data[3];
    if (lvl_char < '1' or lvl_char > '9') return error.InvalidData;

    var r = BitReader.init(data[4..]);
    var all_out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer all_out.deinit(a);
    var combined: u32 = 0;

    while (true) {
        // Read 48-bit magic
        const magic = try r.readBits(48);
        if (magic == end_magic) {
            const stored_stream_crc: u32 = @intCast(try r.readBits(32));
            _ = stored_stream_crc; // We could verify; skip for now
            break;
        }
        if (magic != block_magic) return error.InvalidData;

        const blk = try decodeBlock(a, &r);
        defer a.free(blk.out);
        combined = ((combined << 1) | (combined >> 31)) ^ blk.crc;
        try all_out.appendSlice(a, blk.out);
    }

    // consumed = 4 (header) + bytes the bit reader touched
    const consumed = 4 + r.pos;

    return .{ .out = try all_out.toOwnedSlice(a), .consumed = consumed };
}
