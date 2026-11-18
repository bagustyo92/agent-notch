import Foundation

/// The window a Cursor session was last seen in, under a trusted host (D43). Window ids restart
/// with the IDE, so it is bound to the IDE main process that numbered it. Memory only (R4).
public struct IDEWindow: Sendable, Equatable {
    public var windowId: Int
    public var workspace: String
    public var mainPid: Int32
    public var mainStartedAt: Date

    public init(windowId: Int, workspace: String, mainPid: Int32, mainStartedAt: Date) {
        self.windowId = windowId; self.workspace = workspace; self.mainPid = mainPid; self.mainStartedAt = mainStartedAt
    }
}

/// D28, D43: open the exact chat of an IDE-extension session, or at least its window.
///
/// The Claude Code extension registers `<scheme>://anthropic.claude-code/open?session=<id>`; it
/// reveals the tab (or sidebar) that already holds the session. If the receiving window does NOT
/// hold it, the extension opens a new tab and resumes the session, which would be a second process
/// on a live session (R1). So the link always carries `windowId=<n>`: Cursor's URL router delivers
/// it to exactly that window. The window id comes from the session's parent process, the window's
/// extension host, whose title is `… extension-host (user) <workspace> [<windowId>-<n>]` (F18).
///
/// Every step is checked so a stale row or a reused pid can never produce a link: the pid must be
/// alive, still be the Cursor extension's `claude`, have started when the session started, its
/// parent must be a Cursor helper, and that host must be trusted (D43, `isTrusted`).
///
/// Otherwise a click can still raise the session's window: `/focus?windowId=<n>` makes Cursor
/// focus window n, and the extension ignores the unknown path (F27). That needs a remembered
/// window whose IDE main process still runs and whose window still shows the session's workspace.
public enum IDEDeepLink {
    /// An IDE whose URL router is verified to route `windowId=` exactly (F18, F27).
    struct IDEApp: Sendable {
        /// URL scheme of the extension's links.
        let scheme: String
        /// Path fragment shared by the app's main process and its helpers.
        let bundle: String
        /// Path suffix of the main process, the parent of every extension host (F26).
        let main: String
    }

    /// VS Code is not verified (D28).
    static let apps: [Source: IDEApp] = [
        .cursor: IDEApp(scheme: "cursor", bundle: "/Cursor.app/", main: "/Cursor.app/Contents/MacOS/Cursor"),
    ]

    /// Whether clicks on this source's rows can use links at all.
    public static func supports(_ source: Source) -> Bool { apps[source] != nil }
    /// The registry's `startedAt` is written shortly after the process starts.
    static let startTolerance: TimeInterval = 120
    /// A remembered main process must have started at the same time, give or take rounding.
    static let mainStartTolerance: TimeInterval = 1

    /// Process facts the resolver needs; injectable for tests.
    public struct Probe: Sendable {
        public var isAlive: @Sendable (Int32) -> Bool
        public var executablePath: @Sendable (Int32) -> String?
        public var startTime: @Sendable (Int32) -> Date?
        public var parentPid: @Sendable (Int32) -> Int32?
        public var processTitle: @Sendable (Int32) -> String?
        public var allPids: @Sendable () -> [Int32]

        public init(
            isAlive: @escaping @Sendable (Int32) -> Bool, executablePath: @escaping @Sendable (Int32) -> String?,
            startTime: @escaping @Sendable (Int32) -> Date?, parentPid: @escaping @Sendable (Int32) -> Int32?,
            processTitle: @escaping @Sendable (Int32) -> String?, allPids: @escaping @Sendable () -> [Int32]
        ) {
            self.isAlive = isAlive; self.executablePath = executablePath; self.startTime = startTime
            self.parentPid = parentPid; self.processTitle = processTitle; self.allPids = allPids
        }

        public static let live = Probe(
            isAlive: ProcessProbe.isAlive, executablePath: ProcessProbe.executablePath,
            startTime: ProcessProbe.startTime, parentPid: ProcessProbe.parentPid,
            processTitle: ProcessProbe.processTitle, allPids: ProcessProbe.allPids
        )
    }

