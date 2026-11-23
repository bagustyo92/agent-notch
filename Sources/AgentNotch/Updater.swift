import AgentNotchCore
import AppKit
import Foundation

/// D45: Observable state of the one-click updater, rendered on line 2 of the popover footer.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(ReleaseFeed.UpdateOffer)
    case downloading(Double)
    case installing
    case failed(reason: String, retryOffer: ReleaseFeed.UpdateOffer?)
    case manual(version: AppVersion, notesURL: URL, reason: String)
    case updated(version: AppVersion, notesURL: URL)
}

/// D45: App-owned one-click updater (`@MainActor @Observable`, owned by `AppDelegate` so closing
/// the popover mid-download preserves state). Makes zero network calls unless the user clicks
/// *Check for Updates* or *Update* (R3), and persists nothing (R4).
@MainActor
@Observable
final class Updater {
    struct Config: Sendable {
        let bundleURL: URL
        let runningVersion: AppVersion?
        let feedURL: URL
        let allowedDownloadPrefix: String
        let allowedNotesPrefix: String?
        let publicKey: Data
        let requireHTTPS: Bool
        let isDemo: Bool

        static func live(
            bundle: Bundle = .main,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Config {
            let bundleURL = bundle.bundleURL
            let runningVersion = BundleCheck.readInfo(at: bundleURL)?.version
            var feedURL = ReleaseFeed.defaultFeedURL
            var allowedDownloadPrefix = ReleaseFeed.defaultDownloadPrefix
            var allowedNotesPrefix: String? = ReleaseFeed.defaultNotesPrefix
            var publicKey = UpdateKey.publicKey
            var requireHTTPS = true

            #if DEBUG
            if let rawFeed = environment["AGENTNOTCH_UPDATE_FEED"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawFeed.isEmpty,
               let parsed = URL(string: rawFeed),
               ReleaseFeed.isAllowedTransportURL(parsed, requireHTTPS: false)
            {
                if parsed.isFileURL {
                    feedURL = parsed
                    let dir = parsed.deletingLastPathComponent().standardizedFileURL.absoluteString
                    allowedDownloadPrefix = dir.hasSuffix("/") ? dir : dir + "/"
                    allowedNotesPrefix = nil
                    requireHTTPS = false
                } else if parsed.scheme?.lowercased() == "http" {
                    feedURL = parsed
                    var comps = URLComponents()
                    comps.scheme = parsed.scheme
                    comps.host = parsed.host
                    comps.port = parsed.port
                    comps.path = "/"
                    if let prefix = comps.string {
                        allowedDownloadPrefix = prefix
                    }
                    allowedNotesPrefix = nil
                    requireHTTPS = false
                } else if parsed.scheme?.lowercased() == "https" {
                    feedURL = parsed
                }
            }
            if let rawKey = environment["AGENTNOTCH_UPDATE_PUBKEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawKey.isEmpty,
               let decoded = UpdateSignature.decodePublicKey(base64: rawKey)
            {
                publicKey = decoded
            }
            #endif

            return Config(
                bundleURL: bundleURL,
                runningVersion: runningVersion,
                feedURL: feedURL,
                allowedDownloadPrefix: allowedDownloadPrefix,
                allowedNotesPrefix: allowedNotesPrefix,
                publicKey: publicKey,
                requireHTTPS: requireHTTPS,
                isDemo: false
            )
        }

        static func demo(version: AppVersion = AppVersion("0.7.0")!) -> Config {
            Config(
                bundleURL: URL(fileURLWithPath: "/Applications/AgentNotch.app"),
                runningVersion: version,
                feedURL: ReleaseFeed.defaultFeedURL,
                allowedDownloadPrefix: ReleaseFeed.defaultDownloadPrefix,
                allowedNotesPrefix: ReleaseFeed.defaultNotesPrefix,
                publicKey: UpdateKey.publicKey,
                requireHTTPS: true,
                isDemo: true
            )
        }
    }

    struct FeedResponse: Sendable {
        let data: Data
        let statusCode: Int
        let headers: [String: String]
    }

    struct Dependencies: Sendable {
        let fetchFeed: @Sendable (_ url: URL, _ userAgent: String, _ requireHTTPS: Bool) async throws -> FeedResponse
        let downloadFile: @Sendable (
            _ url: URL,
            _ destination: URL,
            _ userAgent: String,
            _ maxBytes: Int,
            _ expectedBytes: Int,
            _ requireHTTPS: Bool,
            _ onProgress: @escaping @Sendable (Double) -> Void
        ) async throws -> Void
        let downloadData: @Sendable (_ url: URL, _ userAgent: String, _ maxBytes: Int, _ requireHTTPS: Bool) async throws -> Data
        let installability: @Sendable (URL) -> BundleCheck.Installability
        let unzip: @Sendable (_ archive: URL, _ destination: URL) async throws -> URL
        let verifyCodeSign: @Sendable (_ bundleURL: URL) async -> Bool
        let stripQuarantine: @Sendable (_ bundleURL: URL) async -> Void
        let replaceBundle: @Sendable (_ target: URL, _ replacement: URL) throws -> Void
        let relaunch: @MainActor @Sendable (_ bundleURL: URL, _ version: AppVersion) throws -> Void

        static let live = Dependencies(
            fetchFeed: { try await UpdateTransport.fetchFeed(url: $0, userAgent: $1, requireHTTPS: $2) },
            downloadFile: { try await UpdateTransport.downloadFile(url: $0, destination: $1, userAgent: $2, maxBytes: $3, expectedBytes: $4, requireHTTPS: $5, onProgress: $6) },
            downloadData: { try await UpdateTransport.downloadData(url: $0, userAgent: $1, maxBytes: $2, requireHTTPS: $3) },
            installability: { BundleCheck.installability(for: $0) },
            unzip: { try await BundleCheck.unzip(archive: $0, into: $1) },
            verifyCodeSign: { await BundleCheck.verifyCodeSignature(at: $0) },
            stripQuarantine: { await BundleCheck.removeQuarantineIfPresent(at: $0) },
            replaceBundle: { try BundleCheck.replaceBundle(at: $0, with: $1) },
            relaunch: { try UpdateRelaunch.relaunch(bundleURL: $0, updatedTo: $1) }
        )
    }

    private(set) var state: UpdateState = .idle
    let config: Config
    private let deps: Dependencies
    private var activeTask: Task<Void, Never>?
    private var upToDateResetTask: Task<Void, Never>?

    var runningVersion: AppVersion? { config.runningVersion }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    var isInstalling: Bool {
        if case .installing = state { return true }
        return false
    }

    init(config: Config = .live(), dependencies: Dependencies = .live) {
        self.config = config
        self.deps = dependencies
    }

    static func demo() -> Updater {
        let bundled = BundleCheck.readInfo(at: Bundle.main.bundleURL)?.version
        return Updater(config: .demo(version: bundled ?? AppVersion("0.7.0")!))
    }

    func markUpdated(to version: AppVersion) {
        upToDateResetTask?.cancel()
        state = .updated(version: version, notesURL: ReleaseFeed.releaseNotesURL(for: version))
    }

    func popoverDidClose() {
        if case .updated = state {
            state = .idle
        }
    }

    func checkForUpdates() {
        guard !isBusy, !config.isDemo, let running = config.runningVersion else { return }
        upToDateResetTask?.cancel()
        state = .checking

        let cfg = config
        let deps = self.deps
        let userAgent = ReleaseFeed.userAgent(for: running)

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await deps.fetchFeed(cfg.feedURL, userAgent, cfg.requireHTTPS)
                if let httpError = ReleaseFeed.httpErrorMessage(statusCode: response.statusCode, headers: response.headers) {
                    self.state = .failed(reason: httpError, retryOffer: nil)
                    return
                }
                let release = try ReleaseFeed.decode(response.data)
                let decision = ReleaseFeed.decide(
                    release: release,
                    running: running,
                    allowedDownloadPrefix: cfg.allowedDownloadPrefix,
                    allowedNotesPrefix: cfg.allowedNotesPrefix,
                    requireHTTPS: cfg.requireHTTPS
                )
                switch decision {
                case .upToDate:
                    self.state = .upToDate
                    self.scheduleUpToDateReset()
                case .invalid(let reason):
                    self.state = .failed(reason: reason, retryOffer: nil)
                case .available(let offer):
                    switch deps.installability(cfg.bundleURL) {
                    case .inPlace:
                        self.state = .available(offer)
                    case .manual(let reason):
                        self.state = .manual(version: offer.version, notesURL: offer.releaseNotesURL, reason: reason)
                    }
                }
            } catch {
                self.state = .failed(reason: Self.describe(error), retryOffer: nil)
            }
        }
    }

