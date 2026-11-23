import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct SourceClassification {
    @Test(arguments: [
        ("/Users/dev/.cursor/extensions/anthropic.claude-code-2.1.310-darwin-arm64/resources/native-binary/claude", Source.cursor),
        ("/Users/dev/.vscode/extensions/anthropic.claude-code-2.1.235-darwin-arm64/resources/native-binary/claude", .vscode),
        ("/Users/dev/.local/share/claude/versions/2.1.296", .terminal),
        ("/Users/dev/.local/bin/claude", .terminal),
        ("/opt/homebrew/bin/claude", .terminal),
        ("/Users/dev/somewhere/else/node", .unknown),
    ])
    func classifiesByExecutablePath(path: String, expected: Source) {
        #expect(Source.classify(executablePath: path) == expected)
    }

    @Test func nilPathIsUnknown() {
        #expect(Source.classify(executablePath: nil) == .unknown)
    }

    @Test(arguments: [
        "/Users/dev/.local/share/claude/versions/2.1.328",
        "/Users/dev/.local/bin/claude",
        "/opt/homebrew/bin/claude",
    ])
    func classifiesOrcaChatByProviderExecAncestor(path: String) {
        let ancestors = [
            "/Applications/Orca.app/Contents/MacOS/orca-provider-exec",
            "/Users/dev/Library/Application Support/orca/daemon-host/macos/terminal-host-abc/app.noindex/Orca Agents.app/Contents/MacOS/Orca Agents",
        ]
        #expect(Source.classify(executablePath: path, ancestorPaths: ancestors) == .orca)
    }

    @Test func classifiesOrcaTerminalByOrcaAgentsAncestorThroughShellAndLogin() {
        let ancestors = [
            "/bin/zsh",
            "/usr/bin/login",
            "/Users/dev/Library/Application Support/orca/daemon-host/macos/terminal-host-abc/app.noindex/Orca Agents.app/Contents/MacOS/Orca Agents",
        ]
        #expect(Source.classify(executablePath: "/Users/dev/.local/share/claude/versions/2.1.328", ancestorPaths: ancestors) == .orca)
    }

    @Test func classifiesTerminalAppAndEmptyAncestorsAsTerminal() {
        let path = "/Users/dev/.local/share/claude/versions/2.1.328"
        let terminalAncestors = ["/bin/zsh", "/usr/bin/login", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"]
        #expect(Source.classify(executablePath: path, ancestorPaths: terminalAncestors) == .terminal)
        #expect(Source.classify(executablePath: path, ancestorPaths: []) == .terminal)
    }

    @Test func ideExtensionsBeatOrcaAncestors() {
        let orcaAncestors = ["/Applications/Orca.app/Contents/MacOS/orca-provider-exec"]
        let cursorPath = "/Users/dev/.cursor/extensions/anthropic.claude-code-2.1.328-darwin-arm64/resources/native-binary/claude"
        let vscodePath = "/Users/dev/.vscode/extensions/anthropic.claude-code-2.1.328-darwin-arm64/resources/native-binary/claude"
        #expect(Source.classify(executablePath: cursorPath, ancestorPaths: orcaAncestors) == .cursor)
        #expect(Source.classify(executablePath: vscodePath, ancestorPaths: orcaAncestors) == .vscode)
    }

    @Test func nonClaudeBinaryNeverClassifiesAsOrca() {
        let orcaAncestors = ["/Applications/Orca.app/Contents/MacOS/orca-provider-exec"]
        #expect(Source.classify(executablePath: "/Users/dev/somewhere/else/node", ancestorPaths: orcaAncestors) == .unknown)
    }
}

@Suite struct ProcessProbing {
    @Test func ownPidIsAliveAndHasAnExecutablePath() {
        let pid = ProcessInfo.processInfo.processIdentifier
        #expect(ProcessProbe.isAlive(pid))
        #expect(ProcessProbe.executablePath(pid) != nil)
    }

    @Test func exitedPidIsDead() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        #expect(!ProcessProbe.isAlive(p.processIdentifier))
        #expect(ProcessProbe.executablePath(p.processIdentifier) == nil)
        #expect(ProcessProbe.parentPid(p.processIdentifier) == nil)
    }

    @Test func ttyIsNilOrATtyName() {
        let tty = ProcessProbe.tty(ProcessInfo.processInfo.processIdentifier)
        #expect(tty == nil || tty!.hasPrefix("tty"))
    }

    @Test func ancestorWalkTerminatesCleanlyForOwnPid() {
        let paths = ProcessProbe.ancestorExecutablePaths(ProcessInfo.processInfo.processIdentifier)
        #expect(paths.count <= 16)
    }

    @Test func ancestorWalkHandlesCyclesDepthLimitAndUnreadableIntermediary() {
        // 500 -> 400 (zsh) -> 300 (nil exe, e.g. setuid login) -> 200 (Orca Agents) -> 1
        let parents: [Int32: Int32] = [500: 400, 400: 300, 300: 200, 200: 1]
        let exes: [Int32: String] = [400: "/bin/zsh", 200: "/Users/dev/Orca Agents.app/Contents/MacOS/Orca Agents"]
        let walked = ProcessProbe.ancestorExecutablePaths(500, parentPid: { parents[$0] }, executablePath: { exes[$0] })
        #expect(walked == ["/bin/zsh", "/Users/dev/Orca Agents.app/Contents/MacOS/Orca Agents"])

        // Cycle: 10 -> 20 -> 10
        let cyclic: [Int32: Int32] = [10: 20, 20: 10]
        let cyclicWalk = ProcessProbe.ancestorExecutablePaths(10, parentPid: { cyclic[$0] }, executablePath: { "/bin/p\($0)" })
        #expect(cyclicWalk == ["/bin/p20"])

        // Depth cap
        let capped = ProcessProbe.ancestorExecutablePaths(500, maxDepth: 1, parentPid: { parents[$0] }, executablePath: { exes[$0] })
        #expect(capped == ["/bin/zsh"])
    }
}

