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
    /// was killed without the meta file saying so. Shorter once the parent has stopped working.
    public static let subagentStaleWhileWorking: TimeInterval = 1800
    public static let subagentStaleWhileIdle: TimeInterval = 180

    public var workingCount: Int { sessions.filter { $0.status == .working }.count }
    public var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }

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
    /// The first list only seeds the store: launching the app must not pop the notch open.
    @ObservationIgnored private var hasListed = false

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

    /// Replace the live list. Sessions that vanished become Done; probe results, titles,
    /// branches and activity of surviving sessions are kept.
    public func replaceList(_ listed: [ListedSession], now: Date) {
        var seen = Set<String>()
        for entry in listed {
            if entry.kind == .background {
                guard let mtime = entry.transcriptModifiedAt, now.timeIntervalSince(mtime) < backgroundFreshness else { continue }
            }
            seen.insert(entry.sessionId)
            let status = Status.from(entry)
            if var existing = byId[entry.sessionId] {
                existing.pid = entry.pid ?? existing.pid
                existing.cwd = entry.cwd.isEmpty ? existing.cwd : entry.cwd
                existing.name = entry.name
                existing.kind = entry.kind
                existing.claudeVersion = entry.version ?? existing.claudeVersion
                existing.waitingFor = status == .waiting ? entry.waitingFor : nil
                existing.needs = status == .waiting ? entry.needs : nil
                if existing.status == .done, status != .done { existing.endedAt = nil }
                transition(&existing, to: status, now: now)
                byId[entry.sessionId] = existing
            } else {
                var fresh = Session(
                    id: entry.sessionId, pid: entry.pid, cwd: entry.cwd, name: entry.name, kind: entry.kind,
                    source: entry.kind == .background ? .background : .unknown,
                    status: status, statusChangedAt: now, startedAt: entry.startedAt, claudeVersion: entry.version
                )
                if status == .done { fresh.endedAt = now }
                if status == .waiting { fresh.waitingFor = entry.waitingFor; fresh.needs = entry.needs }
                byId[entry.sessionId] = fresh
                if hasListed, status == .working { fireAttention(fresh, .started, now: now) }
                if hasListed, status == .waiting { fireAttention(fresh, .needsYou, now: now) }
            }
        }
        for (id, var session) in byId where !seen.contains(id) && session.status != .done {
            transition(&session, to: .done, now: now)
            byId[id] = session
        }
        hasListed = true
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

    /// Derived transcript fields (M3). Nil leaves a field untouched, so a tool_result line
    /// cannot blank the activity.
    public func updateTranscript(
        id: String, aiTitle: String?, branch: String?, activity: Activity?, phase: Phase? = nil,
        model: String? = nil, effort: String? = nil, unavailable: Bool = false
    ) {
        guard var s = byId[id] else { return }
        if let aiTitle { s.aiTitle = aiTitle }
        if let branch { s.branch = branch }
        if let activity { s.activity = activity }
        if let phase { s.phase = phase }
        if let model { s.model = model }
        if let effort { s.effort = effort }
        s.activityUnavailable = unavailable
        byId[id] = s
        publish()
    }

    /// Convenience for the monitor: apply one tail read.
    public func updateTranscript(id: String, update: TranscriptUpdate) {
        updateTranscript(id: id, aiTitle: update.aiTitle, branch: update.branch, activity: update.activity, phase: update.phase,
                         model: update.model, effort: update.effort, unavailable: update.unavailable)
    }

    /// Merge one subagent read (D33). Folded-away finished subagents stay away.
    public func updateSubagent(sessionId: String, update: SubagentUpdate, now: Date) {
        guard var s = byId[sessionId], s.status != .done,
              !(dismissedSubagents[sessionId]?.contains(update.agentId) ?? false) else { return }
        var agent = s.subagents.first { $0.id == update.agentId } ?? Subagent(
            id: update.agentId, agentType: update.agentType, description: update.description,
            startedAt: update.startedAt ?? now, lastWriteAt: update.lastWriteAt ?? now
        )
        agent.agentType = update.agentType
        agent.description = update.description
        agent.toolUseId = update.toolUseId ?? agent.toolUseId
        agent.spawnDepth = update.spawnDepth
        if let at = update.lastWriteAt { agent.lastWriteAt = max(agent.lastWriteAt, at) }
        if let read = update.transcript {
            if let phase = read.phase { agent.phase = phase }
            if let activity = read.activity { agent.activity = activity }
            if let model = read.model { agent.model = model }
            if let effort = read.effort { agent.effort = effort }
            agent.spawnedToolUseIds.formUnion(read.spawnedToolUseIds)
        }
        if update.finished, !agent.finished { agent.finished = true; agent.finishedAt = now }
        if let i = s.subagents.firstIndex(where: { $0.id == agent.id }) { s.subagents[i] = agent } else { s.subagents.append(agent) }
        byId[sessionId] = s
        publish()
    }

    /// Ids of subagents the store no longer shows, so the monitor can drop their tails.
    public func dismissedSubagentIds(sessionId: String) -> Set<String> { dismissedSubagents[sessionId] ?? [] }

    /// Drop unfinished subagents whose transcript went quiet (see `subagentStale*`).
    public func dropStaleSubagents(now: Date) {
        var changed = false
        for (id, var s) in byId where !s.subagents.isEmpty {
            let limit = s.status == .working ? Self.subagentStaleWhileWorking : Self.subagentStaleWhileIdle
            let kept = s.subagents.filter { $0.finished || now.timeIntervalSince($0.lastWriteAt) < limit }
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
        if status == .done { session.endedAt = now }
        if status != .waiting { session.waitingFor = nil; session.needs = nil }
        if previous == .working, status == .idle || status == .done {
            session.turnFinishedAt = status == .idle ? now : nil
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
        let others = Set(byId.values.compactMap(\.claudeVersion)).subtracting([testedVersion]).sorted()
        versionNote = others.isEmpty ? nil : "Tested with Claude Code \(testedVersion) · running \(others.joined(separator: ", "))"
    }
}
