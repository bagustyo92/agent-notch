import Foundation
import Observation

/// Why the notch should open (D13, Q11): a session started working, needs you, or finished a turn.
public enum AttentionKind: Sendable, Equatable {
    case started, needsYou, finished
}

public struct AttentionEvent: Sendable, Equatable {
    public var session: Session
    public var kind: AttentionKind
    public var id: String { session.id }
}

/// The single in-memory model both surfaces render from (D21). Merges list results, maps
/// status, keeps ended sessions as "Done" for `lingerDuration` (D12), emits attention events
/// (D13) and derives the counts for the menu bar item (D20). Nothing here touches disk (R4).
@MainActor
@Observable
public final class SessionStore {
    public static let defaultTestedVersion = "2.1.310"
    public static let defaultTestedAntigravityVersion = "1.5.15"

    public private(set) var sessions: [Session] = []
    public private(set) var versionNote: String?
    /// Receives every attention event (D13). Set by the UI layer.
    @ObservationIgnored public var onAttention: ((Session, AttentionKind) -> Void)?
    /// The most recent attention events (at most `attentionLogLimit`); tests read it, the UI ignores it.
    @ObservationIgnored public private(set) var attentionLog: [AttentionEvent] = []
    public static let attentionLogLimit = 50
    /// How long a finished turn keeps the live strip and the green check up (Q12).
    public static let finishFlash: TimeInterval = 4
    /// An unfinished subagent whose transcript has not grown for this long is dropped: its process
    /// was killed without the meta file saying so. The same whether the parent works or is idle: a
    /// fork waiting on a long foreground command writes nothing meanwhile (D41).
    public static let subagentStale: TimeInterval = 1800
    /// Task records remembered per session for a record read before the one it matches: closes before
    /// their start (D41), `TaskStop` ids before their acknowledgement (F25). At most this many of each.
    static let taskRecordMemory = 512

