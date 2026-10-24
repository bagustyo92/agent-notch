<!-- Classification: PUBLIC -->

# AgentNotch — design and implementation plan

- Status: v0.2. M1–M6 implemented and released as open source (see "M0 results"); the M7 soak is still open.
- Origin: a personal tool, built for one user on one Mac, now open source.
- Baseline: Claude Code 2.1.310, macOS 27, a notched MacBook Pro.
- Source of decisions: a design Q&A on 2026-10-24 (Q-n → D-n). Change a decision with a PR that edits this file and says why.

## Goal

AgentNotch is a macOS app that shows **every live Claude Code session on this Mac**, in the **notch** and in a **menu bar item**. A session can come from the Terminal CLI, the VS Code extension, the Cursor extension, or `claude --bg`. For each session it shows:

- the status
- one safe activity line
- the elapsed time

Clicking a session focuses its window. The app is strictly read-only.

## Hard rules (never break)

| # | Rule |
|---|---|
| R1 | **Read-only.** Never approve or deny, send messages, stop, resume, attach, or kill. Never write anything under `~/.claude`. |
| R2 | **Never block or slow a session.** No hooks. Do not touch `~/.claude/settings.json`; users often have their own hooks there. Sessions must behave identically whether the app is running, quit or crashed. |
| R3 | **Local-only.** Zero network calls. No analytics, crash reporting, update checks or third-party SDKs. Use the Swift stdlib and Apple frameworks only. |
| R4 | **No persistence of transcript content.** Derived fields live in memory only. No log files. UserDefaults holds settings only (`hideDetails`, `launchAtLogin`, `autoOpen`, `showSubagentsLive`). |
| R5 | **Never open secret files.** These are `~/.claude/sessions/*.key` and `~/.claude/daemon/control.key`. From `~/.claude/ide/*.lock`, decode only `ideName`, `pid` and `workspaceFolders`. That file also holds an `authToken`: never log, display or keep it. |
| R6 | **No real transcripts in the repo.** Fixtures are synthetic and use `/Users/dev/...` paths. The pre-commit hook (M1) enforces this. |
| R7 | **Cost limits.** CPU below 1% when idle. A status change is visible within 1 s. Transcripts are tailed from a byte offset; never re-read a whole transcript. Never poll `claude agents --json`; F1 explains why. |
| R8 | **Degrade, never crash or hide.** Unknown or unparseable data degrades the row instead (D24). |
| R9 | **No "Claude" in the app name or bundle id**, because it is a trademark. |

## Decisions (D-n = grilling question Q-n)

