import Foundation

/// Compact elapsed-time labels for the row's line 2 (D10).
public enum ElapsedFormatter {
    public static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0s" }
        let s = Int(min(max(0, seconds), 1e12))          // R8: Int(Double) traps outside its range
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h \(m % 60)m" }
        return "\(h / 24)d \(h % 24)h"
    }

    /// Running sessions count up to `now`; Done sessions freeze at `endedAt`.
    public static func string(for session: Session, now: Date) -> String {
        string((session.endedAt ?? now).timeIntervalSince(session.startedAt))
    }
}