    public var workingCount: Int { sessions.filter { $0.status == .working }.count }
    public var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }
    /// Running children of idle sessions: the header's `N in background` chip (D41).
    public var backgroundCount: Int { sessions.reduce(0) { $0 + $1.backgroundChildCount } }

    /// Sessions for the live strip: working, needing you, or finished within `finishFlash` (Q10, Q12).
    public func liveSessions(now: Date) -> [Session] {
        sessions.filter { $0.status == .working || $0.status == .waiting || Self.justFinished($0, now: now) }
    }

    public func anyJustFinished(now: Date) -> Bool { sessions.contains { Self.justFinished($0, now: now) } }

    static func justFinished(_ s: Session, now: Date) -> Bool {
        guard s.status == .idle, let at = s.turnFinishedAt else { return false }
        return now.timeIntervalSince(at) < finishFlash
    }

    private let testedVersion: String
    private let lingerDuration: TimeInterval
    private let backgroundFreshness: TimeInterval
    private let attentionInterval: TimeInterval
    @ObservationIgnored private var byId: [String: Session] = [:]
    @ObservationIgnored private var lastAttentionAt: [String: Date] = [:]
    /// Finished subagents folded away at the end of their parent's turn; never re-added (Q22).
    @ObservationIgnored private var dismissedSubagents: [String: Set<String>] = [:]
    /// Background-task closes per session, oldest first, at most `taskRecordMemory` (D41). The start and
    /// the close of a subagent's task can sit in different files, so a close may be read first.
    @ObservationIgnored private var closedTasks: [String: [String]] = [:]
    /// Task ids `TaskStop` named before the store knew their task, per session, oldest first, at most
    /// `taskRecordMemory` (F25). The main session can stop a task its subagent started.
    @ObservationIgnored private var stoppedTasks: [String: [String]] = [:]
    /// Path hashes edited in each session's current turn, its subagents' included (D39). Never paths.
    @ObservationIgnored private var turnEdits: [String: Set<Int>] = [:]
    /// Sessions whose 200k model went past 200k tokens: they run with the 1M window (`[1m]`, D38).
    @ObservationIgnored private var extendedContext: Set<String> = []
    /// The first list per provider only seeds the store: launching the app must not pop the notch open.
    @ObservationIgnored private var listedProviders: Set<AgentProvider> = []
    @ObservationIgnored private var hasListedAll = false

    public init(
        testedVersion: String = SessionStore.defaultTestedVersion,
        lingerDuration: TimeInterval = 600,
        backgroundFreshness: TimeInterval = 24 * 3600,
        attentionInterval: TimeInterval = 5
    ) {
        self.testedVersion = testedVersion
        self.lingerDuration = lingerDuration
        self.backgroundFreshness = backgroundFreshness
        self.attentionInterval = attentionInterval
    }

    public func session(id: String) -> Session? { byId[id] }

    /// Replace the live list (optionally scoped to one provider so Claude and Antigravity refreshes
    /// never clobber each other). Sessions that vanished become Done; probe results, titles,
    /// branches and activity of surviving sessions are kept.
    public func replaceList(_ listed: [ListedSession], provider: AgentProvider? = nil, now: Date) {
        let alreadyListed: Bool = if let provider {
            listedProviders.contains(provider) || hasListedAll
        } else {
            hasListedAll || !listedProviders.isEmpty
        }
        var seen = Set<String>()
        for entry in listed {
            if entry.kind == .background {
                guard let mtime = entry.transcriptModifiedAt, now.timeIntervalSince(mtime) < backgroundFreshness else { continue }
            }
            seen.insert(entry.sessionId)
            let status = Status.from(entry)
            if var existing = byId[entry.sessionId] {
                existing.provider = entry.provider
                // D43: a new process for the session brings its own start time, and its source and
                // tty are probed again. A row's pid and startedAt always come from one entry.
                if let pid = entry.pid, pid != existing.pid {
                    existing.pid = pid
                    existing.startedAt = entry.startedAt
                    if let hint = entry.sourceHint {
                        existing.source = hint
                        existing.tty = entry.tty
                    } else if existing.source != .background {
                        existing.source = .unknown
                        existing.tty = nil
                    }
                } else if let hint = entry.sourceHint,
                          existing.source == .unknown || (entry.provider == .antigravity && hint != .unknown)
                {
                    existing.source = hint
                    if let tty = entry.tty { existing.tty = tty }
                }
                existing.cwd = entry.cwd.isEmpty ? existing.cwd : entry.cwd
                existing.name = entry.name
                existing.kind = entry.kind
                if let aiTitle = entry.aiTitle { existing.aiTitle = aiTitle }
                if let branch = entry.branch, entry.provider == .antigravity || existing.branch == nil {
                    existing.branch = branch
                }
                existing.claudeVersion = entry.version ?? existing.claudeVersion
                existing.waitingFor = status == .waiting ? entry.waitingFor : nil
                existing.needs = status == .waiting ? entry.needs : nil
                if existing.status == .done, status != .done { existing.endedAt = nil }
                transition(&existing, to: status, now: now)
                if status == .done, let endedAt = entry.endedAt, existing.endedAt == nil {
                    existing.endedAt = endedAt
                }
                byId[entry.sessionId] = existing
            } else {
                let initialSource = entry.sourceHint ?? (entry.kind == .background ? .background : .unknown)
                let changedAt = (status == .done ? entry.endedAt : nil) ?? now
                var fresh = Session(
                    id: entry.sessionId, provider: entry.provider, pid: entry.pid, cwd: entry.cwd,
                    branch: entry.branch, name: entry.name, aiTitle: entry.aiTitle, kind: entry.kind,
                    source: initialSource, status: status, statusChangedAt: changedAt,
                    startedAt: entry.startedAt, endedAt: status == .done ? (entry.endedAt ?? now) : nil,
                    claudeVersion: entry.version, tty: entry.tty
                )
                if status == .waiting { fresh.waitingFor = entry.waitingFor; fresh.needs = entry.needs }
                if status.isActive { startTurn(&fresh, now: now) }
                byId[entry.sessionId] = fresh
                if alreadyListed, status == .working { fireAttention(fresh, .started, now: now) }
                if alreadyListed, status == .waiting { fireAttention(fresh, .needsYou, now: now) }
            }
        }
        for (id, var session) in byId
        where !seen.contains(id) && session.status != .done && (provider == nil || session.provider == provider) {
            transition(&session, to: .done, now: now)
            byId[id] = session
        }
        if let provider {
            listedProviders.insert(provider)
        } else {
            hasListedAll = true
        }
        tick(now: now)
    }

    /// Source and tty from `ProcessProbe`, for one session.
    public func setProbe(id: String, source: Source, tty: String?) {
        guard var s = byId[id] else { return }
        s.source = source
        s.tty = tty
        byId[id] = s
        publish()
    }

    /// The IDE window a session was last seen in under a trusted host (D43).
    public func setIDEWindow(id: String, _ window: IDEWindow) {
        guard var s = byId[id], s.ideWindow != window else { return }
        s.ideWindow = window
        byId[id] = s
        publish()
    }

    /// Derived transcript fields (M3), field by field; see `updateTranscript(id:update:now:)`.
    public func updateTranscript(
        id: String, aiTitle: String?, branch: String?, activity: Activity?, phase: Phase? = nil,
        model: String? = nil, effort: String? = nil, contextTokens: Int? = nil, editedPathHashes: [Int] = [],
        unavailable: Bool = false, backgroundStarts: [BackgroundStart] = [], closedToolUseIds: [String] = [],
        erroredToolUseIds: [String] = [], now: Date = Date()
    ) {
        updateTranscript(id: id, update: TranscriptUpdate(
            aiTitle: aiTitle, branch: branch, activity: activity, phase: phase, model: model, effort: effort,
            contextTokens: contextTokens, editedPathHashes: editedPathHashes, backgroundStarts: backgroundStarts,
            closedToolUseIds: closedToolUseIds, erroredToolUseIds: erroredToolUseIds, unavailable: unavailable
        ), now: now)
    }

    /// Apply one tail read (M3). Nil leaves a field untouched, so a tool_result line cannot blank the
    /// activity. Background-task records belong to the main session (D41).
    public func updateTranscript(id: String, update: TranscriptUpdate, now: Date = Date()) {
        guard var s = byId[id] else { return }
        applyTaskRecords(&s, owner: nil, update, now: now)
        if let aiTitle = update.aiTitle { s.aiTitle = aiTitle }
        if let branch = update.branch { s.branch = branch }
        if let activity = update.activity { s.activity = activity }
        if let phase = update.phase { s.phase = phase }
        if let model = update.model { s.model = model }
        if let effort = update.effort { s.effort = effort }
        if let contextTokens = update.contextTokens { s.contextTokens = contextTokens }
        s.contextWindow = resolveContextWindow(id: id, model: s.model, tokens: s.contextTokens)
        if !update.editedPathHashes.isEmpty { turnEdits[id, default: []].formUnion(update.editedPathHashes) }
        s.activityUnavailable = update.unavailable
        byId[id] = s
        publish()
    }

    /// Merge one subagent read (D33). Folded-away finished subagents stay away; their background
    /// tasks still close. A subagent that finishes after its parent's turn ended goes at once (D41).
    public func updateSubagent(sessionId: String, update: SubagentUpdate, now: Date) {
        guard let before = byId[sessionId] else { return }
        var s = before
        if let read = update.transcript { applyTaskRecords(&s, owner: update.agentId, read, now: now) }
        if update.finished, s.status == .idle {
            s.subagents.removeAll { $0.id == update.agentId }
            dismissedSubagents[sessionId, default: []].insert(update.agentId)
        }
        if s.status == .done || (dismissedSubagents[sessionId]?.contains(update.agentId) ?? false) {
            if s != before { byId[sessionId] = s; publish() }
            return
        }
        var agent = s.subagents.first { $0.id == update.agentId } ?? Subagent(
            id: update.agentId, agentType: update.agentType, description: update.description,
            startedAt: update.startedAt ?? now, lastWriteAt: update.lastWriteAt ?? now
        )
        agent.agentType = update.agentType
        agent.description = update.description
        agent.toolUseId = update.toolUseId ?? agent.toolUseId
        agent.parentId = update.parentId ?? agent.parentId
        agent.spawnDepth = update.spawnDepth
        if let at = update.lastWriteAt { agent.lastWriteAt = max(agent.lastWriteAt, at) }
        if let read = update.transcript {
            if let phase = read.phase { agent.phase = phase }
            if let activity = read.activity { agent.activity = activity }
            if let model = read.model { agent.model = model }
            if let effort = read.effort { agent.effort = effort }
            agent.spawnedToolUseIds.formUnion(read.spawnedToolUseIds)
            if !read.editedPathHashes.isEmpty { turnEdits[sessionId, default: []].formUnion(read.editedPathHashes) }   // the parent's turn (D39)
        }
        if update.finished, !agent.finished { agent.finished = true; agent.finishedAt = now }
        if let i = s.subagents.firstIndex(where: { $0.id == agent.id }) { s.subagents[i] = agent } else { s.subagents.append(agent) }
        byId[sessionId] = s
        publish()
    }

    /// Ids of subagents the store no longer shows, so the monitor can drop their tails.
    public func dismissedSubagentIds(sessionId: String) -> Set<String> { dismissedSubagents[sessionId] ?? [] }

    /// Drop unfinished subagents whose transcript went quiet (see `subagentStale`). Background tasks
    /// have no time-based drop (D41).
    public func dropStaleSubagents(now: Date) {
        var changed = false
        for (id, var s) in byId where !s.subagents.isEmpty {
            let kept = s.subagents.filter { $0.finished || now.timeIntervalSince($0.lastWriteAt) < Self.subagentStale }
            guard kept.count != s.subagents.count else { continue }
            dismissedSubagents[id, default: []].formUnion(Set(s.subagents.map(\.id)).subtracting(kept.map(\.id)))
            s.subagents = kept
            byId[id] = s
            changed = true
        }
        if changed { publish() }
    }

    /// The 5 s liveness sweep: a dead pid turns the row Done even if its registry file lingers.
    public func checkLiveness(now: Date, isAlive: (Int32) -> Bool) {
        for (id, var session) in byId where session.status != .done {
            guard let pid = session.pid, !isAlive(pid) else { continue }
            transition(&session, to: .done, now: now)
            byId[id] = session
        }
        tick(now: now)
    }

    /// Drop Done rows older than `lingerDuration`, then re-sort and re-derive.
    public func tick(now: Date) {
        for (id, session) in byId {
            if let endedAt = session.endedAt, now.timeIntervalSince(endedAt) >= lingerDuration {
                byId[id] = nil
                dismissedSubagents[id] = nil
                closedTasks[id] = nil
                stoppedTasks[id] = nil
                turnEdits[id] = nil
                extendedContext.remove(id)
                lastAttentionAt = lastAttentionAt.filter { !$0.key.hasPrefix("\(id)|") }
            }
        }
        publish()
    }

    private func transition(_ session: inout Session, to status: Status, now: Date) {
        let previous = session.status
        guard previous != status else { return }
        session.status = status
        session.statusChangedAt = now
        if status == .done { session.endedAt = now; session.backgroundTasks.removeAll() }
        if status != .waiting { session.waitingFor = nil; session.needs = nil }
        if status.isActive, !previous.isActive { startTurn(&session, now: now) }
        if previous == .working, status == .idle || status == .done {
            session.turnFinishedAt = status == .idle ? now : nil
            session.turnFileCount = turnEdits[session.id]?.count ?? 0
            // Q22: finished subagents fold away with the turn; a killed session drops them all.
            let gone = session.subagents.filter { status == .done || $0.finished }
            dismissedSubagents[session.id, default: []].formUnion(gone.map(\.id))
            session.subagents.removeAll { status == .done || $0.finished }
        }
        if status == .working { session.turnFinishedAt = nil }
        switch status {
        case .working where previous != .waiting: fireAttention(session, .started, now: now)   // not after answering it
        case .waiting: fireAttention(session, .needsYou, now: now)
        case .idle where previous == .working: fireAttention(session, .finished, now: now)
        default: break
        }
    }

    /// Starts first, then acknowledgements and stops, then closes and launch errors, so a start and
    /// its end in one read cancel out. A close is remembered for a start read later, and a stop for an
    /// acknowledgement read later; a launch error sits after its start in the same file, so it only
    /// removes an open task. A Done session takes no new tasks (D41, F25).
    private func applyTaskRecords(_ s: inout Session, owner: String?, _ read: TranscriptUpdate, now: Date) {
        guard !read.backgroundStarts.isEmpty || !read.closedToolUseIds.isEmpty || !read.erroredToolUseIds.isEmpty
            || !read.backgroundAcks.isEmpty || !read.stoppedTaskIds.isEmpty else { return }
        if s.status != .done {
            let remembered = closedTasks[s.id] ?? []
            for start in read.backgroundStarts
            where !remembered.contains(start.toolUseId) && !s.backgroundTasks.contains(where: { $0.id == start.toolUseId }) {
                s.backgroundTasks.append(BackgroundTask(
                    id: start.toolUseId, ownerAgentId: owner, activity: start.activity, startedAt: start.startedAt ?? now
                ))
            }
        }
        // TaskStop names the acknowledgement's task id, and no notification follows it (F25).
        var closed = read.closedToolUseIds
        let pendingStops = stoppedTasks[s.id] ?? []
        for ack in read.backgroundAcks {
            if let i = s.backgroundTasks.firstIndex(where: { $0.id == ack.toolUseId }) { s.backgroundTasks[i].taskId = ack.taskId }
            if pendingStops.contains(ack.taskId) { closed.append(ack.toolUseId) }
        }
        var unmatchedStops: [String] = []
        for taskId in read.stoppedTaskIds {
            if let task = s.backgroundTasks.first(where: { $0.taskId == taskId }) { closed.append(task.id) } else { unmatchedStops.append(taskId) }
        }
        Self.remember(unmatchedStops, in: &stoppedTasks[s.id])
        Self.remember(closed, in: &closedTasks[s.id])
        let ended = Set(closed).union(read.erroredToolUseIds)
        s.backgroundTasks.removeAll { ended.contains($0.id) }
    }

    /// Appends the ids not yet in `memory`, keeping the newest `taskRecordMemory`.
    private static func remember(_ ids: [String], in memory: inout [String]?) {
        guard !ids.isEmpty else { return }
        var list = memory ?? []
        for id in ids where !list.contains(id) { list.append(id) }
        if list.count > taskRecordMemory { list.removeFirst(list.count - taskRecordMemory) }
        memory = list
    }

    /// A turn starts when a session goes from idle (or unseen) to working or waiting; answering a
    /// prompt (waiting → working) continues it. The last turn's finish goes with it (D39).
    private func startTurn(_ session: inout Session, now: Date) {
        session.turnStartedAt = now
        session.turnFinishedAt = nil
        session.turnFileCount = 0
        turnEdits[session.id] = nil
    }

    /// The model's window, or 1M once a 200k model has gone past 200k tokens in this session (D38).
    /// Records that switch, so it outlives compaction.
    private func resolveContextWindow(id: String, model: String?, tokens: Int?) -> Int? {
        guard let window = ContextWindow.window(forModel: model) else { return nil }
        guard window == ContextWindow.standard else { return window }
        if let tokens, tokens > window { extendedContext.insert(id) }
        return extendedContext.contains(id) ? ContextWindow.oneMillion : window
    }

    /// At most one event per session and kind per `attentionInterval`.
    private func fireAttention(_ session: Session, _ kind: AttentionKind, now: Date) {
        let key = "\(session.id)|\(kind)"
        if let last = lastAttentionAt[key], now.timeIntervalSince(last) < attentionInterval { return }
        lastAttentionAt[key] = now
        attentionLog.append(AttentionEvent(session: session, kind: kind))
        if attentionLog.count > Self.attentionLogLimit { attentionLog.removeFirst(attentionLog.count - Self.attentionLogLimit) }
        onAttention?(session, kind)
    }

    private func publish() {
        sessions = byId.values.sorted {
            if $0.status != $1.status { return $0.status < $1.status }
            if $0.statusChangedAt != $1.statusChangedAt { return $0.statusChangedAt > $1.statusChangedAt }
            return $0.id < $1.id
        }
        let others = Set(byId.values.filter { $0.provider == .claude }.compactMap(\.claudeVersion)).subtracting([testedVersion]).sorted()
        versionNote = others.isEmpty ? nil : "Tested with Claude Code \(testedVersion) · running \(others.joined(separator: ", "))"
    }
}
