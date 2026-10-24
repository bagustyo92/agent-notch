import Foundation

/// Anything that can produce the session list the way `claude agents --json` does.
public protocol ListCommand: Sendable {
    func run(now: Date) async throws -> [ListedSession]
}

extension AgentsCommand: ListCommand {}

public struct ListResult: Sendable, Equatable {
    public var sessions: [ListedSession]
    /// True when the registry was read instead of the command (D23 fallback, or the burst cap).
    public var usedFallback: Bool
    /// Set when the call was coalesced by the 1 call/s cap; the caller should list again at this time.
    public var retryAt: Date?
}

/// Chooses between `claude agents --json` and the registry (D23) and enforces the cost rules from
/// the Risks table: at most 1 command run per second (overlapping callers share one run), and after
/// 30 runs in a minute the registry is used for 5 minutes.
public actor SessionLister {
    private let command: any ListCommand
    private let registry: RegistryReader
    private let minInterval: TimeInterval
    private let burstLimit: Int
    private let burstWindow: TimeInterval
    private let fallbackDuration: TimeInterval

    private var lastRunAt: Date?
    private var lastResult: ListResult?
    private var runTimes: [Date] = []
    private var fallbackUntil: Date?
    private var inFlight: Task<ListResult, any Error>?

    public init(
        command: any ListCommand, registry: RegistryReader,
        minInterval: TimeInterval = 1, burstLimit: Int = 30, burstWindow: TimeInterval = 60,
        fallbackDuration: TimeInterval = 300
    ) {
        self.command = command; self.registry = registry
        self.minInterval = minInterval; self.burstLimit = burstLimit
        self.burstWindow = burstWindow; self.fallbackDuration = fallbackDuration
    }

    public func list(now: Date) async throws -> ListResult {
        if let inFlight { return try await inFlight.value }          // actor reentrancy: share the run
        if let lastRunAt, let lastResult, now.timeIntervalSince(lastRunAt) < minInterval {
            var coalesced = lastResult
            coalesced.retryAt = lastRunAt.addingTimeInterval(minInterval)
            return coalesced
        }
        if let until = fallbackUntil, now < until {
            return remember(ListResult(sessions: try registry.read(now: now), usedFallback: true), at: now)
        }
        fallbackUntil = nil
        runTimes = runTimes.filter { now.timeIntervalSince($0) < burstWindow }
        if runTimes.count >= burstLimit {
            fallbackUntil = now.addingTimeInterval(fallbackDuration)
            runTimes.removeAll()
            return remember(ListResult(sessions: try registry.read(now: now), usedFallback: true), at: now)
        }
        runTimes.append(now)

        let command = command, registry = registry
        let task = Task { () throws -> ListResult in
            do {
                return ListResult(sessions: try await command.run(now: now), usedFallback: false)
            } catch {
                return ListResult(sessions: try registry.read(now: now), usedFallback: true)
            }
        }
        inFlight = task
        defer { inFlight = nil }
        return remember(try await task.value, at: now)
    }

    private func remember(_ result: ListResult, at now: Date) -> ListResult {
        lastRunAt = now
        lastResult = result
        return result
    }
}
