#!/bin/sh
# Print the Homebrew cask for a release DMG: scripts/cask.sh build/AgentNotch-<version>.dmg
# Commit the output as Casks/agent-notch.rb in the bagustyo92/homebrew-tap repository.
set -eu
DMG="${1:?usage: scripts/cask.sh <dmg>}"
VERSION="$(basename "$DMG" .dmg)"; VERSION="${VERSION#AgentNotch-}"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
cat <<CASK
cask "agent-notch" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/bagustyo92/agent-notch/releases/download/v#{version}/AgentNotch-#{version}.dmg"
  name "AgentNotch"
  desc "Shows every running Claude Code session in the notch and menu bar"
  homepage "https://github.com/bagustyo92/agent-notch"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"

  app "AgentNotch.app"

  # Releases are not notarized yet; drop this block once they are.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/AgentNotch.app"]
  end

  zap trash: [
    "~/Library/Preferences/com.bagustyo92.agentnotch.plist",
    "~/Library/Preferences/local.agentnotch.plist",
  ]
end
CASK
