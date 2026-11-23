import Foundation

/// D46: GitHub Releases update feed model, validation, and decision logic.
public enum ReleaseFeed {
    public static let defaultFeedURL = URL(string: "https://api.github.com/repos/bagustyo92/agent-notch/releases/latest")!
    public static let defaultDownloadPrefix = "https://github.com/bagustyo92/agent-notch/releases/download/"
    public static let defaultNotesPrefix = "https://github.com/bagustyo92/agent-notch/releases/"
    public static let maxArchiveBytes = 100 * 1024 * 1024
    public static let maxSignatureBytes = UpdateSignature.maxSignatureFileBytes

    public struct Release: Decodable, Sendable, Equatable {
        public let tagName: String
        public let htmlURL: String
        public let draft: Bool
        public let prerelease: Bool
        public let assets: [Asset]

        public init(tagName: String, htmlURL: String, draft: Bool, prerelease: Bool, assets: [Asset]) {
            self.tagName = tagName
            self.htmlURL = htmlURL
            self.draft = draft
            self.prerelease = prerelease
            self.assets = assets
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }
    }

    public struct Asset: Decodable, Sendable, Equatable {
        public let name: String
        public let browserDownloadURL: String
        public let size: Int

        public init(name: String, browserDownloadURL: String, size: Int) {
            self.name = name
            self.browserDownloadURL = browserDownloadURL
            self.size = size
        }

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    public struct UpdateOffer: Sendable, Equatable {
        public let version: AppVersion
        public let archiveURL: URL
        public let archiveSize: Int
        public let signatureURL: URL
        public let releaseNotesURL: URL

        public init(
            version: AppVersion,
            archiveURL: URL,
            archiveSize: Int,
            signatureURL: URL,
            releaseNotesURL: URL
        ) {
            self.version = version
            self.archiveURL = archiveURL
            self.archiveSize = archiveSize
            self.signatureURL = signatureURL
            self.releaseNotesURL = releaseNotesURL
        }
    }

    public enum UpdateDecision: Sendable, Equatable {
        case upToDate
        case available(UpdateOffer)
        case invalid(String)
    }

    public static func decode(_ data: Data) throws -> Release {
        try JSONDecoder().decode(Release.self, from: data)
    }

    /// Evaluate a decoded GitHub Release against the currently running version.
    public static func decide(
        release: Release,
        running: AppVersion,
        allowedDownloadPrefix: String = defaultDownloadPrefix,
        allowedNotesPrefix: String? = defaultNotesPrefix,
        maxArchiveBytes: Int = maxArchiveBytes,
        requireHTTPS: Bool = true
    ) -> UpdateDecision {
        if release.draft || release.prerelease {
            return .upToDate
        }
        guard let candidate = AppVersion(release.tagName) else {
            return .invalid("Malformed release version: \(release.tagName)")
        }
        guard candidate > running else {
            return .upToDate
        }

        guard let notesURL = validatedNotesURL(
            release.htmlURL,
            allowedPrefix: allowedNotesPrefix,
            requireHTTPS: requireHTTPS
        ) else {
            return .invalid("Invalid release notes URL")
        }

        let zipName = "AgentNotch-\(candidate.description).zip"
        let sigName = "\(zipName).sig"

        guard let zipAsset = release.assets.first(where: { $0.name == zipName }) else {
            return .invalid("Release is missing \(zipName)")
        }
        guard let sigAsset = release.assets.first(where: { $0.name == sigName }) else {
            return .invalid("Release is missing \(sigName)")
        }

        guard zipAsset.size > 0, zipAsset.size <= maxArchiveBytes else {
            return .invalid("Update archive size exceeds limit")
        }
        guard sigAsset.size > 0, sigAsset.size <= maxSignatureBytes else {
            return .invalid("Update signature size is invalid")
        }

        guard let zipURL = validatedDownloadURL(
            zipAsset.browserDownloadURL,
            allowedPrefix: allowedDownloadPrefix,
            requireHTTPS: requireHTTPS
        ) else {
            return .invalid("Update archive URL is not allowed")
        }
        guard let sigURL = validatedDownloadURL(
            sigAsset.browserDownloadURL,
            allowedPrefix: allowedDownloadPrefix,
            requireHTTPS: requireHTTPS
        ) else {
            return .invalid("Update signature URL is not allowed")
        }

        return .available(UpdateOffer(
            version: candidate,
            archiveURL: zipURL,
            archiveSize: zipAsset.size,
            signatureURL: sigURL,
            releaseNotesURL: notesURL
        ))
    }

    /// Map non-200 HTTP responses from the GitHub API to a concise user-facing reason.
    public static func httpErrorMessage(statusCode: Int, headers: [AnyHashable: Any]) -> String? {
        if statusCode == 200 { return nil }
        if statusCode == 403 {
            for (k, v) in headers {
                if String(describing: k).lowercased() == "x-ratelimit-remaining",
                   String(describing: v).trimmingCharacters(in: .whitespacesAndNewlines) == "0"
                {
                    return "GitHub rate limit, try again later"
                }
            }
        }
        return "GitHub returned HTTP \(statusCode)"
    }

    /// Transport policy enforced on initial requests and every HTTP redirect.
    public static func isAllowedTransportURL(_ url: URL, requireHTTPS: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if requireHTTPS {
            return scheme == "https"
        }
        switch scheme {
        case "https", "file":
            return true
        case "http":
            let host = url.host?.lowercased()
            return host == "127.0.0.1" || host == "localhost" || host == "::1"
        default:
            return false
        }
    }

    /// Fallback release notes URL used after relaunch (`--updated-to <v>`), since nothing is persisted (R4).
    public static func releaseNotesURL(for version: AppVersion) -> URL {
        URL(string: "https://github.com/bagustyo92/agent-notch/releases/tag/v\(version.description)")!
    }

    public static func userAgent(for version: AppVersion) -> String {
        "AgentNotch/\(version.description)"
    }

    private static func validatedDownloadURL(
        _ raw: String,
        allowedPrefix: String,
        requireHTTPS: Bool
    ) -> URL? {
        guard !raw.isEmpty,
              let url = URL(string: raw),
              isAllowedTransportURL(url, requireHTTPS: requireHTTPS),
              !containsPathTraversal(raw, url: url),
              url.standardized.absoluteString.hasPrefix(allowedPrefix)
        else {
            return nil
        }
        return url
    }

    private static func validatedNotesURL(
        _ raw: String,
        allowedPrefix: String?,
        requireHTTPS: Bool
    ) -> URL? {
        guard !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased()
        else {
            return nil
        }
        if requireHTTPS {
            guard scheme == "https" else { return nil }
        } else {
            let host = url.host?.lowercased()
            let isLoopbackHTTP = scheme == "http" && (host == "127.0.0.1" || host == "localhost" || host == "::1")
            guard scheme == "https" || isLoopbackHTTP else { return nil }
        }
        if let allowedPrefix {
            guard !containsPathTraversal(raw, url: url),
                  url.standardized.absoluteString.hasPrefix(allowedPrefix)
            else {
                return nil
            }
        }
        return url
    }

    private static func containsPathTraversal(_ raw: String, url: URL) -> Bool {
        if url.pathComponents.contains("..") { return true }
        let lower = raw.lowercased()
        return lower.contains("%2e") || lower.contains("%2f") || lower.contains("\\")
    }
}
