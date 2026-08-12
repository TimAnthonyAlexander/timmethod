import CoreGraphics
import CoreVideo
import Foundation
import Testing

@testable import TimMethodCore

/// Exercises `PlateTracker`'s state machine — local search, occlusion
/// bridging, loss, periodic re-detection, determinism — end to end through
/// `PlateDetector`'s real Vision pipeline (via `SyntheticPlateClip`), the
/// same way `PlateDetectorTests` exercises `PlateDetector` itself rather
/// than testing the maths in isolation.
///
/// **These are synthetic verifications only** (see `SyntheticPlateClip`'s
/// doc comment). They prove the tracker is wired correctly against frames
/// with known ground truth. Real-footage confirmation — real occlusion
/// shapes, real gym lighting, real bar acceleration — is W2-06's job, once
/// W1-06's fixture corpus exists. Nothing here claims a real-footage
/// result.
@Suite("PlateTracker")
struct PlateTrackerTests {
    static let plateConfiguration: PlateConfiguration = .olympicOrBumper

    static func makeDetectorConfiguration(radius: Double, tolerance: Double = 0.35) -> PlateDetector.Configuration {
        PlateDetector.Configuration(
            minRadiusPx: radius * (1 - tolerance),
            maxRadiusPx: radius * (1 + tolerance)
        )
    }

    static func makeTrackerConfiguration(
        radius: Double,
        redetectionIntervalFrames: Int = PlateTracker.defaultRedetectionIntervalFrames
    ) -> PlateTracker.Configuration {
        PlateTracker.Configuration(
            detectorConfiguration: Self.makeDetectorConfiguration(radius: radius),
            plateConfiguration: Self.plateConfiguration,
            redetectionIntervalFrames: redetectionIntervalFrames
        )
    }

    // MARK: - 3-frame occlusion: bridged, marked interpolated

    @Test("a 3-frame occlusion mid-motion is bridged: tracking survives and the bridged frames are marked interpolated")
    func threeFrameOcclusionIsBridged() throws {
        let majorAxis = 160.0
        let clip = SyntheticPlateClip.occluding(
            SyntheticPlateClip.movingPlate(
                frameCount: 10, startCenter: CGPoint(x: 150, y: 240),
                velocityPxPerFrame: CGVector(dx: 3, dy: 0), majorAxis: majorAxis
            ),
            hiddenIndices: [4, 5, 6]
        )
        let frames = SyntheticPlateClip.render(clip)
        var tracker = PlateTracker(configuration: Self.makeTrackerConfiguration(radius: majorAxis / 2))
        let results = frames.map { tracker.processFrame($0.buffer, timestamp: $0.timestamp) }

        for index in 0...3 {
            #expect(results[index].isMeasured, "frame \(index) should be a real measurement")
        }
        for index in 4...6 {
            #expect(results[index].isInterpolated, "frame \(index) should be bridged, not measured or lost")
        }
        #expect(results[7].isMeasured, "tracking should recover to a real measurement once the plate reappears")

        let t4 = try #require(results[4].interpolatedValue)
        let t5 = try #require(results[5].interpolatedValue)
        let t6 = try #require(results[6].interpolatedValue)
        #expect(t4.framesSinceMeasurement == 1)
        #expect(t5.framesSinceMeasurement == 2)
        #expect(t6.framesSinceMeasurement == 3)
        // Confidence decays across the gap rather than sitting at full.
        #expect(t4.confidence > t5.confidence)
        #expect(t5.confidence > t6.confidence)
        #expect(t4.confidence < 1)
    }

    // MARK: - 6-frame occlusion: exceeds the window, reports lost

