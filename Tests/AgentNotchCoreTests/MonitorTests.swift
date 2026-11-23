import Foundation
import SQLite3
import Testing
@testable import AgentNotchCore

private let t0 = Date(timeIntervalSince1970: 1_792_900_000)

@MainActor
@Suite struct MonitorRefresh {
    @Test func refreshListsProbesAndEnrichesNewSessions() async throws {
        let store = SessionStore(testedVersion: "2.1.310")
        let listed = [
            ListedSession(sessionId: "11111111-1111-4111-8111-111111111111", pid: 4242, cwd: "/Users/dev/work/repo-a", kind: .interactive, name: "repo-a-36", startedAt: t0, status: "busy"),
            ListedSession(sessionId: "22222222-2222-4222-8222-222222222222", pid: 4243, cwd: "/Users/dev/work/repo-b", kind: .interactive, name: "repo-b-cf", startedAt: t0, status: "idle"),
            ListedSession(sessionId: "33333333-3333-4333-8333-333333333333", pid: nil, cwd: "/Users/dev/work/repo-c", kind: .background, name: "bg task", startedAt: t0, state: "blocked"),
        ]
        let lister = SessionLister(command: StubCommand(.success(listed)), registry: RegistryReader(directory: fixture("sessions")))
        let monitor = Monitor(
            store: store, lister: lister,
            sessionsDirectory: fixture("sessions"), projectsDirectory: fixture("projects"),
            probe: { pid in pid == 4242 ? (.cursor, nil) : (.terminal, "ttys003") },
            transcriptLocator: { id in id.hasPrefix("3333") ? fixture("projects/-Users-dev-work-repo-c/bg.jsonl") : nil },
            transcriptModifiedAt: { _ in t0.addingTimeInterval(-60) },
            isAlive: { _ in true }
        )
        await monitor.refresh(now: t0)

        let a = try #require(store.session(id: "11111111-1111-4111-8111-111111111111"))
        #expect(a.source == .cursor)
        #expect(a.claudeVersion == "2.1.310")     // read from the registry file for pid 4242
        let b = try #require(store.session(id: "22222222-2222-4222-8222-222222222222"))
        #expect(b.source == .terminal)
        #expect(b.tty == "ttys003")
        #expect(b.claudeVersion == "2.1.296")
        let c = try #require(store.session(id: "33333333-3333-4333-8333-333333333333"))
        #expect(c.source == .background)
        #expect(c.status == .waiting)
        #expect(store.versionNote == "Tested with Claude Code 2.1.310 · running 2.1.296")

        // The transcript attach runs off the main actor; wait briefly for it.
        for _ in 0..<40 where store.session(id: c.id)?.aiTitle == nil { try await Task.sleep(for: .milliseconds(50)) }
        let attached = try #require(store.session(id: c.id))
        #expect(attached.aiTitle == "Background title")
        #expect(attached.branch == "bg-branch")
        #expect(attached.activity == Activity(full: "Grep", brief: "Grep"))
    }

    @Test func listedSessionWithADeadPidIsNotRevived() async throws {
        let store = SessionStore()
        let entry = ListedSession(sessionId: "x", pid: 4242, cwd: "/Users/dev/x", kind: .interactive, name: "x", startedAt: t0, status: "busy")
        let alive = AliveSet([4242])
        let lister = SessionLister(command: StubCommand(.success([entry])), registry: RegistryReader(directory: fixture("nope")), minInterval: 0)
        let monitor = Monitor(store: store, lister: lister, sessionsDirectory: fixture("nope"), projectsDirectory: fixture("nope"),
                              probe: { _ in (.cursor, nil) }, transcriptLocator: { _ in nil }, transcriptModifiedAt: { _ in nil },
                              isAlive: { alive.contains($0) })
        await monitor.refresh(now: t0)
        #expect(store.session(id: "x")?.status == .working)
        alive.remove(4242)                       // crashed; its registry file lingers and is listed again
        store.checkLiveness(now: t0.addingTimeInterval(5), isAlive: { alive.contains($0) })
        await monitor.refresh(now: t0.addingTimeInterval(6))
        #expect(store.session(id: "x")?.status == .done)
    }

