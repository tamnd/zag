const std = @import("std");

const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const BuiltinFnPtr = value_mod.BuiltinFnPtr;

const Dict = @import("../object/dict.zig").Dict;
const Code = @import("../object/code.zig").Code;
const Tuple = @import("../object/tuple.zig").Tuple;
const Str = @import("../object/string.zig").Str;
const Instance = @import("../object/instance.zig").Instance;
const Module = @import("../object/module.zig").Module;
const Frame = @import("frame.zig").Frame;
const dispatch = @import("dispatch.zig");
const builtins = @import("builtins.zig");
const asyncio_mod = @import("asyncio.zig");
const importlib_mod = @import("importlib.zig");
const functools_mod = @import("functools_mod.zig");
const itertools_mod = @import("itertools_mod.zig");
const operator_mod = @import("operator_mod.zig");
const collections_mod = @import("collections_mod.zig");
const collections_abc_mod = @import("collections_abc_mod.zig");
const math_mod = @import("math_mod.zig");
const heapq_mod = @import("heapq_mod.zig");
const bisect_mod = @import("bisect_mod.zig");
const array_mod = @import("array_mod.zig");
const weakref_mod = @import("weakref_mod.zig");
const random_mod = @import("random_mod.zig");
const json_mod = @import("json_mod.zig");
const string_mod = @import("string_mod.zig");
const copy_mod = @import("copy_mod.zig");
const io_mod = @import("io_mod.zig");
const hashlib_mod = @import("hashlib_mod.zig");
const base64_mod = @import("base64_mod.zig");
const textwrap_mod = @import("textwrap_mod.zig");
const unicodedata_mod = @import("unicodedata_mod.zig");
const stringprep_mod = @import("stringprep_mod.zig");
const readline_mod = @import("readline_mod.zig");
const rlcompleter_mod = @import("rlcompleter_mod.zig");
const re_mod = @import("re_mod.zig");
const struct_mod = @import("struct_mod.zig");
const codecs_mod = @import("codecs_mod.zig");
const datetime_mod = @import("datetime_mod.zig");
const zoneinfo_mod = @import("zoneinfo_mod.zig");
const csv_mod = @import("csv_mod.zig");
const urlparse_mod = @import("urlparse_mod.zig");
const zlib_mod = @import("zlib_mod.zig");
const binascii_mod = @import("binascii_mod.zig");
const hmac_mod = @import("hmac_mod.zig");
const secrets_mod = @import("secrets_mod.zig");
const uuid_mod = @import("uuid_mod.zig");
const difflib_mod = @import("difflib_mod.zig");
const shlex_mod = @import("shlex_mod.zig");
const gzip_mod = @import("gzip_mod.zig");
const fnmatch_mod = @import("fnmatch_mod.zig");
const statistics_mod = @import("statistics_mod.zig");
const calendar_mod = @import("calendar_mod.zig");
const pprint_mod = @import("pprint_mod.zig");
const html_mod = @import("html_mod.zig");
const sys_mod = @import("sys_mod.zig");

