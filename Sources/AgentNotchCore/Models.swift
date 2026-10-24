import Foundation

/// Where a session's process comes from. Decided from the executable path (F4).
public enum Source: String, Sendable, Equatable, CaseIterable {
    case terminal, vscode, cursor, background, unknown
}

/// Display status. The raw value is the sort rank (D12, "Sort order").
public enum Status: Int, Sendable, Comparable, CaseIterable {
    case waiting = 0, working, idle, done

    public static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The "Status mapping" table; see `ListedSession.mappedStatus`.
    public static func from(_ entry: ListedSession) -> Status { entry.mappedStatus }
}

/// Whether the list entry was an interactive TTY/IDE session or a `claude --bg` one.
public enum SessionKind: String, Sendable, Equatable {
    case interactive, background
}

/// The activity line in both display modes (D11). Both strings are derived and masked;
/// the raw tool input or transcript text is never kept (R4).
public struct Activity: Sendable, Equatable {
    /// e.g. `Bash · run unit tests`, `Edit · Models.swift`
    public var full: String
    /// Hide-details variant: the tool name only, e.g. `Bash`, `Edit`.
    public var brief: String

    public init(full: String, brief: String) { self.full = full; self.brief = brief }
}

/// One live (or recently ended) Claude Code session. Every string in here is
/// already derived and masked; the struct never carries raw transcript text (R4).
public struct Session: Identifiable, Sendable, Equatable {
    public let id: String            // sessionId
    public var pid: Int32?
    public var cwd: String
    public var repo: String { (cwd as NSString).lastPathComponent }
    public var branch: String?
    /// Registry/list `name`; the title falls back to it (D10).
    public var name: String
    /// Latest `ai-title` from the transcript (D10); the latest one wins (F6).
    public var aiTitle: String?
    public var title: String { aiTitle ?? name }
    public var kind: SessionKind
    public var source: Source
    public var status: Status
    public var statusChangedAt: Date
    public var activity: Activity?
    /// Set after 20 decode failures with no success (D24).
    public var activityUnavailable: Bool = false
    public var startedAt: Date
    public var endedAt: Date?
    public var claudeVersion: String?
    public var tty: String?

    public init(
        id: String, pid: Int32? = nil, cwd: String, branch: String? = nil, name: String, aiTitle: String? = nil,
        kind: SessionKind = .interactive, source: Source = .unknown, status: Status, statusChangedAt: Date,
        activity: Activity? = nil, activityUnavailable: Bool = false, startedAt: Date, endedAt: Date? = nil,
        claudeVersion: String? = nil, tty: String? = nil
    ) {
        self.id = id; self.pid = pid; self.cwd = cwd; self.branch = branch; self.name = name; self.aiTitle = aiTitle
        self.kind = kind; self.source = source; self.status = status; self.statusChangedAt = statusChangedAt
        self.activity = activity; self.activityUnavailable = activityUnavailable
        self.startedAt = startedAt; self.endedAt = endedAt; self.claudeVersion = claudeVersion; self.tty = tty
    }
}