@Suite struct AntigravityProcessProbing {
    @Test func classifiesAntigravityHostFromAncestorsTtyAndSurfaceFallback() {
        #expect(Source.classifyAntigravity(
            executablePath: "/Users/dev/.local/bin/agy",
            ancestorPaths: ["/Applications/Orca.app/Contents/MacOS/orca-provider-exec"]
        ) == .orca)
        #expect(Source.classifyAntigravity(
            executablePath: "/Users/dev/.local/bin/agy",
            ancestorPaths: ["/bin/zsh", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"],
            tty: "ttys002"
        ) == .terminal)
        #expect(Source.classifyAntigravity(
            executablePath: "/Users/dev/.local/bin/agy",
            ancestorPaths: ["/Applications/Cursor.app/Contents/MacOS/Cursor"]
        ) == .cursor)
        #expect(Source.classifyAntigravity(
            executablePath: "/Users/dev/.local/bin/agy",
            ancestorPaths: ["/Applications/Visual Studio Code.app/Contents/MacOS/Electron"]
        ) == .vscode)
        #expect(Source.classifyAntigravity(
            executablePath: "/Applications/Gemini.app/Contents/MacOS/Gemini"
        ) == .antigravityApp)
        #expect(Source.classifyAntigravity(
            executablePath: "/Applications/Antigravity.app/Contents/MacOS/Antigravity"
        ) == .antigravityIDE)
        #expect(Source.classifyAntigravity(executablePath: nil, appDataDirName: "antigravity") == .antigravityApp)
        #expect(Source.classifyAntigravity(executablePath: nil, appDataDirName: "antigravity-ide") == .antigravityIDE)
        #expect(Source.classifyAntigravity(executablePath: nil, appDataDirName: "antigravity-cli") == .unknown)
    }

    @Test func identifiesAntigravityExecutablesWithoutWorkspaceFalsePositives() {
        #expect(ProcessProbe.isAntigravityExecutable("/Users/dev/.local/bin/agy"))
        #expect(ProcessProbe.isAntigravityExecutable("/Applications/Gemini.app/Contents/MacOS/Gemini"))
        #expect(ProcessProbe.isAntigravityExecutable("/Applications/Antigravity.app/Contents/Resources/language_server_macos_arm"))
        #expect(!ProcessProbe.isAntigravityExecutable("/Users/dev/work/agent-notch-antigravity/.build/debug/AgentNotch"))
        #expect(!ProcessProbe.isAntigravityExecutable("/Users/dev/.local/bin/claude"))
    }

    @Test func extractsConversationIdsFromDatabaseAndBrainHandlesOnly() {
        let convId = "e205f332-adc1-4ebf-8700-9145839cf5d0"
        let db = ProcessProbe.antigravityConversationId(fromPath: "/Users/dev/.gemini/antigravity-cli/conversations/\(convId).db")
        #expect(db?.id == convId && db?.isDatabase == true)
        let shm = ProcessProbe.antigravityConversationId(fromPath: "/Users/dev/.gemini/antigravity-cli/conversations/\(convId).db-shm")
        #expect(shm?.id == convId && shm?.isDatabase == true)
        let wal = ProcessProbe.antigravityConversationId(fromPath: "/Users/dev/.gemini/antigravity/conversations/\(convId).db-wal")
        #expect(wal?.id == convId && wal?.isDatabase == true)
        let brain = ProcessProbe.antigravityConversationId(fromPath: "/Users/dev/.gemini/antigravity-cli/brain/\(convId)")
        #expect(brain?.id == convId && brain?.isDatabase == false)
        let sysgen = ProcessProbe.antigravityConversationId(fromPath: "/Users/dev/.gemini/antigravity-cli/brain/\(convId)/.system_generated")
        #expect(sysgen?.id == convId && sysgen?.isDatabase == false)
        // State DB itself and cross-session artifact reads must not match
        #expect(ProcessProbe.antigravityConversationId(fromPath: "/Users/dev/.gemini/antigravity-cli/conversation_summaries.db") == nil)
        #expect(ProcessProbe.antigravityConversationId(fromPath: "/Users/dev/.gemini/antigravity-cli/brain/\(convId)/plan.md") == nil)
    }

    @Test func mapsLiveAntigravityProcessesByConversationId() {
        let t0 = Date(timeIntervalSince1970: 1_792_900_000)
        let mapped = ProcessProbe.antigravityProcesses(
            allPids: { [100, 200, 300] },
            executablePath: { pid in
                switch pid {
                case 100: "/Users/dev/.local/bin/claude"
                case 200: "/Users/dev/.local/bin/agy"
                case 300: "/Users/dev/.local/bin/agy"
                default: nil
                }
            },
            openPaths: { pid in
                switch pid {
                case 200: ["/Users/dev/.gemini/antigravity-cli/brain/conv-orca/.system_generated"]
                case 300: ["/Users/dev/.gemini/antigravity-cli/conversations/conv-term.db-shm"]
                default: []
                }
            },
            ancestorPaths: { pid in
                pid == 200 ? ["/Applications/Orca.app/Contents/MacOS/orca-provider-exec"] : ["/bin/zsh"]
            },
            tty: { pid in pid == 300 ? "ttys005" : nil },
            startTime: { _ in t0 }
        )
        #expect(mapped["conv-orca"] == AntigravityProcessInfo(pid: 200, executablePath: "/Users/dev/.local/bin/agy", source: .orca, tty: nil, startedAt: t0))
        #expect(mapped["conv-term"] == AntigravityProcessInfo(pid: 300, executablePath: "/Users/dev/.local/bin/agy", source: .terminal, tty: "ttys005", startedAt: t0))
        #expect(mapped.count == 2)
    }
}
