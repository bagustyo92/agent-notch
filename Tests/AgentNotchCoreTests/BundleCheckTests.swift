import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct BundleCheckTests {
    private func makeBundle(
        in dir: URL,
        name: String = "AgentNotch.app",
        bundleID: String? = BundleCheck.expectedBundleIdentifier,
        version: String? = "0.7.1",
        marker: String? = nil
    ) throws -> URL {
        let appURL = dir.appendingPathComponent(name, isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if bundleID != nil || version != nil {
            var dict: [String: Any] = [:]
            if let bundleID { dict["CFBundleIdentifier"] = bundleID }
            if let version { dict["CFBundleShortVersionString"] = version }
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        if let marker {
            try marker.write(to: contents.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        }
        return appURL
    }

    @Test func acceptsMatchingBundleIDAndNewerVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeBundle(in: root, version: "0.7.1")
        let result = BundleCheck.verifyCandidate(
            at: app,
            expectedVersion: try #require(AppVersion("0.7.1")),
            runningVersion: try #require(AppVersion("0.7.0"))
        )
        guard case .valid(let info) = result else {
            Issue.record("Expected .valid, got \(result)")
            return
        }
        #expect(info.bundleIdentifier == BundleCheck.expectedBundleIdentifier)
        #expect(info.version == AppVersion("0.7.1"))
    }

    @Test func rejectsBundleIDMismatchVersionMismatchAndDowngrade() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let v070 = try #require(AppVersion("0.7.0"))
        let v071 = try #require(AppVersion("0.7.1"))

        let wrongID = try makeBundle(in: root, name: "WrongID.app", bundleID: "com.evil.agentnotch", version: "0.7.1")
        guard case .invalid = BundleCheck.verifyCandidate(at: wrongID, expectedVersion: v071, runningVersion: v070) else {
            Issue.record("Expected .invalid for wrong bundle id")
            return
        }

        // Replayed older validly signed archive under newer tag
        let replayed = try makeBundle(in: root, name: "Replayed.app", version: "0.7.0")
        guard case .invalid = BundleCheck.verifyCandidate(at: replayed, expectedVersion: v071, runningVersion: v070) else {
            Issue.record("Expected .invalid for version mismatch")
            return
        }

        // Same version as running (even if expectedVersion matched)
        let same = try makeBundle(in: root, name: "Same.app", version: "0.7.0")
        guard case .invalid = BundleCheck.verifyCandidate(at: same, expectedVersion: v070, runningVersion: v070) else {
            Issue.record("Expected .invalid for non-newer version")
            return
        }

        // Missing Info.plist
        let missingPlist = try makeBundle(in: root, name: "Missing.app", bundleID: nil, version: nil)
        guard case .invalid = BundleCheck.verifyCandidate(at: missingPlist, expectedVersion: v071, runningVersion: v070) else {
            Issue.record("Expected .invalid for missing Info.plist")
            return
        }
    }

    @Test func classifiesTranslocatedReadOnlyUnwritableAndInPlaceBundles() {
        let translocated = URL(fileURLWithPath: "/private/var/folders/xx/abc/T/AppTranslocation/1234-5678/d/AgentNotch.app")
        guard case .manual = BundleCheck.installability(for: translocated, isReadOnlyVolume: { _ in false }, isWritablePath: { _ in true }) else {
            Issue.record("Expected .manual for translocated path")
            return
        }

        let dmgApp = URL(fileURLWithPath: "/Volumes/AgentNotch 0.7.0/AgentNotch.app")
        guard case .manual = BundleCheck.installability(for: dmgApp, isReadOnlyVolume: { _ in true }, isWritablePath: { _ in true }) else {
            Issue.record("Expected .manual for read-only volume")
            return
        }

        let unwritable = URL(fileURLWithPath: "/Applications/AgentNotch.app")
        guard case .manual = BundleCheck.installability(for: unwritable, isReadOnlyVolume: { _ in false }, isWritablePath: { _ in false }) else {
            Issue.record("Expected .manual for non-writable parent")
            return
        }

        let unbundled = URL(fileURLWithPath: "/Users/dev/agent-notch/.build/debug/AgentNotch")
        guard case .manual = BundleCheck.installability(for: unbundled, isReadOnlyVolume: { _ in false }, isWritablePath: { _ in true }) else {
            Issue.record("Expected .manual for unbundled executable")
            return
        }

        let writableApp = URL(fileURLWithPath: "/Users/dev/Applications/AgentNotch.app")
        #expect(BundleCheck.installability(for: writableApp, isReadOnlyVolume: { _ in false }, isWritablePath: { _ in true }) == .inPlace)
    }

    @Test func replacesBundleAtomicallyAndCleansBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-swap-\(UUID().uuidString)", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldApp = try makeBundle(in: root, version: "0.7.0", marker: "old")
        let newApp = try makeBundle(in: staging, version: "0.7.1", marker: "new")

        try BundleCheck.replaceBundle(at: oldApp, with: newApp)

        let info = try #require(BundleCheck.readInfo(at: oldApp))
        #expect(info.version == AppVersion("0.7.1"))
        let marker = try String(contentsOf: oldApp.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
        #expect(marker == "new")
        let backup = root.appendingPathComponent(BundleCheck.defaultBackupName)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func unzipCodeSignAndQuarantineRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-zip-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = root.appendingPathComponent("src", isDirectory: true)
        let unpackDir = root.appendingPathComponent("unpack", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeBundle(in: sourceDir, version: "0.7.1")
        let macosDir = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
        let exe = macosDir.appendingPathComponent("AgentNotch")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: exe)
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        var plist = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), options: [], format: nil) as? [String: Any]
        )
        plist["CFBundleExecutable"] = "AgentNotch"
        plist["CFBundlePackageType"] = "APPL"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)

        _ = try await ProcessRunner.capture(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", app.path],
            timeout: 15
        )
        #expect(await BundleCheck.verifyCodeSignature(at: app))

        let zipURL = root.appendingPathComponent("AgentNotch-0.7.1.zip")
        _ = try await ProcessRunner.capture(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--keepParent", app.path, zipURL.path],
            timeout: 30
        )

        let extracted = try await BundleCheck.unzip(archive: zipURL, into: unpackDir)
        #expect(await BundleCheck.verifyCodeSignature(at: extracted))

        // Quarantine attribute detection and removal.
        _ = try await ProcessRunner.capture(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-w", "com.apple.quarantine", "0081;00000000;AgentNotch;", extracted.path],
            timeout: 10
        )
        #expect(BundleCheck.hasQuarantine(at: extracted))
        await BundleCheck.removeQuarantineIfPresent(at: extracted)
        #expect(!BundleCheck.hasQuarantine(at: extracted))

        // Tampering a resource inside the signed bundle invalidates codesign --verify --deep --strict.
        try "tampered".write(to: extracted.appendingPathComponent("Contents/extra.txt"), atomically: true, encoding: .utf8)
        #expect(!(await BundleCheck.verifyCodeSignature(at: extracted)))
    }
}
