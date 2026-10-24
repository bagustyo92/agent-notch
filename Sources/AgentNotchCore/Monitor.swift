import Foundation

/// Wires the data flow from the plan: sessions-dir watcher → debounce → lister → store;
/// projects-dir watcher → transcript tails → store; a 5 s liveness sweep. Owns no UI.
@MainActor
public final class Monitor {
    public typealias Probe = @Sendable (Int32) -> (Source, String?)
    public typealias TranscriptLocator = @Sendable (String) -> URL?
    public typealias ModifiedAt = @Sendable (URL) -> Date?

    public let store: SessionStore
    private let lister: SessionLister
    private let registry: RegistryReader
    private let sessionsDirectory: URL
    private let projectsDirectory: URL
    private let probe: Probe
    private let transcriptLocator: TranscriptLocator
    private let transcriptModifiedAt: ModifiedAt
    private let debounceInterval: TimeInterval
    private let livenessInterval: TimeInterval
    private let isAlive: @Sendable (Int32) -> Bool

    private var sessionsWatcher: FileWatcher?
    private var projectsWatcher: FileWatcher?
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    /// sessionId → transcript path, once located.
    private(set) var transcriptPaths: [String: URL] = [:]
    private var sessionIdByTranscriptPath: [String: String] = [:]
    private let transcripts = TranscriptReader()
    /// Back-off for sessions whose transcript has not appeared yet (R7: no unbounded re-globbing).
    private var locateRetryAt: [String: Date] = [:]
    private var locateAttempts: [String: Int] = [:]

    public init(
        store: SessionStore,
        lister: SessionLister,
        sessionsDirectory: URL,
        projectsDirectory: URL,
        probe: @escaping Probe = { pid in (ProcessProbe.source(forPid: pid), ProcessProbe.tty(pid)) },
        transcriptLocator: TranscriptLocator? = nil,
        transcriptModifiedAt: @escaping ModifiedAt = Monitor.modificationDate,
        debounceInterval: TimeInterval = 0.3,
        livenessInterval: TimeInterval = 5,
        isAlive: @escaping @Sendable (Int32) -> Bool = ProcessProbe.isAlive
    ) {
        self.isAlive = isAlive
        self.store = store
        self.lister = lister
        self.registry = RegistryReader(directory: sessionsDirectory)
        self.sessionsDirectory = sessionsDirectory
        self.projectsDirectory = projectsDirectory
        self.probe = probe
        self.transcriptLocator = transcriptLocator ?? Monitor.locator(projectsDirectory: projectsDirectory)
        self.transcriptModifiedAt = transcriptModifiedAt
        self.debounceInterval = debounceInterval
        self.livenessInterval = livenessInterval
    }

    /// Production wiring under `~/.claude` (F2, F5).
    public convenience init(home: URL = FileManager.default.homeDirectoryForCurrentUser, store: SessionStore = SessionStore()) {
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        let sessions = claude.appendingPathComponent("sessions", isDirectory: true)
        let lister = SessionLister(command: AgentsCommand(), registry: RegistryReader(directory: sessions))
        self.init(store: store, lister: lister, sessionsDirectory: sessions,
                  projectsDirectory: claude.appendingPathComponent("projects", isDirectory: true))
    }

