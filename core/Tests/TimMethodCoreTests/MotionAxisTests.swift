import CoreGraphics
import Foundation
import Testing

@testable import TimMethodCore

/// **All verification in this file is synthetic**, matching
/// `MetricScaleTests`' and `PlateTrackerTests`' precedent: hand-constructed
/// centroid traces standing in for a squat, a tilted-camera bench press, a
/// fatiguing set's forward drift, and tracking loss. Real-footage
/// confirmation is W2-06's job.
@Suite("MotionAxis")
struct MotionAxisTests {
    // MARK: - Helpers

    /// A point on a pure vertical (image-space) sinusoid: `x` fixed,
    /// `y` oscillating. Since this codebase's pixel/metres convention is
    /// y-down, "up" motion is *decreasing* y — subtracting the sine term
    /// (rather than adding it) is what makes positive `amplitude *
    /// sin(...)` correspond to upward motion, matching `RepSignal.Sample`
    /// 's "positive is away from the ground" convention.
    private static func verticalPoint(baseX: Double, baseY: Double, amplitude: Double, frequencyHz: Double, t: TimeInterval)
        -> CGPoint
    {
        CGPoint(x: baseX, y: baseY - amplitude * sin(2 * Double.pi * frequencyHz * t))
    }

    /// A point on a sinusoid along an axis tilted `tiltRadians` off pure
    /// vertical (0 = straight up/down, matching `verticalPoint`) —
    /// standing in for the same real motion filmed by a camera that isn't
    /// framing it dead-on.
    private static func tiltedPoint(
        base: CGPoint, amplitude: Double, frequencyHz: Double, tiltRadians: Double, t: TimeInterval
    ) -> CGPoint {
        let displacement = amplitude * sin(2 * Double.pi * frequencyHz * t)
        let axisX = sin(tiltRadians)
        let axisY = -cos(tiltRadians)
        return CGPoint(x: base.x + displacement * axisX, y: base.y + displacement * axisY)
    }

    private static func projection(_ result: MotionAxis.Result) -> MotionAxis.Projection? {
        if case .projected(let projection) = result { projection } else { nil }
    }

    // MARK: - Clean vertical sinusoid (a squat)

    @Test("a vertical quasi-sinusoidal centroid trace projects to a clean quasi-sinusoid matching the generating function")
    func verticalSquatProjectsCleanly() {
        var motionAxis = MotionAxis()
        let sampleRateHz = 60.0
        let frequencyHz = 0.5
        let amplitude = 0.30
        let durationSeconds = 12.0 // 6 full periods — several times the default window
        let sampleCount = Int(durationSeconds * sampleRateHz)

        var steadyState: [(t: Double, axial: Double)] = []
        let warmupCutoff = MotionAxis.defaultWindowDurationSeconds

        for i in 0..<sampleCount {
            let t = Double(i) / sampleRateHz
            let point = Self.verticalPoint(baseX: 0, baseY: 1.0, amplitude: amplitude, frequencyHz: frequencyHz, t: t)
            guard let projection = Self.projection(motionAxis.observe(.measured(pointMetres: point, confidence: 1.0), t: t))
            else { continue }
            if t >= warmupCutoff {
                steadyState.append((t: t, axial: projection.axial))
            }
        }

        #expect(steadyState.count > 100)
        for sample in steadyState {
            let expected = amplitude * sin(2 * Double.pi * frequencyHz * sample.t)
            #expect(abs(sample.axial - expected) < 0.02, "t=\(sample.t): got \(sample.axial), expected \(expected)")
        }
    }

    // MARK: - Same motion, filmed at an angle

