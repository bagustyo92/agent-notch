import Foundation
import Testing
@testable import AgentNotchCore

/// A throwaway `projects/<project>/<sessionId>{.jsonl,/subagents/}` tree.
struct ProjectsTree {
    let root: URL
    let sessionId = "11111111-1111-4111-8111-111111111111"
    var project: URL { root.appendingPathComponent("-Users-dev-work-repo-a") }
    var transcript: URL { project.appendingPathComponent("\(sessionId).jsonl") }
    var subagents: URL { SubagentFiles.directory(forTranscript: transcript) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentnotch-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("-Users-dev-work-repo-a/\(sessionId)/subagents"), withIntermediateDirectories: true)
        try Data((#"{"type":"ai-title","aiTitle":"Parent"}"# + "\n").utf8).write(to: transcript)
    }

    func addAgent(_ id: String, meta: String, lines: [String]) throws {
        try Data(meta.utf8).write(to: SubagentFiles.meta(subagents, agentId: id))
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: SubagentFiles.transcript(subagents, agentId: id))
    }
}

@Suite struct SubagentFileParsing {
    @Test func parsesTranscriptAndMetaPaths() throws {
        let base = "/Users/dev/.claude/projects/-Users-dev-repo/abc-123/subagents"
        let jsonl = try #require(SubagentFiles.parse(path: "\(base)/agent-a3b7.jsonl"))
        #expect(jsonl.sessionId == "abc-123")
        #expect(jsonl.agentId == "a3b7")
        #expect(jsonl.directory.path == base)
        #expect(SubagentFiles.parse(path: "\(base)/agent-a3b7.meta.json")?.agentId == "a3b7")
    }

    @Test func rejectsEverythingElse() {
        #expect(SubagentFiles.parse(path: "/p/-Users-dev-repo/abc.jsonl") == nil)
        #expect(SubagentFiles.parse(path: "/p/x/abc/subagents/notes.txt") == nil)
        #expect(SubagentFiles.parse(path: "/p/x/abc/subagents/agent-.jsonl") == nil)
        #expect(SubagentFiles.parse(path: "/p/x/abc/other/agent-a.jsonl") == nil)
    }

    @Test func readsMetaFieldsAndMasksText() throws {
        let tree = try ProjectsTree()
        let token = String(repeating: "x", count: 40)
        try tree.addAgent("a1", meta: #"{"agentType":"Explore","description":"Find \#(token)","toolUseId":"toolu_01","spawnDepth":2,"finished":true,"extra":"ignored"}"#, lines: [])
        let meta = SubagentFiles.readMeta(tree.subagents, agentId: "a1")
        #expect(meta.agentType == "Explore")
        #expect(meta.description == "Find •••")
        #expect(meta.toolUseId == "toolu_01")
        #expect(meta.spawnDepth == 2)
        #expect(meta.finished)
        #expect(meta.lastWriteAt != nil)
        #expect(SubagentFiles.agentIds(in: tree.subagents) == ["a1"])
    }

    @Test func missingMetaDegradesToDefaults() throws {
        let tree = try ProjectsTree()
        let meta = SubagentFiles.readMeta(tree.subagents, agentId: "nope")
        #expect(meta.agentType == "Agent")
        #expect(meta.finished == false)
        #expect(meta.lastWriteAt == nil)
    }
}

@MainActor
@Suite struct MonitorSubagents {
    private func monitor(_ tree: ProjectsTree, store: SessionStore) -> Monitor {
        let entry = ListedSession(sessionId: tree.sessionId, pid: 4242, cwd: "/Users/dev/work/repo-a", kind: .interactive,
                                  name: "repo-a", startedAt: Date(), status: "busy")
        let lister = SessionLister(command: StubCommand(.success([entry])), registry: RegistryReader(directory: fixture("nope")))
        return Monitor(store: store, lister: lister, sessionsDirectory: fixture("nope"), projectsDirectory: tree.root,
                       probe: { _ in (.terminal, nil) }, isAlive: { _ in true })
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<60 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func runningSubagentsAreAttachedWithTheSession() async throws {
        let tree = try ProjectsTree()
        try tree.addAgent("run", meta: #"{"agentType":"Explore","description":"Scan","toolUseId":"toolu_1","finished":false}"#, lines: [
            #"{"type":"assistant","isSidechain":true,"effort":"low","message":{"model":"claude-haiku-4-5","content":[{"type":"tool_use","name":"Grep","input":{}}]}}"#,
        ])
        try tree.addAgent("old", meta: #"{"agentType":"Plan","description":"Old","finished":true}"#, lines: [])
        let store = SessionStore()
        await monitor(tree, store: store).refresh()
        try await waitFor { store.session(id: tree.sessionId)?.subagents.isEmpty == false }
        let agents = try #require(store.session(id: tree.sessionId)?.subagents)
        #expect(agents.map(\.id) == ["run"])
        #expect(agents[0].model == "claude-haiku-4-5")
        #expect(agents[0].effort == "low")
        #expect(agents[0].phase == .tool)
    }

    @Test func aNewSubagentFileIsPickedUpFromItsEvent() async throws {
        let tree = try ProjectsTree()
        let store = SessionStore()
        let monitor = monitor(tree, store: store)
        await monitor.refresh()
        try await waitFor { store.session(id: tree.sessionId)?.aiTitle == "Parent" }
        try tree.addAgent("new", meta: #"{"agentType":"general-purpose","description":"Write tests","toolUseId":"toolu_9"}"#, lines: [
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"thinking","thinking":"…"}]}}"#,
        ])
        monitor.transcriptsChanged([SubagentFiles.transcript(tree.subagents, agentId: "new").path])
        try await waitFor { store.session(id: tree.sessionId)?.subagents.isEmpty == false }
        let agent = try #require(store.session(id: tree.sessionId)?.subagents.first)
        #expect(agent.agentType == "general-purpose")
        #expect(agent.phase == .thinking)
        try Data(#"{"agentType":"general-purpose","description":"Write tests","finished":true}"#.utf8).write(to: SubagentFiles.meta(tree.subagents, agentId: "new"))
        monitor.transcriptsChanged([SubagentFiles.meta(tree.subagents, agentId: "new").path])
        try await waitFor { store.session(id: tree.sessionId)?.subagents.first?.finished == true }
        #expect(store.session(id: tree.sessionId)?.subagents.first?.finished == true)
    }
}
