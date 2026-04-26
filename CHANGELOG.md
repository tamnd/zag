# Changelog

All notable changes to zag are recorded here. The format follows
[Keep a Changelog 1.1](https://keepachangelog.com/en/1.1.0/). Once
zag reaches 1.0 the project will follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); until
then, expect minor version bumps to sometimes include breaking
changes.

## [Unreleased]

## [0.0.139] - 2026-04-26

### Added

- `functools.update_wrapper` and the `WRAPPER_ASSIGNMENTS` /
  `WRAPPER_UPDATES` constants used by `functools.wraps`.
- `functools.Placeholder`: per-call sentinel for `partial`. Bound
  argument slots holding `Placeholder` are filled by the call-site
  positional args in order.
- `functools.cmp_to_key`: produces a fresh comparator class per
  call. The class implements `__lt__/__le__/__eq__/__ne__/__gt__/__ge__`
  by consulting the captured cmp.
- `functools.total_ordering`: class decorator that fills in the
  three missing rich comparators given any one of `__lt__/__le__/__gt__/__ge__`
  and `__eq__`.
- `functools.partialmethod`: descriptor that, when read through an
  instance attribute, produces a `Partial` with the receiver bound
  in front of the captured args.
- `functools.singledispatch` and `functools.singledispatchmethod`:
  type-keyed dispatch with a `register(type)` decorator form and a
  direct `register(type, fn)` form. Builtin constructors (`int`,
  `str`, `tuple`, ...) match by name; user classes match by MRO walk.
- Attribute access on `partial` objects: `.func`, `.args`,
  `.keywords` for compatibility with CPython introspection.
- `lru_cache(typed=True)`: `f(1)` and `f(1.0)` get separate cache
  entries via a typed composite key that includes each argument's
  runtime tag.
- `cache_parameters()` method on `lru_cache`-decorated callables
  exposing `{maxsize, typed}` as a dict.

### Changed

- `sorted(key=...)` now dispatches through `__lt__` when the keys
  are user class instances. `cmp_to_key` produced keys that the
  previous value-level comparator silently treated as equal,
  preserving input order.

## [0.0.138] - 2026-04-26

### Added

- `itertools.batched(iter, n, *, strict=False)`: fixed-size chunks
  yielded as tuples; `strict=True` raises `ValueError` on a short
  final batch.

### Fixed

- `itertools.count(start, step)` with negative step now yields the
  arithmetic progression downward instead of stopping immediately.
  The internal range had a positive-step sentinel for `stop`; we now
  pick `minInt(i64)` when `step < 0`.

## [0.0.137] - 2026-04-26

### Added

- `statistics` module: full method surface for descriptive stats,
  inferential stats, kernel density estimation, and a `NormalDist`
  class.
- `StatisticsError` (subclass of `Exception`) raised on empty input,
  negative geometric mean, single-sample variance, and negative sigma.
- Central tendency: `mean`, `fmean` (with `weights` kwarg),
  `geometric_mean`, `harmonic_mean` (with `weights` kwarg),
  `median`, `median_low`, `median_high`, `median_grouped`,
  `mode`, `multimode`, `quantiles` (with `n` and `method='inclusive'`).
- Spread: `pvariance` (with `mu` kwarg), `variance`, `pstdev`, `stdev`.
- Relations: `covariance`, `correlation` (with `method='ranked'` for
  Spearman), `linear_regression` (with `proportional=True` for
  through-origin fits).
- Density: `kde` (with `h`, `kernel`, `cumulative` kwargs; supports
  `normal`/`triangular`/`rectangular`/`epanechnikov` kernels),
  `kde_random` (with `seed` for reproducibility).
- `NormalDist`: `mean`/`median`/`mode`/`stdev`/`variance` attrs,
  `pdf`/`cdf`/`inv_cdf`/`zscore`, `quantiles`, `samples` (with
  `seed`), `from_samples` classmethod, `overlap` (Inman-Bradley
  1989), arithmetic (`__add__`/`__sub__` over independent normals,
  `__mul__`/`__rmul__`/`__truediv__` by scalar), `__repr__`,
  default `(0, 1)` constructor.

## [0.0.136] - 2026-04-26

### Added

- `random` module: full method surface backed by Zig's Xoshiro256
  PRNG. Module-level state for free functions and a per-instance map
  for `Random` instances; every entry point routes through a single
  `unpack` helper that picks the right state regardless of whether
  the caller invoked us as a method or a free function.
- Free/method functions: `seed`, `random`, `uniform`, `randint`,
  `randrange`, `getrandbits` (arbitrary bit count via big int),
  `randbytes`, `choice`, `choices` (with `weights` and `cum_weights`
  kwargs), `shuffle`, `sample` (with `counts` kwarg), `binomialvariate`,
  `triangular`, `expovariate`, `gauss` (Box-Muller with cached pair),
  `normalvariate`, `lognormvariate`, `gammavariate` (Marsaglia-Tsang
  for `alpha >= 1`, Ahrens-Dieter for `alpha < 1`), `betavariate`,
  `vonmisesvariate` (Best-Fisher), `paretovariate`, `weibullvariate`,
  `getstate`, `setstate`.
- `Random` and `SystemRandom` classes with independent per-instance
  state; constructing `Random(seed)` or calling `seed()` re-initialises
  the PRNG. `getstate`/`setstate` round-trip the four `u64` Xoshiro
  state words plus the cached gauss carry.

### Changed

- `sum()` builtin now accepts floats (and a starting value) and
  promotes the running accumulator to float on first float element.
- `/` operator now handles mixed float/int operands (and float/float)
  in addition to the existing int/int and complex paths, raising
  `ZeroDivisionError` on a zero denominator.

## [0.0.135] - 2026-04-26

### Added

- `fractions` module: `Fraction` rationals with big-integer numerator
  and denominator, always stored in canonical reduced form with a
  positive denominator. Construction accepts ints, bools, floats,
  Fractions, and strings (including signed integers, simple `n/d`
  forms, and decimal/scientific literals like `'1.5'`, `'-0.25'`,
  `'1.0e2'`). The two-argument form accepts a Fraction or int for
  either numerator or denominator. Float construction goes through
  the IEEE-754 mantissa/exponent split so `Fraction(0.1)` round-trips
  as `3602879701896397/36028797018963968`.
- Arithmetic surface: `+`, `-`, `*`, `/`, `//`, `%`, `**`, with mixed
  Fraction/int interop on both sides. Power supports negative integer
  exponents (returning the reciprocal) and falls back to float for
  fractional exponents. Unary `-`, `+`, `abs`, full comparisons
  (including against ints, floats, and Fractions), `int()`, `float()`,
  `bool()`, `__floor__`, `__ceil__`, `__trunc__`, and half-to-even
  `__round__` (with optional digits argument).
- Methods: `as_integer_ratio`, `is_integer`, and `limit_denominator`
  (continued-fraction algorithm picking the closer of the two
  bounding convergents).
- Classmethods: `from_float`, `from_decimal`, and the 3.14+
  `from_number` constructor.
- `math.floor`, `math.ceil`, and `math.trunc` now dispatch to the
  `__floor__`, `__ceil__`, and `__trunc__` dunder methods on
  instances, so they work transparently on `Fraction` and similar
  rational types.

## [0.0.134] - 2026-04-26

### Added

- `decimal` module: arbitrary-precision decimal arithmetic with
  context-driven precision. `Decimal` supports `+`, `-`, `*`, `/`,
  `//`, `%`, `**`, unary `-`/`+`/`abs`, full comparisons, `int()`,
  `float()`, and `bool()`. Construction accepts strings (including
  `Inf`, `Infinity`, `NaN`, `sNaN`, scientific notation), ints, bools,
  and other Decimals. Methods include `quantize`, `to_integral_value`,
  `adjusted`, `as_tuple`, `normalize`, `sqrt`, `compare`, `copy_sign`,
  `max`, `min`, and the `is_*` predicate family (`is_finite`,
  `is_infinite`, `is_nan`, `is_qnan`, `is_snan`, `is_signed`,
  `is_zero`, `is_normal`).
- Eight rounding modes from the IBM General Decimal Arithmetic spec:
  `ROUND_UP`, `ROUND_DOWN`, `ROUND_CEILING`, `ROUND_FLOOR`,
  `ROUND_HALF_UP`, `ROUND_HALF_DOWN`, `ROUND_HALF_EVEN`, `ROUND_05UP`.
- `Context` with `prec` and `rounding` attributes. Module-level
  `getcontext()`, `setcontext(ctx)`, and `localcontext()` (a context
  manager that swaps the active context on `__enter__` /
  `__exit__`). Pre-built `DefaultContext`, `BasicContext`, and
  `ExtendedContext` instances exposed on the module.
- Decimal-specific exception classes `InvalidOperation`,
  `DivisionByZero`, and `Overflow` (subclasses of `ArithmeticError`,
  catchable via the names imported from `decimal`).

## [0.0.133] - 2026-04-26

### Added

- `cmath` module: complex-arg analogues of the `math` functions.
  `phase`, `polar`, `rect`, `exp`, `log` (with optional base), `log10`,
  `sqrt`, the trig family (`sin`, `cos`, `tan`, `asin`, `acos`,
  `atan`), the hyperbolic family (`sinh`, `cosh`, `tanh`, `asinh`,
  `acosh`, `atanh`), classification (`isfinite`, `isinf`, `isnan`,
  `isclose`), plus the constants `pi`, `e`, `tau`, `inf`, `nan`,
  `infj`, `nanj`. Inputs accept `int`, `float`, or `complex`.