    @Test("the same motion filmed at an angle recovers the same 1D signal shape, not a hardcoded-vertical projection")
    func tiltedCameraRecoversSameShape() {
        var motionAxis = MotionAxis()
        let sampleRateHz = 60.0
        let frequencyHz = 0.5
        let amplitude = 0.30
        let tilt = 25.0 * Double.pi / 180.0
        let durationSeconds = 12.0
        let sampleCount = Int(durationSeconds * sampleRateHz)

        var steadyState: [(t: Double, axial: Double)] = []
        let warmupCutoff = MotionAxis.defaultWindowDurationSeconds

        for i in 0..<sampleCount {
            let t = Double(i) / sampleRateHz
            let point = Self.tiltedPoint(
                base: CGPoint(x: 0.5, y: 1.0), amplitude: amplitude, frequencyHz: frequencyHz, tiltRadians: tilt, t: t
            )
            guard let projection = Self.projection(motionAxis.observe(.measured(pointMetres: point, confidence: 1.0), t: t))
            else { continue }
            if t >= warmupCutoff {
                steadyState.append((t: t, axial: projection.axial))
            }
        }

        #expect(steadyState.count > 100)

        // Recovered amplitude matches the *true* motion amplitude, not the
        // smaller vertical-only component a hardcoded-vertical-axis
        // implementation would recover instead.
        let peak = steadyState.map(\.axial).max() ?? 0
        let trough = steadyState.map(\.axial).min() ?? 0
        let recoveredAmplitude = (peak - trough) / 2
        #expect(abs(recoveredAmplitude - amplitude) < amplitude * 0.1)

        let hardcodedVerticalAmplitude = amplitude * cos(tilt)
        #expect(abs(recoveredAmplitude - hardcodedVerticalAmplitude) > amplitude * 0.03)

        for sample in steadyState {
            let expected = amplitude * sin(2 * Double.pi * frequencyHz * sample.t)
            #expect(abs(sample.axial - expected) < 0.03, "t=\(sample.t): got \(sample.axial), expected \(expected)")
        }
    }

    // MARK: - Sign: correct and stable

    @Test("upward motion produces increasing axial, and the sign never flips mid-set")
    func signIsCorrectAndStable() {
        var motionAxis = MotionAxis()
        let sampleRateHz = 60.0
        // A concentric-like rise, shorter than the default window so the
        // window never saturates (past saturation a constant-velocity
        // ramp's *relative-to-window-mean* projection plateaus by
        // construction — that's a separate, expected property of a
        // sliding-window baseline, not what this test is checking).
        let riseRatePerSecond = 0.10 // m/s upward
        let durationSeconds = 4.0
        let sampleCount = Int(durationSeconds * sampleRateHz)

        var axials: [Double] = []
        var axisDirections: [CGVector] = []
        for i in 0..<sampleCount {
            let t = Double(i) / sampleRateHz
            let point = CGPoint(x: 0, y: 1.0 - riseRatePerSecond * t)
            if let projection = Self.projection(motionAxis.observe(.measured(pointMetres: point, confidence: 1.0), t: t)) {
                axials.append(projection.axial)
            }
            if let direction = motionAxis.axisDirection {
                axisDirections.append(direction)
            }
        }

        #expect(axials.count > 10)
        for i in 1..<axials.count {
            #expect(axials[i] >= axials[i - 1] - 1e-9, "axial decreased during sustained upward motion at index \(i)")
        }

        // Never flips mid-set: consecutive resolved axis directions always
        // agree in sign (a flip shows up as a negative dot product).
        #expect(axisDirections.count > 10)
        for i in 1..<axisDirections.count {
            let dot = axisDirections[i].dx * axisDirections[i - 1].dx + axisDirections[i].dy * axisDirections[i - 1].dy
            #expect(dot >= 0, "axis direction flipped sign between consecutive frames at index \(i)")
        }
    }

    // MARK: - Stability under forward drift

