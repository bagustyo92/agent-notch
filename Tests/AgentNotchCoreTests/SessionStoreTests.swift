import Foundation
import Testing
@testable import AgentNotchCore

private let t0 = Date(timeIntervalSince1970: 1_792_900_000)
private func listed(_ id: String, pid: Int32? = 1, kind: SessionKind = .interactive, status: String? = nil,
                    state: String? = nil, waitingFor: String? = nil, version: String? = nil,
                    transcriptModifiedAt: Date? = nil, startedAt: Date = t0) -> ListedSession {
    ListedSession(sessionId: id, pid: pid, cwd: "/Users/dev/work/\(id)", kind: kind, name: "name-\(id)",
                  startedAt: startedAt, status: status, state: state, waitingFor: waitingFor,
                  version: version, transcriptModifiedAt: transcriptModifiedAt)
}

@Suite struct StatusMapping {
    @Test(arguments: [("busy", Status.working), ("idle", .idle), ("waiting", .waiting), ("weird", .idle)])
    func interactiveStatus(raw: String, expected: Status) {
        #expect(Status.from(listed("s", status: raw)) == expected)
    }

    @Test func waitingForWinsOverBusy() {
        #expect(Status.from(listed("s", status: "busy", waitingFor: "permission")) == .waiting)
    }

    @Test(arguments: [("blocked", Status.waiting), ("running", .working), ("done", .done), ("stopped", .done), ("idle", .idle), ("odd", .idle)])
    func backgroundState(raw: String, expected: Status) {
        #expect(Status.from(listed("b", pid: nil, kind: .background, state: raw)) == expected)
    }
}

@MainActor
@Suite struct SessionStoreMerging {
    let store = SessionStore(testedVersion: "2.1.310")

    @Test func listEntriesBecomeSessionsWithMappedStatus() {
        store.replaceList([listed("a", status: "busy"), listed("b", status: "idle")], now: t0)
        #expect(store.sessions.map(\.id) == ["a", "b"])
        #expect(store.sessions[0].status == .working)
        #expect(store.sessions[0].repo == "a")
        #expect(store.sessions[0].title == "name-a")
        #expect(store.workingCount == 1)
        #expect(store.waitingCount == 0)
    }

    @Test func sortsWaitingWorkingIdleDoneThenMostRecentChangeFirst() {
        store.replaceList([listed("idle1", status: "idle"), listed("work1", status: "busy"), listed("wait1", status: "waiting")], now: t0)
        store.replaceList([listed("idle1", status: "idle"), listed("work1", status: "busy"), listed("wait1", status: "waiting"), listed("work2", status: "busy")], now: t0.addingTimeInterval(10))
        #expect(store.sessions.map(\.id) == ["wait1", "work2", "work1", "idle1"])
    }

    @Test func backgroundSessionsNeedAFreshTranscript() {
        store.replaceList([
            listed("fresh", pid: nil, kind: .background, state: "blocked", transcriptModifiedAt: t0.addingTimeInterval(-3600)),
            listed("stale", pid: nil, kind: .background, state: "blocked", transcriptModifiedAt: t0.addingTimeInterval(-25 * 3600)),
            listed("none", pid: nil, kind: .background, state: "blocked"),
        ], now: t0)
        #expect(store.sessions.map(\.id) == ["fresh"])
        #expect(store.sessions[0].status == .waiting)
        #expect(store.sessions[0].source == .background)
    }

    @Test func probeResultsAndTitlesSurviveARelist() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.setProbe(id: "a", source: .cursor, tty: nil)
        store.updateTranscript(id: "a", aiTitle: "Fix the login bug", branch: "feature/x", activity: nil)
        store.replaceList([listed("a", status: "idle")], now: t0.addingTimeInterval(5))
        let a = store.sessions[0]
        #expect(a.source == .cursor)
        #expect(a.title == "Fix the login bug")
        #expect(a.branch == "feature/x")
        #expect(a.status == .idle)
    }

    @Test func versionNoteAppearsOnlyWhenAVersionDiffers() {
        store.replaceList([listed("a", status: "busy", version: "2.1.310")], now: t0)
        #expect(store.versionNote == nil)
        store.replaceList([listed("a", status: "busy", version: "2.1.310"), listed("b", status: "idle", version: "2.1.296")], now: t0)
        #expect(store.versionNote == "Tested with Claude Code 2.1.310 · running 2.1.296")
    }
}