| # | Decision |
|---|---|
| D1 | **Surfaces:** notch plus menu bar. **Sources:** every top-level session (Terminal, VS Code ext, Cursor ext, `--bg`). The built-in `claude agents` TUI is not enough: it shows interactive IDE sessions only after `/bg`. |
| D2 | **Scope:** top-level sessions only in v1. **Out:** subagents (`<sessionId>/subagents/`, transcript lines with `isSidechain:true`) become child rows in v2 (done in 0.3.0, D33). Cloud and remote sessions are out of scope. |
| D3 | **Row content:** status, one activity line and elapsed time. Clicking a row focuses that session's window. There is no transcript viewer. |
| D4 | Read-only (R1). No macOS notification banners. |
| D5 | Single user, not distributed. |
| D6 | Local-only with no persistence (R3, R4). |
| D7 | Fork, modify or build: whichever meets the requirements. Resolved in D19. |
| D8 | If an organisation's device management blocks ad-hoc-signed apps, installing needs IT approval. Only relevant if V4 fails. |
| D9 | Never block a session (R2). |
| D10 | **Row layout.** Line 1: **title** (latest `ai-title`, falling back to the registry `name`). Line 2: `repo · branch · <source icon> · elapsed`. Line 3: activity. Plus a status chip. |
| D11 | **Activity line:** a safe summary only (see "Activity line" below). A "Hide details" toggle sits in the menu bar dropdown. |
| D12 | **Which sessions appear:** live sessions only. An ended session shows **Done** for 10 min (in memory) and is then dropped. Stale background sessions are hidden (see "Status mapping"). |
| D13 | **Attention signal:** the notch expands or pulses with the session's row when the session turns *waiting* or finishes a turn. No sound, no banner. Superseded in 0.3.0 by D35. |
| D14 | **Click target and screen.** Click focuses at the window level. With no notch (external display), draw a pill at the top centre of the **menu-bar screen**. |
| D15 | Xcode is not installed and not needed. The project builds with Command Line Tools only. |
| D16 | Launch at login. No Dock icon (`LSUIElement`). |
| D17 | Freshness within 1 s, idle CPU below 1%, tail-only reads (R7). |
| D18 | **Repo:** a standalone Swift package. Synthetic fixtures only (R6). |
| D19 | **Build from scratch** as a Swift package with no hooks. Forks rejected after a source audit of vibe-notch@10f1d24 and coucou@47d1c2d. Reasons: <br>• Both block sessions through PermissionRequest hooks (waits of up to 300 s and 118 s). <br>• vibe-notch ships Mixpanel (keyed by hardware UUID) plus Sparkle. <br>• coucou shows one pill per host app and carries about 40 integrations plus an iPhone relay. <br>• Neither focuses a specific window. <br>• Neither sees sessions that were already running when the app launched. <br>• Both need Xcode. |
| D20 | **Menu bar item:** icon plus two stacked small numbers, **working** on top and **waiting** below. The icon tints orange when waiting > 0. |
| D21 | **Division of work:** the notch is the live view. The menu bar dropdown shows the **same rows** plus the controls: Hide details, Pop open automatically, Show subagents in live view, Launch at login, version line, Quit. Both render from one in-memory `SessionStore`. |
| D22 | **Names:** app `AgentNotch`, directory `agent-notch`, bundle id `com.bagustyo92.agentnotch`. |
| D23 | **Session list source:** `claude agents --json`, run only when `~/.claude/sessions/` changes, debounced to 300 ms. Fall back to reading `~/.claude/sessions/*.json` directly if the command fails. **Activity source:** the transcript tail. |
| D24 | **Format drift:** the row shows its status plus "activity unavailable". The dropdown shows `Tested with Claude Code 2.1.310 · running <x>` when any session's version differs. |
| D25 | **Terminal.app focus:** select the exact window and tab through AppleScript. This needs a one-time macOS Automation permission. If the owner denies it, just activate Terminal. |
| D26 | This document lives in the repo and is the spec. |
| D27 | **IDE (Cursor / VS Code) click, fallback:** activate the app by bundle id (F8). No Accessibility permission. Never run `open -a <IDE> <cwd>`: with a multi-root workspace (F7), opening one folder may open a new window. Superseded for Cursor by D28 whenever the window id is known. |
| D28 | **Cursor click opens the exact chat** (2026-10-24): send `cursor://anthropic.claude-code/open?session=<id>&windowId=<n>`, where `<n>` comes from the session's parent process title (F18). The extension reveals the tab or sidebar that holds the session. Before sending, the pid must be alive, still classify as Cursor's `claude`, have started within 120 s of the session's `startedAt`, and have a live parent inside `Cursor.app`; otherwise fall back to D27. The link is never sent without `windowId`: in a window that does not hold the session, the extension would open a new tab and resume it, a second process on a live session (R1). VS Code stays on D27 until its `windowId` routing is verified. |

### 0.3.0 decisions (2026-10-24, second grilling round)

The "notch looks stuck" report traced to what the row showed, not to a missed update: an instrumented
build re-rendered the notch on every store publish, in step with the menu bar item. The parser skipped
`thinking` blocks and `tool_result` lines, so during 10–35 s thinking stretches the row kept the last
tool while Claude Code's own spinner moved.

