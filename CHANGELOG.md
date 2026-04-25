# Changelog

All notable changes to zag are recorded here. The format follows
[Keep a Changelog 1.1](https://keepachangelog.com/en/1.1.0/). Once
zag reaches 1.0 the project will follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); until
then, expect minor version bumps to sometimes include breaking
changes.

## [Unreleased]

## [0.0.9] - 2026-04-25

### Added

- `08_classes` fixture, lifted verbatim from goipy's testdata, running
  byte-equal against CPython 3.14 stdout. Covers `class` definition,
  `__init__`, attribute access, instance methods with `self` binding,
  single inheritance with method override, and `isinstance`.
- `Class` and `Instance` heap value arms. `Class` carries name, bases,
  namespace dict, and a precomputed MRO (single-inheritance only:
  self, then a dedup walk of `bases[i].mro`). `Instance` is a class
  pointer plus a per-instance attribute dict — no `__slots__` yet.
- `LOAD_BUILD_CLASS` pushes the `__build_class__` builtin. The
  builtin runs the class body function with a fresh locals dict and
  wraps the resulting namespace in a `Class`.
- `LOAD_LOCALS` pushes the active frame's locals dict, which the
  3.14 class-body prologue stashes into the `__classdict__` cell.
- `STORE_ATTR name` for `obj.x = v`. Writes land in the instance
  dict; setting attributes on a class itself isn't exercised by the
  fixture and isn't wired up.
- `LOAD_ATTR` extended for instances and classes. The lookup order
  on an instance is the instance dict, then the class MRO; on a
  class it's the MRO directly. The 3.14 method-form (low oparg bit)
  pushes `(method, self)` so the existing bound-method branch in
  `CALL` threads `self` through as `args[0]` without any new
  calling-convention plumbing.
- `CALL` on a `Class` instantiates: allocate an `Instance`, look up
  `__init__` on the class, and if present invoke it with the new
  instance as `args[0]`. Missing `__init__` is fine — the instance
  is returned as-is.
- `__build_class__` and `isinstance` builtins. `isinstance` walks
  the instance's class MRO looking for the target class pointer.
- `callPyFunction` grew a `locals_override` parameter so
  `__build_class__` can run a code object with a separate locals
  dict instead of the function default (locals == globals).

### Out of scope

- `super()`, descriptors, `__slots__`, metaclasses, `__new__`,
  multiple inheritance with C3 linearization. The fixture defines
  `__repr__` but never invokes it, so `repr()` / `str()` builtins
  weren't needed this round either.

## [0.0.8] - 2026-04-25

### Added

- `07_dicts` fixture, lifted verbatim from goipy's testdata, running
  byte-equal against CPython 3.14 stdout. Covers the rest of the
  dict surface: literal display, subscript read / write / delete,
  membership, `keys` / `values` / `get`, and a dict comprehension.
- `BUILD_MAP n`. The 3.14 form pops `2n` values laid out as
  alternating `k0, v0, k1, v1, ...`. zag still requires string
  keys; the dict implementation hasn't grown arbitrary-key support
  yet.
- `DELETE_SUBSCR` for `del d[k]`. Missing keys raise a
  `KeyError`-shaped diagnostic.
- `UNPACK_SEQUENCE n` for tuple/list operands. `STORE_FAST_STORE_FAST`
  with the high-nibble / low-nibble packed argument zag already uses
  for the two other paired fast-local opcodes.
- `MAP_ADD n` for the dict-comprehension append. The dict lives at
  `stack[sp - n]` after popping the value and key, mirroring the
  `LIST_APPEND` pattern.
- `dict` arms in `BINARY_OP 26` (subscript), `STORE_SUBSCR`, and
  `CONTAINS_OP`. Missing keys on read raise a `KeyError`-shaped
  diagnostic; out-of-membership returns `False` rather than raising,
  matching CPython.
- `dict.keys()`, `dict.values()`, and `dict.get()` (1-arg defaults
  to `None`, 2-arg uses the supplied default). All three return
  materialized lists rather than the CPython view objects, same
  pattern `items()` already uses.

### Changed

- `Value.writeRepr` for `dict` now renders the actual contents in
  insertion order (`{'x': 2, 'y': 4}`) instead of the `{...}`
  placeholder M1 left behind. The renderer hardcodes single-quoted
  string keys, which is enough for every fixture so far.

### Notes

- Non-string keys still raise TypeError. The general-key dict, like
  the `dict_keys` / `dict_values` / `dict_items` view objects, waits
  for a fixture that needs them.

