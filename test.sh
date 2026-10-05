#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ODIN_LIBS=$(CDPATH= cd -- "${ODIN_LIBS:-$ROOT/../odin_libraries}" && pwd)
python3 "$ODIN_LIBS/hw_odin_devlog/scripts/lint_devlog.py" "$ROOT"
"$ROOT/build.sh"
for package in textutil ai agent session compact rpc serve fff instructions permissions tools; do
    hw-odin test "$ROOT/$package/" -vet -strict-style -collection:devlog="$ODIN_LIBS/hw_odin_devlog" -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
done
