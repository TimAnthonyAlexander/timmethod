import CoreGraphics
import Testing

@testable import TimMethodCore

/// Tests the maths in isolation: clean, analytically-generated ellipse
/// boundary points in, recovered ellipse parameters out. `PlateDetectorTests`
/// covers the same headline claims through the real pixel-buffer pipeline;
/// this file is what makes a failure there debuggable — if both fail, the
/// bug is in the fit; if only the pipeline test fails, the bug is upstream
/// of it (contour extraction, coordinate conversion, gating).
@Suite("EllipseFit")
struct EllipseFitTests {

    /// Samples `count` points evenly in parametric angle around an ellipse
    /// of full axes `majorAxis` x `minorAxis`, centred at `center`, with
    /// in-plane rotation `rotation` (radians) — the exact inverse of what
    /// `EllipseFit.fit` is trying to recover, so a clean sweep here
    /// isolates the fit's own accuracy from any rendering/detection noise.
    static func points(
        center: CGPoint, majorAxis: Double, minorAxis: Double, rotation: Double, count: Int = 64
    ) -> [CGPoint] {
        let a = majorAxis / 2
        let b = minorAxis / 2
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        return (0..<count).map { i in
            let t = 2 * Double.pi * Double(i) / Double(count)
            let x0 = a * cos(t)
            let y0 = b * sin(t)
            let x = x0 * cosR - y0 * sinR + Double(center.x)
            let y = x0 * sinR + y0 * cosR + Double(center.y)
            return CGPoint(x: x, y: y)
        }
    }

    /// A small deterministic pseudo-random generator (xorshift32), seeded
    /// fixed, so the noisy-degradation test is reproducible run to run —
    /// no dependency on `SystemRandomNumberGenerator`'s non-reproducible
    /// seeding.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    // MARK: - Headline requirement: angle sweep

    @Test(
        "recovers major axis within 1% across a sweep of viewing angles and in-plane rotations",
        arguments: [0.0, 15.0, 30.0, 45.0, 60.0, 70.0], [0.0, 30.0, 47.0, 90.0, 133.0]
    )
    func recoversMajorAxisAcrossAngleSweep(viewingAngleDegrees: Double, inPlaneRotationDegrees: Double) throws {
        let trueMajorAxis = 300.0
        let viewingAngle = viewingAngleDegrees * .pi / 180
        let minorAxis = trueMajorAxis * cos(viewingAngle)
        let rotation = inPlaneRotationDegrees * .pi / 180
        let center = CGPoint(x: 512, y: 384)

        let samples = Self.points(center: center, majorAxis: trueMajorAxis, minorAxis: minorAxis, rotation: rotation)
        let ellipse = try #require(EllipseFit.fit(points: samples))

        let relativeError = abs(ellipse.majorAxis - trueMajorAxis) / trueMajorAxis
        #expect(
            relativeError < 0.01,
            """
            viewingAngle=\(viewingAngleDegrees)°, rotation=\(inPlaneRotationDegrees)°: \
            recovered majorAxis \(ellipse.majorAxis), expected \(trueMajorAxis), relError \(relativeError)
            """
        )
    }

    // MARK: - Perpendicular view (circle)

    @Test("recovers diameter within 1% for a perpendicular (circular) view")
    func recoversCircleDiameter() throws {
        let trueDiameter = 220.0
        let center = CGPoint(x: 100, y: 150)
        let samples = Self.points(center: center, majorAxis: trueDiameter, minorAxis: trueDiameter, rotation: 0)

        let ellipse = try #require(EllipseFit.fit(points: samples))

        #expect(abs(ellipse.majorAxis - trueDiameter) / trueDiameter < 0.01)
        #expect(abs(ellipse.minorAxis - trueDiameter) / trueDiameter < 0.01)
        #expect(abs(ellipse.center.x - center.x) < 1)
        #expect(abs(ellipse.center.y - center.y) < 1)
    }

    // MARK: - Graceful degradation on noisy points

    @Test("degrades gracefully on noisy edge points instead of producing a wild conic")
    func degradesGracefullyOnNoise() throws {
        let trueMajorAxis = 300.0
        let trueMinorAxis = 220.0
        let center = CGPoint(x: 400, y: 300)
        let clean = Self.points(center: center, majorAxis: trueMajorAxis, minorAxis: trueMinorAxis, rotation: 0.4)

        var rng = SeededGenerator(seed: 42)
        // Jitter each point by up to ±4% of the major axis — enough to be a
        // meaningfully noisy edge detection, not enough to destroy the
        // ellipse's basic shape.
        let jitterMagnitude = trueMajorAxis * 0.04
        let noisy = clean.map { point -> CGPoint in
            let dx = Double.random(in: -jitterMagnitude...jitterMagnitude, using: &rng)
            let dy = Double.random(in: -jitterMagnitude...jitterMagnitude, using: &rng)
            return CGPoint(x: Double(point.x) + dx, y: Double(point.y) + dy)
        }

        let ellipse = try #require(EllipseFit.fit(points: noisy))

        // "Graceful" means: still recognisably the same ellipse (loose
        // bound, since points were perturbed), not a wild/degenerate conic
        // (e.g. a near-zero or runaway axis).
        let relativeError = abs(ellipse.majorAxis - trueMajorAxis) / trueMajorAxis
        #expect(relativeError < 0.15, "noisy fit majorAxis \(ellipse.majorAxis) vs true \(trueMajorAxis)")
        #expect(ellipse.majorAxis.isFinite && ellipse.majorAxis > 0)
        #expect(ellipse.minorAxis.isFinite && ellipse.minorAxis > 0)
        #expect(ellipse.majorAxis < trueMajorAxis * 3, "fit should not blow up under noise")

        // The noisy fit's own residual should read as noisier than a clean
        // fit of the same shape — the confidence signal `PlateDetector`
        // derives from this is meaningful, not constant.
        let cleanEllipse = try #require(EllipseFit.fit(points: clean))
        #expect(ellipse.normalizedResidual > cleanEllipse.normalizedResidual)
    }

    @Test("degenerate input (too few points) returns nil rather than a fabricated ellipse")
    func tooFewPointsReturnsNil() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)]
        #expect(EllipseFit.fit(points: points) == nil)
    }

    @Test("degenerate input (collinear points) returns nil rather than a fabricated ellipse")
    func collinearPointsReturnsNil() {
        let points = (0..<20).map { CGPoint(x: Double($0) * 10, y: Double($0) * 10) }
        #expect(EllipseFit.fit(points: points) == nil)
    }

    @Test("degenerate input (coincident points) returns nil")
    func coincidentPointsReturnsNil() {
        let points = Array(repeating: CGPoint(x: 42, y: 42), count: 20)
        #expect(EllipseFit.fit(points: points) == nil)
    }

    @Test("recovers orientation for a known in-plane rotation")
    func recoversOrientation() throws {
        let center = CGPoint(x: 50, y: 60)
        let rotation = 37.0 * .pi / 180
        let samples = Self.points(center: center, majorAxis: 200, minorAxis: 120, rotation: rotation)
        let ellipse = try #require(EllipseFit.fit(points: samples))

        // Orientation is a line direction (wrapped to [0, .pi)); compare
        // modulo .pi with a small tolerance.
        let expected = rotation.truncatingRemainder(dividingBy: .pi)
        let diff = abs(ellipse.orientation - expected)
        let wrapped = min(diff, abs(diff - .pi))
        #expect(wrapped < 0.02, "expected orientation \(expected), got \(ellipse.orientation)")
    }
}
