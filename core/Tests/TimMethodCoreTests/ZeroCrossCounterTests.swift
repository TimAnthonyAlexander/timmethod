import Foundation
import Testing

@testable import TimMethodCore

/// All verification here is synthetic — hand-generated analytic sine
/// signals, matching `MotionAxisTests` / `PostureGateTests` precedent, not
/// real footage. That is deliberate: these tests exercise
/// `ZeroCrossCounter` in isolation from `SignalConditioning`'s own
/// correctness (already covered by `SignalConditioningTests`), so velocity
/// is computed here in closed form (`v = dx/dt` of the cosine directly)
/// rather than through `Derivative.centralDifference`.
@Suite("ZeroCrossCounter")
struct ZeroCrossCounterTests {

    // MARK: - Fixtures

    struct Sample {
        let t: TimeInterval
        let x: Double
        let v: Double
    }

    /// A tiny deterministic PRNG so the irregular-spacing and jitter
    /// fixtures are reproducible across runs without depending on
    /// `SystemRandomNumberGenerator` (same reasoning as any other fixture
    /// in this suite needing "random but repeatable").
    struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// Analytic cosine samples: `x(t) = amplitude * cos(2π f t)`, `v(t) =
    /// dx/dt` in closed form. `t` runs from `-leadIn` through
    /// `cycles / frequency + leadIn` (a quarter of this signal's own
    /// period on each end, by default), so both the very first true peak
    /// at `t = 0` and the very last true peak at `t = cycles / frequency`
    /// are reached — and left — via a genuine crossing rather than being
    /// the stream's first or last sample.
    ///
    /// Both ends of that lead matter, for the same reason: `ZeroCrossCounter`
    /// commits an extremum only once a crossing *away* from it is
    /// observed (peak → valley → peak closes on the sample where the
    /// return crossing happens — SPEC §7.2, this file's "count on return
    /// to start position, immediately"). A stream that starts exactly at a
    /// peak has no crossing *into* it, so that peak never becomes
    /// `lastPeak`; a stream that ends exactly at a peak has no crossing
    /// *out of* it, so that peak never commits at all and the cycle it
    /// should have completed is silently lost. Neither is a bug to work
    /// around with special-casing (this file's whole design rule is
    /// "don't add judgment") — it is the correct, honest behaviour of a
    /// causal detector fed a stream that begins or ends mid-motion. A
    /// quarter-period lead on each end is simply giving the detector the
    /// same runway a live capture would have (the lifter was already
    /// moving before the count started, and the stream doesn't cut off
    /// the instant the last rep's lockout is reached).
    static func cosineSamples(
        cycles: Int,
        frequency: Double,
        sampleRate: Double,
        amplitude: Double = 1.0,
        leadIn: TimeInterval? = nil
    ) -> [Sample] {
        let period = 1.0 / frequency
        let dt = 1.0 / sampleRate
        let lead = leadIn ?? period / 4
        let end = Double(cycles) * period + lead
        var samples: [Sample] = []
        var t = -lead
        while t <= end + dt / 2 {
            let phase = 2 * Double.pi * frequency * t
            samples.append(Sample(t: t, x: amplitude * cos(phase), v: -amplitude * 2 * Double.pi * frequency * sin(phase)))
            t += dt
        }
        return samples
    }

    /// Drives a fresh `ZeroCrossCounter` sample by sample (the streaming
    /// shape a live `AsyncStream` would use) and collects every emitted
    /// candidate, in order.
    static func run(_ samples: [Sample], configuration: ZeroCrossCounter.Configuration = ZeroCrossCounter.Configuration())
        -> [ZeroCrossCounter.Candidate]
    {
        var counter = ZeroCrossCounter(configuration: configuration)
        var results: [ZeroCrossCounter.Candidate] = []
        for sample in samples {
            if let candidate = counter.observe(t: sample.t, x: sample.x, v: sample.v) {
                results.append(candidate)
            }
        }
        return results
    }

    // MARK: - Done-when: exact count on a clean cycle

    @Test("a synthetic 10-cycle sine yields exactly 10 candidates")
    func tenCycleSineYieldsTenCandidates() {
        let samples = Self.cosineSamples(cycles: 10, frequency: 1.0, sampleRate: 100.0)
        let candidates = Self.run(samples)
        #expect(candidates.count == 10)
    }

    @Test("each candidate is structurally a real peak-valley-peak, in order, with plausible amplitude")
    func candidateStructureIsSane() {
        let samples = Self.cosineSamples(cycles: 3, frequency: 1.0, sampleRate: 200.0)
        let candidates = Self.run(samples)
        #expect(candidates.count == 3)
        for candidate in candidates {
            #expect(candidate.startPeak.t < candidate.valley.t)
            #expect(candidate.valley.t < candidate.endPeak.t)
            #expect(candidate.valley.x < candidate.startPeak.x)
            #expect(candidate.valley.x < candidate.endPeak.x)
            #expect(abs(candidate.startPeak.x - 1.0) < 0.01)
            #expect(abs(candidate.endPeak.x - 1.0) < 0.01)
            #expect(abs(candidate.valley.x - (-1.0)) < 0.01)
        }
    }

    // MARK: - Done-when: the debounce

