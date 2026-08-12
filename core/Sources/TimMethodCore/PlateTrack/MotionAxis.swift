import CoreGraphics
import Foundation

/// Turns a stream of 2-D plate centroids (metres) into the scalar
/// `RepSignal` the counter reads (SPEC §6, §8; W2-04) — the file that
/// closes Track A. Everything upstream of this (`PlateDetector`,
/// `PlateTracker`, `MetricScale`) exists to produce one good centroid per
/// frame; this is where that 2-D trace becomes the 1-D signal the rep
/// counter is a single implementation over, and never sees a plate, a
/// joint, or a camera.
///
/// ## Fit the axis, don't assume it
///
/// A squat's plate moves close to vertical in most framings. A bench
/// press's plate also moves vertically **in the real world**, but the
/// camera that films it is usually off to the side, at some height and
/// distance that does not put the motion on the image's vertical axis
/// exactly — and any lift filmed with a tilted phone compounds that
/// further. Hardcoding "vertical = pixel-space up" would quietly mis-measure
/// every one of those. Instead this fits the **first principal component**
/// of the recent centroid trace — the direction the plate is actually
/// moving along, in image space, this set, on this camera — and projects
/// onto that. A squat and a bench press run through identical code with no
/// per-exercise branch; SPEC §6 notes this is exactly the PCA route NEX
/// Team shipped in HomeCourt, reused here for Track A's 2-D case instead of
/// Track B's landmark case.
///
/// The eigenproblem is a plain symmetric 2x2 (the covariance matrix of the
/// windowed points), which has a closed form — no matrix library, same
/// house style as `EllipseFit`'s closed-form conic→ellipse extraction
/// (`ellipseParameters`), reused for inspiration, not by dependency: this
/// file does not import or call into `EllipseFit`, and doesn't need to —
/// 2x2 is smaller than the 3x3 general (non-symmetric) system that file
/// solves, and a symmetric matrix's eigenvectors are always real and
/// orthogonal, so there's no cubic characteristic polynomial or null-space
/// extraction to do here at all.
///
/// ## Window: length and its extremes
///
/// `Configuration.windowDurationSeconds` defaults to 6 seconds
/// (`defaultWindowDurationSeconds`). Two failure modes bound it from
/// opposite sides:
///
/// - **Too short** and the window can sit entirely inside one phase of one
///   rep — e.g. only the concentric half. A single phase's points don't
///   trace out the rep's full excursion, so their covariance is a noisier,
///   less representative estimate of the lift's actual axis, and the fit
///   becomes sensitive to exactly which slice of motion the window happens
///   to catch, producing a jumpier axis frame to frame. SPEC §7.2 treats a
///   half-cycle as "order of a second or more"; a full concentric+eccentric
///   rep is at least ~2s even at a fast tempo, and slower, paused, or
///   tempo-controlled work (e.g. a 3-1-3 tempo) can run a full rep past 6s
///   on its own. 6s is chosen to comfortably span a typical rep more than
///   once, and a slow one at least once, while item 5's "at least a full
///   rep" is the hard floor this must clear.
/// - **Too long** and drift tracking (also item 5) gets sluggish: the axis
///   only fully reflects a change in bar path once most of a many-rep-old
///   window has aged out, so a real change (the lifter shifting stance, or
///   the bar path genuinely rotating as fatigue sets in) lags for longer
///   than it should. A very long window can also start smoothing distinct
///   reps' slightly different paths into one blurred average, and — across
///   a rest break — keep contributing points from the *previous* set to the
///   fit for the first few seconds of the next one.
///
/// `windowDurationSeconds` is time-based, not frame-count-based (contrast
/// `MetricScale.defaultWindowSize`, which is a frame count because that
/// window's job — damping per-frame ellipse-fit jitter — scales with frame
/// count): the point being fit over is a physical duration ("at least a
/// full rep"), and camera frame rate can be 30 or 60 fps (SPEC §16), so a
/// frame-count window would silently cover half as much real time at 60 fps
/// as at 30 fps. Filtering the backing buffer by `t - entry.t` each call
/// makes the fit window's real-world duration invariant to frame rate.
///
/// ## Sign: resolved once, then held stable
///
/// A 2-D PCA gives a *line*, not a *direction* — the dominant eigenvector's
/// sign is arbitrary and can flip between two numerically adjacent fits of
/// nearly-identical data (SPEC / this task item 3). Two different
/// mechanisms handle this, for two different situations:
///
/// 1. **Every fit after the first**: pick whichever of the two sign choices
///    has a positive dot product with the *previous* frame's resolved axis
///    (`axisDirection`). Consecutive windows overlap almost entirely and
///    drift only slowly (that's the whole point of the window-length
///    argument above), so the true axis direction barely moves frame to
///    frame — this reliably picks the "same" direction as last time
///    regardless of which way the raw eigenvector solver happened to point
///    this frame.
/// 2. **The very first fit** (no previous axis to stay consistent with):
///    orient so the axis's image-space-up component is positive — "away
///    from the ground" per `RepSignal.Sample`'s convention — under the
///    standing assumption that the camera is held roughly upright (SPEC §8
///    frames Track A around a phone propped up nearby, not one mounted at
///    an arbitrary roll). This is a **one-time tie-break of which end of an
///    already-fitted line counts as positive**, not a substitute for
///    fitting the line: `candidate`'s direction/angle still comes entirely
///    from the covariance matrix and can be anything, including
///    near-horizontal for an unusually tilted camera. That is the
///    difference between this and "hardcode gravity as the axis" (item 2,
///    forbidden) — the axis itself is never assumed vertical, only the
///    polarity of whatever axis was actually fit is, once, resolved against
///    a vertical reference.
///
/// `axisDirection` also survives gaps (`.lost` observations do not reset
/// it), so a brief occlusion doesn't force a sign re-bootstrap the moment
/// tracking resumes.
///
/// ## Degenerate windows
///
/// A stationary plate (racking between sets, a paused hold) has near-zero
/// variance in every direction — there is no dominant direction to recover,
/// and the closed-form angle (`atan2` of the covariance terms) is not
/// numerically meaningful there. Rather than emit whatever `atan2` returns
/// for a near-zero input (arbitrary, and liable to swing wildly frame to
/// frame for essentially the same reason the sign is ambiguous, just
/// continuously instead of binarily), this reuses the last resolved
/// `axisDirection` if one exists, or an image-space-up default if not
/// (`imageUpUnitVector`) — deterministic either way, and harmless: with
/// near-zero variance the projected `axial`/`lateral` are near zero
/// regardless of which axis they're measured against.
///
/// ## Honest gaps and confidence
///
/// `.lost` observations never become a sample — see `Result.gap` and
/// `RepSignal.append(_:)`. `.interpolated` observations do become samples,
/// but carry whatever (already-decayed, per `PlateTracker.TrackedObservation
/// .confidence`) confidence they were given, further scaled down while the
/// fitting window itself is still short on points (`minimumPointsForFit`) —
/// so an early, barely-informed axis doesn't produce a sample indistinguishable
/// from a fully warmed-up one.
public struct MotionAxis: Sendable {

