import AgentNotchCore
import AppKit

@main
@MainActor
struct AgentNotchMain {
    static func main() {
        let args = CommandLine.arguments
        let full = args.contains("--full")
        if args.contains("--dump") {
            DebugDump.run(watchSeconds: 0, full: full)
            return
        }
        if let i = args.firstIndex(of: "--watch") {
            DebugDump.run(watchSeconds: Double(args.dropFirst(i + 1).first.flatMap(Double.init) ?? 20), full: full)
            return
        }
        if let i = args.firstIndex(of: "--login-item") {
            switch args.dropFirst(i + 1).first {
            case "on": print(LoginItem.set(enabled: true) ?? "ok")
            case "off": print(LoginItem.set(enabled: false) ?? "ok")
            default: print(LoginItem.statusDescription)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        if let i = args.firstIndex(of: "--demo") { delegate.demoScene = args.dropFirst(i + 1).first ?? "notch" }
        app.delegate = delegate
        // Belt and braces with LSUIElement: no Dock icon even when run via `swift run` (D16).
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    let settings = Settings()
    private var monitor: Monitor?
    private var statusItem: StatusItemController?
    private var notch: NotchPanelController?
    private var demo: DemoDriver?
    /// Set by `--demo`: replay synthetic sessions instead of watching real ones.
    var demoScene: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let scene = demoScene {
            // The dropdown scene is a still of the menu bar card: no notch panel in front of it.
            // The menubar scene drives the real menu bar item, so it has neither a stage nor a notch.
            if scene == "menubar" {
                statusItem = StatusItemController(store: store, settings: settings)
            } else if scene != "dropdown" {
                let notch = NotchPanelController(store: store, settings: settings)
                self.notch = notch
                store.onAttention = { [weak notch] session, kind in notch?.attention(session, kind: kind) }
            }
            demo = DemoDriver.start(scene: scene, store: store, settings: settings, notch: notch, statusItem: statusItem)
            return
        }
        let monitor = Monitor(store: store)
        self.monitor = monitor
        statusItem = StatusItemController(store: store, settings: settings)
        let notch = NotchPanelController(store: store, settings: settings)
        self.notch = notch
        store.onAttention = { [weak notch] session, kind in notch?.attention(session, kind: kind) }
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }
}

/// `AgentNotch --dump`: one refresh, print the rows, exit. `--watch <s>`: run the monitor and
/// print every row change with a timestamp. Used by the M2/M3 live checks. Output is pasted into
/// public issues, so titles and activity are hidden unless `--full` is passed (Hide details rules).
@MainActor
enum DebugDump {
    static func run(watchSeconds: Double, full: Bool) {
        let monitor = Monitor()
        Task { @MainActor in
            if watchSeconds <= 0 {
                await monitor.refresh()
                try? await Task.sleep(for: .seconds(1.5))
                monitor.store.sessions.forEach { print(row($0, full: full)) }
            } else {
                monitor.start()
                var last: [String: String] = [:]
                let deadline = Date().addingTimeInterval(watchSeconds)
                while Date() < deadline {
                    for s in monitor.store.sessions {
                        let r = row(s, full: full)
                        if last[s.id] != r { last[s.id] = r; print("\(stamp())\t\(r)"); fflush(stdout) }
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                monitor.stop()
            }
            print("working=\(monitor.store.workingCount) waiting=\(monitor.store.waitingCount) note=\(monitor.store.versionNote ?? "-")")
            exit(0)
        }
        dispatchMain()
    }

    static func row(_ s: Session, full: Bool) -> String {
        let pid = s.pid.map(String.init) ?? "-"
        let title = full ? s.title : "(hidden)"
        let activity = (full ? s.activity?.full : s.activity?.brief) ?? (s.activityUnavailable ? "activity unavailable" : "-")
        let model = ModelName.capsule(model: s.model, effort: s.effort) ?? "-"
        let agents = s.subagents.map { "\($0.agentType):\($0.finished ? "done" : $0.phase?.rawValue ?? "-")" }.joined(separator: ",")
        let link = IDEDeepLink.resolve(source: s.source, sessionId: s.id, pid: s.pid, startedAt: s.startedAt)?.absoluteString ?? "-"
        return "\(s.status)\t\(pid)\t\(s.source)\t\(s.tty ?? "-")\t\(s.claudeVersion ?? "-")\t\(s.repo)\t\(s.branch ?? "-")\t\(title)\t\(activity)\tphase=\(s.phase?.rawValue ?? "-")\tmodel=\(model)\twaitingFor=\(s.waitingFor ?? "-")\tagents=[\(agents)]\tlink=\(link)"
    }

    static func stamp() -> String {
        Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
    }
}
