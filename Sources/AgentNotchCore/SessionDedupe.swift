import Foundation

/// D43: one row per session id. `claude agents --json` can list one session under two live
/// processes, e.g. a chat resumed in a second IDE window while the first process lingers (F28).
/// The row must stand for one process, and its `pid` and `startedAt` must come from the same entry.
public enum SessionDedupe {
    /// Keeps the first position of each session id. For an id listed more than once it picks, in
    /// order: an entry whose process runs under a current, trusted IDE host (`isCurrent`), then the
    /// newest process start, then the newest `startedAt`. Unique ids are never judged or probed.
    public static func pick(
        _ entries: [ListedSession], isCurrent: (ListedSession) -> Bool, startTime: (Int32) -> Date?
    ) -> [ListedSession] {
        var groups: [String: [ListedSession]] = [:]
        var order: [String] = []
        for entry in entries {
            if groups[entry.sessionId] == nil { order.append(entry.sessionId) }
            groups[entry.sessionId, default: []].append(entry)
        }
        return order.compactMap { id in
            guard let group = groups[id] else { return nil }
            guard group.count > 1 else { return group.first }
            let ranked = group.map { (entry: $0, current: isCurrent($0), start: $0.pid.flatMap(startTime)) }
            return ranked.max { a, b in
                if a.current != b.current { return !a.current }
                if let sa = a.start, let sb = b.start, sa != sb { return sa < sb }
                if (a.start == nil) != (b.start == nil) { return a.start == nil }
                return a.entry.startedAt < b.entry.startedAt
            }?.entry
        }
    }
}
