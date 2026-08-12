import Foundation

/// Turns a per-frame `PlateObservation.majorAxisPx` into a metric scale
/// (SPEC §6, §8): a stateful wrapper around `PlateScale.metresPerPixel`
/// (`PlateConfiguration.swift`, reused here — not reimplemented) that adds
/// the three things a bare per-frame division does not have on its own:
///
/// 1. **Recomputed every frame, never cached per set.** A lifter drifting
///    toward or away from the camera changes `majorAxisPx`; the scale has
///    to track that instead of going stale (SPEC §8: "Recomputed every
///    frame, so it survives the lifter drifting"). `observe` is `mutating`
///    and does the full computation on every call — there is no per-set
///    cache to invalidate, because one was never built.
/// 2. **Smoothed over a short window** (`defaultWindowSize`). The quantity
///    behind this signal — distance from lifter to camera — genuinely
///    changes slowly; the noise lives in the per-frame ellipse fit, not in
///    the thing being measured, so averaging it out is signal-appropriate
///    rather than lag-inducing. This is a distinct case from SPEC §4.1's
///    rule ("if smoothing is needed, apply it to the 1D `RepSignal`, not to
///    33 landmarks × 3 coordinates" — one filter, not one per channel):
///    that rule exists to stop a filter being duplicated across many
///    correlated channels. This is one filter on one channel, and it is a
///    scale estimate, not the rep signal itself, so it does not fall under
///    "the rep signal is the only place smoothing happens."
/// 3. **Sanity-bounded, not clamped.** A scale implying the subject is
///    nearer than 0.5 m or further than 8 m is refused outright
///    (`RejectionReason`), never silently clamped to the nearest bound.
///    Clamping would produce a confident wrong number — exactly the
///    failure this project refuses everywhere else (see
///    `PlateConfigurationLookup.unconfigured`, `ScaleSource.torsoRelative`).
public struct MetricScale: Sendable {

    // MARK: - Output shapes

    /// One frame's accepted scale.
    public struct Estimate: Sendable, Equatable {
        /// This frame's raw, unsmoothed `PlateScale.metresPerPixel(majorAxisPx:diameterMm:)`
        /// value. Exposed for debugging and tests only — `metresPerPixel`
        /// is what a caller should actually use.
        public let rawMetresPerPixel: Double

        /// The smoothed estimate: the mean of the last `windowSize` raw
        /// values (fewer while the window is still filling), including
        /// this frame's. This is the number that should feed
        /// `RepSignal.append`.
        public let metresPerPixel: Double

        /// Camera-to-subject distance implied by `metresPerPixel`, metres:
        /// `focalLengthPx * metresPerPixel`. See `MetricScale.init`'s
        /// `focalLengthPx` parameter doc for the assumption behind its
        /// default.
        public let impliedDistanceMetres: Double

        /// Always `.plateDiameter(mm:)` — the only `ScaleSource` this type
        /// ever produces (SPEC §6, §8: "Emit `ScaleSource.plateDiameter`").
        public let scaleSource: RepSignal.ScaleSource
    }

    /// Why a frame's scale was refused. Named cases carrying the offending
    /// numbers, not a bare `nil` — matching this codebase's error style
    /// (`PlateConfigurationError`, `PlateConfigurationLookup.RefusalError`)
    /// so a rejection is debuggable from the value alone, without a caller
    /// re-deriving it from raw inputs.
    public enum RejectionReason: Sendable, Equatable, CustomStringConvertible {
        /// `majorAxisPx` was non-finite or non-positive — there is no
        /// scale to compute. `PlateObservation`'s own precondition already
        /// rules this out for real detector output; this case exists
        /// because `observe(majorAxisPx:)` also accepts a bare `Double`
        /// that hasn't necessarily passed through that precondition.
        case invalidMajorAxis(majorAxisPx: Double)

        /// The implied camera-to-subject distance is under `minimumMetres`
        /// — physically implausible for a lift filmed on a phone propped
        /// up nearby.
        case tooNear(impliedDistanceMetres: Double, minimumMetres: Double)

        /// The implied camera-to-subject distance is over `maximumMetres`
        /// — well past any realistic gym setup.
        case tooFar(impliedDistanceMetres: Double, maximumMetres: Double)

        public var description: String {
            switch self {
            case .invalidMajorAxis(let majorAxisPx):
                "invalid major axis: \(majorAxisPx) px (must be finite and > 0)"
            case .tooNear(let distance, let minimum):
                "implied distance \(distance) m is under the \(minimum) m minimum — rejected, not clamped"
            case .tooFar(let distance, let maximum):
                "implied distance \(distance) m is over the \(maximum) m maximum — rejected, not clamped"
            }
        }
    }

    /// One frame's outcome.
    public enum Result: Sendable, Equatable {
        case accepted(Estimate)
        case rejected(RejectionReason)
    }

    // MARK: - Configuration

    /// The real diameter this scale assumes, and its provenance — see
    /// `PlateConfiguration`. Fixed at `init`; a diameter change mid-stream
    /// means the tracked plate changed, which calls for a new
    /// `MetricScale`, not a mutation of this one (and would otherwise let
    /// a stale smoothing window mix samples computed against two different
    /// diameters).
    public let configuration: PlateConfiguration

    /// Camera-to-subject distance bounds, metres. Outside this range a
    /// frame is rejected (`RejectionReason.tooNear` / `.tooFar`), never
    /// clamped. Defaults to SPEC §8's 0.5 m / 8 m.
    public let distanceBoundsMetres: ClosedRange<Double>

