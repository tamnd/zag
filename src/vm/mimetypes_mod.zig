//! `mimetypes` module — MIME type guessing for fixture 209.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;
const Module = @import("../object/module.zig").Module;
const Class = @import("../object/class.zig").Class;
const Dict = @import("../object/dict.zig").Dict;
const List = @import("../object/list.zig").List;
const Str = @import("../object/string.zig").Str;
const Tuple = @import("../object/tuple.zig").Tuple;
const Interp = @import("interp.zig").Interp;

fn gi(p: *anyopaque) *Interp {
    return @ptrCast(@alignCast(p));
}

fn regM(a: std.mem.Allocator, m: *Module, name: []const u8, f: BuiltinFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f };
    try m.attrs.setStr(a, name, Value{ .builtin_fn = bf });
}

fn regD(a: std.mem.Allocator, d: *Dict, name: []const u8, f: BuiltinFnPtr) !void {
    const bf = try a.create(BuiltinFn);
    bf.* = .{ .name = name, .func = f };
    try d.setStr(a, name, Value{ .builtin_fn = bf });
}

// ===== Module-level mutable tables =====

var g_types_map: ?*Dict = null; // ext → MIME type
var g_encodings_map: ?*Dict = null; // ext → encoding
var g_suffix_map: ?*Dict = null; // ext → ext (e.g. .tgz → .tar.gz)
var g_reverse_map: ?*Dict = null; // MIME type → ext
var g_inited: bool = false;

// ===== Helpers =====

/// Strip query string from a URL/path and return the result.
fn stripQuery(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '?')) |q| return name[0..q];
    return name;
}

/// Return the last extension (including dot) from a path, or empty slice.
fn lastExt(path: []const u8) []const u8 {
    // Work on basename only (after last '/')
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| {
        if (i == 0) return ""; // leading dot, not an extension
        return base[i..];
    }
    return "";
}

/// Guess MIME type and encoding for a file name / URL.
/// Returns a 2-tuple (type_or_None, enc_or_None).
fn doGuessType(a: std.mem.Allocator, types_map: *Dict, encodings_map: *Dict, suffix_map: *Dict, name: []const u8) !Value {
    const clean = stripQuery(name);
    var ext = lastExt(clean);

    var encoding: ?[]const u8 = null;

    // Check suffix_map first (.tgz → .tar.gz)
    if (ext.len > 0) {
        if (suffix_map.getStr(ext)) |mapped| {
            if (mapped == .str) {
                // mapped is e.g. ".tar.gz" — find the encoding ext
                const mapped_str = mapped.str.bytes;
                const enc_ext = lastExt(mapped_str);
                if (enc_ext.len > 0) {
                    if (encodings_map.getStr(enc_ext)) |enc_v| {
                        if (enc_v == .str) encoding = enc_v.str.bytes;
                        // strip the encoding ext to get inner ext
                        ext = mapped_str[0 .. mapped_str.len - enc_ext.len];
                        // ext is now e.g. ".tar"
                    }
                }
            }
        } else {
            // Check encodings_map for the outer extension
            if (encodings_map.getStr(ext)) |enc_v| {
                if (enc_v == .str) {
                    encoding = enc_v.str.bytes;
                    // Strip encoding ext and get inner ext
                    const without_enc = clean[0 .. clean.len - ext.len];
                    ext = lastExt(without_enc);
                }
            }
        }
    }

    const tup = try Tuple.init(a, 2);
    if (ext.len > 0) {
        if (types_map.getStr(ext)) |tv| {
            tup.items[0] = tv;
        } else {
            tup.items[0] = Value.none;
        }
    } else {
        tup.items[0] = Value.none;
    }

    if (encoding) |enc| {
        tup.items[1] = Value{ .str = try Str.init(a, enc) };
    } else {
        tup.items[1] = Value.none;
    }

    return Value{ .tuple = tup };
}

// ===== Module-level functions =====

fn guessTypeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return makeTupleNoneNone(a);
    const name = switch (args[0]) {
        .str => |s| s.bytes,
        else => return makeTupleNoneNone(a),
    };
    const tm = g_types_map orelse return makeTupleNoneNone(a);
    const em = g_encodings_map orelse return makeTupleNoneNone(a);
    const sm = g_suffix_map orelse return makeTupleNoneNone(a);
    return doGuessType(a, tm, em, sm, name);
}

fn makeTupleNoneNone(a: std.mem.Allocator) !Value {
    const tup = try Tuple.init(a, 2);
    tup.items[0] = Value.none;
    tup.items[1] = Value.none;
    return Value{ .tuple = tup };
}

