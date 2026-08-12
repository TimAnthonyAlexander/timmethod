import CoreGraphics
import CoreVideo
import Foundation
import Testing

@testable import TimMethodCore

/// Exercises `PlateDetector`'s real pipeline — edge/gradient pass, Vision
/// contour extraction, coordinate conversion, `EllipseFit`, the radius and
/// eccentricity gates, and multi-candidate resolution — through actual
/// `CVPixelBuffer`s (`SyntheticPlateFrame`), not just the maths in
/// isolation (`EllipseFitTests` covers that). This is what proves the
/// wiring between those pieces, not only each piece alone.
@Suite("PlateDetector")
struct PlateDetectorTests {
    static let frameWidth = 640
    static let frameHeight = 480

    static func makeConfiguration(radius: Double, tolerance: Double = 0.35) -> PlateDetector.Configuration {
        PlateDetector.Configuration(
            minRadiusPx: radius * (1 - tolerance),
            maxRadiusPx: radius * (1 + tolerance)
        )
    }

    // MARK: - Headline requirement: angle sweep, real pipeline

    @Test(
        "recovers major axis within 1% across a sweep of viewing angles, through the real pixel-buffer pipeline",
        arguments: [0.0, 15.0, 30.0, 45.0, 60.0]
    )
    func recoversMajorAxisAcrossAngleSweepThroughPipeline(viewingAngleDegrees: Double) throws {
        let trueMajorAxis = 220.0
        let viewingAngle = viewingAngleDegrees * .pi / 180
        let minorAxis = trueMajorAxis * cos(viewingAngle)
        let center = CGPoint(x: Double(Self.frameWidth) / 2, y: Double(Self.frameHeight) / 2)

        let ellipse = SyntheticPlateFrame.Ellipse(
            center: center, majorAxis: trueMajorAxis, minorAxis: minorAxis, rotation: 0.3
        )
        let buffer = SyntheticPlateFrame.render(width: Self.frameWidth, height: Self.frameHeight, ellipses: [ellipse])

        let detector = PlateDetector(configuration: Self.makeConfiguration(radius: trueMajorAxis / 2))
        let observation = try #require(detector.detect(in: buffer))

        let relativeError = abs(observation.majorAxisPx - trueMajorAxis) / trueMajorAxis
        #expect(
            relativeError < 0.01,
            "viewingAngle=\(viewingAngleDegrees)°: got majorAxisPx \(observation.majorAxisPx), expected \(trueMajorAxis)"
        )
    }

    // MARK: - Perpendicular view (circle)

    @Test("recovers diameter within 1% for a perpendicular (circular) plate")
    func recoversCircleDiameterThroughPipeline() throws {
        let trueDiameter = 200.0
        let center = CGPoint(x: 300, y: 220)
        let ellipse = SyntheticPlateFrame.Ellipse(center: center, majorAxis: trueDiameter, minorAxis: trueDiameter)
        let buffer = SyntheticPlateFrame.render(width: Self.frameWidth, height: Self.frameHeight, ellipses: [ellipse])

        let detector = PlateDetector(configuration: Self.makeConfiguration(radius: trueDiameter / 2))
        let observation = try #require(detector.detect(in: buffer))

        #expect(abs(observation.majorAxisPx - trueDiameter) / trueDiameter < 0.01)
        #expect(abs(observation.minorAxisPx - trueDiameter) / trueDiameter < 0.01)
        #expect(abs(observation.center.x - center.x) < 2)
        #expect(abs(observation.center.y - center.y) < 2)
        #expect(observation.confidence > 0.5)
    }

    // MARK: - No plate in frame

    @Test("a frame with no plate returns nil")
    func noPlateReturnsNil() {
        let buffer = SyntheticPlateFrame.render(width: Self.frameWidth, height: Self.frameHeight, ellipses: [])
        let detector = PlateDetector(configuration: Self.makeConfiguration(radius: 100))
        #expect(detector.detect(in: buffer) == nil)
    }

    @Test("a plate present but outside the configured radius range returns nil")
    func plateOutsideRadiusRangeReturnsNil() {
        let center = CGPoint(x: 300, y: 220)
        let ellipse = SyntheticPlateFrame.Ellipse(center: center, majorAxis: 40, minorAxis: 40)
        let buffer = SyntheticPlateFrame.render(width: Self.frameWidth, height: Self.frameHeight, ellipses: [ellipse])

        // Configuration expects a plate 5-10x larger than what's drawn.
        let detector = PlateDetector(
            configuration: PlateDetector.Configuration(minRadiusPx: 150, maxRadiusPx: 300)
        )
        #expect(detector.detect(in: buffer) == nil)
    }

    // MARK: - Impossible eccentricity

    @Test("rejects a fit whose eccentricity implies an impossible camera angle")
    func rejectsImpossibleEccentricity() {
        let trueMajorAxis = 220.0
        // cos(85°) ≈ 0.087 — well past the default 75° cutoff
        // (cos(75°) ≈ 0.259). A real plate viewed this obliquely is not a
        // plausible workout-video framing (see `PlateDetector
        // .defaultMaxOffPlaneAngleDegrees`).
        let extremeAngle = 85.0 * .pi / 180
        let minorAxis = trueMajorAxis * cos(extremeAngle)
        let center = CGPoint(x: 300, y: 220)
        let ellipse = SyntheticPlateFrame.Ellipse(center: center, majorAxis: trueMajorAxis, minorAxis: minorAxis)
        let buffer = SyntheticPlateFrame.render(width: Self.frameWidth, height: Self.frameHeight, ellipses: [ellipse])

        let detector = PlateDetector(configuration: Self.makeConfiguration(radius: trueMajorAxis / 2))
        #expect(detector.detect(in: buffer) == nil)
    }

    @Test("accepts a fit just inside the eccentricity cutoff")
    func acceptsEccentricityJustInsideCutoff() throws {
        let trueMajorAxis = 220.0
        // Comfortably inside the default 75° cutoff.
        let angle = 60.0 * .pi / 180
        let minorAxis = trueMajorAxis * cos(angle)
        let center = CGPoint(x: 300, y: 220)
        let ellipse = SyntheticPlateFrame.Ellipse(center: center, majorAxis: trueMajorAxis, minorAxis: minorAxis)
        let buffer = SyntheticPlateFrame.render(width: Self.frameWidth, height: Self.frameHeight, ellipses: [ellipse])

        let detector = PlateDetector(configuration: Self.makeConfiguration(radius: trueMajorAxis / 2))
        #expect(detector.detect(in: buffer) != nil)
    }

    // MARK: - Two plates in frame: deterministic resolution

    @Test("resolves two plates in frame to one pick, deterministically across repeated runs")
    func twoPlatesResolveDeterministically() throws {
        // Both ends of a dumbbell: two same-size plates, well separated.
        let majorAxis = 150.0
        let left = SyntheticPlateFrame.Ellipse(
            center: CGPoint(x: 160, y: 240), majorAxis: majorAxis, minorAxis: majorAxis
        )
        let right = SyntheticPlateFrame.Ellipse(
            center: CGPoint(x: 480, y: 240), majorAxis: majorAxis, minorAxis: majorAxis
        )
        let buffer = SyntheticPlateFrame.render(
            width: Self.frameWidth, height: Self.frameHeight, ellipses: [left, right])

        let detector = PlateDetector(configuration: Self.makeConfiguration(radius: majorAxis / 2))

        let results = (0..<10).map { _ in detector.detect(in: buffer) }
        let first = try #require(results.first ?? nil)
        for result in results {
            #expect(result == first, "repeated detect() calls on identical input must return the identical pick")
        }
    }

    @Test("two differently-sized plates: the one closer to the configured size wins")
    func twoPlatesSizePlausibilityBreaksTie() throws {
        let expectedMajorAxis = 200.0
        let matching = SyntheticPlateFrame.Ellipse(
            center: CGPoint(x: 160, y: 240), majorAxis: expectedMajorAxis, minorAxis: expectedMajorAxis
        )
        // Present, but far smaller than the configured range's centre —
        // still inside the (wide) configured range, so it survives gating,
        // but should lose to `matching` on size plausibility.
        let offSize = SyntheticPlateFrame.Ellipse(
            center: CGPoint(x: 480, y: 240), majorAxis: expectedMajorAxis * 0.6, minorAxis: expectedMajorAxis * 0.6
        )
        let buffer = SyntheticPlateFrame.render(
            width: Self.frameWidth, height: Self.frameHeight, ellipses: [matching, offSize]
        )

        let configuration = PlateDetector.Configuration(
            minRadiusPx: expectedMajorAxis / 2 * 0.5, maxRadiusPx: expectedMajorAxis / 2 * 1.5
        )
        let detector = PlateDetector(configuration: configuration)
        let observation = try #require(detector.detect(in: buffer))

        #expect(abs(observation.center.x - matching.center.x) < 5)
    }

    @Test("two identically-scored plates: previous-centre proximity breaks the tie")
    func previousCenterBreaksSizeTie() throws {
        let majorAxis = 150.0
        let left = SyntheticPlateFrame.Ellipse(
            center: CGPoint(x: 160, y: 240), majorAxis: majorAxis, minorAxis: majorAxis
        )
        let right = SyntheticPlateFrame.Ellipse(
            center: CGPoint(x: 480, y: 240), majorAxis: majorAxis, minorAxis: majorAxis
        )
        let buffer = SyntheticPlateFrame.render(
            width: Self.frameWidth, height: Self.frameHeight, ellipses: [left, right])
        let detector = PlateDetector(configuration: Self.makeConfiguration(radius: majorAxis / 2))

        let nearLeft = try #require(detector.detect(in: buffer, previousCenter: CGPoint(x: 150, y: 240)))
        #expect(abs(nearLeft.center.x - left.center.x) < 5)

        let nearRight = try #require(detector.detect(in: buffer, previousCenter: CGPoint(x: 490, y: 240)))
        #expect(abs(nearRight.center.x - right.center.x) < 5)
    }

    // MARK: - Timing

    /// Not a pass/fail correctness test: measures and reports per-frame
    /// detection cost on this Mac, as a stand-in for the SPEC §16 ≤5ms
    /// on-device budget. **This is a stand-in, not a substitute** — the
    /// real number is confirmed on-device in W6-08 against the thermal
    /// ladder; a Mac's CPU/GPU and thermal envelope are not an iPhone's.
    @Test("reports measured per-frame detection timing on this Mac (informational, see doc comment)")
    func measuresPerFrameTiming() throws {
        let majorAxis = 220.0
        let ellipse = SyntheticPlateFrame.Ellipse(
            center: CGPoint(x: 320, y: 240), majorAxis: majorAxis, minorAxis: majorAxis * 0.8, rotation: 0.5
        )
        let buffer = SyntheticPlateFrame.render(width: Self.frameWidth, height: Self.frameHeight, ellipses: [ellipse])
        let detector = PlateDetector(configuration: Self.makeConfiguration(radius: majorAxis / 2))

        // Warm up (first call pays one-time Vision/Metal init cost that a
        // running capture session wouldn't repeat every frame).
        _ = detector.detect(in: buffer)

        let iterations = 30
        let start = Date()
        for _ in 0..<iterations {
            _ = detector.detect(in: buffer)
        }
        let elapsedSeconds = Date().timeIntervalSince(start)
        let perFrameMs = elapsedSeconds * 1000 / Double(iterations)

        print(
            "PlateDetector.detect: \(perFrameMs) ms/frame average over \(iterations) iterations on this Mac "
                + "(stand-in for the ≤5ms on-device budget, SPEC §16 — confirmed on-device in W6-08)."
        )
        // Generous sanity bound so a real performance regression still
        // fails CI, without pretending this Mac number is the device
        // number.
        #expect(perFrameMs < 200)
    }
}
