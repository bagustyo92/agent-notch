import Foundation
import Testing
@testable import AgentNotchCore

private let t0 = Date(timeIntervalSince1970: 1_792_900_000)

@Suite struct ModelNames {
    @Test(arguments: [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),
        ("claude-sonnet-4-5-20250929[1m]", "Sonnet 4.5"),
        ("claude-3-5-haiku-20241022", "Haiku 3.5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("claude-opus", "Opus"),
        ("gpt-x", "gpt-x"),
        ("claude-opus-5-5-x1", "claude-opus-5-5-x1"),
    ])
    func displayNames(id: String, expected: String) {
        #expect(ModelName.display(id) == expected)
    }

    @Test func capsuleJoinsWhatIsKnown() {
        #expect(ModelName.capsule(model: "claude-opus-5-5", effort: "high") == "Opus 5.5 · high")
        #expect(ModelName.capsule(model: "claude-opus-5-5", effort: nil) == "Opus 5.5")
        #expect(ModelName.capsule(model: nil, effort: "low") == "low")
        #expect(ModelName.capsule(model: nil, effort: nil) == nil)
    }
}

@Suite struct NeedsLabels {
    @Test(arguments: [
        ("dialog open", "Needs a decision"), ("input needed", "Needs your input"),
        ("sandbox request", "Needs network access"), ("goal proposal", "Needs goal approval"), ("pending", "Needs you"),
    ])
    func labels(raw: String, expected: String) {
        #expect(NeedsLabel.text(waitingFor: raw) == expected)
    }

    @Test func missingValueStillNeedsYou() {
        #expect(NeedsLabel.text(waitingFor: nil) == "Needs you")
    }
}

@Suite struct Verbs {
    @Test func stableWithinASlotAndRotatingAcrossSlots() {
        let slots = (0..<12).map { SpinnerVerbs.verb(for: "session-a", at: t0.addingTimeInterval(Double($0) * SpinnerVerbs.interval)) }
        #expect(Set(slots).count > 1)
        #expect(slots.allSatisfy { $0.hasSuffix("…") })
    }

    @Test func sameSlotSameVerb() {
        let base = (t0.timeIntervalSince1970 / SpinnerVerbs.interval).rounded(.down) * SpinnerVerbs.interval
        let start = Date(timeIntervalSince1970: base)
        #expect(SpinnerVerbs.verb(for: "x", at: start) == SpinnerVerbs.verb(for: "x", at: start.addingTimeInterval(SpinnerVerbs.interval - 0.01)))
    }

    @Test func hashIsStableAcrossRuns() {
        #expect(SpinnerVerbs.fnv1a("abc") == 0xe71fa2190541574b)
    }
}

@Suite struct DisplayStates {
    private func session(_ status: Status, phase: Phase? = nil, finishedAt: Date? = nil) -> Session {
        var s = Session(id: "a", cwd: "/Users/dev/a", name: "a", status: status, statusChangedAt: t0, startedAt: t0)
        s.phase = phase
        s.turnFinishedAt = finishedAt
        return s
    }

    @Test func mapsStatusAndPhase() {
        #expect(DisplayState.of(session(.working, phase: .tool), now: t0) == .working(.tool))
        #expect(DisplayState.of(session(.waiting), now: t0) == .needsYou)
        #expect(DisplayState.of(session(.done), now: t0) == .ended)
        #expect(DisplayState.of(session(.idle), now: t0) == .idle)
        #expect(DisplayState.of(session(.idle, finishedAt: t0), now: t0.addingTimeInterval(599)) == .finished)
        #expect(DisplayState.of(session(.idle, finishedAt: t0), now: t0.addingTimeInterval(600)) == .idle)
    }

    @Test func onlyWorkingAndNeedsYouAreLive() {
        #expect(DisplayState.working(nil).isLive)
        #expect(DisplayState.needsYou.isLive)
        #expect(!DisplayState.finished.isLive)
        #expect(!DisplayState.idle.isLive)
    }
}

@Suite struct Trees {
    private func agent(_ id: String, use: String? = nil, spawned: Set<String> = [], finished: Bool = false, start: Double = 0) -> Subagent {
        var a = Subagent(id: id, agentType: "Explore", description: id, toolUseId: use, finished: finished,
                         startedAt: t0.addingTimeInterval(start), lastWriteAt: t0)
        a.spawnedToolUseIds = spawned
        return a
    }

    private func session(_ id: String, _ agents: [Subagent]) -> Session {
        var s = Session(id: id, cwd: "/Users/dev/\(id)", name: id, status: .working, statusChangedAt: t0, startedAt: t0)
        s.subagents = agents
        return s
    }

