import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct ElapsedFormatting {
    @Test(arguments: [
        (0.0, "0s"), (45.0, "45s"), (59.9, "59s"), (60.0, "1m"), (754.0, "12m"), (3599.0, "59m"),
        (3600.0, "1h 0m"), (4980.0, "1h 23m"), (86_399.0, "23h 59m"), (86_400.0, "1d 0h"), (100_000.0, "1d 3h"),
    ])
    func formatsSecondsCompactly(seconds: Double, expected: String) {
        #expect(ElapsedFormatter.string(seconds) == expected)
    }

    @Test func negativeIsClampedToZero() {
        #expect(ElapsedFormatter.string(-5) == "0s")
    }

    @Test func nonFiniteAndHugeValuesNeverTrap() {
        #expect(ElapsedFormatter.string(.infinity) == "0s")
        #expect(ElapsedFormatter.string(.nan) == "0s")
        #expect(ElapsedFormatter.string(-.infinity) == "0s")
        #expect(!ElapsedFormatter.string(1e300).isEmpty)
    }

    @Test func usesEndedAtForDoneSessions() {
        let start = Date(timeIntervalSince1970: 1_000)
        let s = Session(id: "a", cwd: "/Users/dev/a", name: "a", status: .done, statusChangedAt: start, startedAt: start, endedAt: start.addingTimeInterval(90))
        #expect(ElapsedFormatter.string(for: s, now: start.addingTimeInterval(10_000)) == "1m")
    }
}
