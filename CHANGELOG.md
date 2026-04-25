# Changelog

All notable changes to zag are recorded here. The format follows
[Keep a Changelog 1.1](https://keepachangelog.com/en/1.1.0/). Once
zag reaches 1.0 the project will follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); until
then, expect minor version bumps to sometimes include breaking
changes.

## [Unreleased]

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

[Unreleased]: https://github.com/tamnd/zag/compare/v0.0.3...HEAD
[0.0.3]: https://github.com/tamnd/zag/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/tamnd/zag/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/tamnd/zag/releases/tag/v0.0.1