## [0.0.7] - 2026-04-25

### Added

- `06_functions` fixture, lifted verbatim from goipy's testdata,
  running byte-equal against CPython 3.14 stdout. The fixture
  covers the whole user-defined-function story in one go: positional
  args, default args, keyword args, `*args` / `**kw`, recursion,
  and a closure (`make_adder`).
- `Function` value type holding `code`, `globals`, optional
  `defaults` tuple, optional `closure` tuple of cells.
- `Cell` value type -- a single mutable Value box. Cells back
  closure free vars; an outer function wraps a fast local in a
  cell, the inner function's frame receives the same `*Cell` via
  its closure tuple, and `LOAD_DEREF` / `STORE_DEREF` route through
  the cell.
- `MAKE_FUNCTION` and `SET_FUNCTION_ATTRIBUTE` (arg=1 defaults,
  arg=8 closure). Other attribute bits (kwdefaults, annotations)
  surface as TypeError until a fixture forces them.
- `BUILD_TUPLE`, `MAKE_CELL`, `LOAD_DEREF`, `STORE_DEREF`,
  `COPY_FREE_VARS`. `LOAD_FAST_LOAD_FAST` and the borrow variant
  `LOAD_FAST_BORROW_LOAD_FAST_BORROW` (high-nibble / low-nibble
  packed argument).
- `CALL_KW`. The names tuple gets popped first, then positional and
  kw values are split out of the same arg slice. Names that aren't
  formal parameters land in the `**kw` dict; names that are
  formals go into the matching fast slot.
- Real Python-function calling convention. `CALL` recognizes a
  `Function` callable, builds a new frame from its code, binds
  positional args, fills missing slots from `defaults`, packs
  overflow into the `*args` slot, and recurses into `dispatch.run`.
- `BINARY_OP` arg=0 (`+`, int+int and str+str) and arg=10 (`-`,
  int-int).
- Tuple ordering in `Value.order` -- lexicographic compare so
  `sorted({'x':10,'y':20}.items())` actually sorts deterministically.
- `dict.items()` method, returning a list of 2-tuples in insertion
  order. CPython returns a `dict_items` view; for the only consumer
  the fixture has -- `sorted(kw.items())` -- a list is
  indistinguishable.

### Notes

- `**kw` collects unmatched keyword arguments into a dict in
  insertion order (the same order a `dict_items` view would walk),
  which is what `sorted(kw.items())` then re-orders.
- Frame allocation per call is unbounded -- recursive calls leak
  per-frame fast / stack arrays through M1's deliberate process-exit
  cleanup. Real frame disposal arrives with the GC milestone.

## [0.0.6] - 2026-04-25

### Added

- `05_control_flow` fixture, lifted verbatim from goipy's testdata,
  running byte-equal against CPython 3.14 stdout. First fixture to
  drive `for i in range(...)` loops, `while` with an accumulator,
  and `break`/`continue` inside a `for`.
- `range()` builtin in 1-arg (`range(stop)`) and 2-arg
  (`range(start, stop)`) forms. The result is an `Iter` directly --
  for `for i in range(...):` that's indistinguishable from CPython's
  separate `range` sequence + `range_iterator` pair, and skipping
  the sequence object until a fixture forces it (len / contains /
  reuse) keeps the value union from gaining a tag it doesn't yet
  earn.
- `Iter.Kind.range` variant carrying `{ current, stop, step }`. Only
  positive step is in scope; the 3-arg form and negative ranges wait
  for a fixture.
- `BINARY_OP` arg=13 (`NB_INPLACE_ADD`) for `int + int`. Ints are
  immutable so the "in-place" path just returns a fresh `small_int`,
  matching what CPython does at the C level.
