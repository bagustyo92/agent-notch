#!/bin/sh
# Command Line Tools keep the Swift Testing macro plugin in <CLT>/usr/lib/swift/host/plugins/testing,
# which swift-frontend does not search by default (V1). With Xcode it is found automatically.
set -eu
cd "$(dirname "$0")/.."
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
