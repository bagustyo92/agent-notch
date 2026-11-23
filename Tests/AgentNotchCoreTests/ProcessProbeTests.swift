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
