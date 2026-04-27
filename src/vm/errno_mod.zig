//! `errno` module: POSIX error constants (Linux values) + errorcode dict.

const std = @import("std");
const value_mod = @import("../object/value.zig");
const Value = value_mod.Value;
const BuiltinFn = value_mod.BuiltinFn;
const Module = @import("../object/module.zig").Module;
const Dict = @import("../object/dict.zig").Dict;
const Str = @import("../object/string.zig").Str;
const Interp = @import("interp.zig").Interp;

const errorcodes = [_]struct { []const u8, i64 }{
    .{ "EPERM",           1   },
    .{ "ENOENT",          2   },
    .{ "ESRCH",           3   },
    .{ "EINTR",           4   },
    .{ "EIO",             5   },
    .{ "ENXIO",           6   },
    .{ "E2BIG",           7   },
    .{ "ENOEXEC",         8   },
    .{ "EBADF",           9   },
    .{ "ECHILD",          10  },
    .{ "EAGAIN",          11  },
    .{ "ENOMEM",          12  },
    .{ "EACCES",          13  },
    .{ "EFAULT",          14  },
    .{ "EBUSY",           16  },
    .{ "EEXIST",          17  },
    .{ "EXDEV",           18  },
    .{ "ENODEV",          19  },
    .{ "ENOTDIR",         20  },
    .{ "EISDIR",          21  },
    .{ "EINVAL",          22  },
    .{ "ENFILE",          23  },
    .{ "EMFILE",          24  },
    .{ "ENOTTY",          25  },
    .{ "EFBIG",           27  },
    .{ "ENOSPC",          28  },
    .{ "ESPIPE",          29  },
    .{ "EROFS",           30  },
    .{ "EMLINK",          31  },
    .{ "EPIPE",           32  },
    .{ "EDOM",            33  },
    .{ "ERANGE",          34  },
    .{ "EDEADLK",         35  },
    .{ "ENAMETOOLONG",    36  },
    .{ "ENOLCK",          37  },
    .{ "ENOSYS",          38  },
    .{ "ENOTEMPTY",       39  },
    .{ "ELOOP",           40  },
    .{ "ENOMSG",          42  },
    .{ "EIDRM",           43  },
    .{ "ENOSTR",          60  },
    .{ "ENODATA",         61  },
    .{ "ETIME",           62  },
    .{ "ENOSR",           63  },
    .{ "EREMOTE",         66  },
    .{ "ENOLINK",         67  },
    .{ "EPROTO",          71  },
    .{ "EMULTIHOP",       72  },
    .{ "EBADMSG",         74  },
    .{ "EOVERFLOW",       75  },
    .{ "EILSEQ",          84  },
    .{ "EUSERS",          87  },
    .{ "ENOTSOCK",        88  },
    .{ "EDESTADDRREQ",    89  },
    .{ "EMSGSIZE",        90  },
    .{ "EPROTOTYPE",      91  },
    .{ "ENOPROTOOPT",     92  },
    .{ "EPROTONOSUPPORT", 93  },
    .{ "ESOCKTNOSUPPORT", 94  },
    .{ "EOPNOTSUPP",      95  },
    .{ "EAFNOSUPPORT",    97  },
    .{ "EADDRINUSE",      98  },
    .{ "EADDRNOTAVAIL",   99  },
    .{ "ENETDOWN",        100 },
    .{ "ENETUNREACH",     101 },
    .{ "ENETRESET",       102 },
    .{ "ECONNABORTED",    103 },
    .{ "ECONNRESET",      104 },
    .{ "ENOBUFS",         105 },
    .{ "EISCONN",         106 },
    .{ "ENOTCONN",        107 },
    .{ "ESHUTDOWN",       108 },
    .{ "ETOOMANYREFS",    109 },
    .{ "ETIMEDOUT",       110 },
    .{ "ECONNREFUSED",    111 },
    .{ "EHOSTDOWN",       112 },
    .{ "EHOSTUNREACH",    113 },
    .{ "EALREADY",        114 },
    .{ "EINPROGRESS",     115 },
    .{ "ESTALE",          116 },
    .{ "EDQUOT",          122 },
    .{ "ECANCELED",       125 },
    .{ "EOWNERDEAD",      130 },
    .{ "ENOTRECOVERABLE", 131 },
};

pub fn build(interp: *Interp) !*Module {
    const a = interp.allocator;
    const m = try Module.init(a, "errno");

    const errorcode = try Dict.init(a);

    for (errorcodes) |pair| {
        const name = pair[0];
        const code = pair[1];
        try m.attrs.setStr(a, name, Value{ .small_int = code });
        const key = Value{ .small_int = code };
        const val = Value{ .str = try Str.init(a, name) };
        try errorcode.setKey(a, key, val);
    }

    // Aliases
    try m.attrs.setStr(a, "EWOULDBLOCK", Value{ .small_int = 11 }); // == EAGAIN
    try m.attrs.setStr(a, "EDEADLOCK",   Value{ .small_int = 35 }); // == EDEADLK
    try m.attrs.setStr(a, "ENOTSUP",     Value{ .small_int = 95 }); // == EOPNOTSUPP

    try m.attrs.setStr(a, "errorcode", Value{ .dict = errorcode });
    return m;
}
