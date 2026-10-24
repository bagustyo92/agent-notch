#!/bin/sh
# Build the app for this version and package it as build/AgentNotch-<version>.dmg (drag-to-Applications).
set -eu
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(cat VERSION)}"
export VERSION
scripts/bundle.sh                     # always rebuild: the DMG name must match the binary inside
STAGE=build/dmg
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R build/AgentNotch.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="build/AgentNotch-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "AgentNotch $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
shasum -a 256 "$DMG"
