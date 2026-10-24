import Foundation
import Observation

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
    @ObservationIgnored public var onAttention: ((Session) -> Void)?
    /// The most recent attention events (at most `attentionLogLimit`); tests read it, the UI ignores it.
    @ObservationIgnored public private(set) var attentionLog: [Session] = []
    public static let attentionLogLimit = 50

    public var workingCount: Int { sessions.filter { $0.status == .working }.count }
    public var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }

    private let testedVersion: String
    private let lingerDuration: TimeInterval
    private let backgroundFreshness: TimeInterval
    private let attentionInterval: TimeInterval
    @ObservationIgnored private var byId: [String: Session] = [:]
    @ObservationIgnored private var lastAttentionAt: [String: Date] = [:]

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
                byId[entry.sessionId] = fresh
            }
        }
        for (id, var session) in byId where !seen.contains(id) && session.status != .done {
            transition(&session, to: .done, now: now)
            byId[id] = session
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

    /// Derived transcript fields (M3). Nil leaves a field untouched, so a tool_result line
    /// cannot blank the activity.
    public func updateTranscript(id: String, aiTitle: String?, branch: String?, activity: Activity?, unavailable: Bool = false) {
        guard var s = byId[id] else { return }
        if let aiTitle { s.aiTitle = aiTitle }
        if let branch { s.branch = branch }
        if let activity { s.activity = activity }
        s.activityUnavailable = unavailable
        byId[id] = s
        publish()
    }

    /// Convenience for the monitor: apply one tail read.
    public func updateTranscript(id: String, update: TranscriptUpdate) {
        updateTranscript(id: id, aiTitle: update.aiTitle, branch: update.branch, activity: update.activity, unavailable: update.unavailable)
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
            if let endedAt = session.endedAt, now.timeIntervalSince(endedAt) >= lingerDuration { byId[id] = nil }
        }
        publish()
    }

    private func transition(_ session: inout Session, to status: Status, now: Date) {
        let previous = session.status
        guard previous != status else { return }
        session.status = status
        session.statusChangedAt = now
        if status == .done { session.endedAt = now }
        let finishedTurn = previous == .working && status == .idle
        if status == .waiting || finishedTurn { fireAttention(session, now: now) }
    }

    private func fireAttention(_ session: Session, now: Date) {
        if let last = lastAttentionAt[session.id], now.timeIntervalSince(last) < attentionInterval { return }
        lastAttentionAt[session.id] = now
        attentionLog.append(session)
        if attentionLog.count > Self.attentionLogLimit { attentionLog.removeFirst(attentionLog.count - Self.attentionLogLimit) }
        onAttention?(session)
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
