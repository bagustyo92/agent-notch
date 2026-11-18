import Foundation
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
