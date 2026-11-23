import Darwin
import Foundation

extension Source {
    /// F4, F30: the executable path tells the sources apart; `entrypoint` cannot (F3).
    /// Terminal sessions resolve to `~/.local/share/claude/versions/<ver>` (V2) because
    /// `~/.local/bin/claude` is a symlink; both spellings count, as does a Homebrew install.
    /// Orca runs that same CLI binary under `Orca.app` (Chat) or `Orca Agents.app` (Terminal).
    public static func classify(executablePath path: String?, ancestorPaths: [String] = []) -> Source {
        guard let path, !path.isEmpty else { return .unknown }
        if path.contains("/.cursor/extensions/") { return .cursor }
        if path.contains("/.vscode/extensions/") || path.contains("/.vscode-insiders/extensions/") { return .vscode }
        if path.contains("/.local/share/claude/versions/") || path.hasSuffix("/.local/bin/claude") || path.hasSuffix("/bin/claude") {
            if ancestorPaths.contains(where: { $0.contains("/Orca.app/") || $0.contains("/Orca Agents.app/") }) {
                return .orca
            }
            return .terminal
        }
        return .unknown
    }

    /// Classify an Antigravity process host from its executable path, ancestor chain, tty and
    /// fallback app-data surface directory name.
    public static func classifyAntigravity(
        executablePath path: String?,
        ancestorPaths: [String] = [],
        tty: String? = nil,
        appDataDirName: String? = nil
    ) -> Source {
        let allPaths = ([path].compactMap { $0 }) + ancestorPaths
        for candidate in allPaths {
            if candidate.contains("/Orca.app/") || candidate.contains("/Orca Agents.app/") { return .orca }
            if candidate.contains("/Cursor.app/") || candidate.contains("/.cursor/extensions/") { return .cursor }
            if candidate.contains("/Visual Studio Code.app/") || candidate.contains("/Visual Studio Code - Insiders.app/")
                || candidate.contains("/.vscode/extensions/") || candidate.contains("/.vscode-insiders/extensions/")
            {
                return .vscode
            }
            if candidate.contains("/Antigravity.app/") || candidate.contains("/Antigravity IDE.app/") { return .antigravityIDE }
            if candidate.contains("/Gemini.app/") { return .antigravityApp }
            if candidate.contains("/Terminal.app/") || candidate.contains("/iTerm.app/")
                || candidate.contains("/Ghostty.app/") || candidate.contains("/WezTerm.app/")
            {
                return .terminal
            }
        }
        if let tty, !tty.isEmpty { return .terminal }
        switch appDataDirName {
        case "antigravity": return .antigravityApp
        case "antigravity-ide": return .antigravityIDE
        default: return .unknown
        }
    }
}

/// Live Antigravity process facts associated with a conversation id.
public struct AntigravityProcessInfo: Sendable, Equatable {
    public var pid: Int32
    public var executablePath: String
    public var source: Source
    public var tty: String?
    public var startedAt: Date?

    public init(pid: Int32, executablePath: String, source: Source, tty: String? = nil, startedAt: Date? = nil) {
        self.pid = pid
        self.executablePath = executablePath
        self.source = source
        self.tty = tty
        self.startedAt = startedAt
    }
}

/// Read-only process facts (R1): liveness, executable path, controlling tty, and open paths.
public enum ProcessProbe {
    /// `kill(pid, 0)`: 0 or EPERM means the process exists.
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// `proc_pidpath`, the real file (symlinks resolved). Nil when the process is gone.
    public static func executablePath(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        let len = buffer.prefix(Int(n)).firstIndex(of: 0) ?? Int(n)
        return String(decoding: buffer.prefix(len), as: UTF8.self)
    }

    /// Controlling terminal name such as `ttys003`, used by the Terminal focus script (D25).
    public static func tty(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard n == size, info.e_tdev != UInt32.max, info.e_tdev != 0 else { return nil }
        guard let name = devname(dev_t(bitPattern: info.e_tdev), mode_t(S_IFCHR)) else { return nil }
        return String(cString: name)
    }