- Signed zeros are preserved across `cos`, `sin`, `acos`, `acosh`, and
  others by hand-implementing CPython's formulas (with a
  CPython-style `c_sqrt` that propagates the sign of the imaginary
  part) instead of going through `std.math.complex`.

## [0.0.132] - 2026-04-26

### Added

- `math` module fills out the rest of the standard library surface:
  `isqrt` (small ints and big ints, via `std.math.big.int.Managed.sqrt`),
  `fma`, `remainder`, `nextafter`, `ulp`, `cbrt`, `exp2`, `expm1`,
  `log1p`, `pow`, `sumprod`, plus the trig family (`asin`, `acos`,
  `atan`) and the hyperbolic family (`sinh`, `cosh`, `tanh`, `asinh`,
  `acosh`, `atanh`). `gamma` and `lgamma` come straight from
  `std.math`; `erf` and `erfc` use the Abramowitz & Stegun 7.1.26
  polynomial (max abs error ~1.5e-7) since `std.math` doesn't ship
  these.
- `math.isqrt` and `math.factorial` raise `ValueError` on negative
  input; `math.remainder` raises on division by zero.

## [0.0.131] - 2026-04-26

### Added

- `numbers` module: the abstract numeric tower `Number`, `Complex`,
  `Real`, `Rational`, `Integral`. Each ABC carries an `abc_kind` so
  `isinstance(v, cls)` matches the right built-in numeric values
  (int and bool flow through as Integral; float as Real; complex as
  Complex), and the inheritance chain gives `issubclass(Integral,
  Number)` for free via MRO.
- `register()` works on each tower class (reusing the
  `collections.abc` `abc_registered` machinery) so user classes can
  opt into a layer as a virtual subclass.

## [0.0.130] - 2026-04-26

### Added

- `graphlib` module: `TopologicalSorter` runs Kahn's algorithm for
  static and incremental output, and `prepare()` performs three-color
  DFS over the successor graph to detect cycles. `add()` accumulates
  predecessors across calls, `static_order()` walks `prepare()` /
  `get_ready()` / `done()` to a flat order, and `is_active()` tracks
  whether either ready or in-flight nodes remain.
- `CycleError` extends `ValueError` and carries `args = (msg, cycle)`
  so `e.args[1]` is the offending node list, matching CPython.
- Misuse paths raise `ValueError`: `add()` after `prepare()`,
  `done()` without `prepare()`, `done()` on a node that wasn't yet
  handed out by `get_ready()`, and `is_active()` before `prepare()`.

## [0.0.129] - 2026-04-26

### Added

- `enum` module: `Enum`, `IntEnum`, `StrEnum`, `Flag`, `IntFlag` base
  classes, `auto`, and `unique`. Each base carries an `EnumKind` marker
  on the class. After `__build_class__` finishes, the namespace walker
  promotes plain attributes to singleton member instances, threads
  `_name_` / `_value_` / `name` / `value` onto each member, builds
  `__members__`, and records the canonical-member list. `auto()`
  resolves to a sequential int for Enum/IntEnum, the next power of two
  for Flag/IntFlag, and the lowercased attribute name for StrEnum.
- `Cls(value)` looks up by value (or builds a Flag composite),
  `Cls['NAME']` looks up by name through `__class_getitem__`, and
  `iter`/`len`/`in` work on the class itself by reading the
  canonical-member list. `unique` raises `ValueError` when any name in
  `__members__` resolves to a member with a different `_name_`
  (i.e., an alias).
- IntEnum members compare equal to their int value and support
  `+` / `-` / `<` / `<=` / `>` / `>=` against ints and other members.
  StrEnum members compare equal to their string value. Flag members
  combine with `|` / `&` / `^` and report containment via `in`.
- Functional API: `Enum('Animal', ['ANT', 'BEE'])`,
  `Enum('Direction', 'NORTH SOUTH EAST WEST')`, and
  `Enum('Status', {'OK': 200})` all build a fresh subclass with the
  expected members.

## [0.0.128] - 2026-04-26

### Added

- `reprlib` module with the surface fixtures rely on. `Repr` is a real
  class with the per-type limits (`maxlevel`, `maxlist`, `maxtuple`,
  `maxdict`, `maxset`, `maxfrozenset`, `maxdeque`, `maxarray`,
  `maxstring`, `maxlong`, `maxother`) and `fillvalue` stored as
  instance attributes so user code can mutate them and have the next
  call honor the change. Truncation matches CPython byte for byte:
  containers cap at `max<kind>` items and append the fillvalue, strings
  and big ints split into a head/tail pair around the fillvalue, and
  the `maxlevel` cutoff replaces deeper nested containers with the
  fillvalue. Sets and frozensets are sorted before truncation, again
  matching CPython.
- `reprlib.repr`, `reprlib.aRepr`, and `Repr.repr1(obj, level)` are all
  exposed. `recursive_repr(fillvalue='...')` is a decorator factory:
  the wrapper detects re-entry on the same target and substitutes the
  fillvalue, so cyclic `__repr__` implementations terminate.

## [0.0.127] - 2026-04-26

### Added

- `pprint` module is now feature-complete enough for the fixture:
  `pformat`, `pprint`, and `pp` accept `width`, `indent`, `depth`,
  `compact`, and `sort_dicts`. The multi-line layout matches CPython
  byte-for-byte: items align at column `column + indent`, the first
  item gets the same alignment as the rest when `indent > 1`, and
  `compact=True` greedily packs items per line within `width`.
  `depth` collapses nested containers past the cutoff to `{...}`.
  `saferepr` detects cycles and emits `<Recursion on TYPE with
  id=N>`. `isreadable` and `isrecursive` walk the value with a seen-
  set. `PrettyPrinter` is a real class with `__init__` (kwargs),
  `pformat`, `pprint`, `format` (returning the
  `(repr, readable, recursive)` triple), `isreadable`, and
  `isrecursive`.

## [0.0.126] - 2026-04-26

### Added

- `copy` module gains the protocols and surface fixtures rely on:
  `__copy__` short-circuits `copy.copy(obj)`; `__deepcopy__(memo)`
  short-circuits `copy.deepcopy(obj)`. Default deepcopy of a user
  instance now clones the instance and deep-copies its attribute
  dict. `copy.deepcopy` threads a Zig-side memo keyed by pointer
  identity so cyclic structures terminate (`lst.append(lst)` round-
  trips with `lst2[2] is lst2`). `copy.replace(obj, **changes)`
  delegates to `__replace__`. `copy.error` and `copy.Error` are
  exposed as the same class.



### Added

- `types` module. The builtin-value types (`NoneType`, `EllipsisType`,
  `NotImplementedType`, `FunctionType` / `LambdaType`,
  `BuiltinFunctionType` / `BuiltinMethodType`, `MethodType`,
  `GeneratorType`, `ModuleType`) are exposed as proper `Class` objects
  carrying a `value_tag`, so `isinstance(x, types.NoneType)` reduces
  to a Value-tag check on `x` and `print(types.NoneType)` shows
  `<class 'NoneType'>`. `SimpleNamespace` and `MappingProxyType` are
  regular Class+Instance classes (kwargs-only ctor, attribute set/del,
  insertion-ordered `repr` / `__eq__` for the former; the read-only
  mapping surface for the latter). `types.new_class(name, bases,
  kwds, exec_body)` returns a fresh class after running `exec_body`
  against the namespace. `types.ModuleType('name', doc)` produces a
  real `.module` Value rather than going through `__init__`.
- `Class.value_tag` for the type-marker pattern above. When set,
  `isinstance` / class-pattern matching consult the tag instead of
  walking the MRO.

### Changed

- `LOAD_ATTR` on an instance miss now raises a real Python
  `AttributeError` (catchable by `try / except`) instead of bailing
  out with a Zig-level error. Previously the `del ns.x; ns.x` pattern
  bypassed the exception table.

## [0.0.124] - 2026-04-26

### Added

- `weakref` module covering the API surface fixtures rely on:
  `ref` / `ReferenceType` (calling a ref returns the target,
  no-callback refs to the same object share identity), `proxy` with
  `ProxyType` / `CallableProxyType` distinguished by whether the
  target is callable, `getweakrefcount` / `getweakrefs` over the
  per-target registry, `WeakValueDictionary` and `WeakKeyDictionary`
  with the full mapping surface (`__getitem__` / `__setitem__` /
  `__delitem__` / `__contains__` / `__len__` / `__iter__` / `get`
  / `pop` / `setdefault` / `update` / `clear` / `keys` / `values`
  / `items`), `WeakSet` with `add` / `discard` / `remove` / `pop` /
  `clear`, `finalize` with `alive` / `atexit` and one-shot `__call__`
  semantics, and `WeakMethod` returning the bound method. We don't
  run a GC, so all "weak" references are strong; everything else
  matches CPython byte-for-byte on the fixture.
- `__getattr__` fallback for instances. The lookup chain (instance
  dict, class MRO, descriptor protocol) now consults a class-level
  `__getattr__` before raising `AttributeError`. Required for
  `weakref.proxy`'s attribute delegation and matches CPython.
- `Class.qualname` for module-qualified `repr(cls)` output (e.g.
  `<class 'weakref.ReferenceType'>`) while `cls.__name__` keeps
  returning the bare class name.

### Changed

- Bare `obj.method` access on built-in types (list, dict, str, set,
  bytes, ...) and on user-class methods now returns a bound method,
  matching CPython. Previously the LOAD_ATTR path returned the raw
  function so `WeakMethod(calc.add)` and
  `finalize(obj, log.append, ...)` couldn't carry their `self`.
