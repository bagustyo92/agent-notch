import Foundation

/// D44: click routing for Claude Code sessions running inside Orca (F30, F32).
///
/// Invokes Orca's documented CLI (`orca`) **only on click**, never on a refresh or timer (R7),
/// always with `--environment local` and stripped `ORCA_*` environment variables so AgentNotch
/// never redirects to or wakes a remote host (R1, R3).
public enum OrcaFocus {
    public static let defaultTimeout: TimeInterval = 5

    /// One live terminal reported by `orca terminal list --environment local --json` (F32).
    public struct TerminalEntry: Sendable, Equatable {
        public var handle: String
        public var worktreePath: String
        public var connected: Bool
        public var orphaned: Bool
        public var executionHostId: String

        public init(handle: String, worktreePath: String, connected: Bool, orphaned: Bool, executionHostId: String) {
            self.handle = handle
            self.worktreePath = worktreePath
            self.connected = connected
            self.orphaned = orphaned
            self.executionHostId = executionHostId
        }
    }

    /// Result of routing a click on an `.orca` session row.
    public enum Route: Sendable, Equatable {
        /// Focused a unique live Orca terminal pane via `orca terminal switch`.
        case terminalSwitch(handle: String)
        /// Activated the enclosing git worktree via `orca worktree activate`.
        case worktreeActivate
        /// Could not target a pane or worktree; caller shows an inline notice after app activation.
        case fallback
    }

    public typealias Runner = @Sendable (
        _ executable: URL,
        _ arguments: [String],
        _ currentDirectory: URL?,
        _ environment: [String: String],
        _ timeout: TimeInterval
    ) async throws -> Data

    /// Candidate locations for the `orca` binary in priority order, because LaunchServices / Finder
    /// launches carry a minimal `PATH`.
    public static func locateExecutable(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemPaths: [String] = [
            "/Applications/Orca.app/Contents/Resources/bin/orca",
            "/usr/local/bin/orca",
            "/opt/homebrew/bin/orca",
        ]
    ) -> URL? {
        let fm = FileManager.default
        let appSystem = systemPaths.filter { $0.contains("/Orca.app/") }.map { URL(fileURLWithPath: $0) }
        let otherSystem = systemPaths.filter { !$0.contains("/Orca.app/") }.map { URL(fileURLWithPath: $0) }
        let userApp = home.appendingPathComponent("Applications/Orca.app/Contents/Resources/bin/orca")
        let candidates = appSystem + [userApp] + otherSystem
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Strip inherited `ORCA_*` environment variables so AgentNotch's own launch environment cannot
    /// redirect or wake a remote host (R1, R3), and disable ANSI colour escapes.
    public static func sanitizedEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var cleaned = env.filter { !$0.key.uppercased().hasPrefix("ORCA_") }
        cleaned["NO_COLOR"] = "1"
        return cleaned
    }

    /// Tolerant JSON decoder for `orca terminal list --environment local --json`.
    /// Returns `[]` on malformed data or `ok == false` (R8).
    public static func decodeTerminals(_ data: Data) -> [TerminalEntry] {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = raw as? [String: Any] else { return [] }
        if let ok = dict["ok"] as? Bool, !ok { return [] }
        let array: [Any]
        if let result = dict["result"] as? [String: Any], let terminals = result["terminals"] as? [Any] {
            array = terminals
        } else if let terminals = dict["terminals"] as? [Any] {
            array = terminals
        } else {
            return []
        }
        return array.compactMap { item in
            guard let entry = item as? [String: Any],
                  let handle = entry["handle"] as? String, !handle.isEmpty,
                  let worktreePath = entry["worktreePath"] as? String, !worktreePath.isEmpty
            else { return nil }
            let connected = entry["connected"] as? Bool ?? false
            let orphaned = entry["orphaned"] as? Bool ?? true
            let executionHostId = entry["executionHostId"] as? String ?? ""
            return TerminalEntry(
                handle: handle,
                worktreePath: worktreePath,
                connected: connected,
                orphaned: orphaned,
                executionHostId: executionHostId
            )
        }
    }