    /// Where a click on an IDE row goes (D43).
    public enum Target: Sendable, Equatable {
        /// `open?session=<id>&windowId=<n>`: the exact chat, in its own trusted window.
        case chat(URL)
        /// `focus?windowId=<n>`: only raise the remembered window. Carries no session.
        case window(URL)
        /// Nothing safe to send; the caller activates the app (D27).
        case none

        public var url: URL? {
            switch self {
            case .chat(let url), .window(let url): url
            case .none: nil
            }
        }
    }

    /// The host a live session runs under, and whether a link may use its window.
    public struct Located: Sendable, Equatable {
        public var host: ExtensionHost
        public var trusted: Bool
        /// Set only when `trusted`.
        public var window: IDEWindow?
    }

    /// One extension host of one IDE window, parsed from its process title (F18, F26):
    /// `… extension-host (<role>) <workspace> [<windowId>-<counter>]`. Newer Cursor builds start
    /// `retrieval`, `always-local` and `agent-exec` hosts next to each window's `user` host; the
    /// Claude Code extension runs in the `user` one. `counter` grows across the whole IDE main
    /// process, so a higher one is a newer host.
    public struct ExtensionHost: Sendable, Equatable {
        public var pid: Int32
        public var parentPid: Int32
        /// Nil when the title has no role; such a host counts as a user host.
        public var role: String?
        public var workspace: String
        public var windowId: Int
        public var counter: Int

        public init(pid: Int32, parentPid: Int32, role: String?, workspace: String, windowId: Int, counter: Int) {
            self.pid = pid; self.parentPid = parentPid; self.role = role
            self.workspace = workspace; self.windowId = windowId; self.counter = counter
        }

        public var isUser: Bool { role == nil || role == "user" }

        public static func parse(title: String, pid: Int32, parentPid: Int32) -> ExtensionHost? {
            guard let match = title.firstMatch(
                of: /extension-host(?: \(([a-z][a-z-]{0,31})\))?(?: (.*?))? \[([1-9][0-9]{0,8})-([0-9]{1,9})\]\s*$/
            ), let windowId = Int(match.3), let counter = Int(match.4) else { return nil }
            return ExtensionHost(pid: pid, parentPid: parentPid, role: match.1.map(String.init),
                                 workspace: match.2.map(String.init) ?? "", windowId: windowId, counter: counter)
        }
    }

    /// D43: may a link carry this host's window id? Only a user host, and only when no other live
    /// user host of the same IDE main process
    /// - has the same window id and a higher counter: this host is left over from the window's
    ///   earlier workspace, and the window now shows another project;
    /// - shows the same workspace in a higher-numbered window: this host's window may be closed,
    ///   and the IDE would route the link to its last focused window instead.
    public static func isTrusted(_ host: ExtensionHost, among hosts: [ExtensionHost]) -> Bool {
        guard host.isUser else { return false }
        return !hosts.contains { other in
            guard other.pid != host.pid, other.isUser, other.parentPid == host.parentPid else { return false }
            if other.windowId == host.windowId, other.counter > host.counter { return true }
            return !host.workspace.isEmpty && other.workspace == host.workspace && other.windowId > host.windowId
        }
    }

    public static func windowId(fromExtensionHostTitle title: String) -> Int? {
        ExtensionHost.parse(title: title, pid: 0, parentPid: 0)?.windowId
    }

    /// Internal so the app can only get a chat link through `target`, which checks trust.
    static func url(source: Source, sessionId: String, windowId: Int?) -> URL? {
        guard let scheme = apps[source]?.scheme, let windowId, windowId > 0,
              !sessionId.isEmpty, sessionId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        return URL(string: "\(scheme)://anthropic.claude-code/open?session=\(sessionId)&windowId=\(windowId)")
    }

    /// Raises window n and nothing else (F27). Never carries a session.
    public static func focusURL(source: Source, windowId: Int) -> URL? {
        guard let scheme = apps[source]?.scheme, windowId > 0 else { return nil }
        return URL(string: "\(scheme)://anthropic.claude-code/focus?windowId=\(windowId)")
    }