- `Value.equals` now compares user-class instances by identity when
  no `__eq__` override is in play. Dict/set keying on instances
  (e.g. `WeakKeyDictionary`) used to silently miss because the
  fallback `order(a, b)` returns null for instances.

## [0.0.123] - 2026-04-26

### Added

- `array` module with the `array.array` class. Supports the integer
  typecodes (`b B h H i I l L q Q`) and the floats (`f d`); `u`/`w`
  surface in `typecodes` but constructing one raises `ValueError`.
  Construction takes a list/tuple/iterable initializer or a bytes
  buffer (parsed little-endian). Method surface: `append`, `extend`,
  `fromlist`, `insert`, `pop`, `remove`, `count`, `index`,
  `reverse`, `tobytes`, `frombytes`, `tolist`, `buffer_info`,
  `byteswap`. Dunders cover `__getitem__` (int + slice, slice
  returns a fresh same-typecode array), `__setitem__`,
  `__delitem__`, `__len__`, `__iter__`, `__contains__`, `__repr__`.
  Per-typecode validation rejects the wrong value kind with
  `TypeError` and out-of-range integers with `OverflowError`.

## [0.0.122] - 2026-04-26

### Added

- `122_bisect` fixture, byte-equal on the first run with no code
  changes. The existing `bisect` module already covers
  `bisect_left`, `bisect_right`, `bisect`, `insort_left`,
  `insort_right`, `insort`, `key=`, `lo=`/`hi=` slicing, duplicate
  handling, and the empty-list edge cases the fixture exercises.

## [0.0.121] - 2026-04-26

### Fixed

- `heapq.merge` now performs a stable merge that honors the `key=`
  callable. The previous implementation concatenated the inputs and
  sorted on raw value, so callers passing pre-sorted-by-key sources
  (`heapq.merge(words1, words2, key=len)`) ended up with output
  reordered by string content.

## [0.0.120] - 2026-04-26

### Added

- `120_collections_abc` fixture, byte-equal. New `collections.abc`
  module exposes the 25 ABCs (`Hashable`, `Callable`, `Iterable`,
  `Iterator`, `Generator`, `Reversible`, `Sized`, `Container`,
  `Collection`, `Sequence`, `MutableSequence`, `Set`, `MutableSet`,
  `Mapping`, `MutableMapping`, `MappingView`, `KeysView`, `ItemsView`,
  `ValuesView`, `Awaitable`, `Coroutine`, `AsyncIterable`,
  `AsyncIterator`, `AsyncGenerator`, `Buffer`). `isinstance(obj, abc)`
  walks the MRO for the ABC itself or anything passed to
  `abc.register(cls)`, then a virtual-registration table for built-in
  types, then the `__subclasshook__` structural check that ABCs like
  `Hashable`, `Iterable`, `Sized`, `Callable`, `Buffer` ship in
  CPython.

### Changed

- Bare attribute access on a `classmethod` descriptor now produces a
  `BoundMethod` so a later call still injects the owning class as the
  first argument (`Sequence.register` was the trigger, but the fix is
  general).

## [0.0.119] - 2026-04-26

### Added

- `119_collections` fixture, byte-equal. `collections` now carries
  `ChainMap`, `UserDict`, `UserList`, and `UserString` as full
  class+instance pairs with the dunder surface (`__getitem__`,
  `__setitem__`, `__delitem__`, `__contains__`, `__len__`, `__iter__`,
  plus the per-class extras: `__add__`/`__lt__`/`__eq__` for the
  user-data wrappers, `parents` property and `new_child` for
  `ChainMap`). `defaultdict(factory, mapping)` now seeds from the
  optional second positional. Counter gains the `+`, `-`, `&`, `|`
  operators, unary `+` / `-`, `copy`, and a `fromkeys` that raises
  `NotImplementedError`. `OrderedDict` gains `copy`, `fromkeys`, and a
  type-preserving `__or__`. `defaultdict` gains a type-preserving
  `copy`. `deque` gains `copy`, `insert`, `remove`, `index(start, stop)`,
  and `del d[i]`. `namedtuple` gains `_field_defaults`, `_make`, and
  the `count`/`index` instance methods.

### Changed

- `type(...)` for `deque`, `defaultdict`, and `OrderedDict` now reports
  the short names (`deque`, `defaultdict`, `OrderedDict`) that CPython
  emits, dropping the `collections.` prefix.

## [0.0.118] - 2026-04-26

### Added

- `118_calendar` fixture, byte-equal. The pinhole `calendar` module now
  carries the full month-constant / Day / Month enum surface, the
  `firstweekday`/`setfirstweekday` pair, `weekheader`, `month`, and the
  `Calendar`/`TextCalendar`/`HTMLCalendar`/`LocaleTextCalendar`/
  `LocaleHTMLCalendar` class hierarchy. `monthrange` and
  `setfirstweekday` raise `IllegalMonthError`/`IllegalWeekdayError`
  (both `ValueError` subclasses) on out-of-range arguments.

## [0.0.117] - 2026-04-26

### Added

- `117_zoneinfo` fixture, byte-equal. New `zoneinfo` module with
  `ZoneInfo`, `ZoneInfoNotFoundError` (subclass of `KeyError`),
  `TZPATH`, `available_timezones`, and `reset_tzpath`. Recognised zone
  set is hard-coded (~150 entries); UTC and GMT carry real
  `_offset`/`_name` so attaching a `ZoneInfo` to a `datetime` formats
  correctly. `ZoneInfo(key)` is identity-cached per interp, and
  `no_cache`/`clear_cache(only_keys=...)` follow the documented
  contract.

### Changed

- `datetime` tzinfo dispatch now reads `_offset` from any tzinfo
  instance instead of hard-checking the `timezone` class. A `ZoneInfo`
  passed to `datetime(..., tzinfo=...)` now round-trips through
  `isoformat`, `utcoffset`, and `tzname` without special-casing.

## [0.0.116] - 2026-04-26

### Added

- `116_datetime` fixture, byte-equal. New `datetime` module with
  `timedelta`, `date`, `time`, `datetime`, `timezone`, and a stub
  `tzinfo`. Covers the surface the fixture exercises: keyword-arg
  constructors, arithmetic, comparisons, `isoformat`/`strftime`/
  `ctime`, `isocalendar`/`fromisocalendar`, `fromisoformat`,
  `fromordinal`/`toordinal`, `replace`, `combine`, `strptime`,
  `fromtimestamp`/`utcfromtimestamp`, plus `MINYEAR`/`MAXYEAR`/`UTC`
  module attrs and `min`/`max`/`resolution` class attrs.

### Changed

- `dispatch.instantiate` now accepts a `builtin_fn` `__init__`,
  routing through `kw_func` when constructor args include keywords.
  Previously only Python-function `__init__` was allowed, which
  forced a Python shim for any kw-aware builtin class.

### Fixed

- ISO week numbering for years that start Friday-Sunday. The first
  Thursday is now located via `mod 7`, fixing `isocalendar()` and
  `fromisocalendar()` whose results were off by 7 days for those
  years.

## [0.0.115] - 2026-04-26

### Added

- `115_codecs` fixture, byte-equal. New `codecs` module with BOM
  constants and `encode`/`decode` for utf-8/ascii/latin-1 plus the
  hex_codec, base64_codec, and rot_13 transforms. Error modes
  `ignore`/`replace`/`xmlcharrefreplace`/`backslashreplace` for ascii
  encode and `ignore`/`replace` for ascii decode. `lookup` returns a
  CodecInfo with `name`/`encode`/`decode`. Adds `getencoder`,
  `getdecoder`, the error-handler registry
  (`register_error`/`lookup_error` paired with `*_errors` attributes
  that match by identity), `iterencode`/`iterdecode`, and
  `charmap_build`.
- `callable()` builtin.

## [0.0.114] - 2026-04-26

### Added

- `114_struct` fixture, byte-equal. The `struct` module gains a real
  `struct.error` Exception subclass (raised on bad format chars, short
  buffers, and integer overflow), the `Struct` class with
  `pack`/`unpack`/`unpack_from`/`pack_into`/`iter_unpack` plus
  `format` and `size` attributes, module-level `pack_into` and
  `iter_unpack`, the `'p'` Pascal-string code, and the `'e'` IEEE 754
  binary16 half-float code. Integer codes now range-check rather than
  silently truncating.

## [0.0.113] - 2026-04-26

### Added

- `113_rlcompleter` fixture, byte-equal. New `rlcompleter` module with
  a `Completer` factory + class method `complete(text, state)` that
  walks builtins, the optional namespace, and Python keywords (with a
  trailing space) for prefix completion. Dotted text walks the named
  expression's attribute dict (modules, classes, instances), and
  callable matches get a trailing `(`. The `os` module gains a small
  `os.path` stub with `join` so dotted probes have something to find.

## [0.0.112] - 2026-04-26

### Added

- `112_readline` fixture, byte-equal. New in-memory `readline` module:
  history (add/remove/replace/clear/get/lengths), line buffer with
  `insert_text`, completer + completer delims, completion bounds at
  zero, startup/pre-input/display hook setters, a `parse_and_bind`
  no-op, and a `read_init_file` that raises OSError when given a
  missing path.

## [0.0.111] - 2026-04-26

### Added

- `111_stringprep` fixture, byte-equal. New `stringprep` module covering
  RFC 3454 lookup tables: A.1 unassigned, B.1 mapped-to-nothing, B.2/B.3
  case folding, the C.1.1 through C.9 disallowed-character tables, and
  the D.1/D.2 bidi tables. Codepoint decoding accepts WTF-8 surrogate
  pairs so the C.5 probe against U+D800 reaches the predicate.