    /// True when JSON output is an object with `ok == true`.
    public static func isOkJSON(_ data: Data) -> Bool {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = raw as? [String: Any] else { return false }
        return (dict["ok"] as? Bool) == true
    }

    /// Return the terminal handle only when **exactly one** live, local, connected, non-orphaned
    /// terminal matches the deepest `worktreePath` enclosing (or equal to) `cwd`. Fails closed on
    /// ambiguity (0 or 2+ matches).
    public static func uniqueTerminalHandle(forCwd cwd: String, in terminals: [TerminalEntry]) -> String? {
        let target = canonicalPath(cwd)
        guard !target.isEmpty else { return nil }
        let matches: [(entry: TerminalEntry, root: String)] = terminals.compactMap { entry in
            guard entry.executionHostId == "local", entry.connected, !entry.orphaned else { return nil }
            let root = canonicalPath(entry.worktreePath)
            guard !root.isEmpty, path(target, isInsideOrEqual: root) else { return nil }
            return (entry, root)
        }
        guard let deepestLength = matches.map(\.root.count).max() else { return nil }
        let deepest = matches.filter { $0.root.count == deepestLength }
        return deepest.count == 1 ? deepest[0].entry.handle : nil
    }

    /// Tiered on-click routing for `.orca` sessions (D44):
    /// 1. Live Orca Terminal (`isLive && tty != nil`): switch to the unique matching terminal pane.
    /// 2. Orca Chat (`tty == nil`), Done Orca rows (`!isLive`), or terminal fallback: activate the
    ///    enclosing local git worktree via `orca worktree activate`.
    /// 3. Fallback when neither succeeds.
    public static func focus(
        cwd: String,
        tty: String?,
        isLive: Bool,
        executable: URL? = OrcaFocus.locateExecutable(),
        timeout: TimeInterval = defaultTimeout,
        environment: [String: String] = OrcaFocus.sanitizedEnvironment(),
        directoryExists: @Sendable (String) -> Bool = OrcaFocus.isExistingDirectory,
        run: Runner? = nil
    ) async -> Route {
        guard let executable else { return .fallback }
        let execute: Runner = run ?? { executable, arguments, currentDirectory, environment, timeout in
            try await ProcessRunner.capture(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                environment: environment,
                timeout: timeout
            )
        }
        let cleanEnv = sanitizedEnvironment(environment)
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)

        if isLive, let tty, !tty.isEmpty, !trimmedCwd.isEmpty {
            if let listData = try? await execute(
                executable,
                ["terminal", "list", "--environment", "local", "--json"],
                nil,
                cleanEnv,
                timeout
            ) {
                let terminals = decodeTerminals(listData)
                if let handle = uniqueTerminalHandle(forCwd: trimmedCwd, in: terminals),
                   let switchData = try? await execute(
                       executable,
                       ["terminal", "switch", "--environment", "local", "--terminal", handle, "--json"],
                       nil,
                       cleanEnv,
                       timeout
                   ),
                   isOkJSON(switchData)
                {
                    return .terminalSwitch(handle: handle)
                }
            }
        }

        guard !trimmedCwd.isEmpty, directoryExists(trimmedCwd) else { return .fallback }
        if let activateData = try? await execute(
            executable,
            ["worktree", "activate", "--environment", "local", "--worktree", "current", "--json"],
            URL(fileURLWithPath: trimmedCwd),
            cleanEnv,
            timeout
        ), isOkJSON(activateData) {
            return .worktreeActivate
        }

        return .fallback
    }

    /// Value printed in `--dump`'s `link=` column for `.orca` rows (never raw `cwd`, R6).
    public static func dumpLink(cwd: String, tty: String?, isLive: Bool) -> String {
        guard !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "-" }
        if isLive, let tty, !tty.isEmpty { return "orca:terminal" }
        return "orca:worktree"
    }

    public static func isExistingDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func canonicalPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var resolved = URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().standardizedFileURL.path
        while resolved.count > 1, resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }

    private static func path(_ cwd: String, isInsideOrEqual root: String) -> Bool {
        if cwd == root { return true }
        if root == "/" { return cwd.hasPrefix("/") }
        return cwd.hasPrefix(root + "/")
    }
}