pub const Interp = struct {
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    io: std.Io = undefined,
    globals: *Dict,
    builtins: *Dict,
    /// The live Python exception, or null. Set by `raisePy` (or
    /// directly by RAISE_VARARGS) before the dispatch loop sees
    /// `error.PyException`; the exception-table catch loop reads it.
    current_exc: ?Value = null,
    /// The value produced by the most recent YIELD_VALUE. Read by the
    /// generator-send wrapper after `error.GenYield` escapes dispatch.
    gen_yielded: ?Value = null,
    /// Cached builtin modules. Lazily built on first import so a
    /// script that doesn't reach for them pays nothing.
    asyncio_module: ?*Module = null,
    importlib_module: ?*Module = null,
    functools_module: ?*Module = null,
    itertools_module: ?*Module = null,
    operator_module: ?*Module = null,
    collections_module: ?*Module = null,
    collections_abc_module: ?*Module = null,
    collections_chainmap_class: ?*@import("../object/class.zig").Class = null,
    collections_userdict_class: ?*@import("../object/class.zig").Class = null,
    collections_userlist_class: ?*@import("../object/class.zig").Class = null,
    collections_userstring_class: ?*@import("../object/class.zig").Class = null,
    math_module: ?*Module = null,
    heapq_module: ?*Module = null,
    bisect_module: ?*Module = null,
    array_module: ?*Module = null,
    array_class: ?*@import("../object/class.zig").Class = null,
    weakref_module: ?*Module = null,
    weakref_ref_class: ?*@import("../object/class.zig").Class = null,
    weakref_proxy_class: ?*@import("../object/class.zig").Class = null,
    weakref_callable_proxy_class: ?*@import("../object/class.zig").Class = null,
    weakref_finalize_class: ?*@import("../object/class.zig").Class = null,
    weakref_weakmethod_class: ?*@import("../object/class.zig").Class = null,
    weakref_wvd_class: ?*@import("../object/class.zig").Class = null,
    weakref_wkd_class: ?*@import("../object/class.zig").Class = null,
    weakref_ws_class: ?*@import("../object/class.zig").Class = null,
    /// Maps a target instance pointer to all `weakref.ref` instances
    /// created for it. Used for canonical dedup (no-callback refs share
    /// identity) and for `getweakrefs`/`getweakrefcount`.
    weakref_registry: std.AutoHashMapUnmanaged(*@import("../object/instance.zig").Instance, std.ArrayListUnmanaged(*@import("../object/instance.zig").Instance)) = .empty,
    random_module: ?*Module = null,
    json_module: ?*Module = null,
    string_module: ?*Module = null,
    copy_module: ?*Module = null,
    io_module: ?*Module = null,
    hashlib_module: ?*Module = null,
    base64_module: ?*Module = null,
    textwrap_module: ?*Module = null,
    unicodedata_module: ?*Module = null,
    stringprep_module: ?*Module = null,
    readline_module: ?*Module = null,
    rlcompleter_module: ?*Module = null,
    rlcompleter_class: ?*@import("../object/class.zig").Class = null,
    re_module: ?*Module = null,
    struct_module: ?*Module = null,
    struct_error_class: ?*@import("../object/class.zig").Class = null,
    struct_struct_class: ?*@import("../object/class.zig").Class = null,
    codecs_module: ?*Module = null,
    codecs_codecinfo_class: ?*@import("../object/class.zig").Class = null,
    codecs_encoder_class: ?*@import("../object/class.zig").Class = null,
    codecs_decoder_class: ?*@import("../object/class.zig").Class = null,
    datetime_module: ?*Module = null,
    dt_tzinfo_class: ?*@import("../object/class.zig").Class = null,
    dt_timedelta_class: ?*@import("../object/class.zig").Class = null,
    dt_date_class: ?*@import("../object/class.zig").Class = null,
    dt_time_class: ?*@import("../object/class.zig").Class = null,
    dt_datetime_class: ?*@import("../object/class.zig").Class = null,
    dt_timezone_class: ?*@import("../object/class.zig").Class = null,
    zoneinfo_module: ?*Module = null,
    zoneinfo_class: ?*@import("../object/class.zig").Class = null,
    zoneinfo_not_found_class: ?*@import("../object/class.zig").Class = null,
    zoneinfo_cache: ?*@import("../object/dict.zig").Dict = null,
    csv_module: ?*Module = null,
    urlparse_module: ?*Module = null,
    urllib_module: ?*Module = null,
    zlib_module: ?*Module = null,
    binascii_module: ?*Module = null,
    hmac_module: ?*Module = null,
    secrets_module: ?*Module = null,
    uuid_module: ?*Module = null,
    difflib_module: ?*Module = null,
    shlex_module: ?*Module = null,
    gzip_module: ?*Module = null,
    fnmatch_module: ?*Module = null,
    statistics_module: ?*Module = null,
    calendar_module: ?*Module = null,
    calendar_first_weekday: i64 = 0,
    calendar_day_class: ?*@import("../object/class.zig").Class = null,
    calendar_month_class: ?*@import("../object/class.zig").Class = null,
    calendar_calendar_class: ?*@import("../object/class.zig").Class = null,
    calendar_text_class: ?*@import("../object/class.zig").Class = null,
    calendar_html_class: ?*@import("../object/class.zig").Class = null,
    calendar_locale_text_class: ?*@import("../object/class.zig").Class = null,
    calendar_locale_html_class: ?*@import("../object/class.zig").Class = null,
    calendar_illegal_month_class: ?*@import("../object/class.zig").Class = null,
    calendar_illegal_weekday_class: ?*@import("../object/class.zig").Class = null,
    pprint_module: ?*Module = null,
    html_module: ?*Module = null,
    sys_module: ?*Module = null,
    warnings_module: ?*Module = null,
    os_module: ?*Module = null,
    threading_module: ?*Module = null,
    templatelib_module: ?*Module = null,
    threading_lock_class: ?*@import("../object/class.zig").Class = null,
    threading_rlock_class: ?*@import("../object/class.zig").Class = null,
    threading_thread_class: ?*@import("../object/class.zig").Class = null,
    threading_event_class: ?*@import("../object/class.zig").Class = null,
    threading_sem_class: ?*@import("../object/class.zig").Class = null,
    threading_cond_class: ?*@import("../object/class.zig").Class = null,
    threading_barrier_class: ?*@import("../object/class.zig").Class = null,
    threading_local_class: ?*@import("../object/class.zig").Class = null,
    string_formatter_class: ?*@import("../object/class.zig").Class = null,
    string_template_class: ?*@import("../object/class.zig").Class = null,
    threading_main_thread: ?*@import("../object/instance.zig").Instance = null,
    sys_stream_class: ?*@import("../object/class.zig").Class = null,
    traceback_class: ?*@import("../object/class.zig").Class = null,
    frame_class: ?*@import("../object/class.zig").Class = null,
    code_class: ?*@import("../object/class.zig").Class = null,
    template_class: ?*@import("../object/class.zig").Class = null,
    interpolation_class: ?*@import("../object/class.zig").Class = null,
    /// Currently-handled exception, set by PUSH_EXC_INFO and restored
    /// by POP_EXCEPT. Powers `sys.exc_info()` and the implicit
    /// `__context__` attached to exceptions raised inside an except.
    handling_exc: ?Value = null,
    recursion_limit: i64 = 1000,
    current_frame: ?*@import("frame.zig").Frame = null,
    difflib_seqmatch_class: ?*@import("../object/class.zig").Class = null,
    difflib_match_class: ?*@import("../object/class.zig").Class = null,
    difflib_differ_class: ?*@import("../object/class.zig").Class = null,
    textwrap_wrapper_class: ?*@import("../object/class.zig").Class = null,
    re_pattern_class: ?*@import("../object/class.zig").Class = null,
    re_match_class: ?*@import("../object/class.zig").Class = null,
    re_error_class: ?*@import("../object/class.zig").Class = null,
    io_stringio_class: ?*@import("../object/class.zig").Class = null,
    io_bytesio_class: ?*@import("../object/class.zig").Class = null,
    file_class: ?*@import("../object/class.zig").Class = null,
    hashlib_hash_class: ?*@import("../object/class.zig").Class = null,
    csv_writer_class: ?*@import("../object/class.zig").Class = null,
    csv_dict_writer_class: ?*@import("../object/class.zig").Class = null,
    urlparse_result_class: ?*@import("../object/class.zig").Class = null,
    hmac_class: ?*@import("../object/class.zig").Class = null,
    uuid_class: ?*@import("../object/class.zig").Class = null,
    primitive_classes: std.StringHashMapUnmanaged(*@import("../object/class.zig").Class) = .empty,
    /// Pre-registered user-module code objects, keyed by module name.
    /// Populated by the embedder (the test harness pre-registers every
    /// helper `.pyc`; the CLI pre-registers siblings of the entry
    /// `.pyc`). Looked up on IMPORT_NAME after builtins.
    module_codes: std.StringHashMapUnmanaged(ModuleCode) = .empty,
    /// Already-executed user modules, keyed by name. First import runs
    /// the body; subsequent imports return the cached `*Module` so
    /// identity holds (e.g. `import x as a; import x as b; a is b`).
    user_modules: std.StringHashMapUnmanaged(*Module) = .empty,
    /// The synthetic class returned by `type(some_module)`. Built
    /// lazily so scripts that never call `type()` on a module pay
    /// nothing. CPython's spelling of this is `types.ModuleType`; we
    /// expose it directly off `type()` because that's all the
    /// fixtures probe.
    module_type: ?*@import("../object/class.zig").Class = null,
    /// Same lazy-cached pattern for `type(complex_val)` so the result
    /// has `.__name__ == "complex"`. The builtin `complex` name itself
    /// stays bound to a constructor function; this class is only
    /// reachable via `type()`.
    complex_type: ?*@import("../object/class.zig").Class = null,
    /// Lazy `type(set_val)` / `type(frozenset_val)` classes. The
    /// builtin `set`/`frozenset` names are constructors; these are
    /// only the synthetic classes that `type()` returns.
    set_type: ?*@import("../object/class.zig").Class = null,
    frozenset_type: ?*@import("../object/class.zig").Class = null,
    bytearray_type: ?*@import("../object/class.zig").Class = null,
    bytes_type: ?*@import("../object/class.zig").Class = null,
    memoryview_type: ?*@import("../object/class.zig").Class = null,
    ellipsis_type: ?*@import("../object/class.zig").Class = null,
    not_implemented_type: ?*@import("../object/class.zig").Class = null,
    slice_type: ?*@import("../object/class.zig").Class = null,

    pub const ModuleCode = struct { code: *Code, is_package: bool };

    pub fn init(
        allocator: std.mem.Allocator,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !Interp {
        return .{
            .allocator = allocator,
            .stdout = stdout,
            .stderr = stderr,
            .globals = try Dict.init(allocator),
            .builtins = try Dict.init(allocator),
        };
    }

    pub fn primitiveClass(self: *Interp, name: []const u8) !*@import("../object/class.zig").Class {
        const ClassT = @import("../object/class.zig").Class;
        if (self.primitive_classes.get(name)) |c| return c;
        const owned_name = try self.allocator.dupe(u8, name);
        const cls = try ClassT.init(self.allocator, owned_name, &.{}, try Dict.init(self.allocator));
        try self.primitive_classes.put(self.allocator, owned_name, cls);
        return cls;
    }

    pub fn installBuiltins(self: *Interp) !void {
        try builtins.install(self);
    }

    pub fn registerBuiltin(self: *Interp, name: []const u8, func: BuiltinFnPtr) !void {
        const f = try self.allocator.create(BuiltinFn);
        f.* = .{ .name = name, .func = func };
        try self.builtins.setStr(self.allocator, name, Value{ .builtin_fn = f });
    }

    pub fn registerBuiltinKw(
        self: *Interp,
        name: []const u8,
        func: BuiltinFnPtr,
        kw_func: value_mod.BuiltinKwFnPtr,
    ) !void {
        const f = try self.allocator.create(BuiltinFn);
        f.* = .{ .name = name, .func = func, .kw_func = kw_func };
        try self.builtins.setStr(self.allocator, name, Value{ .builtin_fn = f });
    }

    pub fn run(self: *Interp, code: *Code) !Value {
        // Module frame: locals alias globals at the module level.
        const frame = try Frame.init(self.allocator, code, self.globals, self.builtins, self.globals);
        defer frame.deinit(self.allocator);

        // Seed __name__ = "__main__" for scripts that test it.
        const name_str_mod = @import("../object/string.zig");
        const name_val = try name_str_mod.Str.init(self.allocator, "__main__");
        try self.globals.setStr(self.allocator, "__name__", Value{ .str = name_val });

        return try dispatch.run(self, frame);
    }

    pub fn nameError(self: *Interp, name: []const u8) !void {
        try self.stderr.print("NameError: name '{s}' is not defined\n", .{name});
        try self.stderr.flush();
    }

    pub fn attributeError(self: *Interp, type_name: []const u8, attr: []const u8) !void {
        try self.stderr.print(
            "AttributeError: '{s}' object has no attribute '{s}'\n",
            .{ type_name, attr },
        );
        try self.stderr.flush();
    }

    pub fn indexError(self: *Interp, msg: []const u8) !void {
        try self.stderr.print("IndexError: {s}\n", .{msg});
        try self.stderr.flush();
    }

    pub fn typeError(self: *Interp, msg: []const u8) !void {
        try self.stderr.print("TypeError: {s}\n", .{msg});
        try self.stderr.flush();
    }

    /// Build an exception instance of `cls_name` with `args = (msg,)`
    /// and stash it as `current_exc`. The caller still has to return
    /// `error.PyException` to kick the dispatch unwind.
    pub fn raisePy(self: *Interp, cls_name: []const u8, msg: []const u8) !void {
        const cls_val = self.builtins.getStr(cls_name) orelse {
            try self.stderr.print("zag: missing exception class '{s}'\n", .{cls_name});
            try self.stderr.flush();
            return error.NameError;
        };
        if (cls_val != .class) return error.TypeError;
        const inst = try Instance.init(self.allocator, cls_val.class);
        const t = try Tuple.init(self.allocator, 1);
        const s = try Str.init(self.allocator, msg);
        t.items[0] = Value{ .str = s };
        try inst.dict.setStr(self.allocator, "args", Value{ .tuple = t });
        self.current_exc = Value{ .instance = inst };
    }

    /// Like `raisePy` but takes a Value for `args[0]` (e.g., the
    /// generator's return value flowing into StopIteration).
    pub fn raisePyValue(self: *Interp, cls_name: []const u8, val: Value) !void {
        const cls_val = self.builtins.getStr(cls_name) orelse {
            try self.stderr.print("zag: missing exception class '{s}'\n", .{cls_name});
            try self.stderr.flush();
            return error.NameError;
        };
        if (cls_val != .class) return error.TypeError;
        const inst = try Instance.init(self.allocator, cls_val.class);
        const t = try Tuple.init(self.allocator, 1);
        t.items[0] = val;
        try inst.dict.setStr(self.allocator, "args", Value{ .tuple = t });
        self.current_exc = Value{ .instance = inst };
    }

    pub fn importError(self: *Interp, name: []const u8) !void {
        try self.stderr.print("ImportError: no module named '{s}'\n", .{name});
        try self.stderr.flush();
    }

    /// Register a pre-loaded `.pyc` so that `import name` finds it.
    /// The body isn't run until something actually imports it.
    /// `is_package` is true for `__init__.py` modules, which then host
    /// submodule attributes.
    pub fn registerModuleCode(
        self: *Interp,
        name: []const u8,
        code: *Code,
        is_package: bool,
    ) !void {
        try self.module_codes.put(self.allocator, name, .{ .code = code, .is_package = is_package });
    }

    /// Load a single (non-dotted) module from its registered code,
    /// caching the result. Returns null if not registered. Internal
    /// helper for `loadModuleChain` — callers wanting dotted-name
    /// resolution (the import opcodes) go through that instead.
    fn loadOneModule(self: *Interp, name: []const u8) !?*Module {
        if (self.user_modules.get(name)) |m| return m;
        const reg = self.module_codes.get(name) orelse return null;
        const mod_globals = try Dict.init(self.allocator);
        const name_val = try Str.init(self.allocator, name);
        try mod_globals.setStr(self.allocator, "__name__", Value{ .str = name_val });
        // CPython sets __package__ to the parent dotted name (or "" at
        // top level). Packages set it to their own name. Relative
        // imports inside the body read this back.
        const dot = std.mem.lastIndexOfScalar(u8, name, '.');
        const pkg: []const u8 = if (reg.is_package)
            name
        else if (dot) |d| name[0..d] else "";
        const pkg_val = try Str.init(self.allocator, pkg);
        try mod_globals.setStr(self.allocator, "__package__", Value{ .str = pkg_val });
        const m = try Module.init(self.allocator, name);
        m.attrs = mod_globals;
        m.is_package = reg.is_package;
        // Insert before running the body so a circular re-import
        // returns the partially-populated module rather than looping.
        try self.user_modules.put(self.allocator, name, m);
        const frame = try Frame.init(self.allocator, reg.code, mod_globals, self.builtins, mod_globals);
        defer frame.deinit(self.allocator);
        _ = dispatch.run(self, frame) catch |err| {
            _ = self.user_modules.remove(name);
            return err;
        };
        return m;
    }

    pub const Chain = struct { top: *Module, innermost: *Module };

    /// Load every prefix of a dotted name, binding each leaf as an
    /// attribute on its parent. Returns the outermost (`top`) and
    /// innermost (`innermost`) modules — IMPORT_NAME picks one based
    /// on whether the fromlist is empty.
    pub fn loadModuleChain(self: *Interp, qname: []const u8) !?Chain {
        var top: ?*Module = null;
        var innermost: ?*Module = null;
        var i: usize = 0;
        while (true) {
            const next = std.mem.indexOfScalarPos(u8, qname, i, '.');
            const end = next orelse qname.len;
            const sub = qname[0..end];
            const m = (try self.loadOneModule(sub)) orelse return null;
            if (top == null) top = m;
            if (innermost) |parent| {
                try parent.attrs.setStr(self.allocator, sub[i..end], Value{ .module = m });
            }
            innermost = m;
            if (next == null) break;
            i = next.? + 1;
        }
        return Chain{ .top = top.?, .innermost = innermost.? };
    }

    /// Hand back the builtin module of the given name. Cached on
    /// first access so identity holds across re-imports.
    pub fn getBuiltinModule(self: *Interp, name: []const u8) ?*Module {
        if (std.mem.eql(u8, name, "asyncio")) {
            if (self.asyncio_module) |m| return m;
            const m = asyncio_mod.build(self) catch return null;
            self.asyncio_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "importlib")) {
            if (self.importlib_module) |m| return m;
            const m = importlib_mod.build(self) catch return null;
            self.importlib_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "functools")) {
            if (self.functools_module) |m| return m;
            const m = functools_mod.build(self) catch return null;
            self.functools_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "itertools")) {
            if (self.itertools_module) |m| return m;
            const m = itertools_mod.build(self) catch return null;
            self.itertools_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "operator")) {
            if (self.operator_module) |m| return m;
            const m = operator_mod.build(self) catch return null;
            self.operator_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "collections")) {
            if (self.collections_module) |m| return m;
            const m = collections_mod.build(self) catch return null;
            self.collections_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "collections.abc")) {
            if (self.collections_abc_module) |m| return m;
            const m = collections_abc_mod.build(self) catch return null;
            self.collections_abc_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "math")) {
            if (self.math_module) |m| return m;
            const m = math_mod.build(self) catch return null;
            self.math_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "heapq")) {
            if (self.heapq_module) |m| return m;
            const m = heapq_mod.build(self) catch return null;
            self.heapq_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "bisect")) {
            if (self.bisect_module) |m| return m;
            const m = bisect_mod.build(self) catch return null;
            self.bisect_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "array")) {
            if (self.array_module) |m| return m;
            const m = array_mod.build(self) catch return null;
            self.array_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "weakref")) {
            if (self.weakref_module) |m| return m;
            const m = weakref_mod.build(self) catch return null;
            self.weakref_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "random")) {
            if (self.random_module) |m| return m;
            const m = random_mod.build(self) catch return null;
            self.random_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "json")) {
            if (self.json_module) |m| return m;
            const m = json_mod.build(self) catch return null;
            self.json_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "string")) {
            if (self.string_module) |m| return m;
            const m = string_mod.build(self) catch return null;
            self.string_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "string.templatelib")) {
            if (self.templatelib_module) |m| return m;
            const m = @import("templatelib_mod.zig").build(self) catch return null;
            self.templatelib_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "copy")) {
            if (self.copy_module) |m| return m;
            const m = copy_mod.build(self) catch return null;
            self.copy_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "re")) {
            if (self.re_module) |m| return m;
            const m = re_mod.build(self) catch return null;
            self.re_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "io")) {
            if (self.io_module) |m| return m;
            const m = io_mod.build(self) catch return null;
            self.io_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "hashlib")) {
            if (self.hashlib_module) |m| return m;
            const m = hashlib_mod.build(self) catch return null;
            self.hashlib_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "base64")) {
            if (self.base64_module) |m| return m;
            const m = base64_mod.build(self) catch return null;
            self.base64_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "textwrap")) {
            if (self.textwrap_module) |m| return m;
            const m = textwrap_mod.build(self) catch return null;
            self.textwrap_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "unicodedata")) {
            if (self.unicodedata_module) |m| return m;
            const m = unicodedata_mod.build(self) catch return null;
            self.unicodedata_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "stringprep")) {
            if (self.stringprep_module) |m| return m;
            const m = stringprep_mod.build(self) catch return null;
            self.stringprep_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "readline")) {
            if (self.readline_module) |m| return m;
            const m = readline_mod.build(self) catch return null;
            self.readline_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "rlcompleter")) {
            if (self.rlcompleter_module) |m| return m;
            const m = rlcompleter_mod.build(self) catch return null;
            self.rlcompleter_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "struct")) {
            if (self.struct_module) |m| return m;
            const m = struct_mod.build(self) catch return null;
            self.struct_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "codecs")) {
            if (self.codecs_module) |m| return m;
            const m = codecs_mod.build(self) catch return null;
            self.codecs_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "datetime")) {
            if (self.datetime_module) |m| return m;
            const m = datetime_mod.build(self) catch return null;
            self.datetime_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "zoneinfo")) {
            if (self.zoneinfo_module) |m| return m;
            const m = zoneinfo_mod.build(self) catch return null;
            self.zoneinfo_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "csv")) {
            if (self.csv_module) |m| return m;
            const m = csv_mod.build(self) catch return null;
            self.csv_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "urllib.parse")) {
            if (self.urlparse_module) |m| return m;
            const m = urlparse_mod.build(self) catch return null;
            self.urlparse_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "urllib")) {
            if (self.urllib_module) |m| return m;
            const m = urlparse_mod.buildUrllibPackage(self) catch return null;
            self.urllib_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "zlib")) {
            if (self.zlib_module) |m| return m;
            const m = zlib_mod.build(self) catch return null;
            self.zlib_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "binascii")) {
            if (self.binascii_module) |m| return m;
            const m = binascii_mod.build(self) catch return null;
            self.binascii_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "hmac")) {
            if (self.hmac_module) |m| return m;
            const m = hmac_mod.build(self) catch return null;
            self.hmac_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "secrets")) {
            if (self.secrets_module) |m| return m;
            const m = secrets_mod.build(self) catch return null;
            self.secrets_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "uuid")) {
            if (self.uuid_module) |m| return m;
            const m = uuid_mod.build(self) catch return null;
            self.uuid_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "difflib")) {
            if (self.difflib_module) |m| return m;
            const m = difflib_mod.build(self) catch return null;
            self.difflib_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "shlex")) {
            if (self.shlex_module) |m| return m;
            const m = shlex_mod.build(self) catch return null;
            self.shlex_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "gzip")) {
            if (self.gzip_module) |m| return m;
            const m = gzip_mod.build(self) catch return null;
            self.gzip_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "fnmatch")) {
            if (self.fnmatch_module) |m| return m;
            const m = fnmatch_mod.build(self) catch return null;
            self.fnmatch_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "statistics")) {
            if (self.statistics_module) |m| return m;
            const m = statistics_mod.build(self) catch return null;
            self.statistics_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "calendar")) {
            if (self.calendar_module) |m| return m;
            const m = calendar_mod.build(self) catch return null;
            self.calendar_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "pprint")) {
            if (self.pprint_module) |m| return m;
            const m = pprint_mod.build(self) catch return null;
            self.pprint_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "html")) {
            if (self.html_module) |m| return m;
            const m = html_mod.build(self) catch return null;
            self.html_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "sys")) {
            if (self.sys_module) |m| return m;
            const m = sys_mod.build(self) catch return null;
            self.sys_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "warnings")) {
            if (self.warnings_module) |m| return m;
            const m = @import("warnings_mod.zig").build(self) catch return null;
            self.warnings_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "os")) {
            if (self.os_module) |m| return m;
            const m = @import("os_mod.zig").build(self) catch return null;
            self.os_module = m;
            return m;
        }
        if (std.mem.eql(u8, name, "threading")) {
            if (self.threading_module) |m| return m;
            const m = @import("threading_mod.zig").build(self) catch return null;
            self.threading_module = m;
            return m;
        }
        return null;
    }

    pub fn unsupportedOpcode(self: *Interp, opcode: u8, ip: u32) !void {
        const op = @import("../op/opcode.zig");
        try self.stderr.print(
            "zag: unsupported opcode {d} ({s}) at ip={d}\n",
            .{ opcode, op.opcodeName(opcode), ip },
        );
        try self.stderr.flush();
    }
};
