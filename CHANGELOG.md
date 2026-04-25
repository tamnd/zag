# Changelog

All notable changes to zag are recorded here. The format follows
[Keep a Changelog 1.1](https://keepachangelog.com/en/1.1.0/). Once
zag reaches 1.0 the project will follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); until
then, expect minor version bumps to sometimes include breaking
changes.

## [Unreleased]

## [0.0.50] - 2026-04-25

### Added

- `49_memoryview` fixture, byte-equal against CPython 3.14.
  Exercises the `memoryview()` constructor over `bytes` and
  `bytearray`, the `tobytes` / `tolist` / `release` methods, the
  `readonly` / `nbytes` / `format` / `itemsize` attributes,
  indexing (returns int), slicing (sub-view sharing the backing
  buffer), bytes/bytearray/memoryview cross-type equality,
  iteration, membership, `bytes(mv)` materialization, item and
  slice assignment on a writable view propagating to the backing
  bytearray, write-through-sub-view, and TypeError when assigning
  to a read-only view.
- `Value.memoryview` variant backed by a new `Memoryview` struct.
  Stores `(backing, start, len)` so a slice of a slice still
  refers into the original `Bytes` / `Bytearray`. `readonly` is
  determined by the backing kind: bytes is read-only,
  bytearray is writable.
- `memoryviewmethods` module (`tobytes` / `tolist` / `release`).
  `release()` is a no-op that returns `None` — the memory model
  doesn't need it, but the symbol has to exist.

### Changed

- `bytes()` accepts a `memoryview` source and copies its window.
- `Value.equals` and `Value.order` now treat
  `bytes` / `bytearray` / `memoryview` as a single bytes-like
  family for content comparison.
- `containsOp`, `len`, `materialize`, `makeIter` all accept
  `memoryview` so `for b in mv`, `len(mv)`, `n in mv`,
  `list(mv)`, `sum(mv)` all work.
- `type(mv)` returns the lazy `memoryview` class, and
  `isinstance(mv, memoryview)` matches.

## [0.0.49] - 2026-04-25

### Added

- `48_bytearray_stress` fixture, byte-equal against CPython 3.14.
  Exercises slice assignment (same-length / shrink / grow / insert
  via empty range), slice deletion, extended slicing including
  step `-1`, the mutation methods (`clear`, `reverse`, `insert`,
  `remove`), search methods (`count`, `find`, `index`,
  `startswith`, `endswith`), `replace` and `split`, lex
  comparison across `bytes` / `bytearray`, `hash()` raising
  `TypeError`, in-place `+=`, and `remove` raising `ValueError`
  when the byte is missing.
- Eleven new bytearray methods: `clear`, `reverse`, `insert`,
  `remove`, `count`, `find`, `index`, `startswith`, `endswith`,
  `replace`, `split`. Each accepts bytes-like arguments
  uniformly (so `ba.replace(b"x", bytearray(b"y"))` works).
- Slice assignment and slice deletion on bytearray, sharing the
  same `replaceRange` machinery list already uses. Step != 1
  raises TypeError to match CPython's "extended slice" rule for
  the assign-to-different-length case.

### Changed

- `bytes` / `bytearray` ordering in `Value.order` is
  lexicographic and crosses the two types — previously it fell
  through to `null` (TypeError on `<`).
- `hash()` raises `TypeError` on `bytearray`.
- `+=` (NB_INPLACE_ADD) on `bytearray` mutates in place when the
  RHS is bytes-like, matching CPython. Other LHS types still
  fall back to a fresh `add`.

## [0.0.48] - 2026-04-25

### Added

- `47_bytearray` fixture, byte-equal against CPython 3.14.
  Exercises the `bytearray()` constructor (zero-arg, int-count of
  zeros, bytes-like, iterable of ints), repr with proper escape
  sequences (`\xHH` for non-printables, `\\` `\'` `\n` `\r` `\t`
  for the special cases), `len`, indexing (returns int), slicing
  (returns bytearray), item assignment, equality across `bytes`
  and `bytearray`, mutation methods (`append`, `extend`, `pop`),
  iteration yielding ints, membership (int matches a byte;
  bytes-like matches a contiguous subsequence), `+` concat
  preserving the left operand's flavor, `isinstance`
  discrimination, `.hex()` and `.decode()`.
- `Value.bytearray` variant backed by a fresh `Bytearray` struct
  with a mutable `std.ArrayList(u8)`. Distinct from `Bytes`
  because bytes is otherwise immutable shared-buffer.
- `bytearraymethods` module (`append` / `extend` / `pop` /
  `hex` / `decode`). `extend` accepts any iterable of ints, plus
  bytes/bytearray fast paths.
- Bytes-content escaping now goes through a shared
  `writeBytesContent` helper, so `bytes` repr also picks up the
  CPython-style escapes (the older naive `b'{s}'` would have
  spelled NUL bytes literally).

### Changed

- `+` between two bytes-likes now coerces to a single output type
  determined by the left operand: `b"a" + bytearray(b"b")` is a
  `bytes`, the reverse is a `bytearray`. Previously this raised
  TypeError.
- `==` between `bytes` and `bytearray` is content-only — both
  directions return True for the same buffer. Previously the
  cross-type compare just fell through to `False`.
- `containsOp` for `bytes` and `bytearray` now matches integers
  (single-byte) and bytes-likes (contiguous subsequence). The
  earlier handling only worked for `str in str`.

## [0.0.47] - 2026-04-25

### Added

- `46_frozenset_stress` fixture, byte-equal against CPython 3.14.
  Exercises subset / superset comparison operators (`<` `<=` `>`
  `>=`), the eight set-algebra methods (`issubset`, `issuperset`,
  `isdisjoint`, `union`, `intersection`, `difference`,
  `symmetric_difference`, `copy`), order-independent hashing of
  frozensets, mixed `set | frozenset` (left flavor wins), and
  nested-frozenset dedup inside a `set`.