    @Test func refreshKeepsTheOldListWhenBothSourcesFail() async {
        let store = SessionStore()
        let good = SessionLister(command: StubCommand(.success([ListedSession(sessionId: "x", pid: 1, cwd: "/Users/dev/x", kind: .interactive, name: "x", startedAt: t0, status: "busy")])), registry: RegistryReader(directory: fixture("nope")))
        let m1 = Monitor(store: store, lister: good, sessionsDirectory: fixture("nope"), projectsDirectory: fixture("nope"), probe: { _ in (.unknown, nil) }, transcriptLocator: { _ in nil }, transcriptModifiedAt: { _ in nil }, isAlive: { _ in true })
        await m1.refresh(now: t0)
        #expect(store.sessions.count == 1)
        let bad = SessionLister(command: StubCommand(.failure(AgentsCommandError.executableNotFound)), registry: RegistryReader(directory: fixture("nope")))
        let m2 = Monitor(store: store, lister: bad, sessionsDirectory: fixture("nope"), projectsDirectory: fixture("nope"), probe: { _ in (.unknown, nil) }, transcriptLocator: { _ in nil }, transcriptModifiedAt: { _ in nil }, isAlive: { _ in true })
        await m2.refresh(now: t0.addingTimeInterval(1))
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].status == .working)
    }
}

/// D43 through `Monitor.refresh`: one row per session id, and the window a click can fall back to.
@MainActor
@Suite struct MonitorIDEWindows {
    typealias Proc = IDEDeepLinking.Proc
    static let started = IDEDeepLinking.started
    static let otherAppTitle = "Cursor Helper (Plugin): extension-host (user) other-app [5-7]"

    func monitor(_ store: SessionStore, _ entries: [ListedSession], _ table: ProcTable) -> Monitor {
        let lister = SessionLister(command: StubCommand(.success(entries)), registry: RegistryReader(directory: fixture("nope")), minInterval: 0)
        return Monitor(store: store, lister: lister, sessionsDirectory: fixture("nope"), projectsDirectory: fixture("nope"),
                       probe: { _ in (.cursor, nil) }, transcriptLocator: { _ in nil }, transcriptModifiedAt: { _ in nil },
                       isAlive: { _ in true }, ideProbe: table.probe)
    }

    func entry(pid: Int32, startedAt: Date = started) -> ListedSession {
        ListedSession(sessionId: "s", pid: pid, cwd: "/Users/dev/work/my-app", kind: .interactive, name: "s", startedAt: startedAt, status: "idle")
    }

    @Test func trustedWindowIsRememberedAndKeptWhenTheHostLaterLosesTrust() async throws {
        let store = SessionStore()
        let table = ProcTable(IDEDeepLinking.procs())
        let monitor = monitor(store, [entry(pid: 4242)], table)
        await monitor.refresh(now: t0)
        let expected = IDEWindow(windowId: 5, workspace: "my-app", mainPid: 322, mainStartedAt: IDEDeepLinking.mainStarted)
        #expect(store.session(id: "s")?.ideWindow == expected)

        // Window 5 later opens another project: the session's host is left over, not trusted.
        table.set(901, Proc(exe: IDEDeepLinking.cursorHelper, start: IDEDeepLinking.mainStarted, parent: 322, title: Self.otherAppTitle))
        await monitor.refresh(now: t0.addingTimeInterval(1))
        #expect(store.session(id: "s")?.ideWindow == expected)
    }