- `BINARY_OP` arg=6 (`NB_REMAINDER`) for `int % int`, with Python's
  floor-modulo semantics: the result takes the sign of the divisor,
  not the dividend (`@rem` in Zig takes the dividend's sign). The
  fixture only uses positive operands but the right answer is cheap.
- `GET_ITER` pass-through when handed something already iterable as
  an `Iter` -- needed because `range()` returns one directly and the
  emitted code is `range(); GET_ITER; FOR_ITER`.

### Notes

- `break` and `continue` need no new opcodes: the 3.14 compiler
  emits `POP_TOP; JUMP_FORWARD` past the loop's `END_FOR; POP_ITER`
  for `break`, and a plain `JUMP_BACKWARD` to `FOR_ITER` for
  `continue`. The exception-table cleanup region the compiler also
  emits never fires for plain `for`/`while` loops, so we still
  haven't needed an exception-table walker.
- `BINARY_OP` arg=0 (regular `+`) isn't wired yet; the fixture's
  adds are all augmented (`+=`, arg=13). The next fixture to force a
  bare `+` between non-constant ints will widen the table.

## [0.0.5] - 2026-04-25

### Added

- `04_lists` fixture, lifted verbatim from goipy's testdata, running
  byte-equal against CPython 3.14 stdout. First fixture to force a
  list comprehension end-to-end.
- `Iter` value type backing real Python iterators, with sources for
  `list` and `tuple`. `GET_ITER`, `FOR_ITER`, `END_FOR`, `POP_ITER`,
  `JUMP_BACKWARD`, and `LIST_APPEND` are wired through dispatch so
  the inlined comprehension frame the 3.14 compiler emits actually
  iterates.
- Fast-local opcodes: `LOAD_FAST`, `LOAD_FAST_BORROW`,
  `LOAD_FAST_CHECK`, `LOAD_FAST_AND_CLEAR`, `STORE_FAST`,
  `STORE_FAST_LOAD_FAST` (with the high-nibble/low-nibble packed
  argument).
- `STORE_SUBSCR` for `a[i] = value` on lists.
- `BINARY_OP` arg=5 (multiply) for `int * int`. Other operand type
  combinations still raise `TypeError`; the next fixture to force
  them will widen the table.
- List slicing: `a[i:j]` returns a new list. Step != 1 raises
  `TypeError`, matching M4's policy for strings.
- Four `list` methods, in `src/vm/listmethods.zig` behind the same
  name-keyed lookup `str` already uses: `append`, `extend`, `pop`
  (no-arg), `reverse`. `LOAD_ATTR`'s method form picks the right
  table by receiver tag.
- `sum()` and `sorted()` builtins. `sorted` uses `Value.order` and
  `std.sort.pdq`; `sum` walks any iterable made of ints/bools.

### Notes

- Comprehension cleanup is implemented by following the bytecode,
  not the exception table. The single try-region in this fixture
  is a NULL-cleanup that never fires; full exception-table walking
  arrives the first time a fixture forces it.
- `pop` is the no-arg form. `pop(i)` and `sort(key=...)` aren't in
  scope until a fixture needs them.

## [0.0.4] - 2026-04-25

### Added

- `03_strings` fixture, lifted verbatim from goipy's testdata,
  running byte-equal against CPython 3.14 stdout. This is the first
  fixture that exercises method calls on a runtime value rather
  than free functions and constants.
- `LOAD_ATTR` in the method-form path: when the low bit of the
  oparg is set, zag pops the receiver, looks up the method, and
  pushes `(method, self)`. The existing `CALL` arm's bound-method
  branch threads `self` through as `args[0]`, so no calling-
  convention plumbing was needed.
- `BINARY_OP` arg=26 (subscript). `s[i]`, `s[-1]`, and `s[i:j]` all
  work for `str`. Negative indices wrap; out-of-range raises
  `IndexError`. Lists subscript with int as well; slice on lists
  is deferred until `04_lists` forces it.
- `CONTAINS_OP` for `in` / `not in`. Substring check on `str`,
  linear scan on `list`/`tuple`.
- `BUILD_LIST` / `LIST_EXTEND`. The fixture relies on the
  `LIST_EXTEND` form CPython emits when a list literal contains
  only constants -- the compiler emits `BUILD_LIST 0; LIST_EXTEND
  1` over a constant tuple.
- Six `str` methods, each living in `src/vm/strmethods.zig`
  behind a small name-keyed table: `upper`, `replace`, `split`
  (no-arg form, ASCII-whitespace splitting), `join`, `startswith`,
  `endswith`.
- `len()` builtin, dispatching by tag: `str`, `bytes`, `tuple`,
  `list`, `dict`. Anything else raises `TypeError`.
- `Slice` value type plus real `TYPE_SLICE` decoding in the
  marshal reader. The previous behavior silently swallowed slices
  into `None`.
- `AttributeError` and `IndexError` plumbing on `Interp`.

### Notes

- ASCII fast paths in `str.upper` and `str` indexing. Codepoint-
  correct behavior is deferred until a fixture exercises a non-
  ASCII string.
- Slice with `step != 1` raises `TypeError` for now. The fixture
  only uses `slice(start, stop, None)`.

## [0.0.3] - 2026-04-25

### Added

- `02_comparisons` fixture, lifted verbatim from goipy's testdata,
  running byte-equal against CPython 3.14 stdout.
- Comparison and identity helpers on `Value`: `order` for
  `<`/`<=`/`>`/`>=`, `equals` for `==`/`!=`, and `identityEq` for
  `is`/`is not`. Numeric/bool ordering coerces `bool` to `0`/`1`,
  `str` orders lexicographically by bytes, mismatched non-orderable
  types compare unequal rather than raising (matching Python's
  `1 == "a"` -> `False`).
- New opcodes: `COMPARE_OP`, `IS_OP`, `TO_BOOL`, `COPY`, `SWAP`,
  `POP_JUMP_IF_FALSE`, `POP_JUMP_IF_TRUE`, `JUMP_FORWARD`. Together
  these cover both straight-line compares and the chained-compare
  desugaring (`a < b < c`) the 3.14 compiler emits.

### Changed

- `release` workflow no longer marks `v0.x.x` tags as prereleases.
  The 0.x line tracks an evolving API, but the binaries themselves
  are real releases. Existing `v0.0.1` and `v0.0.2` were retagged
  as full releases via `gh release edit --prerelease=false`.

## [0.0.2] - 2026-04-25

### Added

- `01_arithmetic` fixture, lifted verbatim from goipy's testdata,
  running byte-equal against CPython 3.14 stdout.
- `abs()` builtin, dispatching on `Value` tag: ints and floats
  negate in place, booleans coerce to `0`/`1`, anything else raises
  `TypeError` with CPython's wording.
- `build` workflow: cross-compiles every push and PR for five
  targets from a single Linux runner -- Linux x86_64 and aarch64
  (musl, static), macOS x86_64 and aarch64, Windows x86_64 (GNU).
- `release` workflow: on any `v*.*.*` tag, builds those same five
  targets, packages each as `zag-<tag>-<triple>.{tar.gz,zip}` with
  the binary plus `LICENSE` and `README.md`, and attaches the lot
  to an auto-generated GitHub release.

### Changed

- Float repr now appends a trailing `.0` to whole-valued floats so
  `print(10/4)` renders `2.5` and `print(1.0)` renders `1.0` rather
  than `1`, matching CPython's REPL-style distinction between `int`
  and `float`.
- `01_print_multiple` renumbered to `99_print_multiple` so the
  `01..09` slots stay aligned with goipy's fixture numbering; the
  print_multiple case isn't in goipy's set.
- Milestone summary moved out of `README.md` and into this
  changelog.

## [0.0.1] - 2026-04-25

### Added

- First public release: a Zig 0.16 interpreter that loads a CPython
  3.14 `.pyc` and runs it end to end.
- `.pyc` header validator (magic `0a 0d 0e 2b`) plus a marshal v5
  decoder covering every `TYPE_*` tag the `py_compile` output of a
  hello-world module touches, including the `FLAG_REF` reference
  table.
- Threaded dispatch built on Zig 0.16's labeled-`continue` switch,
  the language-level analogue of GCC's computed-goto trick CPython
  has used for years.
- Opcode coverage for the smallest runnable module: `RESUME`,
  `CACHE`, `NOP`, `NOT_TAKEN`, `EXTENDED_ARG`, `POP_TOP`,
  `PUSH_NULL`, `LOAD_CONST`, `LOAD_SMALL_INT`, `LOAD_NAME`,
  `STORE_NAME`, `LOAD_GLOBAL`, `CALL`, `RETURN_VALUE`. Runtime-only
  specializations (`LOAD_GLOBAL_BUILTIN` and friends) are
  deliberately excluded -- `py_compile` never emits them.
- `print` builtin, routed through a configurable `std.Io.Writer` so
  tests can pin stdout without forking a subprocess.
- CLI entry point: `zig build run -- path/to/foo.cpython-314.pyc`.
- Fixture generator `tests/fixtures/gen.sh` that produces `.pyc` and
  `.expected.txt` oracles plus a `fixtures.zig` manifest, so adding
  a fixture is one `.py` file and one re-run -- no code changes in
  `tests/integration.zig`.
- CI workflow running `zig build`, `zig build test`, and one end-to-
  end `zig build run` of the hello fixture on every push and PR.

[Unreleased]: https://github.com/tamnd/zag/compare/v0.0.8...HEAD
[0.0.8]: https://github.com/tamnd/zag/compare/v0.0.7...v0.0.8
[0.0.7]: https://github.com/tamnd/zag/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/tamnd/zag/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/tamnd/zag/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/tamnd/zag/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/tamnd/zag/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/tamnd/zag/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/tamnd/zag/releases/tag/v0.0.1
