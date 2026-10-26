import Foundation

/// Where a session's process comes from. Decided from the executable path (F4).
public enum Source: String, Sendable, Equatable, CaseIterable {
    case terminal, vscode, cursor, background, unknown
}

/// Display status. The raw value is the sort rank (D12, "Sort order").
public enum Status: Int, Sendable, Comparable, CaseIterable {
    case waiting = 0, working, idle, done

    public static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Working or waiting: a turn is in progress.
    public var isActive: Bool { self == .working || self == .waiting }

    /// The "Status mapping" table; see `ListedSession.mappedStatus`.
    public static func from(_ entry: ListedSession) -> Status { entry.mappedStatus }
}

/// Whether the list entry was an interactive TTY/IDE session or a `claude --bg` one.
public enum SessionKind: String, Sendable, Equatable {
    case interactive, background
}

/// What a working session is doing right now, from its newest transcript line (D29). Claude Code
/// writes nothing while the model streams a thought, so `thinking` also covers "a tool result or
/// prompt arrived and no reply has been written yet": the UI shows a rotating verb then.
public enum Phase: String, Sendable, Equatable {
    case thinking, tool, writing
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
    /// Newest phase from the transcript (D29); meaningful only while `status == .working`.
    public var phase: Phase?
    /// Model id and effort level of the newest assistant line, e.g. `claude-opus-5-5`, `high` (D30).
    public var model: String?
    public var effort: String?
    /// Why a waiting session waits (`dialog open`, `input needed`, …) and Claude Code's own
    /// one-line `needs` text, masked (D31). The UI hides `needs` under Hide details.
    public var waitingFor: String?
    public var needs: String?
    /// When the last turn finished (working → idle), for the green "Finished" state (D32).
    public var turnFinishedAt: Date?
    /// When the current or last turn started: idle or new → working or waiting (D39).
    public var turnStartedAt: Date?
    /// Distinct files the last finished turn edited, its subagents' included (D39).
    public var turnFileCount: Int = 0
    /// Context size of the newest main-chain reply, and the window it counts against: nil for an
    /// unknown model (D38).
    public var contextTokens: Int?
    public var contextWindow: Int?
    /// Subagents of the current turn, plus any still running (D33).
    public var subagents: [Subagent] = []

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

/// One subagent of a session, from `<sessionId>/subagents/agent-<id>.{jsonl,meta.json}` (D33).
/// Strings are derived and masked like the session's own.
public struct Subagent: Identifiable, Sendable, Equatable {
    public let id: String
    /// `general-purpose`, `Explore`, … from the meta file.
    public var agentType: String
    /// The short task description the parent gave it.
    public var description: String
    /// The parent's `Agent` tool_use id; a grandchild's id appears in its parent subagent's
    /// `spawnedToolUseIds`.
    public var toolUseId: String?
    public var spawnDepth: Int
    public var spawnedToolUseIds: Set<String> = []
    public var phase: Phase?
    public var activity: Activity?
    public var model: String?
    public var effort: String?
    public var finished: Bool
    public var startedAt: Date
    public var finishedAt: Date?
    /// Last time its transcript grew; drives the stale sweep.
    public var lastWriteAt: Date

    public init(
        id: String, agentType: String, description: String, toolUseId: String? = nil, spawnDepth: Int = 1,
        phase: Phase? = nil, activity: Activity? = nil, model: String? = nil, effort: String? = nil,
        finished: Bool = false, startedAt: Date, finishedAt: Date? = nil, lastWriteAt: Date
    ) {
        self.id = id; self.agentType = agentType; self.description = description; self.toolUseId = toolUseId
        self.spawnDepth = spawnDepth; self.phase = phase; self.activity = activity; self.model = model
        self.effort = effort; self.finished = finished; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.lastWriteAt = lastWriteAt
    }
}

/// One read of a subagent's meta file and transcript, before it is merged into the store.
public struct SubagentUpdate: Sendable, Equatable {
    public var agentId: String
    public var agentType: String
    public var description: String
    public var toolUseId: String?
    public var spawnDepth: Int
    public var finished: Bool
    /// Transcript creation and modification times.
    public var startedAt: Date?
    public var lastWriteAt: Date?
    /// Nil when the transcript had nothing new.
    public var transcript: TranscriptUpdate?

    public init(
        agentId: String, agentType: String = "Agent", description: String = "", toolUseId: String? = nil,
        spawnDepth: Int = 1, finished: Bool = false, startedAt: Date? = nil, lastWriteAt: Date? = nil,
        transcript: TranscriptUpdate? = nil
    ) {
        self.agentId = agentId; self.agentType = agentType; self.description = description; self.toolUseId = toolUseId
        self.spawnDepth = spawnDepth; self.finished = finished; self.startedAt = startedAt; self.lastWriteAt = lastWriteAt
        self.transcript = transcript
    }
}