| # | Decision |
|---|---|
| D29 | **Phase.** Every session and subagent tracks the phase of its newest transcript line: `thinking` (a thinking block, or a prompt / tool result not yet answered), `tool` (tool_use), `writing` (text). While thinking, the row shows a rotating verb from AgentNotch's own list ("Percolating…"), picked per session every 4 s; Claude Code's spinner text is not on disk. |
| D30 | **Model and effort** come from `message.model` and the line's `effort` field, shown as a capsule `Opus 5.5 · high` on every row and subagent row (not in the collapsed notch). Only short machine tokens are accepted; `<synthetic>` and anything else is dropped. |
| D31 | **Needs you** uses the registry's `waitingFor` (values in the 2.1.310 binary: `dialog open`, `input needed`, `sandbox request`, `goal proposal`) for the label ("Needs a decision", "Needs your input", …) and its `needs` text, masked, as detail. Hide details drops the `needs` text. |
| D32 | **Five display states**, one color and one motion each: working (blue, three rising dots, shimmering verb), needs you (orange, breathing glow), finished turn (green check, "Finished · 2m ago" for 10 min), idle (dim dot), ended (grey). Motion honors Reduce Motion. |
| D33 | **Subagents** are child rows, read from `<sessionId>/subagents/agent-<id>.{jsonl,meta.json}` (meta: `agentType`, `description`, `toolUseId`, `spawnDepth`, `finished`). Grandchildren nest under the subagent whose transcript holds their `toolUseId`; two levels are drawn. Two children show per session, then "+N more" expands the whole tree. Finished children fold away when the parent's turn ends; unfinished ones whose transcript is quiet for 30 min (3 min once the parent is idle) are dropped. They do not count in the notch number. |
| D34 | **Look.** Dynamic-Island black for the notch with spring morphs between shapes; the dropdown keeps the system material and follows light/dark. Raised row cards, SF Symbols, rounded numerals, no text chips. |
| D35 | **Live strip** (replaces the D13 pulse). When a session starts working or needs you, the collapsed notch opens a compact strip: one line per live session (at most 3, then "+N more") with time in the current state, plus running subagents when "Show subagents in live view" is on. It stays until the pointer hovers it (that acknowledges it) and reopens on the next transition. A finished turn shows for 4 s. Answering a prompt does not reopen it; the first list after launch does not open it. "Pop open automatically" switches the strip off; the collapsed notch still animates. |

| D36 | **Sections** (third grilling round). The full list (notch hover view and dropdown) groups sessions under headers with a count: **Needs you**, **Working** (with subagent trees), **Done** (finished, idle and ended, newest first). Empty sections are hidden. Done shows its 2 newest, then "Show N more". |
| D37 | **Identity.** The hover view opens with the same header as the dropdown: bot glyph and "AgentNotch" on the left, the live summary on the right. The collapsed notch and the live strip stay unbranded. |

Fix (0.3.0): a collapsed side with nothing to show had zero width, which slid the working count under the physical notch. Each side now keeps a fixed-width base. Verified by capturing the running panel's own view.

## Verified facts (2026-10-24)

| # | Fact | How verified |
|---|---|---|
| F1 | `claude agents --json` prints a JSON array of active sessions. <br>• Interactive entry: `{pid, cwd, kind:"interactive", startedAt, sessionId, name, status}`. <br>• Background entry: `{id, cwd, kind:"background", startedAt, sessionId, name, state}`. <br>• Observed `status` values: `busy`, `idle`. Observed `state`: `blocked` (6 stale Aug–Sep sessions). <br>• Documented, unobserved: `status:"waiting"` and a `waitingFor` field. <br>• **Cost: about 0.25 s CPU and 0.5–1.1 s wall per call.** | Ran it 3× with `time`. Docs: code.claude.com/docs/en/agent-view.md |
| F2 | **Session registry:** `~/.claude/sessions/<pid>.json`, one file per running session, each with a sibling `<pid>.<hash>.key` (**secret**). <br>• Keys: `pid, sessionId, cwd, startedAt, procStart, version, kind, entrypoint, name, nameSource, status, statusUpdatedAt, updatedAt, messagingSocketPath, peerProtocol, peerFeatures`. <br>• `updatedAt == statusUpdatedAt` in all 6 files, so a file is rewritten on status transitions only. *Inference from one snapshot.* <br>• Officially an internal format. | `jq` over the live files |
| F3 | `entrypoint` is `"claude-vscode"` for **both** VS Code and Cursor extension sessions. It cannot tell them apart. | Live Cursor sessions |
| F4 | **Source by executable path:** <br>• Cursor: `~/.cursor/extensions/anthropic.claude-code-<ver>-darwin-arm64/resources/native-binary/claude` (verified). <br>• Terminal CLI: `~/.local/bin/claude`, a symlink to `~/.local/share/claude/versions/<ver>`. The install path is verified; a running terminal session was not observed (V2). <br>• VS Code: `~/.vscode/extensions/anthropic.claude-code-*/…`. **ASSUMPTION** (V3). | `ps`, `which -a claude` |
| F5 | **Transcript path:** `~/.claude/projects/<encoded cwd>/<sessionId>.jsonl`. Example: `/Users/dev/work/my-app` encodes to `-Users-dev-work-my-app`. Locate transcripts by globbing `~/.claude/projects/*/<sessionId>.jsonl` rather than re-implementing the encoding. Each session also has a folder `<sessionId>/subagents/`. | `ls` |
| F6 | **Transcript line types seen:** `user`, `assistant`, `attachment`, `system`, `ai-title {aiTitle}`, `last-prompt {lastPrompt}`, `queue-operation`, `file-history-snapshot`, `api-request*`, `atis-latch`. <br>• Message lines carry `gitBranch, cwd, entrypoint, isSidechain, timestamp, version`. <br>• `ai-title` repeats; the latest one wins. <br>• Officially internal and changes between versions. | `jq '.type' \| uniq -c` on a live transcript |
| F7 | **IDE lock:** `~/.claude/ide/<port>.lock`, one per IDE window, has keys `authToken` (**secret**), `ideName` (`"Cursor"`), `pid` (the IDE main process, shared by all windows), `runningInWindows`, `transport` and `workspaceFolders`. A multi-root workspace lists many folders. | `jq keys` only |
| F8 | **Bundle ids:** Cursor `com.todesktop.230313mzl4w4u92`, VS Code `com.microsoft.VSCode`, Terminal `com.apple.Terminal`. | `plutil` |
| F9 | **Hooks do run in IDE sessions:** a transcript shows `stop_hook_summary` under `claude-vscode`. Irrelevant to v1, which has no hooks. | Transcript |
| F11 | **Toolchain:** Command Line Tools only, no Xcode. Swift 6.2.1. CLT ships `Testing.framework` (swift-testing) but **no XCTest**. No Rust. | `xcode-select -p`, `ls` |
| F12 | **Hardware assumed:** a built-in display with a notch. Without one, the panel draws a pill (D14). Terminal app supported: Terminal.app. Editors: Cursor and VS Code. | `system_profiler` |

