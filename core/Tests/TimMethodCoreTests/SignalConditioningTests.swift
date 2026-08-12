import Foundation
import Testing

@testable import TimMethodCore

/// A tiny deterministic PRNG (splitmix64) so "known injected noise" tests
/// are reproducible — never `SystemRandomNumberGenerator`, which would make
/// these tests flaky by construction.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("SignalConditioning")
struct SignalConditioningTests {
    // MARK: - Helpers

    private static func sampleArray(t: [TimeInterval], x: [Double]) -> [RepSignal.Sample] {
        precondition(t.count == x.count)
        return zip(t, x).map { RepSignal.Sample(t: $0, x: $1, confidence: 1.0) }
    }

    // MARK: - Derivative: headline correctness (uniform spacing)

    @Test("central-difference derivative of a synthetic sine matches the analytic derivative, uniform spacing")
    func derivativeMatchesAnalyticSineUniformSpacing() {
        let sampleRateHz = 60.0
        let frequencyHz = 0.5
        let amplitude = 0.30
        let durationSeconds = 4.0
        let sampleCount = Int(durationSeconds * sampleRateHz)

        let ts = (0..<sampleCount).map { Double($0) / sampleRateHz }
        let xs = ts.map { amplitude * sin(2 * Double.pi * frequencyHz * $0) }
        let samples = Self.sampleArray(t: ts, x: xs)

        let velocities = Derivative.centralDifference(samples)
        #expect(velocities.count == sampleCount - 2)

        for sample in velocities {
            let expected = amplitude * 2 * Double.pi * frequencyHz * cos(2 * Double.pi * frequencyHz * sample.t)
            #expect(abs(sample.v - expected) < 0.01, "t=\(sample.t): got \(sample.v), expected \(expected)")
        }
    }

    // MARK: - Derivative: non-uniform spacing regression guard

    @Test("central-difference derivative is correct under genuinely irregular (non-two-rate) sample spacing")
    func derivativeCorrectUnderNonUniformSpacing() {
        let frequencyHz = 0.4
        let amplitude = 0.25
        let baseDt = 1.0 / 45.0

        // Irregular spacing: each gap is `baseDt` scaled by a continuously
        // varying factor, not merely alternating between two fixed rates —
        // the regression this task's brief specifically calls for.
        var ts: [TimeInterval] = [0]
        var t = 0.0
        for i in 1..<400 {
            let factor = 1.0 + 0.7 * sin(2.3 * Double(i)) + 0.3 * sin(5.1 * Double(i) + 1.0)
            let dt = baseDt * max(0.15, factor)
            t += dt
            ts.append(t)
        }
        let xs = ts.map { amplitude * sin(2 * Double.pi * frequencyHz * $0) }
        let samples = Self.sampleArray(t: ts, x: xs)

        // Sanity: spacing really is irregular, not two-rate.
        let gaps = zip(ts.dropFirst(), ts).map { $0 - $1 }
        let distinctGapBuckets = Set(gaps.map { (($0 / baseDt) * 20).rounded() })
        #expect(distinctGapBuckets.count > 10, "expected genuinely varied spacing, got \(distinctGapBuckets.count) distinct buckets")

        let velocities = Derivative.centralDifference(samples)
        #expect(velocities.count == samples.count - 2)

        for sample in velocities {
            let expected = amplitude * 2 * Double.pi * frequencyHz * cos(2 * Double.pi * frequencyHz * sample.t)
            #expect(abs(sample.v - expected) < 0.02, "t=\(sample.t): got \(sample.v), expected \(expected)")
        }
    }

    @Test("central-difference derivative skips a pair with a non-positive gap instead of fabricating a value")
    func derivativeSkipsNonPositiveGap() {
        // t[1] == t[0]: a zero gap either side of index 1 must not produce
        // an infinite or NaN velocity.
        let samples = Self.sampleArray(t: [0, 0, 0.1, 0.2], x: [0, 0.01, 0.02, 0.03])
        let velocities = Derivative.centralDifference(samples)
        #expect(velocities.allSatisfy { $0.v.isFinite })
        // Only index 2 (t=0.1, neighbours t=0 and t=0.2, both positive gaps
        // from it) can produce a value; index 1's left gap is zero.
        #expect(velocities.map(\.t) == [0.1])
    }

    // MARK: - Rolling-median detrend

