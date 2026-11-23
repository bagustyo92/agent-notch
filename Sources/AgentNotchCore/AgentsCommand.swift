import Foundation

public enum AgentsCommandError: Error, Equatable {
    case executableNotFound
    case nonZeroExit(Int32)
    case timedOut
    case notAnArray
}

/// Runs `claude agents --json` (D23) and decodes it. Never runs on a timer (R7): the monitor
/// calls it only after `~/.claude/sessions/` changed.
public struct AgentsCommand: Sendable {
    public var executable: URL?
    public var timeout: TimeInterval

    /// Candidate locations for the `claude` binary. The app is launched by launchd/Finder with a
    /// minimal PATH, so `~/.local/bin` must be tried explicitly (F4). npm and nvm installs come last.
    public static func locateExecutable(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemPaths: [String] = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    ) -> URL? {
        let fm = FileManager.default
        var candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
        ] + systemPaths.map { URL(fileURLWithPath: $0) } + [
            home.appendingPathComponent(".npm-global/bin/claude"),
            home.appendingPathComponent(".bun/bin/claude"),
        ]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? fm.contentsOfDirectory(atPath: nvm.path)) ?? []
        candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { nvm.appendingPathComponent("\($0)/bin/claude") }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    public init(executable: URL? = AgentsCommand.locateExecutable(), timeout: TimeInterval = 5) {
        self.executable = executable
        self.timeout = timeout
    }

    /// Decode the command's stdout. Entries without a `sessionId` are dropped; everything else degrades.
    public static func decode(_ data: Data, now: Date) throws -> [ListedSession] {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let array = raw as? [Any] else { throw AgentsCommandError.notAnArray }
        return array.compactMap { element in
            guard let dict = element as? [String: Any] else { return nil }
            return ListedSession(json: dict, now: now)
        }
    }

    /// Run the command. Throws when the binary is missing, exits non-zero, or exceeds `timeout`,
    /// so the caller can fall back to `RegistryReader` (D23).
    public func run(now: Date = Date()) async throws -> [ListedSession] {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AgentsCommandError.executableNotFound
        }
        let data: Data
        do {
            data = try await ProcessRunner.capture(executable: executable, arguments: ["agents", "--json"], timeout: timeout)
        } catch let error as ProcessRunnerError {
            switch error {
            case .launchFailed: throw AgentsCommandError.executableNotFound
            case .nonZeroExit(let status): throw AgentsCommandError.nonZeroExit(status)
            case .timedOut: throw AgentsCommandError.timedOut
            }
        }
        return try Self.decode(data, now: now)
    }
}
