<!-- Classification: PUBLIC -->
<p align="center"><img src="docs/icon.png" width="160" alt="AgentNotch icon"></p>

# AgentNotch

See every running Claude Code session on your Mac at a glance: in the notch and in the menu bar.

If you run several Claude Code sessions at once (Terminal, the Cursor or VS Code extension,
`claude --bg`), AgentNotch shows which ones are working, which are waiting for you, and what each
is doing right now. Click a row to jump to it. It is strictly **read-only**: it never approves,
sends, stops or resumes anything, installs no hooks, and makes no network calls.

> AgentNotch is an independent community project. It is not affiliated with or endorsed by Anthropic.

## Install

Requirements: macOS 15 or later, Apple silicon, and [Claude Code](https://docs.claude.com/en/docs/claude-code) installed.

### Option 1: download the app

1. Download `AgentNotch-<version>.dmg` from the [Releases](../../releases) page.
2. Open it and drag **AgentNotch** into **Applications**.
3. Open AgentNotch. The app is not notarized by Apple yet, so macOS blocks the first launch.
   Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
   Or run this once in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/AgentNotch.app
   ```

### Option 2: build from source

Needs only the Xcode Command Line Tools (`xcode-select --install`); full Xcode is optional.

```sh
git clone https://github.com/bagustyo92/agent-notch.git
cd agent-notch
scripts/install.sh      # builds, copies to ~/Applications, and launches
```

To start it at login, open the menu bar item and switch on **Launch at login**.

## What you see

- **Notch.** The number of working sessions sits left of the notch; an orange dot on the right
  means a session is waiting for you. Hover the notch (or click it) to expand the list; move the
  pointer away to close it. When a session starts waiting or finishes a turn, the notch briefly
  opens with just that row. Macs without a notch get a small pill at the top of the screen.
- **Menu bar.** A little bot with two numbers: working on top, waiting below. It turns orange
  when something waits. Click it for the same list plus settings. If you can't see it, macOS may
  be hiding it behind the notch: hold ⌘ and drag it next to the clock.
- **Each row.** The session's title, then `repo · branch · where it runs · elapsed`, then a
  one-line summary of the current activity (for example `Edit · Login.swift`).
- **Click a row.**
  - Cursor: opens that exact chat tab in its window.
  - VS Code: brings VS Code forward.
  - Terminal: selects the exact tab. The first click asks for permission to control Terminal.
  - Background (`claude --bg`): shows the `claude attach <id>` command to copy; runs nothing.
- **Hide details** (menu bar dropdown) reduces every row to `repo · branch` and the tool name, for
  screen sharing.

Ended sessions show **Done** for 10 minutes, then disappear.

## Privacy

AgentNotch only reads, and only on your Mac:

- the session list from `claude agents --json`, or `~/.claude/sessions/*.json` if that fails;
- the tail of each session's transcript under `~/.claude/projects/`, to show the current title,
  branch and a safe activity line;
- process facts (executable path, terminal, parent process) for the session processes.

It never opens `*.key` files or reads tokens, never shows Bash commands, search patterns, URLs or
queries, masks anything that looks like a secret, and keeps everything in memory. The only things
it saves are your two settings. It makes no network connections of any kind.

## Uninstall

Quit it from the menu bar dropdown, switch off **Launch at login** first if you turned it on, then
delete the app and its two settings:

```sh
rm -rf /Applications/AgentNotch.app ~/Applications/AgentNotch.app
defaults delete local.agentnotch
```

## Contributing

Bug reports, ideas and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md);
the design, hard rules and decisions live in [docs/DESIGN.md](docs/DESIGN.md).

Handy flags while developing:

```sh
.build/debug/AgentNotch --dump          # print the current rows once
.build/debug/AgentNotch --watch 30      # print row changes with timestamps for 30 s
```

## License

[MIT](LICENSE)
