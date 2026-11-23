import Foundation

/// Wires the data flow from the plan:
/// - Claude Code: sessions-dir watcher → debounce → lister → store; projects-dir watcher → transcript tails → store
/// - Antigravity: ~/.gemini/antigravity* watcher → debounce → read-only SQLite reader → store;
///   brain/*/transcript.jsonl events → incremental tails (main sessions + subagents) → store
/// - A 5 s liveness sweep. Owns no UI.
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
    private let antigravityReader: AntigravityReader?
    private let antigravityWatchPaths: [String]
    private let probe: Probe
    private let transcriptLocator: TranscriptLocator
    private let transcriptModifiedAt: ModifiedAt
    private let debounceInterval: TimeInterval
    private let livenessInterval: TimeInterval
    private let isAlive: @Sendable (Int32) -> Bool
    /// Process facts for IDE window routing (D43).
    private let ideProbe: IDEDeepLink.Probe

    private var sessionsWatcher: FileWatcher?
    private var projectsWatcher: FileWatcher?
    private var antigravityWatcher: FileWatcher?
    private var debounceTask: Task<Void, Never>?
    private var antigravityDebounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    /// sessionId → transcript path, once located.
    private(set) var transcriptPaths: [String: URL] = [:]
    private var sessionIdByTranscriptPath: [String: String] = [:]
    /// Antigravity sessionId → expected transcript.jsonl URL (may not exist until first turn writes).
    private var antigravityTranscriptURLs: [String: URL] = [:]
    /// Resolved subagent transcript.jsonl path → (rootSessionId, subagent metadata).
    private var antigravitySubagentByPath: [String: (rootId: String, subagent: AntigravitySubagent)] = [:]
    private let transcripts = TranscriptReader()
    /// Back-off for Claude sessions whose transcript has not appeared yet (R7: no unbounded re-globbing).
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
        isAlive: @escaping @Sendable (Int32) -> Bool = ProcessProbe.isAlive,
        ideProbe: IDEDeepLink.Probe = .live,
        antigravityReader: AntigravityReader? = nil,
        antigravityWatchPaths: [String]? = nil
    ) {
        self.isAlive = isAlive
        self.ideProbe = ideProbe
        self.store = store
        self.lister = lister
        self.registry = RegistryReader(directory: sessionsDirectory)
        self.sessionsDirectory = sessionsDirectory
        self.projectsDirectory = projectsDirectory
        self.antigravityReader = antigravityReader
        self.antigravityWatchPaths = antigravityWatchPaths ?? (antigravityReader?.surfaces.map(\.directory.path) ?? [])
        self.probe = probe
        self.transcriptLocator = transcriptLocator ?? Monitor.locator(projectsDirectory: projectsDirectory)
        self.transcriptModifiedAt = transcriptModifiedAt
        self.debounceInterval = debounceInterval
        self.livenessInterval = livenessInterval
    }

    /// Production wiring under `~/.claude` (F2, F5) and `~/.gemini/antigravity*`.
    public convenience init(home: URL = FileManager.default.homeDirectoryForCurrentUser, store: SessionStore = SessionStore()) {
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        let sessions = claude.appendingPathComponent("sessions", isDirectory: true)
        let lister = SessionLister(command: AgentsCommand(), registry: RegistryReader(directory: sessions))
        let reader = AntigravityReader(home: home)
        let fm = FileManager.default
        let geminiDir = home.appendingPathComponent(".gemini", isDirectory: true)
        let surfacePaths = reader.surfaces.map(\.directory.path).filter { fm.fileExists(atPath: $0) }
        let watchPaths: [String] = if fm.fileExists(atPath: geminiDir.path) {
            [geminiDir.path]
        } else {
            surfacePaths
        }
        self.init(
            store: store,
            lister: lister,
            sessionsDirectory: sessions,
            projectsDirectory: claude.appendingPathComponent("projects", isDirectory: true),
            antigravityReader: reader,
            antigravityWatchPaths: watchPaths
        )
    }

    public func start() {
        let fm = FileManager.default
        if fm.fileExists(atPath: sessionsDirectory.path) {
            sessionsWatcher = FileWatcher(paths: [sessionsDirectory.path], latency: 0.1) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            sessionsWatcher?.start()
        }
        if fm.fileExists(atPath: projectsDirectory.path) {
            projectsWatcher = FileWatcher(paths: [projectsDirectory.path], latency: 0.1) { [weak self] paths in
                Task { @MainActor in self?.transcriptsChanged(paths) }
            }
            projectsWatcher?.start()
        }
        let existingAntigravityPaths = antigravityWatchPaths.filter { fm.fileExists(atPath: $0) }
        if antigravityReader != nil, !existingAntigravityPaths.isEmpty {
            antigravityWatcher = FileWatcher(paths: existingAntigravityPaths, latency: 0.1) { [weak self] paths in
                // Filter noisy logs/caches off the main actor so idle CPU stays near 0% (R7).
                var dbChanged = false
                var transcriptPaths: [String] = []
                for path in paths {
                    if Self.isAntigravityDatabasePath(path) {
                        dbChanged = true
                    } else if Self.isAntigravityTranscriptPath(path) {
                        transcriptPaths.append(path)
                    }
                }
                guard dbChanged || !transcriptPaths.isEmpty else { return }
                let changedTranscripts = transcriptPaths
                let needsDBRefresh = dbChanged
                Task { @MainActor in
                    if needsDBRefresh { self?.scheduleAntigravityRefresh() }
                    if !changedTranscripts.isEmpty { self?.antigravityTranscriptsChanged(changedTranscripts) }
                }
            }
            antigravityWatcher?.start()
        }
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
        antigravityWatcher?.stop(); antigravityWatcher = nil
        debounceTask?.cancel(); antigravityDebounceTask?.cancel(); retryTask?.cancel(); livenessTask?.cancel()
    }

    /// D43: one entry per session id; for a duplicate, prefer the process under a trusted IDE host.
    /// The host list is read once per source, and only when an id is duplicated.
    nonisolated static func dedupe(_ entries: [ListedSession], probe: IDEDeepLink.Probe) -> [ListedSession] {
        var hostsBySource: [Source: [IDEDeepLink.ExtensionHost]] = [:]
        return SessionDedupe.pick(entries, isCurrent: { entry in
            guard let pid = entry.pid else { return false }
            let source = Source.classify(executablePath: probe.executablePath(pid))
            guard IDEDeepLink.supports(source) else { return false }
            let hosts = hostsBySource[source] ?? IDEDeepLink.hosts(source: source, probe: probe)
            hostsBySource[source] = hosts
            return IDEDeepLink.locate(source: source, pid: pid, startedAt: entry.startedAt, hosts: hosts, probe: probe)?.trusted == true
        }, startTime: probe.startTime)
    }

    /// D43: remember the window of each live Claude IDE session whose host is trusted, so a click can
    /// still raise it after the session turns Done or its host stops being trusted. An untrusted
    /// read leaves the last remembered window in place. Off the main actor; runs per refresh only.
    private func rememberIDEWindows() async {
        let candidates = store.sessions.filter {
            $0.provider == .claude && $0.status != .done && $0.pid != nil && IDEDeepLink.supports($0.source)
        }.map { (id: $0.id, source: $0.source, pid: $0.pid, startedAt: $0.startedAt) }
        guard !candidates.isEmpty else { return }
        let probe = ideProbe
        let found = await Task.detached(priority: .utility) { () -> [(id: String, pid: Int32?, window: IDEWindow)] in
            var hostsBySource: [Source: [IDEDeepLink.ExtensionHost]] = [:]
            return candidates.compactMap { c in
                let hosts = hostsBySource[c.source] ?? IDEDeepLink.hosts(source: c.source, probe: probe)
                hostsBySource[c.source] = hosts
                guard let window = IDEDeepLink.locate(source: c.source, pid: c.pid, startedAt: c.startedAt, hosts: hosts, probe: probe)?.window
                else { return nil }
                return (c.id, c.pid, window)
            }
        }.value
        // A refresh may have moved the row to another process meanwhile; keep only current reads.
        for f in found where store.session(id: f.id)?.pid == f.pid { store.setIDEWindow(id: f.id, f.window) }
    }

    /// D23: the Claude registry changed → one Claude list refresh after 300 ms of quiet.
    func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.debounceInterval ?? 0.3))
            guard !Task.isCancelled else { return }
            await self?.refreshClaude()
        }
    }

    /// Antigravity SQLite DB/WAL changed → one Antigravity refresh after 300 ms of quiet.
    func scheduleAntigravityRefresh() {
        antigravityDebounceTask?.cancel()
        antigravityDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.debounceInterval ?? 0.3))
            guard !Task.isCancelled else { return }
            await self?.refreshAntigravity()
        }
    }

    /// Refresh both Claude Code and Antigravity independently so neither provider can clobber or
    /// block the other.
    public func refresh(now: Date = Date()) async {
        await refreshClaude(now: now)
        await refreshAntigravity(now: now)
    }

    /// Claude Code list → enrich (background mtimes, versions) → merge → probe new pids → locate transcripts.
    public func refreshClaude(now: Date = Date()) async {
        let result: ListResult
        do { result = try await lister.list(now: now) } catch { return }   // keep the last good list (R8)

        var knownVersions: [String: String] = [:]
        for session in store.sessions where session.provider == .claude {
            if let v = session.claudeVersion { knownVersions[session.id] = v }
        }
        let locator = transcriptLocator, modifiedAt = transcriptModifiedAt, registry = registry, isAlive = isAlive
        let ideProbe = ideProbe
        let enriched = await Task.detached(priority: .utility) { () -> [ListedSession] in
            // A crashed session's registry file can linger; a dead pid is never listed as live.
            let live = result.sessions.filter { $0.pid.map(isAlive) ?? true }
            return Monitor.dedupe(live, probe: ideProbe).map { entry in
                var e = entry
                if e.kind == .background, let url = locator(e.sessionId) { e.transcriptModifiedAt = modifiedAt(url) }
                if e.version == nil, let pid = e.pid {
                    e.version = knownVersions[e.sessionId] ?? registry.readOne(pid: pid, now: now)?.version
                }
                return e
            }
        }.value
        store.replaceList(enriched, provider: .claude, now: now)

        for session in store.sessions where session.provider == .claude && session.source == .unknown && session.status != .done {
            guard let pid = session.pid else { continue }
            let (source, tty) = probe(pid)
            store.setProbe(id: session.id, source: source, tty: tty)
        }
        await rememberIDEWindows()
        locateMissingTranscripts(now: now)

        if let retryAt = result.retryAt {
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, retryAt.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                await self?.refreshClaude()
            }
        }
    }

    /// Antigravity read-only SQLite snapshot → merge → attach main & subagent transcripts.
    public func refreshAntigravity(now: Date = Date()) async {
        guard let reader = antigravityReader else { return }
        let snapshot = await Task.detached(priority: .utility) {
            reader.read(now: now)
        }.value

        for entry in snapshot.sessions {
            if let url = entry.transcriptURL {
                antigravityTranscriptURLs[entry.sessionId] = url
            }
        }

        store.replaceList(snapshot.sessions, provider: .antigravity, now: now)
        locateMissingTranscripts(now: now)

        // Attach and sync Antigravity subagents grouped under their top-level conversations.
        var toRead: [(rootId: String, subagent: AntigravitySubagent)] = []
        for (rootId, subagents) in snapshot.subagentsByRootId {
            let dismissed = store.dismissedSubagentIds(sessionId: rootId)
            for sub in subagents where !dismissed.contains(sub.id) {
                let resolved = sub.transcriptURL.resolvingSymlinksInPath().path
                antigravitySubagentByPath[resolved] = (rootId, sub)
                toRead.append((rootId, sub))
            }
        }
        if !toRead.isEmpty {
            let pending = toRead
            Task { [transcripts, store] in
                for item in pending {
                    let update = await transcripts.readAntigravitySubagent(sessionId: item.rootId, subagent: item.subagent)
                    store.updateSubagent(sessionId: item.rootId, update: update, now: now)
                }
            }
        }
    }

    /// Locate transcripts for sessions not yet attached:
    /// - Claude: glob `~/.claude/projects/*/<sessionId>.jsonl` with exponential backoff (F5, R7).
    /// - Antigravity: check the known `brain/<conversationId>/.system_generated/logs/transcript.jsonl`.
    func locateMissingTranscripts(now: Date = Date()) {
        let fm = FileManager.default
        for session in store.sessions where transcriptPaths[session.id] == nil && session.status != .done {
            if session.provider == .antigravity {
                if let url = antigravityTranscriptURLs[session.id], fm.fileExists(atPath: url.path) {
                    track(sessionId: session.id, url: url, format: .antigravity)
                }
                continue
            }
            if let retryAt = locateRetryAt[session.id], now < retryAt { continue }
            guard let url = transcriptLocator(session.id) else {
                let attempts = (locateAttempts[session.id] ?? 0) + 1
                locateAttempts[session.id] = attempts
                locateRetryAt[session.id] = now.addingTimeInterval(min(5 * pow(2, Double(attempts - 1)), 60))
                continue
            }
            track(sessionId: session.id, url: url, format: .claude)
        }
    }

    private func track(sessionId: String, url: URL, format: TranscriptFormat) {
        locateAttempts[sessionId] = nil
        locateRetryAt[sessionId] = nil
        transcriptPaths[sessionId] = url
        sessionIdByTranscriptPath[url.resolvingSymlinksInPath().path] = sessionId
        transcriptAttached(sessionId: sessionId, url: url, format: format)
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
        for id in antigravityTranscriptURLs.keys where !live.contains(id) {
            antigravityTranscriptURLs[id] = nil
        }
        antigravitySubagentByPath = antigravitySubagentByPath.filter { live.contains($0.value.rootId) }
    }

    // MARK: - Transcripts (M3)

    func transcriptAttached(sessionId: String, url: URL, format: TranscriptFormat = .claude) {
        Task { [transcripts, store] in
            if let update = await transcripts.attach(sessionId: sessionId, url: url, format: format) {
                store.updateTranscript(id: sessionId, update: update)
            }
            guard format == .claude else { return }
            // D33: Claude subagents already running when the session (or the app) was first seen.
            let running = await transcripts.scanSubagents(sessionId: sessionId, directory: SubagentFiles.directory(forTranscript: url), now: Date())
            for update in running { store.updateSubagent(sessionId: sessionId, update: update, now: Date()) }
        }
    }

    /// Projects-dir file events → `readNew` for the Claude sessions whose transcript changed. A path that
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
            if transcriptPaths[candidate] == nil, let session = store.session(id: candidate),
               session.provider == .claude, session.status != .done
            {
                track(sessionId: candidate, url: URL(fileURLWithPath: path), format: .claude)
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

    /// Antigravity `brain/<id>/.system_generated/logs/transcript.jsonl` events → incremental tail
    /// reads for both main sessions and subagents.
    func antigravityTranscriptsChanged(_ paths: [String]) {
        var mainIds = Set<String>()
        var subagents: [(rootId: String, subagent: AntigravitySubagent)] = []
        var sawUnknown = false

        for rawPath in paths {
            let resolved = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
            if let id = sessionIdByTranscriptPath[resolved] ?? sessionIdByTranscriptPath[rawPath] {
                mainIds.insert(id)
                continue
            }
            if let entry = antigravitySubagentByPath[resolved] ?? antigravitySubagentByPath[rawPath] {
                if !subagents.contains(where: { $0.rootId == entry.rootId && $0.subagent.id == entry.subagent.id }) {
                    subagents.append(entry)
                }
                continue
            }
            if let convId = Self.antigravityConversationId(fromTranscriptPath: rawPath),
               let session = store.session(id: convId), session.provider == .antigravity, session.status != .done
            {
                track(sessionId: convId, url: URL(fileURLWithPath: rawPath), format: .antigravity)
            } else {
                sawUnknown = true
            }
        }

        if sawUnknown { scheduleAntigravityRefresh() }
        guard !mainIds.isEmpty || !subagents.isEmpty else { return }
        Task { [transcripts, store] in
            for id in mainIds {
                guard let update = await transcripts.readNew(sessionId: id) else { continue }
                store.updateTranscript(id: id, update: update)
            }
            for item in subagents {
                let update = await transcripts.readAntigravitySubagent(sessionId: item.rootId, subagent: item.subagent)
                store.updateSubagent(sessionId: item.rootId, update: update, now: Date())
            }
        }
    }

    nonisolated static func isAntigravityDatabasePath(_ path: String) -> Bool {
        path.hasSuffix("/conversation_summaries.db")
            || path.hasSuffix("/conversation_summaries.db-wal")
            || path.hasSuffix("/conversation_summaries.db-shm")
    }

    nonisolated static func isAntigravityTranscriptPath(_ path: String) -> Bool {
        path.hasSuffix("/.system_generated/logs/transcript.jsonl")
    }

    nonisolated static func antigravityConversationId(fromTranscriptPath path: String) -> String? {
        guard isAntigravityTranscriptPath(path) else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 5 else { return nil }
        let brainIdx = components.count - 5
        guard components[brainIdx] == "brain" else { return nil }
        let id = components[brainIdx + 1]
        return id.isEmpty ? nil : id
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

    func attach(sessionId: String, url: URL, format: TranscriptFormat = .claude) -> TranscriptUpdate? {
        let tail = TranscriptTail(path: url, format: format)
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

    /// Meta plus new transcript lines of one Claude subagent; the first read scans its whole transcript.
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

    /// Metadata plus incremental transcript read for one Antigravity subagent.
    func readAntigravitySubagent(sessionId: String, subagent: AntigravitySubagent) -> SubagentUpdate {
        let parentId = subagent.parentId == sessionId ? nil : subagent.parentId
        var update = SubagentUpdate(
            agentId: subagent.id,
            agentType: subagent.agentType,
            description: subagent.description,
            parentId: parentId,
            spawnDepth: subagent.spawnDepth,
            finished: subagent.finished,
            startedAt: subagent.startedAt,
            lastWriteAt: subagent.lastWriteAt
        )
        let url = subagent.transcriptURL
        if let tail = subagentTails[sessionId]?[subagent.id] {
            update.transcript = try? tail.readNew()
            if let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                update.lastWriteAt = max(subagent.lastWriteAt, mtime)
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            let tail = TranscriptTail(path: url, format: .antigravity)
            subagentTails[sessionId, default: [:]][subagent.id] = tail
            update.transcript = try? tail.attachFromStart()
            if let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                update.lastWriteAt = max(subagent.lastWriteAt, mtime)
            }
        }
        return update
    }

    /// Unfinished Claude subagents whose transcripts moved within `subagentAttachWindow`.
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