## M0 — verify first (blocking; write the results back into the facts table)

- **V1.** Check that `swift test` runs a Swift Testing (`import Testing`) test under CLT.
  - If it fails, try `swift test --enable-swift-testing`.
  - If that also fails, replace the test target with an executable target `SelfTest` that runs the same checks and `exit(1)`s on failure.
- **V2.** Run `claude` in Terminal.app. Record its `entrypoint` (from `sessions/<pid>.json`), its executable path (`ps -o comm= -p <pid>`) and its tty (`ps -o tty= -p <pid>`). Update F3 and F4.
- **V3.** Open the Claude panel in VS Code and record the executable path. Update F4.
- **V4.** After M1, ad-hoc sign the app, copy it to `~/Applications` and open it.
  - If Gatekeeper or MDM blocks it, installing needs IT approval (D8).
  - **ASSUMPTION:** a locally built app carries no quarantine xattr, so it will run.
- **V5.** While a session waits on a permission prompt, run `claude agents --json` and record `status` and `waitingFor`. Run `claude agents --json --all` and record every background `state` value. Fill in the status mapping below.
- **V6.** After M1, check that `SMAppService.mainApp.register()` works for an ad-hoc-signed app in `~/Applications`.
  - If it doesn't, fall back to a LaunchAgent: `~/Library/LaunchAgents/com.bagustyo92.agentnotch.plist` with `RunAtLoad` set to true.

## M0 results (2026-10-24)