    @Test("forward drift across a fatiguing set keeps the axis stable and the recovered amplitude from wandering")
    func stableUnderForwardDrift() {
        var motionAxis = MotionAxis()
        let sampleRateHz = 60.0
        let frequencyHz = 0.5
        let amplitude = 0.30
        let driftRatePerSecond = 0.0025 // slow horizontal creep, m/s
        let durationSeconds = 40.0 // several window-lengths, a whole "set"
        let sampleCount = Int(durationSeconds * sampleRateHz)

        var steadyState: [(t: Double, axial: Double)] = []
        var directionsAfterWarmup: [CGVector] = []
        let warmupCutoff = MotionAxis.defaultWindowDurationSeconds

        for i in 0..<sampleCount {
            let t = Double(i) / sampleRateHz
            let point = CGPoint(
                x: driftRatePerSecond * t,
                y: 1.0 - amplitude * sin(2 * Double.pi * frequencyHz * t)
            )
            guard let projection = Self.projection(motionAxis.observe(.measured(pointMetres: point, confidence: 1.0), t: t))
            else { continue }
            if t >= warmupCutoff {
                steadyState.append((t: t, axial: projection.axial))
                if let direction = motionAxis.axisDirection {
                    directionsAfterWarmup.append(direction)
                }
            }
        }
        #expect(steadyState.count > 100)

        // The axis tracks the drift *slowly*: it stays close to vertical
        // throughout (drift is small relative to the oscillation), not
        // rotating toward the drift direction.
        for direction in directionsAfterWarmup {
            let alignmentWithUp = direction.dx * 0 + direction.dy * (-1)
            #expect(alignmentWithUp > 0.9, "axis rotated away from vertical under drift: \(direction)")
        }

        // Amplitude doesn't wander: peak-to-peak amplitude measured in the
        // first third vs the last third of the steady-state run should be
        // close, despite the accumulated drift by the end.
        let third = steadyState.count / 3
        let firstChunk = steadyState.prefix(third).map(\.axial)
        let lastChunk = steadyState.suffix(third).map(\.axial)
        let firstAmplitude = ((firstChunk.max() ?? 0) - (firstChunk.min() ?? 0)) / 2
        let lastAmplitude = ((lastChunk.max() ?? 0) - (lastChunk.min() ?? 0)) / 2
        #expect(abs(firstAmplitude - lastAmplitude) < amplitude * 0.25)
        #expect(abs(firstAmplitude - amplitude) < amplitude * 0.25)
        #expect(abs(lastAmplitude - amplitude) < amplitude * 0.25)
    }

    // MARK: - Perpendicular component: bar deviation, excluded from axial

    @Test("the perpendicular component captures horizontal deviation and is excluded from the axial signal")
    func lateralCapturesDeviationAxialExcludesIt() {
        var motionAxis = MotionAxis()
        var signal = RepSignal(scale: .plateDiameter(mm: 450))
        let sampleRateHz = 60.0
        let verticalFrequencyHz = 0.5
        let verticalAmplitude = 0.30
        let lateralFrequencyHz = 1.7 // distinct from the vertical frequency
        let lateralAmplitude = 0.02 // small relative to the vertical motion
        let durationSeconds = 12.0
        let sampleCount = Int(durationSeconds * sampleRateHz)

        var steadyState: [(t: Double, axial: Double, lateral: Double)] = []
        let warmupCutoff = MotionAxis.defaultWindowDurationSeconds

        for i in 0..<sampleCount {
            let t = Double(i) / sampleRateHz
            let point = CGPoint(
                x: lateralAmplitude * sin(2 * Double.pi * lateralFrequencyHz * t),
                y: 1.0 - verticalAmplitude * sin(2 * Double.pi * verticalFrequencyHz * t)
            )
            let result = motionAxis.observe(.measured(pointMetres: point, confidence: 1.0), t: t)
            signal.append(result)
            guard let projection = Self.projection(result) else { continue }
            if t >= warmupCutoff {
                steadyState.append((t: t, axial: projection.axial, lateral: projection.lateral))
            }
        }

        #expect(steadyState.count > 100)

        // lateral recovers the horizontal deviation's amplitude...
        let lateralPeak = steadyState.map(\.lateral).max() ?? 0
        let lateralTrough = steadyState.map(\.lateral).min() ?? 0
        let recoveredLateralAmplitude = (lateralPeak - lateralTrough) / 2
        #expect(abs(recoveredLateralAmplitude - lateralAmplitude) < lateralAmplitude * 0.4)

        // ...while axial stays close to the pure vertical generating
        // function, largely uncontaminated by the lateral oscillation.
        for sample in steadyState {
            let expected = verticalAmplitude * sin(2 * Double.pi * verticalFrequencyHz * sample.t)
            #expect(abs(sample.axial - expected) < 0.03)
        }

        // And structurally: every sample actually appended to RepSignal
        // carries the axial value, never the lateral one.
        #expect(signal.samples.count > 0)
        for i in 0..<signal.samples.count {
            let sample = signal.samples[i]
            let matchingProjection = steadyState.first { abs($0.t - sample.t) < 1e-9 }
            if let matchingProjection {
                #expect(abs(sample.x - matchingProjection.axial) < 1e-9)
                #expect(abs(sample.x - matchingProjection.lateral) > 1e-9)
            }
        }
    }