    // MARK: - Input

    /// One frame's centroid, already converted to metres — this type does
    /// the geometry (axis fit, projection), not the pixel→metres
    /// conversion (`MetricScale`, a different file) or the occlusion
    /// bridging (`PlateTracker`, also a different file). A caller wiring
    /// the three together converts `PlateTracker.FrameResult.center` via
    /// `MetricScale`'s smoothed `metresPerPixel` once per frame and hands
    /// the result here.
    ///
    /// `pointMetres` is in the same coordinate convention as the pixel
    /// source it was scaled from (`PlateObservation.center`'s documented
    /// convention: origin top-left, x right, **y down**) — `MetricScale`
    /// only rescales magnitude, it does not flip axes, so a caller that
    /// just multiplies a pixel centroid by `metresPerPixel` preserves that
    /// convention automatically. This type's sign resolution (see type
    /// doc, "Sign") depends on that being true.
    public enum Observation: Sendable, Equatable {
        /// A real detection this frame (`PlateTracker.FrameResult
        /// .measured`, converted to metres).
        case measured(pointMetres: CGPoint, confidence: Double)

        /// A bridged/dead-reckoned centroid (`PlateTracker.FrameResult
        /// .interpolated`, converted to metres). `confidence` should
        /// already be the decayed value `PlateTracker.TrackedObservation
        /// .confidence` carries — this type only ever forwards what it's
        /// given, it does not discount interpolated frames a second time
        /// on top of that (see `Result.projected`'s `confidence`, which
        /// applies only a warm-up discount, orthogonal to this one).
        case interpolated(pointMetres: CGPoint, confidence: Double)

        /// Tracking lost this frame (`PlateTracker.FrameResult.lost`). No
        /// point exists to fit or project — see `observe(_:t:)` and
        /// `Result.gap`.
        case lost

        fileprivate var pointAndConfidence: (point: CGPoint, confidence: Double)? {
            switch self {
            case .measured(let point, let confidence), .interpolated(let point, let confidence):
                (point, confidence)
            case .lost:
                nil
            }
        }
    }