fn guessAllExtensionsFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return Value{ .list = try List.init(a) };
    const mime_type = switch (args[0]) {
        .str => |s| s.bytes,
        else => return Value{ .list = try List.init(a) },
    };
    const tm = g_types_map orelse return Value{ .list = try List.init(a) };
    return collectExtsForType(a, tm, mime_type);
}

fn collectExtsForType(a: std.mem.Allocator, types_map: *Dict, mime_type: []const u8) !Value {
    const out = try List.init(a);
    for (types_map.pairs.items) |pair| {
        if (pair.key != .str or pair.value != .str) continue;
        if (std.mem.eql(u8, pair.value.str.bytes, mime_type)) {
            const sv = try Str.init(a, pair.key.str.bytes);
            try out.items.append(a, Value{ .str = sv });
        }
    }
    return Value{ .list = out };
}

fn guessExtensionFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    const mime_type = switch (args[0]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const tm = g_types_map orelse return Value.none;
    // Use reverse_map first for determinism
    if (g_reverse_map) |rm| {
        if (rm.getStr(mime_type)) |ev| {
            if (ev == .str) return ev;
        }
    }
    // Fall back to linear scan
    for (tm.pairs.items) |pair| {
        if (pair.key != .str or pair.value != .str) continue;
        if (std.mem.eql(u8, pair.value.str.bytes, mime_type)) return pair.key;
    }
    _ = a;
    return Value.none;
}

fn addTypeFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2) return Value.none;
    const mime_type = switch (args[0]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const ext = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const tm = g_types_map orelse return Value.none;
    const rm = g_reverse_map orelse return Value.none;
    const tv = try Str.init(a, mime_type);
    try tm.setStr(a, ext, Value{ .str = tv });
    const ev = try Str.init(a, ext);
    try rm.setStr(a, mime_type, Value{ .str = ev });
    return Value.none;
}

fn initFn(p: *anyopaque, _: []const Value) anyerror!Value {
    const interp = gi(p);
    g_inited = true;
    // Update module attribute
    if (interp.mimetypes_module) |m| {
        try m.attrs.setStr(interp.allocator, "inited", Value{ .boolean = true });
    }
    return Value.none;
}

fn readMimeTypesFn(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1) return Value.none;
    const path = switch (args[0]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    return readMimeTypesFile(interp, a, path) catch return Value.none;
}

fn readMimeTypesFile(interp: *Interp, a: std.mem.Allocator, path: []const u8) !Value {
    var file = std.Io.Dir.cwd().openFile(interp.io, path, .{}) catch return Value.none;
    defer file.close(interp.io);

    var data: std.ArrayListUnmanaged(u8) = .empty;
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(interp.io, &read_buf);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const got = reader.interface.readSliceShort(chunk[0..]) catch break;
        if (got == 0) break;
        try data.appendSlice(a, chunk[0..got]);
    }
    const content = data.toOwnedSlice(a) catch return Value.none;
    defer a.free(content);

    const result = try Dict.init(a);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const mime_type = parts.next() orelse continue;
        const tv = try Str.init(a, mime_type);
        while (parts.next()) |raw_ext| {
            // Ensure extension starts with dot
            var ext_buf: [64]u8 = undefined;
            const ext: []const u8 = if (raw_ext[0] == '.') raw_ext else blk: {
                if (raw_ext.len + 1 > ext_buf.len) continue;
                ext_buf[0] = '.';
                @memcpy(ext_buf[1 .. raw_ext.len + 1], raw_ext);
                break :blk ext_buf[0 .. raw_ext.len + 1];
            };
            try result.setStr(a, ext, Value{ .str = tv });
        }
    }
    return Value{ .dict = result };
}

// ===== MimeTypes class =====

fn mimeTypesInit(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 1 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;

    // Create instance-local tables, copy from globals
    const inst_types = try Dict.init(a);
    const inst_reverse = try Dict.init(a);

    if (g_types_map) |tm| {
        for (tm.pairs.items) |pair| {
            if (pair.key != .str or pair.value != .str) continue;
            try inst_types.setStr(a, pair.key.str.bytes, pair.value);
        }
    }
    if (g_reverse_map) |rm| {
        for (rm.pairs.items) |pair| {
            if (pair.key != .str or pair.value != .str) continue;
            try inst_reverse.setStr(a, pair.key.str.bytes, pair.value);
        }
    }

    try inst.dict.setStr(a, "_types", Value{ .dict = inst_types });
    try inst.dict.setStr(a, "_reverse", Value{ .dict = inst_reverse });
    return Value.none;
}

