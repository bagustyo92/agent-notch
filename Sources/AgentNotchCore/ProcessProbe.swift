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
}

/// Read-only process facts (R1): liveness, executable path and controlling tty.
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
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
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

    /// Every pid on the system (`proc_listallpids`), used to find the IDE's extension hosts (D43).
    public static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 }
    }
}