## [0.0.110] - 2026-04-26

### Added

- `110_unicodedata` fixture, byte-equal. New `unicodedata` module with
  `name`/`lookup` (small named-char table plus CJK ideograph
  synthesis), `decimal`/`digit`/`numeric` value lookups, `category`,
  `bidirectional`, `combining`, `east_asian_width`, `mirrored`,
  `decomposition`, plus `normalize` and `is_normalized` for NFC, NFD,
  NFKC, NFKD.

## [0.0.109] - 2026-04-26

### Added

- `109_textwrap` fixture, byte-equal. `indent` honors a `predicate`
  keyword. `wrap` and `fill` now respect `initial_indent`,
  `subsequent_indent`, `max_lines`, `placeholder`, `expand_tabs`,
  `tabsize`, `replace_whitespace`, `drop_whitespace`,
  `break_long_words`. New `TextWrapper` class exposing the same knobs
  as instance attributes plus `wrap`/`fill` methods. `shorten` is now
  built on top of the shared core with `max_lines=1`.

## [0.0.108] - 2026-04-26

### Added

- `108_difflib` fixture, byte-equal. `SequenceMatcher` now accepts both
  strings and lists. New methods: `find_longest_match`,
  `get_matching_blocks`, `get_opcodes` (Ratcliff-Obershelp). New
  module-level `context_diff` (with the `*** ... ****` /
  `--- ... ----` two-block format), `restore(diff, 1|2)`, and a
  minimal `Differ` class with `compare` for non-fancy line diffs.

## [0.0.107] - 2026-04-26

### Added

- `107_re_syntax` fixture, byte-equal. `\A` and `\Z` anchors via new
  `bos`/`eos` opcodes. `\A` matches strict start of string and `\Z`
  matches strict end of string; multiline does not loosen them.

## [0.0.106] - 2026-04-26

### Added

- `106_re_pattern` fixture, byte-equal. `Pattern.groups` (count) and
  `Pattern.groupindex` (read-only name → 1-based index dict).
  `Match.pos` and `Match.endpos`. `Match.__getitem__` delegating to
  `.group`. `default=` kwarg on `Match.groups` and `Match.groupdict`,
  letting callers replace `None` for non-participating groups.

## [0.0.105] - 2026-04-26

### Added

- `105_re_functions` fixture, byte-equal. `re.purge()` (no-op since
  the runtime keeps no compile cache), the missing `VERBOSE`/`X`,
  `ASCII`/`A`, `UNICODE`/`U`, and `NOFLAG` constants, an `re.error`
  exception class (subclassed from `ValueError` so existing call
  sites that already raise `ValueError` stay catchable), and
  `VERBOSE` flag handling in `compile` — strips ASCII whitespace and
  `#` comments outside character classes, honoring backslash escapes
  so `\ ` keeps the literal space.

## [0.0.104] - 2026-04-26

### Added

- `104_templatelib` fixture, byte-equal. `string.templatelib` module
  with `Template`, `Interpolation`, and `convert`. The runtime objects
  already existed (`BUILD_TEMPLATE` / `BUILD_INTERPOLATION` emit them);
  this round adds a manual `Template` constructor that merges
  consecutive strings and pads consecutive `Interpolation`s with `''`,
  a manual `Interpolation(value, expression, conversion=None,
  format_spec='')` constructor, `__add__` for `Template + Template`
  concatenation that glues the trailing string to the leading one,
  `__iter__` that yields strings and `Interpolation`s interleaved
  (skipping empty strings), `Template` repr matching CPython, and the
  `convert()` free function. `isinstance(x, Template | Interpolation)`
  now matches by class name.

## [0.0.103] - 2026-04-26

### Added

- `103_string_template` fixture, byte-equal. `string.Template` class
  with `substitute`, `safe_substitute`, `is_valid`, `get_identifiers`,
  and a `.template` attribute. `substitute` raises `KeyError` on a
  missing key; `safe_substitute` leaves the original placeholder text
  in place (and tolerates a trailing `$` or one followed by a
  non-identifier). Both forms accept a mapping arg, kwargs, or both,
  with kwargs winning on conflict. `get_identifiers` preserves
  first-seen order and dedupes.

## [0.0.102] - 2026-04-26

### Added

- `102_string_formatter` fixture, byte-equal. `string.Formatter` class
  with `format`, `vformat`, `format_field`, `convert_field`, `parse`,
  `get_value`, and `check_unused_args`. `parse()` yields the same
  `(literal, field_name, format_spec, conversion)` quads as CPython,
  including the trailing `(literal, None, None, None)` on a closed
  brace; `format_field` reuses the `str.format` mini-language renderer
  added in 0.0.101; `convert_field` handles `'s'`, `'r'`, `'a'`, and
  `None` passthrough.

## [0.0.101] - 2026-04-26

### Changed

- `str.format` rewritten to handle the full Python mini-language:
  dotted/bracketed field paths, `!s`/`!r`/`!a` conversions, fill+align
  (`< > = ^`), sign, `#` alt form, `0` zero-pad, width, `,`/`_`
  grouping, `.precision`, types `b c d e E f F g G o s x X %`, and
  nested specs (`{0:{1}}`).

## [0.0.100] - 2026-04-26

### Added

- `100_string_constants` fixture, byte-equal. `string.capwords(s,
  sep=None)`: with `sep`, split on literal sep and join with same
  sep; without sep, split on runs of ASCII whitespace and join with
  a single space.

## [0.0.99] - 2026-04-26

### Added

- `99_threading_module` fixture, byte-equal. New pinhole `threading`:
  Lock, RLock, Thread (target runs inline on start), Event,
  Semaphore, Condition, Barrier, local; plus current_thread,
  main_thread, active_count, enumerate, get_ident.

## [0.0.98] - 2026-04-26

### Added

- `98_threadsafe_memoryview` fixture, byte-equal. memoryview gains
  ndim/shape/strides/suboffsets/c_contiguous/f_contiguous/contiguous/
  obj attributes; bytearray tracks a view count, and mutating
  methods raise BufferError while a view is still holding the buffer.

## [0.0.97] - 2026-04-26

### Added

- `97_threadsafe_bytearray` fixture, byte-equal. `bytearray.copy()`
  returns a fresh mutable copy; `bytes * n` and `bytearray * n` (and
  the swapped forms) produce repeated buffers.

## [0.0.96] - 2026-04-26

### Added

- `96_threadsafe_set` fixture, byte-equal. The Python 3.13+
  thread-safety set operations all already worked — the fixture
  locks them down.

## [0.0.95] - 2026-04-26

### Added

- `95_threadsafe_dict` fixture, byte-equal. The Python 3.13+
  thread-safety dict operations (lock-free reads, locked writes,
  copy/merge, fromkeys, pop-with-default, copy-before-iterate) all
  already worked — the fixture locks them down.

## [0.0.94] - 2026-04-26

### Added

- `94_threadsafe_list` fixture, byte-equal.
- `list + list` and `tuple + tuple` concatenate.

## [0.0.93] - 2026-04-26

### Added

- `93_exceptions_new` fixture, byte-equal.
- `sys.exit` raises `SystemExit` so `try/except` can catch it; the
  top-level main exits with the carried code if the exception
  escapes the script.
- New pinhole `warnings` module backing `warnings.warn(msg, category)`.
- `EnvironmentError` aliases `OSError`.

## [0.0.92] - 2026-04-26

### Added

- `92_exceptions_hierarchy` fixture, byte-equal.
- Builtin exception tree mirrors CPython 3.14: SystemExit/
  KeyboardInterrupt/GeneratorExit, the full Arithmetic/Lookup/Name/
  Import/OS/Connection/Syntax/Unicode families, the entire Warning
  tree, RecursionError, BufferError, MemoryError, ReferenceError,
  SystemError, EOFError, and BaseExceptionGroup/ExceptionGroup (the
  latter multi-inherits BaseExceptionGroup and Exception).
- `IOError` aliases `OSError`.

## [0.0.91] - 2026-04-26

### Added

- `91_bytes_methods` fixture, byte-equal.
- New `bytesops` module shares hex/join/strip/lstrip/rstrip/upper/
  lower/center/ljust/rjust/zfill/count/find/rfind/index/startswith/
  endswith/replace/split between `bytes` and `bytearray`.
- `bytes.fromhex` and `bytearray.fromhex` via class-level attr
  access.

## [0.0.90] - 2026-04-26

### Added

- `90_dict_set_methods` fixture, byte-equal.
- dict: `popitem`; `dict.fromkeys` via class-level attr access;
  `dict | dict` and `dict |= dict` produce a merged dict.
- set: `pop`, `clear`, `update`, `intersection_update`,
  `difference_update`, `symmetric_difference_update`.

## [0.0.89] - 2026-04-26

### Added

- `89_range_methods` fixture, byte-equal.
- range: `start`, `stop`, `step` attrs; `count`, `index` methods;
  `len()` and `in` membership for positive- and negative-step ranges.

## [0.0.88] - 2026-04-26

### Added

- `88_int_float_methods` fixture, byte-equal.
- int: `bit_length`, `bit_count`, `to_bytes` (with `signed` kwarg),
  `conjugate`, `as_integer_ratio`; `int.from_bytes` via the `int`
  builtin; `numerator`/`denominator`/`real`/`imag` attrs.
- float: `is_integer`, `as_integer_ratio`, `conjugate`;
  `float.fromhex` via the `float` builtin; `real`/`imag` attrs.

## [0.0.87] - 2026-04-26

### Added

