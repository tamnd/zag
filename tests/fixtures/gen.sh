#!/usr/bin/env bash
# Regenerate .pyc and .expected.txt for every .py fixture in this directory.
# Requires python3.14 on PATH. build.zig runs this before the integration
# test compile step so @embedFile has something to pick up.
set -euo pipefail
cd "$(dirname "$0")"
PY=${PYTHON:-python3.14}
for src in *.py; do
  base=${src%.py}
  $PY -c "import py_compile; py_compile.compile('$src', cfile='${base}.cpython-314.pyc', doraise=True)"
  $PY "$src" > "${base}.expected.txt"
done
