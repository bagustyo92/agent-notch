import Darwin
import Foundation

extension Source {
    /// F4: the executable path tells the sources apart; `entrypoint` cannot (F3).
    /// Terminal sessions resolve to `~/.local/share/claude/versions/<ver>` (V2) because
    /// `~/.local/bin/claude` is a symlink; both spellings count, as does a Homebrew install.
    public static func classify(executablePath path: String?) -> Source {
        guard let path, !path.isEmpty else { return .unknown }
        if path.contains("/.cursor/extensions/") { return .cursor }
        if path.contains("/.vscode/extensions/") || path.contains("/.vscode-insiders/extensions/") { return .vscode }
        if path.contains("/.local/share/claude/versions/") || path.hasSuffix("/.local/bin/claude") { return .terminal }
        if path.hasSuffix("/bin/claude") { return .terminal }
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

    /// Parent pid from `proc_pidinfo`, nil when the process is gone.
    public static func parentPid(_ pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
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

    public static func source(forPid pid: Int32) -> Source {
        Source.classify(executablePath: executablePath(pid))
    }
}