    @Test("a single-sample noise spike is debounced: 10 candidates with a merge threshold set, 11 without")
    func noiseSpikeIsDebounced() throws {
        var samples = Self.cosineSamples(cycles: 10, frequency: 1.0, sampleRate: 100.0)
        // Just past the first valley (t = 0.5), the ascent back toward the
        // next peak has barely started — a real single-frame glitch here
        // (velocity's estimated sign flipping for one sample without the
        // true position having reversed) swings only a fraction of a
        // percent away from the valley just committed, versus the ~2.0
        // peak-to-valley amplitude a real half-cycle swings.
        let spikeIndex = try #require(samples.firstIndex(where: { $0.t >= 0.53 }))
        samples[spikeIndex] = Sample(t: samples[spikeIndex].t, x: samples[spikeIndex].x, v: -samples[spikeIndex].v)

        let debounced = Self.run(samples, configuration: ZeroCrossCounter.Configuration(mergeThreshold: 0.05))
        #expect(debounced.count == 10)

        let undebounced = Self.run(samples, configuration: ZeroCrossCounter.Configuration(mergeThreshold: 0))
        #expect(undebounced.count == 11)
    }

    // MARK: - Done-when: abandoned reps don't count

    @Test("an abandoned half-cycle (reaches the valley, never returns to a peak) yields 0 candidates")
    func abandonedHalfCycleYieldsZero() {
        let full = Self.cosineSamples(cycles: 1, frequency: 1.0, sampleRate: 100.0)
        // Truncate well past the valley (t = 0.5) but well before the
        // next peak (t = 1.0) — SPEC §7.2: "A rep counts on the return to
        // the start position, never on reaching the bottom. An abandoned
        // rep is not a rep."
        let abandoned = full.filter { $0.t <= 0.6 }
        let candidates = Self.run(abandoned)
        #expect(candidates.isEmpty)
    }

    @Test("a partial ascent that never even reaches the first peak yields 0 candidates")
    func partialAscentYieldsZero() {
        let full = Self.cosineSamples(cycles: 1, frequency: 1.0, sampleRate: 100.0)
        let abandoned = full.filter { $0.t <= -0.05 }
        let candidates = Self.run(abandoned)
        #expect(candidates.isEmpty)
    }

    // MARK: - Speed neutrality (SPEC §7.2 rejects dwell-time gating)

    @Test("a sine at 2x speed still yields the right candidate count")
    func doubleSpeedSineYieldsCorrectCount() {
        let samples = Self.cosineSamples(cycles: 10, frequency: 2.0, sampleRate: 200.0)
        let candidates = Self.run(samples)
        #expect(candidates.count == 10)
    }

    @Test("a sine at 0.5x speed still yields the right candidate count")
    func halfSpeedSineYieldsCorrectCount() {
        let samples = Self.cosineSamples(cycles: 10, frequency: 0.5, sampleRate: 50.0)
        let candidates = Self.run(samples)
        #expect(candidates.count == 10)
    }

    // MARK: - Irregular spacing

    @Test("irregular sample spacing does not change the candidate count")
    func irregularSpacingDoesNotChangeCount() {
        let frequency = 1.0
        let period = 1.0 / frequency
        let lead = period / 4
        let end = 10 * period + lead
        var rng = LCG(state: 88_172_645_463_325_252)
        var samples: [Sample] = []
        var t = -lead
        while t <= end {
            let phase = 2 * Double.pi * frequency * t
            samples.append(Sample(t: t, x: cos(phase), v: -2 * Double.pi * frequency * sin(phase)))
            t += Double.random(in: 0.004...0.016, using: &rng)
        }
        let candidates = Self.run(samples)
        #expect(candidates.count == 10)
    }

    // MARK: - Flat signal

    @Test("a flat signal (zero velocity throughout) yields 0 candidates")
    func flatSignalYieldsZero() {
        let samples = (0..<500).map { i in Sample(t: Double(i) * 0.01, x: 1.234, v: 0) }
        let candidates = Self.run(samples)
        #expect(candidates.isEmpty)
    }

    @Test("a flat signal with velocity-only jitter does not emit a candidate from noise alone")
    func flatSignalWithJitterYieldsZero() {
        var rng = LCG(state: 1_234_567)
        let samples = (0..<500).map { i -> Sample in
            // The true position never moves; only the derivative's noise
            // flips sign — exactly the case `mergeThreshold` exists for.
            let jitter = Double.random(in: -0.02...0.02, using: &rng)
            return Sample(t: Double(i) * 0.01, x: 1.234, v: jitter)
        }
        let candidates = Self.run(samples, configuration: ZeroCrossCounter.Configuration(mergeThreshold: 0.001))
        #expect(candidates.isEmpty)
    }

    // MARK: - Determinism

    @Test("identical input yields identical output")
    func deterministic() {
        let samples = Self.cosineSamples(cycles: 10, frequency: 1.0, sampleRate: 100.0)
        let configuration = ZeroCrossCounter.Configuration(mergeThreshold: 0.02)
        let a = Self.run(samples, configuration: configuration)
        let b = Self.run(samples, configuration: configuration)
        #expect(a == b)
        #expect(a.count == 10)
    }

    // MARK: - Batch convenience matches streaming

    @Test("candidates(detrended:velocity:) matches sample-by-sample streaming use")
    func batchConvenienceMatchesStreaming() {
        let samples = Self.cosineSamples(cycles: 10, frequency: 1.0, sampleRate: 100.0)
        let detrended = samples.map { RepSignal.Sample(t: $0.t, x: $0.x, confidence: 1.0) }
        let velocity = samples.map { VelocitySample(t: $0.t, v: $0.v) }

        let batch = ZeroCrossCounter.candidates(detrended: detrended, velocity: velocity)
        let streaming = Self.run(samples)

        #expect(batch == streaming)
        #expect(batch.count == 10)
    }
}