fn mimeTypesAdd(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 3 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const mime_type = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };
    const ext = switch (args[2]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };

    const types_v = inst.dict.getStr("_types") orelse return Value.none;
    const reverse_v = inst.dict.getStr("_reverse") orelse return Value.none;
    if (types_v != .dict or reverse_v != .dict) return Value.none;

    const tv = try Str.init(a, mime_type);
    try types_v.dict.setStr(a, ext, Value{ .str = tv });
    const ev = try Str.init(a, ext);
    try reverse_v.dict.setStr(a, mime_type, Value{ .str = ev });
    return Value.none;
}

fn mimeTypesGuessType(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return makeTupleNoneNone(a);
    const inst = args[0].instance;
    const name = switch (args[1]) {
        .str => |s| s.bytes,
        else => return makeTupleNoneNone(a),
    };

    const types_v = inst.dict.getStr("_types") orelse return makeTupleNoneNone(a);
    if (types_v != .dict) return makeTupleNoneNone(a);

    const em = g_encodings_map orelse return makeTupleNoneNone(a);
    const sm = g_suffix_map orelse return makeTupleNoneNone(a);
    return doGuessType(a, types_v.dict, em, sm, name);
}

fn mimeTypesGuessAllExtensions(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value{ .list = try List.init(a) };
    const inst = args[0].instance;
    const mime_type = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value{ .list = try List.init(a) },
    };

    const types_v = inst.dict.getStr("_types") orelse return Value{ .list = try List.init(a) };
    if (types_v != .dict) return Value{ .list = try List.init(a) };
    return collectExtsForType(a, types_v.dict, mime_type);
}

fn mimeTypesGuessExtension(p: *anyopaque, args: []const Value) anyerror!Value {
    const interp = gi(p);
    const a = interp.allocator;
    if (args.len < 2 or args[0] != .instance) return Value.none;
    const inst = args[0].instance;
    const mime_type = switch (args[1]) {
        .str => |s| s.bytes,
        else => return Value.none,
    };

    // Check reverse map in instance dict
    const reverse_v = inst.dict.getStr("_reverse") orelse return Value.none;
    if (reverse_v == .dict) {
        if (reverse_v.dict.getStr(mime_type)) |ev| {
            if (ev == .str) return ev;
        }
    }

    const types_v = inst.dict.getStr("_types") orelse return Value.none;
    if (types_v != .dict) return Value.none;
    for (types_v.dict.pairs.items) |pair| {
        if (pair.key != .str or pair.value != .str) continue;
        if (std.mem.eql(u8, pair.value.str.bytes, mime_type)) return pair.key;
    }
    _ = a;
    return Value.none;
}

// ===== Populate tables =====

const TypeEntry = struct { ext: []const u8, mime: []const u8 };
const EncodingEntry = struct { ext: []const u8, enc: []const u8 };
const SuffixEntry = struct { from: []const u8, to: []const u8 };