    public func start() {
        sessionsWatcher = FileWatcher(paths: [sessionsDirectory.path], latency: 0.1) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        sessionsWatcher?.start()
        projectsWatcher = FileWatcher(paths: [projectsDirectory.path], latency: 0.1) { [weak self] paths in
            Task { @MainActor in self?.transcriptsChanged(paths) }
        }
        projectsWatcher?.start()
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.livenessInterval ?? 5))
                guard let self, !Task.isCancelled else { return }
                self.store.checkLiveness(now: Date(), isAlive: self.isAlive)
                self.store.dropStaleSubagents(now: Date())
                self.locateMissingTranscripts()
                self.pruneTranscripts()
            }
        }
        Task { await refresh() }
    }

    public func stop() {
        sessionsWatcher?.stop(); sessionsWatcher = nil
        projectsWatcher?.stop(); projectsWatcher = nil
        debounceTask?.cancel(); retryTask?.cancel(); livenessTask?.cancel()
    }

    /// D23: the registry changed → one list refresh after 300 ms of quiet.
    func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.debounceInterval ?? 0.3))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// List → enrich (background mtimes, versions) → merge → probe new pids → locate transcripts.
    public func refresh(now: Date = Date()) async {
        let result: ListResult
        do { result = try await lister.list(now: now) } catch { return }   // keep the last good list (R8)

        var knownVersions: [String: String] = [:]
        for session in store.sessions { if let v = session.claudeVersion { knownVersions[session.id] = v } }
        let locator = transcriptLocator, modifiedAt = transcriptModifiedAt, registry = registry, isAlive = isAlive
        let enriched = await Task.detached(priority: .utility) { () -> [ListedSession] in
            // A crashed session's registry file can linger; a dead pid is never listed as live.
            result.sessions.filter { $0.pid.map(isAlive) ?? true }.map { entry in
                var e = entry
                if e.kind == .background, let url = locator(e.sessionId) { e.transcriptModifiedAt = modifiedAt(url) }
                if e.version == nil, let pid = e.pid {
                    e.version = knownVersions[e.sessionId] ?? registry.readOne(pid: pid, now: now)?.version
                }
                return e
            }
        }.value
        store.replaceList(enriched, now: now)

        for session in store.sessions where session.source == .unknown && session.status != .done {
            guard let pid = session.pid else { continue }
            let (source, tty) = probe(pid)
            store.setProbe(id: session.id, source: source, tty: tty)
        }
        locateMissingTranscripts()

        if let retryAt = result.retryAt {
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, retryAt.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    /// F5: glob `~/.claude/projects/*/<sessionId>.jsonl` for sessions that have no transcript yet.
    /// A miss backs off 5 s, 10 s, 20 s, 40 s, then every 60 s; the projects watcher also attaches a
    /// transcript the moment its file appears, so the back-off is only a safety net.
    func locateMissingTranscripts(now: Date = Date()) {
        for session in store.sessions where transcriptPaths[session.id] == nil && session.status != .done {
            if let retryAt = locateRetryAt[session.id], now < retryAt { continue }
            guard let url = transcriptLocator(session.id) else {
                let attempts = (locateAttempts[session.id] ?? 0) + 1
                locateAttempts[session.id] = attempts
                locateRetryAt[session.id] = now.addingTimeInterval(min(5 * pow(2, Double(attempts - 1)), 60))
                continue
            }
            track(sessionId: session.id, url: url)
        }
    }

    private func track(sessionId: String, url: URL) {
        locateAttempts[sessionId] = nil
        locateRetryAt[sessionId] = nil
        transcriptPaths[sessionId] = url
        sessionIdByTranscriptPath[url.resolvingSymlinksInPath().path] = sessionId
        transcriptAttached(sessionId: sessionId, url: url)
    }

    /// Forget tails of sessions the store has dropped.
    func pruneTranscripts() {
        let live = Set(store.sessions.map(\.id))
        for (id, url) in transcriptPaths where !live.contains(id) {
            transcriptPaths[id] = nil
            sessionIdByTranscriptPath[url.resolvingSymlinksInPath().path] = nil
            Task { await transcripts.detach(sessionId: id) }
        }
        for id in transcriptPaths.keys {
            let dismissed = store.dismissedSubagentIds(sessionId: id)
            if !dismissed.isEmpty { Task { await transcripts.dropSubagents(sessionId: id, agentIds: dismissed) } }
        }
        for id in locateRetryAt.keys where !live.contains(id) {
            locateRetryAt[id] = nil
            locateAttempts[id] = nil
        }
    }

    // MARK: - Transcripts (M3)

    func transcriptAttached(sessionId: String, url: URL) {
        Task { [transcripts, store] in
            if let update = await transcripts.attach(sessionId: sessionId, url: url) {
                store.updateTranscript(id: sessionId, update: update)
            }
            // D33: subagents already running when the session (or the app) was first seen.
            let running = await transcripts.scanSubagents(sessionId: sessionId, directory: SubagentFiles.directory(forTranscript: url), now: Date())
            for update in running { store.updateSubagent(sessionId: sessionId, update: update, now: Date()) }
        }
    }

    /// Projects-dir file events → `readNew` for the sessions whose transcript changed. A path that
    /// is not tracked yet but is named `<known sessionId>.jsonl` is a transcript that just appeared.
    func transcriptsChanged(_ paths: [String]) {
        var ids = Set<String>()
        var agents: [(sessionId: String, agentId: String, directory: URL)] = []
        for path in paths {
            if let id = sessionIdByTranscriptPath[path] { ids.insert(id); continue }
            if let sub = SubagentFiles.parse(path: path) {
                if let session = store.session(id: sub.sessionId), session.status != .done,
                   !agents.contains(where: { $0.sessionId == sub.sessionId && $0.agentId == sub.agentId }) { agents.append(sub) }
                continue
            }
            guard path.hasSuffix(".jsonl") else { continue }
            let candidate = String((path as NSString).lastPathComponent.dropLast(6))
            if transcriptPaths[candidate] == nil, let session = store.session(id: candidate), session.status != .done {
                track(sessionId: candidate, url: URL(fileURLWithPath: path))
            }
        }
        guard !ids.isEmpty || !agents.isEmpty else { return }
        Task { [transcripts, store] in
            for id in ids {
                guard let update = await transcripts.readNew(sessionId: id) else { continue }
                store.updateTranscript(id: id, update: update)
            }
            for sub in agents {
                let update = await transcripts.readSubagent(sessionId: sub.sessionId, agentId: sub.agentId, directory: sub.directory)
                store.updateSubagent(sessionId: sub.sessionId, update: update, now: Date())
            }
        }
    }

    // MARK: - Defaults

    public static func locator(projectsDirectory: URL) -> TranscriptLocator {
        { sessionId in
            guard !sessionId.isEmpty, !sessionId.contains("/"), !sessionId.contains("..") else { return nil }
            let fm = FileManager.default
            guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDirectory.path) else { return nil }
            for dir in dirs {
                let candidate = projectsDirectory.appendingPathComponent(dir).appendingPathComponent("\(sessionId).jsonl")
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
            return nil
        }
    }

    public static let modificationDate: ModifiedAt = { url in
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Owns every `TranscriptTail` so all transcript IO happens off the main actor.
actor TranscriptReader {
    private var tails: [String: TranscriptTail] = [:]
    /// sessionId → agentId → tail of that subagent's transcript.
    private var subagentTails: [String: [String: TranscriptTail]] = [:]
    /// A subagent seen at attach time counts only if its transcript moved this recently.
    static let subagentAttachWindow: TimeInterval = 1800

    func attach(sessionId: String, url: URL) -> TranscriptUpdate? {
        let tail = TranscriptTail(path: url)
        tails[sessionId] = tail
        return try? tail.attach()
    }

    func readNew(sessionId: String) -> TranscriptUpdate? {
        guard let tail = tails[sessionId] else { return nil }
        return try? tail.readNew()
    }

    func detach(sessionId: String) {
        tails[sessionId] = nil
        subagentTails[sessionId] = nil
    }

    /// Meta plus new transcript lines of one subagent; the first read scans its whole transcript.
    func readSubagent(sessionId: String, agentId: String, directory: URL) -> SubagentUpdate {
        var update = SubagentFiles.readMeta(directory, agentId: agentId)
        if let tail = subagentTails[sessionId]?[agentId] {
            update.transcript = try? tail.readNew()
        } else if update.lastWriteAt != nil {
            let tail = TranscriptTail(path: SubagentFiles.transcript(directory, agentId: agentId), includeSidechain: true)
            subagentTails[sessionId, default: [:]][agentId] = tail
            update.transcript = try? tail.attachFromStart()
        }
        return update
    }

    /// Unfinished subagents whose transcripts moved within `subagentAttachWindow`.
    func scanSubagents(sessionId: String, directory: URL, now: Date) -> [SubagentUpdate] {
        SubagentFiles.agentIds(in: directory).compactMap { agentId in
            let meta = SubagentFiles.readMeta(directory, agentId: agentId)
            guard !meta.finished, let at = meta.lastWriteAt, now.timeIntervalSince(at) < Self.subagentAttachWindow else { return nil }
            return readSubagent(sessionId: sessionId, agentId: agentId, directory: directory)
        }
    }

    func dropSubagents(sessionId: String, agentIds: Set<String>) {
        for id in agentIds { subagentTails[sessionId]?[id] = nil }
    }
}
