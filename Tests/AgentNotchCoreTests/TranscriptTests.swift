import Foundation
import Testing
@testable import AgentNotchCore

private func line(_ s: String) -> Data { Data(s.utf8) }

@Suite struct TranscriptLineParsing {
    @Test func aiTitleLine() {
        #expect(TranscriptLineParser.parse(line(#"{"type":"ai-title","aiTitle":"Fix login"}"#)) == .aiTitle("Fix login"))
    }

    @Test func assistantToolUseGivesActivityAndBranch() {
        let parsed = TranscriptLineParser.parse(line(#"{"type":"assistant","gitBranch":"main","isSidechain":false,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"secret cmd","description":"Run tests"}}]}}"#))
        #expect(parsed == .message(role: .assistant, branch: "main", activity: Activity(full: "Bash · Run tests", brief: "Bash"), details: MessageDetails(phase: .tool)))
    }

    @Test func toolUseWinsOverTextAndTextIsTheFallback() {
        let parsed = TranscriptLineParser.parse(line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/Users/dev/a.txt"}},{"type":"text","text":"Done reading."}]}}"#))
        #expect(parsed == .message(role: .assistant, branch: nil, activity: Activity(full: "Read · a.txt", brief: "Read"), details: MessageDetails(phase: .writing)))
        let textOnly = TranscriptLineParser.parse(line(#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"Done reading."}]}}"#))
        #expect(textOnly == .message(role: .assistant, branch: nil, activity: Activity(full: "Done reading.", brief: "Text"), details: MessageDetails(phase: .writing)))
        let toolLast = TranscriptLineParser.parse(line(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","name":"Read","input":{"file_path":"/Users/dev/a.txt"}}]}}"#))
        #expect(toolLast == .message(role: .assistant, branch: nil, activity: Activity(full: "Read · a.txt", brief: "Read"), details: MessageDetails(phase: .tool)))
    }

    @Test func userToolResultCarriesNoActivity() {
        let parsed = TranscriptLineParser.parse(line(#"{"type":"user","gitBranch":"dev","message":{"content":[{"type":"tool_result","content":"huge output"}]}}"#))
        #expect(parsed == .message(role: .user, branch: "dev", activity: nil, details: MessageDetails(phase: .thinking)))
    }

    @Test func thinkingBlockMeansThinkingAndKeepsNoActivity() {
        let parsed = TranscriptLineParser.parse(line(#"{"type":"assistant","effort":"high","message":{"model":"claude-opus-5-5","content":[{"type":"thinking","thinking":"private"}]}}"#))
        #expect(parsed == .message(role: .assistant, branch: nil, activity: nil, details: MessageDetails(phase: .thinking, model: "claude-opus-5-5", effort: "high")))
    }

    @Test func agentCallsAreRecordedForNesting() {
        let parsed = TranscriptLineParser.parse(line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01AbC","name":"Agent","input":{"description":"Scan repo"}},{"type":"tool_use","id":"toolu_02","name":"Read","input":{}}]}}"#))
        guard case .message(_, _, _, let details) = parsed else { Issue.record("not a message"); return }
        #expect(details.spawnedToolUseIds == ["toolu_01AbC"])
    }

    @Test func syntheticOrOddModelValuesAreDropped() {
        let parsed = TranscriptLineParser.parse(line(#"{"type":"assistant","effort":"high; rm -rf","message":{"model":"<synthetic>","content":[{"type":"text","text":"x"}]}}"#))
        #expect(parsed == .message(role: .assistant, branch: nil, activity: Activity(full: "x", brief: "Text"), details: MessageDetails(phase: .writing)))
    }

    @Test func sidechainLinesParseForSubagentTranscripts() {
        let parsed = TranscriptLineParser.parse(line(#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"sub"}]}}"#), includeSidechain: true)
        #expect(parsed == .message(role: .assistant, branch: nil, activity: Activity(full: "sub", brief: "Text"), details: MessageDetails(phase: .writing)))
    }

    @Test func sidechainLinesAreSkipped() {
        #expect(TranscriptLineParser.parse(line(#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"sub"}]}}"#)) == .ignored)
    }

    @Test func usageGivesTheContextTokens() {
        let parsed = TranscriptLineParser.parse(line(#"{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":6,"cache_creation_input_tokens":1200,"cache_read_input_tokens":40000,"output_tokens":900},"content":[{"type":"text","text":"x"}]}}"#))
        guard case .message(_, _, _, let details) = parsed else { Issue.record("not a message"); return }
        #expect(details.contextTokens == 41_206)          // output_tokens is not context yet
    }

    @Test func noUsageOrAllZeroUsageGivesNoTokens() {
        let none = TranscriptLineParser.parse(line(#"{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]}}"#))
        guard case .message(_, _, _, let a) = none else { Issue.record("not a message"); return }
        #expect(a.contextTokens == nil)
        // Claude Code's `<synthetic>` placeholders carry zeroed usage.
        let synthetic = TranscriptLineParser.parse(line(#"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"text","text":"x"}]}}"#))
        guard case .message(_, _, _, let b) = synthetic else { Issue.record("not a message"); return }
        #expect(b.contextTokens == nil)
    }

    @Test func userLinesCarryNoTokensOrEdits() {
        let parsed = TranscriptLineParser.parse(line(#"{"type":"user","message":{"usage":{"input_tokens":5},"content":[{"type":"tool_result","content":"ok"}]}}"#))
        #expect(parsed == .message(role: .user, branch: nil, activity: nil, details: MessageDetails(phase: .thinking)))
    }

    @Test(arguments: [
        (#"{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/dev/a.swift","old_string":"x","new_string":"y"}}"#, "/Users/dev/a.swift"),
        (#"{"type":"tool_use","name":"Write","input":{"file_path":"/Users/dev/b.md","content":"z"}}"#, "/Users/dev/b.md"),
        (#"{"type":"tool_use","name":"MultiEdit","input":{"file_path":"/Users/dev/c.go","edits":[]}}"#, "/Users/dev/c.go"),
        (#"{"type":"tool_use","name":"NotebookEdit","input":{"notebook_path":"/Users/dev/d.ipynb","new_source":"q"}}"#, "/Users/dev/d.ipynb"),
    ])
    func editToolsRecordAHashOfThePath(block: String, path: String) {
        let parsed = TranscriptLineParser.parse(line(#"{"type":"assistant","message":{"content":["# + block + #"]}}"#))
        guard case .message(_, _, _, let details) = parsed else { Issue.record("not a message"); return }
        #expect(details.editedPathHashes == [path.hashValue])
    }

    @Test func nonEditToolsRecordNoEdits() {
        let parsed = TranscriptLineParser.parse(line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/Users/dev/a.swift"}},{"type":"tool_use","name":"Bash","input":{"command":"sed -i x /Users/dev/a.swift"}}]}}"#))
        guard case .message(_, _, _, let details) = parsed else { Issue.record("not a message"); return }
        #expect(details.editedPathHashes.isEmpty)
    }

    @Test func sidechainEditsAndUsageStayOffTheMainTail() {
        let parsed = TranscriptLineParser.parse(line(#"{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":9000},"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/dev/a.swift"}}]}}"#))
        #expect(parsed == .ignored)
    }

    @Test func unknownTypesAreIgnoredNotFailures() {
        #expect(TranscriptLineParser.parse(line(#"{"type":"atis-latch","value":1}"#)) == .ignored)
        #expect(TranscriptLineParser.parse(line(#"{"type":"brand-new-type","payload":{}}"#)) == .ignored)
    }

    @Test func garbageIsADecodeFailure() {
        #expect(TranscriptLineParser.parse(line("not json at all")) == nil)
        #expect(TranscriptLineParser.parse(line("[1,2,3]")) == nil)
    }
}

@Suite struct TranscriptTailing {
    func tempFile(_ contents: String = "") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentnotch-\(UUID().uuidString).jsonl")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func attachReadsTheLatestTitleBranchAndActivity() throws {
        let tail = TranscriptTail(path: fixture("transcript-basic.jsonl"))
        let snap = try tail.attach()
        #expect(snap.aiTitle == "Second title")
        #expect(snap.branch == "feature/login-fix")
        #expect(snap.activity == Activity(full: "Edit · Login.swift", brief: "Edit"))
        #expect(snap.unavailable == false)
        #expect(snap.phase == .thinking)          // the newest message line is a tool result
    }

    @Test func attachFindsTheLatestModelAndEffort() throws {
        let url = try tempFile([
            #"{"type":"assistant","effort":"low","message":{"model":"claude-sonnet-4-5","content":[{"type":"text","text":"a"}]}}"#,
            #"{"type":"assistant","effort":"high","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","name":"Bash","input":{"description":"Run"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
        ].joined(separator: "\n") + "\n")
        let snap = try TranscriptTail(path: url).attach()
        #expect(snap.model == "claude-opus-5-5")
        #expect(snap.effort == "high")
        #expect(snap.phase == .thinking)
        #expect(snap.activity?.full == "Bash · Run")
    }

    @Test func attachKeepsTheNewestContextTokensButNoEdits() throws {
        let url = try tempFile([
            #"{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":3,"cache_read_input_tokens":1000},"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/dev/old.swift"}}]}}"#,
            #"{"type":"assistant","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":2000},"content":[{"type":"text","text":"a"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"next"}]}}"#,
        ].joined(separator: "\n") + "\n")
        let snap = try TranscriptTail(path: url).attach()
        #expect(snap.contextTokens == 2005)
        #expect(snap.editedPathHashes.isEmpty)       // edits before launch belong to no turn we saw start
    }

    @Test func readNewCarriesTheLatestTokensAndEveryEdit() throws {
        let url = try tempFile()
        let tail = TranscriptTail(path: url)
        _ = try tail.attach()
        let h = FileHandle(forWritingAtPath: url.path)!
        h.seekToEndOfFile()
        h.write(Data(([
            #"{"type":"assistant","message":{"usage":{"input_tokens":100},"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/dev/a.swift"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"assistant","message":{"usage":{"input_tokens":250},"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/dev/b.swift"}}]}}"#,
        ].joined(separator: "\n") + "\n").utf8))
        h.closeFile()
        let update = try tail.readNew()
        #expect(update?.contextTokens == 250)
        #expect(update?.editedPathHashes == ["/Users/dev/a.swift".hashValue, "/Users/dev/b.swift".hashValue])
    }

    @Test func readNewTracksThePhaseOfTheNewestLine() throws {
        let url = try tempFile()
        let tail = TranscriptTail(path: url)
        _ = try tail.attach()
        func append(_ s: String) {
            let h = FileHandle(forWritingAtPath: url.path)!
            h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); h.closeFile()
        }
        append(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"description":"Build"}}]}}"#)
        #expect(try tail.readNew()?.phase == .tool)
        append(#"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#)
        let thinking = try tail.readNew()
        #expect(thinking?.phase == .thinking)
        #expect(thinking?.activity == nil)        // the row keeps "Bash · Build" but shows the verb
        append(#"{"type":"assistant","message":{"content":[{"type":"text","text":"All green."}]}}"#)
        #expect(try tail.readNew()?.phase == .writing)
    }

    @Test func attachFromStartReadsSidechainLinesAndEveryAgentCall() throws {
        let url = try tempFile([
            #"{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5","content":[{"type":"tool_use","id":"toolu_a","name":"Agent","input":{"description":"x"}}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"toolu_b","name":"Agent","input":{"description":"y"}}]}}"#,
            #"{"type":"assistant","isSidechain":true,"effort":"medium","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"p"}}]}}"#,
        ].joined(separator: "\n") + "\n")
        let snap = try TranscriptTail(path: url, includeSidechain: true).attachFromStart()
        #expect(snap.spawnedToolUseIds == ["toolu_a", "toolu_b"])
        #expect(snap.model == "claude-haiku-4-5")
        #expect(snap.effort == "medium")
        #expect(snap.activity == Activity(full: "Grep", brief: "Grep"))
        #expect(snap.phase == .tool)
    }

    @Test func attachScansBackwardsAcrossSmallChunks() throws {
        let tail = TranscriptTail(path: fixture("transcript-basic.jsonl"), chunkSize: 100)
        let snap = try tail.attach()
        #expect(snap.aiTitle == "Second title")
        #expect(snap.activity?.full == "Edit · Login.swift")
    }

    @Test func partialLineIsCompletedOnTheNextRead() throws {
        let url = try tempFile(#"{"type":"ai-title","aiTitle":"T1"}"# + "\n")
        let tail = TranscriptTail(path: url)
        _ = try tail.attach()
        let full = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"description":"Run tests"}}]}}"# + "\n"
        let h = FileHandle(forWritingAtPath: url.path)!
        h.seekToEndOfFile(); h.write(Data(full.prefix(40).utf8)); h.closeFile()
        let first = try tail.readNew()
        #expect(first?.activity == nil)
        let h2 = FileHandle(forWritingAtPath: url.path)!
        h2.seekToEndOfFile(); h2.write(Data(full.dropFirst(40).utf8)); h2.closeFile()
        let second = try tail.readNew()
        #expect(second?.activity?.full == "Bash · Run tests")
        #expect(try tail.readNew() == nil)
    }

    @Test func truncationTriggersReattach() throws {
        let url = try tempFile(#"{"type":"ai-title","aiTitle":"Long title here"}"# + "\n" + #"{"type":"ai-title","aiTitle":"Second"}"# + "\n")
        let tail = TranscriptTail(path: url)
        #expect(try tail.attach().aiTitle == "Second")
        try Data((#"{"type":"ai-title","aiTitle":"New"}"# + "\n").utf8).write(to: url)
        let update = try tail.readNew()
        #expect(update?.aiTitle == "New")
    }

    @Test func twentyMalformedLinesMakeActivityUnavailable() throws {
        let url = try tempFile(String(repeating: "garbage line\n", count: 20))
        let tail = TranscriptTail(path: url)
        let snap = try tail.attach()
        #expect(snap.unavailable == true)
        let h = FileHandle(forWritingAtPath: url.path)!
        h.seekToEndOfFile(); h.write(Data((#"{"type":"ai-title","aiTitle":"ok"}"# + "\n").utf8)); h.closeFile()
        let update = try tail.readNew()
        #expect(update?.unavailable == false)
    }

    @Test func nineteenMalformedLinesAreTolerated() throws {
        let url = try tempFile(String(repeating: "garbage line\n", count: 19))
        let snap = try TranscriptTail(path: url).attach()
        #expect(snap.unavailable == false)
    }
}
