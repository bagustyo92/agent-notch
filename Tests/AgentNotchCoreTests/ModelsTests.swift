import Foundation
import Testing
@testable import AgentNotchCore

@Test func statusSortRankFollowsWaitingWorkingIdleDone() {
    #expect(Status.allCases.sorted() == [.waiting, .working, .idle, .done])
}

@Suite struct RunningChildren {
    private let t0 = Date(timeIntervalSince1970: 1_792_900_000)

    private func session(_ status: Status) -> Session {
        var s = Session(id: "s", cwd: "/Users/dev/s", name: "s", status: status, statusChangedAt: t0, startedAt: t0)
        s.subagents = [
            Subagent(id: "run", agentType: "fork", description: "", startedAt: t0, lastWriteAt: t0),
            Subagent(id: "done", agentType: "Explore", description: "", finished: true, startedAt: t0, lastWriteAt: t0),
        ]
        s.backgroundTasks = [BackgroundTask(id: "toolu_01A", activity: Activity(full: "Bash · Serve", brief: "Bash"), startedAt: t0)]
        return s
    }

    @Test func unfinishedSubagentsAndOpenTasksAreRunningChildren() {
        #expect(session(.working).runningChildCount == 2)
        #expect(session(.idle).runningChildCount == 2)
    }

    @Test func onlyAnIdleParentHasThemInTheBackground() {
        #expect(session(.idle).backgroundChildCount == 2)
        for status in [Status.working, .waiting, .done] { #expect(session(status).backgroundChildCount == 0) }
    }

    @Test func aTaskWithoutAnOwnerBelongsToTheMainSession() {
        let task = BackgroundTask(id: "toolu_01B", ownerAgentId: nil, activity: Activity(full: "Bash", brief: "Bash"), startedAt: t0)
        #expect(task.ownerAgentId == nil)
        #expect(task.id == "toolu_01B")
    }
}