    @Test("rolling-median detrend removes a slow linear drift while leaving rep-scale excursion amplitude intact")
    func detrendRemovesLinearDriftKeepsRepAmplitude() {
        let sampleRateHz = 60.0
        let durationSeconds = 30.0
        let sampleCount = Int(durationSeconds * sampleRateHz)
        let driftRatePerSecond = 0.004 // slow: ~12 cm over the whole 30s clip
        let repAmplitude = 0.30
        let repFrequencyHz = 0.5 // 2s period, several cycles per 3s window

        let ts = (0..<sampleCount).map { Double($0) / sampleRateHz }
        let xs = ts.map { t in
            driftRatePerSecond * t + repAmplitude * sin(2 * Double.pi * repFrequencyHz * t)
        }
        let samples = Self.sampleArray(t: ts, x: xs)
        let detrended = RollingMedianDetrend.detrend(samples)

        // Steady state: once the window is fully warmed up (past one window
        // duration), the residual's peak-to-peak amplitude should closely
        // match the injected rep oscillation's own peak-to-peak (2x
        // amplitude) — the causal median tracks the slow drift with a small,
        // roughly constant lag offset, which does not compress amplitude.
        let warmupCutoff = RollingMedianDetrend.defaultWindowSeconds * 2
        let steadyState = detrended.filter { $0.t >= warmupCutoff }
        #expect(steadyState.count > 100)

        let peakToPeak = (steadyState.map(\.x).max() ?? 0) - (steadyState.map(\.x).min() ?? 0)
        let expectedPeakToPeak = 2 * repAmplitude
        #expect(
            abs(peakToPeak - expectedPeakToPeak) / expectedPeakToPeak < 0.15,
            "peak-to-peak \(peakToPeak), expected close to \(expectedPeakToPeak)"
        )

