import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct ActivityLines {
    @Test func bashShowsTheDescriptionAndNeverTheCommand() {
        let a = ActivitySummary.forToolUse(name: "Bash", input: ["command": "rm -rf /tmp/secret-dir", "description": "Clean temp dir"])
        #expect(a.full == "Bash · Clean temp dir")
        #expect(!a.full.contains("rm -rf"))
        #expect(a.brief == "Bash")
        let noDesc = ActivitySummary.forToolUse(name: "Bash", input: ["command": "ls"])
        #expect(noDesc.full == "Bash")
    }

    @Test func fileToolsShowTheBasenameOnly() {
        #expect(ActivitySummary.forToolUse(name: "Edit", input: ["file_path": "/Users/dev/work/repo/src/Login.swift"]).full == "Edit · Login.swift")
        #expect(ActivitySummary.forToolUse(name: "Read", input: ["file_path": "/Users/dev/x/README.md"]).full == "Read · README.md")
        #expect(ActivitySummary.forToolUse(name: "NotebookEdit", input: ["notebook_path": "/Users/dev/x/analysis.ipynb"]).full == "NotebookEdit · analysis.ipynb")
        #expect(ActivitySummary.forToolUse(name: "Write", input: [:]).full == "Write")
    }

    @Test func agentAndTaskShowTheDescription() {
        #expect(ActivitySummary.forToolUse(name: "Agent", input: ["description": "Review the diff", "prompt": "long secret prompt"]).full == "Agent · Review the diff")
        #expect(ActivitySummary.forToolUse(name: "Task", input: ["description": "Search docs"]).full == "Task · Search docs")
    }

    @Test(arguments: ["Grep", "Glob", "WebFetch", "WebSearch"])
    func searchToolsShowTheNameOnly(name: String) {
        let a = ActivitySummary.forToolUse(name: name, input: ["pattern": "AKIA[0-9A-Z]{16}", "url": "https://internal.example/secret", "query": "customer NIK"])
        #expect(a.full == name)
        #expect(a.brief == name)
    }

    @Test func mcpToolsShowServerAndTool() {
        let a = ActivitySummary.forToolUse(name: "mcp__github__create_pull_request", input: ["title": "x"])
        #expect(a.full == "github · create_pull_request")
        #expect(a.brief == "github · create_pull_request")
    }

    @Test func unknownToolsShowTheNameOnly() {
        #expect(ActivitySummary.forToolUse(name: "FancyTool", input: ["anything": "data"]).full == "FancyTool")
    }

    @Test func textBlockShowsItsFirstNonEmptyLine() {
        let a = ActivitySummary.forText("\n\n  I'll start by reading the plan.  \nThen more.")
        #expect(a?.full == "I'll start by reading the plan.")
        #expect(a?.brief == "Text")
        #expect(ActivitySummary.forText("  \n\n ") == nil)
    }

    @Test func masksLongTokensAndCredentialAssignments() {
        #expect(ActivitySummary.mask("push ghp_abcdefghijklmnopqrstuvwxyz0123456789 now") == "push ••• now")
        #expect(ActivitySummary.mask("export TOKEN=abc123 && run") == "export TOKEN=••• && run")
        #expect(ActivitySummary.mask("api_key: sk-live-42") == "api_key=•••")
        #expect(ActivitySummary.mask("Authorization: Bearer") == "Authorization=•••")
        #expect(ActivitySummary.mask("password = hunter2") == "password=•••")
        #expect(ActivitySummary.mask("short words stay") == "short words stay")
    }

    @Test func maskingAppliesToDescriptionsAndTruncatesTo80() {
        let long = String(repeating: "word ", count: 30)
        let a = ActivitySummary.forToolUse(name: "Bash", input: ["description": "Set SECRET=abc then " + long])
        #expect(a.full.hasPrefix("Bash · Set SECRET=•••"))
        #expect(a.full.count <= 80)
    }
}
