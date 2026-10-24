import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct RegistryReading {
    let now = Date(timeIntervalSince1970: 1_792_900_000)

    @Test func decodesEveryRegistryJsonFile() throws {
        let reader = RegistryReader(directory: fixture("sessions"))
        let listed = try reader.read(now: now)
        let a = try #require(listed.first { $0.sessionId == "11111111-1111-4111-8111-111111111111" })
        #expect(a.pid == 4242)
        #expect(a.kind == .interactive)
        #expect(a.version == "2.1.310")
        #expect(a.status == "busy")
        #expect(a.name == "repo-a-36")
        #expect(a.cwd == "/Users/dev/work/repo-a")
        #expect(a.startedAt == Date(timeIntervalSince1970: 1_792_811_619.613))
        let b = try #require(listed.first { $0.sessionId == "22222222-2222-4222-8222-222222222222" })
        #expect(b.version == "2.1.296")
        #expect(b.status == "idle")
    }

    @Test func registryKindBgMapsToBackground() throws {
        let listed = try RegistryReader(directory: fixture("sessions")).read(now: now)
        let spare = try #require(listed.first { $0.sessionId == "55555555-5555-4555-8555-555555555555" })
        #expect(spare.kind == .background)
    }

    @Test func malformedFileIsSkippedNotFatal() throws {
        let listed = try RegistryReader(directory: fixture("sessions")).read(now: now)
        #expect(listed.count == 3)
        #expect(!listed.contains { $0.sessionId == "broken" })
    }

    @Test func keyFilesAreNeverOpened() throws {
        let opened = OpenedPaths()
        let reader = RegistryReader(directory: fixture("sessions")) { url in
            opened.record(url.lastPathComponent)
            return try? Data(contentsOf: url)
        }
        _ = try reader.read(now: now)
        let names = opened.names
        #expect(!names.isEmpty)
        #expect(names.allSatisfy { $0.hasSuffix(".json") }, "opened: \(names)")
        #expect(!names.contains { $0.hasSuffix(".key") })
    }

    @Test func missingDirectoryIsAnError() {
        #expect(throws: (any Error).self) {
            try RegistryReader(directory: fixture("does-not-exist")).read(now: now)
        }
    }
}

final class OpenedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []
    func record(_ n: String) { lock.withLock { _names.append(n) } }
    var names: [String] { lock.withLock { _names } }
}
