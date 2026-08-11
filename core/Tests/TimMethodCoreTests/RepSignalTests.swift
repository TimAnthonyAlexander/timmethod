import Foundation
import Testing

@testable import TimMethodCore

@Suite("RepSignal")
struct RepSignalTests {
    // MARK: - Capacity

    @Test("default capacity is 180s at 60Hz")
    func defaultCapacityArithmetic() {
        #expect(RepSignal.defaultCapacity == 180 * 60)
        let signal = RepSignal(scale: .torsoRelative)
        #expect(signal.samples.capacity == 10_800)
    }

    @Test("capacity is overridable")
    func capacityOverride() {
        let signal = RepSignal(scale: .torsoRelative, capacity: 42)
        #expect(signal.samples.capacity == 42)
    }

    // MARK: - Sine round-trip

    @Test("a synthetic sine wave round-trips through RepSignal without distortion")
    func sineRoundTrips() {
        var signal = RepSignal(scale: .plateDiameter(mm: 450), capacity: 1_000)

        let sampleRateHz = 60.0
        let frequencyHz = 0.5
        let amplitude = 0.30
        let sampleCount = 120 // 2 seconds at 60 Hz

        var expected: [(t: TimeInterval, x: Double)] = []
        for i in 0..<sampleCount {
            let t = Double(i) / sampleRateHz
            let x = amplitude * sin(2 * Double.pi * frequencyHz * t)
            signal.append(t: t, x: x, confidence: 0.95)
            expected.append((t: t, x: x))
        }

        #expect(signal.samples.count == sampleCount)

        // Every sample round-trips: exact position, exact value (within
        // floating-point tolerance), oldest-first ordering preserved.
        for i in 0..<sampleCount {
            let sample = signal.samples[i]
            #expect(abs(sample.t - expected[i].t) < 1e-9)
            #expect(abs(sample.x - expected[i].x) < 1e-9)
            #expect(sample.confidence == 0.95)
        }

        // Spot-check the actual shape, not just that values exist: sample 0
        // is at the zero crossing rising, sample 30 (t=0.5s, quarter period)
        // is at the peak.
        #expect(abs(signal.samples[0].x) < 1e-9)
        #expect(abs(signal.samples[30].x - amplitude) < 1e-9)
    }

    // MARK: - Trace export fidelity

    @Test("trace() returns exactly targetCount samples")
    func traceReturnsExactCount() {
        var signal = RepSignal(scale: .torsoRelative, capacity: 2_000)
        for i in 0..<600 {
            signal.append(t: Double(i) / 60.0, x: sin(Double(i)), confidence: 1.0)
        }
        #expect(signal.trace(targetCount: 100).count == 100)
        #expect(signal.trace(targetCount: 1).count == 1)
        #expect(signal.trace(targetCount: 600).count == 600)
    }

    @Test("trace() on an empty signal returns an empty array")
    func traceOnEmptySignal() {
        let signal = RepSignal(scale: .torsoRelative)
        #expect(signal.trace(targetCount: 128) == [])
    }

    @Test("trace() preserves peak/trough structure of a downsampled sine")
    func tracePreservesPeaksAndTroughs() {
        var signal = RepSignal(scale: .lidarBodyHeight(m: 1.78), capacity: 2_000)

        let sampleRateHz = 60.0
        let frequencyHz = 0.4 // slow, rep-scale motion
        let amplitude = 0.5
        let durationSec = 10.0
        let sampleCount = Int(durationSec * sampleRateHz) // 600 samples, 4 full cycles

        for i in 0..<sampleCount {
            let t = Double(i) / sampleRateHz
            let x = amplitude * sin(2 * Double.pi * frequencyHz * t)
            signal.append(t: t, x: x, confidence: 1.0)
        }

        let targetCount = 100 // well above Nyquist for a 0.4 Hz signal
        let trace = signal.trace(targetCount: targetCount)
        #expect(trace.count == targetCount)

        // Amplitude is preserved: the resampled max/min should land close to
        // the true peak/trough, not be smoothed away.
        let maxValue = trace.max() ?? 0
        let minValue = trace.min() ?? 0
        #expect(abs(Double(maxValue) - amplitude) < 0.02)
        #expect(abs(Double(minValue) + amplitude) < 0.02)

        // Structure, not just amplitude: a local maximum for each of the
        // 4 cycles should still be present in the downsampled trace.
        var peakCount = 0
        for i in 1..<(trace.count - 1) {
            if trace[i] > trace[i - 1] && trace[i] > trace[i + 1] && trace[i] > 0.4 {
                peakCount += 1
            }
        }
        #expect(peakCount == 4)
    }

    @Test("trace() on a single sample fills targetCount with that value")
    func traceOnSingleSample() {
        var signal = RepSignal(scale: .torsoRelative)
        signal.append(t: 0, x: 0.42, confidence: 1.0)
        let trace = signal.trace(targetCount: 10)
        #expect(trace.count == 10)
        // 1e-6 tolerance, not 1e-9: values pass through a Double -> Float
        // narrowing conversion in trace(), which loses precision beyond
        // Float's ~7 significant digits.
        #expect(trace.allSatisfy { abs(Double($0) - 0.42) < 1e-6 })
    }

    // MARK: - ScaleSource trust semantics

    @Test("plateDiameter and lidarBodyHeight are metrically trustworthy")
    func measuredScalesAreTrustworthy() {
        #expect(RepSignal.ScaleSource.plateDiameter(mm: 450).isMetricallyTrustworthy)
        #expect(RepSignal.ScaleSource.lidarBodyHeight(m: 1.8).isMetricallyTrustworthy)
    }

    @Test("referenceHeight and torsoRelative are not metrically trustworthy")
    func unmeasuredScalesAreNotTrustworthy() {
        #expect(!RepSignal.ScaleSource.referenceHeight.isMetricallyTrustworthy)
        #expect(!RepSignal.ScaleSource.torsoRelative.isMetricallyTrustworthy)
    }

    @Test("ScaleSource preserves its associated values")
    func scaleSourceAssociatedValues() {
        #expect(RepSignal.ScaleSource.plateDiameter(mm: 450) == .plateDiameter(mm: 450))
        #expect(RepSignal.ScaleSource.plateDiameter(mm: 450) != .plateDiameter(mm: 400))
        #expect(RepSignal.ScaleSource.lidarBodyHeight(m: 1.8) == .lidarBodyHeight(m: 1.8))
    }
}
