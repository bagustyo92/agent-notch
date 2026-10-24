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
    }

    @Test func ttyIsNilOrATtyName() {
        let tty = ProcessProbe.tty(ProcessInfo.processInfo.processIdentifier)
        #expect(tty == nil || tty!.hasPrefix("tty"))
    }
}