    /// Every live extension host of the source's IDE. Reads the executable path of each pid, then
    /// argv[0] of the IDE's own processes (R7: on a click or a list refresh, never on a timer).
    public static func hosts(source: Source, probe: Probe = .live) -> [ExtensionHost] {
        guard let app = apps[source] else { return [] }
        return probe.allPids().compactMap { pid in
            guard let exe = probe.executablePath(pid), exe.contains(app.bundle), !exe.hasSuffix(app.main),
                  let title = probe.processTitle(pid), title.contains("extension-host"),
                  let parent = probe.parentPid(pid) else { return nil }
            return ExtensionHost.parse(title: title, pid: pid, parentPid: parent)
        }
    }

    /// session pid → (verified) parent extension host → trust among `hosts`. Fails closed: a host
    /// missing from `hosts` (an incomplete scan) or not parented by the IDE's main process is
    /// never trusted, so nothing unproven reaches the chat link (R1).
    public static func locate(source: Source, pid: Int32?, startedAt: Date, hosts: [ExtensionHost], probe: Probe = .live) -> Located? {
        guard let app = apps[source], let pid, pid > 1, probe.isAlive(pid),
              Source.classify(executablePath: probe.executablePath(pid)) == source,
              let processStart = probe.startTime(pid),
              abs(startedAt.timeIntervalSince(processStart)) <= startTolerance,
              let parent = probe.parentPid(pid), parent > 1, probe.isAlive(parent),
              let parentExe = probe.executablePath(parent), parentExe.contains(app.bundle),
              let title = probe.processTitle(parent), let grandparent = probe.parentPid(parent),
              let host = ExtensionHost.parse(title: title, pid: parent, parentPid: grandparent) else { return nil }
        guard grandparent > 1, probe.executablePath(grandparent)?.hasSuffix(app.main) == true,
              let mainStart = probe.startTime(grandparent), hosts.contains(where: { $0.pid == parent }),
              isTrusted(host, among: hosts) else {
            return Located(host: host, trusted: false, window: nil)
        }
        let window = IDEWindow(windowId: host.windowId, workspace: host.workspace, mainPid: grandparent, mainStartedAt: mainStart)
        return Located(host: host, trusted: true, window: window)
    }

    /// A remembered window is usable while the same IDE main process runs and the window's newest
    /// user host still shows the same workspace and is trusted.
    public static func isUsable(_ window: IDEWindow, source: Source, hosts: [ExtensionHost], probe: Probe = .live) -> Bool {
        guard let app = apps[source], probe.isAlive(window.mainPid),
              probe.executablePath(window.mainPid)?.hasSuffix(app.main) == true,
              let start = probe.startTime(window.mainPid),
              abs(start.timeIntervalSince(window.mainStartedAt)) <= mainStartTolerance,
              let current = hosts.filter({ $0.isUser && $0.parentPid == window.mainPid && $0.windowId == window.windowId })
                  .max(by: { $0.counter < $1.counter })
        else { return false }
        return current.workspace == window.workspace && isTrusted(current, among: hosts)
    }

    /// D43's click order: the exact chat when the session is live under a trusted host; else its
    /// remembered window; else nothing. `isLive` is false for done rows, which never get the chat.
    public static func target(
        source: Source, sessionId: String, pid: Int32?, startedAt: Date, isLive: Bool,
        remembered: IDEWindow?, hosts known: [ExtensionHost]? = nil, probe: Probe = .live
    ) -> Target {
        guard supports(source) else { return .none }
        let hosts = known ?? hosts(source: source, probe: probe)
        if isLive, let located = locate(source: source, pid: pid, startedAt: startedAt, hosts: hosts, probe: probe),
           located.trusted, let url = url(source: source, sessionId: sessionId, windowId: located.host.windowId) {
            return .chat(url)
        }
        if let remembered, isUsable(remembered, source: source, hosts: hosts, probe: probe),
           let url = focusURL(source: source, windowId: remembered.windowId) {
            return .window(url)
        }
        return .none
    }
}
