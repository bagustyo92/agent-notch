#!/bin/sh
# Release build + signature → build/AgentNotch.app
# UNIVERSAL=0 builds for this Mac only (faster). SIGN_IDENTITY="Developer ID Application: ..." signs for
# distribution with the hardened runtime; the default "-" is an ad-hoc signature.
set -eu
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(cat VERSION)}"
case "$VERSION" in
  ''|*[!0-9.]*) echo "VERSION must be digits and dots, got '$VERSION'" >&2; exit 1 ;;
esac
UNIVERSAL="${UNIVERSAL:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$UNIVERSAL" = 1 ]; then ARCHFLAGS="--arch arm64 --arch x86_64"; else ARCHFLAGS=""; fi
swift build -c release $ARCHFLAGS
BIN="$(swift build -c release $ARCHFLAGS --show-bin-path)/AgentNotch"
mkdir -p build
if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  swift scripts/make-icon.swift build
fi
APP=build/AgentNotch.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentNotch"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.bagustyo92.agentnotch</string>
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
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --entitlements scripts/AgentNotch.entitlements --sign "$SIGN_IDENTITY" "$APP"
fi
echo "built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/AgentNotch"))"