| V | Result |
|---|---|
| V1 | `swift test` fails under CLT: `plugin for module 'TestingMacros' not found`. The plugin exists at `<CLT>/usr/lib/swift/host/plugins/testing/`, which swift-frontend does not search. Fix: `scripts/test.sh` passes `-Xswiftc -plugin-path -Xswiftc <that dir>`. Also found: in the macOS 27 SDK, SwiftUI `@State`/`@Bindable` are macros (`SwiftUIMacros`) with no CLT plugin at all, so the app uses `@Observable` classes and manual `Binding`s instead. `@Observable` works (its plugin is in the default dir). |
| V2 | No interactive Terminal session was running. The `claude agents` TUI on `ttys000` resolves through `proc_pidpath` to `~/.local/share/claude/versions/2.1.296` (the symlink target), so Source matches both that path and `~/.local/bin/claude`. tty comes from `proc_pidinfo` + `devname`. `entrypoint` of a Terminal session is still **ASSUMPTION** (`cli`, as the registry shows for bg spares). |
| V3 | VS Code extension is installed at `~/.vscode/extensions/anthropic.claude-code-2.1.235-darwin-arm64/resources/native-binary/claude`; no live VS Code session was observed. Path pattern confirmed as the install path only. |
| V4 | Ad-hoc signed `AgentNotch.app` launched from `build/` and from `~/Applications`. No quarantine xattr on a local build (only `com.apple.provenance`); LaunchServices type `UIElement`; nothing blocked. A downloaded DMG does carry quarantine: see the README. |
| V5 | No session was waiting on a permission prompt during implementation, so `status:"waiting"` / `waitingFor` remain unobserved (mapping implemented as documented). `claude agents --json --all` states observed: `blocked`, `done`, `stopped`. Mapping: blocked→waiting, running/busy→working, done/stopped/exited/failed/killed/completed→done, anything else→idle. |
| V6 | `SMAppService.mainApp.register()` works for the ad-hoc app in `~/Applications` (status enabled → unregister → notRegistered). From `build/` the status is `notFound`. The LaunchAgent fallback is implemented but unused. |

Extra facts found while implementing:

| # | Fact |
|---|---|
| F14 | The registry also holds **pre-warmed spares**: `kind:"bg"`, `entrypoint:"cli"`, cwd `~`, process `claude bg-spare`, which `claude agents --json` does not list. They have no transcript, so the 24 h rule hides them in the registry fallback. |
| F15 | `startedAt` is epoch **milliseconds** in both the command output and the registry. The decoder also accepts seconds and ISO-8601. |
| F16 | `claude agents --json` carries no `version`; the app reads `~/.claude/sessions/<pid>.json` once per new session for the version line (D24). |
| F17 | Live transcript lines also carry `thinking` blocks and `api-request*`, `attachment`, `last-prompt` types; all ignored. `tool_use.input` for Bash has `command` and `description`. |
| F18 | **IDE window id:** an extension-session `claude` process is a child of its window's extension host, whose title (`ps -o args=`) is `<App> Helper (Plugin): extension-host (user) <workspace> [<windowId>-<n>]`; Cursor builds it as `[${responseWindowId}-…]`. Cursor's main-process `URLHandlerRouter` routes a URI with `windowId=<n>` to window `<n>`. The extension's URI handler `/open?session=<id>` calls `primaryEditor.open`, which reveals an existing panel or sidebar for that session. Live check: opening the link for a live session revealed its tab and started no new process. | Cursor `main.js`, extension `extension.js`, `ps`, `pgrep` |

## Architecture

```
agent-notch/
  Package.swift                 // swift-tools-version 6.0; platforms [.macOS(.v15)]; targets: AgentNotchCore (lib), AgentNotch (exe), AgentNotchCoreTests
  Sources/AgentNotchCore/       // pure logic, no AppKit, fully unit-tested
    Models.swift                // Session, Source, Status
    AgentsCommand.swift         // runs `claude agents --json` (Process, 5 s timeout), decodes
    RegistryReader.swift        // fallback: decode ~/.claude/sessions/*.json (skip *.key)
    ProcessProbe.swift          // pid alive (kill(pid,0)), exe path (proc_pidpath) → Source, tty
    TranscriptTail.swift        // offset tail + tolerant line parser
    ActivitySummary.swift       // tool_use/text → safe one-liner, secret mask, hide-details
    SessionStore.swift          // @MainActor @Observable: merge, status, linger, attention events, counts
    FileWatcher.swift           // FSEvents wrapper (kFSEventStreamCreateFlagFileEvents)
  Sources/AgentNotch/           // AppKit + SwiftUI
    App.swift                   // NSApplication, accessory policy
    NotchPanel.swift            // NSPanel geometry, hover/expand/pulse
    StatusItem.swift            // two-line counts + NSPopover dropdown
    SessionRowView.swift        // ONE row view shared by notch and dropdown
    Focus.swift                 // Terminal AppleScript; IDE app activation (D27)
    LoginItem.swift             // SMAppService or LaunchAgent fallback (V6)
  Tests/AgentNotchCoreTests/    // Swift Testing
  Tests/Fixtures/               // synthetic *.jsonl / *.json, each < 20 KB, paths under /Users/dev
  scripts/bundle.sh
  scripts/githooks/pre-commit
  NOTICE                        // Apache-2.0 credit if the vibe-notch notch-geometry approach is adapted
```

