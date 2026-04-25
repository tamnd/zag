//! A pinhole `importlib` module: enough for `import_module(name,
//! package=None)` and `reload(mod)`. Both delegate to the loader on
//! `Interp` — no separate finder/loader machinery, no spec objects.
//! `import_module` differs from the `import a.b.c` opcode in one
//! place: it returns the *innermost* module of the chain, not the
//! top.

const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const Module = @import("../object/module.zig").Module;
const Str = @import("../object/string.zig").Str;
const Frame = @import("frame.zig").Frame;
const Interp = @import("interp.zig").Interp;
const dispatch = @import("dispatch.zig");

pub fn build(interp: *Interp) !*Module {
    const m = try Module.init(interp.allocator, "importlib");

    const im_fn = try interp.allocator.create(BuiltinFn);
    im_fn.* = .{ .name = "import_module", .func = importModuleFn, .kw_func = importModuleKw };
    try m.attrs.setStr(interp.allocator, "import_module", Value{ .builtin_fn = im_fn });

    const reload_fn = try interp.allocator.create(BuiltinFn);
    reload_fn.* = .{ .name = "reload", .func = reloadFn };
    try m.attrs.setStr(interp.allocator, "reload", Value{ .builtin_fn = reload_fn });

    return m;
}

fn importModuleFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    return importModuleKw(interp_opaque, args, &.{}, &.{});
}

fn importModuleKw(
    interp_opaque: *anyopaque,
    args: []const Value,
    kw_names: []const Value,
    kw_values: []const Value,
) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len < 1 or args.len > 2) {
        try interp.raisePy("TypeError", "import_module() takes 1 or 2 positional arguments");
        return error.PyException;
    }
    if (args[0] != .str) {
        try interp.raisePy("TypeError", "import_module() name must be str");
        return error.PyException;
    }
    const name = args[0].str.bytes;

    var package: []const u8 = "";
    if (args.len >= 2) {
        switch (args[1]) {
            .none => {},
            .str => |s| package = s.bytes,
            else => {
                try interp.raisePy("TypeError", "import_module() package must be str or None");
                return error.PyException;
            },
        }
    }
    for (kw_names, kw_values) |kn, kv| {
        if (kn != .str) {
            try interp.raisePy("TypeError", "import_module() keyword name must be str");
            return error.PyException;
        }
        if (std.mem.eql(u8, kn.str.bytes, "package")) {
            switch (kv) {
                .none => {},
                .str => |s| package = s.bytes,
                else => {
                    try interp.raisePy("TypeError", "import_module() package must be str or None");
                    return error.PyException;
                },
            }
        } else {
            try interp.raisePy("TypeError", "import_module() got an unexpected keyword argument");
            return error.PyException;
        }
    }

    // Count leading dots — that's the relative-import level.
    var level: usize = 0;
    while (level < name.len and name[level] == '.') : (level += 1) {}
    const tail = name[level..];

    const abs_name: []const u8 = blk: {
        if (level == 0) break :blk tail;
        if (package.len == 0) {
            try interp.raisePy("ImportError", "attempted relative import with no known parent package");
            return error.PyException;
        }
        var pkg = package;
        var k: usize = 1;
        while (k < level) : (k += 1) {
            if (std.mem.lastIndexOfScalar(u8, pkg, '.')) |d| {
                pkg = pkg[0..d];
            } else {
                try interp.raisePy("ImportError", "attempted relative import beyond top-level package");
                return error.PyException;
            }
        }
        if (tail.len == 0) break :blk pkg;
        break :blk try std.fmt.allocPrint(interp.allocator, "{s}.{s}", .{ pkg, tail });
    };

    if (interp.getBuiltinModule(abs_name)) |m| return Value{ .module = m };

    const chain_opt = try interp.loadModuleChain(abs_name);
    const chain = chain_opt orelse {
        const msg = try std.fmt.allocPrint(interp.allocator, "No module named '{s}'", .{abs_name});
        try interp.raisePy("ModuleNotFoundError", msg);
        return error.PyException;
    };
    // Unlike `import a.b.c`, importlib hands back the *innermost*
    // module — that's the whole point of the function.
    return Value{ .module = chain.innermost };
}

fn reloadFn(interp_opaque: *anyopaque, args: []const Value) anyerror!Value {
    const interp: *Interp = @ptrCast(@alignCast(interp_opaque));
    if (args.len != 1) {
        try interp.raisePy("TypeError", "reload() takes exactly one argument");
        return error.PyException;
    }
    const m = switch (args[0]) {
        .module => |mm| mm,
        else => {
            try interp.raisePy("TypeError", "reload() argument must be a module");
            return error.PyException;
        },
    };
    const reg = interp.module_codes.get(m.name) orelse {
        const msg = try std.fmt.allocPrint(interp.allocator, "module {s} not in sys.modules", .{m.name});
        try interp.raisePy("ImportError", msg);
        return error.PyException;
    };
    // Re-seed the dunder names — a body's relative imports read
    // `__package__` back, and a fresh `__name__` matches CPython.
    const name_val = try Str.init(interp.allocator, m.name);
    try m.attrs.setStr(interp.allocator, "__name__", Value{ .str = name_val });
    const dot = std.mem.lastIndexOfScalar(u8, m.name, '.');
    const pkg_name: []const u8 = if (reg.is_package)
        m.name
    else if (dot) |d| m.name[0..d] else "";
    const pkg_val = try Str.init(interp.allocator, pkg_name);
    try m.attrs.setStr(interp.allocator, "__package__", Value{ .str = pkg_val });

    const frame = try Frame.init(interp.allocator, reg.code, m.attrs, interp.builtins, m.attrs);
    defer frame.deinit(interp.allocator);
    _ = try dispatch.run(interp, frame);
    return Value{ .module = m };
}