    // MARK: - Honest gaps and confidence

    @Test("lost frames leave a gap rather than a zero; interpolated frames carry lower confidence than measured")
    func lostIsGapInterpolatedCarriesLowerConfidence() {
        var motionAxis = MotionAxis()
        var signal = RepSignal(scale: .plateDiameter(mm: 450))

        // Warm the window with real measurements so a real axis exists.
        for i in 0..<20 {
            let t = Double(i) / 60.0
            let point = CGPoint(x: 0, y: 1.0 - 0.01 * Double(i))
            let result = motionAxis.observe(.measured(pointMetres: point, confidence: 0.95), t: t)
            signal.append(result)
        }
        let countBeforeLoss = signal.samples.count

        // A lost frame: a gap, never a fabricated zero.
        let lostResult = motionAxis.observe(.lost, t: 20.0 / 60.0)
        #expect(lostResult == .gap)
        signal.append(lostResult)
        #expect(signal.samples.count == countBeforeLoss)

        // A real measurement, high confidence.
        let measuredResult = motionAxis.observe(.measured(pointMetres: CGPoint(x: 0, y: 0.79), confidence: 0.9), t: 21.0 / 60.0)
        guard let measuredProjection = Self.projection(measuredResult) else {
            Issue.record("expected a projected sample from a measured observation")
            return
        }
        #expect(abs(measuredProjection.confidence - 0.9) < 1e-9)

        // A bridged/interpolated frame at roughly the same place, with a
        // lower, already-decayed confidence (matching what `PlateTracker
        // .TrackedObservation.confidence` would carry).
        let interpolatedResult = motionAxis.observe(
            .interpolated(pointMetres: CGPoint(x: 0, y: 0.788), confidence: 0.3), t: 22.0 / 60.0
        )
        guard let interpolatedProjection = Self.projection(interpolatedResult) else {
            Issue.record("expected a projected sample from an interpolated observation")
            return
        }
        #expect(abs(interpolatedProjection.confidence - 0.3) < 1e-9)
        #expect(interpolatedProjection.confidence < measuredProjection.confidence)
    }

    // MARK: - Degenerate input

    @Test("fewer points than the window, and a stationary plate, are both handled without crashing or producing garbage")
    func degenerateInputsHandledSafely() {
        // Fewer points than the window: the very first observation ever
        // has nothing to fit against yet.
        var motionAxis = MotionAxis()
        let first = motionAxis.observe(.measured(pointMetres: CGPoint(x: 0, y: 1), confidence: 1.0), t: 0)
        #expect(first == .gap)

        // Exactly two points: enough for a degenerate but well-defined
        // line — must produce finite output, not crash.
        let second = motionAxis.observe(.measured(pointMetres: CGPoint(x: 0, y: 0.99), confidence: 1.0), t: 1.0 / 60.0)
        guard let secondProjection = Self.projection(second) else {
            Issue.record("expected a projected sample once two points exist")
            return
        }
        #expect(secondProjection.axial.isFinite)
        #expect(secondProjection.lateral.isFinite)
        #expect(secondProjection.confidence.isFinite)

        // A perfectly stationary plate: identical point every frame. No
        // dominant direction exists; must not crash or emit NaN/garbage.
        var stationaryAxis = MotionAxis()
        let fixedPoint = CGPoint(x: 0.3, y: 0.6)
        for i in 0..<120 {
            let t = Double(i) / 60.0
            let result = stationaryAxis.observe(.measured(pointMetres: fixedPoint, confidence: 1.0), t: t)
            switch result {
            case .projected(let projection):
                #expect(projection.axial.isFinite)
                #expect(projection.lateral.isFinite)
                #expect(abs(projection.axial) < 1e-6)
                #expect(abs(projection.lateral) < 1e-6)
            case .gap:
                #expect(i == 0, "only the very first frame should ever be a gap")
            }
        }
        #expect(stationaryAxis.axisDirection != nil)
        #expect(stationaryAxis.axisDirection?.dx.isFinite == true)
        #expect(stationaryAxis.axisDirection?.dy.isFinite == true)
    }
}