    func install(_ offer: ReleaseFeed.UpdateOffer) {
        guard !isBusy, !config.isDemo, let running = config.runningVersion else { return }
        upToDateResetTask?.cancel()

        if case .manual(let reason) = deps.installability(config.bundleURL) {
            state = .manual(version: offer.version, notesURL: offer.releaseNotesURL, reason: reason)
            return
        }

        state = .downloading(0)
        let cfg = config
        let deps = self.deps
        let userAgent = ReleaseFeed.userAgent(for: running)

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var tempDir: URL?
            defer {
                if let tempDir {
                    try? FileManager.default.removeItem(at: tempDir)
                }
            }
            do {
                let staging = try FileManager.default.url(
                    for: .itemReplacementDirectory,
                    in: .userDomainMask,
                    appropriateFor: cfg.bundleURL,
                    create: true
                )
                tempDir = staging
                let zipURL = staging.appendingPathComponent("update.zip")
                let unpackedDir = staging.appendingPathComponent("unpacked", isDirectory: true)

                let lastPercent = PercentGate()
                try await deps.downloadFile(
                    offer.archiveURL,
                    zipURL,
                    userAgent,
                    ReleaseFeed.maxArchiveBytes,
                    offer.archiveSize,
                    cfg.requireHTTPS
                ) { [weak self] progress in
                    let pct = Int((min(1, max(0, progress)) * 100).rounded())
                    guard lastPercent.updateIfChanged(pct) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(Double(pct) / 100.0)
                    }
                }

                let sigData = try await deps.downloadData(
                    offer.signatureURL,
                    userAgent,
                    ReleaseFeed.maxSignatureBytes,
                    cfg.requireHTTPS
                )

                self.state = .installing

                // Verify, unpack, validate, strip quarantine, and swap off @MainActor.
                try await Task.detached(priority: .userInitiated) {
                    let archiveData = try Data(contentsOf: zipURL, options: .mappedIfSafe)
                    guard archiveData.count <= ReleaseFeed.maxArchiveBytes else {
                        throw UpdateFailure("Downloaded archive exceeds size limit")
                    }
                    guard UpdateSignature.verify(archive: archiveData, signatureData: sigData, publicKey: cfg.publicKey) else {
                        throw UpdateFailure("Update signature verification failed")
                    }
                    let extractedApp = try await deps.unzip(zipURL, unpackedDir)
                    switch BundleCheck.verifyCandidate(
                        at: extractedApp,
                        expectedVersion: offer.version,
                        runningVersion: running
                    ) {
                    case .valid:
                        break
                    case .invalid(let reason):
                        throw UpdateFailure(reason)
                    }
                    guard await deps.verifyCodeSign(extractedApp) else {
                        throw UpdateFailure("Downloaded app failed code signature check")
                    }
                    await deps.stripQuarantine(extractedApp)
                    try deps.replaceBundle(cfg.bundleURL, extractedApp)
                }.value

                if let staging = tempDir {
                    try? FileManager.default.removeItem(at: staging)
                    tempDir = nil
                }

                try deps.relaunch(cfg.bundleURL, offer.version)
            } catch {
                self.state = .failed(reason: Self.describe(error), retryOffer: offer)
            }
        }
    }

    func retry() {
        guard case .failed(_, let offer) = state else { return }
        if let offer {
            install(offer)
        } else {
            checkForUpdates()
        }
    }

    private func scheduleUpToDateReset() {
        upToDateResetTask?.cancel()
        upToDateResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, case .upToDate = self.state else { return }
            self.state = .idle
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let failure = error as? UpdateFailure {
            return failure.message
        }
        if let transfer = error as? UpdateTransferError {
            return transfer.message
        }
        return error.localizedDescription
    }
}

