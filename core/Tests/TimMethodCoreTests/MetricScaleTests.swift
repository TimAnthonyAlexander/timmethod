import Foundation
import Testing

@testable import TimMethodCore

/// **All verification in this file is synthetic.** `MetricScale`'s two
/// task-level "Done when" items — "a clip with a known subject distance
/// recovers that distance to within 5%" and "scale remains stable across a
/// set where the lifter shifts position" — are exercised here against
/// hand-constructed `majorAxisPx` sequences, never against real footage.
/// Real-footage confirmation is out of scope for this file: it is W2-06's
/// job, once W1-06 (the fixture clip corpus) exists.
@Suite("MetricScale")
struct MetricScaleTests {
    // MARK: - Helpers

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        let m = mean(values)
        let variance = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count)
        return variance.squareRoot()
    }

    private static func acceptedEstimate(_ result: MetricScale.Result) -> MetricScale.Estimate? {
        if case .accepted(let estimate) = result { estimate } else { nil }
    }

    // MARK: - Arithmetic against hand-computed numbers

    @Test("metresPerPixel matches PlateScale.metresPerPixel for a single observation")
    func arithmeticMatchesHandComputedNumber() {
        // 450 mm / 300 px = 0.0015 m/px, hand-computed.
        var scale = MetricScale(configuration: .olympicOrBumper)
        let result = scale.observe(majorAxisPx: 300)
        guard let estimate = Self.acceptedEstimate(result) else {
            Issue.record("expected an accepted estimate, got \(result)")
            return
        }
        #expect(abs(estimate.rawMetresPerPixel - 0.0015) < 1e-12)
        // First observation: the window holds exactly one sample, so the
        // smoothed value equals the raw one.
        #expect(abs(estimate.metresPerPixel - 0.0015) < 1e-12)
    }

    @Test("doubling the observed major axis halves metres-per-pixel")
    func doublingMajorAxisHalvesScale() {
        var narrow = MetricScale(configuration: .olympicOrBumper)
        var wide = MetricScale(configuration: .olympicOrBumper)

        guard let narrowEstimate = Self.acceptedEstimate(narrow.observe(majorAxisPx: 200)),
            let wideEstimate = Self.acceptedEstimate(wide.observe(majorAxisPx: 400))
        else {
            Issue.record("expected both observations to be accepted")
            return
        }

        #expect(abs(wideEstimate.rawMetresPerPixel - narrowEstimate.rawMetresPerPixel / 2) < 1e-12)
    }

    @Test("an accepted estimate always carries .plateDiameter, never another ScaleSource")
    func emitsPlateDiameterScaleSource() {
        var scale = MetricScale(configuration: .standardOneInch(.medium))
        guard let estimate = Self.acceptedEstimate(scale.observe(majorAxisPx: 250)) else {
            Issue.record("expected an accepted estimate")
            return
        }
        #expect(estimate.scaleSource == .plateDiameter(mm: PlateConfiguration.StandardOneInch.medium.millimetres))
    }

    // MARK: - Recomputed every frame, not cached

    @Test("a smoothly approaching subject keeps the recovered diameter constant while metres-per-pixel tracks the change")
    func approachingSubjectKeepsDiameterConstantAndTracksScale() {
        var scale = MetricScale(configuration: .olympicOrBumper)
        let diameterMetres = PlateConfiguration.olympicOrBumper.millimetres / 1000.0

        var smoothedSequence: [Double] = []
        // A linear ramp: the "lifter" walks steadily toward the camera, so
        // the plate's projected major axis grows frame by frame. Range
        // chosen so every frame's implied distance stays inside the
        // default 0.5–8 m sanity bounds (checked below).
        for majorAxisPx in stride(from: 200.0, through: 500.0, by: 5.0) {
            guard let estimate = Self.acceptedEstimate(scale.observe(majorAxisPx: majorAxisPx)) else {
                Issue.record("frame at majorAxisPx=\(majorAxisPx) was unexpectedly rejected")
                continue
            }
            // Recomputed fresh every frame from the raw measurement: the
            // implied real diameter is exactly the configured one, at
            // every single frame, not just the first — this is the
            // property a one-time-cached scale would not have.
            #expect(abs(estimate.rawMetresPerPixel * majorAxisPx - diameterMetres) < 1e-9)
            smoothedSequence.append(estimate.metresPerPixel)
        }

        // metres-per-pixel tracks the approach: strictly decreasing as the
        // major axis grows (moving average of a strictly decreasing
        // sequence is itself strictly decreasing).
        for i in 1..<smoothedSequence.count {
            #expect(smoothedSequence[i] < smoothedSequence[i - 1])
        }
    }

    // MARK: - Smoothing: reduces jitter, preserves the mean

    @Test("smoothing reduces jitter on a noisy input without introducing a bias")
    func smoothingReducesJitterWithoutBias() {
        var scale = MetricScale(configuration: .olympicOrBumper)
        let baseMajorAxisPx = 300.0
        let noisePx = 3.0
        let frameCount = 200

        var rawSequence: [Double] = []
        var smoothedSequence: [Double] = []
        for i in 0..<frameCount {
            // Deterministic, zero-sum-over-any-even-run alternating noise —
            // no RNG, so the test is exactly reproducible — applied to an
            // otherwise-constant major axis, standing in for per-frame
            // ellipse-fit jitter around a lifter who isn't actually moving.
            let noisy = baseMajorAxisPx + (i.isMultiple(of: 2) ? noisePx : -noisePx)
            guard let estimate = Self.acceptedEstimate(scale.observe(majorAxisPx: noisy)) else {
                Issue.record("frame \(i) was unexpectedly rejected")
                continue
            }
            rawSequence.append(estimate.rawMetresPerPixel)
            smoothedSequence.append(estimate.metresPerPixel)
        }

        let rawMean = Self.mean(rawSequence)
        let smoothedMean = Self.mean(smoothedSequence)
        let rawStdDev = Self.standardDeviation(rawSequence)
        let smoothedStdDev = Self.standardDeviation(smoothedSequence)

        // No bias: smoothing shifts the mean by well under 1%.
        #expect(abs(smoothedMean - rawMean) / rawMean < 0.01)
        // Jitter is meaningfully damped, not just marginally: smoothed
        // variation is under a third of the raw variation.
        #expect(smoothedStdDev < rawStdDev * 0.34)
    }

    // MARK: - Sanity bounds: reject, don't clamp

    @Test("a scale implying the subject is nearer than 0.5 m is rejected as .tooNear, not clamped")
    func rejectsTooNear() {
        var scale = MetricScale(configuration: .olympicOrBumper)
        // 450 mm / 2000 px implies well under 0.5 m at the default focal length.
        let result = scale.observe(majorAxisPx: 2000)
        guard case .rejected(let reason) = result else {
            Issue.record("expected a rejection, got \(result)")
            return
        }
        guard case .tooNear(let impliedDistanceMetres, let minimumMetres) = reason else {
            Issue.record("expected .tooNear, got \(reason)")
            return
        }
        #expect(minimumMetres == 0.5)
        #expect(impliedDistanceMetres < minimumMetres)
    }

    @Test("a scale implying the subject is further than 8 m is rejected as .tooFar, not clamped")
    func rejectsTooFar() {
        var scale = MetricScale(configuration: .olympicOrBumper)
        // 450 mm / 50 px implies well over 8 m at the default focal length.
        let result = scale.observe(majorAxisPx: 50)
        guard case .rejected(let reason) = result else {
            Issue.record("expected a rejection, got \(result)")
            return
        }
        guard case .tooFar(let impliedDistanceMetres, let maximumMetres) = reason else {
            Issue.record("expected .tooFar, got \(reason)")
            return
        }
        #expect(maximumMetres == 8.0)
        #expect(impliedDistanceMetres > maximumMetres)
    }

    @Test("a non-positive or non-finite major axis is rejected as .invalidMajorAxis")
    func rejectsInvalidMajorAxis() {
        var scale = MetricScale(configuration: .olympicOrBumper)
        for bad in [0.0, -5.0, Double.nan, Double.infinity] {
            let result = scale.observe(majorAxisPx: bad)
            guard case .rejected(.invalidMajorAxis(let majorAxisPx)) = result else {
                Issue.record("expected .invalidMajorAxis for \(bad), got \(result)")
                continue
            }
            if bad.isNaN {
                #expect(majorAxisPx.isNaN)
            } else {
                #expect(majorAxisPx == bad)
            }
        }
    }

    @Test("a rejected frame is never mixed into the smoothing window")
    func rejectedFrameDoesNotPolluteWindow() {
        var scale = MetricScale(configuration: .olympicOrBumper, windowSize: 3)

        // Fill the (capacity-3) window with three identical, in-bounds
        // observations.
        scale.observe(majorAxisPx: 300) // r1 = 0.0015
        scale.observe(majorAxisPx: 300)
        guard let filled = Self.acceptedEstimate(scale.observe(majorAxisPx: 300)) else {
            Issue.record("expected the third fill observation to be accepted")
            return
        }
        #expect(abs(filled.metresPerPixel - 0.0015) < 1e-12)

        // A too-near frame: rejected. If it were pushed into the window
        // anyway, it would evict one of the three r1 samples above before
        // the next accepted frame arrives, changing the result below.
        let rejection = scale.observe(majorAxisPx: 2000)
        guard case .rejected = rejection else {
            Issue.record("expected the pollution attempt to be rejected")
            return
        }

        // One new, different, in-bounds observation. If the rejected frame
        // had been pushed, the window would now be [r1, rBad, r2] and the
        // average would differ from the value asserted below. Since it
        // wasn't pushed, the window is still [r1, r1] before this append,
        // so afterward it is exactly [r1, r1, r2].
        guard let next = Self.acceptedEstimate(scale.observe(majorAxisPx: 200)) else {
            Issue.record("expected the post-rejection observation to be accepted")
            return
        }
        let r1 = 0.0015
        let r2 = 0.00225 // 450 mm / 200 px
        let expected = (r1 + r1 + r2) / 3
        #expect(abs(next.metresPerPixel - expected) < 1e-9)
    }

    // MARK: - Done-when (synthetic): known-distance recovery

    @Test(
        """
        Done-when, verified synthetically: an observation implying a known \
        subject distance recovers that distance to within 5%. Real-footage \
        confirmation is W2-06's job once W1-06 exists.
        """
    )
    func recoversKnownDistanceSynthetically() {
        let configuration = PlateConfiguration.standardOneInch(.large) // 254.0 mm
        let diameterMetres = configuration.millimetres / 1000.0
        let focalLengthPx = MetricScale.defaultFocalLengthPx
        let targetDistanceMetres = 3.0

        // Invert distance = focalLengthPx * (diameterMetres / majorAxisPx).
        let majorAxisPx = focalLengthPx * diameterMetres / targetDistanceMetres

        var scale = MetricScale(configuration: configuration)
        var lastEstimate: MetricScale.Estimate?
        // Feed it several times (more than the default window) so the
        // recovered value reflects the steady-state smoothed estimate, the
        // way a real per-frame stream would.
        for _ in 0..<(MetricScale.defaultWindowSize + 5) {
            lastEstimate = Self.acceptedEstimate(scale.observe(majorAxisPx: majorAxisPx))
        }

        guard let estimate = lastEstimate else {
            Issue.record("expected the known-distance observation to be accepted")
            return
        }
        let relativeError = abs(estimate.impliedDistanceMetres - targetDistanceMetres) / targetDistanceMetres
        #expect(relativeError < 0.05)
    }

    // MARK: - Done-when (synthetic): stability while the lifter shifts

    @Test(
        """
        Done-when, verified synthetically: scale remains stable across a \
        set where the lifter shifts position. Real-footage confirmation is \
        W2-06's job once W1-06 exists.
        """
    )
    func stableAcrossSimulatedPositionShifts() {
        var scale = MetricScale(configuration: .olympicOrBumper)
        let baseMajorAxisPx = 300.0

        var smoothedValues: [Double] = []
        // Small sinusoidal wobble in the projected major axis, standing in
        // for a lifter shifting stance/position slightly between reps —
        // not a sustained approach/retreat, just noise around a fixed
        // working distance.
        for i in 0..<300 {
            let wobble = 6.0 * sin(Double(i) * 0.3)
            guard let estimate = Self.acceptedEstimate(scale.observe(majorAxisPx: baseMajorAxisPx + wobble)) else {
                Issue.record("frame \(i) was unexpectedly rejected")
                continue
            }
            smoothedValues.append(estimate.metresPerPixel)
        }

        // Ignore the initial window fill-up (its average is over fewer
        // samples and swings more) and check steady-state stability.
        let steadyState = Array(smoothedValues.dropFirst(MetricScale.defaultWindowSize))
        let m = Self.mean(steadyState)
        let maxDeviation = steadyState.map { abs($0 - m) / m }.max() ?? 0
        #expect(maxDeviation < 0.05)
    }
}
