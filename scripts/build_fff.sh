#!/bin/sh
# Builds fff_bridge (fff-mcp's search tools as a static library) against a
# pinned fff checkout in build/fff/src. Rebuilds only when sources change.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# fff v0.11.0 — keep equal to the fff-mcp release whose behaviour we mirror.
FFF_REVISION=95fd777c2529fc7b4d7572dabff64cc07268f2c5
SRC="$ROOT/build/fff/src"

if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$FFF_REVISION" ]; then
  rm -rf "$SRC"
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin https://github.com/dmtrKovalenko/fff.git
  git -C "$SRC" fetch -q --depth 1 origin "$FFF_REVISION"
  git -C "$SRC" checkout -q FETCH_HEAD
fi
cargo build --quiet --release --locked --manifest-path "$ROOT/fff_bridge/Cargo.toml" --target-dir "$ROOT/build/fff/target"
