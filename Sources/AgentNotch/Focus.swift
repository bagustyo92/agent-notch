import AgentNotchCore
import AppKit

extension Source {
    /// F8. Nil for sources without a host app window.
    var bundleId: String? {
        switch self {
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .vscode: "com.microsoft.VSCode"
        case .orca: "com.stablyai.orca"
        case .terminal: "com.apple.Terminal"
        case .background, .unknown: nil
        }
    }
}

/// D14, D25, D27, D43, D44: focus a session's window. Read-only otherwise (R1).
@MainActor
enum Focus {
    static let windowNotFound = "Couldn't find this session's window"
    static let orcaWorkspaceNotFound = "Couldn't select this workspace in Orca"

    private static var clickToken: UInt64 = 0
    private static var orcaTask: Task<Void, Never>?

    /// Focus the session's window; invokes `onMessage` on `@MainActor` when there is a status
    /// message to display (synchronously for non-Orca sources, asynchronously for `.orca`).
    static func focus(_ session: Session, onMessage: @escaping @MainActor (String) -> Void) {
        clickToken &+= 1
        let token = clickToken
        orcaTask?.cancel()
        orcaTask = nil

        if session.source == .orca {
            if let bundleId = Source.orca.bundleId { activate(bundleId: bundleId) }
            let cwd = session.cwd
            let tty = session.tty
            let isLive = session.status != .done
            orcaTask = Task.detached(priority: .userInitiated) {
                let route = await OrcaFocus.focus(cwd: cwd, tty: tty, isLive: isLive)
                await MainActor.run {
                    guard clickToken == token else { return }
                    if route == .fallback { onMessage(Self.orcaWorkspaceNotFound) }
                }
            }
            return
        }

        if let message = focusSync(session) { onMessage(message) }
    }

    /// Returns a message to display instead when there is nothing to focus.
    private static func focusSync(_ session: Session) -> String? {
        switch session.source {
        case .background:
            return "claude attach \(session.id)"
        case .terminal:
            focusTerminal(tty: session.tty)
            return nil
        case .cursor, .vscode:
            // D43: the exact chat in its own trusted window (D28); else only raise the window it was
            // last seen in; else bring the IDE forward (D27) and say so.
            let target = IDEDeepLink.target(
                source: session.source, sessionId: session.id, pid: session.pid, startedAt: session.startedAt,
                isLive: session.status != .done, remembered: session.ideWindow
            )
            if let url = target.url {
                NSWorkspace.shared.open(url)
                return nil
            }
            if let bundleId = session.source.bundleId { activate(bundleId: bundleId) }
            // VS Code has no window routing at all (D28); the message is for Cursor's misses.
            return IDEDeepLink.supports(session.source) ? Self.windowNotFound : nil
        case .orca:
            return nil
        case .unknown:
            if session.tty != nil { focusTerminal(tty: session.tty); return nil }
            return session.pid == nil ? "claude attach \(session.id)" : "No window found for this session"
        }
    }

    /// Select the exact Terminal tab by tty (D25); on denial or failure just activate Terminal.
    static func focusTerminal(tty: String?) {
        if let tty, tty.allSatisfy({ $0.isLetter || $0.isNumber }), runTerminalScript(tty: "/dev/\(tty)") { return }
        if let bundleId = Source.terminal.bundleId { activate(bundleId: bundleId) }
    }

    private static func runTerminalScript(tty: String) -> Bool {
        let source = """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected of t to true
                set index of w to 1
                activate
                return true
              end if
            end repeat
          end repeat
        end tell
        return false
        """
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return false }
        return result.booleanValue
    }

    /// D27: activate the IDE by bundle id only. Never `open -a <IDE> <cwd>`.
    static func activate(bundleId: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return }
        NSApp.activate()
        _ = app.activate(from: .current, options: [.activateIgnoringOtherApps])
    }
}