    /// Parent pid from `proc_pidinfo`, falling back to `KERN_PROC_PID` so ancestor walks can cross
    /// setuid-root intermediaries like `/usr/bin/login` in Orca Terminal panes (F30).
    public static func parentPid(_ pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            return Int32(bitPattern: info.pbi_ppid)
        }
        var kp = kinfo_proc()
        var ksize = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &ksize, nil, 0) == 0, ksize == MemoryLayout<kinfo_proc>.size else { return nil }
        return kp.kp_eproc.e_ppid
    }

    /// Start time from `proc_pidinfo`; tells a session's process apart from a later one that
    /// reused its pid.
    public static func startTime(_ pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// argv[0] from KERN_PROCARGS2. Electron helpers write their title there, which is how the IDE
    /// window id is found. Only argv[0] is read, never later arguments or the environment block.
    public static func processTitle(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var index = MemoryLayout<Int32>.size                        // skip argc
        while index < size, buffer[index] != 0 { index += 1 }       // exec path
        while index < size, buffer[index] == 0 { index += 1 }       // padding
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }       // argv[0]
        guard index > start else { return nil }
        return String(decoding: buffer[start..<index], as: UTF8.self)
    }

    /// Walk `parentPid` up to `maxDepth` hops (stopping at PID <= 1 or a cycle) and collect each
    /// ancestor's executable path (F30).
    public static func ancestorExecutablePaths(_ pid: Int32, maxDepth: Int = 16) -> [String] {
        ancestorExecutablePaths(pid, maxDepth: maxDepth, parentPid: parentPid, executablePath: executablePath)
    }

    static func ancestorExecutablePaths(
        _ pid: Int32,
        maxDepth: Int = 16,
        parentPid: (Int32) -> Int32?,
        executablePath: (Int32) -> String?
    ) -> [String] {
        guard pid > 1, maxDepth > 0 else { return [] }
        var paths: [String] = []
        var seen: Set<Int32> = [pid]
        var current = pid
        for _ in 0..<maxDepth {
            guard let parent = parentPid(current), parent > 1, seen.insert(parent).inserted else { break }
            if let exe = executablePath(parent) { paths.append(exe) }
            current = parent
        }
        return paths
    }

    public static func source(forPid pid: Int32) -> Source {
        let path = executablePath(pid)
        let initial = Source.classify(executablePath: path)
        guard initial == .terminal else { return initial }
        return Source.classify(executablePath: path, ancestorPaths: ancestorExecutablePaths(pid))
    }

    /// Every pid on the system (`proc_listallpids`), used to find IDE hosts and Antigravity processes.
    public static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 }
    }

    /// True for Antigravity executables (`agy`, Gemini macOS app, Antigravity IDE/language server).
    /// Matches specific executable/bundle paths so workspace paths containing "antigravity" never match.
    public static func isAntigravityExecutable(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let name = (path as NSString).lastPathComponent
        if name == "agy" { return true }
        if path.contains("/.gemini/antigravity") { return true }
        if path.contains("/Gemini.app/Contents/") { return true }
        if path.contains("/Antigravity.app/Contents/") || path.contains("/Antigravity IDE.app/Contents/") { return true }
        if name.hasPrefix("language_server_macos"), path.lowercased().contains("/antigravity") { return true }
        return false
    }

    /// Open vnode file and directory paths for `pid` (`PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO`).
    public static func openVnodePaths(_ pid: Int32) -> [String] {
        guard pid > 0 else { return [] }
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let entrySize = MemoryLayout<proc_fdinfo>.size
        let capacity = Int(needed) / entrySize + 16
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let filled = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return [] }
        let count = Int(filled) / entrySize
        var paths: [String] = []
        paths.reserveCapacity(count)
        let vnodeSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for i in 0..<count where fds[i].proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let n = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &info, vnodeSize)
            guard n == vnodeSize else { continue }
            let path = decodeCPath(info.pvip.vip_path)
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// Memory-mapped file paths for `pid` (`PROC_PIDREGIONPATHINFO`), catching SQLite `.db-shm` mmaps.
    public static func mappedRegionPaths(_ pid: Int32) -> [String] {
        guard pid > 0 else { return [] }
        var paths: [String] = []
        var seen = Set<String>()
        var address: UInt64 = 0
        let regionSize = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        for _ in 0..<4096 {
            var info = proc_regionwithpathinfo()
            let n = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &info, regionSize)
            guard n == regionSize else { break }
            let path = decodeCPath(info.prp_vip.vip_path)
            if !path.isEmpty, seen.insert(path).inserted { paths.append(path) }
            let next = info.prp_prinfo.pri_address &+ info.prp_prinfo.pri_size
            guard next > address else { break }
            address = next
        }
        return paths
    }

    /// Extracts an Antigravity conversation id from an open path under `~/.gemini/<app_dir>/`:
    /// - `conversations/<id>.db`, `.db-shm`, `.db-wal` (strongest ownership signal)
    /// - `brain/<id>` or `brain/<id>/{.system_generated,scratch,.user_uploaded}` (directory handles)
    /// Arbitrary artifact reads (`brain/<other>/plan.md`) are ignored so cross-session reads don't false-match.
    public static func antigravityConversationId(fromPath path: String) -> (id: String, isDatabase: Bool)? {
        let components = path.split(separator: "/").map(String.init)
        guard let geminiIdx = components.firstIndex(of: ".gemini"),
              geminiIdx + 3 < components.count else { return nil }
        let appDir = components[geminiIdx + 1]
        guard appDir == "antigravity-cli" || appDir == "antigravity" || appDir == "antigravity-ide" else { return nil }
        let kind = components[geminiIdx + 2]
        let target = components[geminiIdx + 3]
        if kind == "conversations", components.count == geminiIdx + 4 {
            for suffix in [".db-shm", ".db-wal", ".db"] where target.hasSuffix(suffix) {
                let id = String(target.dropLast(suffix.count))
                return isValidConversationId(id) ? (id, true) : nil
            }
            return nil
        }
        if kind == "brain", isValidConversationId(target) {
            if components.count == geminiIdx + 4 { return (target, false) }
            let child = components[geminiIdx + 4]
            if child == ".system_generated" || child == "scratch" || child == ".user_uploaded" {
                return (target, false)
            }
        }
        return nil
    }

    /// Discover live Antigravity processes and map `conversationId -> AntigravityProcessInfo`.
    public static func antigravityProcesses() -> [String: AntigravityProcessInfo] {
        antigravityProcesses(
            allPids: allPids,
            executablePath: executablePath,
            openPaths: { pid in openVnodePaths(pid) + mappedRegionPaths(pid) },
            ancestorPaths: { ancestorExecutablePaths($0) },
            tty: tty,
            startTime: startTime
        )
    }

    static func antigravityProcesses(
        allPids: () -> [Int32],
        executablePath: (Int32) -> String?,
        openPaths: (Int32) -> [String],
        ancestorPaths: (Int32) -> [String],
        tty: (Int32) -> String?,
        startTime: (Int32) -> Date?
    ) -> [String: AntigravityProcessInfo] {
        var result: [String: (info: AntigravityProcessInfo, isDatabase: Bool)] = [:]
        for pid in allPids() {
            guard let exe = executablePath(pid), isAntigravityExecutable(exe) else { continue }
            var matched: [String: Bool] = [:]
            for path in openPaths(pid) {
                guard let hit = antigravityConversationId(fromPath: path) else { continue }
                matched[hit.id] = (matched[hit.id] ?? false) || hit.isDatabase
            }
            guard !matched.isEmpty else { continue }
            let procTty = tty(pid)
            let ancestors = ancestorPaths(pid)
            let source = Source.classifyAntigravity(executablePath: exe, ancestorPaths: ancestors, tty: procTty)
            let info = AntigravityProcessInfo(
                pid: pid,
                executablePath: exe,
                source: source,
                tty: procTty,
                startedAt: startTime(pid)
            )
            for (convId, isDB) in matched {
                if let prev = result[convId] {
                    if prev.isDatabase && !isDB { continue }
                    if prev.isDatabase == isDB {
                        let prevStart = prev.info.startedAt ?? .distantPast
                        let nextStart = info.startedAt ?? .distantPast
                        if nextStart < prevStart || (nextStart == prevStart && info.pid <= prev.info.pid) { continue }
                    }
                }
                result[convId] = (info, isDB)
            }
        }
        return result.mapValues(\.info)
    }

    private static func isValidConversationId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && !id.hasPrefix(".")
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }
    }

    private static func decodeCPath<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let length = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes.prefix(length), as: UTF8.self)
        }
    }
}