- `87_str_methods` fixture, byte-equal.
- Full coverage of `str` methods: case ops (lower/title/swapcase/
  casefold/capitalize), predicates (isalpha/isdigit/isalnum/isspace/
  isupper/islower/istitle/isidentifier/isprintable/isascii/isdecimal/
  isnumeric), splits (rsplit, splitlines, partition, rpartition; split
  honors maxsplit; replace honors count), find/rfind/index/rindex,
  removeprefix/removesuffix, padding (center, ljust, rjust, zfill,
  expandtabs), translate, encode, format.
- `startswith`/`endswith` accept a tuple of candidates.
- `str.maketrans` via attribute access on the `str` builtin.

## [0.0.86] - 2026-04-26

### Added

- `86_builtin_constants` fixture, byte-equal.
- `Ellipsis == Ellipsis` and `NotImplemented == NotImplemented`.
- Unsupported BINARY_OP `+` raises a real Python `TypeError` so
  `try / except TypeError` catches it.

## [0.0.85] - 2026-04-26

### Added

- `85_opcode_stress` fixture, byte-equal.
- `bytes.decode()`.
- `list.sort` (with key/reverse kwargs), `insert`, `remove`, `index`,
  `count`, `clear`, `copy`.
- `dict.update` (positional and keyword), `setdefault`, `clear`, `copy`.
- Interpolation instance repr matches CPython.

## [0.0.84] - 2026-04-26

### Added

- `84_init_check` fixture, byte-equal.
- TypeError when `__init__` returns a non-None value, matching CPython's
  EXIT_INIT_CHECK opcode semantics.

## [0.0.83] - 2026-04-26

### Added

- `83_tstrings` fixture, byte-equal.
- BUILD_INTERPOLATION and BUILD_TEMPLATE opcodes (PEP 750 t-strings).
- Synthetic Template/Interpolation classes; `list(template)` yields
  interleaved string + Interpolation pieces; `template.values` shortcut.

## [0.0.82] - 2026-04-26

### Added

- `82_annotations` fixture, byte-equal.
- SET_FUNCTION_ATTRIBUTE arg=16 (PEP 649 lazy annotate) is ignored.
- `str * int` and `int * str` sequence repetition.
- `str.strip` / `lstrip` / `rstrip` with optional chars.

## [0.0.81] - 2026-04-26

### Added

- `81_async_for` fixture, byte-equal.
- GET_AITER, GET_ANEXT, END_ASYNC_FOR opcodes; nested async-for
  unwinds correctly when inner `__anext__` raises StopAsyncIteration.

## [0.0.80] - 2026-04-26

### Added

- `80_builtins_missing` fixture, byte-equal.
- Builtins `globals`, `locals`, `vars`, `aiter`, `anext`, `breakpoint`,
  `help`, `object`. `locals()` and `vars()` (no-arg) snapshot
  `frame.fast` when the locals dict aliases globals.
- `open()` reads/writes real files via `interp.io`; supports `r`/`w`/`b`
  modes and the context-manager protocol.
- New exceptions: `StopAsyncIteration`, `OSError`, `FileNotFoundError`.
- Pinhole `os` module: `remove`/`unlink`.

## [0.0.79] - 2026-04-26

### Added

- `78_traceback_sys_await_stress` fixture, byte-equal.
- `sys.version` string and `sys.setrecursionlimit`/`getrecursionlimit`
  round-trip via a new `Interp.recursion_limit` field.
- `sys.stdout`/`sys.stderr` expose `name`, `mode`, `closed`, `encoding`.
- `tb_lasti` on synthetic traceback wrappers.
- Generators answer `__await__` with themselves so user awaitables can
  delegate to async-def via `return self._run().__await__()`.
- `isinstance(cls, type)` is true for any user class.

## [0.0.78] - 2026-04-26

### Added

- `77_traceback_sys_await` fixture, byte-equal.
- Pinhole `sys` module: version_info, byteorder, maxsize, modules, path,
  argv, getrecursionlimit, exc_info, exit, stdout/stderr proxies with
  write/flush.
- Synthetic traceback chain: `__traceback__.tb_frame.f_code.co_name`
  walkable after a raise; dispatch records each frame on PyException
  receipt.
- Exception chaining: `raise X from Y` sets `__cause__` and
  `__suppress_context__`; raise-during-except sets `__context__` from
  the active handler.
- `sys.exc_info()` driven by exception state tracked through
  PUSH_EXC_INFO / POP_EXCEPT.
- GET_AWAITABLE accepts user instances with `__await__`.

## [0.0.77] - 2026-04-26

### Added

- `76_statistics_calendar_pprint_html_stress` fixture, byte-equal.
- statistics: `mean`/`variance`/`pvariance` return int when result is
  whole and inputs are all ints (CPython Fraction parity); `fmean`
  always returns float; iterator inputs accepted via `seqFloats`.
- statistics.quantiles `method="inclusive"`.
- pprint.pformat/pprint `sort_dicts=False`.

## [0.0.76] - 2026-04-26

### Added

- `75_statistics_calendar_pprint_html` fixture, byte-equal.
- statistics: mean/fmean/median/median_low/median_high, mode/multimode,
  pvariance/variance/pstdev/stdev, geometric_mean/harmonic_mean,
  quantiles with `n=` kwarg.
- calendar: isleap/leapdays/weekday/monthrange/monthcalendar/timegm,
  MONDAY..SUNDAY, month_name/month_abbr/day_name/day_abbr lists.
- pprint: pformat/pprint with `width=` kwarg breaking lists when the
  single-line form overflows; sorted dict keys; saferepr; isreadable.
- html: escape with `quote=` kwarg (apostrophe escapes to `&#x27;`);
  unescape covering `&lt;/&gt;/&amp;/&quot;/&apos;/&copy;/&hellip;` and
  numeric `&#NNN;` / `&#xHH;` refs.

## [0.0.75] - 2026-04-26

### Added

- `74_difflib_shlex_gzip_fnmatch_stress` fixture, byte-equal.
- difflib SequenceMatcher: `a`, `b` attrs; `set_seq1`/`set_seq2`/
  `set_seqs` methods; `quick_ratio` alias.
- gzip writes the `1f 8b` magic header; `compresslevel=` kwarg.
- fnmatch.translate.

### Fixed

- `get_close_matches` tie-breaks by lexicographic descending word.
- `unified_diff` returns `[]` when sequences are identical.

## [0.0.74] - 2026-04-26

### Added

- `73_difflib_shlex_gzip_fnmatch` fixture, byte-equal against
  CPython 3.14.
- `difflib`: `get_close_matches`, `SequenceMatcher.ratio` (and the
  `quick_*` aliases), `ndiff`, `unified_diff`.
- `shlex`: `quote`, `join`, `split` (POSIX rules).
- `gzip`: `compress` / `decompress` (round-trip via the zlib_mod
  LZ format).
- `fnmatch`: `fnmatch`, `fnmatchcase`, `filter` with `*`, `?`,
  `[..]`, `[!..]` classes.

## [0.0.73] - 2026-04-26

### Added

- `72_binascii_uuid_hmac_secrets_stress` fixture, byte-equal against
  CPython 3.14.
- `binascii.crc32(data, seed)` second-arg seeding for chained CRCs.
- `hmac.new` accepts `digestmod=` and `msg=` kwargs; `name` attr
  now reads `hmac-{algo}`.
- `uuid.UUID(int=...)`, `UUID(bytes_le=...)`, `urn:uuid:` and braced
  string parsing; `bytes_le`, `urn`, `fields`, `variant` attrs;
  `uuid3` (MD5 namespaced); `NAMESPACE_OID` and `NAMESPACE_X500`.
- `secrets.choice` over `str` returns a 1-char `str`; `token_*`
  accept `n=0`.

### Fixed

- Marshal's long reader preserves big ints instead of clamping the
  accumulator to `i64`.
- `BINARY_OP <<` promotes to `big_int` when the shift result
  overflows `i64`.
- `Value.order` handles mixed `small_int`/`big_int` via
  `Const.orderAgainstScalar`, so chain comparisons resolve.
- `struct.pack`/`unpack` accept big_int input and emit big_int
  output for u64 values that don't fit `i64`.

## [0.0.72] - 2026-04-26

### Added

- `71_binascii_uuid_hmac_secrets` fixture, byte-equal against
  CPython 3.14.
- `binascii` module: `hexlify`/`unhexlify`/`b2a_hex`/`a2b_hex`,
  `b2a_base64(..., newline=False)` / `a2b_base64`, and `crc32`.
- `hmac` module: `hmac.new(key, msg, digestmod)` (string name or
  hashlib constructor), `hmac.digest`, `hmac.compare_digest`,
  with `name`, `digest_size`, and `block_size` attrs on the
  HMAC object.
- `secrets` module: `token_bytes` / `token_hex` / `token_urlsafe`,
  `randbelow` / `randbits`, `choice`, and `compare_digest`.
- `uuid` module: `UUID(hex)` / `UUID(bytes=...)`, `uuid4`, `uuid5`,
  `NAMESPACE_DNS` / `NAMESPACE_URL`, with `bytes` / `hex` / `int` /
  `version` attrs and a canonical `__str__`.

## [0.0.71] - 2026-04-25

### Added

- `70_struct_csv_urlparse_zlib_stress` fixture, byte-equal against
  CPython 3.14.
- `urllib.parse.urlsplit` / `urlunsplit`, plus a `urllib` package
  module so `import urllib.parse as up` resolves cleanly.
- `urllib.parse.urlencode(..., doseq=True)`.
- `csv.writer` accepts a `delimiter=` keyword argument.
- `ParseResult` is iterable (`__iter__`) and supports `len()`.
- `zlib.MAX_WBITS = 15`.

