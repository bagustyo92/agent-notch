import Foundation
import SQLite3
import Testing
@testable import AgentNotchCore

@Suite struct AntigravityReading {
    private let t0 = Date(timeIntervalSince1970: 1_792_900_000)

    private struct RowSeed {
        var id: String
        var title: String = "Test conversation"
        var status: String = ""
        var agentName: String = ""
        var parentId: String = ""
        var nestingDepth: Int = 0
        var notFullyIdle: Int = 0
        var killed: Int = 0
        var lastModified: String
        var lastUserInput: String
        var workspaceUris: String = #"["file:///Users/dev/work/my-app"]"#
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch-ag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func isoString(_ date: Date, fractionalDigits: Int = 6) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let base = fmt.string(from: date).replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "")
        if fractionalDigits == 0 { return "\(base)+00:00" }
        let frac = String(repeating: "5", count: fractionalDigits)
        return "\(base).\(frac)+00:00"
    }

    /// Creates a real WAL-mode `conversation_summaries.db` matching Antigravity's schema.
    /// When `keepWALOpen` is true, returns the open writer handle so `-shm` and `-wal` exist on disk.
    @discardableResult
    private func createDB(in surfaceDir: URL, rows: [RowSeed], keepWALOpen: Bool = false) throws -> OpaquePointer? {
        try FileManager.default.createDirectory(at: surfaceDir, withIntermediateDirectories: true)
        let dbURL = surfaceDir.appendingPathComponent("conversation_summaries.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let handle = try #require(db)
        func exec(_ sql: String) {
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("""
            CREATE TABLE conversation_summaries (
                conversation_id text PRIMARY KEY,
                title text NOT NULL DEFAULT "",
                preview text NOT NULL DEFAULT "",
                step_count integer NOT NULL DEFAULT 0,
                last_modified_time datetime NOT NULL,
                workspace_uris text NOT NULL,
                status text NOT NULL DEFAULT "",
                source text NOT NULL DEFAULT "",
                project_id text NOT NULL DEFAULT "",
                agent_name text NOT NULL DEFAULT "",
                parent_conversation_id text NOT NULL DEFAULT "",
                nesting_depth integer NOT NULL DEFAULT 0,
                not_fully_idle numeric NOT NULL DEFAULT false,
                killed numeric NOT NULL DEFAULT false,
                last_user_input_time datetime NOT NULL,
                raw_summary blob
            );
            """)
        let insertSQL = """
            INSERT INTO conversation_summaries (
                conversation_id, title, preview, last_modified_time, workspace_uris, status,
                agent_name, parent_conversation_id, nesting_depth, not_fully_idle, killed,
                last_user_input_time, raw_summary
            ) VALUES (?, ?, 'PRIVATE PREVIEW NEVER READ', ?, ?, ?, ?, ?, ?, ?, ?, ?, X'DEADBEEF');
            """
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for r in rows {
            var stmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(handle, insertSQL, -1, &stmt, nil) == SQLITE_OK)
            let s = try #require(stmt)
            sqlite3_bind_text(s, 1, r.id, -1, transient)
            sqlite3_bind_text(s, 2, r.title, -1, transient)
            sqlite3_bind_text(s, 3, r.lastModified, -1, transient)
            sqlite3_bind_text(s, 4, r.workspaceUris, -1, transient)
            sqlite3_bind_text(s, 5, r.status, -1, transient)
            sqlite3_bind_text(s, 6, r.agentName, -1, transient)
            sqlite3_bind_text(s, 7, r.parentId, -1, transient)
            sqlite3_bind_int64(s, 8, Int64(r.nestingDepth))
            sqlite3_bind_int64(s, 9, Int64(r.notFullyIdle))
            sqlite3_bind_int64(s, 10, Int64(r.killed))
            sqlite3_bind_text(s, 11, r.lastUserInput, -1, transient)
            #expect(sqlite3_step(s) == SQLITE_DONE)
            sqlite3_finalize(s)
        }
        if keepWALOpen {
            return handle
        }
        exec("PRAGMA wal_checkpoint(TRUNCATE);")
        sqlite3_close(handle)
        try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
        try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
        return nil
    }

    @Test func filtersActiveWaitingIdleKilledStaleRunningAndRecentLinger() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliDir = root.appendingPathComponent("antigravity-cli", isDirectory: true)

        let writer = try createDB(in: cliDir, rows: [
            // Actively running without detected pid, recent -> included as working
            RowSeed(id: "running-no-pid", title: "Build feature token=secret99", status: "CASCADE_RUN_STATUS_RUNNING",
                    notFullyIdle: 1, lastModified: isoString(t0.addingTimeInterval(-30)), lastUserInput: isoString(t0.addingTimeInterval(-120))),
            // Waiting for user -> included as waiting
            RowSeed(id: "waiting-user", title: "Approve plan", status: "CASCADE_RUN_STATUS_WAITING_FOR_USER",
                    lastModified: isoString(t0.addingTimeInterval(-15)), lastUserInput: isoString(t0.addingTimeInterval(-90))),
            // Live backing process, currently idle -> included as idle with process source & tty
            RowSeed(id: "live-idle", title: "Ready for prompt", status: "CASCADE_RUN_STATUS_IDLE",
                    lastModified: isoString(t0.addingTimeInterval(-1800)), lastUserInput: isoString(t0.addingTimeInterval(-2000))),
            // Recently finished with no backing process (3 min ago) -> included as done with endedAt
            RowSeed(id: "recent-done", title: "Just finished", status: "",
                    lastModified: isoString(t0.addingTimeInterval(-180)), lastUserInput: isoString(t0.addingTimeInterval(-300))),
            // Old idle with no backing process (15 min ago) -> excluded
            RowSeed(id: "old-idle", title: "Old session", status: "CASCADE_RUN_STATUS_IDLE",
                    lastModified: isoString(t0.addingTimeInterval(-900)), lastUserInput: isoString(t0.addingTimeInterval(-1000))),
            // Stale abandoned RUNNING with no backing process (35 min ago) -> guarded & excluded
            RowSeed(id: "stale-running", title: "Abandoned run", status: "CASCADE_RUN_STATUS_RUNNING",
                    notFullyIdle: 1, lastModified: isoString(t0.addingTimeInterval(-2100)), lastUserInput: isoString(t0.addingTimeInterval(-2200))),
            // Killed without live process -> excluded
            RowSeed(id: "killed-row", title: "Killed session", status: "CASCADE_RUN_STATUS_RUNNING",
                    notFullyIdle: 1, killed: 1, lastModified: isoString(t0.addingTimeInterval(-10)), lastUserInput: isoString(t0.addingTimeInterval(-60))),
            // Running WITH live process even after 40 min -> kept because process is alive
            RowSeed(id: "long-live-running", title: "Long build", status: "CASCADE_RUN_STATUS_RUNNING",
                    notFullyIdle: 1, lastModified: isoString(t0.addingTimeInterval(-2400)), lastUserInput: isoString(t0.addingTimeInterval(-2500))),
        ], keepWALOpen: true)
        defer { if let writer { sqlite3_close(writer) } }

        let procs: [String: AntigravityProcessInfo] = [
            "live-idle": AntigravityProcessInfo(pid: 5001, executablePath: "/Users/dev/.local/bin/agy", source: .orca, tty: nil, startedAt: t0.addingTimeInterval(-2500)),
            "long-live-running": AntigravityProcessInfo(pid: 5002, executablePath: "/Users/dev/.local/bin/agy", source: .terminal, tty: "ttys004", startedAt: t0.addingTimeInterval(-2600)),
        ]
        let reader = AntigravityReader(
            surfaces: [AntigravitySurface(name: "antigravity-cli", directory: cliDir)],
            processScanner: { procs },
            branchResolver: { _ in "feat/test" }
        )

        let snap = reader.read(now: t0)
        let byId = Dictionary(uniqueKeysWithValues: snap.sessions.map { ($0.sessionId, $0) })

        #expect(Set(byId.keys) == ["running-no-pid", "waiting-user", "live-idle", "recent-done", "long-live-running"])

        let running = try #require(byId["running-no-pid"])
        #expect(running.provider == .antigravity)
        #expect(running.mappedStatus == .working)
        #expect(running.aiTitle == "Build feature token=•••")
        #expect(running.branch == "feat/test")
        #expect(running.cwd == "/Users/dev/work/my-app")

        let waiting = try #require(byId["waiting-user"])
        #expect(waiting.mappedStatus == .waiting)
        #expect(waiting.waitingFor == "input needed")

        let liveIdle = try #require(byId["live-idle"])
        #expect(liveIdle.mappedStatus == .idle)
        #expect(liveIdle.pid == 5001)
        #expect(liveIdle.sourceHint == .orca)

        let recentDone = try #require(byId["recent-done"])
        #expect(recentDone.mappedStatus == .done)
        #expect(recentDone.endedAt != nil)

        let longLive = try #require(byId["long-live-running"])
        #expect(longLive.mappedStatus == .working)
        #expect(longLive.sourceHint == .terminal)
        #expect(longLive.tty == "ttys004")
    }

    @Test func readsCheckpointedWALDatabaseStrictlyReadOnlyWithoutCreatingShmOrWal() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let appDir = root.appendingPathComponent("antigravity", isDirectory: true)

        try createDB(in: appDir, rows: [
            RowSeed(id: "app-session", title: "Desktop chat", status: "CASCADE_RUN_STATUS_RUNNING",
                    lastModified: isoString(t0.addingTimeInterval(-5)), lastUserInput: isoString(t0.addingTimeInterval(-20))),
        ], keepWALOpen: false)

        // Confirm SQLite closed cleanly and no -shm/-wal exists before read.
        let shmPath = appDir.appendingPathComponent("conversation_summaries.db-shm").path
        let walPath = appDir.appendingPathComponent("conversation_summaries.db-wal").path
        #expect(!FileManager.default.fileExists(atPath: shmPath))
        #expect(!FileManager.default.fileExists(atPath: walPath))

        let reader = AntigravityReader(
            surfaces: [AntigravitySurface(name: "antigravity", directory: appDir)],
            processScanner: { [:] },
            branchResolver: { _ in nil }
        )
        let snap = reader.read(now: t0)
        #expect(snap.sessions.count == 1)
        #expect(snap.sessions[0].sessionId == "app-session")
        #expect(snap.sessions[0].sourceHint == .antigravityApp)

        // R1: strictly read-only — must NEVER create -shm or -wal files under ~/.gemini/.
        #expect(!FileManager.default.fileExists(atPath: shmPath))
        #expect(!FileManager.default.fileExists(atPath: walPath))
    }

    @Test func nestsChildAndGrandchildSubagentsUnderTopLevelSession() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliDir = root.appendingPathComponent("antigravity-cli", isDirectory: true)

        try createDB(in: cliDir, rows: [
            RowSeed(id: "root-1", title: "Main task", status: "CASCADE_RUN_STATUS_RUNNING",
                    lastModified: isoString(t0.addingTimeInterval(-5)), lastUserInput: isoString(t0.addingTimeInterval(-60))),
            RowSeed(id: "sub-1", title: "Explore codebase", status: "CASCADE_RUN_STATUS_RUNNING",
                    agentName: "research", parentId: "root-1", nestingDepth: 1,
                    lastModified: isoString(t0.addingTimeInterval(-4)), lastUserInput: isoString(t0.addingTimeInterval(-30))),
            RowSeed(id: "sub-2", title: "Read schema", status: "CASCADE_RUN_STATUS_IDLE",
                    agentName: "helper", parentId: "sub-1", nestingDepth: 2,
                    lastModified: isoString(t0.addingTimeInterval(-3)), lastUserInput: isoString(t0.addingTimeInterval(-20))),
            // Orphan subagent whose root is not included -> dropped
            RowSeed(id: "orphan-sub", title: "Orphan", status: "CASCADE_RUN_STATUS_RUNNING",
                    agentName: "research", parentId: "missing-root", nestingDepth: 1,
                    lastModified: isoString(t0.addingTimeInterval(-2)), lastUserInput: isoString(t0.addingTimeInterval(-10))),
        ])

        let reader = AntigravityReader(
            surfaces: [AntigravitySurface(name: "antigravity-cli", directory: cliDir)],
            processScanner: { [:] },
            branchResolver: { _ in nil }
        )
        let snap = reader.read(now: t0)
        #expect(snap.sessions.map(\.sessionId) == ["root-1"])
        let subs = try #require(snap.subagentsByRootId["root-1"])
        let subsById = Dictionary(uniqueKeysWithValues: subs.map { ($0.id, $0) })
        #expect(Set(subsById.keys) == ["sub-1", "sub-2"])
        #expect(subsById["sub-1"]?.agentType == "research")
        #expect(subsById["sub-1"]?.parentId == "root-1")
        #expect(subsById["sub-1"]?.finished == false)
        #expect(subsById["sub-2"]?.parentId == "sub-1")
        #expect(subsById["sub-2"]?.spawnDepth == 2)
        #expect(subsById["sub-2"]?.finished == true)
    }

    @Test func parsesWorkspaceUrisAndTimestampFormats() {
        #expect(AntigravityReader.firstWorkspacePath(from: #"["file:///Users/dev/work/my-app"]"#) == "/Users/dev/work/my-app")
        #expect(AntigravityReader.firstWorkspacePath(from: #"["file:///Users/dev/my%20repo"]"#) == "/Users/dev/my repo")
        #expect(AntigravityReader.firstWorkspacePath(from: "[]") == nil)
        #expect(AntigravityReader.firstWorkspacePath(from: "not json") == nil)

        #expect(AntigravityReader.parseTimestamp("2026-11-23 09:51:13.54225+00:00") != nil)
        #expect(AntigravityReader.parseTimestamp("2026-11-23 09:49:55.986339+00:00") != nil)
        #expect(AntigravityReader.parseTimestamp("2026-11-23T09:49:55Z") != nil)
        #expect(AntigravityReader.parseTimestamp("2026-11-23 09:49:55") != nil)
        #expect(AntigravityReader.parseTimestamp("1792900000") == Date(timeIntervalSince1970: 1_792_900_000))
        #expect(AntigravityReader.parseTimestamp("1792900000000") == Date(timeIntervalSince1970: 1_792_900_000))
        // Go zero time and garbage must degrade to nil (R8)
        #expect(AntigravityReader.parseTimestamp("0001-01-01 00:00:00+00:00") == nil)
        #expect(AntigravityReader.parseTimestamp("") == nil)
        #expect(AntigravityReader.parseTimestamp("not-a-date") == nil)
    }
}
