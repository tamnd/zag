const std = @import("std");
const zag = @import("zag");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();

    // The marshal reader and the M1 interpreter both leak intermediate
    // wrappers on purpose (CPython's ref table can alias them). One arena
    // for the whole run keeps the gpa leak-clean.
    var run_arena: std.heap.ArenaAllocator = .init(gpa);
    defer run_arena.deinit();
    const run_alloc = run_arena.allocator();

    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_file_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_file_writer.interface;

    if (args.len < 2) {
        try stderr.print("usage: {s} <path-to-pyc>\n", .{args[0]});
        try stderr.flush();
        std.process.exit(2);
    }

    const code = zag.marshal.pyc.loadFile(run_alloc, io, args[1]) catch |err| {
        try stderr.print("zag: failed to load {s}: {s}\n", .{ args[1], @errorName(err) });
        try stderr.flush();
        std.process.exit(1);
    };

    var interp = try zag.vm.interp.Interp.init(run_alloc, stdout, stderr);
    interp.io = io;
    try interp.installBuiltins();

    // Pre-register every sibling `.cpython-314.pyc` next to the entry
    // file as a user module. Cheap to scan (one directory listing);
    // bodies only execute on first import, so unused modules cost
    // just the marshal load.
    registerSiblings(&interp, run_alloc, io, args[1]) catch {};

    _ = interp.run(code) catch |err| {
        if (err == error.PyException) {
            if (interp.current_exc) |exc| {
                if (isSystemExit(&interp, exc)) {
                    try stdout.flush();
                    try stderr.flush();
                    std.process.exit(systemExitCode(exc));
                }
            }
        }
        try stderr.print("zag: run error: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };

    try stdout.flush();
}

fn isSystemExit(interp: *zag.vm.interp.Interp, exc: zag.object.value.Value) bool {
    if (exc != .instance) return false;
    const cls_v = interp.builtins.getStr("SystemExit") orelse return false;
    if (cls_v != .class) return false;
    for (exc.instance.cls.mro) |c| if (c == cls_v.class) return true;
    return false;
}

fn systemExitCode(exc: zag.object.value.Value) u8 {
    const args_v = exc.instance.dict.getStr("args") orelse return 0;
    if (args_v != .tuple or args_v.tuple.items.len == 0) return 0;
    const a = args_v.tuple.items[0];
    return switch (a) {
        .small_int => |i| @intCast(@as(i64, i) & 0xff),
        .boolean => |b| if (b) 1 else 0,
        .none => 0,
        else => 1,
    };
}

/// Walk the directory containing `entry_path` and register every other
/// `.cpython-314.pyc` under its module name. Top-level files become
/// modules named after their stem; subdirectories become packages
/// (with `__init__.cpython-314.pyc`) and their inner files become
/// dotted submodules. Best-effort throughout — failure just means
/// `import` won't find that file later.
fn registerSiblings(
    interp: *zag.vm.interp.Interp,
    alloc: std.mem.Allocator,
    io: std.Io,
    entry_path: []const u8,
) !void {
    const dirname = std.fs.path.dirname(entry_path) orelse ".";
    const entry_base = std.fs.path.basename(entry_path);
    try walkAndRegister(interp, alloc, io, dirname, "", entry_base);
}

/// Recursive helper. `dotted_prefix` is the dotted package path so far
/// (empty at the top level); `skip_basename` is the entry-script's
/// filename so we don't register it as a sibling module of itself.
fn walkAndRegister(
    interp: *zag.vm.interp.Interp,
    alloc: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    dotted_prefix: []const u8,
    skip_basename: []const u8,
) !void {
    const suffix = ".cpython-314.pyc";
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |ent| {
        if (ent.kind == .file) {
            if (!std.mem.endsWith(u8, ent.name, suffix)) continue;
            if (std.mem.eql(u8, ent.name, skip_basename)) continue;
            const stem = ent.name[0 .. ent.name.len - suffix.len];
            const path = try std.fs.path.join(alloc, &.{ dir_path, ent.name });
            const code = zag.marshal.pyc.loadFile(alloc, io, path) catch continue;
            if (std.mem.eql(u8, stem, "__init__")) {
                if (dotted_prefix.len == 0) continue; // Stray __init__ at top level.
                const owned = try alloc.dupe(u8, dotted_prefix);
                try interp.registerModuleCode(owned, code, true);
            } else {
                const owned = if (dotted_prefix.len == 0)
                    try alloc.dupe(u8, stem)
                else
                    try std.fmt.allocPrint(alloc, "{s}.{s}", .{ dotted_prefix, stem });
                try interp.registerModuleCode(owned, code, false);
            }
        } else if (ent.kind == .directory) {
            // Recurse into subdirectories that look like Python
            // packages (no leading `.`, no `__pycache__`).
            if (std.mem.eql(u8, ent.name, "__pycache__")) continue;
            if (ent.name.len == 0 or ent.name[0] == '.') continue;
            const sub_path = try std.fs.path.join(alloc, &.{ dir_path, ent.name });
            const sub_dotted = if (dotted_prefix.len == 0)
                try alloc.dupe(u8, ent.name)
            else
                try std.fmt.allocPrint(alloc, "{s}.{s}", .{ dotted_prefix, ent.name });
            try walkAndRegister(interp, alloc, io, sub_path, sub_dotted, "");
        }
    }
}