### Changed

- `struct` format strings tolerate ASCII whitespace between codes
  (e.g. `"< i h b"`).
- `IMPORT_NAME` walks dotted builtin names so `import a.b` binds
  `a` (the package) rather than the inner module.

## [0.0.70] - 2026-04-25

### Added

- `69_struct_csv_urlparse_zlib` fixture, byte-equal against
  CPython 3.14.
- `struct` module: `calcsize`, `pack`, `unpack`, `unpack_from`
  with the common format codes (`bBhHiIlLqQfd?sxc`) and the
  endian prefixes `<`, `>`, `!`, `=`, `@`.
- `csv` module: `reader`, `writer`, `DictReader`, `DictWriter`,
  the `excel` and `excel-tab` dialects, and the `QUOTE_*`
  constants.
- `urllib.parse` module: `urlparse` / `urlunparse` / `urljoin`
  / `quote` / `unquote` / `quote_plus` / `unquote_plus` /
  `urlencode` / `parse_qs` / `parse_qsl`. The `ParseResult`
  exposes named attributes plus tuple indexing.
- `zlib` module: `compress` / `decompress` (round-trip
  consistent with itself, not bit-compatible with real zlib),
  `crc32` / `adler32` (real CPython values), and the standard
  level constants.

## [0.0.69] - 2026-04-25

### Added

- `68_io_hashlib_base64_textwrap_stress` fixture, byte-equal
  against CPython 3.14.
- `io.{StringIO,BytesIO}.truncate(size?)`.
- `hashlib.sha224`, `hashlib.sha384`, and `hashlib.<h>.copy()`.
- `base64.standard_b64encode` / `standard_b64decode` aliases.
- `str.count(sub)` method.

### Changed

- `io.StringIO.writelines` accepts iterators and tuples, not just
  lists. `io.BytesIO.write` accepts `bytearray`.
- `hashlib` accepts `bytearray` wherever it accepted `bytes`.
- `hashlib.new("unknown")` raises a catchable `ValueError`.
- `base64.b64decode` rejects non-multiple-of-4 length with a
  catchable `ValueError`.
- `textwrap.wrap` breaks long words at the width boundary by
  default, matching CPython.

### Fixed

- `io` and `hashlib` class objects are now cached on the `Interp`
  instead of in module-level statics, so consecutive interpreters
  in the integration test no longer share stale pointers.

## [0.0.68] - 2026-04-25

### Added

- `67_io_hashlib_base64_textwrap` fixture, byte-equal against
  CPython 3.14.
- `io` module: `StringIO` and `BytesIO` with `write`/`read`/
  `readline`/`readlines`/`writelines`/`seek`/`tell`/`getvalue`/
  `close`.
- `hashlib` module: `md5`, `sha1`, `sha256`, `sha512`, and
  `new(name, data=b"")`. Hash objects expose `update`, `digest`,
  `hexdigest`, `digest_size`, `name`. Backed by `std.crypto.hash`.
- `base64` module: `b64encode`/`b64decode`, `urlsafe_b64encode`/
  `urlsafe_b64decode`, `b32encode`/`b32decode`, `b16encode`/
  `b16decode`.
- `textwrap` module: `dedent`, `indent`, `wrap`, `fill`,
  `shorten`.

## [0.0.67] - 2026-04-25

### Added

- `66_json_re_string_copy_stress` fixture, byte-equal against
  CPython 3.14.
- Regex word boundaries `\b` and `\B` via new `wb`/`nwb` opcodes.
- `Match.expand` method, sharing the replacement template parser
  with `re.sub`.
- `copy.copy` and `copy.deepcopy` for `set` (and `frozenset`).
- `Match.lastindex` and `Match.lastgroup` attributes.
- `type(x).__name__` works for instances of primitive types like
  `int` and `float` via a lazy primitive-class cache.

### Changed

- `re.compile` raises a Python `ValueError` for invalid patterns
  instead of aborting with a runtime error, so user code can
  catch it.
- `json.dumps` coerces non-string dict keys (`int`, `float`,
  `bool`, `None`) to their string form, matching CPython.
- `repr(str)` escapes control bytes, backslashes, and newlines
  the same way CPython does, including the `'` vs `"` quote
  choice.

## [0.0.66] - 2026-04-25

### Added

- `65_json_re_string_copy` fixture, byte-equal against CPython
  3.14.
- `json` module: `dumps` (with `indent`, `sort_keys`,
  `separators`, `ensure_ascii`) and `loads`. Non-ASCII renders
  as `\uXXXX`; codepoints above U+FFFF use surrogate pairs.
- `re` module: a small backtracking regex engine living under
  `src/lib/re/` with its own SPEC, AST, compiler, matcher, and
  unit tests; bridged through `src/vm/re_mod.zig`. Supports
  literals, `.`, `^`, `$`, char classes (`\d \D \w \W \s \S`,
  `[abc]`, `[a-z]`, `[^abc]`), `* + ? {n,m}` (greedy and lazy),
  alternation, groups (`(...)`, `(?:...)`, `(?P<name>...)`),
  backreferences in patterns, and the `IGNORECASE` /
  `MULTILINE` / `DOTALL` flags. `match`, `search`, `fullmatch`,
  `findall`, `finditer`, `split`, `sub`, `subn`, `compile`,
  `escape`. Match objects expose `group`, `groups`,
  `groupdict`, `span`, `start`, `end`. `re.sub` accepts both
  string templates (`\1` … `\9`, `\g<name>`) and callables.
  Out-of-scope features (`\b`, lookaround, inline flags,
  Unicode property classes) raise `error.UnsupportedRegex` at
  compile time rather than mismatching silently.
- `string` module: ASCII / digit / punctuation / whitespace
  constants the fixture prints.
- `copy` module: `copy.copy` (shallow) and `copy.deepcopy`
  (recursive on `list`, `dict`, `tuple`; identity for
  immutables).
- Element-wise structural equality for `dict == dict`.

## [0.0.65] - 2026-04-25

### Added

- `64_math_heap_bisect_random_stress` fixture, byte-equal
  against CPython 3.14.
- `math.fsum` (Kahan-Neumaier compensated summation, so
  `fsum([0.1] * 10) == 1.0` exactly).
- `heapq.nlargest` / `nsmallest` accept `key=`. `heapq.merge`
  accepts `reverse=`.
- `bisect.bisect_left` / `bisect_right` / `insort_left` /
  `insort` accept `lo`, `hi`, and `key=` (positional and
  keyword).
- `random.randrange` (1-, 2-, or 3-argument forms; raises
  `ValueError` on empty range or zero step) and
  `random.uniform`.
- Sequence repetition: `list * int`, `int * list`, and the
  same for `tuple`. Backed by a fresh container.
- Element-wise structural equality for `list == list` and
  `tuple == tuple`. Previously they fell through to identity.

## [0.0.64] - 2026-04-25

### Added

- `63_math_heap_bisect_random` fixture, byte-equal against
  CPython 3.14.
- `math` module: constants (`pi`, `e`, `tau`, `inf`, `nan`) and
  the bulk of CPython's surface used in numerical code:
  `sqrt`, `ceil`, `floor`, `trunc`, `fabs`, `gcd`, `lcm`,
  `factorial`, `comb`, `perm`, `hypot`, `dist`, `prod`,
  `isclose`, `log`, `log2`, `log10`, `exp`, `sin`, `cos`,
  `tan`, `atan2`, `degrees`, `radians`, `copysign`, `fmod`,
  `isfinite`, `isinf`, `isnan`, `modf`, `frexp`, `ldexp`.
- `heapq` module: `heappush`, `heappop`, `heapify`,
  `heappushpop`, `heapreplace`, `nlargest`, `nsmallest`,
  `merge`. The list invariant is maintained by sorting; fine
  for the fixture sizes, no real heap structure required.
- `bisect` module: `bisect_left`, `bisect_right`, `bisect`
  (alias), `insort_left`, `insort` / `insort_right`.
- `random` module: `seed`, `random`, `randint`, `choice`,
  `choices` (with `k=` kwarg), `shuffle`, `sample`. Backed by
  Zig's `DefaultPrng` -- not Mersenne-Twister, so byte
  reproducibility against CPython is not claimed; same-seed
  determinism within zag is.

## [0.0.63] - 2026-04-25

### Added

- `62_collections_operator_stress` fixture, byte-equal against
  CPython 3.14. Exercises the corners of m62: deque overflow
  rules, `Counter` from a dict (preserve values, not just keys),
  `defaultdict.default_factory`, nested defaultdicts,
  `OrderedDict.move_to_end` / `popitem` errors, and `namedtuple`
  with `defaults=`.
- `namedtuple(..., defaults=[...])`. Defaults align with the
  trailing fields, fill in unset positions on construction, and
  raising required fields still raises a Python-level
  `TypeError` (catchable via `except`).
- `Counter.update` / `.subtract` accept a dict-shaped argument
  (`dict`, `Counter`, `defaultdict`, `OrderedDict`) and merge
  the values directly, instead of iterating keys and counting
  them.
- `default_factory` attribute on `defaultdict`.
- `set.add` / `set.discard` / `set.remove`. The fixture builds
  values into a `defaultdict(set)`.
- `BINARY_SUBSCR` membership (`in`) for `deque`, `Counter`,
  `defaultdict`, `OrderedDict`, `named_tuple`, and iteration
  (`GET_ITER`) for the same set.
- `operator.index` (passes ints / bools through, raises
  `TypeError` otherwise) and a kw-aware `methodcaller` so
  `methodcaller("greet", "world", excited=True)` works.