- `setmethods` module backing the eight methods above. Each one
  accepts arbitrary iterables (`a.union([5, 6], (7,))`) by routing
  through `materialize`, and the algebra methods preserve the
  caller's `frozen` flag in the result. `frozenset.copy()` returns
  `self` (immutability lets identity stand in for the copy);
  `set.copy()` returns a fresh set.
- Set / frozenset partial-order comparisons in `compareOp`. `<` is
  proper subset, `<=` is subset; the frozen flag is irrelevant, so
  `{1} <= frozenset([1, 2])` and `frozenset([1]) <= {1, 2}` both
  work.

## [0.0.46] - 2026-04-25

### Added

- `45_frozenset` fixture, byte-equal against CPython 3.14.
  Exercises the `frozenset()` constructor, `repr` (`frozenset({1, 2})`
  with the empty case `frozenset()`), `len`, membership, set algebra
  (`|` `&` `-` `^`), equality across `set` and `frozenset`,
  hashability (frozenset usable as a dict key, plain set raises
  `TypeError` on `hash()`), nesting, `bool()`, iteration, and
  `isinstance` discrimination between the two types.
- `frozenset` builtin. Modeled as the same `Set` struct with a
  `frozen: bool` flag rather than a separate `Value` variant —
  the algebra is single-pathed, and the result keeps the *left*
  operand's flavor (CPython does the same).
- `hash(obj)` builtin. The fixture only exercises the negative
  path (`hash({1, 2})` → `TypeError`); for everything else we
  return `0` for now and tighten as fixtures demand. List and
  dict also raise.
- `BINARY_OP` cases for `&` / `|` / `^` (NB_AND=1, NB_OR=7,
  NB_XOR=12) and a set-vs-set arm in `subtract` / `containsOp` /
  `makeIter` / `materialize` / `len`.

### Changed

- `Value.equals` for `.set == .set` is now element-wise and
  order-insensitive, and indifferent to the `frozen` flag — so
  `frozenset({1, 2}) == {1, 2}` is `True`, matching CPython. Dict
  keying routes through `Value.equals`, so frozenset keys land in
  the same slot regardless of insertion order of the elements.
- `Value.typeName` returns `"frozenset"` vs `"set"` based on the
  flag, and `writeRepr` formats `frozenset({...})` / `frozenset()`
  / `set()` correctly.
- `matchClassCheck` recognizes `set` and `frozenset` as separate
  builtin "types" — `isinstance(set(), frozenset)` is `False`.

## [0.0.45] - 2026-04-25

### Added