    // MARK: - Output

    /// One projected sample, ready to feed `RepSignal` (see
    /// `RepSignal.append(_:)`, defined below in this file).
    public struct Projection: Sendable, Equatable {
        /// Capture timestamp, seconds, same clock as the input `t`.
        public let t: TimeInterval

        /// Metres, along the fitted motion axis, **signed per
        /// `RepSignal.Sample.x`**: positive away from the ground. Measured
        /// relative to the current fitting window's mean position, not a
        /// fixed absolute origin — see type doc "Window": the window's
        /// mean itself tracks slow drift (a lifter's bar path creeping
        /// forward across a fatiguing set shifts the window mean, not the
        /// oscillation riding on top of it), so amplitude stays meaningful
        /// even as the baseline moves. This is the value `RepSignal
        /// .append(_:)` uses as `Sample.x` — it is what the counter (Wave
        /// 3) ultimately reads.
        public let axial: Double

        /// Metres, perpendicular to `axial`'s axis: horizontal bar
        /// deviation (SPEC §8's bar path, SPEC §14.1's "one genuinely
        /// beautiful thing this app draws"). A real, usable output — but
        /// it must **never** reach the counter (SPEC / this task item 4).
        /// `RepSignal.append(_:)` enforces that structurally: there is no
        /// overload that accepts a `Projection` and reads `lateral`.
        public let lateral: Double

        /// The sample's confidence, `0...1`: the triggering `Observation`
        /// 's own confidence, scaled down while the fitting window has
        /// fewer than `Configuration.minimumPointsForFit` points (see type
        /// doc, "Honest gaps and confidence"). Never scaled *up` — a
        /// warmed-up window cannot make a low-confidence interpolated
        /// frame more trustworthy than it was reported to be.
        public let confidence: Double
    }

    /// One frame's outcome from `observe(_:t:)`.
    public enum Result: Sendable, Equatable {
        /// A sample was produced — see `Projection`.
        case projected(Projection)

        /// This frame contributes no signal sample: either the
        /// `Observation` was `.lost`, or fewer than two points have ever
        /// been observed within the current window, so not even a
        /// degenerate axis exists yet. A caller must not synthesize a
        /// sample for either case — that is the entire meaning of "a gap
        /// is a gap, never a fabricated zero" (SPEC / this task item 6).
        /// `RepSignal.append(_:)` enforces this: there is no code path
        /// from `.gap` to a `RepSignal.Sample`.
        case gap
    }

    // MARK: - Configuration

    public struct Configuration: Sendable, Equatable {
        /// How much recent history, seconds, the PCA fit is computed over.
        /// See `MotionAxis.defaultWindowDurationSeconds` for the default
        /// and the type doc's "Window" section for the full derivation.
        public var windowDurationSeconds: Double

        /// Upper bound on how many observations the backing window ever
        /// retains, regardless of `windowDurationSeconds` — a ceiling on
        /// memory/compute if frame delivery stalls (timestamps stop
        /// advancing while `observe` keeps being called), not a value
        /// callers should need to tune. See
        /// `MotionAxis.defaultMaxWindowEntries`.
        public var maxWindowEntries: Int

        /// Below this many points in the current time-filtered window, a
        /// sample's `confidence` is discounted proportionally (see
        /// `Projection.confidence`). Distinct from the 2-point floor below
        /// which no fit — not even a discounted one — is attempted at all
        /// (`Result.gap`).
        public var minimumPointsForFit: Int

        public init(
            windowDurationSeconds: Double = MotionAxis.defaultWindowDurationSeconds,
            maxWindowEntries: Int = MotionAxis.defaultMaxWindowEntries,
            minimumPointsForFit: Int = MotionAxis.defaultMinimumPointsForFit
        ) {
            precondition(
                windowDurationSeconds.isFinite && windowDurationSeconds > 0,
                "MotionAxis.Configuration.windowDurationSeconds must be finite and positive"
            )
            precondition(
                maxWindowEntries > 1,
                "MotionAxis.Configuration.maxWindowEntries must be > 1 — a window needs at least two entries to ever fit anything"
            )
            precondition(
                minimumPointsForFit >= 2,
                "MotionAxis.Configuration.minimumPointsForFit must be >= 2, matching the hard floor below which Result.gap is returned"
            )
            self.windowDurationSeconds = windowDurationSeconds
            self.maxWindowEntries = maxWindowEntries
            self.minimumPointsForFit = minimumPointsForFit
        }
    }

    /// 6.0 s. See type doc, "Window: length and its extremes" for the full
    /// derivation.
    public static let defaultWindowDurationSeconds: Double = 6.0

