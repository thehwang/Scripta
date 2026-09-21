#!/bin/bash
# Prints "1" when the active Xcode SDK supports Apple Translation (macOS 15+).
set -euo pipefail

dev="${DEVELOPER_DIR:-$(xcode-select -p)}"
sdk_dir="$dev/Platforms/MacOSX.platform/Developer/SDKs"
sdk="$(ls "$sdk_dir" 2>/dev/null | grep '^MacOSX' | sort -V | tail -1 || true)"
major="$(echo "${sdk:-MacOSX0.sdk}" | sed 's/MacOSX//;s/.sdk//' | cut -d. -f1)"
if [ "${major:-0}" -ge 15 ]; then
    echo 1
fi