- `sorted(iterable, key=..., reverse=...)`. Computes keys
  upfront, sorts indices, rebuilds the slice in order.
- `KeyError` formats `args[0]` via repr (`'x'`, with quotes) to
  match CPython's `str(KeyError("x"))`. Other exceptions still
  go through `writeStr`.
- `print` uses an interp-aware deep-repr writer so user-defined
  `__repr__` shows up inside `[...]` / `(...)` / `{...}` when
  printing containers of instances.

## [0.0.62] - 2026-04-25

### Added

- `61_collections_operator` fixture, byte-equal against CPython
  3.14. Covers a `collections` core --
  `deque(append/appendleft/pop/popleft/extend/extendleft/rotate/reverse/count/index/clear)`
  with `maxlen=` trimming, `Counter` (build from str / kwargs,
  `most_common`, `elements`, `update`, `subtract`, `total`, key
  subscript with 0-default), `defaultdict(factory)` with
  missing-key auto-fill, `OrderedDict` with
  `move_to_end(last=)` / `popitem(last=)`, and
  `namedtuple(typename, fields)` with positional/kw construction,
  field attribute access, `_asdict`, `_replace`, `_fields`, and
  pairwise equality between instances.
- `operator` module: arithmetic / bitwise / shift / comparison /
  unary wrappers, `getitem` / `setitem` / `delitem` / `contains`,
  and the curried builders `attrgetter`, `itemgetter`,
  `methodcaller` (built on `Partial` + a trampoline `BuiltinFn`).
- `dict(...)` now accepts the new mapping-shaped values
  (`defaultdict`, `OrderedDict`, `Counter`) and copies their
  pairs in insertion order, instead of falling through to the
  iter-of-pairs path.
- `BINARY_SUBSCR` / `STORE_SUBSCR` arms for `deque` (int index
  with negative wrap), `Counter` (str key, missing returns
  `0`), `defaultdict` (missing key calls factory and stores),
  `OrderedDict` (str key), and `named_tuple` (int index).
- `LOAD_ATTR` for `deque.maxlen`, `named_tuple.<field>`, and
  `NamedTupleFactory._fields`. Method dispatch on
  `defaultdict` / `Counter` / `OrderedDict` falls through to
  `dictmethods` with the underlying dict swapped in as `self`,
  so `.items()` / `.keys()` / `.values()` Just Work.
- `invokeKw` arm for `named_tuple_factory`: validates positional
  + kwarg coverage of all fields with no duplicates and no
  unknowns, then constructs a `NamedTuple` sharing the factory's
  field table.
- `Value.equals` for `named_tuple` is field-wise; instances of
  the same factory with equal items compare equal, otherwise
  `False`.

## [0.0.61] - 2026-04-25

### Added

- `60_functools_itertools_stress` fixture, byte-equal against
  CPython 3.14. Pushes the stdlib coverage past the basics:
  `lru_cache` LRU eviction with `maxsize`, `cache_info()` /
  `cache_clear()`, kwargs in the cache key, `partial`
  call-time kwargs overriding bound ones, `cached_property`
  recompute after `del instance.__dict__[name]`,
  `itertools.product(repeat=N)` and the `()` / `[]` edges,
  `accumulate(initial=...)` and `accumulate(iter, max)`,
  `groupby(iter, key=...)` with consecutive-key runs,
  `tee(iter)` independent iterators, `count(start, step)`
  with float arguments, `permutations(iter, 0)` /
  `combinations(iter, 0)` empty-r edges.
- `cache_info()` returns a 4-tuple `(hits, misses, maxsize,
  currsize)`; `cache_clear()` resets stats and the cache.
  `LOAD_ATTR` on a `cached_fn` returns these as bound
  methods so `kw.cache_info()` works.
- `itertools.groupby` and `itertools.tee` (eager, list-backed
  copies; the fixture wraps both in `list(...)` so laziness
  is invisible).
- `itertools.count` honors `start` and `step` of type
  `float`, materializing a long-but-finite stream that
  `islice` truncates in time.

### Changed

- `lru_cache` evicts the oldest entry when at `maxsize` and
  promotes the most recently accessed key to the back of
  `Dict.pairs` on a hit. The fixture's `seen` list confirms
  the LRU order matches CPython.
- `functools.partial` now skips bound kwargs that the call
  also provides, so `p(2, c=99)` wins over a partial bound
  `c=10` instead of raising "got multiple values".
- `accumulate` and `product` accept their kwargs (`initial=`,
  `repeat=`) via `kw_func` registration.

## [0.0.60] - 2026-04-25

### Added

- `59_functools_itertools` fixture, byte-equal against CPython
  3.14. Covers a representative slice of both stdlib modules:
  `reduce`, `partial` (positional + keyword binding),
  `lru_cache`, `cache`, `wraps`, `cached_property`; `count`,
  `cycle`, `repeat`, `chain` and `chain.from_iterable`,
  `compress`, `dropwhile`, `takewhile`, `starmap`,
  `zip_longest`, `product`, `permutations`, `combinations`,
  `combinations_with_replacement`, `accumulate`, `pairwise`,
  `filterfalse`, `islice`.
- `functools` and `itertools` builtin modules. Lazy-built on
  first import, like `asyncio` and `importlib`.
- `Value.partial` carrying `(func, bound_args, bound_kwargs)`;
  `Value.cached_fn` carrying `(func, cache, maxsize)`;
  `Value.cached_property` carrying `(func, name)`. All three
  route through `invokeKw` (and, for `cached_property`,
  through instance `LOAD_ATTR`).
- `int(s, base=...)` accepts `base` as a positional or keyword
  argument, so `functools.partial(int, base=16)` works.
- `Function.name_override` / `doc_override` / `wrapped`
  fields, written by `functools.wraps` and read by `LOAD_ATTR`
  for `__name__` / `__doc__` / `__wrapped__`.

### Changed

- `LOAD_ATTR` on a `function` returns `name_override` for
  `__name__` when set (`functools.wraps` writes it).
- `__build_class__` records the attribute name on
  `cached_property` during class body finalization, so the
  cache key for `@cached_property` is the attribute slot.

## [0.0.59] - 2026-04-25

### Added

- `58_descriptors_stress` fixture, byte-equal against CPython
  3.14. Covers `@property` / `@x.setter` / `@x.deleter`
  decorator chains, descriptor + property combined on the same
  class, `__init_subclass__` cooperative chains driven by class
  kwargs (`class Mid(Root, tag="mid"):`), `__class_getitem__`
  with tuple keys, slot-style data descriptors that beat the
  instance dict, `__delete__` restoring a default, non-data
  descriptors yielding to the instance dict, `__set_name__`
  receiving the defining class, and class-level descriptor
  access invoking `__get__(None, cls)`.
- `Value.bound_method` variant carrying `(func, self)`. The
  property descriptor's `setter` / `deleter` / `getter`
  attribute returns a bound method when accessed in non
  `LOAD_METHOD` form (the decorator case `@x.setter`), so the
  later `CALL` still threads the property in as `self`.
- `__build_class__` accepts class kwargs and forwards them to
  the parent's `__init_subclass__`.

### Changed

- `str.join` consumes any iterable -- generator, set, iter,
  user `__iter__` -- not just list / tuple. Brings
  `', '.join(t.__name__ for t in items)` and similar idioms
  in line with CPython.
- `sorted(...)` materializes its argument through the general
  iterable path, so dicts, sets, generators, and user
  iterables all sort.
- Class-level `LOAD_ATTR` invokes `__get__(None, owner)` on a
  user-defined non-data descriptor, instead of returning the
  raw descriptor instance.

## [0.0.58] - 2026-04-25

### Added

- `57_descriptors` fixture, byte-equal against CPython 3.14.
  Covers data and non-data descriptors with `__get__` /
  `__set__` / `__delete__`, `__set_name__` driven from class
  body finalization, the data-vs-non-data precedence rules
  against the instance dict, `Cls[item]` routed through
  `__class_getitem__`, and `__init_subclass__` notified on
  every subclass.
- `DELETE_ATTR` opcode. For instances, calls `__delete__`
  on a class-level descriptor when present, otherwise removes
  the entry from the instance dict.
- `dict.pop(key)` and `dict.pop(key, default)`.

### Changed

- `LOAD_ATTR` / `STORE_ATTR` honor the descriptor protocol
  for user-defined classes: a class-level attribute that
  defines `__set__` (data descriptor) wins over the instance
  dict on read, and triggers `__set__` instead of writing to
  the instance dict on write. A descriptor with only `__get__`
  (non-data) is consulted only after the instance dict.
- `obj.__dict__` returns the actual instance dict so callers
  can do `obj.__dict__[k] = v`, `obj.__dict__.get(...)`, and
  `obj.__dict__.pop(...)`.
- `__build_class__` walks the new namespace and calls
  `__set_name__(cls, name)` on every attribute that defines
  it, then walks the parent MRO and dispatches the new class
  through the first `__init_subclass__` hook it finds.
- `Cls[item]` now dispatches through `__class_getitem__` when
  the class defines it, matching CPython's PEP 560 generic
  syntax.
- `builtin_fn.__name__` returns the registered name, so
  `int.__name__` and friends produce `"int"` instead of
  raising `AttributeError`.

## [0.0.57] - 2026-04-25

### Added

