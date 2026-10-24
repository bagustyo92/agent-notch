import Foundation

/// D28: open the exact chat of an IDE-extension session.
///
/// The Claude Code extension registers `<scheme>://anthropic.claude-code/open?session=<id>`; it
/// reveals the tab (or sidebar) that already holds the session. If the receiving window does NOT
/// hold it, the extension opens a new tab and resumes the session, which would be a second process
/// on a live session (R1). So the link always carries `windowId=<n>`: Cursor's URL router delivers
/// it to exactly that window. The window id comes from the session's parent process, the window's
/// extension host, whose title is `… extension-host (user) <workspace> [<windowId>-<n>]` (F18).
///
/// Every step is checked so a stale row or a reused pid can never produce a link: the pid must be
/// alive, still be the Cursor extension's `claude`, have started when the session started, and its
/// parent must be a Cursor helper.
public enum IDEDeepLink {
    /// Sources whose IDE is verified to route `windowId=` (F18). VS Code is not verified yet.
    static let schemes: [Source: String] = [.cursor: "cursor"]
    /// The registry's `startedAt` is written shortly after the process starts.
    static let startTolerance: TimeInterval = 120

    /// Process facts the resolver needs; injectable for tests.
    public struct Probe: Sendable {
        public var isAlive: @Sendable (Int32) -> Bool
        public var executablePath: @Sendable (Int32) -> String?
        public var startTime: @Sendable (Int32) -> Date?
        public var parentPid: @Sendable (Int32) -> Int32?
        public var processTitle: @Sendable (Int32) -> String?

        public init(
            isAlive: @escaping @Sendable (Int32) -> Bool, executablePath: @escaping @Sendable (Int32) -> String?,
            startTime: @escaping @Sendable (Int32) -> Date?, parentPid: @escaping @Sendable (Int32) -> Int32?,
            processTitle: @escaping @Sendable (Int32) -> String?
        ) {
            self.isAlive = isAlive; self.executablePath = executablePath; self.startTime = startTime
            self.parentPid = parentPid; self.processTitle = processTitle
        }

        public static let live = Probe(
            isAlive: ProcessProbe.isAlive, executablePath: ProcessProbe.executablePath,
            startTime: ProcessProbe.startTime, parentPid: ProcessProbe.parentPid,
            processTitle: ProcessProbe.processTitle
        )
    }

    public static func windowId(fromExtensionHostTitle title: String) -> Int? {
        guard title.contains("extension-host"),
              let match = title.firstMatch(of: /\[([1-9][0-9]{0,8})-[0-9]+\]\s*$/) else { return nil }
        return Int(match.1)
    }

    public static func url(source: Source, sessionId: String, windowId: Int?) -> URL? {
        guard let scheme = schemes[source], let windowId, windowId > 0,
              !sessionId.isEmpty, sessionId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        return URL(string: "\(scheme)://anthropic.claude-code/open?session=\(sessionId)&windowId=\(windowId)")
    }

    /// session pid → (verified) parent extension host → its title → window id → link.
    public static func resolve(source: Source, sessionId: String, pid: Int32?, startedAt: Date, probe: Probe = .live) -> URL? {
        guard schemes[source] != nil, let pid, pid > 1, probe.isAlive(pid),
              Source.classify(executablePath: probe.executablePath(pid)) == source,
              let processStart = probe.startTime(pid),
              abs(startedAt.timeIntervalSince(processStart)) <= startTolerance,
              let parent = probe.parentPid(pid), parent > 1, probe.isAlive(parent),
              let parentExe = probe.executablePath(parent), parentExe.contains("/Cursor.app/"),
              let title = probe.processTitle(parent) else { return nil }
        return url(source: source, sessionId: sessionId, windowId: windowId(fromExtensionHostTitle: title))
    }
}