const types_table = [_]TypeEntry{
    // Text
    .{ .ext = ".html", .mime = "text/html" },
    .{ .ext = ".htm", .mime = "text/html" },
    .{ .ext = ".txt", .mime = "text/plain" },
    .{ .ext = ".text", .mime = "text/plain" },
    .{ .ext = ".css", .mime = "text/css" },
    .{ .ext = ".csv", .mime = "text/csv" },
    .{ .ext = ".xml", .mime = "text/xml" },
    .{ .ext = ".xhtml", .mime = "application/xhtml+xml" },
    .{ .ext = ".md", .mime = "text/markdown" },
    .{ .ext = ".rst", .mime = "text/x-rst" },
    .{ .ext = ".rtf", .mime = "text/rtf" },
    .{ .ext = ".ics", .mime = "text/calendar" },
    // Application
    .{ .ext = ".json", .mime = "application/json" },
    .{ .ext = ".js", .mime = "application/javascript" },
    .{ .ext = ".mjs", .mime = "application/javascript" },
    .{ .ext = ".pdf", .mime = "application/pdf" },
    .{ .ext = ".zip", .mime = "application/zip" },
    .{ .ext = ".tar", .mime = "application/x-tar" },
    .{ .ext = ".gz", .mime = "application/gzip" },
    .{ .ext = ".bz2", .mime = "application/x-bzip2" },
    .{ .ext = ".xz", .mime = "application/x-xz" },
    .{ .ext = ".7z", .mime = "application/x-7z-compressed" },
    .{ .ext = ".rar", .mime = "application/vnd.rar" },
    .{ .ext = ".jar", .mime = "application/java-archive" },
    .{ .ext = ".war", .mime = "application/java-archive" },
    .{ .ext = ".ear", .mime = "application/java-archive" },
    .{ .ext = ".wasm", .mime = "application/wasm" },
    .{ .ext = ".ogx", .mime = "application/ogg" },
    .{ .ext = ".swf", .mime = "application/x-shockwave-flash" },
    .{ .ext = ".sh", .mime = "application/x-sh" },
    .{ .ext = ".bat", .mime = "application/x-msdos-program" },
    .{ .ext = ".exe", .mime = "application/octet-stream" },
    .{ .ext = ".dll", .mime = "application/octet-stream" },
    .{ .ext = ".bin", .mime = "application/octet-stream" },
    .{ .ext = ".iso", .mime = "application/x-iso9660-image" },
    .{ .ext = ".dmg", .mime = "application/x-apple-diskimage" },
    .{ .ext = ".doc", .mime = "application/msword" },
    .{ .ext = ".dot", .mime = "application/msword" },
    .{ .ext = ".docx", .mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
    .{ .ext = ".xls", .mime = "application/vnd.ms-excel" },
    .{ .ext = ".xlsx", .mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
    .{ .ext = ".ppt", .mime = "application/vnd.ms-powerpoint" },
    .{ .ext = ".pptx", .mime = "application/vnd.openxmlformats-officedocument.presentationml.presentation" },
    .{ .ext = ".odt", .mime = "application/vnd.oasis.opendocument.text" },
    .{ .ext = ".ods", .mime = "application/vnd.oasis.opendocument.spreadsheet" },
    .{ .ext = ".odp", .mime = "application/vnd.oasis.opendocument.presentation" },
    .{ .ext = ".woff", .mime = "font/woff" },
    .{ .ext = ".woff2", .mime = "font/woff2" },
    .{ .ext = ".ttf", .mime = "font/ttf" },
    .{ .ext = ".otf", .mime = "font/otf" },
    .{ .ext = ".eot", .mime = "application/vnd.ms-fontobject" },
    .{ .ext = ".py", .mime = "text/x-python" },
    .{ .ext = ".pyc", .mime = "application/x-python-code" },
    .{ .ext = ".rb", .mime = "application/x-ruby" },
    .{ .ext = ".pl", .mime = "text/x-perl" },
    .{ .ext = ".java", .mime = "text/x-java-source" },
    .{ .ext = ".c", .mime = "text/x-csrc" },
    .{ .ext = ".h", .mime = "text/x-chdr" },
    .{ .ext = ".cpp", .mime = "text/x-c++src" },
    .{ .ext = ".cc", .mime = "text/x-c++src" },
    .{ .ext = ".go", .mime = "text/x-go" },
    .{ .ext = ".rs", .mime = "text/x-rustsrc" },
    .{ .ext = ".zig", .mime = "text/x-zig" },
    .{ .ext = ".ts", .mime = "text/typescript" },
    .{ .ext = ".yaml", .mime = "text/yaml" },
    .{ .ext = ".yml", .mime = "text/yaml" },
    .{ .ext = ".toml", .mime = "application/toml" },
    .{ .ext = ".ini", .mime = "text/plain" },
    .{ .ext = ".cfg", .mime = "text/plain" },
    .{ .ext = ".conf", .mime = "text/plain" },
    .{ .ext = ".log", .mime = "text/plain" },
    // Images
    .{ .ext = ".png", .mime = "image/png" },
    .{ .ext = ".jpg", .mime = "image/jpeg" },
    .{ .ext = ".jpeg", .mime = "image/jpeg" },
    .{ .ext = ".gif", .mime = "image/gif" },
    .{ .ext = ".bmp", .mime = "image/bmp" },
    .{ .ext = ".ico", .mime = "image/x-icon" },
    .{ .ext = ".svg", .mime = "image/svg+xml" },
    .{ .ext = ".webp", .mime = "image/webp" },
    .{ .ext = ".tif", .mime = "image/tiff" },
    .{ .ext = ".tiff", .mime = "image/tiff" },
    .{ .ext = ".avif", .mime = "image/avif" },
    // Audio
    .{ .ext = ".mp3", .mime = "audio/mpeg" },
    .{ .ext = ".ogg", .mime = "audio/ogg" },
    .{ .ext = ".oga", .mime = "audio/ogg" },
    .{ .ext = ".wav", .mime = "audio/wav" },
    .{ .ext = ".flac", .mime = "audio/flac" },
    .{ .ext = ".aac", .mime = "audio/aac" },
    .{ .ext = ".m4a", .mime = "audio/mp4" },
    .{ .ext = ".opus", .mime = "audio/opus" },
    .{ .ext = ".mid", .mime = "audio/midi" },
    .{ .ext = ".midi", .mime = "audio/midi" },
    // Video
    .{ .ext = ".mp4", .mime = "video/mp4" },
    .{ .ext = ".m4v", .mime = "video/mp4" },
    .{ .ext = ".webm", .mime = "video/webm" },
    .{ .ext = ".ogv", .mime = "video/ogg" },
    .{ .ext = ".avi", .mime = "video/x-msvideo" },
    .{ .ext = ".mov", .mime = "video/quicktime" },
    .{ .ext = ".mkv", .mime = "video/x-matroska" },
    .{ .ext = ".flv", .mime = "video/x-flv" },
    .{ .ext = ".wmv", .mime = "video/x-ms-wmv" },
    .{ .ext = ".mpeg", .mime = "video/mpeg" },
    .{ .ext = ".mpg", .mime = "video/mpeg" },
    // Data / misc
    .{ .ext = ".sqlite", .mime = "application/x-sqlite3" },
    .{ .ext = ".db", .mime = "application/x-sqlite3" },
    .{ .ext = ".whl", .mime = "application/zip" },
};

const encodings_table = [_]EncodingEntry{
    .{ .ext = ".gz", .enc = "gzip" },
    .{ .ext = ".bz2", .enc = "bzip2" },
    .{ .ext = ".xz", .enc = "xz" },
    .{ .ext = ".Z", .enc = "compress" },
    .{ .ext = ".br", .enc = "br" },
    .{ .ext = ".zst", .enc = "zstd" },
};

const suffix_table = [_]SuffixEntry{
    .{ .from = ".tgz", .to = ".tar.gz" },
    .{ .from = ".tbz2", .to = ".tar.bz2" },
    .{ .from = ".txz", .to = ".tar.xz" },
    .{ .from = ".taz", .to = ".tar.gz" },
};

fn populateTables(a: std.mem.Allocator) !void {
    const tm = try Dict.init(a);
    const em = try Dict.init(a);
    const sm = try Dict.init(a);
    const rm = try Dict.init(a);

    for (types_table) |e| {
        const tv = try Str.init(a, e.mime);
        try tm.setStr(a, e.ext, Value{ .str = tv });
        // Only record first ext for reverse map
        if (rm.getStr(e.mime) == null) {
            const ev = try Str.init(a, e.ext);
            try rm.setStr(a, e.mime, Value{ .str = ev });
        }
    }
    for (encodings_table) |e| {
        const ev = try Str.init(a, e.enc);
        try em.setStr(a, e.ext, Value{ .str = ev });
    }
    for (suffix_table) |e| {
        const sv = try Str.init(a, e.to);
        try sm.setStr(a, e.from, Value{ .str = sv });
    }

    g_types_map = tm;
    g_encodings_map = em;
    g_suffix_map = sm;
    g_reverse_map = rm;
}

// ===== build =====

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "mimetypes");

    try populateTables(a);

    // Module attributes
    try m.attrs.setStr(a, "inited", Value{ .boolean = false });
    try m.attrs.setStr(a, "suffix_map", Value{ .dict = g_suffix_map.? });
    try m.attrs.setStr(a, "encodings_map", Value{ .dict = g_encodings_map.? });
    try m.attrs.setStr(a, "types_map", Value{ .dict = g_types_map.? });

    // Module-level functions
    try regM(a, m, "guess_type", guessTypeFn);
    try regM(a, m, "guess_all_extensions", guessAllExtensionsFn);
    try regM(a, m, "guess_extension", guessExtensionFn);
    try regM(a, m, "add_type", addTypeFn);
    try regM(a, m, "init", initFn);
    try regM(a, m, "read_mime_types", readMimeTypesFn);

    // MimeTypes class
    {
        const d = try Dict.init(a);
        try regD(a, d, "__init__", mimeTypesInit);
        try regD(a, d, "add", mimeTypesAdd);
        try regD(a, d, "guess_type", mimeTypesGuessType);
        try regD(a, d, "guess_all_extensions", mimeTypesGuessAllExtensions);
        try regD(a, d, "guess_extension", mimeTypesGuessExtension);
        interp.mimetypes_class = try Class.init(a, "MimeTypes", &.{}, d);
        try m.attrs.setStr(a, "MimeTypes", Value{ .class = interp.mimetypes_class.? });
    }

    interp.mimetypes_module = m;
    return m;
}