@MainActor
@Suite struct SessionStoreLinger {
    let store = SessionStore(testedVersion: "2.1.310", lingerDuration: 600)

    @Test func missingSessionShowsDoneForTenMinutesThenDisappears() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.replaceList([], now: t0.addingTimeInterval(1))
        #expect(store.sessions.map(\.status) == [.done])
        #expect(store.sessions[0].endedAt == t0.addingTimeInterval(1))
        store.tick(now: t0.addingTimeInterval(1 + 599))
        #expect(store.sessions.count == 1)
        store.tick(now: t0.addingTimeInterval(1 + 600))
        #expect(store.sessions.isEmpty)
    }

    @Test func reappearingSessionIsRevived() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.replaceList([], now: t0.addingTimeInterval(1))
        store.replaceList([listed("a", status: "busy")], now: t0.addingTimeInterval(2))
        #expect(store.sessions[0].status == .working)
        #expect(store.sessions[0].endedAt == nil)
    }

    @Test func deadPidTurnsTheRowDone() {
        store.replaceList([listed("a", pid: 4242, status: "busy"), listed("b", pid: 4243, status: "busy")], now: t0)
        store.checkLiveness(now: t0.addingTimeInterval(5)) { pid in pid == 4243 }
        #expect(store.session(id: "a")?.status == .done)
        #expect(store.session(id: "b")?.status == .working)
    }

    @Test func backgroundDoneStateLingersThenExpires() {
        store.replaceList([listed("bg", pid: nil, kind: .background, state: "done", transcriptModifiedAt: t0)], now: t0)
        #expect(store.sessions[0].status == .done)
        store.tick(now: t0.addingTimeInterval(601))
        #expect(store.sessions.isEmpty)
    }
}

@MainActor
@Suite struct SessionStoreAttention {
    let store = SessionStore(testedVersion: "2.1.310", attentionInterval: 5)

    @Test func firesWhenASessionStartsWaiting() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.replaceList([listed("a", status: "waiting")], now: t0.addingTimeInterval(1))
        #expect(store.attentionLog.map(\.id) == ["a"])
    }

    @Test func firesWhenATurnFinishes() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.replaceList([listed("a", status: "idle")], now: t0.addingTimeInterval(1))
        #expect(store.attentionLog.map(\.id) == ["a"])
    }

    @Test func doesNotFireForIdleToWorkingOrForFirstSight() {
        store.replaceList([listed("a", status: "waiting")], now: t0)
        store.replaceList([listed("a", status: "idle")], now: t0.addingTimeInterval(1))
        store.replaceList([listed("a", status: "busy")], now: t0.addingTimeInterval(2))
        #expect(store.attentionLog.isEmpty)
    }

    @Test func attentionLogIsBounded() {
        let many = (0..<60).map { listed("s\($0)", status: "busy") }
        store.replaceList(many, now: t0)
        store.replaceList(many.map { var e = $0; e.status = "waiting"; return e }, now: t0.addingTimeInterval(1))
        #expect(store.attentionLog.count == SessionStore.attentionLogLimit)
    }

    @Test func atMostOneEventPerSessionPerFiveSeconds() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.replaceList([listed("a", status: "waiting")], now: t0.addingTimeInterval(1))
        store.replaceList([listed("a", status: "busy")], now: t0.addingTimeInterval(2))
        store.replaceList([listed("a", status: "idle")], now: t0.addingTimeInterval(3))
        #expect(store.attentionLog.count == 1)
        store.replaceList([listed("a", status: "busy")], now: t0.addingTimeInterval(4))
        store.replaceList([listed("a", status: "idle")], now: t0.addingTimeInterval(6.5))
        #expect(store.attentionLog.count == 2)
    }
}
