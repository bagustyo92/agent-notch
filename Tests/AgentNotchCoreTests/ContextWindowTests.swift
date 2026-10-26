import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct ContextWindows {
    @Test(arguments: [
        ("claude-opus-5-5", 1_000_000),
        ("claude-fable-5-1", 1_000_000),
        ("claude-sonnet-5-5", 1_000_000),
        ("claude-haiku-5-5", 1_000_000),
        ("claude-opus-4-7", 1_000_000),
        ("claude-opus-4-8-20260101", 1_000_000),
        ("claude-opus-4-6", 200_000),
        ("claude-opus-4-1-20250805", 200_000),
        ("claude-sonnet-4-5-20250929", 200_000),
        ("claude-sonnet-4-20250514", 200_000),
        ("claude-haiku-4-5-20251001", 200_000),
        ("claude-sonnet-4-5-20250929[1m]", 1_000_000),
    ])
    func knownModels(id: String, window: Int) {
        #expect(ContextWindow.window(forModel: id) == window)
    }

    @Test(arguments: ["gpt-x", "claude-3-5-haiku-20241022", "claude-haiku-5-1", "claude-opus-4-10", "claude-opus-50", ""])
    func unknownModels(id: String) {
        #expect(ContextWindow.window(forModel: id) == nil)
    }

    @Test func noModelNoWindow() {
        #expect(ContextWindow.window(forModel: nil) == nil)
    }

    @Test func percentRoundsAndClamps() {
        #expect(ContextWindow.percent(tokens: 620_000, window: 1_000_000) == 62)
        #expect(ContextWindow.percent(tokens: 1_000, window: 200_000) == 1)       // 0.5 rounds up
        #expect(ContextWindow.percent(tokens: 999, window: 200_000) == 0)
        #expect(ContextWindow.percent(tokens: 250_000, window: 200_000) == 100)
        #expect(ContextWindow.percent(tokens: -5, window: 200_000) == 0)
        #expect(ContextWindow.percent(tokens: 5, window: 0) == 0)
    }

    /// Compact point = window − 33 000: 967 000 for 1M, 167 000 for 200k.
    @Test(arguments: [
        (725_249, 1_000_000, ContextLevel.normal), (725_250, 1_000_000, .warn),
        (870_299, 1_000_000, .warn), (870_300, 1_000_000, .critical), (990_000, 1_000_000, .critical),
        (125_249, 200_000, .normal), (125_250, 200_000, .warn),
        (150_299, 200_000, .warn), (150_300, 200_000, .critical),
    ])
    func levelsAgainstTheCompactPoint(tokens: Int, window: Int, level: ContextLevel) {
        #expect(ContextWindow.level(tokens: tokens, window: window) == level)
    }

    @Test func unknownWindowIsNeverColored() {
        #expect(ContextWindow.level(tokens: 900_000, window: nil) == .normal)
    }

    @Test func labelIsAPercentOrARawCount() {
        #expect(ContextWindow.label(tokens: 620_000, window: 1_000_000) == "62%")
        #expect(ContextWindow.label(tokens: 412_345, window: nil) == "412k")
        #expect(ContextWindow.label(tokens: 412_600, window: nil) == "413k")
        #expect(ContextWindow.label(tokens: 850, window: nil) == "850")
        #expect(ContextWindow.label(tokens: 1_234_000, window: nil) == "1.2M")
    }
}
