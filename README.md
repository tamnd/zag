<h1 align="center">zag</h1>

<p align="center">A Zig interpreter for CPython 3.14 bytecode.<br>One static binary. No libpython. No cgo.</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/python-3.14-3776AB?logo=python&logoColor=white" alt="Python 3.14">
  <img src="https://img.shields.io/badge/zig-0.16-F7A41D?logo=zig&logoColor=white" alt="Zig 0.16">
</p>

```sh
python3.14 -m py_compile hello.py
zig build run -- __pycache__/hello.cpython-314.pyc
```

zag reads a `.pyc` file and runs it. CPython compiles; zag executes. Execution happens inside a Zig `switch` with labeled-continue dispatch (the equivalent of GCC's computed goto), with Python values held in a tagged union and memory owned explicitly by the interpreter.

## Why

Embedding Python inside a Zig program usually means linking `libpython` and bridging two runtimes. That works; it also drags in the whole CPython build. zag is the alternative: accept compiled `.pyc` on input, execute it inside a single Zig binary, exit cleanly.

Good fits: a Zig service that wants user-pluggable logic, a CLI that accepts small Python scripts as config, a sandbox that runs auditable `.pyc` payloads.

Trade you lose: peak speed and the C extension ecosystem. Trade you keep: one binary, one toolchain, one kind of crash dump.

zag is the Zig sibling of [goipy](https://github.com/tamnd/goipy), which does the same thing in Go. The two projects share test fixtures and disagree only on host language.

## Status

Early. Milestone 1 targets "hello world runs", which means:

- Load a `.pyc` produced by `python3.14 -m py_compile`.
- Decode the 3.14 marshal stream.
- Dispatch the seven opcodes `RESUME`, `LOAD_NAME`, `PUSH_NULL`, `LOAD_CONST`, `CALL`, `POP_TOP`, `RETURN_VALUE`.
- Implement one builtin: `print`.

Later milestones: arithmetic, control flow, functions, collections, classes, exceptions, generators, stdlib.

## Requirements

- Zig 0.16 (tested against `0.16.0-dev.2984+cb7d2b056`).
- CPython 3.14 on `PATH` to produce `.pyc` inputs.

## Layout (planned)

```
src/
  main.zig           CLI entry point
  root.zig           library root
  marshal/           .pyc header + marshal decoder
  op/                3.14 opcode enum + cache widths
  object/            Value tagged union and per-type structs
  vm/                interp, frame, dispatch, call, builtins
tests/
  fixtures/          .py + .pyc + expected stdout
```

## License

MIT. `.pyc` input files remain under the PSF license that covers CPython bytecode output.
