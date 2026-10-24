import Foundation

/// One entry of the session list, before it is merged into the store.
/// Produced by `AgentsCommand` (primary, D23) or `RegistryReader` (fallback).
public struct ListedSession: Sendable, Equatable {
    public var sessionId: String
    public var pid: Int32?
    public var cwd: String
    public var kind: SessionKind
    public var name: String
    public var startedAt: Date
    /// Interactive sessions: `busy`, `idle`, `waiting` (F1).
    public var status: String?
    /// Background sessions: `blocked`, `done`, `stopped`, … (F1, V5).
    public var state: String?
    public var waitingFor: String?
    /// Only the registry carries the Claude Code version (F2).
    public var version: String?
    /// Filled by the monitor from the transcript's mtime; drives the 24 h rule for background sessions.
    public var transcriptModifiedAt: Date?

    public init(
        sessionId: String, pid: Int32? = nil, cwd: String, kind: SessionKind, name: String,
        startedAt: Date, status: String? = nil, state: String? = nil, waitingFor: String? = nil,
        version: String? = nil, transcriptModifiedAt: Date? = nil
    ) {
        self.sessionId = sessionId; self.pid = pid; self.cwd = cwd; self.kind = kind; self.name = name
        self.startedAt = startedAt; self.status = status; self.state = state; self.waitingFor = waitingFor
        self.version = version; self.transcriptModifiedAt = transcriptModifiedAt
    }
}

extension ListedSession {
    /// Shared decoder for one entry of `claude agents --json` (F1) or one registry file (F2).
    /// Entries without a `sessionId` are dropped; every other field degrades (R8).
    init?(json dict: [String: Any], now: Date) {
        guard let sessionId = JSONField.string(dict, "sessionId"), !sessionId.isEmpty else { return nil }
        let pid = JSONField.int32(dict, "pid")
        self.init(
            sessionId: sessionId,
            pid: pid,
            cwd: JSONField.string(dict, "cwd") ?? "",
            kind: JSONField.kind(dict, hasPid: pid != nil),
            name: JSONField.string(dict, "name") ?? String(sessionId.prefix(8)),
            startedAt: JSONField.date(dict, "startedAt", fallback: now),
            status: JSONField.string(dict, "status"),
            state: JSONField.string(dict, "state"),
            waitingFor: JSONField.waitingFor(dict),
            version: JSONField.string(dict, "version")
        )
    }

    /// The "Status mapping" table. Unknown values degrade to `idle` (R8).
    var mappedStatus: Status {
        if waitingFor != nil { return .waiting }
        switch kind {
        case .interactive:
            switch status?.lowercased() {
            case "busy", "running", "working": return .working
            case "waiting", "blocked": return .waiting
            default: return .idle
            }
        case .background:
            switch (state ?? status)?.lowercased() {
            case "blocked", "waiting": return .waiting
            case "running", "busy", "working": return .working
            case "done", "stopped", "exited", "failed", "killed", "completed": return .done
            default: return .idle
            }
        }
    }
}

/// Tolerant field readers shared by the two list sources. Internal formats drift (F2, F6), so
/// every field is optional and a bad value degrades to a default instead of failing (R8).
enum JSONField {
    static func string(_ dict: [String: Any], _ key: String) -> String? {
        if let s = dict[key] as? String { return s }
        if let n = dict[key] as? NSNumber { return n.stringValue }
        return nil
    }

    static func int32(_ dict: [String: Any], _ key: String) -> Int32? {
        if let n = dict[key] as? NSNumber, n.intValue > 0, n.intValue <= Int(Int32.max) { return Int32(n.intValue) }
        if let s = dict[key] as? String, let v = Int32(s), v > 0 { return v }
        return nil
    }

    /// Epoch milliseconds (F15), epoch seconds, or ISO-8601. Anything else, including values
    /// outside 1973…5138 or non-finite numbers, → `fallback` (R8: no traps on bad input).
    static func date(_ dict: [String: Any], _ key: String, fallback: Date) -> Date {
        if let n = dict[key] as? NSNumber, let d = epoch(n.doubleValue) { return d }
        if let s = dict[key] as? String {
            if let d = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s))
                ?? (try? Date.ISO8601FormatStyle().parse(s)) { return d }
            if let v = Double(s), let d = epoch(v) { return d }
        }
        return fallback
    }

    private static func epoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 1e11 ? value / 1000 : value
        guard seconds > 1e8, seconds < 1e11 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// `waitingFor` is documented but its shape is unobserved (F1): any non-null value counts.
    static func waitingFor(_ dict: [String: Any]) -> String? {
        guard let value = dict["waitingFor"], !(value is NSNull) else { return nil }
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let n = value as? NSNumber { return n.stringValue }
        return "pending"
    }

    static func kind(_ dict: [String: Any], hasPid: Bool) -> SessionKind {
        switch (dict["kind"] as? String)?.lowercased() {
        case "interactive": return .interactive
        case "background", "bg": return .background
        default: return hasPid ? .interactive : .background
        }
    }

}