private struct UpdateFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private enum UpdateTransferError: Error {
    case disallowedURL
    case disallowedRedirect
    case exceededSizeLimit
    case httpStatus(Int)
    case missingResponse

    var message: String {
        switch self {
        case .disallowedURL: "Update URL is not allowed"
        case .disallowedRedirect: "Update redirect to insecure URL was blocked"
        case .exceededSizeLimit: "Update download exceeded size limit"
        case .httpStatus(let code): "Download failed with HTTP \(code)"
        case .missingResponse: "Invalid server response"
        }
    }
}

/// Coalesces download progress callbacks so SwiftUI only updates when the integer percent changes.
private final class PercentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func updateIfChanged(_ pct: Int) -> Bool {
        lock.withLock {
            guard pct != last else { return false }
            last = pct
            return true
        }
    }
}

/// Ephemeral URLSession transport created on demand only when the user clicks (R3, R4).
private enum UpdateTransport {
    private static func makeSession(delegate: URLSessionDelegate?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    static func fetchFeed(url: URL, userAgent: String, requireHTTPS: Bool) async throws -> Updater.FeedResponse {
        guard ReleaseFeed.isAllowedTransportURL(url, requireHTTPS: requireHTTPS) else {
            throw UpdateTransferError.disallowedURL
        }
        if url.isFileURL {
            let data = try readLocalFile(at: url, maxBytes: 1_048_576)
            return Updater.FeedResponse(data: data, statusCode: 200, headers: [:])
        }
        let guardDelegate = RedirectGuardDelegate(requireHTTPS: requireHTTPS)
        let session = makeSession(delegate: guardDelegate)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        if guardDelegate.blockedRedirect {
            throw UpdateTransferError.disallowedRedirect
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateTransferError.missingResponse
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            headers[String(describing: k)] = String(describing: v)
        }
        return Updater.FeedResponse(data: data, statusCode: http.statusCode, headers: headers)
    }

    static func downloadData(url: URL, userAgent: String, maxBytes: Int, requireHTTPS: Bool) async throws -> Data {
        guard ReleaseFeed.isAllowedTransportURL(url, requireHTTPS: requireHTTPS) else {
            throw UpdateTransferError.disallowedURL
        }
        if url.isFileURL {
            return try readLocalFile(at: url, maxBytes: maxBytes)
        }
        let guardDelegate = RedirectGuardDelegate(requireHTTPS: requireHTTPS)
        let session = makeSession(delegate: guardDelegate)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        if guardDelegate.blockedRedirect {
            throw UpdateTransferError.disallowedRedirect
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateTransferError.missingResponse
        }
        guard http.statusCode == 200 else {
            throw UpdateTransferError.httpStatus(http.statusCode)
        }
        guard data.count <= maxBytes else {
            throw UpdateTransferError.exceededSizeLimit
        }
        return data
    }

    static func downloadFile(
        url: URL,
        destination: URL,
        userAgent: String,
        maxBytes: Int,
        expectedBytes: Int,
        requireHTTPS: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard ReleaseFeed.isAllowedTransportURL(url, requireHTTPS: requireHTTPS) else {
            throw UpdateTransferError.disallowedURL
        }
        if url.isFileURL {
            let data = try readLocalFile(at: url, maxBytes: maxBytes)
            try data.write(to: destination, options: .atomic)
            onProgress(1.0)
            return
        }

        let delegate = FileDownloadDelegate(
            destination: destination,
            maxBytes: maxBytes,
            expectedBytes: expectedBytes,
            requireHTTPS: requireHTTPS,
            onProgress: onProgress
        )
        let session = makeSession(delegate: delegate)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        try await delegate.start(request: request, on: session)
    }

    private static func readLocalFile(at url: URL, maxBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maxBytes {
            throw UpdateTransferError.exceededSizeLimit
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else {
            throw UpdateTransferError.exceededSizeLimit
        }
        return data
    }
}

private final class RedirectGuardDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let requireHTTPS: Bool
    private let lock = NSLock()
    private var _blockedRedirect = false

    var blockedRedirect: Bool { lock.withLock { _blockedRedirect } }

    init(requireHTTPS: Bool) {
        self.requireHTTPS = requireHTTPS
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, ReleaseFeed.isAllowedTransportURL(url, requireHTTPS: requireHTTPS) else {
            lock.withLock { _blockedRedirect = true }
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }
}

private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let maxBytes: Int
    private let expectedBytes: Int
    private let requireHTTPS: Bool
    private let onProgress: @Sendable (Double) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var recordedError: (any Error)?
    private var didMoveFile = false

    init(
        destination: URL,
        maxBytes: Int,
        expectedBytes: Int,
        requireHTTPS: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) {
        self.destination = destination
        self.maxBytes = maxBytes
        self.expectedBytes = expectedBytes
        self.requireHTTPS = requireHTTPS
        self.onProgress = onProgress
    }

    func start(request: URLRequest, on session: URLSession) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            lock.withLock { self.continuation = cont }
            let task = session.downloadTask(with: request)
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, ReleaseFeed.isAllowedTransportURL(url, requireHTTPS: requireHTTPS) else {
            recordError(UpdateTransferError.disallowedRedirect)
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > Int64(maxBytes) || totalBytesExpectedToWrite > Int64(maxBytes) {
            recordError(UpdateTransferError.exceededSizeLimit)
            downloadTask.cancel()
            return
        }
        let denom = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(expectedBytes)
        if denom > 0 {
            onProgress(min(1.0, max(0.0, Double(totalBytesWritten) / Double(denom))))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            recordError(UpdateTransferError.httpStatus(http.statusCode))
            return
        }
        do {
            let values = try location.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, size > maxBytes {
                recordError(UpdateTransferError.exceededSizeLimit)
                return
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
            lock.withLock { didMoveFile = true }
            onProgress(1.0)
        } catch {
            recordError(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (cont, storedError, moved) = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, (any Error)?, Bool) in
            let c = continuation
            continuation = nil
            return (c, recordedError, didMoveFile)
        }
        guard let cont else { return }
        if let storedError {
            cont.resume(throwing: storedError)
        } else if let error {
            cont.resume(throwing: error)
        } else if !moved {
            cont.resume(throwing: UpdateTransferError.missingResponse)
        } else {
            cont.resume(returning: ())
        }
    }

    private func recordError(_ error: any Error) {
        lock.withLock {
            if recordedError == nil { recordedError = error }
        }
    }
}

/// D45: Detached shell helper that waits for this PID to exit, then relaunches the replaced bundle
/// with `--updated-to <version>`, and terminates the running app.
@MainActor
private enum UpdateRelaunch {
    static func relaunch(bundleURL: URL, updatedTo version: AppVersion) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        trap '' HUP
        pid="$1"; app="$2"; ver="$3"
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
          sleep 0.1
          i=$((i + 1))
        done
        sleep 0.2
        exec /usr/bin/open -n "$app" --args --updated-to "$ver"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "agentnotch-relaunch", String(pid), bundleURL.path, version.description]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }
}
