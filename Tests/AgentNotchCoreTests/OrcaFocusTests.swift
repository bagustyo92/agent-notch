import Foundation
import Testing
@testable import AgentNotchCore

private final class RecordedCalls: @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let executable: URL
        let arguments: [String]
        let currentDirectory: URL?
        let environment: [String: String]
        let timeout: TimeInterval
    }

    private let lock = NSLock()
    private var _calls: [Call] = []

    var calls: [Call] { lock.withLock { _calls } }

    func append(_ call: Call) { lock.withLock { _calls.append(call) } }
}

private let fakeOrca = URL(fileURLWithPath: "/Applications/Orca.app/Contents/Resources/bin/orca")
private let okJSON = Data(#"{"id":"req-1","ok":true,"result":{}}"#.utf8)
private let failJSON = Data(#"{"id":"req-2","ok":false,"error":{"message":"folder workspace unsupported"}}"#.utf8)

@Suite struct OrcaExecutableLocation {
    private func makeTree(files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orca-loc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for rel in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return root
    }

    @Test func prefersSystemAppOverUserAppAndBrewPaths() throws {
        let root = try makeTree(files: [
            "sys/Applications/Orca.app/Contents/Resources/bin/orca",
            "home/Applications/Orca.app/Contents/Resources/bin/orca",
            "usr/local/bin/orca",
            "opt/homebrew/bin/orca",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let sysApp = root.appendingPathComponent("sys/Applications/Orca.app/Contents/Resources/bin/orca").path
        let usrLocal = root.appendingPathComponent("usr/local/bin/orca").path
        let brew = root.appendingPathComponent("opt/homebrew/bin/orca").path
        let found = OrcaFocus.locateExecutable(
            home: root.appendingPathComponent("home"),
            systemPaths: [sysApp, usrLocal, brew]
        )
        #expect(found?.path == sysApp)
    }

    @Test func prefersUserAppOverUsrLocalAndHomebrew() throws {
        let root = try makeTree(files: [
            "home/Applications/Orca.app/Contents/Resources/bin/orca",
            "usr/local/bin/orca",
            "opt/homebrew/bin/orca",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let missingSysApp = root.appendingPathComponent("sys/Applications/Orca.app/Contents/Resources/bin/orca").path
        let usrLocal = root.appendingPathComponent("usr/local/bin/orca").path
        let brew = root.appendingPathComponent("opt/homebrew/bin/orca").path
        let found = OrcaFocus.locateExecutable(
            home: root.appendingPathComponent("home"),
            systemPaths: [missingSysApp, usrLocal, brew]
        )
        #expect(found?.path == root.appendingPathComponent("home/Applications/Orca.app/Contents/Resources/bin/orca").path)
    }

    @Test func fallsBackToUsrLocalThenHomebrewThenNil() throws {
        let root = try makeTree(files: ["opt/homebrew/bin/orca"])
        defer { try? FileManager.default.removeItem(at: root) }
        let missingSys = root.appendingPathComponent("sys/Applications/Orca.app/Contents/Resources/bin/orca").path
        let missingUsr = root.appendingPathComponent("usr/local/bin/orca").path
        let brew = root.appendingPathComponent("opt/homebrew/bin/orca").path
        let found = OrcaFocus.locateExecutable(
            home: root.appendingPathComponent("home"),
            systemPaths: [missingSys, missingUsr, brew]
        )
        #expect(found?.path == brew)
        #expect(OrcaFocus.locateExecutable(home: root.appendingPathComponent("home"), systemPaths: [missingSys, missingUsr]) == nil)
    }
}

@Suite struct OrcaEnvironmentSanitization {
    @Test func stripsAllOrcaVariablesAndSetsNoColor() {
        let cleaned = OrcaFocus.sanitizedEnvironment([
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/dev",
            "ORCA_ENVIRONMENT": "sandbox",
            "ORCA_PAIRING_CODE": "orca://pair?t=secret",
            "ORCA_RUNTIME_SOCKET": "/tmp/orca.sock",
            "orca_custom": "1",
            "NO_COLOR": "0",
        ])
        #expect(cleaned["PATH"] == "/usr/bin:/bin")
        #expect(cleaned["HOME"] == "/Users/dev")
        #expect(cleaned["NO_COLOR"] == "1")
        #expect(cleaned["ORCA_ENVIRONMENT"] == nil)
        #expect(cleaned["ORCA_PAIRING_CODE"] == nil)
        #expect(cleaned["ORCA_RUNTIME_SOCKET"] == nil)
        #expect(cleaned["orca_custom"] == nil)
    }
}

@Suite struct OrcaTerminalDecoding {
    @Test func decodesResultTerminalsEnvelope() {
        let json = """
        {
          "id": "req-1",
          "ok": true,
          "result": {
            "terminals": [
              {
                "handle": "term_1",
                "worktreePath": "/Users/dev/work/repo-a",
                "connected": true,
                "orphaned": false,
                "executionHostId": "local"
              },
              {
                "handle": "term_2",
                "worktreePath": "/Users/dev/work/repo-b",
                "connected": false,
                "orphaned": true,
                "executionHostId": "remote-vm"
              },
              {
                "handle": "",
                "worktreePath": "/Users/dev/work/bad"
              }
            ]
          }
        }
        """
        let decoded = OrcaFocus.decodeTerminals(Data(json.utf8))
        #expect(decoded == [
            OrcaFocus.TerminalEntry(handle: "term_1", worktreePath: "/Users/dev/work/repo-a", connected: true, orphaned: false, executionHostId: "local"),
            OrcaFocus.TerminalEntry(handle: "term_2", worktreePath: "/Users/dev/work/repo-b", connected: false, orphaned: true, executionHostId: "remote-vm"),
        ])
    }

    @Test func returnsEmptyOnOkFalseOrMalformedData() {
        #expect(OrcaFocus.decodeTerminals(failJSON).isEmpty)
        #expect(OrcaFocus.decodeTerminals(Data("not json".utf8)).isEmpty)
        #expect(OrcaFocus.decodeTerminals(Data("[]".utf8)).isEmpty)
        #expect(OrcaFocus.decodeTerminals(Data()).isEmpty)
    }
}

@Suite struct OrcaTerminalMatching {
    private func term(
        _ handle: String,
        _ path: String,
        connected: Bool = true,
        orphaned: Bool = false,
        host: String = "local"
    ) -> OrcaFocus.TerminalEntry {
        OrcaFocus.TerminalEntry(handle: handle, worktreePath: path, connected: connected, orphaned: orphaned, executionHostId: host)
    }

    @Test func matchesExactSubdirectoryAndTrailingSlash() {
        let list = [term("term_a", "/Users/dev/work/app/")]
        #expect(OrcaFocus.uniqueTerminalHandle(forCwd: "/Users/dev/work/app", in: list) == "term_a")
        #expect(OrcaFocus.uniqueTerminalHandle(forCwd: "/Users/dev/work/app/", in: list) == "term_a")
        #expect(OrcaFocus.uniqueTerminalHandle(forCwd: "/Users/dev/work/app/src/api", in: list) == "term_a")
        #expect(OrcaFocus.uniqueTerminalHandle(forCwd: "/Users/dev/work/app-2", in: list) == nil)
        #expect(OrcaFocus.uniqueTerminalHandle(forCwd: "", in: list) == nil)
    }

    @Test func ignoresRemoteDisconnectedAndOrphanedTerminals() {
        let list = [
            term("term_remote", "/Users/dev/work/app", host: "sandbox"),
            term("term_disc", "/Users/dev/work/app", connected: false),
            term("term_orphan", "/Users/dev/work/app", orphaned: true),
            term("term_good", "/Users/dev/work/app"),
        ]
        #expect(OrcaFocus.uniqueTerminalHandle(forCwd: "/Users/dev/work/app", in: list) == "term_good")
    }

    @Test func failsClosedWhenTwoTerminalsShareDeepestWorktree() {
        let same = [term("term_1", "/Users/dev/work/app"), term("term_2", "/Users/dev/work/app")]
        #expect(OrcaFocus.uniqueTerminalHandle(forCwd: "/Users/dev/work/app", in: same) == nil)

        // Nested: deepest has 2, parent has 1 -> still ambiguous (do not pick parent).
        let nestedAmbiguous = [
            term("term_parent", "/Users/dev/work"),
            term("term_sub_1", "/Users/dev/work/app"),
            term("term_sub_2", "/Users/dev/work/app"),
        ]
        #expect(OrcaFocus.uniqueTerminalHandle(forCwd: "/Users/dev/work/app/pkg", in: nestedAmbiguous) == nil)
    }

    @Test func deepestMatchingWorktreeWinsWhenUnique() {
        let nested = [
            term("term_parent", "/Users/dev/work"),
            term("term_sub", "/Users/dev/work/app"),
        ]
        #expect(OrcaFocus.uniqueTerminalHandle(forCwd: "/Users/dev/work/app/pkg", in: nested) == "term_sub")
    }
}

@Suite struct OrcaFocusRouting {
    private static func terminalsJSON(_ entries: [(String, String)]) -> Data {
        let items = entries.map { handle, path in
            #"{"handle":"\#(handle)","worktreePath":"\#(path)","connected":true,"orphaned":false,"executionHostId":"local"}"#
        }.joined(separator: ",")
        return Data(#"{"ok":true,"result":{"terminals":[\#(items)]}}"#.utf8)
    }

    @Test func liveTerminalWithUniqueHandleSwitchesDirectly() async {
        let recorded = RecordedCalls()
        let route = await OrcaFocus.focus(
            cwd: "/Users/dev/work/repo-a/sub",
            tty: "ttys002",
            isLive: true,
            executable: fakeOrca,
            environment: ["PATH": "/usr/bin", "ORCA_ENVIRONMENT": "remote-vm"],
            directoryExists: { _ in true },
            run: { exe, args, cwd, env, timeout in
                recorded.append(.init(executable: exe, arguments: args, currentDirectory: cwd, environment: env, timeout: timeout))
                if args.prefix(2) == ["terminal", "list"] {
                    return Self.terminalsJSON([("term_unique", "/Users/dev/work/repo-a")])
                }
                return okJSON
            }
        )

        #expect(route == .terminalSwitch(handle: "term_unique"))
        #expect(recorded.calls.count == 2)
        #expect(recorded.calls[0].arguments == ["terminal", "list", "--environment", "local", "--json"])
        #expect(recorded.calls[0].environment["ORCA_ENVIRONMENT"] == nil)
        #expect(recorded.calls[0].environment["NO_COLOR"] == "1")
        #expect(recorded.calls[1].arguments == ["terminal", "switch", "--environment", "local", "--terminal", "term_unique", "--json"])
    }

    @Test func liveTerminalWithTwoMatchingHandlesFallsBackToWorktreeActivate() async {
        let recorded = RecordedCalls()
        let route = await OrcaFocus.focus(
            cwd: "/Users/dev/work/repo-a",
            tty: "ttys002",
            isLive: true,
            executable: fakeOrca,
            directoryExists: { _ in true },
            run: { exe, args, cwd, env, timeout in
                recorded.append(.init(executable: exe, arguments: args, currentDirectory: cwd, environment: env, timeout: timeout))
                if args.prefix(2) == ["terminal", "list"] {
                    return Self.terminalsJSON([("term_1", "/Users/dev/work/repo-a"), ("term_2", "/Users/dev/work/repo-a")])
                }
                return okJSON
            }
        )

        #expect(route == .worktreeActivate)
        #expect(recorded.calls.map { Array($0.arguments.prefix(2)) } == [["terminal", "list"], ["worktree", "activate"]])
        #expect(recorded.calls[1].arguments == ["worktree", "activate", "--environment", "local", "--worktree", "current", "--json"])
        #expect(recorded.calls[1].currentDirectory == URL(fileURLWithPath: "/Users/dev/work/repo-a"))
    }

    @Test func liveTerminalSwitchFailureFallsBackToWorktreeActivate() async {
        let recorded = RecordedCalls()
        let route = await OrcaFocus.focus(
            cwd: "/Users/dev/work/repo-a",
            tty: "ttys002",
            isLive: true,
            executable: fakeOrca,
            directoryExists: { _ in true },
            run: { exe, args, cwd, env, timeout in
                recorded.append(.init(executable: exe, arguments: args, currentDirectory: cwd, environment: env, timeout: timeout))
                if args.prefix(2) == ["terminal", "list"] {
                    return Self.terminalsJSON([("term_1", "/Users/dev/work/repo-a")])
                }
                if args.prefix(2) == ["terminal", "switch"] {
                    throw ProcessRunnerError.nonZeroExit(1)
                }
                return okJSON
            }
        )

        #expect(route == .worktreeActivate)
        #expect(recorded.calls.map { Array($0.arguments.prefix(2)) } == [["terminal", "list"], ["terminal", "switch"], ["worktree", "activate"]])
    }

    @Test func liveTerminalListMalformedOrErrorFallsBackToWorktreeActivate() async {
        let route = await OrcaFocus.focus(
            cwd: "/Users/dev/work/repo-a",
            tty: "ttys002",
            isLive: true,
            executable: fakeOrca,
            directoryExists: { _ in true },
            run: { _, args, _, _, _ in
                if args.prefix(2) == ["terminal", "list"] { return Data("not json".utf8) }
                return okJSON
            }
        )
        #expect(route == .worktreeActivate)
    }

    @Test func liveChatSkipsTerminalListAndCallsWorktreeActivate() async {
        let recorded = RecordedCalls()
        let route = await OrcaFocus.focus(
            cwd: "/Users/dev/work/repo-a",
            tty: nil,
            isLive: true,
            executable: fakeOrca,
            directoryExists: { _ in true },
            run: { exe, args, cwd, env, timeout in
                recorded.append(.init(executable: exe, arguments: args, currentDirectory: cwd, environment: env, timeout: timeout))
                return okJSON
            }
        )

        #expect(route == .worktreeActivate)
        #expect(recorded.calls.count == 1)
        #expect(recorded.calls[0].arguments == ["worktree", "activate", "--environment", "local", "--worktree", "current", "--json"])
        #expect(recorded.calls[0].currentDirectory == URL(fileURLWithPath: "/Users/dev/work/repo-a"))
    }

    @Test func doneRowWithTtySkipsTerminalListAndCallsWorktreeActivate() async {
        let recorded = RecordedCalls()
        let route = await OrcaFocus.focus(
            cwd: "/Users/dev/work/repo-a",
            tty: "ttys002",
            isLive: false,
            executable: fakeOrca,
            directoryExists: { _ in true },
            run: { exe, args, cwd, env, timeout in
                recorded.append(.init(executable: exe, arguments: args, currentDirectory: cwd, environment: env, timeout: timeout))
                return okJSON
            }
        )

        #expect(route == .worktreeActivate)
        #expect(recorded.calls.count == 1)
        #expect(recorded.calls[0].arguments == ["worktree", "activate", "--environment", "local", "--worktree", "current", "--json"])
    }

    @Test func folderWorkspaceOrNonZeroOrMissingCwdOrMissingExecutableFallsBack() async {
        let folderRoute = await OrcaFocus.focus(
            cwd: "/Users/dev/work/folder-ws", tty: nil, isLive: true, executable: fakeOrca,
            directoryExists: { _ in true },
            run: { _, _, _, _, _ in failJSON }
        )
        #expect(folderRoute == .fallback)

        let errorRoute = await OrcaFocus.focus(
            cwd: "/Users/dev/work/folder-ws", tty: nil, isLive: true, executable: fakeOrca,
            directoryExists: { _ in true },
            run: { _, _, _, _, _ in throw ProcessRunnerError.nonZeroExit(1) }
        )
        #expect(errorRoute == .fallback)

        let recorded = RecordedCalls()
        let noExe = await OrcaFocus.focus(
            cwd: "/Users/dev/work/repo-a", tty: "ttys002", isLive: true, executable: nil,
            directoryExists: { _ in true },
            run: { exe, args, cwd, env, timeout in
                recorded.append(.init(executable: exe, arguments: args, currentDirectory: cwd, environment: env, timeout: timeout))
                return okJSON
            }
        )
        #expect(noExe == .fallback)

        let noCwd = await OrcaFocus.focus(
            cwd: "", tty: nil, isLive: true, executable: fakeOrca,
            directoryExists: { _ in true },
            run: { exe, args, cwd, env, timeout in
                recorded.append(.init(executable: exe, arguments: args, currentDirectory: cwd, environment: env, timeout: timeout))
                return okJSON
            }
        )
        #expect(noCwd == .fallback)

        let missingDir = await OrcaFocus.focus(
            cwd: "/Users/dev/work/gone", tty: nil, isLive: true, executable: fakeOrca,
            directoryExists: { _ in false },
            run: { exe, args, cwd, env, timeout in
                recorded.append(.init(executable: exe, arguments: args, currentDirectory: cwd, environment: env, timeout: timeout))
                return okJSON
            }
        )
        #expect(missingDir == .fallback)
        #expect(recorded.calls.isEmpty)
    }
}

@Suite struct OrcaDumpLink {
    @Test func formatsDumpLinkWithoutLeakingRawCwd() {
        #expect(OrcaFocus.dumpLink(cwd: "/Users/dev/work/repo-a", tty: "ttys002", isLive: true) == "orca:terminal")
        #expect(OrcaFocus.dumpLink(cwd: "/Users/dev/work/repo-a", tty: nil, isLive: true) == "orca:worktree")
        #expect(OrcaFocus.dumpLink(cwd: "/Users/dev/work/repo-a", tty: "ttys002", isLive: false) == "orca:worktree")
        #expect(OrcaFocus.dumpLink(cwd: "/Users/dev/work/repo-a", tty: nil, isLive: false) == "orca:worktree")
        #expect(OrcaFocus.dumpLink(cwd: "", tty: "ttys002", isLive: true) == "-")
    }
}

@Suite struct ProcessRunnerOptions {
    @Test func passesCurrentDirectoryAndSanitizedEnvironment() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let env = OrcaFocus.sanitizedEnvironment(["PATH": "/usr/bin:/bin", "ORCA_ENVIRONMENT": "remote", "CUSTOM_KEY": "ok"])
        let data = try await ProcessRunner.capture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "pwd; echo CUSTOM=$CUSTOM_KEY; echo ORCA=$ORCA_ENVIRONMENT; echo NOCOLOR=$NO_COLOR"],
            currentDirectory: dir,
            environment: env,
            timeout: 5
        )
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(URL(fileURLWithPath: lines[0]).resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path)
        #expect(lines[1] == "CUSTOM=ok")
        #expect(lines[2] == "ORCA=")
        #expect(lines[3] == "NOCOLOR=1")
    }
}