- `56_dunders_extra_stress` fixture, byte-equal against CPython
  3.14. Stress-tests the v0.0.56 work: reflected bitwise ops
  where `int op user_class` falls through to the user's
  `__rand__` / `__ror__` / `__rxor__` / `__rlshift__` /
  `__rrshift__`, `NotImplemented` fallback between two custom
  classes, in-place ops without `__i*__` rebinding to a new
  object, in-place ops inherited through a child class,
  matmul chained left-to-right, `__int__` vs `__index__`
  precedence (`__int__` wins), `__format__` driving f-strings
  with both empty and structured specs, and custom
  `__hash__` / `__eq__` honored by both `dict` keys and
  `frozenset` membership.

### Changed

- `FORMAT_SIMPLE` (the `f"{x}"` fast path) now calls
  `__format__("")` on instances first, falling back to
  `__str__` / `__repr__` only when the instance has no
  `__format__`. CPython routes empty-spec formatting through
  `__format__`, so user classes that override it (currency
  formatters, structured logs) take effect inside f-strings
  as well as inside `format(x)`.

## [0.0.56] - 2026-04-25

### Added

- `55_dunders_extra` fixture, byte-equal against CPython 3.14.
  Covers bitwise / shift / matmul dunders (`__and__`, `__or__`,
  `__xor__`, `__lshift__`, `__rshift__`, `__matmul__`), unary
  `__invert__` / `__pos__` / `__abs__`, in-place ops with
  explicit `__iadd__` / `__isub__` / `__imul__` / `__ior__` and
  the fallback to `__add__` when an instance has no `__iadd__`,
  the numeric conversion dunders `__int__` / `__float__` /
  `__index__`, plus `divmod`, `round`, and custom `__format__`
  through both `format(...)` and f-string spec.
- `divmod` builtin. `(a, b)` returns `(a // b, a % b)` for ints
  and routes through `__divmod__` / `__rdivmod__` for instances.
- `UNARY_INVERT`, `UNARY_NOT`, and the `INTRINSIC_UNARY_POSITIVE`
  case of `CALL_INTRINSIC_1`. Each consults the matching dunder
  for instances.

### Changed

- `BINARY_OP` covers args 2-25 (floor division, left/right shift,
  matmul, and the in-place variants 13-25). In-place ops try
  `__i*__` first and fall back to the forward `__*__` if the
  instance has no in-place hook, matching CPython.
- `&`, `|`, `^` between `int` / `bool` operands now produce the
  expected integer result. They previously only accepted sets.
- `abs`, `int`, `float`, `round`, and `format` consult their
  respective dunders for instance arguments. `int(x)` falls back
  to `__index__` when `__int__` is absent. `format(obj, spec)`
  and `FORMAT_WITH_SPEC` route through `__format__`.

## [0.0.55] - 2026-04-25

### Added

- `54_dunders_stress` fixture, byte-equal against CPython 3.14.
  Covers dunders inherited through a child class, `NotImplemented`
  fallback between two instance types, the iterator protocol with
  `__iter__` returning `self` and `__next__` raising
  `StopIteration`, `__bool__` vs `__len__` precedence, hash and
  equality respected by both `set` and `dict`, `__str__` falling
  back to `__repr__` (including inside f-strings), reflected ops
  with same-type operands (where `__add__` wins and `__radd__`
  is not called), iteration via `__getitem__` ending on
  `IndexError`, and `__call__` with `*args`.

### Changed

- `iterStep` consults `__next__` for instance iterators and
  treats a raised `StopIteration` as the natural end-of-iteration
  signal, so `for x in obj:` works when `obj.__iter__()` returns
  `self`.
- `STORE_ATTR` now writes to a class object's namespace, so
  `Cls.attr = ...` updates the class dict the same way an
  instance assignment updates the instance dict.

## [0.0.54] - 2026-04-25

### Added

- `53_dunders` fixture, byte-equal against CPython 3.14. Covers
  user-defined `__repr__`, `__str__`, `__eq__`, `__lt__`, `__hash__`,
  `__add__` / `__radd__`, `__sub__` / `__rsub__`, `__mul__`, `__neg__`,
  `__bool__`, `__len__`, `__getitem__`, `__setitem__`, `__delitem__`,
  `__contains__`, `__iter__`, `__call__`, plus the indexed
  `__getitem__` iteration protocol that ends on `IndexError`.
- `src/vm/dunder.zig`: tiny dispatch layer around an instance's class
  MRO. `lookup` walks the chain, `call` prepends `self` and invokes,
  `binop` handles the left-then-reflected fallback, `compare` handles
  the six comparison kinds, and `valuesEqual` makes dict/set keys
  honor `__eq__` for instance keys.

### Changed

- `BINARY_OP`, `COMPARE_OP`, and `UNARY_NEGATIVE` consult instance
  dunders before the built-in numeric paths. Reflected ops
  (`__radd__`, `__rsub__`, ...) fire when the left operand returns
  `NotImplemented` or doesn't define the forward op.
- Subscript / store / delete subscript route through `__getitem__`
  / `__setitem__` / `__delitem__` for instances. `in` consults
  `__contains__` first, then falls back to iterating the instance.
- `iter()` / `for x in obj:` honor `__iter__`, falling back to
  walking `__getitem__(0)`, `__getitem__(1)`, ... until `IndexError`.
- `print`, `repr`, `str`, and `FORMAT_SIMPLE` now call `__str__` /
  `__repr__` for instances, with `__str__` falling back to
  `__repr__`. `len`, `bool`, and `hash` consult their respective
  dunders before the built-in defaults.
- Calling an instance (`obj(...)`) routes through `__call__`.
- Dict literals, dict subscript, set literals, and `in` over dicts
  and sets compare keys with `__eq__` when either side is an
  instance. Identity-only equality stays the path for everything else.

## [0.0.53] - 2026-04-25

### Added

- `52_builtins_stress` fixture, byte-equal against CPython 3.14.
  Covers a wide range of `format` specs (binary/octal/hex with `#`
  alternate forms, `,` and `_` thousands separators, sign and fill
  alignment, float precision and exponent forms, string padding),
  `pow` corners (`pow(2, 100)` overflowing into a big int,
  `pow(2, 1000, 10**9 + 7)`, `pow(7, -1, 11)` modular inverse,
  `pow(2, -2)` returning a float, `pow(2, 3, 1)` returning 0),
  `ascii` on nested containers and a string with control
  characters, `slice` with `None` stops and negative starts,
  `Ellipsis` / `NotImplemented` identity, `dir` walking the MRO,
  and a `try / except AttributeError` around `delattr`.
- `Value.big_int` variant backed by `std.math.big.int.Managed`,
  used as the overflow promotion target for integer `**`. The
  `i64` fast path is preserved via `@mulWithOverflow`; only when
  the product would not fit do we promote, so small-int arithmetic
  stays branchless.
- `BINARY_OP` arg `8` (`NB_POWER`) in the dispatch loop, routed
  through the `pow` builtin so the `**` operator and `pow(...)`
  share one code path (including the fast paths and the BigInt
  promotion).

### Changed

- `delattr` on a missing attribute now raises `AttributeError`
  via `raisePy`, so `try / except AttributeError` catches it
  instead of the interpreter aborting the run.
- `ascii(obj)` walks lists, tuples, dicts, and sets recursively
  and escapes nested string bodies (control chars as `\n` / `\t`
  / `\r` / `\\` / `\'`, non-ASCII codepoints as `\xHH` / `\uHHHH`
  / `\UHHHHHHHH`).

## [0.0.52] - 2026-04-25

### Added

- `51_builtins_extras` fixture, byte-equal against CPython 3.14.
  Covers `pow` (2-arg, 3-arg, modular inverse for negative
  exponents, ValueError on mod 0), `format` with a spec
  string, `ascii` escaping non-ASCII codepoints, the `slice`
  constructor with field access (`.start` / `.stop` / `.step`),
  the `Ellipsis` and `NotImplemented` singletons (with the
  matching `type(...).__name__`), and `delattr` / `dir` /
  `hasattr` against a simple class.
- New builtins: `pow`, `format`, `ascii`, `slice`, `hasattr`,
  `getattr`, `setattr`, `delattr`, `dir`. `getattr` falls back
  to a default when given three arguments and the attribute is
  missing, mirroring CPython.
- `Value.ellipsis` and `Value.not_implemented` singletons. The
  marshal reader now decodes `TYPE_ELLIPSIS` to the real value
  instead of folding it into `None`. Both singletons get a lazy
  type cache so `type(...)` and `type(NotImplemented)` produce
  classes named `ellipsis` / `NotImplementedType`.

### Changed

- `Ellipsis` and `NotImplemented` are bound as builtins, so
  fixtures that reference them by name (`... is Ellipsis`) work.
- Slice attribute access (`s.start`, `s.stop`, `s.step`) now
  returns the field directly instead of raising AttributeError.

## [0.0.51] - 2026-04-25

### Added

- `50_memoryview_stress` fixture, byte-equal against CPython 3.14.
  Exercises nested slicing (slice-of-slice writes still land in
  the original `bytearray`), negative indices, slice assignment
  with a mismatched length raising `ValueError`, `enumerate` over
  a `memoryview`, `!=` across the bytes-like family, the
  read-only flag propagating through slicing, `nbytes` /
  `tolist`, the empty view, ordering between memoryviews raising
  `TypeError`, and `sum(mv)`.

### Changed

- `Value.order` no longer treats `memoryview` as a member of the
  bytes-like ordering family. CPython raises `TypeError` on
  `mv < mv`, so we let `order` fall through to `null`. Equality
  is unchanged — that path still treats all three types as one
  family for content compare.
- The `<` / `<=` / `>` / `>=` TypeError now goes through
  `raisePy("TypeError", ...)` and unwinds as a Python exception,
  so user code can catch it with `try / except TypeError`.
  Previously the message was printed to stderr and the script
  exited.

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
