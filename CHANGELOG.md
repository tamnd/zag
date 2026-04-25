# Changelog

All notable changes to zag are recorded here. The format follows
[Keep a Changelog 1.1](https://keepachangelog.com/en/1.1.0/). Once
zag reaches 1.0 the project will follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); until
then, expect minor version bumps to sometimes include breaking
changes.

## [Unreleased]

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

[Unreleased]: https://github.com/tamnd/zag/compare/v0.0.5...HEAD
[0.0.5]: https://github.com/tamnd/zag/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/tamnd/zag/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/tamnd/zag/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/tamnd/zag/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/tamnd/zag/releases/tag/v0.0.1