    @Test func duplicatedSessionStandsForTheProcessUnderTheCurrentHost() async throws {
        // 4242 sits under the left-over host [5-1]; 4300 runs the same session under window 8.
        var procs = IDEDeepLinking.procs()
        procs[901] = Proc(exe: IDEDeepLinking.cursorHelper, start: IDEDeepLinking.mainStarted, parent: 322, title: Self.otherAppTitle)
        procs[902] = Proc(exe: IDEDeepLinking.cursorHelper, start: IDEDeepLinking.mainStarted, parent: 322,
                          title: "Cursor Helper (Plugin): extension-host (user) my-app [8-42]")
        let later = Self.started.addingTimeInterval(-3600)       // the current process is the OLDER one here
        procs[4300] = Proc(exe: IDEDeepLinking.cursorClaude, start: later, parent: 902)
        let store = SessionStore()
        let monitor = monitor(store, [entry(pid: 4242), entry(pid: 4300, startedAt: later)], ProcTable(procs))
        await monitor.refresh(now: t0)
        let s = try #require(store.session(id: "s"))
        #expect(s.pid == 4300)
        #expect(s.startedAt == later)
        #expect(s.ideWindow?.windowId == 8)
    }
}

/// A mutable fake process table for `IDEDeepLink.Probe`; every listed pid is alive.
final class ProcTable: @unchecked Sendable {
    private let lock = NSLock()
    private var procs: [Int32: IDEDeepLinking.Proc]
    init(_ procs: [Int32: IDEDeepLinking.Proc]) { self.procs = procs }
    func set(_ pid: Int32, _ proc: IDEDeepLinking.Proc?) { lock.withLock { procs[pid] = proc } }
    private func get(_ pid: Int32) -> IDEDeepLinking.Proc? { lock.withLock { procs[pid] } }
    var probe: IDEDeepLink.Probe {
        IDEDeepLink.Probe(
            isAlive: { self.get($0) != nil }, executablePath: { self.get($0)?.exe }, startTime: { self.get($0)?.start },
            parentPid: { self.get($0)?.parent }, processTitle: { self.get($0)?.title },
            allPids: { self.lock.withLock { self.procs.keys.sorted() } }
        )
    }
}

final class AliveSet: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<Int32>
    init(_ pids: Set<Int32>) { self.pids = pids }
    func contains(_ pid: Int32) -> Bool { lock.withLock { pids.contains(pid) } }
    func remove(_ pid: Int32) { lock.withLock { _ = pids.remove(pid) } }
}