    /// 480: `defaultWindowDurationSeconds` (6s) at the SPEC §16 60 fps
    /// ceiling is 360 raw frames; this adds ~33% headroom above that so a
    /// brief burst of unusually fast frame delivery, or `observe` being
    /// called slightly more often than the nominal capture rate, doesn't
    /// evict entries the time-filter in `observe` would otherwise still
    /// consider in-window. Entries older than `windowDurationSeconds` are
    /// filtered out of the fit regardless of whether they're still
    /// physically present in the buffer, so this only bounds worst-case
    /// memory — it never lets stale data leak into a fit.
    public static let defaultMaxWindowEntries: Int = 480

    /// 8. A handful of points is enough for the closed-form 2x2 fit to
    /// produce *a* direction, but not enough to trust it as representative
    /// of the set's actual bar path yet — the confidence discount in
    /// `Projection.confidence` ramps linearly from `0` at 2 points (the
    /// floor below which `Result.gap` applies instead) up to full trust at
    /// this many.
    public static let defaultMinimumPointsForFit: Int = 8

    /// Image-space "up": negative y, matching the y-down pixel/metres
    /// convention this type assumes (see `Observation`'s doc). Used only
    /// as the one-time sign tie-break for the very first fit and as the
    /// degenerate-window fallback when no previous axis exists yet — never
    /// as the fitted axis itself. See type doc, "Sign" and "Degenerate
    /// windows".
    public static let imageUpUnitVector = CGVector(dx: 0, dy: -1)

    /// Below this total variance (m²) in the fitting window, there is no
    /// meaningful dominant direction to recover — treated as a degenerate
    /// window (see type doc). `1e-8` m² is a standard deviation of about
    /// 0.1 mm per axis: far below any real barbell displacement, so this
    /// only fires for a genuinely stationary plate (or duplicate points),
    /// never for real, if small, motion.
    private static let degenerateVarianceEpsilonMetresSquared: Double = 1e-8

    // MARK: - State

    private struct WindowEntry: Sendable, Equatable {
        let t: TimeInterval
        let point: CGPoint
    }

    public let configuration: Configuration
    private var window: RingBuffer<WindowEntry>

