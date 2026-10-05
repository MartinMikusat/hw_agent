#!/bin/sh

set -eu

"$(dirname -- "$0")/build.sh"
for package in ai agent session compact rpc serve; do
    hw-odin test "$package/"
done
