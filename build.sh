#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ODIN_LIBS=$(CDPATH= cd -- "${ODIN_LIBS:-$ROOT/../odin_libraries}" && pwd)
BUILD="$ROOT/build"
MODE=${1:-debug}
mkdir -p "$BUILD"
python3 "$ROOT/scripts/check_dependencies.py" "$MODE"

case "$MODE" in
  debug)
    ODIN_FLAGS="-debug -o:none"
    OUT="$BUILD/hw_agent"
    PLIST=""
    ;;
  release)
    ODIN_FLAGS="-o:speed"
    OUT="$BUILD/hw_agent-release"
    VERSION=${HW_UPDATE_VERSION:-0.0.0}
    # The release tool compiles the version and feed in; without them it never updates.
    if [ -n "${HW_UPDATE_VERSION:-}" ]; then
      ODIN_FLAGS="$ODIN_FLAGS -define:HW_UPDATE_VERSION=$HW_UPDATE_VERSION -define:HW_UPDATE_FEED_URL=$HW_UPDATE_FEED_URL -define:HW_UPDATE_TEAM_ID=$HW_UPDATE_TEAM_ID"
    fi
    # A bare executable carries its Info.plist in __TEXT,__info_plist; the
    # updater's code requirement pins the version from it.
    cat > "$BUILD/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>com.halwayland.hw-agent</string>
	<key>CFBundleName</key><string>hw_agent</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
</dict>
</plist>
PLIST
    PLIST="$BUILD/Info.plist"
    ;;
  *)
    echo "usage: ./build.sh [debug|release]" >&2
    exit 2
    ;;
esac

set -- -collection:native_update="$ODIN_LIBS/hw_odin_native_update" -out:"$OUT"
if [ -n "$PLIST" ]; then
  set -- "$@" -extra-linker-flags:"-sectcreate __TEXT __info_plist $PLIST"
fi
# shellcheck disable=SC2086
hw-odin build "$ROOT" "$@" $ODIN_FLAGS
