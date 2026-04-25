# `src/lib/re` — regex engine spec

A small, self-contained regex engine that lives under `src/lib/re/`
and is consumed by `src/vm/re_mod.zig` (the Python `re` module
bridge). The engine itself knows nothing about `Value`, `Interp`, or
the rest of the VM — it works on `[]const u8` and emits its own match
type. The bridge wraps the result in Python objects.

## Scope

This is a **pinhole** engine: it implements the subset of Python's
`re` exercised by fixture 65 (and the fixture-66 stress that lands
next), not all of CPython's `re`. Scope is fixed by the failing
prints in `tests/fixtures/65_json_re_string_copy.py` and its sibling
expected output. Anything outside that is explicitly out of scope and
should error rather than silently return wrong results.

### In scope

Pattern syntax:

| Feature | Examples |
| --- | --- |
| Literal bytes | `cat`, `hello` |
| Any-char | `.` (no newline by default; matches newline under `re.DOTALL`) |
| Anchors | `^`, `$` (both default to whole-input; `^`/`$` per-line under `re.MULTILINE`) |
| Char classes | `\d` `\D` `\w` `\W` `\s` `\S`, `[abc]`, `[a-z]`, `[^abc]`, `[\dA-F]` |
| Repetition | `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}` (greedy) |
| Lazy repetition | `*?`, `+?`, `??`, `{n,m}?` |
| Grouping | `(...)`, `(?:...)` (non-capturing), `(?P<name>...)` |
| Alternation | `a|b|c` |
| Backreferences in pattern | `\1` … `\9` |
| Escapes | `\.`, `\+`, `\\`, `\n`, `\t`, `\r`, `\(`, `\)`, `\[`, `\]`, `\{`, `\}`, `\|`, `\^`, `\$`, `\?`, `\*` |

Flags:

| Flag | Effect |
| --- | --- |
| `re.IGNORECASE` (`I`) | ASCII-only case folding for literals + char classes |
| `re.MULTILINE` (`M`) | `^` matches after `\n`; `$` matches before `\n` |
| `re.DOTALL` (`S`) | `.` matches `\n` |

Engine-side API surface:

```zig
const re = @import("lib/re/re.zig");

const Pattern = re.Pattern;
const Match   = re.Match;       // owns nothing; views into input
const Flags   = re.Flags;       // packed struct of bools

pub fn compile(allocator, pattern: []const u8, flags: Flags) !*Pattern;
pub fn deinit(pattern: *Pattern, allocator) void;

// Each returns null if no match. `Match` records the overall span
// plus per-group spans (group 0 = the whole match).
pub fn match(pattern: *Pattern, input: []const u8) ?Match;        // anchored at 0
pub fn search(pattern: *Pattern, input: []const u8, start: usize) ?Match;
pub fn fullmatch(pattern: *Pattern, input: []const u8) ?Match;    // must consume all

// Iterating findall/finditer is just `search(pattern, input, last_end)`
// in a loop; no need for a dedicated iterator type.

pub fn groupName(pattern: *Pattern, idx: usize) ?[]const u8;      // named groups
pub fn groupIndex(pattern: *Pattern, name: []const u8) ?usize;
pub fn groupCount(pattern: *Pattern) usize;                       // excluding group 0
```

`Match` shape:

```zig
pub const Span = struct { start: usize, end: usize };  // half-open, byte indices

pub const Match = struct {
    spans: []Span,           // index 0 = whole match; len = group_count + 1
    // A group that did not participate in the match (e.g. `(a)|(b)`
    // where the second branch matched) is encoded as start == end == NPOS.
};
pub const NPOS: usize = std.math.maxInt(usize);
```

### Substitution helper

Replacement-string parsing (`\1`…`\9`, `\g<name>`, `\g<n>`, `\\`, and
literal characters) is also under `src/lib/re/`, in `replace.zig`.
Callable replacements stay on the VM side — the bridge invokes the
Python callable per match and stitches the result with the engine's
`search` loop.

### Out of scope (explicitly)

- Unicode property classes (`\p{…}`); `\d`/`\w`/`\s` are ASCII-only.
- Possessive quantifiers (`*+`, `++`).
- Lookaround (`(?=…)`, `(?!…)`, `(?<=…)`, `(?<!…)`).
- Atomic groups (`(?>…)`).
- Conditional groups (`(?(id)yes|no)`).
- Inline flags inside the pattern (`(?i)…`); flags come through the
  argument only.
