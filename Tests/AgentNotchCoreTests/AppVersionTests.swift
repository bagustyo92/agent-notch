import Testing
@testable import AgentNotchCore

@Suite struct AppVersionTests {
    @Test func comparesComponentWise() throws {
        let v070 = try #require(AppVersion("0.7.0"))
        let v0610 = try #require(AppVersion("0.6.10"))
        let v100 = try #require(AppVersion("1.0.0"))
        let v071 = try #require(AppVersion("0.7.1"))

        #expect(v070 > v0610)
        #expect(v0610 < v070)
        #expect(v071 > v070)
        #expect(v100 > v071)
        #expect(!(v070 < v070))
    }

    @Test func stripsLeadingVAndPadsMissingComponents() throws {
        let withV = try #require(AppVersion("v0.7.0"))
        let plain = try #require(AppVersion("0.7.0"))
        let short = try #require(AppVersion("0.7"))

        #expect(withV == plain)
        #expect(short == plain)
        #expect(short.hashValue == plain.hashValue)
        #expect(withV.description == "0.7.0")
        #expect(short.description == "0.7")
        #expect(!(short < plain))
        #expect(!(plain < short))
    }

    @Test func rejectsMalformedStrings() {
        let invalid = [
            "",
            "v",
            "0.7.0-beta",
            "v0.7.0-rc1",
            "1..2",
            ".1",
            "1.",
            "vv0.7.0",
            "V0.7.0",
            " 0.7.0",
            "0.7.0 ",
            "0.7.a",
            "0.-1.0",
            "99999999999999999999999999999.0",
        ]
        for s in invalid {
            #expect(AppVersion(s) == nil, "Expected \(s.debugDescription) to be rejected")
        }
    }
}
