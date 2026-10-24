#!/bin/sh
# Build from source and install into ~/Applications, then launch.
set -eu
cd "$(dirname "$0")/.."
scripts/bundle.sh
pkill -x AgentNotch 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/AgentNotch.app"
cp -R build/AgentNotch.app "$HOME/Applications/"
open "$HOME/Applications/AgentNotch.app"
echo "installed: $HOME/Applications/AgentNotch.app"
