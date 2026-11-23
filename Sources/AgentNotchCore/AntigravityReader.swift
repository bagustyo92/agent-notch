import Foundation
import SQLite3

/// One Antigravity local app-data directory (`~/.gemini/<name>`).
public struct AntigravitySurface: Sendable, Equatable {
    public var name: String
    public var directory: URL

    public init(name: String, directory: URL) {
        self.name = name
        self.directory = directory
    }

    public var databaseURL: URL { directory.appendingPathComponent("conversation_summaries.db") }

    public func transcriptURL(for conversationId: String) -> URL {
        directory
            .appendingPathComponent("brain", isDirectory: true)
            .appendingPathComponent(conversationId, isDirectory: true)
            .appendingPathComponent(".system_generated", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("transcript.jsonl")
    }

    public static let defaultNames = ["antigravity-cli", "antigravity", "antigravity-ide"]

    public static func defaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AntigravitySurface] {
        let gemini = home.appendingPathComponent(".gemini", isDirectory: true)
        return defaultNames.map { AntigravitySurface(name: $0, directory: gemini.appendingPathComponent($0, isDirectory: true)) }
    }
}

/// One child conversation row from `conversation_summaries.db`, attached to a root Antigravity session.
public struct AntigravitySubagent: Sendable, Equatable {
    public var id: String
    public var rootSessionId: String
    public var parentId: String
    public var agentType: String
    public var description: String
    public var spawnDepth: Int
    public var finished: Bool
    public var startedAt: Date
    public var lastWriteAt: Date
    public var transcriptURL: URL

    public init(
        id: String, rootSessionId: String, parentId: String, agentType: String, description: String,
        spawnDepth: Int, finished: Bool, startedAt: Date, lastWriteAt: Date, transcriptURL: URL
    ) {
        self.id = id; self.rootSessionId = rootSessionId; self.parentId = parentId
        self.agentType = agentType; self.description = description; self.spawnDepth = spawnDepth
        self.finished = finished; self.startedAt = startedAt; self.lastWriteAt = lastWriteAt
        self.transcriptURL = transcriptURL
    }
}

/// One read across all configured Antigravity SQLite state databases.
public struct AntigravitySnapshot: Sendable, Equatable {
    public var sessions: [ListedSession]
    public var subagentsByRootId: [String: [AntigravitySubagent]]

    public init(sessions: [ListedSession] = [], subagentsByRootId: [String: [AntigravitySubagent]] = [:]) {
        self.sessions = sessions
        self.subagentsByRootId = subagentsByRootId
    }
}

/// Strictly read-only SQLite reader for Antigravity (`~/.gemini/{antigravity-cli,antigravity,antigravity-ide}`).
///
/// Follows R1–R8:
/// - Opens `conversation_summaries.db` with `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX`
///   (`mode=ro`, falling back to `mode=ro&immutable=1` when a checkpointed WAL DB has no `-shm` on disk)
///   so AgentNotch never creates or writes any file under `~/.gemini/`.
/// - Reads ONLY safe metadata columns; never reads `raw_summary`, `preview`, or `conversations_fts` (R4).
/// - Applies the hybrid live-process + active-status filter, 30-min stale-running guard, and 10-min
///   recently-ended linger window.
public struct AntigravityReader: Sendable {
    public typealias ProcessScanner = @Sendable () -> [String: AntigravityProcessInfo]
    public typealias BranchResolver = @Sendable (String) -> String?

    /// Abandoned `RUNNING`/`WAITING`/`not_fully_idle` rows with no live process are dropped after 30 min.
    public static let defaultStaleRunningWindow: TimeInterval = 1800
    /// Recently modified conversations with no live process stay visible as Done for the standard 10 min linger.
    public static let defaultRecentLingerWindow: TimeInterval = 600

    public let surfaces: [AntigravitySurface]
    private let staleRunningWindow: TimeInterval
    private let recentLingerWindow: TimeInterval
    private let processScanner: ProcessScanner
    private let branchResolver: BranchResolver

