#!/bin/sh

set -eu

hw-odin build . -out:build/hw_agent
for package in ai agent session compact rpc serve; do
    hw-odin test "$package/"
done
