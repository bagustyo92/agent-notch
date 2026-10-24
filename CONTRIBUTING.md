<!-- Classification: PUBLIC -->
# Contributing to AgentNotch

Thanks for helping. This file says how to build, test and propose changes.

## Set up

- macOS 15+, Swift 6 (Xcode 16+ or the Command Line Tools alone).
- `git config core.hooksPath scripts/githooks` once per clone. The hook stops you from committing
  a real transcript or a file that contains your home path.

```sh
scripts/test.sh        # unit tests (Swift Testing)
swift build            # debug build
scripts/install.sh     # release build, install to ~/Applications, launch
scripts/dmg.sh         # build/AgentNotch-<version>.dmg
```

`scripts/test.sh` exists because the Command Line Tools need an extra plugin path for Swift Testing.
Under Xcode it simply runs `swift test`. SwiftUI's `@State` and `@Bindable` are macros that the
Command Line Tools cannot expand, so the app uses `@Observable` classes and explicit `Binding`s.

## Rules every change must keep

The full list is the "Hard rules" table in [docs/DESIGN.md](docs/DESIGN.md). In short:

1. **Read-only.** Never approve, send, stop, resume, attach or kill a session. Never write under `~/.claude`.
2. **No hooks, no slowdown.** Sessions must behave the same whether AgentNotch runs, quits or crashes.
3. **Local only.** No network calls, analytics, crash reporters, update checks or third-party SDKs.
4. **Nothing persisted** except the two settings. Transcript content stays in memory as derived strings.
5. **Never open secrets** (`~/.claude/sessions/*.key`, `~/.claude/daemon/control.key`, IDE `authToken`).
6. **Synthetic fixtures only**, with `/Users/dev/...` paths.
7. **Cheap.** Under 1% CPU when idle; tail transcripts from an offset; never poll `claude agents`.
8. **Degrade, never crash.** Unknown data shows "activity unavailable" instead.

A pull request that needs to bend one of these should change `docs/DESIGN.md` too and explain why.

## How the code is laid out

- `Sources/AgentNotchCore`: all logic, no AppKit, fully unit-tested. Session list, registry
  fallback, process probing, transcript tailing, activity summaries, the in-memory store.
- `Sources/AgentNotch`: the AppKit/SwiftUI shell. Notch panel, menu bar item, focus, login item.
- `Tests/AgentNotchCoreTests` + `Tests/Fixtures`: Swift Testing tests and synthetic data.

New behaviour goes into Core behind a small public function first, with a test, then the UI calls it.

## Claude Code format changes

The session registry and transcript formats are internal to Claude Code and change between
versions. When something breaks after an update, add a synthetic fixture that reproduces the new
shape, make the parser tolerate it, and update the "Verified facts" table in `docs/DESIGN.md`.

## Pull requests

- One topic per PR. Describe what changed and how you checked it (tests, `--dump`, a screenshot).
- `scripts/test.sh` must pass; CI runs it on every PR.
- Keep screenshots free of real session titles, file names or anything private. `.build/debug/AgentNotch --demo`
  replays synthetic sessions in front of a clean backdrop (`--demo dropdown` for the menu bar card); it
  prints the screen rect to capture, e.g. `screencapture -x -R<rect> shot.png`. Park the mouse away from the notch first.

## Good first issues

- Verify VS Code routes `windowId=` deep links, then enable it in `IDEDeepLink` (see D28).
- Child rows for subagents (v2 in the design).
- Notarized releases and a Homebrew cask.
- iTerm2, Ghostty and WezTerm tab focus.