    @Test("a 6-frame occlusion exceeds the interpolation window and reports lost rather than bridging")
    func sixFrameOcclusionExceedsWindow() throws {
        let majorAxis = 160.0
        let clip = SyntheticPlateClip.occluding(
            SyntheticPlateClip.movingPlate(
                frameCount: 10, startCenter: CGPoint(x: 150, y: 240),
                velocityPxPerFrame: CGVector(dx: 3, dy: 0), majorAxis: majorAxis
            ),
            hiddenIndices: [3, 4, 5, 6, 7, 8]
        )
        let frames = SyntheticPlateClip.render(clip)
        var tracker = PlateTracker(configuration: Self.makeTrackerConfiguration(radius: majorAxis / 2))
        let results = frames.map { tracker.processFrame($0.buffer, timestamp: $0.timestamp) }

        for index in 0...2 {
            #expect(results[index].isMeasured, "frame \(index) should be a real measurement")
        }
        for index in 3...7 {
            #expect(results[index].isInterpolated, "frame \(index) is within the 5-frame window")
        }
        #expect(results[8].isLost, "the 6th consecutive missed frame must exceed the window and report lost")
        #expect(results[8].center == nil, "a lost frame must carry no fabricated centroid")
        #expect(
            results[9].isMeasured,
            "the plate reappearing should recover via the mandatory full re-detection after a loss"
        )
    }

    // MARK: - Plate leaves frame entirely: lost, no fabricated centroids

    @Test("a plate that leaves frame entirely reports lost and emits no fabricated centroids")
    func plateLeavingFrameReportsLostWithNoFabrication() throws {
        let majorAxis = 160.0
        var frames = SyntheticPlateClip.movingPlate(
            frameCount: 12, startCenter: CGPoint(x: 150, y: 240), majorAxis: majorAxis
        )
        // Plate present for the first 3 frames, then gone for good — from
        // the detector's point of view this is indistinguishable from
        // "walked off the edge of frame" (see `SyntheticPlateClip`'s doc).
        for index in 3..<frames.count {
            frames[index].ellipse = nil
        }
        let rendered = SyntheticPlateClip.render(frames)
        var tracker = PlateTracker(configuration: Self.makeTrackerConfiguration(radius: majorAxis / 2))
        let results = rendered.map { tracker.processFrame($0.buffer, timestamp: $0.timestamp) }

        for index in 0...2 {
            #expect(results[index].isMeasured)
        }
        // Frames 3...7 are within the 5-frame interpolation window.
        for index in 3...7 {
            #expect(results[index].isInterpolated)
        }
        // From frame 8 on, the plate never comes back: every remaining
        // frame must report lost, with no centroid at all.
        for index in 8..<results.count {
            #expect(results[index].isLost, "frame \(index) should report lost — the plate never returns")
            #expect(results[index].center == nil, "frame \(index) must not carry a fabricated centroid")
        }
    }

    // MARK: - Local search matches full detection

    @Test("local search follows a moving plate and matches independent full detection every frame, within tolerance")
    func localSearchMatchesFullDetection() throws {
        let majorAxis = 180.0
        let clipFrames = SyntheticPlateClip.movingPlate(
            frameCount: 8, startCenter: CGPoint(x: 200, y: 220),
            velocityPxPerFrame: CGVector(dx: 4, dy: -2), majorAxis: majorAxis
        )
        let rendered = SyntheticPlateClip.render(clipFrames)

        let detectorConfiguration = Self.makeDetectorConfiguration(radius: majorAxis / 2)
        var tracker = PlateTracker(
            configuration: PlateTracker.Configuration(
                detectorConfiguration: detectorConfiguration, plateConfiguration: Self.plateConfiguration
            )
        )
        let trackedResults = rendered.map { tracker.processFrame($0.buffer, timestamp: $0.timestamp) }

        // Ground truth: an independent, full-frame-only detector run over
        // the identical buffers, with no temporal state at all.
        let independentDetector = PlateDetector(configuration: detectorConfiguration)
        let independentCenters = rendered.map { independentDetector.detect(in: $0.buffer)?.center }

        #expect(trackedResults.count == independentCenters.count)
        for index in trackedResults.indices {
            let tracked = try #require(trackedResults[index].measuredValue, "frame \(index) should be a real measurement")
            let independent = try #require(independentCenters[index], "frame \(index) ground truth should detect")
            #expect(
                abs(tracked.center.x - independent.x) < 2.5,
                "frame \(index): tracked x \(tracked.center.x) vs independent x \(independent.x)"
            )
            #expect(
                abs(tracked.center.y - independent.y) < 2.5,
                "frame \(index): tracked y \(tracked.center.y) vs independent y \(independent.y)"
            )
        }
    }

    // MARK: - Periodic re-detection recovers a bad lock

    @Test("periodic full re-detection recovers from a deliberately seeded bad lock")
    func periodicRedetectionRecoversBadLock() throws {
        let majorAxis = 160.0
        // Frame 0: only a decoy, far from where the real plate will be —
        // the tracker's only option is to lock onto it (a "bad lock",
        // seeded through the clip itself, not a test-only hook).
        let decoyCenter = CGPoint(x: 150, y: 240)
        let realCenter = CGPoint(x: 490, y: 240)
        // Well outside the local-search radius from the decoy, so local
        // search alone can never bridge the gap — only a scheduled
        // full-frame pass can recover it.
        #expect(hypot(realCenter.x - decoyCenter.x, realCenter.y - decoyCenter.y) > 300)

        let decoy = SyntheticPlateFrame.Ellipse(center: decoyCenter, majorAxis: majorAxis, minorAxis: majorAxis)
        let real = SyntheticPlateFrame.Ellipse(center: realCenter, majorAxis: majorAxis, minorAxis: majorAxis)
        let interval = 1.0 / 30.0
        let frames = [
            SyntheticPlateClip.Frame(ellipse: decoy, timestamp: 0),
            SyntheticPlateClip.Frame(ellipse: real, timestamp: interval),
            SyntheticPlateClip.Frame(ellipse: real, timestamp: 2 * interval),
            SyntheticPlateClip.Frame(ellipse: real, timestamp: 3 * interval),
            SyntheticPlateClip.Frame(ellipse: real, timestamp: 4 * interval),
        ]
        let rendered = SyntheticPlateClip.render(frames)

        // Force a full re-detection every 3rd frame — well inside the
        // 5-frame interpolation window, so recovery here can only be the
        // periodic mechanism, not the occlusion-timeout-into-loss path.
        var tracker = PlateTracker(
            configuration: Self.makeTrackerConfiguration(radius: majorAxis / 2, redetectionIntervalFrames: 3)
        )
        let results = rendered.map { tracker.processFrame($0.buffer, timestamp: $0.timestamp) }

        #expect(results[0].isMeasured, "frame 0 locks onto the only thing in frame — the decoy")
        #expect(results[1].isInterpolated, "the real plate is outside the decoy-anchored local-search window")
        #expect(results[2].isInterpolated, "still bridging — periodic re-detection hasn't fired yet")
        let recovered = try #require(results[3].measuredValue, "the scheduled 3rd-frame full pass should recover")
        #expect(abs(recovered.center.x - realCenter.x) < 2, "recovered center should be the real plate, not the decoy")
        #expect(abs(recovered.center.y - realCenter.y) < 2)
        #expect(results[4].isMeasured, "tracking should continue normally once relocked onto the real plate")
    }

    // MARK: - Determinism

    @Test("identical clip in, identical track out")
    func deterministicAcrossRuns() throws {
        let majorAxis = 160.0
        let clip = SyntheticPlateClip.occluding(
            SyntheticPlateClip.movingPlate(
                frameCount: 10, startCenter: CGPoint(x: 150, y: 240),
                velocityPxPerFrame: CGVector(dx: 3, dy: 0), majorAxis: majorAxis
            ),
            hiddenIndices: [4, 5, 6]
        )
        let frames = SyntheticPlateClip.render(clip)
        let configuration = Self.makeTrackerConfiguration(radius: majorAxis / 2)

        var trackerA = PlateTracker(configuration: configuration)
        let resultsA = frames.map { trackerA.processFrame($0.buffer, timestamp: $0.timestamp) }

        var trackerB = PlateTracker(configuration: configuration)
        let resultsB = frames.map { trackerB.processFrame($0.buffer, timestamp: $0.timestamp) }

        #expect(resultsA == resultsB, "identical clip fed to two fresh trackers must produce identical results")
    }
}

// MARK: - Test-only extraction helpers

extension PlateTracker.FrameResult {
    fileprivate var measuredValue: PlateObservation? {
        if case .measured(let observation) = self { observation } else { nil }
    }

    fileprivate var interpolatedValue: PlateTracker.TrackedObservation? {
        if case .interpolated(let tracked) = self { tracked } else { nil }
    }
}