@MainActor
@Suite struct MonitorCoexistence {
    private func makeAntigravitySurface(convId: String, status: String, now: Date) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch-coexist-\(UUID().uuidString)", isDirectory: true)
        let cliDir = root.appendingPathComponent("antigravity-cli", isDirectory: true)
        let transcriptDir = cliDir
            .appendingPathComponent("brain/\(convId)/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        try fixtureData("antigravity-transcript.jsonl").write(to: transcriptDir.appendingPathComponent("transcript.jsonl"))

        let dbURL = cliDir.appendingPathComponent("conversation_summaries.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let handle = try #require(db)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE conversation_summaries (
                conversation_id text PRIMARY KEY, title text NOT NULL DEFAULT "",
                last_modified_time datetime NOT NULL, workspace_uris text NOT NULL,
                status text NOT NULL DEFAULT "", agent_name text NOT NULL DEFAULT "",
                parent_conversation_id text NOT NULL DEFAULT "", nesting_depth integer NOT NULL DEFAULT 0,
                not_fully_idle numeric NOT NULL DEFAULT false, killed numeric NOT NULL DEFAULT false,
                last_user_input_time datetime NOT NULL
            );
            """, nil, nil, nil) == SQLITE_OK)
        let iso = ISO8601DateFormatter().string(from: now)
        let sql = """
            INSERT INTO conversation_summaries VALUES (
                '\(convId)', 'Antigravity feature', '\(iso)', '["file:///Users/dev/work/ag-repo"]',
                '\(status)', '', '', 0, 1, 0, '\(iso)'
            );
            """
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        return root
    }

    @Test func claudeAndAntigravityCoexistWithoutClobberingEachOther() async throws {
        let root = try makeAntigravitySurface(convId: "ag-conv-1", status: "CASCADE_RUN_STATUS_RUNNING", now: t0)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(testedVersion: "2.1.310")
        let claudeEntry = ListedSession(
            sessionId: "claude-1", pid: 4242, cwd: "/Users/dev/work/claude-repo",
            kind: .interactive, name: "claude-repo", startedAt: t0, status: "busy", version: "2.1.310"
        )
        let lister = SessionLister(command: StubCommand(.success([claudeEntry])), registry: RegistryReader(directory: fixture("nope")), minInterval: 0)
        let agReader = AntigravityReader(
            surfaces: [AntigravitySurface(name: "antigravity-cli", directory: root.appendingPathComponent("antigravity-cli"))],
            processScanner: { ["ag-conv-1": AntigravityProcessInfo(pid: 9001, executablePath: "/Users/dev/.local/bin/agy", source: .orca, startedAt: t0)] },
            branchResolver: { _ in "feat/ag" }
        )
        let monitor = Monitor(
            store: store, lister: lister,
            sessionsDirectory: fixture("nope"), projectsDirectory: fixture("nope"),
            probe: { _ in (.cursor, nil) }, transcriptLocator: { _ in nil },
            transcriptModifiedAt: { _ in nil }, isAlive: { _ in true },
            antigravityReader: agReader
        )

        await monitor.refresh(now: t0)

        // First refresh seeds both providers silently (no attention pop at launch).
        #expect(store.attentionLog.isEmpty)
        #expect(store.sessions.count == 2)

        let claude = try #require(store.session(id: "claude-1"))
        #expect(claude.provider == .claude)
        #expect(claude.source == .cursor)

        let ag = try #require(store.session(id: "ag-conv-1"))
        #expect(ag.provider == .antigravity)
        #expect(ag.source == .orca)
        #expect(ag.branch == "feat/ag")
        #expect(ag.aiTitle == "Antigravity feature")

        // Wait briefly for Antigravity transcript attachment off-actor.
        for _ in 0..<40 where store.session(id: "ag-conv-1")?.model == nil { try await Task.sleep(for: .milliseconds(50)) }
        let attached = try #require(store.session(id: "ag-conv-1"))
        #expect(attached.model == "gemini-4-neon")
        #expect(attached.effort == "high")
        #expect(attached.contextTokens == 120_000)
        #expect(attached.contextWindow == 1_000_000)
        #expect(attached.activity == Activity(full: "Run · Unit test execution", brief: "Run"))

        // Refreshing only Antigravity must NOT drop or alter Claude sessions.
        await monitor.refreshAntigravity(now: t0.addingTimeInterval(2))
        #expect(store.session(id: "claude-1")?.status == .working)
        #expect(store.session(id: "ag-conv-1")?.status == .working)

        // Refreshing only Claude must NOT drop or alter Antigravity sessions.
        await monitor.refreshClaude(now: t0.addingTimeInterval(3))
        #expect(store.session(id: "claude-1")?.status == .working)
        #expect(store.session(id: "ag-conv-1")?.status == .working)

        // versionNote stays nil because Claude matches testedVersion and Antigravity never triggers Claude version drift.
        #expect(store.versionNote == nil)
    }

    @Test func antigravityWorksEvenWhenClaudeIsAbsentOrFailing() async throws {
        let root = try makeAntigravitySurface(convId: "ag-only-1", status: "CASCADE_RUN_STATUS_RUNNING", now: t0)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore()
        let failingClaude = SessionLister(command: StubCommand(.failure(AgentsCommandError.executableNotFound)), registry: RegistryReader(directory: fixture("nope")), minInterval: 0)
        let agReader = AntigravityReader(
            surfaces: [AntigravitySurface(name: "antigravity-cli", directory: root.appendingPathComponent("antigravity-cli"))],
            processScanner: { [:] },
            branchResolver: { _ in "main" }
        )
        let monitor = Monitor(
            store: store, lister: failingClaude,
            sessionsDirectory: fixture("nope"), projectsDirectory: fixture("nope"),
            probe: { _ in (.unknown, nil) }, transcriptLocator: { _ in nil },
            transcriptModifiedAt: { _ in nil }, isAlive: { _ in true },
            antigravityReader: agReader
        )
        await monitor.refresh(now: t0)
        #expect(store.sessions.map(\.id) == ["ag-only-1"])
        #expect(store.sessions[0].provider == .antigravity)
        #expect(store.sessions[0].status == .working)
    }
}