- `44_complex_stress` fixture, byte-equal against CPython 3.14.
  Exercises power (constant-folded by `py_compile`, so it lands
  as a literal complex), `round(z.real, n)` formatting, `bool()`
  on complex, dict / list keying with complex values
  (insertion-ordered linear-scan dict already routes through
  `Value.equals`, so equality-as-identity holds: setting a
  complex key twice mutates the slot, doesn't add).
- `bool()` builtin. Returns `args[0].isTruthy()` and lands in
  `Value.boolean`. Was previously unimplemented even though
  every truthiness test in the dispatch loop already used the
  same machinery.
- `round(x[, ndigits])` builtin. Banker's rounding (half-to-
  even) on the float fast path so `.5` ties match CPython
  (Zig's `@round` rounds away from zero, which would diverge).
  Negative-`ndigits` on int rounds to a multiple of `10^|n|`.

### Notes

- No new arithmetic — power didn't need an opcode handler. The
  CPython 3.14 compiler folds `(1+2j) ** 2` and friends to a
  literal complex constant during `py_compile`, so what hits
  the VM is a `LOAD_CONST (-3+4j)`. The complex-exponent case
  `(1+1j) ** (2+0j)` similarly folds to `2j`.

## [0.0.44] - 2026-04-25

### Added

- `43_complex` fixture, byte-equal against CPython 3.14.
  Exercises complex literals (`1+2j`, `-2j`), the `complex()`
  constructor, `.real` / `.imag` / `.conjugate()`, full
  `+ - * / unary-` arithmetic across complex/int/float, mixed
  numeric `==` (e.g. `1+0j == 1`, `complex(2) == 2.0`), `abs()`
  as the modulus, and `type(x+y).__name__` returning
  `"complex"`.
- `Value.complex_num` variant carrying an inline
  `Complex { re: f64, im: f64 }`. The union grows by one tag and
  fits in 24 bytes, the existing size budget.
- The marshal reader emits real `Value.complex_num` for both
  `'y'` (binary) and `'x'` (ASCII) complex bodies. Previously
  these were stubbed to read-and-discard, returning `None` —
  which silently broke any literal like `1+2j`.
- `complex(re, im=0)` builtin. Accepts int / bool / float for
  both arguments. Calling with another complex composes
  correctly: `complex(c)` returns `c`, and a complex `im` is
  treated as `c.re*1j` so `complex(1, 2j) == (-2+1j)`.
- Repr / print formatting that matches CPython's complex
  formatter, including the corner cases:
  - Positive-zero real → drop the parens (`2j`, `0j`).
  - Negative-zero real → keep them (`(-0-2j)`, the repr of
    `-2j`).
  - Component floats render *without* the trailing `.0` that
    `float.__repr__` adds — so `complex(5, 0)` reads
    `(5+0j)`, not `(5.0+0.0j)`.
- `repr()` builtin (the missing twin of `print`). Threads
  through `Value.writeRepr` and hands back a `Str`. Used by the
  fixture but generally useful.
- `abs()` on `complex_num` returns the modulus,
  `sqrt(re² + im²)`, as a `float`.
- Attribute access on `complex_num` for `real` / `imag` / a
  zero-arg `conjugate` method, modeled on the existing
  generator-attribute path.
- `type(complex_val)` returns a lazily-built synthetic class
  named `"complex"`, mirroring `module_type`. The builtin
  `complex` name itself stays bound to the constructor function
  — the class is only reachable through `type()`.

### Changed

- Mixed-type `==` between complex and int/float coerces both
  sides to `Complex` and compares component-wise. Previously
  `equals` fell through `order()`, which doesn't know about the
  imaginary axis.

## [0.0.43] - 2026-04-25

### Added

- `42_importlib_stress` fixture, byte-equal against CPython
  3.14. Stresses the importlib façade across the corner cases:
  is-identity caching across `import_module` and the `import`
  opcode (they share the same module table), `import_module`
  vs `import a.b.c` returning different ends of the same chain,
  multi-dot relative (`..util` with `package="_39pkg.sub"`), the
  bare-dot case (`import_module(".", package="_39pkg")` returns
  the package itself), `reload()` of a package without
  clobbering submodule attributes already bound to it, the
  relative-import miss (`ImportError`), and the
  non-string-name miss (`TypeError`).

### Changed

- `CHECK_EXC_MATCH` accepts tuple types. `except (A, B)`
  compiles to a load-tuple-then-CHECK_EXC_MATCH; the opcode now
  walks the tuple and matches if any element's MRO covers the
  exception. Previously only a bare class was checked, so a
  tuple-form except would silently miss.
- `importlib.import_module` and `importlib.reload` raise real
  Python `TypeError` exceptions for argument-shape mistakes
  (instead of returning a Zig-level `error.TypeError` that
  unwound the whole script). Caught by user code's
  `try/except`.

## [0.0.42] - 2026-04-25

### Added

- `41_importlib` fixture and the `_41_state` helper, byte-equal
  against CPython 3.14. Exercises the importlib façade end to
  end: absolute dotted import returning the *innermost* module
  (`importlib.import_module("_39pkg.sub.leaf")`), single-segment
  import, `reload()` resetting a mutated module attribute back
  to its body's initial value, relative resolution via the
  `package=` keyword (`import_module(".sub", package="_39pkg")`),
  hitting a builtin module (`asyncio`), and the `ImportError`
  surface for a missing name.
- A pinhole `importlib` builtin module (`src/vm/importlib.zig`).
  Lazily built on first import via `Interp.getBuiltinModule`, the
  same hook that already serves `asyncio`. Two callables:
  - `import_module(name, package=None)` resolves leading dots
    against `package` the same way `IMPORT_NAME` does, then
    delegates to `loadModuleChain`. Differs from `import a.b.c`
    in one place — it returns the innermost module of the chain
    rather than the top, which is the whole point of the
    function.
  - `reload(mod)` re-runs the module body against the existing
    `mod.attrs` dict so module-level rebindings reset, while the
    module identity is preserved (callers holding the old
    reference still see the same object).

### Changed

- `Interp.importlib_module` cache field (twin of
  `asyncio_module`). Lazy build pattern means scripts that don't
  reach for importlib pay nothing.

## [0.0.41] - 2026-04-25

### Added

- `40_packages_stress` fixture and the `_40pkg/` helper package,
  byte-equal against CPython 3.14. Stress-tests the package
  loader added in m40: eager re-export from a top-level
  `__init__` (`from . import a`, `from .a import b`, `from .a.b
  import compute`), three-dot relative imports reaching back up
  to the root package (`from ... import PKG_NAME`), idempotent
  re-import (`import x.y.z` twice returns the same object), and
  the two import-failure surfaces — `ImportError` for a missing
  name `from x import nope` and `ModuleNotFoundError` for a
  missing path `import x.does_not_exist`.

### Notes

- No opcode or runtime changes. The m40 package machinery
  covers this stress variant verbatim — the value of this round
  is the regression-test evidence, not new code.

## [0.0.40] - 2026-04-25

### Added

- `39_packages` fixture and the `_39pkg/` package tree (lifted
  from goipy's testdata), byte-equal against CPython 3.14.
  `import _39pkg.sub.leaf`, `from _39pkg.sub import leaf,
  SUB_VERSION, combined`, dotted attribute access through
  packages, submodule binding on the parent package, and
  relative imports in a subpackage's `__init__` (`from .. import
  util`, `from . import leaf`).
- Dotted-name imports. `IMPORT_NAME` now walks the dotted chain,
  loading each prefix in order and binding the leaf as an
  attribute on its parent. With an empty `fromlist` it returns
  the top of the chain (matches `import a.b.c` binding `a`);
  with a non-empty `fromlist` it returns the innermost module
  and eagerly loads any `fromlist` entries that name submodules.
- Relative imports. `IMPORT_NAME` reads the level operand and
  resolves against the caller frame's `__package__`. Walks up
  `level - 1` parents, then prepends to the `name`. `from ..
  import x` and `from . import y` both work.
- `Module.is_package`. Set when the module's code came from an
  `__init__.py`; controls whether a non-empty `fromlist`
  triggers eager submodule loading.
- `STORE_ATTR` learnt nothing this round, but `__name__` and
  `__package__` are now seeded into module globals on first
  execution so a body's relative imports can resolve.
- The fixture harness picks up package directories. `gen.sh`
  recurses into any `_*/` helper, compiling every `.py` to a
  `.pyc` next to it, and emits a `helpers` table in
  `fixtures.zig` with each module's dotted name and `__init__`
  flag. The integration test registers them all before running
  any fixture; the CLI binary does the same walk on disk so
  `zag-bin some_script.pyc` finds neighbour packages.

## [0.0.39] - 2026-04-25

### Added

- `38_import_transitive` fixture and its companions `_38_mid` and
  `_38_leaf` (lifted from goipy's testdata), byte-equal against
  CPython 3.14. A middle module that imports a leaf, function-local
  imports hitting the cached module without re-executing it,
  re-exports flowing through the middle module, and module
  attributes mutated from the importer becoming visible to other
  importers.
- `STORE_ATTR` on a module. `module.attr = value` writes into the
  module's globals dict, so other importers that hold a reference
  see the new binding.

## [0.0.38] - 2026-04-25

### Added

- `37_import_stress` fixture and its companion `_37_helper`
  (lifted from goipy's testdata), byte-equal against CPython 3.14.
  Module-level state observable across calls, `from X import a, b`
  alongside `import X`, module identity preserved across re-imports
  with the body running exactly once, `type(asyncio).__name__ ==
  "module"`, and try/except around both a missing module and a
  missing name.
- `ImportError` and `ModuleNotFoundError` exception classes.
  `IMPORT_NAME` raises a `ModuleNotFoundError` with the CPython
  message `No module named 'X'`; `IMPORT_FROM` raises an
  `ImportError` with `cannot import name 'X' from 'M'`. Both flow
  through the normal exception-table machinery so user code can
  catch them.
- `type(module)` now returns a synthetic `module` class so
  `type(asyncio).__name__` evaluates to `"module"`. Built lazily
  the first time `type()` sees a module value.
- `str.split(sep)` with an explicit literal separator. Until now
  only the no-arg form (whitespace split) was wired up; the new
  form supports any non-empty separator and keeps empty pieces
  between consecutive matches, the way CPython does.

### Fixed

- `dict.keys()`, `dict.values()`, and `dict.items()` now iterate
  every pair, not just the string-keyed ones. The string-only
  shadow inside `Dict` was never updated when a non-string key
  was inserted, so `{0: 0, 1: 1, 2: 4}.values()` came back empty
  and `sum(...)` returned 0.
- `dict.get(key, default)` accepts non-string keys. Routes
  through `Dict.getKey` so ints, tuples, and bools all work.

## [0.0.37] - 2026-04-25

### Added

- `36_import_basic` fixture and its companion `_36_mymod` helper
  (lifted from goipy's testdata), byte-equal against CPython 3.14.
  Plain `import x as y`, `from x import a, b, c`, attribute access
  on the imported module, calls into module-level functions and
  classes, module-level side effects observable from the importer,
  and identity (`mymod is again`) across re-imports.
- Module loading for user `.pyc` files. The CLI binary scans the
  directory of the entry script and registers every sibling
  `.cpython-314.pyc` as an importable module; the test harness
  pre-registers helper fixtures (those whose name starts with
  `_`). Bodies are lazy — they only run on first import.
- `IMPORT_FROM` opcode. Peeks the module on TOS, looks up the
  attribute, and pushes it for the following `STORE_*` to bind.
- `IMPORT_NAME` learned to consult user modules: builtin lookup
  first (so `asyncio` still wins), then the user-module cache,
  then the registered `.pyc` codes (executed and cached on first
  hit).

## [0.0.36] - 2026-04-25

### Added

- `35_async_deep` fixture, lifted from goipy's testdata,
  byte-equal against CPython 3.14. `try/except` around an
  `await`, an exception raised through `asyncio.gather` and
  caught by the top-level coroutine, dict/list/set/tuple
  comprehensions inside `async def`, nested coroutines that
  return values up through several `await` levels, and
  `del local` mid-function.
- `DELETE_FAST` opcode. Drops the named fast slot back to the
  null sentinel so a later `LOAD_FAST` raises `UnboundLocalError`
  the same way CPython does.

### Fixed

- `str(exc)` for exception instances now formats as CPython
  does: a single-element `args` tuple unwraps to the bare
  message, an empty tuple becomes `""`, and anything else falls
  back to `repr(args)`. Before this, `f"caught:{e}"` printed
  `caught:<ValueError object>` instead of `caught:boom`.

## [0.0.35] - 2026-04-25

### Added

- `34_async_stress` fixture, lifted from goipy's testdata,
  byte-equal against CPython 3.14. Sequential awaits, return
  values flowing through nested coroutines, `asyncio.sleep(0,
  value)` delivering `value` as the await result,
  `asyncio.gather` over a handful of coroutines, conditional
  awaits, awaiting the same helper twice, and deeply nested
  `async def` closures.
- `asyncio.gather(*coros)` — runs each argument coroutine to
  completion in order and returns the list of results. No event
  loop, no interleaving; the fixtures only observe the final
  list, so a sequential drive is enough.
- `asyncio.sleep(delay, result=None)` now honours the second arg:
  the synthetic finished Generator carries `result` as its
  `return_value`, which is what the await loop hands back as the
  expression's value.

## [0.0.34] - 2026-04-25

### Added

- `33_async_basic` fixture, lifted from goipy's testdata,
  byte-equal against CPython 3.14. `import asyncio`,
  `asyncio.run(main())`, and `await asyncio.sleep(0)` from inside
  a nested coroutine.
- `Module` value (`name`, `attrs` dict). The first builtin module
  registered is `asyncio`; `getBuiltinModule` lazily caches it on
  the interpreter so identity holds across re-imports.
- `IMPORT_NAME` opcode. Today only resolves builtin modules; the
  `level` and `fromlist` operands are popped but not consulted.
- `GET_AWAITABLE` opcode — pass-through for generators (which is
  how we model coroutines).
- `LOAD_ATTR` learns to read attributes off a `Module`.
- `asyncio` module with `run` and `sleep`. `run` drives a
  coroutine to completion by sending None until StopIteration;
  `sleep` returns a synthetic `Generator` that's already
  `finished`, so the await loop short-circuits on first SEND.
- Coroutines (`CO_COROUTINE` flag) get the same prologue as
  generators — `RETURN_GENERATOR` then `POP_TOP` then `RESUME`,
  and the call site hands back a `Generator` value.

## [0.0.33] - 2026-04-25

### Added

- `32_generators_deep` fixture, lifted from goipy's testdata,
  byte-equal against CPython 3.14. `yield from` capturing the
  delegate's return value through nested recursion, generator
  expressions feeding `sum`/`min`/`max`/`any`/`all`/`dict`/`set`,
  generator-of-generators, two-way `.send()` loops, generators on
  class methods, and `enumerate(gen, start=…)` over both finite
  and infinite sources.
- `LOAD_COMMON_CONSTANT` opcode (3.14): names 0..6 cover
  `AssertionError`, `NotImplementedError`, `tuple`, `list`,
  `set`, `dict`, `frozenset` — looked up in the builtins module
  the same way `LOAD_NAME` would have.
- `tuple()`, `set()`, and `dict()` builtins. `dict()` accepts an
  iterable of length-2 pairs (tuple or list); `set()` and
  `tuple()` materialize from any iterable.
- Builtins can opt into kwargs via `registerBuiltinKw`. `enumerate`
  uses it to accept `start=`; the rest stay positional-only.
- `EnumIter`, a lazy `enumerate` adapter. Wraps any iterable as a
  `Value` and pairs each step with a counter, so
  `enumerate(infinite_gen)` no longer drains the source up front.
- `iterStep(interp, value)` — a single helper that advances any
  iterator-shaped value (`iter` / `generator` / `enum_iter`).
  `FOR_ITER` and `materialize` now route through it.
- `AssertionError` and `NotImplementedError` exception classes in
  the builtins module.

### Fixed

- Generator prologue now applies `COPY_FREE_VARS` before skipping
  `RETURN_GENERATOR`, so closure cells are seeded into the fast
  slots the body's `LOAD_DEREF` reads. Without this, a generator
  that closes over outer locals would crash on first resume.
- `LOAD_DEREF` and `STORE_DEREF` tolerate non-cell fast slots:
  read passes the value through; write auto-promotes to a fresh
  `Cell`. CPython sometimes elides `MAKE_CELL` for parameters
  that are also closure variables, and we have to catch up.
- Exhausted-generator `gen_yielded` is now the generator's
  `return_value`, not `None`. `for x in gen` and `list(gen)`
  don't observe this, but `yield from gen` does — it's how the
  delegate's return value reaches the caller.

## [0.0.32] - 2026-04-25

### Added

- `31_generators_stress` fixture, lifted from goipy's testdata,
  byte-equal against CPython 3.14. Generators with `return`
  values flowing through `StopIteration.args[0]`, two-way
  `.send()`, `yield from` over heterogeneous iterables (range,
  tuple, str), and `.close()`.
- `interp.raisePyValue` for raising a Python exception with a
  pre-built `args[0]` value (vs. a string).
- `Generator.return_value` field; `genResume` captures the
  function's `RETURN_VALUE` so `next`/`send` can surface it via
  `StopIteration.args[0]`.
- Generator `.close()` method (just flips `finished` — close-on-
  unclosed-frame finalization isn't exercised by fixtures yet).
- `makeIter` now drains `str`/`bytes`/`dict`/`generator` via
  `materialize`, so `yield from` accepts them.

### Fixed

- `isinstance` now accepts builtin type stand-ins (`list`,
  `int`, ...) and a tuple-of-classes second argument.
- `StopIteration` raised by an exhausted generator now carries
  the generator's return value (was empty string).

## [0.0.31] - 2026-04-25

### Added

- `30_format_edge` fixture, lifted from goipy's testdata,
  byte-equal against CPython 3.14. Edge cases of the format
  mini-language: alt+sign+zero on negative ints, alignment
  with grouping, repr-conversion + width, nested format spec,
  and signed-zero / banker's-rounding for floats.

### Fixed

- `-0.0` now formats with the `-` sign (was `+`/empty because
  `fff < 0` is false for negative zero — switched to
  `std.math.signbit`).
- `f"{2.5:.0f}"` now rounds half-to-even (`2`) like CPython,
  instead of Zig's default half-away-from-zero (`3`).

## [0.0.30] - 2026-04-25

### Added

- `29_format_polish` fixture, lifted from goipy's testdata,
  byte-equal against CPython 3.14. Polishes the format
  mini-language: `#b/#o/#x/#X` alt prefixes for ints,
  underscore grouping (`_`) every 3 for `d` and every 4 for
  `b/o/x/X`, comma/underscore grouping for floats, `%` type,
  `n` type (treated as `d`/`g`), `c` type (UTF-8 codepoint),
  `#g` keeps trailing zeros, and zero-pad cooperates with both
  alt prefixes (`0x00007b`) and grouping (`000,001,234,567`).

## [0.0.29] - 2026-04-25

### Added

- `28_match_deep` fixture, lifted from goipy's testdata,
  byte-equal against CPython 3.14. Recursive class patterns
  through `Node(tag, kids)`, attribute-access matching
  (`Color.RED`), `as` binding inside or-patterns and mapping
  patterns, deeply nested mapping+list patterns over a tiny
  AST.

## [0.0.28] - 2026-04-25

### Added

- `27_match_stress` fixture, lifted from goipy's testdata,
  byte-equal against CPython 3.14. Class patterns with
  `__match_args__`, nested class patterns, kw attrs, guards,
  or-patterns, sequence patterns with star, mapping patterns
  with `**rest`.

### Fixed

- `MATCH_CLASS` now walks `__match_args__` for instance subjects
  with positional patterns, and accepts the kw-attr form (used
  by `Circle(Point(0, 0), radius=r)`).

## [0.0.27] - 2026-04-25

### Added

- `26_descriptors_stress` fixture, lifted from goipy's testdata,
  byte-equal against CPython 3.14. Property / classmethod /
  staticmethod across a base class and an inheriting subclass
  chaining through `cls(...)` and `super().property`.
- `type(obj)` builtin (single-arg form).

### Fixed

- `LOAD_SUPER_ATTR` now binds descriptors against the super-side
  receiver, so `super().some_property` actually invokes the
  getter instead of pushing the descriptor object.

## [0.0.26] - 2026-04-25

### Added

- `25_walrus_stress` fixture, lifted from goipy's testdata,
  byte-equal against CPython 3.14. Walrus in `if`, `while`,
  comprehensions, conditional expressions, nested walrus.
- `int <op> float` arithmetic for `+ - *` (and the same coercion
  in `Value.order`).
- `list.pop(i)` indexed form (drains from the front when i==0).

## [0.0.25] - 2026-04-25

### Added

- `24_unpack_stress` fixture, lifted from goipy's testdata,
  byte-equal against CPython 3.14. Stars in every unpack
  position, nested unpack, for-loop unpack, splat call sites
  with positional / kwargs / mixed.
- `INTRINSIC_LIST_TO_TUPLE` (`CALL_INTRINSIC_1` oparg 6) for
  star-prefixed tuple literals.
- `SET_UPDATE` for set-spread literals.
- `SET_FUNCTION_ATTRIBUTE` flags 2 (kw_defaults) and 4
  (annotations — ignored). `callPyFunction` walks
  `kw_defaults` to fill missing kw-only slots.

## [0.0.24] - 2026-04-25

### Added

- `23_format_stress` fixture, lifted from goipy's testdata,
  byte-equal against CPython 3.14. Comprehensive format-spec
  coverage on int / float / str.
- `:g` / `:G` float format, with the CPython rule for picking
  fixed vs exponent representation (exp < -4 or exp >=
  precision) and trailing-zero / dangling-dot stripping.

## [0.0.23] - 2026-04-25

### Added

- `22_slicing_stress` fixture, lifted from goipy's testdata,
  byte-equal against CPython 3.14. Exhaustive slice combinations
  over lists, tuples, strings, bytes; clamping; slice assignment
  / `del`; reversed slices.
- Tuple and bytes slicing through the existing `resolveSlice`
  helper.
- `bytes()` builtin (empty + iterable-of-ints).
- `materialize` drains bytes as a sequence of ints.

## [0.0.22] - 2026-04-25

### Added

- `21_with_stress` fixture, lifted from goipy's testdata, running
  byte-equal against CPython 3.14. Multi-item `with`, nested
  `with`, exception swallowed via `__exit__` truthy return,
  exception bubbling, early `return` inside `with`.
- `issubclass(sub, cls)` builtin.
- `DELETE_DEREF` opcode for cleaning up `except E as e:` cells.

### Changed

- "unsupported opcode" diagnostic reports the actual offending
  byte at `code[ip]` instead of the dispatchOne entry opcode.

## [0.0.21] - 2026-04-25

### Added

- `20_unpack` fixture, lifted from goipy's testdata, running
  byte-equal against CPython 3.14. Sequence unpack with / without
  a starred target over tuples, lists, `range(...)`, strings;
  `f(*args)` from a list; `g(**kw)` with dict-spread.
- `CALL_FUNCTION_EX` opcode for `*args` / `**kwargs` call sites,
  matching CPython 3.14's `[callable, NULL, args, kwargs_or_NULL]`
  stack layout.
- `DICT_MERGE` / `DICT_UPDATE` opcodes used to assemble the
  kwargs dict for `**` spreads.

### Changed

- `UNPACK_SEQUENCE` and `UNPACK_EX` now drain any iterable
  (iter / generator / str / dict) via the same `materialize`
  helper the builtins use, instead of restricting to tuple / list.
- `LIST_EXTEND` follows the same path so list literals built
  from a non-tuple / non-list iterable just work.

## [0.0.20] - 2026-04-25

### Added

- `19_comprehensions` fixture, lifted from goipy's testdata,
  running byte-equal against CPython 3.14. List, dict, set, and
  generator comprehensions; multi-loop with `enumerate`; a
  `sum(...)` over a generator expression.
- `Set` value type backed by an insertion-ordered ArrayList,
  with `BUILD_SET` and `SET_ADD` opcodes.
- Generic dict keys: `Dict` now stores `(Value, Value)` pairs,
  and `BUILD_MAP` / `MAP_ADD` / subscript / store / repr go
  through the value-keyed API. `setStr` / `getStr` remain as
  thin wrappers so module / class / instance namespaces stay
  ergonomic.

### Changed

- `Dict` repr walks `pairs` directly so int / bool / mixed-key
  dicts render correctly. The previous `keys` slice (str-only)
  is now an insertion-order shadow used by namespace iteration.

## [0.0.19] - 2026-04-25

### Added

- `18_slicing` fixture, lifted from goipy's testdata, running
  byte-equal against CPython 3.14. Covers default bounds, step
  (positive, negative, `[::-1]`), negative indices, slice
  assignment, slice deletion, and string slicing.
- `resolveSlice` helper that mirrors CPython's normalization:
  step defaults, sign-aware default bounds, negative-index
  fold, and clamp per step sign. Drives string and list reads.
- `BINARY_SLICE`, `STORE_SLICE`, `BUILD_SLICE` opcodes. The 2-
  and 3-arg slice forms now share the same `Slice` value type.
- `DELETE_SUBSCR` for list-element and list-slice deletion.

## [0.0.18] - 2026-04-25

### Added

- `17_walrus` fixture, lifted from goipy's testdata, running
  byte-equal against CPython 3.14. Covers walrus in an `if`
  head, a `while next(it, None) is not None` loop, and a list
  comprehension whose filter binds via walrus.
- `STORE_GLOBAL` opcode -- the comprehension's walrus binds to
  the enclosing scope, not the comprehension's locals.
- `iter` builtin: pass-through for iterators and generators,
  otherwise delegate to `makeIter`.
- Two-argument `next(it, default)`: returns `default` instead of
  raising `StopIteration` when the iterator is exhausted.

## [0.0.17] - 2026-04-25

### Added

- `16_generators` fixture, lifted from goipy's testdata, running
  byte-equal against CPython 3.14. A `count(n)` consumed by `list`,
  an `echo` driven by `next` / `g.send` / `try ... except
  StopIteration`, and a `chain(*its)` that uses `yield from` over
  a list, a tuple, and a `range`.
- A `Generator` value backed by a suspendable `Frame`. Generator
  functions are detected via `CO_GENERATOR` (flag `0x20`) at call
  time; the call returns the wrapper without running, and each
  `next` / `send` resumes the saved `ip` and stack.
- `YIELD_VALUE`, `RETURN_GENERATOR`, `SEND`, `END_SEND`,
  `GET_YIELD_FROM_ITER`. `SEND` keeps both receiver and sent value
  on the stack and rewrites the slot in place, matching CPython's
  `(receiver, v -- receiver, retval)` stack effect.
- `next` builtin and a `g.send` method that funnel through one
  `genResume` helper. `list(gen)` / `for x in gen` drive the same
  helper so generators participate in iteration without a separate
  `Iter` shim.
- `CALL_INTRINSIC_1` and `CLEANUP_THROW` stubs, enough to pass over
  the generator-prologue bytecode the fixture emits.

### Fixed

- `JUMP_BACKWARD_NO_INTERRUPT` now reads its own cache width
  instead of borrowing `JUMP_BACKWARD`'s. The off-by-two landed on
  the wrong instruction once the match-fixture exception cleanup
  flow exercised it.

## [0.0.16] - 2026-04-25

### Added

- `15_match` fixture, lifted from goipy's testdata, running
  byte-equal against CPython 3.14. Seven `case` arms covering
  literal, class+guard, sequence, star-sequence, mapping,
  class-as, and default.
- `MATCH_CLASS`, `MATCH_SEQUENCE`, `MATCH_MAPPING`, `MATCH_KEYS`,
  `GET_LEN`. The class form supports atomic-type single-positional
  binding (`int(n)` / `str()` style) by builtin name; user
  classes walk the MRO. Generic `__match_args__` extraction is
  out of scope until a fixture forces it.
- `UNPACK_EX` for `[a, *rest, b]` patterns. The starred middle
  is collected into a fresh `List`; push order leaves the
  leftmost name on top of the stack.
- `CONVERT_VALUE` for f-string `!s` / `!r` / `!a` conversions.
- `POP_JUMP_IF_NONE` / `POP_JUMP_IF_NOT_NONE` -- needed for the
  `MATCH_CLASS` and `MATCH_KEYS` None-check pattern.

## [0.0.15] - 2026-04-25

### Added

- `14_fstring_format` fixture, lifted from goipy's testdata,
  running byte-equal against CPython 3.14. Covers width, zero-pad,
  int bases (`b/o/x/X`), thousands separator, float `.Nf` and
  `.Ne`, fill+align combos, and the `+` sign flag.
- `FORMAT_WITH_SPEC` opcode plus a PEP 3101 mini-language parser
  in `src/vm/format.zig`. Dispatches on value kind: int formats
  go through `printInt` plus a comma-insertion pass; float `e/E`
  is hand-rolled because Zig's `{e}` doesn't produce Python's
  two-digit signed exponent.
- `FORMAT_SIMPLE` empty-spec fast path. Strings pass through;
  everything else converts via `writeStr`.
- `BUILD_STRING` for f-strings that interleave literal text with
  formatted interpolations. Concatenates n stack entries into a
  single `Str`.
- `UNARY_NEGATIVE`. The fixture's `-n` test forced it; small_int,
  float, and bool are in scope.

## [0.0.14] - 2026-04-25

### Added

- `13_descriptors` fixture, lifted from goipy's testdata, running
  byte-equal against CPython 3.14. Exercises `@property`,
  `@classmethod`, and `@staticmethod` through both instance and
  class access.
- `property`, `classmethod`, `staticmethod` builtins. Each returns
  a `Descriptor` -- a thin wrapper over the decorated callable
  plus a kind tag.
- `Value.descriptor` arm. `loadAttr` recognizes it when walking the
  MRO and applies the binding rule:
  - `property` on instance access invokes `getter(self)` and
    pushes the result; class access returns the descriptor.
  - `classmethod` pushes `(func, cls)` so `CALL` threads the class
    as the first argument.
  - `staticmethod` pushes `(func, NULL)` for no binding.

## [0.0.13] - 2026-04-25

### Added

- `12_super` fixture, lifted from goipy's testdata, running byte-equal
  against CPython 3.14. Three classes (A, B(A), C(B)) with overrides
  that chain through `super().greet()` and `super().kind()`.
- `LOAD_SUPER_ATTR`. Pops `(global_super, class, self)`, walks
  `class.mro[1..]` for the named attribute, and pushes
  `(method, self)` in method form (same convention as `LOAD_ATTR`).
  Only the zero-arg `super()` shape is in scope; the bytecode itself
  builds the three-arg stack.
- `__classcell__` cell-fill in `__build_class__`. After the body runs,
  the still-empty cell sitting in the namespace dict gets pointed at
  the freshly built class, so each method's `LOAD_DEREF __class__`
  closure returns the right class for `super()`.
- `super` registered as a builtin so `LOAD_GLOBAL super` resolves.
  Calling it directly raises TypeError -- proxy objects with their
  own `__getattr__` semantics are out of scope.

## [0.0.12] - 2026-04-25

### Added

- `11_with` fixture, lifted verbatim from goipy's testdata, running
  byte-equal against CPython 3.14 stdout. Covers `with M() as x:`,
  `with M():` raising into the manager, and `M(suppress=True)`
  swallowing an exception via a truthy `__exit__` return.
- `LOAD_SPECIAL` for the two dunder slots the `with` prologue uses
  (`__enter__` / `__exit__`). It's a method-form lookup that pushes
  `(method, self)` -- same convention as `LOAD_ATTR` with the
  method bit, so the existing `CALL` bound-method path threads
  `self` without new plumbing.
- `WITH_EXCEPT_START`. Reads `exit_func` from `sp-5`, `exit_self`
  from `sp-4`, the live exception from `sp-1`, and calls
  `exit_func(exit_self, type(exc), exc, None)` -- pushing the
  result without popping. Truthy result + `POP_JUMP_IF_TRUE`
  swallows the exception; falsy + `RERAISE` re-raises.
- `__name__` on a class. `LOAD_ATTR __name__` returns a fresh `Str`
  of `class.name`; that's what `exc_type.__name__` reads for the
  fixture's `print("exit", self.name, exc_type.__name__ ...)` line.

### Out of scope

- `async with` and async context managers
- `contextlib.contextmanager`-style generator-based managers
- `traceback` argument to `__exit__` (we always pass `None`)
- Multiple managers in one `with` (the compiler lowers them to
  nested withs, which already works)

## [0.0.11] - 2026-04-25

### Added

- `10_builtins` fixture, lifted verbatim from goipy's testdata,
  running byte-equal against CPython 3.14 stdout. Covers a grab-bag
  of common builtins plus a `lambda` (which already worked through
  `MAKE_FUNCTION`).
- `list`, `max`, `min`, `reversed`, `enumerate`, `zip`, `map`,
  `filter`, `any`, `all`, `ord`, `chr`, `hex`, `oct`, `bin`, `int`,
  `float`, `str` builtins. The compound ones (`map` / `filter` /
  `zip` / `enumerate` / `reversed`) materialize eagerly into a
  `List` rather than wrapping in lazy iterator types -- the fixture
  always wraps each call in `list(...)`, so a layer of laziness
  would just churn objects.
- Shared `materialize(interp, v)` helper that drains any iterable
  (list, tuple, str, dict-as-keys, iter) into a fresh List. The new
  builtins build on it, and `sum` is now backed by it instead of
  the old list/tuple-only `iterableItems`.
- `dispatch.invoke` is now `pub` so `map` / `filter` can call user
  functions (including lambdas) without going through a fake CALL
  opcode.
- `int(s)` and `float(s)` raise `ValueError` on parse failure --
  they round-trip through the m10 PyException machinery.

### Out of scope

- Lazy iterator wrappers for `map` / `zip` / `filter` /
  `enumerate` / `reversed` (CPython prints these as `<map object>`
  etc., which we'd never match anyway).
- Multi-byte unicode in `ord` / `chr`, negative inputs to `hex` /
  `oct` / `bin`, `int(s, base)`, `key=` / `default=` keyword args.

## [0.0.10] - 2026-04-25

### Added

- `09_exceptions` fixture, lifted verbatim from goipy's testdata,
  running byte-equal against CPython 3.14 stdout. Covers `try` /
  `except`, `as e` binding, `e.args[0]` readback, `raise Cls("msg")`,
  cross-frame propagation through `f()`, and a nested try where the
  inner clause doesn't match and the outer one does.
- `BaseException` / `Exception` and the subclasses the fixture
  touches (`ArithmeticError`, `LookupError`, `ZeroDivisionError`,
  `ValueError`, `IndexError`, `KeyError`, `RuntimeError`,
  `AttributeError`, `TypeError`, `NameError`, `StopIteration`),
  installed as builtin `Class` values with the right MRO. A Python
  exception is just an `Instance` of one of these.
- `Interp.current_exc` plus `raisePy(cls_name, msg)`. The dispatch
  loop signals "look at current_exc" by returning a new
  `error.PyException`; everything else still propagates as a Zig
  error the way it did before.
- Exception-table-driven unwind. `run` is now a thin loop around the
  inner `dispatchOne`: on `error.PyException` it parses the running
  frame's `co_exceptiontable`, finds the first entry covering
  `frame.ip`, truncates the stack to the entry's depth, pushes the
  exception, jumps to the handler, and re-enters. No handler ->
  propagate to the caller frame, where the same loop catches at the
  parent's CALL instruction.
- `RAISE_VARARGS`, `PUSH_EXC_INFO`, `CHECK_EXC_MATCH`, `POP_EXCEPT`,
  `RERAISE`, `DELETE_NAME` opcodes. `PUSH_EXC_INFO` uses a
  `null_sentinel` placeholder for the previous `sys.exc_info()` slot
  -- we don't track it and the fixture never reads it.
- `BINARY_OP 11` (true division). `int / int` returns a float;
  zero divisor raises `ZeroDivisionError("division by zero")`.
- `tuple` arm in `subscript` so `e.args[0]` works. Out-of-range
  raises `IndexError`. List `IndexError` was upgraded from the old
  stderr-print + Zig-error path to the new PyException path.
- Default `args` binding in `instantiate`: a class without
  `__init__` whose MRO contains `BaseException` gets
  `inst.dict["args"] = tuple(positional)` -- mirrors what
  `BaseException.__init__` does in CPython, and is what
  `raise ValueError("msg")` relies on for `e.args[0]`.

### Out of scope

- `try / finally`, `except (A, B):` tuple match, `except*`
  exception groups, `__cause__` / `__context__` chaining,
  `traceback`, `sys.exc_info()`. The `PUSH_EXC_INFO` placeholder
  exists to keep the stack discipline right, not to surface real
  exception state.

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
