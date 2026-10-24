import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct IDEDeepLinking {
    @Test(arguments: [
        ("Cursor Helper (Plugin): extension-host (user) my-app [1-1]", 1),
        ("Cursor Helper (Plugin): extension-host (user) mock-service [2-12]", 2),
        ("Cursor Helper (Plugin): extension-host my app with spaces [17-3]", 17),
    ])
    func windowIdComesFromTheExtensionHostTitle(title: String, expected: Int) {
        #expect(IDEDeepLink.windowId(fromExtensionHostTitle: title) == expected)
    }

    @Test(arguments: [
        "Cursor Helper (Renderer)",
        "extension-host (user) x [0-1]",
        "extension-host (user) x [a-1]",
        "/usr/bin/zsh",
        "",
    ])
    func otherTitlesHaveNoWindowId(title: String) {
        #expect(IDEDeepLink.windowId(fromExtensionHostTitle: title) == nil)
    }

    @Test func cursorLinkTargetsTheSessionAndItsWindow() {
        let url = IDEDeepLink.url(source: .cursor, sessionId: "11111111-1111-4111-8111-111111111111", windowId: 3)
        #expect(url?.absoluteString == "cursor://anthropic.claude-code/open?session=11111111-1111-4111-8111-111111111111&windowId=3")
    }

    @Test func noLinkWithoutAWindowId() {
        // Without windowId the IDE routes to its last active window, which may not host the
        // session and would then resume it in a new tab (R1). Never send that.
        #expect(IDEDeepLink.url(source: .cursor, sessionId: "11111111-1111-4111-8111-111111111111", windowId: nil) == nil)
    }

    @Test(arguments: [Source.vscode, .terminal, .background, .unknown])
    func onlyCursorRoutingIsVerified(source: Source) {
        #expect(IDEDeepLink.url(source: source, sessionId: "11111111-1111-4111-8111-111111111111", windowId: 1) == nil)
    }

    @Test(arguments: ["", "abc&windowId=9", "../x", "a b", "id?x=1"])
    func unsafeSessionIdsAreRejected(sessionId: String) {
        #expect(IDEDeepLink.url(source: .cursor, sessionId: sessionId, windowId: 1) == nil)
    }

    static let started = Date(timeIntervalSince1970: 1_792_818_568)
    static let cursorClaude = "/Users/dev/.cursor/extensions/anthropic.claude-code-2.1.310-darwin-arm64/resources/native-binary/claude"
    static let cursorHelper = "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"

    /// A process table where pid 4242 is the session's claude and 900 its Cursor extension host.
    static func probe(
        sessionExe: String = cursorClaude, sessionStart: Date = started.addingTimeInterval(-2),
        parentExe: String = cursorHelper, title: String = "Cursor Helper (Plugin): extension-host (user) my-app [5-1]"
    ) -> IDEDeepLink.Probe {
        IDEDeepLink.Probe(
            isAlive: { $0 == 4242 || $0 == 900 },
            executablePath: { $0 == 4242 ? sessionExe : $0 == 900 ? parentExe : nil },
            startTime: { $0 == 4242 ? sessionStart : nil },
            parentPid: { $0 == 4242 ? 900 : nil },
            processTitle: { $0 == 900 ? title : nil }
        )
    }

    @Test func resolveWalksFromTheSessionToItsParentTitle() {
        let url = IDEDeepLink.resolve(source: .cursor, sessionId: "abc-123", pid: 4242, startedAt: Self.started, probe: Self.probe())
        #expect(url?.absoluteString == "cursor://anthropic.claude-code/open?session=abc-123&windowId=5")
        #expect(IDEDeepLink.resolve(source: .cursor, sessionId: "abc-123", pid: nil, startedAt: Self.started, probe: Self.probe()) == nil)
    }

    @Test func deadPidGetsNoLink() {
        #expect(IDEDeepLink.resolve(source: .cursor, sessionId: "abc-123", pid: 5555, startedAt: Self.started, probe: Self.probe()) == nil)
    }

    @Test func reusedPidThatIsNoLongerCursorClaudeGetsNoLink() {
        let probe = Self.probe(sessionExe: "/Applications/Cursor.app/Contents/Resources/app/node_modules/@vscode/ripgrep/bin/rg")
        #expect(IDEDeepLink.resolve(source: .cursor, sessionId: "abc-123", pid: 4242, startedAt: Self.started, probe: probe) == nil)
    }

    @Test func reusedPidWithADifferentStartTimeGetsNoLink() {
        let probe = Self.probe(sessionStart: Self.started.addingTimeInterval(3600))
        #expect(IDEDeepLink.resolve(source: .cursor, sessionId: "abc-123", pid: 4242, startedAt: Self.started, probe: probe) == nil)
    }

    @Test func parentOutsideCursorAppGetsNoLink() {
        let probe = Self.probe(parentExe: "/Applications/Other.app/Contents/MacOS/Other")
        #expect(IDEDeepLink.resolve(source: .cursor, sessionId: "abc-123", pid: 4242, startedAt: Self.started, probe: probe) == nil)
    }
}

@Suite struct ProcessTree {
    @Test func parentPidOfThisProcessIsGetppid() {
        #expect(ProcessProbe.parentPid(ProcessInfo.processInfo.processIdentifier) == getppid())
    }

    @Test func processTitleOfThisProcessIsArgvZero() throws {
        let title = try #require(ProcessProbe.processTitle(ProcessInfo.processInfo.processIdentifier))
        #expect(title == CommandLine.arguments[0])
        #expect(ProcessProbe.processTitle(-1) == nil)
    }

    @Test func startTimeOfThisProcessIsInThePast() throws {
        let start = try #require(ProcessProbe.startTime(ProcessInfo.processInfo.processIdentifier))
        #expect(start < Date())
        #expect(Date().timeIntervalSince(start) < 3600)
    }
}
