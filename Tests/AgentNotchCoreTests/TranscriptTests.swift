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

/// Background Bash tasks (0.6.0, D41, F22, F23). Every line here is synthetic (R6).
@Suite struct BackgroundTaskRecords {
    static let start = #"{"type":"assistant","isSidechain":false,"timestamp":"2026-11-09T09:08:09.000Z","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"toolu_01AAA","name":"Bash","input":{"command":"npm run e2e --token=hunter2","description":"Run e2e suite","run_in_background":true}}]}}"#
    static let ack = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01AAA","content":"Command running in background with ID: b1x2y3z4w. Output is being written to: /private/tmp/claude-501/-Users-dev-work-my-app/s1/tasks/b1x2y3z4w.output","is_error":false}]}}"#
    static let notification = #"<task-notification>\n<task-id>b1x2y3z4w</task-id>\n<tool-use-id>toolu_01AAA</tool-use-id>\n<output-file>/private/tmp/claude-501/-Users-dev-work-my-app/s1/tasks/b1x2y3z4w.output</output-file>\n<status>completed</status>\n<summary>Background command \"Run e2e suite\" completed (exit code 0)</summary>\n</task-notification>"#
    static var queueOperation: String { #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-09T09:12:00.000Z","sessionId":"s1","content":""# + notification + #""}"# }
    static var attachment: String { #"{"type":"attachment","isSidechain":true,"attachment":{"type":"queued_command","prompt":""# + notification + #""}}"# }
    static var metaUser: String { #"{"type":"user","isSidechain":true,"isMeta":true,"message":{"role":"user","content":""# + notification + #""}}"# }
    static let launchError = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01AAA","content":"Permission to use Bash has been denied.","is_error":true}]}}"#

    private func details(_ s: String, includeSidechain: Bool = false) -> MessageDetails? {
        guard case .message(_, _, _, let details) = TranscriptLineParser.parse(line(s), includeSidechain: includeSidechain) else { return nil }
        return details
    }

    @Test func aBackgroundBashCallIsAStart() throws {
        let starts = try #require(details(Self.start)).backgroundStarts
        #expect(starts == [BackgroundStart(
            toolUseId: "toolu_01AAA", activity: Activity(full: "Bash · Run e2e suite", brief: "Bash"),
            startedAt: Date(timeIntervalSince1970: 1_794_215_289)
        )])
    }

    @Test func theCommandNeverReachesTheActivity() throws {
        let start = try #require(details(Self.start)?.backgroundStarts.first)
        #expect(!start.activity.full.contains("npm"))
        #expect(!start.activity.full.contains("hunter2"))
    }

    @Test func aForegroundOrNonBashCallIsNotAStart() {
        let foreground = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01B","name":"Bash","input":{"command":"ls","description":"List"}}]}}"#
        let explicitFalse = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01C","name":"Bash","input":{"command":"ls","run_in_background":false}}]}}"#
        let notBash = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01D","name":"Agent","input":{"description":"x","run_in_background":true}}]}}"#
        #expect(details(foreground)?.backgroundStarts == [])
        #expect(details(explicitFalse)?.backgroundStarts == [])
        #expect(details(notBash)?.backgroundStarts == [])
    }

    @Test func aStartWithoutATimestampLeavesTheTimeToTheReader() throws {
        let noTime = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01E","name":"Bash","input":{"run_in_background":true}}]}}"#
        let start = try #require(details(noTime)?.backgroundStarts.first)
        #expect(start.startedAt == nil)
        #expect(start.activity == Activity(full: "Bash", brief: "Bash"))
    }

    @Test func theQueueOperationCopyClosesTheTask() {
        #expect(TranscriptLineParser.parse(line(Self.queueOperation)) == .taskRecords(closed: ["toolu_01AAA"]))
    }

