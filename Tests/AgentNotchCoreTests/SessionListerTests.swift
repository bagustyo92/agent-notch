import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct AgentsCommandProcess {
    @Test func runsTheScriptAndDecodesItsOutput() async throws {
        let cmd = AgentsCommand(executable: fixture("bin/claude-ok"), timeout: 5)
        let listed = try await cmd.run(now: Date())
        #expect(listed.count == 4)
        #expect(listed.contains { $0.name == "repo-a-36" && $0.status == "busy" })
    }

    @Test func missingExecutableThrows() async {
        let cmd = AgentsCommand(executable: fixture("bin/does-not-exist"), timeout: 5)
        await #expect(throws: AgentsCommandError.executableNotFound) { try await cmd.run(now: Date()) }
    }

    @Test func nonZeroExitThrows() async {
        let cmd = AgentsCommand(executable: fixture("bin/claude-fail"), timeout: 5)
        await #expect(throws: AgentsCommandError.nonZeroExit(2)) { try await cmd.run(now: Date()) }
    }

    @Test func timeoutThrows() async {
        let cmd = AgentsCommand(executable: fixture("bin/claude-slow"), timeout: 0.3)
        await #expect(throws: AgentsCommandError.timedOut) { try await cmd.run(now: Date()) }
    }
}

/// Counting stand-in for the command so the rate cap can be tested without spawning.
final class StubCommand: ListCommand, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    var result: Result<[ListedSession], any Error>
    let delay: Duration
    init(_ result: Result<[ListedSession], any Error>, delay: Duration = .zero) { self.result = result; self.delay = delay }
    func run(now: Date) async throws -> [ListedSession] {
        lock.withLock { _calls += 1 }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return try result.get()
    }
}

private let t0 = Date(timeIntervalSince1970: 1_792_900_000)
private let fromCommand = [ListedSession(sessionId: "cmd-1", pid: 1, cwd: "/Users/dev/a", kind: .interactive, name: "a", startedAt: t0, status: "busy")]

@Suite struct SessionListing {
    let registry = RegistryReader(directory: fixture("sessions"))

    @Test func usesTheCommandWhenItWorks() async throws {
        let lister = SessionLister(command: StubCommand(.success(fromCommand)), registry: registry)
        let r = try await lister.list(now: t0)
        #expect(r.sessions == fromCommand)
        #expect(r.usedFallback == false)
    }

    @Test func fallsBackToRegistryWhenCommandFails() async throws {
        let lister = SessionLister(command: StubCommand(.failure(AgentsCommandError.nonZeroExit(2))), registry: registry)
        let r = try await lister.list(now: t0)
        #expect(r.usedFallback == true)
        #expect(r.sessions.contains { $0.sessionId == "11111111-1111-4111-8111-111111111111" })
    }

    @Test func throwsWhenBothSourcesFail() async {
        let lister = SessionLister(command: StubCommand(.failure(AgentsCommandError.executableNotFound)),
                                   registry: RegistryReader(directory: fixture("does-not-exist")))
        await #expect(throws: (any Error).self) { try await lister.list(now: t0) }
    }

    @Test func callsWithinOneSecondReuseTheLastResult() async throws {
        let stub = StubCommand(.success(fromCommand))
        let lister = SessionLister(command: stub, registry: registry)
        _ = try await lister.list(now: t0)
        let r2 = try await lister.list(now: t0.addingTimeInterval(0.4))
        #expect(stub.calls == 1)
        #expect(r2.sessions == fromCommand)
        #expect(r2.retryAt == t0.addingTimeInterval(1))
        _ = try await lister.list(now: t0.addingTimeInterval(1.0))
        #expect(stub.calls == 2)
    }

    @Test func overlappingCallersShareOneCommandRun() async throws {
        let stub = StubCommand(.success(fromCommand), delay: .milliseconds(150))
        let lister = SessionLister(command: stub, registry: registry)
        async let a = lister.list(now: t0)
        async let b = lister.list(now: t0.addingTimeInterval(0.01))
        async let c = lister.list(now: t0.addingTimeInterval(0.02))
        let results = try await [a, b, c]
        #expect(stub.calls == 1)
        #expect(results.allSatisfy { $0.sessions == fromCommand && !$0.usedFallback })
    }

    @Test func morethanThirtyRunsPerMinuteSwitchesToRegistryForFiveMinutes() async throws {
        let stub = StubCommand(.success(fromCommand))
        let lister = SessionLister(command: stub, registry: registry)
        for i in 0..<30 { _ = try await lister.list(now: t0.addingTimeInterval(Double(i) * 1.5)) }
        #expect(stub.calls == 30)
        let r = try await lister.list(now: t0.addingTimeInterval(30 * 1.5))
        #expect(r.usedFallback == true)
        #expect(stub.calls == 30)
        let later = try await lister.list(now: t0.addingTimeInterval(30 * 1.5 + 299))
        #expect(later.usedFallback == true)
        let afterCooldown = try await lister.list(now: t0.addingTimeInterval(30 * 1.5 + 301))
        #expect(afterCooldown.usedFallback == false)
        #expect(stub.calls == 31)
    }
}
