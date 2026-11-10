import Foundation
import Testing
@testable import AgentNotchCore

/// The D34 motion curves, sampled for Core Animation keyframes (D42).
@Suite struct MotionCurves {
    @Test func theWaveSwingsFromZeroToOne() {
        #expect(abs(Motion.wave(0) - 0.5) < 1e-9)
        #expect(abs(Motion.wave(0.25) - 1) < 1e-9)
        #expect(abs(Motion.wave(0.75)) < 1e-9)
    }

    @Test func aDotLiftsAsTheWaveSquared() {
        let lift = Motion.dotLift(samples: 33)
        #expect(lift.count == 33)
        #expect(abs(lift[0] - 0.25) < 1e-9)                 // wave(0)² = 0.5²
        #expect(abs(lift[8] - 1) < 1e-9)                    // a quarter period in: the top
        #expect(abs(lift[24]) < 1e-9)                       // three quarters in: the bottom
        #expect(abs(lift.first! - lift.last!) < 1e-9)       // a seamless loop
    }

    @Test func theGlowBreathesAsThePlainWave() {
        let glow = Motion.glowLevels(samples: 5)
        #expect(glow.count == 5)
        #expect(zip(glow, [0.5, 1, 0.5, 0, 0.5]).allSatisfy { abs($0 - $1) < 1e-9 })
    }

    @Test func everyCopyStartsInStepWithTheWallClock() {
        let period = Motion.dotsPeriod
        let now = Date(timeIntervalSinceReferenceDate: 10 * period + 0.3)
        #expect(abs(Motion.timeOffset(now: now, period: period) - 0.3) < 1e-9)
        // Dot i trails dot 0 by i × stagger of the period, wrapped into one period.
        let lagged = Motion.timeOffset(now: now, period: period, lag: Motion.dotsStagger)
        let expected = (0.3 - Motion.dotsStagger * period + period).truncatingRemainder(dividingBy: period)
        #expect(abs(lagged - expected) < 1e-9)
        #expect((0..<3).allSatisfy { i in
            let t = Motion.timeOffset(now: now, period: period, lag: Double(i) * Motion.dotsStagger)
            return t >= 0 && t < period
        })
    }

    @Test func theCurvesKeepTheirTiming() {
        #expect(Motion.dotsPeriod == 1.1)
        #expect(Motion.dotsStagger == 0.17)
        #expect(Motion.glowPeriod == 2)
        #expect(Motion.shimmerPeriod == 2.2)
    }
}
