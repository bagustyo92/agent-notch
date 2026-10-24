#!/bin/sh
# Notarize a signed DMG with Apple and staple the ticket: scripts/notarize.sh build/AgentNotch-<version>.dmg
# Needs APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD (an app-specific password) in the environment.
set -eu
DMG="${1:?usage: scripts/notarize.sh <dmg>}"
: "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_PASSWORD:?}"
xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
