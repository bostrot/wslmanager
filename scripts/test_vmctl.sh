#!/bin/bash
# Run the vmctl Swift test suite.
#
# With full Xcode installed a plain `swift test` works. On a host with only
# the Command Line Tools, Swift Testing's framework is not on the default
# search path, so it is passed explicitly.
set -euo pipefail

cd "$(dirname "$0")/../macos/vmctl"

if xcode-select -p 2>/dev/null | grep -qv CommandLineTools; then
  exec swift test "$@"
fi

CLT=/Library/Developer/CommandLineTools
FW="$CLT/Library/Developer/Frameworks"
LIB="$CLT/Library/Developer/usr/lib"
exec swift test \
  -Xswiftc -F"$FW" \
  -Xlinker -F"$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$@"