    public init(
        surfaces: [AntigravitySurface],
        staleRunningWindow: TimeInterval = AntigravityReader.defaultStaleRunningWindow,
        recentLingerWindow: TimeInterval = AntigravityReader.defaultRecentLingerWindow,
        processScanner: @escaping ProcessScanner = ProcessProbe.antigravityProcesses,
        branchResolver: @escaping BranchResolver = GitBranchReader.branch(forDirectory:)
    ) {
        self.surfaces = surfaces
        self.staleRunningWindow = staleRunningWindow
        self.recentLingerWindow = recentLingerWindow
        self.processScanner = processScanner
        self.branchResolver = branchResolver
    }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(surfaces: AntigravitySurface.defaults(home: home))
    }

    /// Safe metadata columns only (never `raw_summary`, `preview`, or `conversations_fts`, R4).
    private static let selectSQL = """
        SELECT conversation_id, title, status, agent_name, parent_conversation_id,
               nesting_depth, not_fully_idle, killed, last_modified_time,
               last_user_input_time, workspace_uris
        FROM conversation_summaries
        """

    private struct RawRow {
        let conversationId: String
        let title: String
        let status: String
        let agentName: String
        let parentConversationId: String
        let nestingDepth: Int
        let notFullyIdle: Bool
        let killed: Bool
        let lastModifiedTime: Date?
        let lastUserInputTime: Date?
        let workspaceUris: String
        let surface: AntigravitySurface
    }

    public func read(now: Date = Date()) -> AntigravitySnapshot {
        let fm = FileManager.default
        let existingSurfaces = surfaces.filter { fm.fileExists(atPath: $0.databaseURL.path) }
        guard !existingSurfaces.isEmpty else { return AntigravitySnapshot() }

        let liveProcesses = processScanner()
        var rowsById: [String: RawRow] = [:]
        for surface in existingSurfaces {
            for row in queryDatabase(at: surface.databaseURL, surface: surface) {
                if let prev = rowsById[row.conversationId] {
                    let prevTime = prev.lastModifiedTime ?? .distantPast
                    let nextTime = row.lastModifiedTime ?? .distantPast
                    if nextTime < prevTime { continue }
                }
                rowsById[row.conversationId] = row
            }
        }
        guard !rowsById.isEmpty else { return AntigravitySnapshot() }

        var listed: [ListedSession] = []
        var includedTopLevelIds = Set<String>()

        for row in rowsById.values where row.parentConversationId.isEmpty && row.nestingDepth == 0 {
            let proc = liveProcesses[row.conversationId]
            guard let decision = classifyTopLevel(row: row, process: proc, now: now) else { continue }

            let cwd = Self.firstWorkspacePath(from: row.workspaceUris) ?? ""
            let repo = (cwd as NSString).lastPathComponent
            let maskedTitle = ActivitySummary.finish(row.title)
            let aiTitle = maskedTitle.isEmpty ? nil : maskedTitle
            let fallbackName = repo.isEmpty ? String(row.conversationId.prefix(8)) : repo
            let branch = cwd.isEmpty ? nil : branchResolver(cwd)
            let source = proc?.source ?? Source.classifyAntigravity(executablePath: nil, appDataDirName: row.surface.name)
            let startedAt = proc?.startedAt ?? Self.earlierValidDate(row.lastUserInputTime, row.lastModifiedTime) ?? now
            let transcriptURL = row.surface.transcriptURL(for: row.conversationId)

            includedTopLevelIds.insert(row.conversationId)
            listed.append(ListedSession(
                sessionId: row.conversationId,
                pid: proc?.pid,
                cwd: cwd,
                kind: .interactive,
                name: aiTitle ?? fallbackName,
                startedAt: startedAt,
                status: decision.status,
                waitingFor: decision.waitingFor,
                provider: .antigravity,
                sourceHint: source,
                tty: proc?.tty,
                transcriptURL: transcriptURL,
                branch: branch,
                aiTitle: aiTitle,
                endedAt: decision.endedAt
            ))
        }

        var subagentsByRoot: [String: [AntigravitySubagent]] = [:]
        for row in rowsById.values where !row.parentConversationId.isEmpty || row.nestingDepth > 0 {
            guard let rootId = Self.rootAncestor(of: row, in: rowsById),
                  includedTopLevelIds.contains(rootId) else { continue }
            let proc = liveProcesses[row.conversationId]
            let active = isActiveSubagent(row: row, process: proc, now: now)
            let lastWrite = row.lastModifiedTime ?? row.lastUserInputTime ?? now
            let startedAt = Self.earlierValidDate(row.lastUserInputTime, row.lastModifiedTime) ?? lastWrite
            let rawType = row.agentName.trimmingCharacters(in: .whitespacesAndNewlines)
            let agentType = rawType.isEmpty ? "Subagent" : ActivitySummary.finish(rawType)
            let description = ActivitySummary.finish(row.title)
            let subagent = AntigravitySubagent(
                id: row.conversationId,
                rootSessionId: rootId,
                parentId: row.parentConversationId,
                agentType: agentType,
                description: description,
                spawnDepth: max(1, row.nestingDepth),
                finished: !active,
                startedAt: startedAt,
                lastWriteAt: lastWrite,
                transcriptURL: row.surface.transcriptURL(for: row.conversationId)
            )
            subagentsByRoot[rootId, default: []].append(subagent)
        }

        return AntigravitySnapshot(sessions: listed, subagentsByRootId: subagentsByRoot)
    }

    // MARK: - Classification

    private struct TopLevelDecision {
        let status: String
        let waitingFor: String?
        let endedAt: Date?
    }

    private func classifyTopLevel(row: RawRow, process: AntigravityProcessInfo?, now: Date) -> TopLevelDecision? {
        let upper = row.status.uppercased()
        let isRunning = upper == "CASCADE_RUN_STATUS_RUNNING"
        let isWaiting = upper.hasPrefix("CASCADE_RUN_STATUS_WAITING")
        let isActiveFlag = isRunning || isWaiting || row.notFullyIdle
        let hasLiveProcess = process != nil
        let age = row.lastModifiedTime.map { now.timeIntervalSince($0) }

        if row.killed && !hasLiveProcess {
            return nil
        }

        // Guard stale abandoned RUNNING/WAITING rows with no backing process after 30 minutes of quiet.
        if !hasLiveProcess, isActiveFlag {
            guard let age, age < staleRunningWindow else { return nil }
            let waitingFor = isWaiting ? Self.waitingLabel(for: upper) : nil
            return TopLevelDecision(status: isWaiting ? "waiting" : "busy", waitingFor: waitingFor, endedAt: nil)
        }

        if hasLiveProcess {
            if !row.killed && isWaiting {
                return TopLevelDecision(status: "waiting", waitingFor: Self.waitingLabel(for: upper), endedAt: nil)
            }
            if !row.killed && (isRunning || row.notFullyIdle) {
                return TopLevelDecision(status: "busy", waitingFor: nil, endedAt: nil)
            }
            return TopLevelDecision(status: "idle", waitingFor: nil, endedAt: nil)
        }

        // No live process and not active: show recently ended conversations for the 10-minute linger window.
        if let lastModified = row.lastModifiedTime, let age, age >= -60, age < recentLingerWindow {
            return TopLevelDecision(status: "done", waitingFor: nil, endedAt: lastModified)
        }
        return nil
    }

    private func isActiveSubagent(row: RawRow, process: AntigravityProcessInfo?, now: Date) -> Bool {
        if row.killed { return false }
        let upper = row.status.uppercased()
        let isActiveFlag = upper == "CASCADE_RUN_STATUS_RUNNING"
            || upper.hasPrefix("CASCADE_RUN_STATUS_WAITING")
            || row.notFullyIdle
        guard isActiveFlag else { return false }
        if process != nil { return true }
        guard let lastModified = row.lastModifiedTime else { return false }
        return now.timeIntervalSince(lastModified) < staleRunningWindow
    }

    private static func waitingLabel(for upperStatus: String) -> String? {
        upperStatus.contains("USER") ? "input needed" : nil
    }

    private static func rootAncestor(of row: RawRow, in rows: [String: RawRow]) -> String? {
        var current = row.parentConversationId
        var seen: Set<String> = [row.conversationId]
        for _ in 0..<16 {
            guard !current.isEmpty, seen.insert(current).inserted else { return nil }
            guard let parent = rows[current] else { return current }
            if parent.parentConversationId.isEmpty && parent.nestingDepth == 0 { return parent.conversationId }
            current = parent.parentConversationId
        }
        return nil
    }

    private static func earlierValidDate(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case (let x?, let y?): min(x, y)
        case (let x?, nil): x
        case (nil, let y?): y
        case (nil, nil): nil
        }
    }

    // MARK: - SQLite Read-Only Query

    private func queryDatabase(at url: URL, surface: AntigravitySurface) -> [RawRow] {
        // R1: never create -shm or -wal files under ~/.gemini/. Only use live WAL mode (`mode=ro`)
        // when -shm or -wal already exists on disk; otherwise open directly with `immutable=1`.
        let fm = FileManager.default
        let hasWALSidecar = fm.fileExists(atPath: url.path + "-shm") || fm.fileExists(atPath: url.path + "-wal")
        if hasWALSidecar, let rows = runQuery(uri: Self.sqliteURI(for: url, immutable: false), surface: surface) {
            return rows
        }
        return runQuery(uri: Self.sqliteURI(for: url, immutable: true), surface: surface) ?? []
    }

    private func runQuery(uri: String, surface: AntigravitySurface) -> [RawRow]? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.selectSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [RawRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { return nil }
            let id = Self.columnText(stmt, 0)
            guard !id.isEmpty else { continue }
            rows.append(RawRow(
                conversationId: id,
                title: Self.columnText(stmt, 1),
                status: Self.columnText(stmt, 2),
                agentName: Self.columnText(stmt, 3),
                parentConversationId: Self.columnText(stmt, 4),
                nestingDepth: Int(sqlite3_column_int64(stmt, 5)),
                notFullyIdle: Self.columnBool(stmt, 6),
                killed: Self.columnBool(stmt, 7),
                lastModifiedTime: Self.parseTimestamp(Self.columnText(stmt, 8)),
                lastUserInputTime: Self.parseTimestamp(Self.columnText(stmt, 9)),
                workspaceUris: Self.columnText(stmt, 10),
                surface: surface
            ))
        }
        return rows
    }

    static func sqliteURI(for url: URL, immutable: Bool) -> String {
        let base = url.standardizedFileURL.absoluteString
        return immutable ? "\(base)?mode=ro&immutable=1" : "\(base)?mode=ro"
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, index) else { return "" }
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: count), as: UTF8.self)
    }

    private static func columnBool(_ stmt: OpaquePointer, _ index: Int32) -> Bool {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_INTEGER:
            return sqlite3_column_int64(stmt, index) != 0
        case SQLITE_FLOAT:
            return sqlite3_column_double(stmt, index) != 0
        case SQLITE_TEXT:
            let s = columnText(stmt, index).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return s == "1" || s == "true"
        default:
            return false
        }
    }

    // MARK: - Field Parsers

    /// Extracts the first `file://` path from `workspace_uris` (a JSON array of URI strings).
    static func firstWorkspacePath(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        for item in array {
            guard let uriString = item as? String, !uriString.isEmpty else { continue }
            if let url = URL(string: uriString), url.isFileURL, !url.path.isEmpty {
                return url.path
            }
            if uriString.hasPrefix("file://") {
                let rawPath = String(uriString.dropFirst("file://".count))
                let decoded = rawPath.removingPercentEncoding ?? rawPath
                if !decoded.isEmpty { return decoded }
            }
        }
        return nil
    }

    /// Parses Antigravity SQLite timestamps:
    /// - Go/SQLite datetime: `2026-11-23 09:51:13.54225+00:00`, `2026-11-23 09:49:55.986339+00:00`
    /// - Standard ISO-8601: `2026-11-23T09:49:55Z`, `2026-11-23T09:49:55.123Z`
    /// - Epoch seconds or milliseconds
    /// Rejects Go's zero time (`0001-01-01`) and out-of-range dates (R8).
    static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let number = Double(trimmed), number.isFinite, number > 0 {
            let seconds = number > 1e11 ? number / 1000 : number
            guard seconds > 1e8, seconds < 1e11 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        // Normalize space date-time separator to 'T'.
        var iso = trimmed
        if let space = iso.firstIndex(of: " "), iso.distance(from: iso.startIndex, to: space) == 10 {
            iso.replaceSubrange(space...space, with: "T")
        }
        // Ensure timezone designator exists after 'T'.
        if let tIdx = iso.firstIndex(of: "T") {
            let timePart = iso[iso.index(after: tIdx)...]
            let hasZone = timePart.hasSuffix("Z") || timePart.hasSuffix("z")
                || timePart.contains("+") || timePart.contains("-")
            if !hasZone { iso.append("Z") }
        }
        // Normalize variable-length fractional seconds (e.g. .54225, .986339) to 3 digits for ISO8601FormatStyle.
        if let dot = iso.firstIndex(of: ".") {
            let fracStart = iso.index(after: dot)
            var fracEnd = fracStart
            while fracEnd < iso.endIndex, iso[fracEnd].isNumber {
                fracEnd = iso.index(after: fracEnd)
            }
            let digits = iso[fracStart..<fracEnd]
            let normalized = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            iso.replaceSubrange(fracStart..<fracEnd, with: normalized)
        }
        let parsed = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso))
            ?? (try? Date.ISO8601FormatStyle().parse(iso))
        guard let parsed else { return nil }
        let s = parsed.timeIntervalSince1970
        guard s > 1e8, s < 1e11 else { return nil }
        return parsed
    }
}
