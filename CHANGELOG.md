# Changelog

## Unreleased

- The menu bar item mirrors the notch's collapsed status, showing only what is live: working dots and count, the needs-you count in orange, or a green check right after a turn finishes. Two stack beside the bot, one sits centred, and idle shows the bot alone.
- Fixed the menu bar item showing only the bot: it stayed one icon wide and clipped the counts away. It now sizes to its content.
- `--demo menubar <dir>` steps the real menu bar item through its states and writes a PNG of each.

## 0.4.1

- The live strip shows the AI title instead of the repo name, cut at a word boundary to 24 characters. Until the title exists, and under Hide details, it shows the repo.
- `--dump` and `--watch` hide titles and activity by default; `--full` prints them. The bug report template says so.
- `claude` is also found in `~/.claude/local`, `~/.npm-global/bin`, `~/.bun/bin` and nvm installs.
- Launch at login now says so when macOS still needs your approval instead of showing the toggle on.
- Fixed a compile error on Swift 6.1 (the CI toolchain): `size.height / 2 - 5` in the subagent connector was ambiguous. CI and Release had failed on every run because of it.
- Fixed a clean checkout failing `MonitorRefresh`: a test fixture was caught by `.gitignore` and never committed.
- Release workflow stops when the tag does not match `VERSION`.
- README: the privacy section says what is and is not filtered. The cask now removes the login-item plist on zap.

## 0.4.0

Universal build, real bundle id (`com.bagustyo92.agentnotch`), Homebrew cask script, notarization pipeline.
