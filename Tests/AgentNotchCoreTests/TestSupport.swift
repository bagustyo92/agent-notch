import Foundation

/// `Tests/Fixtures/`, located from this file so no bundle resources are needed.
let fixturesURL: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // AgentNotchCoreTests
    .deletingLastPathComponent()   // Tests
    .appendingPathComponent("Fixtures", isDirectory: true)

func fixture(_ name: String) -> URL { fixturesURL.appendingPathComponent(name) }
func fixtureData(_ name: String) throws -> Data { try Data(contentsOf: fixture(name)) }
