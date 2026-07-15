#!/bin/bash
# Wrapper around `swift test` that adds the swift-testing framework search paths
# when running under Command Line Tools (no full Xcode). Passes through args.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/app"

FLAGS=()
DEV="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV" == *CommandLineTools* ]]; then
  FW="$DEV/Library/Developer/Frameworks"
  LIB="$DEV/Library/Developer/usr/lib"
  FLAGS=(-Xswiftc -F"$FW" -Xlinker -F"$FW"
         -Xlinker -rpath -Xlinker "$FW"
         -Xlinker -rpath -Xlinker "$LIB")
fi

# ${FLAGS[@]+...} guards against empty-array expansion under `set -u` on bash 3.2.
exec swift test "$@" ${FLAGS[@]+"${FLAGS[@]}"}
