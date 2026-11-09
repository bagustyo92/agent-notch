import Foundation

/// The motion curves of D34, sampled so Core Animation can run them as keyframes in the window
/// server (D42). Before 0.6.0 SwiftUI timelines redrew them 20–30 times a second, at 4–7% CPU each.
public enum Motion {
    /// Working dots: one rise and fall per period; dot i trails dot 0 by i × `dotsStagger` periods.
    public static let dotsPeriod: TimeInterval = 1.1
    public static let dotsStagger = 0.17
    /// Needs-you glow: one breath per period.
    public static let glowPeriod: TimeInterval = 2
    /// Thinking shimmer: one sweep across the text per period.
    public static let shimmerPeriod: TimeInterval = 2.2

    /// 0…1, `0.5 + 0.5 sin(2π phase)`.
    public static func wave(_ phase: Double) -> Double { 0.5 + 0.5 * sin(2 * .pi * phase) }

    /// One period of a working dot's lift, `wave²`, sampled `samples` times from phase 0 to 1
    /// inclusive, so the first and last values match and the loop is seamless.
    public static func dotLift(samples: Int) -> [Double] { sampled(samples) { pow(wave($0), 2) } }

    /// One period of the glow's breath, `wave`, sampled like `dotLift`.
    public static func glowLevels(samples: Int) -> [Double] { sampled(samples, wave) }

    /// The `timeOffset` that starts an animation where the wall clock says it is, so every copy on
    /// screen moves in step, as the timeline versions did. `lag` delays it by that fraction of the period.
    public static func timeOffset(now: Date, period: TimeInterval, lag: Double = 0) -> TimeInterval {
        guard period > 0 else { return 0 }
        let t = (now.timeIntervalSinceReferenceDate - lag * period).truncatingRemainder(dividingBy: period)
        return t < 0 ? t + period : t
    }

    private static func sampled(_ samples: Int, _ f: (Double) -> Double) -> [Double] {
        let n = max(2, samples)
        return (0..<n).map { f(Double($0) / Double(n - 1)) }
    }
}
