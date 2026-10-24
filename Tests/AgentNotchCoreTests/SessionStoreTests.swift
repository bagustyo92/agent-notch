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

    private var kinds: [AttentionKind] { store.attentionLog.map(\.kind) }

    @Test func firesWhenASessionStartsWaiting() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.replaceList([listed("a", status: "waiting")], now: t0.addingTimeInterval(1))
        #expect(store.attentionLog.map(\.id) == ["a"])
        #expect(kinds == [.needsYou])
    }

    @Test func firesWhenATurnFinishes() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.replaceList([listed("a", status: "idle")], now: t0.addingTimeInterval(1))
        #expect(kinds == [.finished])
    }

    @Test func firesWhenASessionStartsWorking() {
        store.replaceList([listed("a", status: "idle")], now: t0)
        store.replaceList([listed("a", status: "busy")], now: t0.addingTimeInterval(1))
        #expect(kinds == [.started])
    }

    @Test func aNewSessionThatIsAlreadyWorkingFiresButTheFirstListDoesNot() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        #expect(store.attentionLog.isEmpty)
        store.replaceList([listed("a", status: "busy"), listed("b", status: "busy")], now: t0.addingTimeInterval(1))
        #expect(store.attentionLog.map(\.id) == ["b"])
        #expect(kinds == [.started])
    }

    @Test func answeringAPromptDoesNotReopenTheNotch() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.replaceList([listed("a", status: "waiting")], now: t0.addingTimeInterval(1))
        store.replaceList([listed("a", status: "busy")], now: t0.addingTimeInterval(2))
        #expect(kinds == [.needsYou])
    }

    @Test func attentionLogIsBounded() {
        let many = (0..<60).map { listed("s\($0)", status: "busy") }
        store.replaceList(many, now: t0)
        store.replaceList(many.map { var e = $0; e.status = "waiting"; return e }, now: t0.addingTimeInterval(1))
        #expect(store.attentionLog.count == SessionStore.attentionLogLimit)
    }

    @Test func atMostOneEventPerSessionAndKindPerFiveSeconds() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.replaceList([listed("a", status: "idle")], now: t0.addingTimeInterval(1))
        store.replaceList([listed("a", status: "busy")], now: t0.addingTimeInterval(2))
        store.replaceList([listed("a", status: "idle")], now: t0.addingTimeInterval(3))
        #expect(kinds == [.finished, .started])
        store.replaceList([listed("a", status: "busy")], now: t0.addingTimeInterval(4))
        store.replaceList([listed("a", status: "idle")], now: t0.addingTimeInterval(6.5))
        #expect(kinds == [.finished, .started, .finished])
    }
}

@MainActor
@Suite struct SessionStoreTurns {
    let store = SessionStore(testedVersion: "2.1.310")

    @Test func finishedTurnIsStampedAndLiveForFourSeconds() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        #expect(store.liveSessions(now: t0).map(\.id) == ["a"])
        store.replaceList([listed("a", status: "idle")], now: t0.addingTimeInterval(10))
        let a = store.sessions[0]
        #expect(a.turnFinishedAt == t0.addingTimeInterval(10))
        #expect(DisplayState.of(a, now: t0.addingTimeInterval(11)) == .finished)
        #expect(store.liveSessions(now: t0.addingTimeInterval(13.9)).map(\.id) == ["a"])
        #expect(store.anyJustFinished(now: t0.addingTimeInterval(13.9)))
        #expect(store.liveSessions(now: t0.addingTimeInterval(14)).isEmpty)
        #expect(DisplayState.of(a, now: t0.addingTimeInterval(10 + 600)) == .idle)
        store.replaceList([listed("a", status: "busy")], now: t0.addingTimeInterval(20))
        #expect(store.sessions[0].turnFinishedAt == nil)
    }

    @Test func waitingCarriesWaitingForAndNeedsUntilItResolves() {
        let waiting = ListedSession(sessionId: "a", pid: 1, cwd: "/Users/dev/a", kind: .interactive, name: "a", startedAt: t0,
                                    status: "waiting", waitingFor: "dialog open", needs: "choose: allow Bash")
        store.replaceList([waiting], now: t0)
        #expect(store.sessions[0].waitingFor == "dialog open")
        #expect(store.sessions[0].needs == "choose: allow Bash")
        store.replaceList([listed("a", status: "busy")], now: t0.addingTimeInterval(1))
        #expect(store.sessions[0].waitingFor == nil)
        #expect(store.sessions[0].needs == nil)
    }

    @Test func transcriptPhaseModelAndEffortAreKept() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.updateTranscript(id: "a", update: TranscriptUpdate(phase: .tool, model: "claude-opus-5-5", effort: "high"))
        store.updateTranscript(id: "a", update: TranscriptUpdate(phase: .thinking))
        let a = store.sessions[0]
        #expect(a.phase == .thinking)
        #expect(a.model == "claude-opus-5-5")
        #expect(a.effort == "high")
        #expect(DisplayState.of(a, now: t0) == .working(.thinking))
    }
}

