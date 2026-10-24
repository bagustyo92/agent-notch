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

final class AliveSet: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<Int32>
    init(_ pids: Set<Int32>) { self.pids = pids }
    func contains(_ pid: Int32) -> Bool { lock.withLock { pids.contains(pid) } }
    func remove(_ pid: Int32) { lock.withLock { _ = pids.remove(pid) } }
}
