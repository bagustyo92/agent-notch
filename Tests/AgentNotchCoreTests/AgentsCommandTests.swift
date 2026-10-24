import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct AgentsCommandDecoding {
    let listed = try! AgentsCommand.decode(try! fixtureData("agents.json"), now: Date(timeIntervalSince1970: 1_792_900_000))

    @Test func decodesInteractiveEntry() throws {
        let a = try #require(listed.first { $0.sessionId == "11111111-1111-4111-8111-111111111111" })
        #expect(a.pid == 4242)
        #expect(a.kind == .interactive)
        #expect(a.cwd == "/Users/dev/work/repo-a")
        #expect(a.name == "repo-a-36")
        #expect(a.status == "busy")
        #expect(a.state == nil)
        #expect(a.startedAt == Date(timeIntervalSince1970: 1_792_811_619.613))
    }

    @Test func decodesWaitingForOnInteractiveEntry() throws {
        let b = try #require(listed.first { $0.sessionId == "22222222-2222-4222-8222-222222222222" })
        #expect(b.status == "waiting")
        #expect(b.waitingFor == "permission")
    }

    @Test func decodesBackgroundEntryWithoutPid() throws {
        let c = try #require(listed.first { $0.sessionId == "33333333-3333-4333-8333-333333333333" })
        #expect(c.pid == nil)
        #expect(c.kind == .background)
        #expect(c.state == "blocked")
        #expect(c.status == nil)
        #expect(c.startedAt == Date(timeIntervalSince1970: 1_787_708_968.917))
    }

    @Test func unknownKindAndIsoDateDegradeInsteadOfFailing() throws {
        let d = try #require(listed.first { $0.sessionId == "44444444-4444-4444-8444-444444444444" })
        #expect(d.kind == .background)   // no pid → treated as background
        #expect(d.startedAt == Date(timeIntervalSince1970: 1_792_818_000))
    }

    @Test func entryWithoutSessionIdIsDropped() {
        #expect(listed.count == 4)
        #expect(!listed.contains { $0.name == "dropped" })
    }

    @Test func absurdEpochFallsBackAndObjectWaitingForCountsAsWaiting() throws {
        let now = Date(timeIntervalSince1970: 1_792_900_000)
        let json = #"[{"sessionId":"x","pid":1,"kind":"interactive","startedAt":1e300,"status":"busy","waitingFor":{"type":"permission"}},"# +
                   #"{"sessionId":"y","pid":2,"kind":"interactive","startedAt":-7,"status":"busy","waitingFor":null}]"#
        let decoded = try AgentsCommand.decode(Data(json.utf8), now: now)
        let x = try #require(decoded.first { $0.sessionId == "x" })
        #expect(x.startedAt == now)
        #expect(Status.from(x) == .waiting)
        let y = try #require(decoded.first { $0.sessionId == "y" })
        #expect(y.startedAt == now)
        #expect(Status.from(y) == .working)
    }

    @Test func nonArrayJsonIsAnError() {
        #expect(throws: (any Error).self) { try AgentsCommand.decode(Data("{\"oops\":1}".utf8), now: Date()) }
        #expect(throws: (any Error).self) { try AgentsCommand.decode(Data("not json".utf8), now: Date()) }
    }
}
