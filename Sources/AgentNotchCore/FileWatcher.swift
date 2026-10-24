import CoreServices
import Foundation

public enum FileWatcherError: Error { case startFailed }

/// Thin FSEvents wrapper (file-level events). Delivers changed paths on a private queue;
/// the caller debounces and hops to the main actor.
///
/// Lifetime: the stream's context retains the watcher, so a callback in flight can never outlive
/// it. That also means `stop()` must be called to release a started watcher.
public final class FileWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable ([String]) -> Void

    private let paths: [String]
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.bagustyo92.agentnotch.filewatcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    public init(paths: [String], latency: TimeInterval = 0.2, handler: @escaping Handler) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    @discardableResult
    public func start() -> Bool {
        lock.withLock {
            guard stream == nil else { return true }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: { info in
                    guard let info else { return nil }
                    _ = Unmanaged<FileWatcher>.fromOpaque(info).retain()
                    return info
                },
                release: { info in
                    guard let info else { return }
                    Unmanaged<FileWatcher>.fromOpaque(info).release()
                },
                copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            )
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault, FileWatcher.callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
            ) else { return false }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                return false
            }
            self.stream = stream
            return true
        }
    }

    public func stop() {
        lock.withLock {
            guard let stream else { return }
            self.stream = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
        guard let info, count > 0 else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
        let array = unsafeBitCast(eventPaths, to: CFArray.self) as NSArray
        let paths = array.compactMap { $0 as? String }
        if !paths.isEmpty { watcher.handler(paths) }
    }
}