    @Test func collapsedShowsTwoTopLevelChildrenRunningFirstThenMore() {
        let s = session("s", [
            agent("old-done", use: "u1", finished: true, start: 0),
            agent("b", use: "u2", spawned: ["u4"], start: 2),
            agent("a", use: "u3", start: 1),
            agent("grandchild", use: "u4", start: 3),
        ])
        let items = SessionTree.items([s])
        #expect(items.map(\.id) == ["s:s", "a:s:a", "a:s:b", "m:s"])
        #expect(items.last == .more(sessionId: "s", hidden: 2))
    }

    @Test func expandedShowsTheWholeTreeTwoLevelsDeep() {
        let s = session("s", [
            agent("a", use: "u1", spawned: ["u2"]),
            agent("child", use: "u2", spawned: ["u3"], start: 1),
            agent("deep", use: "u3", start: 2),
            agent("z", use: "u9", start: 5),
        ])
        let items = SessionTree.items([s], expanded: ["s"])
        let levels: [String: Int] = Dictionary(uniqueKeysWithValues: items.compactMap {
            if case .subagent(let a, _, let level) = $0 { return (a.id, level) }
            return nil
        })
        #expect(items.map(\.id) == ["s:s", "a:s:a", "a:s:child", "a:s:deep", "a:s:z"])
        #expect(levels == ["a": 1, "child": 2, "deep": 2, "z": 1])
    }

    @Test func runningOnlyAndSwitchedOff() {
        let s = session("s", [agent("done", use: "u1", finished: true), agent("run", use: "u2")])
        #expect(SessionTree.items([s], runningOnly: true).map(\.id) == ["s:s", "a:s:run"])
        #expect(SessionTree.items([s], includeSubagents: false).map(\.id) == ["s:s"])
    }

    @Test func aCycleDoesNotLoop() {
        let s = session("s", [agent("a", use: "u1", spawned: ["u2"]), agent("b", use: "u2", spawned: ["u1"])])
        #expect(SessionTree.items([s], expanded: ["s"]).count == 3)
    }
}

@Suite struct Sections {
    private func session(_ id: String, _ status: Status, changed: Double = 0) -> Session {
        Session(id: id, cwd: "/Users/dev/\(id)", name: id, status: status, statusChangedAt: t0.addingTimeInterval(changed), startedAt: t0)
    }

    @Test func groupsNeedsYouThenWorkingThenDoneAndHidesEmptySections() {
        let items = SessionTree.sectioned([session("w", .working), session("n", .waiting), session("i", .idle)])
        #expect(items.map(\.id) == ["h:needsYou", "s:n", "h:working", "s:w", "h:done", "s:i"])
        #expect(items.first == .header(.needsYou, count: 1))
        #expect(SessionTree.sectioned([session("w", .working)]).map(\.id) == ["h:working", "s:w"])
        #expect(SessionTree.sectioned([]).isEmpty)
    }

    @Test func doneIsNewestFirstAndCappedUntilExpanded() {
        let done = [session("old", .idle, changed: 1), session("ended", .done, changed: 5), session("new", .idle, changed: 9), session("mid", .idle, changed: 3)]
        let folded = SessionTree.sectioned(done)
        #expect(folded.map(\.id) == ["h:done", "s:new", "s:ended", "sm:done"])
        #expect(folded.first == .header(.done, count: 4))
        #expect(folded.last == .sectionMore(.done, hidden: 2))
        let open = SessionTree.sectioned(done, expandedSections: [.done])
        #expect(open.map(\.id) == ["h:done", "s:new", "s:ended", "s:mid", "s:old", "sm:done"])
        #expect(open.last == .sectionMore(.done, hidden: 0))
    }

    @Test func workingSessionsKeepTheirSubagents() {
        var w = session("w", .working)
        w.subagents = [Subagent(id: "a", agentType: "Explore", description: "", toolUseId: "u", startedAt: t0, lastWriteAt: t0)]
        #expect(SessionTree.sectioned([w]).map(\.id) == ["h:working", "s:w", "a:w:a"])
    }
}

@Suite struct StripLabels {
    private func session(title: String?, cwd: String = "/Users/dev/work/repo-a") -> Session {
        Session(id: "s", cwd: cwd, name: "repo-a-36", aiTitle: title, status: .working, statusChangedAt: t0, startedAt: t0)
    }

    @Test func shortTitleIsKept() {
        #expect(StripLabel.text(for: session(title: "Fix invoice rounding"), hideDetails: false) == "Fix invoice rounding")
    }

