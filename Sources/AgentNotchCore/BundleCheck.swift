import Darwin
import Foundation

/// D46: Bundle inspection, installability checks, safe extraction, code-signature verification,
/// quarantine removal, and atomic replacement. Pure Foundation/Darwin, no AppKit.
public enum BundleCheck {
    public static let expectedBundleIdentifier = "com.bagustyo92.agentnotch"
    public static let defaultBackupName = "AgentNotch.app.old"

    public struct Info: Sendable, Equatable {
        public let bundleIdentifier: String
        public let version: AppVersion
        public let rawVersion: String

        public init(bundleIdentifier: String, version: AppVersion, rawVersion: String) {
            self.bundleIdentifier = bundleIdentifier
            self.version = version
            self.rawVersion = rawVersion
        }
    }

    public enum Installability: Sendable, Equatable {
        case inPlace
        case manual(reason: String)
    }

    public enum CandidateCheck: Sendable, Equatable {
        case valid(Info)
        case invalid(String)
    }

    public enum Error: Swift.Error, Equatable {
        case missingAppBundle
        case unsafeAppBundle
    }

    /// Read `CFBundleIdentifier` and `CFBundleShortVersionString` from `<bundle>/Contents/Info.plist`.
    public static func readInfo(at bundleURL: URL) -> Info? {
        let plistURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = raw as? [String: Any],
              let bundleID = dict["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty,
              let rawVersion = dict["CFBundleShortVersionString"] as? String,
              let version = AppVersion(rawVersion)
        else {
            return nil
        }
        return Info(bundleIdentifier: bundleID, version: version, rawVersion: rawVersion)
    }

    /// Trust model step 2 (version binding): the unzipped app must match the expected bundle id,
    /// match the release tag version, and be strictly newer than the running version.
    public static func verifyCandidate(
        at bundleURL: URL,
        expectedVersion: AppVersion,
        runningVersion: AppVersion,
        expectedBundleIdentifier: String = expectedBundleIdentifier
    ) -> CandidateCheck {
        guard let info = readInfo(at: bundleURL) else {
            return .invalid("Downloaded app has an invalid Info.plist")
        }
        guard info.bundleIdentifier == expectedBundleIdentifier else {
            return .invalid("Bundle identifier mismatch: \(info.bundleIdentifier)")
        }
        guard info.version == expectedVersion else {
            return .invalid("App version \(info.version) does not match release \(expectedVersion)")
        }
        guard info.version > runningVersion else {
            return .invalid("App version \(info.version) is not newer than \(runningVersion)")
        }
        return .valid(info)
    }

    /// Decide whether `bundleURL` can be replaced in place or must use the manual release-page path.
    public static func installability(
        for bundleURL: URL,
        isReadOnlyVolume: ((URL) -> Bool)? = nil,
        isWritablePath: ((String) -> Bool)? = nil
    ) -> Installability {
        guard bundleURL.pathExtension == "app" else {
            return .manual(reason: "Not running from an app bundle")
        }
        if bundleURL.path.contains("/AppTranslocation/") {
            return .manual(reason: "Move AgentNotch to Applications to update in place")
        }
        let readOnly: Bool
        if let isReadOnlyVolume {
            readOnly = isReadOnlyVolume(bundleURL)
        } else {
            let values = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
            readOnly = values?.volumeIsReadOnly ?? false
        }
        if readOnly {
            return .manual(reason: "AgentNotch is running from a read-only volume")
        }
        let parentPath = bundleURL.deletingLastPathComponent().path
        let writable = isWritablePath?(parentPath) ?? FileManager.default.isWritableFile(atPath: parentPath)
        if !writable {
            return .manual(reason: "App folder is not writable")
        }
        return .inPlace
    }

    /// Extract a zip archive with `/usr/bin/ditto -x -k` and return the extracted `.app` URL.
    public static func unzip(
        archive: URL,
        into destination: URL,
        expectedAppName: String = "AgentNotch.app",
        timeout: TimeInterval = 60
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try await ProcessRunner.capture(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, destination.path],
            timeout: timeout
        )
        let appURL = destination.appendingPathComponent(expectedAppName, isDirectory: true)
        guard let values = try? appURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true
        else {
            throw Error.missingAppBundle
        }
        if values.isSymbolicLink == true {
            throw Error.unsafeAppBundle
        }
        return appURL
    }

    /// Trust model step 3: `codesign --verify --deep --strict` must pass on the unzipped app.
    public static func verifyCodeSignature(at bundleURL: URL, timeout: TimeInterval = 30) async -> Bool {
        do {
            _ = try await ProcessRunner.capture(
                executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--deep", "--strict", bundleURL.path],
                timeout: timeout
            )
            return true
        } catch {
            return false
        }
    }

    /// Check whether `com.apple.quarantine` is present on `url`.
    public static func hasQuarantine(at url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Strip `com.apple.quarantine` recursively if present. Only call after signature, plist, and
    /// `codesign` checks have all passed.
    public static func removeQuarantineIfPresent(at bundleURL: URL, timeout: TimeInterval = 15) async {
        let exeURL = bundleURL.appendingPathComponent("Contents/MacOS/AgentNotch")
        guard hasQuarantine(at: bundleURL) || hasQuarantine(at: exeURL) else { return }
        _ = try? await ProcessRunner.capture(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-dr", "com.apple.quarantine", bundleURL.path],
            timeout: timeout
        )
    }

    /// Atomically replace the bundle at `targetURL` with `newBundleURL`, cleaning up the backup.
    public static func replaceBundle(
        at targetURL: URL,
        with newBundleURL: URL,
        backupName: String = defaultBackupName
    ) throws {
        let fm = FileManager.default
        let backupURL = targetURL.deletingLastPathComponent().appendingPathComponent(backupName)
        if fm.fileExists(atPath: backupURL.path) {
            try? fm.removeItem(at: backupURL)
        }
        _ = try fm.replaceItemAt(
            targetURL,
            withItemAt: newBundleURL,
            backupItemName: backupName,
            options: []
        )
        if fm.fileExists(atPath: backupURL.path) {
            try? fm.removeItem(at: backupURL)
        }
    }
}