    /// The last resolved axis direction, unit length. `nil` until the
    /// first successful fit. Persists across `.lost` gaps and across
    /// degenerate (near-zero-variance) windows — see type doc "Sign" and
    /// "Degenerate windows" for why continuity, not a reset, is the
    /// correct behaviour in both cases.
    public private(set) var axisDirection: CGVector?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.window = RingBuffer(capacity: configuration.maxWindowEntries)
    }

    // MARK: - Per-frame entry point

    /// Advances the fit by one frame and returns that frame's outcome.
    /// `t` is capture time, seconds, same clock as `RepSignal.Sample.t`.
    /// Must be called once per frame, in capture order — like
    /// `PlateTracker.processFrame`, this is causal: a given call only ever
    /// sees data from calls before it, never after.
    public mutating func observe(_ observation: Observation, t: TimeInterval) -> Result {
        guard let (point, confidence) = observation.pointAndConfidence else {
            // `.lost`: no point to add to the window, no sample to emit.
            // Deliberately does not touch `window` or `axisDirection` — a
            // brief occlusion (capped at 5 frames by `PlateTracker`)
            // shouldn't force the fit to restart the moment tracking
            // resumes.
            return .gap
        }

        window.append(WindowEntry(t: t, point: point))
        let entries = window.suffix(configuration.maxWindowEntries)
            .filter { t - $0.t <= configuration.windowDurationSeconds }

        guard entries.count >= 2 else {
            // Not even two points to define a line from yet. Emitting a
            // sample against a made-up axis here would be exactly the
            // "confident wrong number" this project refuses everywhere
            // else (SPEC — see `MetricScale`'s reject-don't-clamp
            // precedent for the same principle applied to a different
            // quantity).
            return .gap
        }

        let mean = Self.mean(of: entries)
        let axis = fitAxis(entries: entries, mean: mean)
        axisDirection = axis

        let centered = CGVector(dx: point.x - mean.x, dy: point.y - mean.y)
        let axial = centered.dx * axis.dx + centered.dy * axis.dy
        let perpendicular = CGVector(dx: -axis.dy, dy: axis.dx)
        let lateral = centered.dx * perpendicular.dx + centered.dy * perpendicular.dy

        let warmupFactor = Swift.min(1.0, Double(entries.count) / Double(configuration.minimumPointsForFit))
        let outputConfidence = Swift.max(0, Swift.min(1, confidence * warmupFactor))

        return .projected(Projection(t: t, axial: axial, lateral: lateral, confidence: outputConfidence))
    }

    // MARK: - PCA fit

    private static func mean(of entries: [WindowEntry]) -> CGPoint {
        var sumX = 0.0
        var sumY = 0.0
        for entry in entries {
            sumX += entry.point.x
            sumY += entry.point.y
        }
        let n = Double(entries.count)
        return CGPoint(x: sumX / n, y: sumY / n)
    }

    /// Fits the dominant direction of `entries` around `mean` and resolves
    /// its sign — see type doc "Sign" and "Degenerate windows" for the
    /// reasoning behind both halves of this function. `self.axisDirection`
    /// is read (as "the previous axis") but not written here; the caller
    /// (`observe`) commits the result.
    private func fitAxis(entries: [WindowEntry], mean: CGPoint) -> CGVector {
        // Covariance matrix [[sxx, sxy], [sxy, syy]] of the centred window
        // points — a plain, unweighted second moment. (Interpolated points
        // do contribute to this fit, unweighted by their lower confidence:
        // `PlateTracker` caps a bridged run at 5 consecutive frames, a
        // small fraction of a multi-hundred-entry window, so weighting
        // would not materially change the fit — leaving it out keeps this
        // function simpler without a real accuracy cost.)
        var sxx = 0.0
        var syy = 0.0
        var sxy = 0.0
        for entry in entries {
            let dx = entry.point.x - mean.x
            let dy = entry.point.y - mean.y
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        let n = Double(entries.count)
        sxx /= n
        syy /= n
        sxy /= n

        let totalVariance = sxx + syy
        guard totalVariance.isFinite, totalVariance > Self.degenerateVarianceEpsilonMetresSquared else {
            // No dominant direction to recover (SPEC / this task item 7's
            // "degenerate input... stationary plate with no dominant
            // direction" case). Hold the last resolved axis for
            // continuity; if there's never been one, the one-time
            // image-up fallback is the only deterministic choice
            // available with zero information.
            return axisDirection ?? Self.imageUpUnitVector
        }

        // Closed-form symmetric 2x2 eigen-decomposition — same
        // mean/half-difference/radius shape as `EllipseFit
        // .ellipseParameters`'s 2x2 sub-step, specialised to a covariance
        // matrix instead of a conic's quadratic-form matrix. The larger
        // eigenvalue's eigenvector (`theta`) is the dominant — first
        // principal component — direction; the smaller one (unused here
        // beyond this comment) is the `lateral` axis's direction.
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        var candidate = CGVector(dx: cos(theta), dy: sin(theta))

        if let previous = axisDirection {
            // Stability: pick whichever of the two sign choices agrees
            // with last frame's resolved axis, so a numerically arbitrary
            // eigenvector-sign flip in the solver never surfaces as a
            // flip in the emitted signal (SPEC / this task item 3).
            let alignment = candidate.dx * previous.dx + candidate.dy * previous.dy
            if alignment < 0 {
                candidate = CGVector(dx: -candidate.dx, dy: -candidate.dy)
            }
        } else {
            // Bootstrap, once: orient so "up" in image space (negative y)
            // is positive — see type doc "Sign" for why this is a sign
            // tie-break on an already-fitted line, not an assumption about
            // the line's direction.
            if candidate.dy > 0 {
                candidate = CGVector(dx: -candidate.dx, dy: -candidate.dy)
            }
        }
        return candidate
    }
}

// MARK: - RepSignal integration

extension RepSignal {
    /// Appends one `MotionAxis.Result` as at most one `Sample` (SPEC §6,
    /// §8; W2-04 item 7: "Emit into `RepSignal` with `ScaleSource
    /// .plateDiameter`" — the caller constructing this `RepSignal` is
    /// responsible for that `scale`, fixed at `init`; this method only
    /// appends samples to it).
    ///
    /// `.projected` becomes one `Sample`, using `axial` — never `lateral`,
    /// which is bar-path deviation and must not reach the counter (item
    /// 4); there is no overload here that reads `lateral` at all, so that
    /// is enforced by the type signature, not by caller discipline.
    ///
    /// `.gap` appends nothing. That is the entire mechanism behind "a gap
    /// is a gap, not a fabricated zero" (item 6): there is no code path
    /// from `.gap` to a call of `append(t:x:confidence:)`.
    public mutating func append(_ result: MotionAxis.Result) {
        guard case .projected(let projection) = result else { return }
        append(t: projection.t, x: projection.axial, confidence: projection.confidence)
    }
}