    @Test func longTitleIsCutAtAWordBoundary() {
        let label = StripLabel.text(for: session(title: "Redesign the checkout flow for guests"), hideDetails: false)
        #expect(label == "Redesign the checkout…")
        #expect(label.count <= StripLabel.maxLength)
    }

    @Test func firstWordLongerThanTheCapIsCutHard() {
        let label = StripLabel.shorten("Internationalization-and-localization-pipeline")
        #expect(label.count == StripLabel.maxLength)
        #expect(label.hasSuffix("…"))
    }

    @Test func noTitleFallsBackToTheRepo() {
        #expect(StripLabel.text(for: session(title: nil), hideDetails: false) == "repo-a")
        #expect(StripLabel.text(for: session(title: "  "), hideDetails: false) == "repo-a")
    }

    @Test func hideDetailsNeverShowsTheTitle() {
        #expect(StripLabel.text(for: session(title: "Fix invoice rounding"), hideDetails: true) == "repo-a")
    }
}

@Suite struct ContextIndicators {
    private func session(_ status: Status, tokens: Int?, window: Int?) -> Session {
        var s = Session(id: "a", cwd: "/Users/dev/a", name: "a", status: status, statusChangedAt: t0, startedAt: t0)
        s.contextTokens = tokens
        s.contextWindow = window
        return s
    }

    @Test func liveAndIdleSessionsShowTheirContext() {
        for status in [Status.working, .waiting, .idle] {
            #expect(ContextIndicator.of(session(status, tokens: 620_000, window: 1_000_000)) == ContextIndicator(label: "62%", level: .normal))
        }
    }

    @Test func doneSessionsAndSessionsWithoutAReplyShowNone() {
        #expect(ContextIndicator.of(session(.done, tokens: 620_000, window: 1_000_000)) == nil)
        #expect(ContextIndicator.of(session(.working, tokens: nil, window: 1_000_000)) == nil)
    }

    @Test func unknownModelsShowARawCountUncolored() {
        #expect(ContextIndicator.of(session(.working, tokens: 412_345, window: nil)) == ContextIndicator(label: "412k", level: .normal))
    }

    @Test func capsuleAppendsTheContext() {
        #expect(ModelName.capsule(model: "claude-opus-5-5", effort: "high", context: "62%") == "Opus 5.5 · high · 62%")
        #expect(ModelName.capsule(model: "claude-opus-5-5", effort: nil, context: "412k") == "Opus 5.5 · 412k")
        #expect(ModelName.capsule(model: nil, effort: nil, context: "62%") == "62%")
        #expect(ModelName.capsule(model: "claude-opus-5-5", effort: "high", context: nil) == "Opus 5.5 · high")
    }

    @Test func stripSuffixOnlyWhenAmberOrRed() {
        let amber = StripLabel.contextSuffix(for: session(.working, tokens: 810_000, window: 1_000_000))
        #expect(amber?.text == "· 81% ctx")
        #expect(amber?.level == .warn)
        let red = StripLabel.contextSuffix(for: session(.waiting, tokens: 920_000, window: 1_000_000))
        #expect(red?.text == "· 92% ctx")
        #expect(red?.level == .critical)
        #expect(StripLabel.contextSuffix(for: session(.working, tokens: 700_000, window: 1_000_000)) == nil)
        #expect(StripLabel.contextSuffix(for: session(.working, tokens: 900_000, window: nil)) == nil)
        #expect(StripLabel.contextSuffix(for: session(.done, tokens: 920_000, window: 1_000_000)) == nil)
    }
}

@Suite struct FinishedLabels {
    private let finished = t0.addingTimeInterval(-120)
    private let started = t0.addingTimeInterval(-300)

    @Test func filesAndRunTime() {
        #expect(FinishedLabel.text(finishedAt: finished, startedAt: started, files: 4, now: t0) == "Finished 2m ago · 4 files · ran 3m")
        #expect(FinishedLabel.text(finishedAt: finished, startedAt: started, files: 1, now: t0) == "Finished 2m ago · 1 file · ran 3m")
    }

    @Test func noEditsDropsTheFileCount() {
        #expect(FinishedLabel.text(finishedAt: finished, startedAt: started, files: 0, now: t0) == "Finished 2m ago · ran 3m")
    }

    @Test func unknownStartOrFinishDropsThoseParts() {
        #expect(FinishedLabel.text(finishedAt: finished, startedAt: nil, files: 2, now: t0) == "Finished 2m ago · 2 files")
        #expect(FinishedLabel.text(finishedAt: nil, startedAt: started, files: 0, now: t0) == "Finished")
    }
}