    /// Focal length, pixels, used **only** to turn `metresPerPixel` into
    /// `impliedDistanceMetres` for the sanity-bounds check. It plays no
    /// part in `metresPerPixel` itself, which depends solely on
    /// `configuration.millimetres` and the observed `majorAxisPx`
    /// (`PlateScale.metresPerPixel` — pure pixels-to-metres arithmetic,
    /// no camera intrinsic involved). So an error in this assumption only
    /// widens or narrows the sanity gate; it can never bias the scale a
    /// caller actually uses for velocity or ROM.
    public let focalLengthPx: Double

    /// Default `focalLengthPx`. Assumes the SPEC §4.2 default capture
    /// configuration — front (TrueDepth) camera, 1920×1080 — and a
    /// horizontal field of view of roughly 70°, a commonly cited ballpark
    /// for that camera across recent iPhone generations (Apple does not
    /// publish an exact per-model figure, and this project does not have
    /// one measured). `focalLengthPx = (imageWidthPx / 2) / tan(hfov / 2)
    /// = 960 / tan(35°) ≈ 1371 px`. This is a coarse stand-in for a real
    /// per-device intrinsic (`AVCaptureDevice.activeFormat` exposes one);
    /// reading that is capture-layer work outside `Core`, so any caller
    /// that can read the real intrinsic should pass it here instead of
    /// relying on this default.
    public static let defaultFocalLengthPx: Double = 960.0 / tan(35.0 * Double.pi / 180.0)

    /// SPEC §8's default sanity bounds: reject a scale implying the
    /// subject is nearer than 0.5 m or further than 8 m away.
    public static let defaultDistanceBoundsMetres: ClosedRange<Double> = 0.5...8.0

    /// Default smoothing window length, in frames.
    ///
    /// 15 frames at the SPEC §4.2 60 fps capture rate is 0.25 s. Chosen
    /// deliberately, not picked round: camera-to-subject distance drifts
    /// on a timescale of seconds (a lifter stepping back from the rack,
    /// resettling between reps), while a rep's own concentric/eccentric
    /// half-cycle is on the order of a second or more — so 0.25 s is short
    /// enough that this window can never be mistaken for (or start acting
    /// like) a rep-scale filter, and long enough to average over 15
    /// independent per-frame ellipse fits, which is enough to meaningfully
    /// damp frame-to-frame detection jitter without averaging away a
    /// genuine, slower distance change.
    public static let defaultWindowSize = 15

    private var window: RingBuffer<Double>

    // MARK: - Init

    /// - Parameters:
    ///   - configuration: the assumed real plate/end-cap diameter (see
    ///     `PlateConfiguration`). Typically the result of
    ///     `PlateConfigurationLookup.requireConfiguration()` — this type
    ///     never defaults one.
    ///   - windowSize: smoothing window length, frames. See
    ///     `defaultWindowSize` for the default and its justification.
    ///   - focalLengthPx: see `defaultFocalLengthPx` for the default and
    ///     the assumption it encodes.
    ///   - distanceBoundsMetres: see `defaultDistanceBoundsMetres`.
    public init(
        configuration: PlateConfiguration,
        windowSize: Int = MetricScale.defaultWindowSize,
        focalLengthPx: Double = MetricScale.defaultFocalLengthPx,
        distanceBoundsMetres: ClosedRange<Double> = MetricScale.defaultDistanceBoundsMetres
    ) {
        precondition(windowSize > 0, "MetricScale windowSize must be positive")
        precondition(
            focalLengthPx.isFinite && focalLengthPx > 0,
            "MetricScale focalLengthPx must be finite and > 0"
        )
        self.configuration = configuration
        self.focalLengthPx = focalLengthPx
        self.distanceBoundsMetres = distanceBoundsMetres
        self.window = RingBuffer(capacity: windowSize)
    }

    // MARK: - Per-frame update

    /// Feeds one frame's fitted major axis through the scale arithmetic,
    /// the smoothing window, and the sanity bounds, in that order.
    ///
    /// A frame that fails either check (`invalidMajorAxis`, `tooNear`,
    /// `tooFar`) is rejected **without** being pushed into the smoothing
    /// window, so one bad detection cannot drag several subsequent
    /// frames' smoothed output toward it — the window only ever holds
    /// values that already passed the sanity gate on their own.
    @discardableResult
    public mutating func observe(majorAxisPx: Double) -> Result {
        guard
            let rawMetresPerPixel = PlateScale.metresPerPixel(
                majorAxisPx: majorAxisPx,
                diameterMm: configuration.millimetres
            )
        else {
            return .rejected(.invalidMajorAxis(majorAxisPx: majorAxisPx))
        }

        let rawDistanceMetres = focalLengthPx * rawMetresPerPixel
        guard rawDistanceMetres >= distanceBoundsMetres.lowerBound else {
            return .rejected(
                .tooNear(impliedDistanceMetres: rawDistanceMetres, minimumMetres: distanceBoundsMetres.lowerBound)
            )
        }
        guard rawDistanceMetres <= distanceBoundsMetres.upperBound else {
            return .rejected(
                .tooFar(impliedDistanceMetres: rawDistanceMetres, maximumMetres: distanceBoundsMetres.upperBound)
            )
        }

        window.append(rawMetresPerPixel)
        let smoothedMetresPerPixel = window.reduce(0, +) / Double(window.count)

        return .accepted(
            Estimate(
                rawMetresPerPixel: rawMetresPerPixel,
                metresPerPixel: smoothedMetresPerPixel,
                impliedDistanceMetres: focalLengthPx * smoothedMetresPerPixel,
                scaleSource: .plateDiameter(mm: configuration.millimetres)
            )
        )
    }

    /// Convenience over `observe(majorAxisPx:)` for the real per-frame
    /// input shape — `PlateDetector` / a future tracker's per-frame
    /// output.
    @discardableResult
    public mutating func observe(_ observation: PlateObservation) -> Result {
        observe(majorAxisPx: observation.majorAxisPx)
    }
}