### Data flow

1. `FileWatcher(~/.claude/sessions)` → debounce 300 ms → `AgentsCommand`. If the command fails, use `RegistryReader` instead. Then `SessionStore.replaceList(...)`.
2. For each new sessionId:
   - Run `ProcessProbe` to get the source and tty.
   - Glob for the transcript.
   - Call `TranscriptTail.attach`.
3. `FileWatcher(~/.claude/projects)` reports changed files. Look the file up by sessionId, call `TranscriptTail.readNew`, then `SessionStore.updateActivity`.
4. A 5 s timer checks pid liveness with `kill(pid,0)`. This catches crashed sessions whose registry file lingers. Elapsed labels re-render only while the notch is expanded or the dropdown is open.

### Models

```swift
enum Source { case terminal, vscode, cursor, background, unknown }
enum Status { case waiting, working, idle, done }          // display + sort order
struct Session: Identifiable {
  let id: String            // sessionId
  var pid: Int32?
  var cwd: String; var repo: String   // repo = last path component of cwd
  var branch: String?; var title: String
  var source: Source; var status: Status
  var activity: String?     // already summarised + masked; never raw transcript text
  var startedAt: Date; var endedAt: Date?
  var claudeVersion: String?; var tty: String?
}
```

### Status mapping

| Input | Status |
|---|---|
| `status == "busy"` | working |
| `status == "waiting"` **or** `waitingFor != nil` | waiting |
| `status == "idle"` | idle |
| The session is missing from the list, or its pid is dead | done, with `endedAt = now`. Removed once 600 s have passed since `endedAt` (D12). |
| `kind == "background"` | Show it only if its transcript mtime is less than 24 h old. Map `state` after V5; until then, `blocked` → waiting. The 6 stale Aug–Sep sessions disappear through the 24 h rule. |

- **Sort order:** waiting, working, idle, done. Within a group, most recent status change first.
- **Attention event (D13):** fires when a session moves to `waiting`, or from `working` to `idle` (turn finished). At most one event per session every 5 s.

### TranscriptTail

**`attach(path)`**

1. Read **backwards** in 256 KB chunks, up to 4 MB, until you have the latest `ai-title`, the latest `gitBranch`, and the last assistant or user message.
2. Set `offset = EOF`.

**`readNew()`**

1. Read from `offset` to EOF.
2. Split on `\n`. Keep any trailing partial line in a buffer.
3. Advance `offset` by the bytes of complete lines only.
4. If the file size is now smaller than `offset`, call `attach` again.

**Parsing each line**

- Use `JSONSerialization` (tolerant).
- Read only these keys: `type`, `aiTitle`, `gitBranch`, `isSidechain`, and `message.content[].{type,name,input,text}`.
- Skip lines with `isSidechain == true`.
- Ignore unknown `type` values.
- If a session has 20 or more decode failures and 0 successes, set its activity to `"activity unavailable"` (D24).
- **Never retain a raw line.** Keep only the derived strings.

### Activity line (D11)

The activity comes from the **last** `tool_use` block, or failing that the last text block, in the latest `assistant` line. A `user` line carrying a `tool_result` leaves the activity unchanged.

| `tool_use.name` | Shown |
|---|---|
| `Bash` | `Bash · <input.description>`, or just `Bash` if there is no description. **Never `input.command`.** |
| `Read`, `Edit`, `Write`, `MultiEdit`, `NotebookEdit` | `<name> · <basename(input.file_path or input.notebook_path)>` |
| `Agent`, `Task` | `<name> · <input.description>` |
| `Grep`, `Glob`, `WebFetch`, `WebSearch` | `<name>` only (patterns, URLs and queries can leak data) |
| `mcp__<server>__<tool>` | `<server> · <tool>` |
| anything else | `<name>` |
| assistant text block | its first non-empty line |

Then, in every mode:

1. Replace `[A-Za-z0-9_\-]{32,}` with `•••`.
2. Replace `(?i)(password|passwd|pwd|token|secret|api[_-]?key|authorization)\s*[=:]\s*\S+` with `$1=•••`.
3. Truncate to 80 characters.

Risk area: secrets on screen and during screen share.

**Hide details ON:**

