# Changelog

## 0.6.2

- **Orca session detection and click routing.** Claude Code sessions running inside Orca — both native Orca Chat (`orca-provider-exec`) and Orca Terminal panes (`Orca Agents` ancestor) — are now classified as `Orca` instead of `Terminal`.
- Clicking an Orca row immediately brings Orca (`com.stablyai.orca`) forward and runs Orca's documented CLI off the main actor (only on click, always with `--environment local` and stripped `ORCA_*` env vars):
  - Live Orca Terminal sessions switch to the exact terminal pane (`orca terminal switch`) when a single local, connected, non-orphaned terminal matches the deepest enclosing worktree; ambiguous or failed switches fall through.
  - Orca Chat sessions, Done Orca rows, and terminal fallbacks activate the enclosing local git worktree (`orca worktree activate --worktree current`).
  - When Orca cannot select the workspace (for example, an Orca folder workspace), Orca stays active and the banner shows `"Couldn't select this workspace in Orca"`.
- `--dump` prints `orca` in the source column and `link=orca:terminal`, `link=orca:worktree`, or `link=-` without printing raw working directories.

## 0.6.1

- **Clicking a Cursor row opens the right window when several are open.** Before, a click could raise a different project's window: either the link pointed at a window that had since opened another project, or no link was built and AgentNotch only activated Cursor, which raises the last active window.
- A session listed under two processes (resumed in a second window while the first lingers) now stands for the process in the window that holds it, and its start time comes from that same process. This was why some idle rows got no link at all.
- The exact-chat link is sent only when the session's extension host is still the current one for its window. A host left over from a window's earlier project, or the older of two windows on the same project, never gets it, because Cursor would resume the chat in the wrong window as a second process.
- A finished row, or one whose window can't be trusted any more, now raises the window the session was last seen in (`cursor://anthropic.claude-code/focus?windowId=<n>`, which opens no tab), as long as that Cursor is still running and the window still shows the project. Otherwise AgentNotch activates Cursor and says "Couldn't find this session's window".
- `--dump` prints what a click would send in `link=`, plus `window=` (the remembered window) and `trust=`.
- VS Code still only activates the app: it gives no reliable way to tell its windows apart (details in D28).

## 0.6.0

- **Background children.** When a turn ends while its subagents or background Bash commands (`run_in_background`) keep running, the session no longer reads plain Idle. It stays in Done, pinned to the top, with `· 2 in background` in violet, and its running children show under it in a new Background state: a static violet ring and `Background · <activity>`. The header adds `● 2 in background`, and "All quiet" shows only when nothing runs at all. Background work never opens the notch and leaves the collapsed notch and the menu bar item alone.
- Background Bash tasks get their own rows, `Bash` and its description, nested under the agent that started them: `Background` once the turn has ended, `Running` while it goes on. A row goes as soon as its task's notification arrives, when the task is stopped with `TaskStop` (which sends no notification), or when its launch was denied. They are read from transcripts AgentNotch already tails; the task output files under `/private/tmp` are never opened.
- A quiet subagent of an idle session is now kept for 30 minutes, as for a working one, instead of 3. A fork waiting on a long test run no longer disappears. A child that finishes after its session's turn ended is removed at once.
- `--dump` and `--watch` print each session's open tasks (`tasks=[Bash:4m 2s]`, the description only with `--full`) and the summary line adds `background=N`. `--watch` also prints that line, with a timestamp, whenever a count changes.
- `--demo background` replays a turn that ends while its fork and a Bash server keep running, for the README clip.
- **CPU while sessions work: about 0.1%, down from about 24%.** The working dots, the needs-you glow and the thinking shimmer now run as Core Animation, so the window server animates them and AgentNotch does nothing per frame; they look and move as before. The menu bar item's working dots are now still: macOS re-snapshots the whole item for every animation frame, which alone cost about 18%. The notch keeps the motion. `--demo bench-<working|waiting|thinking>[-strip]` holds one state for measuring.
- Known limits: a task started more than 4 MB back in a transcript when AgentNotch launches is missed, as is one started by a subagent that had already finished then.

## 0.5.0

- Each row's model capsule shows how full the session's context is, `Opus 5.5 · high · 62%`, with the formula of Claude Code's status line. It turns amber at 75% of the auto-compact point and red at 90%; a model AgentNotch does not know shows a raw count (`412k`). The live strip adds `· 81% ctx` when a session is amber or red. Shown under Hide details; not on done sessions or subagents.
- The Finished line summarises the turn: `Finished 2m ago · 4 files · ran 3m`. Files are the distinct ones edited with Edit, Write, MultiEdit or NotebookEdit by the session and its subagents; paths are hashed in memory and never kept. Edits made through Bash are not counted.
- `--dump` and `--watch` print each session's context (`ctx=`, `tokens=`) and its last turn's file count (`files=`).
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