    @Test(arguments: ["enqueue", "dequeue", "remove", "something-new"])
    func everyQueueOperationIsAccepted(operation: String) {
        let s = Self.queueOperation.replacingOccurrences(of: #""operation":"enqueue""#, with: #""operation":""# + operation + #"""#)
        #expect(TranscriptLineParser.parse(line(s)) == .taskRecords(closed: ["toolu_01AAA"]))
    }

    @Test func theAttachmentCopyClosesTheTaskInASubagentTranscript() {
        #expect(TranscriptLineParser.parse(line(Self.attachment), includeSidechain: true) == .taskRecords(closed: ["toolu_01AAA"]))
    }

    @Test func theMetaUserCopyClosesTheTaskAndStillMeansThinking() throws {
        let d = try #require(details(Self.metaUser, includeSidechain: true))
        #expect(d.closedToolUseIds == ["toolu_01AAA"])
        #expect(d.phase == .thinking)
    }

    @Test func aNotificationInATextBlockClosesTheTask() throws {
        let s = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":""# + Self.notification + #""}]}}"#
        #expect(try #require(details(s)).closedToolUseIds == ["toolu_01AAA"])
    }

    @Test func anyStatusClosesAndSeveralNotificationsAreRead() {
        let two = Self.notification.replacingOccurrences(of: "completed", with: "failed")
            + Self.notification.replacingOccurrences(of: "toolu_01AAA", with: "toolu_01BBB")
        let s = #"{"type":"queue-operation","operation":"enqueue","content":""# + two + #""}"#
        #expect(TranscriptLineParser.parse(line(s)) == .taskRecords(closed: ["toolu_01AAA", "toolu_01BBB"]))
    }

    @Test func theSummaryOutputFileAndTaskIdAreNeverKept() {
        for (s, sidechain) in [(Self.queueOperation, false), (Self.attachment, true), (Self.metaUser, true), (Self.ack, false)] {
            let kept = String(describing: TranscriptLineParser.parse(line(s), includeSidechain: sidechain))
            #expect(!kept.contains("exit code"))
            #expect(!kept.contains("private/tmp"))
            #expect(!kept.contains("b1x2y3z4w"))
        }
    }

    @Test func anErroredToolResultIsCollectedAndAnAcknowledgementIsNot() {
        #expect(details(Self.launchError)?.erroredToolUseIds == ["toolu_01AAA"])
        #expect(details(Self.launchError)?.phase == .thinking)
        #expect(details(Self.ack)?.erroredToolUseIds == [])
        #expect(details(Self.ack)?.closedToolUseIds == [])
    }

    @Test func oversizedOrMalformedIdsAreDropped() {
        let long = String(repeating: "x", count: 65)
        let badStart = Self.start.replacingOccurrences(of: "toolu_01AAA", with: "toolu 01/AAA")
        #expect(details(badStart)?.backgroundStarts == [])
        let longClose = Self.queueOperation.replacingOccurrences(of: "toolu_01AAA", with: long)
        #expect(TranscriptLineParser.parse(line(longClose)) == .ignored)
        let badStatus = Self.queueOperation.replacingOccurrences(of: "<status>completed</status>", with: "<status>done; rm -rf</status>")
        #expect(TranscriptLineParser.parse(line(badStatus)) == .ignored)
        let noStatus = Self.queueOperation.replacingOccurrences(of: "<status>completed</status>", with: "")
        #expect(TranscriptLineParser.parse(line(noStatus)) == .ignored)
        let badError = Self.launchError.replacingOccurrences(of: "toolu_01AAA", with: long)
        #expect(details(badError)?.erroredToolUseIds == [])
    }

    @Test func queueLinesWithoutANotificationAreIgnored() {
        #expect(TranscriptLineParser.parse(line(#"{"type":"queue-operation","operation":"enqueue","content":"fix the tests"}"#)) == .ignored)
        #expect(TranscriptLineParser.parse(line(#"{"type":"attachment","attachment":{"type":"queued_command","prompt":"hello"}}"#)) == .ignored)
    }

    @Test func sidechainRecordsStayOffTheMainTail() {
        let sidechainStart = Self.start.replacingOccurrences(of: #""isSidechain":false"#, with: #""isSidechain":true"#)
        #expect(TranscriptLineParser.parse(line(sidechainStart)) == .ignored)
        #expect(TranscriptLineParser.parse(line(Self.attachment)) == .ignored)
        #expect(TranscriptLineParser.parse(line(Self.metaUser)) == .ignored)
    }
}

@Suite struct BackgroundTaskTailing {
    typealias R = BackgroundTaskRecords

    func tempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentnotch-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    /// The newest lines give every field `attach` looks for, so its scan is complete after them.
    static let completeTail = [
        #"{"type":"ai-title","aiTitle":"Ship it"}"#,
        #"{"type":"assistant","gitBranch":"main","effort":"high","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10},"content":[{"type":"text","text":"Done."}]}}"#,
    ]

    @Test func readNewCarriesStartsClosesAndErrors() throws {
        let url = try tempFile([])
        let tail = TranscriptTail(path: url)
        _ = try tail.attach()
        let h = FileHandle(forWritingAtPath: url.path)!
        h.seekToEndOfFile()
        h.write(Data(([R.start, R.ack, R.launchError, R.queueOperation].joined(separator: "\n") + "\n").utf8))
        h.closeFile()
        let update = try #require(try tail.readNew())
        #expect(update.backgroundStarts.map(\.toolUseId) == ["toolu_01AAA"])
        #expect(update.closedToolUseIds == ["toolu_01AAA"])
        #expect(update.erroredToolUseIds == ["toolu_01AAA"])
        #expect(update.activity?.full == "Bash · Run e2e suite")    // the queue line leaves the activity alone
    }

    @Test func attachFindsAnOpenStart() throws {
        let snap = try TranscriptTail(path: tempFile([R.start, R.ack] + Self.completeTail)).attach()
        #expect(snap.backgroundStarts.map(\.toolUseId) == ["toolu_01AAA"])
        #expect(snap.aiTitle == "Ship it")
    }

    @Test func attachLeavesAStartWithANewerCloseClosed() throws {
        let snap = try TranscriptTail(path: tempFile([R.start, R.ack, R.queueOperation] + Self.completeTail)).attach()
        #expect(snap.backgroundStarts.isEmpty)
        #expect(snap.closedToolUseIds == ["toolu_01AAA"])
    }

    @Test func attachLeavesADeniedStartClosed() throws {
        let snap = try TranscriptTail(path: tempFile([R.start, R.launchError] + Self.completeTail)).attach()
        #expect(snap.backgroundStarts.isEmpty)
    }

    @Test func attachFindsAStartPastTheCompletePointAndDecodesNothingElseThere() throws {
        // 30 undecodable lines sit between the start and the complete tail: the byte filter skips them.
        let filler = Array(repeating: "not json, never decoded", count: 30)
        let tail = TranscriptTail(path: try tempFile([R.start] + filler + Self.completeTail), chunkSize: 128)
        let snap = try tail.attach()
        #expect(snap.backgroundStarts.map(\.toolUseId) == ["toolu_01AAA"])
        #expect(snap.aiTitle == "Ship it")
        #expect(tail.decodeFailures == 0)
        #expect(snap.unavailable == false)
    }

    @Test func attachKeepsStartsOldestFirst() throws {
        let second = R.start.replacingOccurrences(of: "toolu_01AAA", with: "toolu_01BBB")
        let snap = try TranscriptTail(path: tempFile([R.start, second] + Self.completeTail)).attach()
        #expect(snap.backgroundStarts.map(\.toolUseId) == ["toolu_01AAA", "toolu_01BBB"])
    }

    @Test func attachStopsAtTheBackscanLimit() throws {
        let filler = Array(repeating: #"{"type":"user","message":{"content":[{"type":"tool_result","content":"padding padding padding"}]}}"#, count: 40)
        let tail = TranscriptTail(path: try tempFile([R.start] + filler + Self.completeTail), chunkSize: 256, maxBackscan: 1024)
        #expect(try tail.attach().backgroundStarts.isEmpty)       // a known limit (D41)
    }
}