        // The drift itself must actually have been removed: a window near
        // the end of the clip should not be offset by anywhere close to the
        // full drift accumulated over 30s (~0.12 m) — a few window-lengths'
        // worth of drift lag at most.
        let lateWindow = detrended.filter { $0.t >= durationSeconds - 3 }
        let lateMean = lateWindow.map(\.x).reduce(0, +) / Double(lateWindow.count)
        let totalDrift = driftRatePerSecond * durationSeconds
        #expect(abs(lateMean) < totalDrift * 0.5, "late-window mean \(lateMean) should be well under the full \(totalDrift) drift")
    }

    @Test("rolling-median detrend removes a slow sinusoidal drift while leaving rep-scale excursion amplitude intact")
    func detrendRemovesSinusoidalDriftKeepsRepAmplitude() {
        let sampleRateHz = 60.0
        let durationSeconds = 40.0
        let sampleCount = Int(durationSeconds * sampleRateHz)
        let driftAmplitude = 0.15
        let driftFrequencyHz = 0.02 // 50s period — far slower than the 3s window
        let repAmplitude = 0.25
        let repFrequencyHz = 0.6

        let ts = (0..<sampleCount).map { Double($0) / sampleRateHz }
        let xs = ts.map { t in
            driftAmplitude * sin(2 * Double.pi * driftFrequencyHz * t) + repAmplitude * sin(2 * Double.pi * repFrequencyHz * t)
        }
        let samples = Self.sampleArray(t: ts, x: xs)
        let detrended = RollingMedianDetrend.detrend(samples)

        let warmupCutoff = RollingMedianDetrend.defaultWindowSeconds * 2
        let steadyState = detrended.filter { $0.t >= warmupCutoff && $0.t <= durationSeconds - warmupCutoff }
        #expect(steadyState.count > 100)

        // Check peak-to-peak amplitude over several short sub-windows rather
        // than the whole steady-state span: the drift is slow but not
        // static, so a single global peak-to-peak would also capture some
        // of the drift's own excursion. A short sub-window (a few rep
        // periods) isolates the rep-scale swing from the much-slower drift.
        let subWindowSeconds = 4.0
        var sampledPeakToPeaks: [Double] = []
        var windowStart = warmupCutoff
        while windowStart + subWindowSeconds <= durationSeconds - warmupCutoff {
            let window = steadyState.filter { $0.t >= windowStart && $0.t < windowStart + subWindowSeconds }
            if window.count > 10 {
                sampledPeakToPeaks.append((window.map(\.x).max() ?? 0) - (window.map(\.x).min() ?? 0))
            }
            windowStart += subWindowSeconds
        }
        #expect(!sampledPeakToPeaks.isEmpty)

        let expectedPeakToPeak = 2 * repAmplitude
        for peakToPeak in sampledPeakToPeaks {
            #expect(
                abs(peakToPeak - expectedPeakToPeak) / expectedPeakToPeak < 0.2,
                "sub-window peak-to-peak \(peakToPeak), expected close to \(expectedPeakToPeak)"
            )
        }
    }

    // MARK: - Default path is unsmoothed

    @Test("the default conditioning pipeline (no smoothing configured) is bit-for-bit identical to detrend + derivative alone")
    func defaultPipelineIsBitForBitUnsmoothed() {
        let sampleRateHz = 60.0
        let sampleCount = 400
        let ts = (0..<sampleCount).map { Double($0) / sampleRateHz }
        let xs = ts.map { t in 0.02 * sin(2 * Double.pi * 0.5 * t) + 0.001 * sin(37 * t) }
        let samples = Self.sampleArray(t: ts, x: xs)

        // The pipeline's default `Configuration()` leaves `smoothing` at its
        // default `nil`.
        let pipelineResult = SignalConditioningPipeline.condition(samples)

        let manualDetrend = RollingMedianDetrend.detrend(samples)
        let manualVelocity = Derivative.centralDifference(manualDetrend)

        #expect(pipelineResult.detrended == manualDetrend)
        #expect(pipelineResult.velocity == manualVelocity)
    }

    @Test("explicitly configuring smoothing changes the pipeline's detrended output versus the default")
    func explicitSmoothingChangesOutput() {
        let sampleRateHz = 60.0
        let sampleCount = 300
        let ts = (0..<sampleCount).map { Double($0) / sampleRateHz }
        var rng = SeededGenerator(seed: 42)
        let xs = ts.map { t in
            0.02 * sin(2 * Double.pi * 0.5 * t) + Double.random(in: -0.01...0.01, using: &rng)
        }
        let samples = Self.sampleArray(t: ts, x: xs)

        let unsmoothed = SignalConditioningPipeline.condition(samples)
        let smoothed = SignalConditioningPipeline.condition(
            samples,
            configuration: .init(smoothing: OneEuroFilter.Configuration())
        )

        #expect(unsmoothed.detrended != smoothed.detrended)
    }

    // MARK: - One Euro filter: reduces jitter, lag is measured

    @Test("the One Euro filter, explicitly enabled, reduces error against the clean underlying value versus raw noisy input on a static hold")
    func oneEuroFilterReducesJitter() {
        // "Jitter" (SPEC §4.1, this task's own framing) means static-subject
        // noise, so this reduction test uses the same shape of signal the
        // filter is meant for: a near-constant true position plus
        // frame-to-frame noise — not a signal that is itself moving fast
        // relative to the filter's cutoff, which would mix in tracking lag
        // as a second error source and muddy what's being measured. Lag on
        // a moving signal is covered separately and explicitly by
        // `oneEuroFilterLagIsPositiveAndMeasured`.
        let sampleRateHz = 60.0
        let sampleCount = 600
        let trueValue = 0.02
        var rng = SeededGenerator(seed: 7)

        var filter = OneEuroFilter(configuration: .init(minCutoff: 1.0, beta: 0.0, derivativeCutoff: 1.0))
        var rawErrorSquaredSum = 0.0
        var filteredErrorSquaredSum = 0.0
        var n = 0

        for i in 0..<sampleCount {
            let t = Double(i) / sampleRateHz
            let noisy = trueValue + Double.random(in: -0.03...0.03, using: &rng)
            let filtered = filter.filter(t: t, x: noisy)

            // Skip the warm-up transient near the very start.
            if i > 30 {
                rawErrorSquaredSum += (noisy - trueValue) * (noisy - trueValue)
                filteredErrorSquaredSum += (filtered - trueValue) * (filtered - trueValue)
                n += 1
            }
        }

        let rawRMSE = (rawErrorSquaredSum / Double(n)).squareRoot()
        let filteredRMSE = (filteredErrorSquaredSum / Double(n)).squareRoot()
        #expect(filteredRMSE < rawRMSE * 0.6, "filtered RMSE \(filteredRMSE) should be well below raw RMSE \(rawRMSE)")
    }

    @Test("the One Euro filter's lag on a step input is measured and is strictly positive")
    func oneEuroFilterLagIsPositiveAndMeasured() throws {
        let sampleRateHz = 60.0
        let stepAtSeconds = 1.0
        let minCutoff = 1.0
        var filter = OneEuroFilter(configuration: .init(minCutoff: minCutoff, beta: 0.0, derivativeCutoff: 1.0))

        var crossingTime: TimeInterval?
        var t: TimeInterval = 0
        while t < 3.0 {
            let raw = t < stepAtSeconds ? 0.0 : 1.0
            let filtered = filter.filter(t: t, x: raw)
            if crossingTime == nil, t >= stepAtSeconds, filtered >= 0.5 {
                crossingTime = t
            }
            t += 1.0 / sampleRateHz
        }

        let measuredLag = try #require(crossingTime) - stepAtSeconds
        // The filter must have real, nonzero lag (the cost this task's
        // brief asks to make visible) ...
        #expect(measuredLag > 0)
        // ... and that lag should be in the ballpark set by the configured
        // cutoff (tau = 1 / (2*pi*minCutoff) ~= 0.159s here) rather than
        // being unboundedly large — a generous multiple of tau as a sanity
        // ceiling, not a tight tuned bound.
        let tau = 1 / (2 * Double.pi * minCutoff)
        #expect(measuredLag < tau * 5, "measured lag \(measuredLag)s, expected within a few multiples of tau=\(tau)s")
    }

    // MARK: - Jitter measurement

    @Test("jitter measurement returns sane numbers on a synthetic static signal with known injected noise")
    func jitterMeasurementSaneOnStaticSignalWithKnownNoise() throws {
        let sampleRateHz = 60.0
        let durationSeconds = 30.0
        let sampleCount = Int(durationSeconds * sampleRateHz)
        let trueValue = 0.02
        let noiseAmplitude = 0.004 // uniform in [-noiseAmplitude, noiseAmplitude]

        var rng = SeededGenerator(seed: 1234)
        var ts: [TimeInterval] = []
        var xs: [Double] = []
        for i in 0..<sampleCount {
            let t = Double(i) / sampleRateHz
            let noise = Double.random(in: -noiseAmplitude...noiseAmplitude, using: &rng)
            ts.append(t)
            xs.append(trueValue + noise)
        }
        let samples = Self.sampleArray(t: ts, x: xs)

        let repAmplitudeReference = 0.4 // a plausible squat peak-to-valley ROM, supplied by the caller, not guessed here
        let measurement = try #require(JitterAnalysis.measure(samples, repAmplitudeReferenceMetres: repAmplitudeReference))

        #expect(measurement.sampleCount == sampleCount)
        #expect(abs(measurement.durationSeconds - (Double(sampleCount - 1) / sampleRateHz)) < 1e-9)

        // Detrended mean should sit close to zero — the constant true value
        // was removed by the median, leaving only (near-zero-mean) noise.
        #expect(abs(measurement.meanMetres) < noiseAmplitude * 0.5, "mean \(measurement.meanMetres)")

        // Uniform noise on [-A, A] has standard deviation A/sqrt(3).
        let expectedStandardDeviation = noiseAmplitude / 3.0.squareRoot()
        #expect(
            abs(measurement.standardDeviationMetres - expectedStandardDeviation) / expectedStandardDeviation < 0.2,
            "std dev \(measurement.standardDeviationMetres), expected close to \(expectedStandardDeviation)"
        )

        // Peak-to-peak of uniform noise over many samples approaches 2A from below.
        #expect(measurement.peakToPeakMetres > noiseAmplitude * 1.2)
        #expect(measurement.peakToPeakMetres < noiseAmplitude * 2.3)

        let ratio = try #require(measurement.jitterToRepAmplitudeRatio)
        #expect(abs(ratio - measurement.peakToPeakMetres / repAmplitudeReference) < 1e-12)
        // The whole point of the ratio: this synthetic noise floor is a
        // small fraction of a real rep's swept range.
        #expect(ratio < 0.05, "jitter/rep-amplitude ratio \(ratio) unexpectedly large for injected noise this small")
    }

    @Test("jitter measurement returns nil for fewer than two samples")
    func jitterMeasurementNilForInsufficientSamples() {
        #expect(JitterAnalysis.measure([]) == nil)
        #expect(JitterAnalysis.measure([RepSignal.Sample(t: 0, x: 0, confidence: 1)]) == nil)
    }

    @Test("jitter measurement omits the ratio when no rep-amplitude reference is supplied, or when it is non-positive")
    func jitterMeasurementOmitsRatioWithoutReference() {
        let samples = Self.sampleArray(t: [0, 1, 2, 3], x: [0.01, 0.011, 0.009, 0.01])
        let noReference = JitterAnalysis.measure(samples)
        #expect(noReference?.jitterToRepAmplitudeRatio == nil)
        #expect(noReference?.repAmplitudeReferenceMetres == nil)

        let nonPositiveReference = JitterAnalysis.measure(samples, repAmplitudeReferenceMetres: -1)
        #expect(nonPositiveReference?.jitterToRepAmplitudeRatio == nil)
        #expect(nonPositiveReference?.repAmplitudeReferenceMetres == nil)
    }
}
