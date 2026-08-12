import CoreGraphics
import CoreVideo
import Foundation

/// A short, deterministic multi-frame clip built on top of
/// `SyntheticPlateFrame` (READ ONLY, owned elsewhere) for exercising
/// `PlateTracker` across time rather than a single frame.
/// `SyntheticPlateFrame` renders one buffer; this stitches a sequence of
/// them together with per-frame plate placement (or deliberate absence)
/// and timestamps, in the plain `(CVPixelBuffer, TimeInterval)` shape
/// `PlateTracker.processFrame` consumes.
///
/// **These are synthetic verifications only.** They prove `PlateTracker`'s
/// state machine — local search, occlusion bridging, loss, periodic
/// re-detection — is wired correctly against frames whose ground truth is
/// known exactly, because this generator drew them. They say nothing about
/// real footage: real gym lighting, real chrome-plate glare, the real
/// shape of a hand or rack-upright occlusion, real bar acceleration. That
/// confirmation is W2-06's job, once W1-06's real-footage fixture corpus
/// exists — this file does not claim it.
enum SyntheticPlateClip {
    static let frameWidth = 640
    static let frameHeight = 480

    /// One frame's ground truth: where the plate is, or `nil` if it should
    /// be absent (occluded, or — indistinguishably, from a detector's
    /// point of view — off-frame entirely; see `leavingFrame`).
    struct Frame {
        var ellipse: SyntheticPlateFrame.Ellipse?
        var timestamp: TimeInterval
    }

    /// Renders `frames` into buffers ready to feed
    /// `PlateTracker.processFrame(_:timestamp:)` in order.
    static func render(_ frames: [Frame]) -> [(buffer: CVPixelBuffer, timestamp: TimeInterval)] {
        frames.map { frame in
            let ellipses = frame.ellipse.map { [$0] } ?? []
            let buffer = SyntheticPlateFrame.render(width: frameWidth, height: frameHeight, ellipses: ellipses)
            return (buffer, frame.timestamp)
        }
    }

    /// A clip of a plate moving in a straight line at constant per-frame
    /// velocity, fixed size and rotation throughout. Varying only position
    /// (not size) is deliberate: it exercises centroid-following without
    /// confounding it with a second varying dimension local search was
    /// never asked to handle here.
    static func movingPlate(
        frameCount: Int,
        startCenter: CGPoint,
        velocityPxPerFrame: CGVector = .zero,
        majorAxis: Double,
        minorAxis: Double? = nil,
        rotation: Double = 0,
        frameIntervalSeconds: TimeInterval = 1.0 / 30.0,
        startTimestamp: TimeInterval = 0
    ) -> [Frame] {
        (0..<frameCount).map { index in
            let center = CGPoint(
                x: startCenter.x + velocityPxPerFrame.dx * Double(index),
                y: startCenter.y + velocityPxPerFrame.dy * Double(index)
            )
            let ellipse = SyntheticPlateFrame.Ellipse(
                center: center, majorAxis: majorAxis, minorAxis: minorAxis ?? majorAxis, rotation: rotation
            )
            return Frame(ellipse: ellipse, timestamp: startTimestamp + Double(index) * frameIntervalSeconds)
        }
    }

    /// `base` with the plate removed for every frame index in
    /// `hiddenIndices` — stands in for a hand/rack-upright occlusion, or
    /// (for a trailing run of hidden indices through the end of the clip)
    /// the plate leaving frame entirely. Timestamps are preserved so the
    /// clip's timing is unaffected by which frames happen to be hidden.
    static func occluding(_ base: [Frame], hiddenIndices: Set<Int>) -> [Frame] {
        base.enumerated().map { index, frame in
            hiddenIndices.contains(index) ? Frame(ellipse: nil, timestamp: frame.timestamp) : frame
        }
    }
}