@MainActor
@Suite struct SessionStoreSubagents {
    let store = SessionStore(testedVersion: "2.1.310")

    private func update(_ id: String, finished: Bool = false, phase: Phase? = .tool, at: Date = t0) -> SubagentUpdate {
        SubagentUpdate(agentId: id, agentType: "Explore", description: "Scan \(id)", toolUseId: "toolu_\(id)", finished: finished,
                       startedAt: at, lastWriteAt: at, transcript: TranscriptUpdate(activity: Activity(full: "Grep", brief: "Grep"), phase: phase, model: "claude-haiku-4-5", effort: "low"))
    }

    @Test func subagentsMergeAndKeepTheirFields() throws {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.updateSubagent(sessionId: "a", update: update("x"), now: t0)
        store.updateSubagent(sessionId: "a", update: SubagentUpdate(agentId: "x", agentType: "Explore", description: "Scan x", transcript: TranscriptUpdate(phase: .thinking)), now: t0.addingTimeInterval(1))
        let x = try #require(store.sessions[0].subagents.first)
        #expect(x.phase == .thinking)
        #expect(x.activity?.brief == "Grep")
        #expect(x.model == "claude-haiku-4-5")
        #expect(x.toolUseId == "toolu_x")
        #expect(x.startedAt == t0)
    }

    @Test func finishedSubagentsFoldAwayWhenTheTurnEndsAndStayAway() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.updateSubagent(sessionId: "a", update: update("done", finished: true), now: t0)
        store.updateSubagent(sessionId: "a", update: update("bg"), now: t0)
        #expect(store.sessions[0].subagents.first { $0.id == "done" }?.finishedAt == t0)
        store.replaceList([listed("a", status: "idle")], now: t0.addingTimeInterval(1))
        #expect(store.sessions[0].subagents.map(\.id) == ["bg"])         // a still-running one stays
        store.updateSubagent(sessionId: "a", update: update("done", finished: true), now: t0.addingTimeInterval(2))
        #expect(store.sessions[0].subagents.map(\.id) == ["bg"])
        #expect(store.dismissedSubagentIds(sessionId: "a") == ["done"])
    }

    @Test func quietUnfinishedSubagentsAreDropped() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.updateSubagent(sessionId: "a", update: update("x"), now: t0)
        store.dropStaleSubagents(now: t0.addingTimeInterval(SessionStore.subagentStaleWhileWorking - 1))
        #expect(store.sessions[0].subagents.count == 1)
        store.replaceList([listed("a", status: "idle")], now: t0.addingTimeInterval(10))
        store.dropStaleSubagents(now: t0.addingTimeInterval(SessionStore.subagentStaleWhileIdle + 1))
        #expect(store.sessions[0].subagents.isEmpty)
    }

    @Test func endedSessionsTakeNoSubagents() {
        store.replaceList([listed("a", status: "busy")], now: t0)
        store.updateSubagent(sessionId: "a", update: update("x"), now: t0)
        store.replaceList([], now: t0.addingTimeInterval(1))
        #expect(store.sessions[0].subagents.isEmpty)
        store.updateSubagent(sessionId: "a", update: update("y"), now: t0.addingTimeInterval(2))
        #expect(store.sessions[0].subagents.isEmpty)
    }
}
