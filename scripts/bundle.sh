#!/bin/sh
# Release build + ad-hoc signature → build/AgentNotch.app
set -eu
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(cat VERSION)}"
case "$VERSION" in
  ''|*[!0-9.]*) echo "VERSION must be digits and dots, got '$VERSION'" >&2; exit 1 ;;
esac
swift build -c release
mkdir -p build
if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  swift scripts/make-icon.swift build
fi
APP=build/AgentNotch.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AgentNotch "$APP/Contents/MacOS/AgentNotch"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.agentnotch</string>
  <key>CFBundleName</key><string>AgentNotch</string>
  <key>CFBundleDisplayName</key><string>AgentNotch</string>
  <key>CFBundleExecutable</key><string>AgentNotch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Focus the Terminal tab running a Claude Code session.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "built $APP ($VERSION)"