- `re.VERBOSE`, `re.ASCII`, `re.LOCALE`, `re.UNICODE`, `re.DEBUG`.
- `\b` / `\B` word-boundary assertions. Add only if a fixture needs
  them.

Each excluded feature should produce a `error.UnsupportedRegex` at
compile time, not a silent mismatch.

## File layout

```
src/lib/re/
├── SPEC.md          (this file)
├── re.zig           public façade: compile / match / search / fullmatch
├── parse.zig        pattern -> AST
├── ast.zig          AST node definitions
├── compile.zig      AST -> bytecode (program)
├── program.zig      bytecode opcode definitions
├── exec.zig         the matcher (backtracking VM over the bytecode)
├── replace.zig      replacement-string parser + applier
└── tests.zig        zig-level unit tests, hit from `zig build test`
```

`src/vm/re_mod.zig` will be the Python bridge: it owns the
`*Pattern`, builds `Value{ .instance = ... }` match objects with
`group`/`groups`/`groupdict`/`span`/`start`/`end` methods, and routes
`re.findall`/`finditer`/`split`/`sub`/`subn`/`compile`/`escape` into
the engine. The bridge does **not** know about regex internals.

## Algorithm

The matcher is a **backtracking VM** over a small bytecode. Thompson
construction (linear-time NFA) would be more elegant but doesn't
support backreferences, which the fixture's `\g<…>` substitution
relies on indirectly (we need them in patterns soon enough), so a
recursive-descent matcher with explicit state stacks is simpler to
own.

### Bytecode

```zig
pub const Op = enum {
    char,         // arg: u8 — literal byte
    char_ci,      // arg: u8 — literal byte, case-insensitive
    any,          // matches one byte (newline only when DOTALL)
    class,        // arg: class_id — bitset of 256 bits
    bol, eol,     // ^ and $ (MULTILINE-aware)
    backref,      // arg: group_id
    save,         // arg: 2*group_id + (0 start | 1 end)
    jump,         // arg: pc
    split,        // args: pc_a, pc_b — try a first, then b on backtrack
    split_lazy,   // args: pc_a, pc_b — try b first, then a on backtrack
    match,        // accept
};
```

Repetitions compile down to `split` + `jump` loops. Greedy `x*`
becomes `L: split L_body, L_end; L_body: <x>; jump L; L_end: …`;
lazy `x*?` swaps the order via `split_lazy`.

### Backtracking state

```zig
const Thread = struct {
    pc: usize,
    sp: usize,
    saves: [2 * max_groups]usize,
};
```

The matcher runs a single thread, pushing alternatives onto an
explicit `std.ArrayList(Thread)` stack on every `split`. On a dead
end it pops the most recent alternative. Worst-case exponential, but
for the fixture inputs it's a few microseconds.

### Memory ownership

- `Pattern` owns its program slice, group-name table, and class
  bitsets — all freed in `deinit`.
- `Match.spans` is allocated by the matcher and handed to the caller.
  The bridge frees it when the Python match instance is collected.
- The matcher uses an arena for its scratch state stack and tears it
  down before returning.

## Replacement strings

`replace.zig` parses the replacement template once into a list of
literal-or-group references, then applies them per match. References:

- `\1` … `\9` → group N (1-indexed).
- `\g<N>` → group N (any positive integer).
- `\g<name>` → named group.
- `\\` → literal `\`.
- `\n`, `\t`, `\r` → literal control byte. Other `\<char>` sequences
  follow CPython: `\<x>` becomes literal `\<x>` rather than a syntax
  error, to keep the fixture quiet.

If a referenced group did not participate in the match, the
substitution emits an empty string (CPython raises in some cases; we
emit empty until a fixture forces tighter behavior).

## Validation

- `tests.zig` covers each in-scope feature with a small
  case (`compile + match + spans`).
- The integration test (fixture 65 + 66) is the user-facing
  validation; CI on six platforms gates the merge.
- No fuzz harness yet — add one only if a corpus surfaces.

## Future work

- Once fixture 67+ pulls in word boundaries, lookaround, or inline
  flags, extend the bytecode rather than reaching for an external
  library.
- If runtime cost becomes visible, swap the inner matcher for a
  Thompson NFA when no backrefs are present, falling back to the
  current VM only for patterns that use them.
