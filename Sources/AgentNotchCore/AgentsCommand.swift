import Darwin
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
        let data = try await Self.capture(executable: executable, arguments: ["agents", "--json"], timeout: timeout)
        return try Self.decode(data, now: now)
    }

    /// Spawn, drain stdout on a background thread (so a large list can never fill the pipe and stall
    /// the child), and enforce the timeout with SIGTERM, then SIGKILL one second later.
    static func capture(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["NO_COLOR": "1"]) { $1 }
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            let state = CaptureState()
            let queue = DispatchQueue.global(qos: .utility)
            let group = DispatchGroup()

            group.enter()
            queue.async {
                state.output = stdout.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            process.terminationHandler = { _ in group.leave() }

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                guard state.markTimedOut() else { return }
                process.terminate()
                queue.asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }

            do {
                try process.run()
            } catch {
                try? stdout.fileHandleForWriting.close()      // lets the reader see EOF
                timer.setEventHandler(handler: nil)
                timer.resume()                               // a suspended source must never be released
                timer.cancel()
                continuation.resume(throwing: AgentsCommandError.executableNotFound)
                return
            }
            timer.resume()

            group.notify(queue: queue) {
                timer.cancel()
                if state.didTimeOut {
                    continuation.resume(throwing: AgentsCommandError.timedOut)
                } else if process.terminationStatus != 0 {
                    continuation.resume(throwing: AgentsCommandError.nonZeroExit(process.terminationStatus))
                } else {
                    continuation.resume(returning: state.output)
                }
            }
        }
    }
}

/// Lock-guarded state shared by the reader thread, the timeout timer and the completion block.
private final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false
    private var _output = Data()

    var didTimeOut: Bool { lock.withLock { timedOut } }
    /// Returns true only for the first caller.
    func markTimedOut() -> Bool { lock.withLock { if timedOut { return false }; timedOut = true; return true } }
    var output: Data {
        get { lock.withLock { _output } }
        set { lock.withLock { _output = newValue } }
    }
}
