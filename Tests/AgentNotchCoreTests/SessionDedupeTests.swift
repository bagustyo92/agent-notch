import Foundation
import Testing
@testable import AgentNotchCore

private let t0 = Date(timeIntervalSince1970: 1_792_900_000)

private func entry(_ id: String, pid: Int32?, startedAt: Date = t0) -> ListedSession {
    ListedSession(sessionId: id, pid: pid, cwd: "/Users/dev/work/\(id)", kind: .interactive, name: id, startedAt: startedAt, status: "idle")
}

/// One session id listed with two live processes (F28): the row stands for the reachable one (D43).
@Suite struct SessionDedupePicking {
    let starts: [Int32: Date] = [3910: t0, 51965: t0.addingTimeInterval(3360), 7000: t0.addingTimeInterval(60)]

    @Test func entryUnderACurrentHostWinsOverANewerProcess() {
        let picked = SessionDedupe.pick(
            [entry("s", pid: 3910), entry("s", pid: 51965, startedAt: t0.addingTimeInterval(3360))],
            isCurrent: { $0.pid == 3910 }, startTime: { starts[$0] }
        )
        #expect(picked.map(\.pid) == [3910])
    }

    @Test func withoutACurrentHostTheNewerProcessWins() {
        let picked = SessionDedupe.pick(
            [entry("s", pid: 51965), entry("s", pid: 3910)],
            isCurrent: { _ in false }, startTime: { starts[$0] }
        )
        #expect(picked.map(\.pid) == [51965])
    }

    @Test func listOrderDoesNotChangeThePick() {
        let a = entry("s", pid: 3910), b = entry("s", pid: 51965)
        let forward = SessionDedupe.pick([a, b], isCurrent: { $0.pid == 51965 }, startTime: { starts[$0] })
        let backward = SessionDedupe.pick([b, a], isCurrent: { $0.pid == 51965 }, startTime: { starts[$0] })
        #expect(forward.map(\.pid) == [51965])
        #expect(backward.map(\.pid) == [51965])
    }

    @Test func unknownStartTimesFallBackToTheNewerStartedAt() {
        let picked = SessionDedupe.pick(
            [entry("s", pid: 1, startedAt: t0.addingTimeInterval(500)), entry("s", pid: 2, startedAt: t0)],
            isCurrent: { _ in false }, startTime: { _ in nil }
        )
        #expect(picked.map(\.pid) == [1])
    }

    @Test func distinctIdsPassThroughInOrderAndAreNeverJudged() {
        let list = [entry("a", pid: 7000), entry("b", pid: nil), entry("c", pid: 3910)]
        let picked = SessionDedupe.pick(list, isCurrent: { _ in Issue.record("judged a unique id"); return false },
                                        startTime: { _ in Issue.record("probed a unique id"); return nil })
        #expect(picked == list)
    }

    @Test func duplicateKeepsTheFirstEntrysPosition() {
        let picked = SessionDedupe.pick(
            [entry("a", pid: 7000), entry("s", pid: 3910), entry("b", pid: nil), entry("s", pid: 51965)],
            isCurrent: { _ in false }, startTime: { starts[$0] }
        )
        #expect(picked.map(\.sessionId) == ["a", "s", "b"])
        #expect(picked[1].pid == 51965)
    }
}
