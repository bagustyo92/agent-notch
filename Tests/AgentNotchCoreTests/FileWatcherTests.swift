import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct FileWatching {
    @Test func reportsAFileCreatedInsideTheWatchedDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch-fw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolvedDir = dir.resolvingSymlinksInPath().path

        let collector = PathCollector()
        let seen = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String], any Error>) in
            let watcher = FileWatcher(paths: [resolvedDir], latency: 0.1) { paths in
                let all = collector.add(paths)
                if all.contains(where: { $0.hasSuffix("/4242.json") }), collector.finish() { cont.resume(returning: all) }
            }
            guard watcher.start() else { cont.resume(throwing: FileWatcherError.startFailed); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                try? Data("x".utf8).write(to: dir.appendingPathComponent("4242.json"))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                if collector.finish() { cont.resume(returning: collector.all) }
                watcher.stop()
            }
        }
        #expect(seen.contains { $0.hasSuffix("/4242.json") }, "seen: \(seen)")
    }
}

final class PathCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var finished = false
    func add(_ p: [String]) -> [String] { lock.withLock { paths += p; return paths } }
    var all: [String] { lock.withLock { paths } }
    /// Returns true only the first time.
    func finish() -> Bool { lock.withLock { if finished { return false }; finished = true; return true } }
}
