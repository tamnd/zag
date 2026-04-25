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
    try interp.installBuiltins();

    // Pre-register every sibling `.cpython-314.pyc` next to the entry
    // file as a user module. Cheap to scan (one directory listing);
    // bodies only execute on first import, so unused modules cost
    // just the marshal load.
    registerSiblings(&interp, run_alloc, io, args[1]) catch {};

    _ = interp.run(code) catch |err| {
        try stderr.print("zag: run error: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };

    try stdout.flush();
}

/// Walk the directory containing `entry_path` and register every other
/// `.cpython-314.pyc` under its module name (basename minus the
/// `.cpython-314.pyc` suffix). Errors here are best-effort — failure
/// just means `import` won't find that file later.
fn registerSiblings(
    interp: *zag.vm.interp.Interp,
    alloc: std.mem.Allocator,
    io: std.Io,
    entry_path: []const u8,
) !void {
    const suffix = ".cpython-314.pyc";
    const dirname = std.fs.path.dirname(entry_path) orelse ".";
    const entry_base = std.fs.path.basename(entry_path);

    var dir = try std.Io.Dir.cwd().openDir(io, dirname, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.name, suffix)) continue;
        if (std.mem.eql(u8, ent.name, entry_base)) continue;
        const stem = ent.name[0 .. ent.name.len - suffix.len];
        const path = try std.fs.path.join(alloc, &.{ dirname, ent.name });
        const code = zag.marshal.pyc.loadFile(alloc, io, path) catch continue;
        const owned = try alloc.dupe(u8, stem);
        try interp.registerModuleCode(owned, code);
    }
}
