import Foundation
import Testing
@testable import AgentNotchCore

private func agLine(_ s: String) -> Data { Data(s.utf8) }

@Suite struct AntigravityTranscriptParsing {
    @Test func parsesUserInputAsThinking() {
        let parsed = TranscriptLineParser.parse(
            agLine(#"{"step_index":0,"type":"USER_INPUT","status":"DONE","content":"hello"}"#),
            format: .antigravity
        )
        #expect(parsed == .message(role: .user, branch: nil, activity: nil, details: MessageDetails(phase: .thinking)))
    }

    @Test func parsesPlannerResponseModelEffortTokensToolsAndEdits() {
        let parsed = TranscriptLineParser.parse(
            agLine(#"{"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","model":"gemini-4-neon-xhigh","input_tokens":2080,"cache_read_tokens":6699,"output_tokens":231,"thinking":"working","tool_calls":[{"name":"edit_file","args":{"Path":"/Users/dev/work/app/Models.swift","Target":"x","Replacement":"y"}},{"name":"run_command","args":{"CommandLine":"curl -H 'Authorization: secret' https://internal.example","toolSummary":"Unit test execution"}}]}"#),
            format: .antigravity
        )
        guard case .message(let role, let branch, let activity, let details) = parsed else {
            Issue.record("expected message"); return
        }
        #expect(role == .assistant)
        #expect(branch == nil)
        #expect(details.phase == .tool)
        #expect(details.model == "gemini-4-neon")
        #expect(details.effort == "xhigh")
        #expect(details.contextTokens == 8_779)
        #expect(details.editedPathHashes == ["/Users/dev/work/app/Models.swift".hashValue])
        #expect(activity == Activity(full: "Run · Unit test execution", brief: "Run"))
        #expect(!(activity?.full.contains("curl") ?? false))
    }

    @Test func parsesPlannerResponseTextAsWritingAndThinkingOnlyAsThinking() {
        let writing = TranscriptLineParser.parse(
            agLine(#"{"type":"PLANNER_RESPONSE","model":"gemini-2.5-pro-high","input_tokens":1000,"cache_read_tokens":4000,"content":"All unit tests are now passing.\nDetails below."}"#),
            format: .antigravity
        )
        guard case .message(_, _, let activity, let details) = writing else { Issue.record("expected message"); return }
        #expect(details.phase == .writing)
        #expect(details.model == "gemini-2.5-pro")
        #expect(details.effort == "high")
        #expect(details.contextTokens == 5_000)
        #expect(activity == Activity(full: "All unit tests are now passing.", brief: "Text"))

        let thinkingOnly = TranscriptLineParser.parse(
            agLine(#"{"type":"PLANNER_RESPONSE","model":"gemini-2.5-flash","thinking":"reasoning..."}"#),
            format: .antigravity
        )
        guard case .message(_, _, let act2, let det2) = thinkingOnly else { Issue.record("expected message"); return }
        #expect(det2.phase == .thinking)
        #expect(det2.model == "gemini-2.5-flash")
        #expect(det2.effort == nil)
        #expect(det2.contextTokens == nil)
        #expect(act2 == nil)
    }

    @Test func splitsGeminiEffortSuffixesCleanly() {
        #expect(TranscriptLineParser.splitModelEffort("gemini-4-neon-xhigh") == ("gemini-4-neon", "xhigh"))
        #expect(TranscriptLineParser.splitModelEffort("gemini-4-neon-high") == ("gemini-4-neon", "high"))
        #expect(TranscriptLineParser.splitModelEffort("gemini-3-pro-medium") == ("gemini-3-pro", "medium"))
        #expect(TranscriptLineParser.splitModelEffort("gemini-2.5-flash-low") == ("gemini-2.5-flash", "low"))
        #expect(TranscriptLineParser.splitModelEffort("gemini-4-neon-max") == ("gemini-4-neon", "max"))
        #expect(TranscriptLineParser.splitModelEffort("gemini-2.5-pro") == ("gemini-2.5-pro", nil))
        #expect(TranscriptLineParser.splitModelEffort("<synthetic>") == (nil, nil))
    }

    @Test func parsesGenericToolResultsAndIgnoresSystemMessages() {
        let running = TranscriptLineParser.parse(
            agLine(#"{"type":"GENERIC","status":"RUNNING","content":"compiling..."}"#),
            format: .antigravity
        )
        #expect(running == .message(role: .user, branch: nil, activity: nil, details: MessageDetails(phase: .tool)))

        let done = TranscriptLineParser.parse(
            agLine(#"{"type":"GENERIC","status":"DONE","content":"ok"}"#),
            format: .antigravity
        )
        #expect(done == .message(role: .user, branch: nil, activity: nil, details: MessageDetails(phase: .thinking)))

        let sys = TranscriptLineParser.parse(
            agLine(#"{"type":"SYSTEM_MESSAGE","status":"DONE","content":"reminder"}"#),
            format: .antigravity
        )
        #expect(sys == .ignored)
    }

    @Test func antigravityToolSummariesAreD11SafeAndMaskSecrets() {
        let cmd = ActivitySummary.forAntigravityToolCall(
            name: "run_command",
            args: ["CommandLine": "psql postgres://user:hunter2@prod/db", "toolSummary": "Check token=abc123 status"]
        )
        #expect(cmd.full == "Run · Check token=••• status")
        #expect(cmd.brief == "Run")
        #expect(!cmd.full.contains("psql"))

        let cmdNoSummary = ActivitySummary.forAntigravityToolCall(name: "run_command", args: ["CommandLine": "rm -rf /tmp/x"])
        #expect(cmdNoSummary == Activity(full: "Run", brief: "Run"))

        // Antigravity encodes `tool_calls[].args` values as JSON-serialized strings (F34).
        let quotedCmd = ActivitySummary.forAntigravityToolCall(
            name: "run_command",
            args: ["CommandLine": "\"git status\"", "toolSummary": "\"Inspect repo status\""]
        )
        #expect(quotedCmd == Activity(full: "Run · Inspect repo status", brief: "Run"))
        let quotedRead = ActivitySummary.forAntigravityToolCall(
            name: "read_file",
            args: ["Path": "\"/Users/dev/work/app/Models.swift\""]
        )
        #expect(quotedRead == Activity(full: "Read · Models.swift", brief: "Read"))

        #expect(ActivitySummary.forAntigravityToolCall(name: "read_file", args: ["Path": "/Users/dev/secret/App.swift"]) == Activity(full: "Read · App.swift", brief: "Read"))
        #expect(ActivitySummary.forAntigravityToolCall(name: "write_to_file", args: ["TargetFile": "/Users/dev/secret/New.swift", "CodeContent": "secret"]) == Activity(full: "Write · New.swift", brief: "Write"))
        #expect(ActivitySummary.forAntigravityToolCall(name: "replace_file_content", args: ["TargetFile": "/Users/dev/a/B.swift"]) == Activity(full: "Edit · B.swift", brief: "Edit"))
        #expect(ActivitySummary.forAntigravityToolCall(name: "invoke_subagent", args: ["Role": "Codebase Researcher", "Prompt": "PRIVATE PROMPT"]) == Activity(full: "Subagent · Codebase Researcher", brief: "Subagent"))
        #expect(ActivitySummary.forAntigravityToolCall(name: "ask_question", args: ["questions": [["question": "Secret?"]]]) == Activity(full: "Ask", brief: "Ask"))
        #expect(ActivitySummary.forAntigravityToolCall(name: "grep_search", args: ["Query": "AKIA1234567890ABCDEF"]) == Activity(full: "Search", brief: "Search"))
        #expect(ActivitySummary.forAntigravityToolCall(name: "search_web", args: ["query": "private client"]) == Activity(full: "Web", brief: "Web"))
        #expect(ActivitySummary.forAntigravityToolCall(name: "mcp__github__list_prs", args: ["repo": "private"]) == Activity(full: "github · list_prs", brief: "github · list_prs"))
    }

    @Test(arguments: [
        ("edit_file", "Path", "/Users/dev/a.swift"),
        ("write_file", "Path", "/Users/dev/b.swift"),
        ("write_to_file", "TargetFile", "/Users/dev/c.swift"),
        ("replace_file_content", "TargetFile", "/Users/dev/d.swift"),
        ("multi_replace_file_content", "TargetFile", "/Users/dev/e.swift"),
    ])
    func tracksAllAntigravityEditTools(tool: String, key: String, path: String) {
        let parsed = TranscriptLineParser.parse(
            agLine(#"{"type":"PLANNER_RESPONSE","tool_calls":[{"name":"\#(tool)","args":{"\#(key)":"\"\#(path)\""}}]}"#),
            format: .antigravity
        )
        guard case .message(_, _, _, let details) = parsed else { Issue.record("expected message"); return }
        #expect(details.editedPathHashes == [path.hashValue])
    }

    @Test func tailsFixtureBackscanAndIncrementalAppends() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ag-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: temp) }
        try fixtureData("antigravity-transcript.jsonl").write(to: temp)

        let tail = TranscriptTail(path: temp, format: .antigravity)
        let attached = try tail.attach()
        #expect(attached.model == "gemini-4-neon")
        #expect(attached.effort == "high")
        #expect(attached.contextTokens == 120_000)
        #expect(attached.activity == Activity(full: "Run · Unit test execution", brief: "Run"))
        #expect(attached.phase == .tool)
        #expect(attached.editedPathHashes.isEmpty) // attach back-scan never counts prior turns' edits

        // Append a finished tool result + new edit call incrementally
        let append1 = #"{"step_index":6,"type":"GENERIC","status":"DONE","content":"passed"}"# + "\n"
            + #"{"step_index":7,"type":"PLANNER_RESPONSE","model":"gemini-4-neon-xhigh","input_tokens":30000,"cache_read_tokens":120000,"tool_calls":[{"name":"write_file","args":{"Path":"/Users/dev/work/agent-notch/Sources/New.swift"}}]}"# + "\n"
        let fh = try FileHandle(forWritingTo: temp)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(append1.utf8))
        try fh.close()

        let next = try #require(try tail.readNew())
        #expect(next.model == "gemini-4-neon")
        #expect(next.effort == "xhigh")
        #expect(next.contextTokens == 150_000)
        #expect(next.activity == Activity(full: "Write · New.swift", brief: "Write"))
        #expect(next.phase == .tool)
        #expect(next.editedPathHashes == ["/Users/dev/work/agent-notch/Sources/New.swift".hashValue])
    }
}
