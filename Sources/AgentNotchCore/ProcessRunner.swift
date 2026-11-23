import Darwin
import Foundation

enum ProcessRunnerError: Error, Equatable {
    case launchFailed
    case nonZeroExit(Int32)
    case timedOut
}

/// Shared subprocess execution with background pipe draining and SIGTERM→SIGKILL timeout.
enum ProcessRunner {
    /// Spawn, drain stdout on a background thread (so a large output can never fill the pipe and
    /// stall the child), and enforce the timeout with SIGTERM, then SIGKILL one second later.
    static func capture(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let currentDirectory {
                process.currentDirectoryURL = currentDirectory
            }
            process.environment = environment ?? ProcessInfo.processInfo.environment.merging(["NO_COLOR": "1"]) { $1 }
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
                continuation.resume(throwing: ProcessRunnerError.launchFailed)
                return
            }
            timer.resume()

            group.notify(queue: queue) {
                timer.cancel()
                if state.didTimeOut {
                    continuation.resume(throwing: ProcessRunnerError.timedOut)
                } else if process.terminationStatus != 0 {
                    continuation.resume(throwing: ProcessRunnerError.nonZeroExit(process.terminationStatus))
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
