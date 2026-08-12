import CoreGraphics

/// One frame's plate detection result (SPEC §8): the fitted ellipse of the
/// tracked plate, in pixel space, plus a confidence in the fit itself.
///
/// This is Track A's per-frame output before any of `PlateScale` (metric
/// conversion), a tracker's occlusion/interpolation logic (W2-03), or the
/// motion-axis projection (W2-04) touch it. It carries pixels and a fit
/// confidence only — no metres, no velocity, no rep state.
///
/// A real `Sendable` value type, not `@unchecked`: every stored property is
/// itself a plain, already-`Sendable` value (`CGPoint`, `Double`), matching
/// SPEC §4.4 — this is exactly the kind of `Sendable` value type meant to
/// cross the `CaptureActor` → `@MainActor` boundary over an `AsyncStream`,
/// once a tracker (W2-03) produces one per frame.
public struct PlateObservation: Sendable, Equatable {
    /// Ellipse centre, pixel space, same coordinate frame as the source
    /// `CVPixelBuffer` (origin top-left, x right, y down — matching
    /// `CVPixelBuffer`/`CGImage` convention, not Vision's normalized,
    /// bottom-left-origin one).
    public let center: CGPoint

    /// The fitted ellipse's major axis, **full length** in pixels — i.e.
    /// the true diameter of the tracked circle projected into the image,
    /// not a semi-axis. This is what SPEC §8's
    /// `pixels_per_metre = major_axis_px / plate_diameter_m` divides by,
    /// and is rotation-invariant: it stays the true diameter regardless of
    /// how the plate is oriented on screen or how obliquely the camera
    /// views it (up to the eccentricity cutoff `PlateDetector` enforces
    /// before an observation is ever produced).
    public let majorAxisPx: Double

    /// The fitted ellipse's minor axis, full length in pixels. Equal to
    /// `majorAxisPx` for a perpendicular (circular) view; smaller as the
    /// camera's angle off the plate's face increases (`minorAxisPx /
    /// majorAxisPx == cos(viewingAngle)`, see `PlateDetector`'s
    /// eccentricity check).
    public let minorAxisPx: Double

    /// The major axis's direction, radians, measured the same way
    /// `EllipseFit.Ellipse.orientation` is: from the positive x-axis,
    /// increasing toward positive y (pixel-space "down"), wrapped to
    /// `[0, .pi)`. An ellipse's major axis is a line, not an arrow — there
    /// is no intrinsic "forward" end to distinguish 0 from `.pi`, so this
    /// type does not pretend one exists.
    public let orientation: Double

    /// Fit quality, `0...1`. A real function of how well the fitted conic
    /// matches the edge points it was fit from (`EllipseFit.Ellipse
    /// .normalizedResidual`, via `PlateDetector`) — never a fixed constant.
    /// This is *not* the same signal as the eccentricity check: an
    /// implausible camera angle is rejected outright (`PlateDetector`
    /// returns `nil` for it, per SPEC §8's "reject fits whose eccentricity
    /// implies an impossible camera angle" — a hard refusal, not a lowered
    /// number here), so by the time an observation exists, its geometry has
    /// already passed that gate and `confidence` is purely about how
    /// cleanly the edge points it saw agreed with an ellipse.
    public let confidence: Double

    /// - Precondition: `majorAxisPx >= minorAxisPx > 0`, both finite.
    /// - Precondition: `confidence` is finite and in `0...1`.
    public init(center: CGPoint, majorAxisPx: Double, minorAxisPx: Double, orientation: Double, confidence: Double) {
        precondition(
            majorAxisPx.isFinite && minorAxisPx.isFinite && majorAxisPx >= minorAxisPx && minorAxisPx > 0,
            "PlateObservation requires 0 < minorAxisPx <= majorAxisPx, both finite"
        )
        precondition(
            confidence.isFinite && (0...1).contains(confidence),
            "PlateObservation.confidence must be finite and in 0...1"
        )
        self.center = center
        self.majorAxisPx = majorAxisPx
        self.minorAxisPx = minorAxisPx
        self.orientation = orientation
        self.confidence = confidence
    }
}
