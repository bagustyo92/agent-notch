import AgentNotchCore
import AppKit

extension Source {
    /// F8. Nil for sources without a host app window.
    var bundleId: String? {
        switch self {
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .vscode: "com.microsoft.VSCode"
        case .terminal: "com.apple.Terminal"
        case .background, .unknown: nil
        }
    }
}

/// D14, D25, D27: focus a session's window. Read-only otherwise (R1).
@MainActor
enum Focus {

    /// Returns a message to display instead when there is nothing to focus.
    static func focus(_ session: Session) -> String? {
        switch session.source {
        case .background:
            return "claude attach \(session.id)"
        case .terminal:
            focusTerminal(tty: session.tty)
            return nil
        case .cursor, .vscode:
            // D28: open the exact chat in its own window when that window is known; otherwise
            // just bring the IDE forward (D27).
            if session.status != .done,
               let link = IDEDeepLink.resolve(source: session.source, sessionId: session.id, pid: session.pid, startedAt: session.startedAt) {
                NSWorkspace.shared.open(link)
            } else if let bundleId = session.source.bundleId {
                activate(bundleId: bundleId)
            }
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
