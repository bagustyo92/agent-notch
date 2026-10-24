import Testing
@testable import AgentNotchCore

@Test func statusSortRankFollowsWaitingWorkingIdleDone() {
    #expect(Status.allCases.sorted() == [.waiting, .working, .idle, .done])
}
