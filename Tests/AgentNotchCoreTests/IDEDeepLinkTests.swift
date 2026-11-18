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

    @Test func userHostTitleParsesRoleWorkspaceWindowAndCounter() throws {
        let host = try #require(IDEDeepLink.ExtensionHost.parse(
            title: "Cursor Helper (Plugin): extension-host (user) app-a [2-26]", pid: 900, parentPid: 322))
        #expect(host == IDEDeepLink.ExtensionHost(pid: 900, parentPid: 322, role: "user", workspace: "app-a", windowId: 2, counter: 26))
        #expect(host.isUser)
    }

    @Test func helperRolesAreNotUserHosts() throws {
        let host = try #require(IDEDeepLink.ExtensionHost.parse(
            title: "Cursor Helper (Plugin): extension-host (retrieval) app-a [2-55]", pid: 901, parentPid: 322))
        #expect(host.role == "retrieval")
        #expect(host.counter == 55)
        #expect(!host.isUser)
    }

    @Test func titleWithoutARoleCountsAsUserAndKeepsSpaces() throws {
        let host = try #require(IDEDeepLink.ExtensionHost.parse(
            title: "Cursor Helper (Plugin): extension-host my app with spaces [17-3]", pid: 902, parentPid: 322))
        #expect(host.role == nil)
        #expect(host.isUser)
        #expect(host.workspace == "my app with spaces")
        #expect(host.windowId == 17)
    }

    @Test(arguments: [
        "Cursor Helper (Renderer)",
        "extension-host (user) x [0-1]",
        "extension-host (user) x [2-]",
        "extension-host (user) x 2-1",
        "",
    ])
    func malformedTitlesAreNotHosts(title: String) {
        #expect(IDEDeepLink.ExtensionHost.parse(title: title, pid: 903, parentPid: 322) == nil)
    }

    /// The process table seen live on 2026-11-18, renamed (R6).
    static func host(_ pid: Int32, _ role: String?, _ workspace: String, _ window: Int, _ counter: Int, parent: Int32 = 322) -> IDEDeepLink.ExtensionHost {
        IDEDeepLink.ExtensionHost(pid: pid, parentPid: parent, role: role, workspace: workspace, windowId: window, counter: counter)
    }
    static let liveHosts = [
        host(2909, "user", "app-a", 2, 9),        // left over: window 2 later opened app-b
        host(44811, "user", "app-b", 2, 26),
        host(22797, "retrieval", "app-b", 2, 55),
        host(50743, "user", "app-a", 8, 42),
        host(37755, "user", "app-c", 6, 22),      // a newer window shows app-c too
        host(25880, "user", "app-c", 9, 62),
    ]

    @Test func hostLeftOverInAReusedWindowIsNotTrusted() {
        #expect(!IDEDeepLink.isTrusted(Self.liveHosts[0], among: Self.liveHosts))
    }

    @Test func newerHelperHostDoesNotUntrustTheUserHost() {
        #expect(IDEDeepLink.isTrusted(Self.liveHosts[1], among: Self.liveHosts))
        #expect(IDEDeepLink.isTrusted(Self.liveHosts[3], among: Self.liveHosts))
    }

    @Test func olderWindowOfAWorkspaceANewerWindowShowsIsNotTrusted() {
        #expect(!IDEDeepLink.isTrusted(Self.liveHosts[4], among: Self.liveHosts))
        #expect(IDEDeepLink.isTrusted(Self.liveHosts[5], among: Self.liveHosts))
    }

    @Test func loneHostIsTrustedAndAHelperHostNeverIs() {
        let lone = Self.host(900, "user", "my-app", 5, 1)
        #expect(IDEDeepLink.isTrusted(lone, among: [lone]))
        #expect(IDEDeepLink.isTrusted(lone, among: []))
        #expect(!IDEDeepLink.isTrusted(Self.liveHosts[2], among: Self.liveHosts))
    }

    @Test func hostsOfAnotherIDEMainProcessAreNotCompared() {
        let mine = Self.host(900, "user", "my-app", 2, 3)
        let otherMain = Self.host(901, "user", "my-app", 4, 9, parent: 777)
        #expect(IDEDeepLink.isTrusted(mine, among: [mine, otherMain]))
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
    static let mainStarted = Date(timeIntervalSince1970: 1_792_800_000)
    static let cursorClaude = "/Users/dev/.cursor/extensions/anthropic.claude-code-2.1.310-darwin-arm64/resources/native-binary/claude"
    static let cursorHelper = "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"
    static let cursorMain = "/Applications/Cursor.app/Contents/MacOS/Cursor"
    static let myAppTitle = "Cursor Helper (Plugin): extension-host (user) my-app [5-1]"

    struct Proc { var exe: String; var start: Date? = nil; var parent: Int32? = nil; var title: String? = nil }

    /// A fake process table; every listed pid is alive.
    static func table(_ procs: [Int32: Proc]) -> IDEDeepLink.Probe {
        IDEDeepLink.Probe(
            isAlive: { procs[$0] != nil },
            executablePath: { procs[$0]?.exe },
            startTime: { procs[$0]?.start },
            parentPid: { procs[$0]?.parent },
            processTitle: { procs[$0]?.title },
            allPids: { procs.keys.sorted() }
        )
    }

    /// Pid 4242 is the session's claude, 900 its Cursor extension host, 322 Cursor's main process.
    static func procs(
        sessionExe: String = cursorClaude, sessionStart: Date = started.addingTimeInterval(-2),
        parentExe: String = cursorHelper, title: String = myAppTitle, mainStart: Date = mainStarted
    ) -> [Int32: Proc] {
        [
            4242: Proc(exe: sessionExe, start: sessionStart, parent: 900),
            900: Proc(exe: parentExe, start: mainStart.addingTimeInterval(5), parent: 322, title: title),
            322: Proc(exe: cursorMain, start: mainStart, parent: 1),
        ]
    }

    static func probe(
        sessionExe: String = cursorClaude, sessionStart: Date = started.addingTimeInterval(-2),
        parentExe: String = cursorHelper, title: String = myAppTitle
    ) -> IDEDeepLink.Probe {
        table(procs(sessionExe: sessionExe, sessionStart: sessionStart, parentExe: parentExe, title: title))
    }

    static func target(
        pid: Int32? = 4242, isLive: Bool = true, remembered: IDEWindow? = nil, probe: IDEDeepLink.Probe = probe()
    ) -> IDEDeepLink.Target {
        IDEDeepLink.target(source: .cursor, sessionId: "abc-123", pid: pid, startedAt: started, isLive: isLive,
                           remembered: remembered, probe: probe)
    }

    static let chat5 = IDEDeepLink.Target.chat(URL(string: "cursor://anthropic.claude-code/open?session=abc-123&windowId=5")!)
    static let focus5 = IDEDeepLink.Target.window(URL(string: "cursor://anthropic.claude-code/focus?windowId=5")!)
    static let remembered5 = IDEWindow(windowId: 5, workspace: "my-app", mainPid: 322, mainStartedAt: mainStarted)

    @Test func liveSessionUnderATrustedHostGetsItsExactChat() {
        #expect(Self.target() == Self.chat5)
        #expect(Self.target(pid: nil) == IDEDeepLink.Target.none)
    }

    @Test func locateRemembersTheWindowWithItsMainProcess() throws {
        let probe = Self.probe()
        let located = try #require(IDEDeepLink.locate(source: .cursor, pid: 4242, startedAt: Self.started,
                                                       hosts: IDEDeepLink.hosts(source: .cursor, probe: probe), probe: probe))
        #expect(located.trusted)
        #expect(located.window == Self.remembered5)
    }

    @Test func deadPidGetsNoLink() {
        #expect(Self.target(pid: 5555) == IDEDeepLink.Target.none)
    }

    @Test func reusedPidThatIsNoLongerCursorClaudeGetsNoLink() {
        let probe = Self.probe(sessionExe: "/Applications/Cursor.app/Contents/Resources/app/node_modules/@vscode/ripgrep/bin/rg")
        #expect(Self.target(probe: probe) == IDEDeepLink.Target.none)
    }

    @Test func reusedPidWithADifferentStartTimeGetsNoLink() {
        #expect(Self.target(probe: Self.probe(sessionStart: Self.started.addingTimeInterval(3600))) == IDEDeepLink.Target.none)
    }

    @Test func parentOutsideCursorAppGetsNoLink() {
        #expect(Self.target(probe: Self.probe(parentExe: "/Applications/Other.app/Contents/MacOS/Other")) == IDEDeepLink.Target.none)
    }

    /// The left-over host of a reused window: window 5 now shows other-app under a newer host.
    static func leftOverProbe() -> IDEDeepLink.Probe {
        var procs = procs()
        procs[901] = Proc(exe: cursorHelper, start: mainStarted.addingTimeInterval(900), parent: 322,
                          title: "Cursor Helper (Plugin): extension-host (user) other-app [5-7]")
        return table(procs)
    }

    @Test func untrustedHostNeverGetsTheChatLink() {
        #expect(Self.target(probe: Self.leftOverProbe()) == IDEDeepLink.Target.none)
    }

    static let otherAppTitle5 = "Cursor Helper (Plugin): extension-host (user) other-app [5-7]"

    /// The R1 guard fails closed: whatever makes a host untrusted, or unprovable, no link carries
    /// `session=`.
    @Test(arguments: ["left-over", "same-workspace", "helper-role", "empty-host-list", "main-not-cursor"])
    func noUntrustedOrUnprovenHostGetsASessionLink(case name: String) {
        var procs = Self.procs()
        var allPids: (@Sendable () -> [Int32])?
        switch name {
        case "left-over":
            procs[901] = Proc(exe: Self.cursorHelper, start: Self.mainStarted, parent: 322, title: Self.otherAppTitle5)
        case "same-workspace":
            procs[901] = Proc(exe: Self.cursorHelper, start: Self.mainStarted, parent: 322,
                              title: "Cursor Helper (Plugin): extension-host (user) my-app [9-62]")
        case "helper-role":
            procs[900]?.title = "Cursor Helper (Plugin): extension-host (retrieval) my-app [5-1]"
        case "empty-host-list":
            allPids = { [] }                 // the newer host [5-7] exists but the scan saw nothing
            procs[901] = Proc(exe: Self.cursorHelper, start: Self.mainStarted, parent: 322, title: Self.otherAppTitle5)
        default:
            procs[322]?.exe = Self.cursorHelper   // the host's parent is another helper, not Cursor's main
        }
        var probe = Self.table(procs)
        if let allPids { probe.allPids = allPids }
        if case .chat = Self.target(probe: probe) { Issue.record("\(name) got the chat link") }
        if case .chat = Self.target(remembered: Self.remembered5, probe: probe) { Issue.record("\(name) got the chat link") }
    }

    @Test func liveRowWhoseProcessDiedGetsItsRememberedWindow() {
        var procs = Self.procs()
        procs[4242] = nil
        #expect(Self.target(isLive: true, remembered: Self.remembered5, probe: Self.table(procs)) == Self.focus5)
    }

    @Test func untrustedHostFallsBackToTheRememberedWindowWhileItStillShowsTheWorkspace() {
        var procs = Self.procs(title: "Cursor Helper (Plugin): extension-host (user) my-app [3-2]")
        procs[901] = Proc(exe: Self.cursorHelper, start: Self.mainStarted, parent: 322, title: Self.myAppTitle.replacingOccurrences(of: "[5-1]", with: "[5-4]"))
        procs[902] = Proc(exe: Self.cursorHelper, start: Self.mainStarted, parent: 322,
                          title: "Cursor Helper (Plugin): extension-host (user) my-app [3-9]")
        // The session sits under the left-over host [3-2]; it was last seen trusted in window 5.
        #expect(Self.target(remembered: Self.remembered5, probe: Self.table(procs)) == Self.focus5)
    }

    @Test func doneSessionGetsOnlyItsRememberedWindow() {
        var procs = Self.procs()
        procs[4242] = nil                                                    // claude exited
        #expect(Self.target(isLive: false, remembered: Self.remembered5, probe: Self.table(procs)) == Self.focus5)
        // Even while the process lingers, a done row never sends the chat link.
        #expect(Self.target(isLive: false, remembered: Self.remembered5) == Self.focus5)
        #expect(Self.target(isLive: false) == IDEDeepLink.Target.none)
    }

    @Test func rememberedWindowOfARestartedCursorIsNotUsed() {
        var procs = Self.procs(mainStart: Self.mainStarted.addingTimeInterval(7200))
        procs[4242] = nil
        #expect(Self.target(isLive: false, remembered: Self.remembered5, probe: Self.table(procs)) == IDEDeepLink.Target.none)
    }

    @Test func rememberedWindowThatNowShowsAnotherProjectIsNotUsed() {
        var procs = Self.procs()
        procs[4242] = nil
        procs[901] = Proc(exe: Self.cursorHelper, start: Self.mainStarted, parent: 322,
                          title: "Cursor Helper (Plugin): extension-host (user) other-app [5-7]")
        #expect(Self.target(isLive: false, remembered: Self.remembered5, probe: Self.table(procs)) == IDEDeepLink.Target.none)
    }

    @Test func rememberedWindowThatIsClosedIsNotUsed() {
        var procs = Self.procs()
        procs[4242] = nil
        procs[900] = nil                                                     // window 5's host is gone
        #expect(Self.target(isLive: false, remembered: Self.remembered5, probe: Self.table(procs)) == IDEDeepLink.Target.none)
    }

    @Test func focusLinkCarriesOnlyTheWindow() {
        let url = IDEDeepLink.focusURL(source: .cursor, windowId: 5)
        #expect(url?.absoluteString == "cursor://anthropic.claude-code/focus?windowId=5")
        #expect(IDEDeepLink.focusURL(source: .vscode, windowId: 5) == nil)
        #expect(IDEDeepLink.focusURL(source: .cursor, windowId: 0) == nil)
    }

    @Test func hostsListsOnlyTheIDEsExtensionHosts() {
        var procs = Self.procs()
        procs[903] = Proc(exe: Self.cursorHelper, start: Self.mainStarted, parent: 322, title: "Cursor Helper (Renderer)")
        procs[904] = Proc(exe: "/Applications/Other.app/Contents/MacOS/Other", start: Self.mainStarted, parent: 1,
                          title: "extension-host (user) x [9-9]")
        let hosts = IDEDeepLink.hosts(source: .cursor, probe: Self.table(procs))
        #expect(hosts == [IDEDeepLink.ExtensionHost(pid: 900, parentPid: 322, role: "user", workspace: "my-app", windowId: 5, counter: 1)])
        #expect(IDEDeepLink.hosts(source: .vscode, probe: Self.table(procs)).isEmpty)
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

    @Test func allPidsListsThisProcessAndItsParent() {
        let pids = Set(ProcessProbe.allPids())
        #expect(pids.contains(ProcessInfo.processInfo.processIdentifier))
        #expect(pids.contains(getppid()))
        #expect(!pids.contains(0))
    }
}