- The activity shows the tool name only: no description, file name or text.
- The title is hidden. Line 1 becomes `repo · branch`.

### Notch panel (D1, D13, D14)

**Window**

- `NSPanel` with `styleMask [.borderless, .nonactivatingPanel]`.
- `collectionBehavior [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`.
- Never takes key focus.

**Placement**

- Screen: `NSScreen.screens.first`, the menu-bar screen.
- A notch exists when `safeAreaInsets.top > 0`. The notch rect is the gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`.
- With no notch, draw a 224×38 pill at the top centre.
- Reposition on `NSApplication.didChangeScreenParametersNotification`.

**Prior art:** vibe-notch@10f1d24 `Ext+NSScreen.swift:13-16` and `ScreenSelector.swift` (Apache-2.0). Read them for approach only: no SDKs, no hook code. If you adapt code, add a NOTICE entry and mark the changed files.

**Behaviour**

- **Collapsed:** the overlay matches the notch size while nothing is live. While a session works, needs you, or just finished, it grows an 80 pt side on each edge (spring): working dots and the working count on the left, the needs-you count with a breathing glow (or a green check for 4 s after a turn) on the right. The panel ignores the mouse, so menu bar items next to the notch stay clickable; hover and click are read by event monitors over the visible shape plus 4 pt (Q13).
- **Live (D35):** the strip described in D35. Hovering it expands to the full list.
- **Expand:** after hovering 150 ms, or on click. **Collapse:** 300 ms after the mouse leaves, or on Esc. The list scrolls past 520 pt.
- **Attention while expanded:** outline that row in place for 2.5 s.
- **Morph:** the controller computes every shape size from fixed row heights. Growing sets the panel frame first and springs the shape; shrinking springs first and trims the panel 480 ms later.
- **Esc (implementation note, 2026-10-24):** a global key monitor needs the Accessibility permission, which M6 forbids, so Esc is read by a local monitor and works only while AgentNotch is the active app (e.g. right after using the dropdown). Moving the pointer away always collapses.

### Menu bar item (D20, D21)

- `NSStatusItem(variableLength)` with a custom view:
  - an SF Symbol icon
  - a VStack of two 9-pt monospaced-digit numbers, working on top and waiting below
- Tint the icon orange when waiting > 0.
- **Click** opens an `NSPopover` containing:
  1. the `SessionRowView` list (the same view the notch uses)
  2. a divider
  3. Toggle "Hide details"
  4. Toggle "Launch at login"
  5. the version line (D24)
  6. "Quit AgentNotch"
- Write in the README: macOS hides overflowing menu bar items behind the notch when there are many. Tell users to ⌘-drag the item next to the clock.

### Focus (D14, D25, D27)

**Terminal** (tty from V2, e.g. `ttys003` → `/dev/ttys003`). Run through `NSAppleScript`:

```applescript
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "/dev/ttys003" then
        set selected of t to true
        set index of w to 1
        activate
        return
      end if
    end repeat
  end repeat
end tell
```

- Needs `NSAppleEventsUsageDescription` in Info.plist.
- If the owner denies permission or the script fails, call `NSRunningApplication` `activate` for `com.apple.Terminal`.

**Cursor and VS Code (D27):** run `NSRunningApplication.runningApplications(withBundleIdentifier:).first?.activate()` with the bundle id from F8. Never run `open -a <IDE> <cwd>`.

**Background:** there is no window. Clicking shows the text `claude attach <id>` and runs nothing (R1).

### scripts/bundle.sh

```sh
#!/bin/sh
set -eu
swift build -c release
APP=build/AgentNotch.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/AgentNotch "$APP/Contents/MacOS/AgentNotch"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.bagustyo92.agentnotch</string>
  <key>CFBundleName</key><string>AgentNotch</string>
  <key>CFBundleExecutable</key><string>AgentNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Focus the Terminal tab running a Claude Code session.</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "built $APP — install: cp -R $APP ~/Applications/"
```

### scripts/githooks/pre-commit (R6)

Enable with `git config core.hooksPath scripts/githooks`.

```sh
#!/bin/sh
fail=0
for f in $(git diff --cached --name-only --diff-filter=AM -- '*.jsonl' '*.json'); do
  if [ "$(wc -c < "$f")" -gt 20480 ]; then echo "blocked: $f > 20 KB (real transcript?)"; fail=1; fi
  if git show ":$f" | grep -qF "$HOME"; then echo "blocked: $f contains a real home path"; fail=1; fi
