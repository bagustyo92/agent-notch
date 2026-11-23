import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct ReleaseFeedTests {
    private func load(_ name: String) throws -> ReleaseFeed.Release {
        try ReleaseFeed.decode(try fixtureData("releases/\(name)"))
    }

    @Test func newerReleaseOffersValidAssets() throws {
        let release = try load("valid-0.7.1.json")
        let decision = ReleaseFeed.decide(release: release, running: try #require(AppVersion("0.7.0")))
        guard case .available(let offer) = decision else {
            Issue.record("Expected .available, got \(decision)")
            return
        }
        #expect(offer.version == AppVersion("0.7.1"))
        #expect(offer.archiveURL.absoluteString == "https://github.com/bagustyo92/agent-notch/releases/download/v0.7.1/AgentNotch-0.7.1.zip")
        #expect(offer.signatureURL.absoluteString == "https://github.com/bagustyo92/agent-notch/releases/download/v0.7.1/AgentNotch-0.7.1.zip.sig")
        #expect(offer.releaseNotesURL.absoluteString == "https://github.com/bagustyo92/agent-notch/releases/tag/v0.7.1")
        #expect(offer.archiveSize == 4_200_000)
    }

    @Test func sameOrOlderVersionIsUpToDate() throws {
        let release = try load("valid-0.7.1.json")
        #expect(ReleaseFeed.decide(release: release, running: try #require(AppVersion("0.7.1"))) == .upToDate)
        #expect(ReleaseFeed.decide(release: release, running: try #require(AppVersion("0.8.0"))) == .upToDate)
    }

    @Test func draftAndPrereleaseAreUpToDate() throws {
        let running = try #require(AppVersion("0.7.0"))
        #expect(ReleaseFeed.decide(release: try load("draft-0.7.1.json"), running: running) == .upToDate)
        #expect(ReleaseFeed.decide(release: try load("prerelease-0.7.1.json"), running: running) == .upToDate)
    }

    @Test func missingSigOrZipIsInvalid() throws {
        let running = try #require(AppVersion("0.7.0"))
        let missingSig = ReleaseFeed.decide(release: try load("missing-sig.json"), running: running)
        guard case .invalid = missingSig else {
            Issue.record("Expected .invalid for missing sig, got \(missingSig)")
            return
        }

        let noZip = ReleaseFeed.Release(
            tagName: "v0.7.1",
            htmlURL: "https://github.com/bagustyo92/agent-notch/releases/tag/v0.7.1",
            draft: false,
            prerelease: false,
            assets: [
                ReleaseFeed.Asset(
                    name: "AgentNotch-0.7.1.zip.sig",
                    browserDownloadURL: "https://github.com/bagustyo92/agent-notch/releases/download/v0.7.1/AgentNotch-0.7.1.zip.sig",
                    size: 89
                ),
            ]
        )
        guard case .invalid = ReleaseFeed.decide(release: noZip, running: running) else {
            Issue.record("Expected .invalid for missing zip")
            return
        }
    }

    @Test func foreignOrDowngradedOrTraversalURLIsInvalid() throws {
        let running = try #require(AppVersion("0.7.0"))
        let foreign = ReleaseFeed.decide(release: try load("foreign-url.json"), running: running)
        guard case .invalid = foreign else {
            Issue.record("Expected .invalid for foreign URL, got \(foreign)")
            return
        }

        let traversal = ReleaseFeed.Release(
            tagName: "v0.7.1",
            htmlURL: "https://github.com/bagustyo92/agent-notch/releases/tag/v0.7.1",
            draft: false,
            prerelease: false,
            assets: [
                ReleaseFeed.Asset(
                    name: "AgentNotch-0.7.1.zip",
                    browserDownloadURL: "https://github.com/bagustyo92/agent-notch/releases/download/../../../evil/repo/AgentNotch-0.7.1.zip",
                    size: 1024
                ),
                ReleaseFeed.Asset(
                    name: "AgentNotch-0.7.1.zip.sig",
                    browserDownloadURL: "https://github.com/bagustyo92/agent-notch/releases/download/v0.7.1/AgentNotch-0.7.1.zip.sig",
                    size: 89
                ),
            ]
        )
        guard case .invalid = ReleaseFeed.decide(release: traversal, running: running) else {
            Issue.record("Expected .invalid for path traversal URL")
            return
        }

        let httpNotes = ReleaseFeed.Release(
            tagName: "v0.7.1",
            htmlURL: "http://github.com/bagustyo92/agent-notch/releases/tag/v0.7.1",
            draft: false,
            prerelease: false,
            assets: try load("valid-0.7.1.json").assets
        )
        guard case .invalid = ReleaseFeed.decide(release: httpNotes, running: running) else {
            Issue.record("Expected .invalid for non-HTTPS html_url")
            return
        }
    }

    @Test func oversizeArchiveIsInvalid() throws {
        let decision = ReleaseFeed.decide(
            release: try load("oversize.json"),
            running: try #require(AppVersion("0.7.0"))
        )
        guard case .invalid = decision else {
            Issue.record("Expected .invalid for oversize archive, got \(decision)")
            return
        }
    }

    @Test func malformedTagIsInvalid() throws {
        let release = ReleaseFeed.Release(
            tagName: "v0.7.1-beta",
            htmlURL: "https://github.com/bagustyo92/agent-notch/releases/tag/v0.7.1-beta",
            draft: false,
            prerelease: false,
            assets: []
        )
        guard case .invalid = ReleaseFeed.decide(release: release, running: try #require(AppVersion("0.7.0"))) else {
            Issue.record("Expected .invalid for malformed tag")
            return
        }
    }

    @Test func mapsRateLimitAndHttpErrors() {
        #expect(ReleaseFeed.httpErrorMessage(statusCode: 200, headers: [:]) == nil)
        #expect(
            ReleaseFeed.httpErrorMessage(statusCode: 403, headers: ["X-RateLimit-Remaining": "0"])
                == "GitHub rate limit, try again later"
        )
        #expect(
            ReleaseFeed.httpErrorMessage(statusCode: 403, headers: ["x-ratelimit-remaining": "12"])
                == "GitHub returned HTTP 403"
        )
        #expect(
            ReleaseFeed.httpErrorMessage(statusCode: 502, headers: [:])
                == "GitHub returned HTTP 502"
        )
    }

    @Test func transportPolicyEnforcesHTTPSInProduction() throws {
        #expect(ReleaseFeed.isAllowedTransportURL(try #require(URL(string: "https://objects.githubusercontent.com/file")), requireHTTPS: true))
        #expect(!ReleaseFeed.isAllowedTransportURL(try #require(URL(string: "http://objects.githubusercontent.com/file")), requireHTTPS: true))
        #expect(!ReleaseFeed.isAllowedTransportURL(try #require(URL(string: "http://127.0.0.1:8080/feed.json")), requireHTTPS: true))
        #expect(!ReleaseFeed.isAllowedTransportURL(try #require(URL(string: "file:///tmp/feed.json")), requireHTTPS: true))

        #expect(ReleaseFeed.isAllowedTransportURL(try #require(URL(string: "http://127.0.0.1:8080/feed.json")), requireHTTPS: false))
        #expect(ReleaseFeed.isAllowedTransportURL(try #require(URL(string: "file:///tmp/feed.json")), requireHTTPS: false))
        #expect(!ReleaseFeed.isAllowedTransportURL(try #require(URL(string: "http://example.com/feed.json")), requireHTTPS: false))
    }
}