done
exit $fail
```

`.gitignore`: `.build/`, `build/`, `*.jsonl` and `!Tests/Fixtures/*.jsonl`.

## Milestones

Do them in order. Each one ends with its acceptance checks passing.

| M | Work | Acceptance |
|---|---|---|
| M0 | V1–V3, V5 now; V4 and V6 right after M1. Write the results into the facts table. | Every V item has a recorded result. |
| M1 | Skeleton: Package.swift, an empty accessory app, `bundle.sh`, pre-commit, `.gitignore`. | `scripts/bundle.sh` builds the app. Launching it shows no Dock icon. `swift test` passes one placeholder test. Committing a 30 KB `.jsonl` is blocked. |
| M2 | `AgentsCommand`, `RegistryReader`, `ProcessProbe`, `FileWatcher`, and `SessionStore` without activity. | **Tests:** <br>• decode synthetic `claude agents --json` output, both kinds <br>• decode registry files; `*.key` files are never opened <br>• fallback is used when the command is missing or exits non-zero <br>• status mapping and sort order <br>• done-linger expiry, with an injected clock <br>• attention events <br>**Live:** <br>• the debug list matches `claude agents --json` <br>• Source is correct for one Cursor and one Terminal session <br>• `top -pid` shows CPU below 1% over 60 s idle |
| M3 | `TranscriptTail` and `ActivitySummary`. | **Tests:** <br>• a partial line is completed on the next read <br>• truncation triggers re-attach <br>• the latest `ai-title` wins <br>• sidechain lines are skipped <br>• Bash shows the description and never the command <br>• the mask cases <br>• hide-details output <br>• unknown types are ignored <br>• 20 malformed lines give "activity unavailable" <br>**Live:** a tool call appears in the activity within 1 s. |
| M4 | Menu bar item and dropdown. | **Live:** <br>• the counts match <br>• the item turns orange while a session waits on a permission prompt <br>• Hide details works <br>• the version line appears when versions differ (fake it in a test) <br>• Quit works |
| M5 | Notch panel. | **Live:** <br>• the overlay sits exactly on the notch <br>• hovering expands it <br>• rows are identical to the dropdown's <br>• it pulses on a permission prompt and when a turn finishes <br>• menu bar items beside the notch stay clickable <br>• with an external display as the menu-bar screen, the pill appears at its top centre |
| M6 | Focus and launch at login. | **Live:** <br>• clicking a Terminal row selects the exact tab <br>• with Automation denied, Terminal still activates <br>• clicking a Cursor row brings Cursor forward without opening a new window <br>• no Accessibility permission is ever requested <br>• the login item survives a logout and login |
| M7 | Soak test. | **Live:** <br>• 8 h with 5 or more sessions: idle CPU below 1%, memory flat <br>• `kill -9` on a session turns its row Done, and the row disappears 10 min later <br>• quitting the app leaves every session unaffected |

## Open decisions

None. Q27 was resolved on 2026-10-24 as D27 (activate the app only).

The upgrade path, should it ever be needed: use the Accessibility permission to raise the window whose lock-file `workspaceFolders` contains the session's `cwd`, matched by window title. The owner must approve this first, because Accessibility is a broad permission.

## Out of scope for v1

- Subagent rows (v2)
- Cloud and remote sessions
- Notification banners or sound
- Any control action
- Other machines
- Sharing or distribution

## Risks

| Risk | Mitigation |
|---|---|
| Internal formats (F2, F5, F6) change in a Claude Code update. | D24 degrade plus the version line. Re-run V5 and the M3 live check after each update. |
| Registry writes become frequent, so `claude agents --json` would run often. | Cap it at 1 call/s. If it runs more than 30 times in a minute, switch to `RegistryReader` for 5 min. |
| The notch window level clashes with other notch or menu bar apps. | Verify in M5. Keep the collapsed overlay click-through. |
| The menu bar item ends up hidden behind the notch. | README note (⌘-drag). The notch surface still works. |
| Device management blocks the ad-hoc-signed app. | V4; ask IT (D8). Notarized releases would remove this; see the README. |
| With several IDE windows open, an IDE click brings forward the wrong window. | Accepted (D27). See the upgrade path under "Open decisions". |
