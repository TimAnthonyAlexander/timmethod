import CoreGraphics
import CoreVideo
import Foundation

/// Follows the plate `PlateDetector` finds, frame to frame (SPEC §8:
/// "Detect on frame 1, then track by local search around the previous
/// centroid with periodic full re-detection ... When the plate is briefly
/// hidden ... interpolate up to 5 frames, then declare loss").
///
/// ## Shape
///
/// A plain value-type state machine: `Configuration` in, one `FrameResult`
/// out per `processFrame` call, with all mutable state (`phase`,
/// `framesSinceFullDetect`, `lastFrameTimestamp`) held in `var` properties
/// of the struct itself — no class, no actor, no shared mutable state
/// hidden behind a reference. Two `PlateTracker`s constructed from the same
/// `Configuration` and fed the same frames in the same order always produce
/// the same results (`PlateTrackerTests`'s determinism test), because there
/// is nothing else that could make them differ.
///
/// ## Causal, not clairvoyant
///
/// This consumes frames **one at a time, in capture order**, exactly the
/// shape the live pipeline hands it (SPEC §4.4: `CaptureActor` yields one
/// `TimedFrame` at a time over an `AsyncStream`). It never looks ahead. So
/// "interpolate through an occlusion" cannot mean the textbook two-sided
/// interpolation between a point before *and* a point after the gap — the
/// point after doesn't exist yet when frame 2 of a 3-frame occlusion is
/// being processed. What it means here is dead-reckoning: project forward
/// from the last measured position using the last measured velocity, for
/// up to `Configuration.maxInterpolatedFrames` frames, with confidence
/// decaying every frame it isn't corrected by a real measurement. That
/// projection is explicitly capped — see `FrameResult.lost` and
/// `predictedObservation` — because an uncapped version of exactly this
/// technique is what turns a hidden plate into a fabricated rep.
///
/// ## What "local search" actually does
///
/// `PlateDetector.detect(in:)` has no notion of a region of interest — it
/// always scans the whole buffer it's given, using `previousCenter` only as
/// a *tie-break* when more than one candidate survives, not as a search
/// bound. So "local search" here means physically cropping the source
/// `CVPixelBuffer` to a small window around the last known/predicted
/// centroid (`croppedPixelBuffer`) before handing it to the detector —
/// this is what actually makes it cheaper than a full-frame pass (SPEC
/// §8: "Cheap"), and what makes it structurally unable to lock onto a
/// second plate-shaped object elsewhere in frame, rather than merely being
/// discouraged from doing so by a scoring bonus.
public struct PlateTracker: Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable, Equatable {
        /// Passed straight through to the internal `PlateDetector` used
        /// for both the full-frame and local-search passes. A crop doesn't
        /// change pixel scale (see `croppedPixelBuffer` — it copies, never
        /// resizes), so the same expected-radius range is valid for both.
        public var detectorConfiguration: PlateDetector.Configuration

        /// The real diameter Track A assumes for the tracked plate (SPEC
        /// §8), used **only** to turn `maxBarVelocityMetresPerSecond` into
        /// a pixel search radius (`searchRadiusPx`) — this tracker does not
        /// otherwise deal in metres, emit a `RepSignal`, or build the
        /// metric scale (that's `MetricScale`, W2-02, a different file).
        public var plateConfiguration: PlateConfiguration

        /// Plausible ceiling on concentric bar velocity, m/s, used to size
        /// the local-search radius (`searchRadiusPx`). See that function's
        /// doc comment for the full derivation and literature basis; 2.5
        /// m/s sits comfortably above reported concentric velocities for
        /// near-maximal and fast sub-maximal barbell work.
        public var maxBarVelocityMetresPerSecond: Double

        /// Multiplier applied on top of the raw velocity-implied radius,
        /// covering frame-delivery jitter and the fact
        /// `maxBarVelocityMetresPerSecond` is an assumed ceiling, not a
        /// per-set measurement. See `searchRadiusPx`.
        public var searchMarginMultiplier: Double

        /// Force a full-frame detection at least this often, regardless of
        /// whether local search is succeeding, so accumulated local-search
        /// drift gets corrected before it compounds (SPEC §8's "periodic
        /// full re-detection"). 30 frames is roughly 1s at a typical 30fps
        /// capture — frequent relative to a rep's concentric/eccentric
        /// half-cycle (SPEC §7.2: order of a second or more), so it can
        /// never itself be mistaken for missing a whole rep's motion, and
        /// infrequent enough that most frames still get the cheaper
        /// local-search path.
        public var redetectionIntervalFrames: Int

        /// How many consecutive frames without a detection are bridged by
        /// prediction before tracking is declared lost. Fixed at 5 by SPEC
        /// §8 and this task, matching the pose-landmark dropout precedent
        /// (SPEC §7.1) — same principle (a brief real occlusion is
        /// routine, not exceptional), different signal. Left configurable
        /// (rather than a bare constant) because it's exactly the kind of
        /// number an eval run against real footage (W2-06) may need to
        /// retune; the default is what SPEC and this task specify.
        public var maxInterpolatedFrames: Int

        /// Assumed inter-frame interval, seconds, used only for the very
        /// first frame (there is no previous timestamp yet to derive a
        /// real one from) and as a fallback if two consecutive timestamps
        /// are non-monotonic. 1/30s: a conservative (i.e. larger, so the
        /// resulting search radius is more generous, not less) assumption
        /// than the 60fps ceiling SPEC §16 allows for.
        public var assumedFrameIntervalSeconds: Double

        /// Upper bound on the `dt` fed into `searchRadiusPx`, seconds. An
        /// unusually long gap between frames (a dropped frame, the app
        /// resuming) would otherwise balloon the local-search crop back up
        /// toward full-frame size, defeating the reason local search
        /// exists; capping `dt` here keeps the crop bounded. Correctness
        /// in that scenario still comes from `croppedPixelBuffer`'s
        /// full-frame fallback and periodic re-detection, not from this
        /// cap growing without limit.
        public var maxAssumedFrameGapSeconds: Double

        public init(
            detectorConfiguration: PlateDetector.Configuration,
            plateConfiguration: PlateConfiguration,
            maxBarVelocityMetresPerSecond: Double = PlateTracker.defaultMaxBarVelocityMetresPerSecond,
            searchMarginMultiplier: Double = PlateTracker.defaultSearchMarginMultiplier,
            redetectionIntervalFrames: Int = PlateTracker.defaultRedetectionIntervalFrames,
            maxInterpolatedFrames: Int = PlateTracker.defaultMaxInterpolatedFrames,
            assumedFrameIntervalSeconds: Double = PlateTracker.defaultAssumedFrameIntervalSeconds,
            maxAssumedFrameGapSeconds: Double = PlateTracker.defaultMaxAssumedFrameGapSeconds
        ) {
            precondition(
                maxBarVelocityMetresPerSecond.isFinite && maxBarVelocityMetresPerSecond > 0,
                "PlateTracker.Configuration.maxBarVelocityMetresPerSecond must be finite and positive"
            )
            precondition(
                searchMarginMultiplier.isFinite && searchMarginMultiplier >= 1,
                "PlateTracker.Configuration.searchMarginMultiplier must be finite and >= 1"
            )
            precondition(
                redetectionIntervalFrames > 0,
                "PlateTracker.Configuration.redetectionIntervalFrames must be positive"
            )
            precondition(
                maxInterpolatedFrames >= 0,
                "PlateTracker.Configuration.maxInterpolatedFrames must be >= 0"
            )
            precondition(
                assumedFrameIntervalSeconds.isFinite && assumedFrameIntervalSeconds > 0,
                "PlateTracker.Configuration.assumedFrameIntervalSeconds must be finite and positive"
            )
            precondition(
                maxAssumedFrameGapSeconds.isFinite && maxAssumedFrameGapSeconds >= assumedFrameIntervalSeconds,
                "PlateTracker.Configuration.maxAssumedFrameGapSeconds must be finite and >= assumedFrameIntervalSeconds"
            )
            self.detectorConfiguration = detectorConfiguration
            self.plateConfiguration = plateConfiguration
            self.maxBarVelocityMetresPerSecond = maxBarVelocityMetresPerSecond
            self.searchMarginMultiplier = searchMarginMultiplier
            self.redetectionIntervalFrames = redetectionIntervalFrames
            self.maxInterpolatedFrames = maxInterpolatedFrames
            self.assumedFrameIntervalSeconds = assumedFrameIntervalSeconds
            self.maxAssumedFrameGapSeconds = maxAssumedFrameGapSeconds
        }
    }

    /// See `Configuration.maxBarVelocityMetresPerSecond`'s doc and
    /// `searchRadiusPx`'s full derivation.
    public static let defaultMaxBarVelocityMetresPerSecond: Double = 2.5
    /// See `Configuration.searchMarginMultiplier`'s doc.
    public static let defaultSearchMarginMultiplier: Double = 1.5
    /// See `Configuration.redetectionIntervalFrames`'s doc.
    public static let defaultRedetectionIntervalFrames: Int = 30
    /// SPEC §8 / this task: fixed at 5.
    public static let defaultMaxInterpolatedFrames: Int = 5
    /// See `Configuration.assumedFrameIntervalSeconds`'s doc.
    public static let defaultAssumedFrameIntervalSeconds: Double = 1.0 / 30.0
    /// See `Configuration.maxAssumedFrameGapSeconds`'s doc.
    public static let defaultMaxAssumedFrameGapSeconds: Double = 0.5

    // MARK: - Per-frame output

    /// One frame's tracking outcome. Deliberately three cases, not a
    /// `PlateObservation?` with a side flag — a consumer pattern-matching
    /// this cannot accidentally treat a bridged frame as a real
    /// measurement, or a lost frame as either (SPEC §8 / this task: "a
    /// consumer has to be able to tell a real observation from a bridged
    /// one").
    public enum FrameResult: Sendable, Equatable {
        /// The plate was actually detected this frame (a fresh Vision
        /// measurement, whether via local search or a full-frame pass).
        case measured(PlateObservation)

        /// Not detected this frame, but bridged by prediction — see
        /// `TrackedObservation`. Never emitted for more than
        /// `Configuration.maxInterpolatedFrames` consecutive frames.
        case interpolated(TrackedObservation)

        /// Occlusion exceeded the interpolation window, or a full
        /// re-detection attempt found nothing. No centroid is carried —
        /// there is deliberately nothing here a caller could mistake for a
        /// position (SPEC §8 / this task: "on loss, freeze rather than
        /// guess"; "a silently wrong number is the worst failure this app
        /// has").
        case lost

        /// The centroid, pixel space, for `.measured` and `.interpolated`;
        /// `nil` for `.lost`. Convenience for a caller that only cares
        /// about position, not provenance.
        public var center: CGPoint? {
            switch self {
            case .measured(let observation): observation.center
            case .interpolated(let tracked): tracked.center
            case .lost: nil
            }
        }

        /// Per-frame tracking confidence, `0...1`, the counter gates on
        /// (SPEC §8 / this task item 4). `.measured` reports the
        /// detector's own fit confidence; `.interpolated` reports the
        /// decayed value described on `TrackedObservation.confidence`;
        /// `.lost` is `nil` — there is no confidence in a value that
        /// doesn't exist.
        public var trackingConfidence: Double? {
            switch self {
            case .measured(let observation): observation.confidence
            case .interpolated(let tracked): tracked.confidence
            case .lost: nil
            }
        }

        public var isMeasured: Bool { if case .measured = self { true } else { false } }
        public var isInterpolated: Bool { if case .interpolated = self { true } else { false } }
        public var isLost: Bool { if case .lost = self { true } else { false } }
    }

    /// A bridged (predicted, not measured) frame's projected state.
    /// Distinguished from `PlateObservation` as its own type, not reused
    /// with a flag, specifically so an interpolated frame can never be
    /// silently accepted anywhere a real `PlateObservation` is expected —
    /// the two types are not interchangeable without a caller explicitly
    /// choosing to unwrap `FrameResult.interpolated`.
    public struct TrackedObservation: Sendable, Equatable {
        /// Projected centroid: last measured centre plus last measured
        /// velocity times elapsed time since that measurement. Never
        /// extrapolated past `Configuration.maxInterpolatedFrames` frames —
        /// beyond that this type is never constructed; `FrameResult.lost`
        /// is emitted instead.
        public let center: CGPoint
        /// Held constant from the last real measurement — there is no
        /// principled way to extrapolate size from a hidden plate, and
        /// `PlateTracker` never tries.
        public let majorAxisPx: Double
        public let minorAxisPx: Double
        public let orientation: Double
        /// Decayed tracking confidence — see `predictedObservation` for
        /// the decay curve. Strictly less than the confidence of the
        /// measurement it's projected from, and decreases every additional
        /// frame the gap continues, so a consumer gating on confidence
        /// naturally trusts a bridged frame less the longer the bridge.
        public let confidence: Double
        /// How many consecutive frames (including this one) since the last
        /// real measurement. Always in `1...Configuration
        /// .maxInterpolatedFrames`.
        public let framesSinceMeasurement: Int

        public init(
            center: CGPoint, majorAxisPx: Double, minorAxisPx: Double, orientation: Double, confidence: Double,
            framesSinceMeasurement: Int
        ) {
            precondition(
                majorAxisPx.isFinite && minorAxisPx.isFinite && majorAxisPx >= minorAxisPx && minorAxisPx > 0,
                "TrackedObservation requires 0 < minorAxisPx <= majorAxisPx, both finite"
            )
            precondition(
                confidence.isFinite && (0...1).contains(confidence),
                "TrackedObservation.confidence must be finite and in 0...1"
            )
            precondition(framesSinceMeasurement > 0, "TrackedObservation.framesSinceMeasurement must be positive")
            self.center = center
            self.majorAxisPx = majorAxisPx
            self.minorAxisPx = minorAxisPx
            self.orientation = orientation
            self.confidence = confidence
            self.framesSinceMeasurement = framesSinceMeasurement
        }
    }

    // MARK: - Internal state

    /// What's carried forward from the last real measurement — enough to
    /// anchor a local search and to dead-reckon through an occlusion.
    /// Never holds anything derived from a prediction: `center` /
    /// `velocity*` are only ever written from an actual `PlateObservation`
    /// (`makeLock`), so a chain of interpolated frames can never drift the
    /// lock itself — only `FrameResult.interpolated`'s own `center`
    /// (computed fresh each frame from this unchanging lock) moves.
    private struct Lock: Sendable, Equatable {
        var center: CGPoint
        var majorAxisPx: Double
        var minorAxisPx: Double
        var orientation: Double
        var measuredConfidence: Double
        /// Pixels/second, computed from the two most recent *measured*
        /// centres — never from an interpolated one, so a compounding
        /// prediction error can't feed back into the velocity used to
        /// produce further predictions.
        var velocityXPxPerSecond: Double
        var velocityYPxPerSecond: Double
        var lastMeasuredTimestamp: TimeInterval
    }

    private enum Phase: Sendable, Equatable {
        /// Never yet locked onto anything.
        case initial
        /// Currently tracking; last frame was a real measurement.
        case tracking(Lock)
        /// Currently bridging an occlusion; `framesLost` frames have
        /// passed (inclusive) since the last real measurement, and it's
        /// `<= Configuration.maxInterpolatedFrames`.
        case occluded(Lock, framesLost: Int)
        /// Occlusion exceeded the window, or a full re-detection attempt
        /// found nothing. The next frame always attempts a full-frame
        /// re-detection (SPEC §8: "always after a loss") — there is no
        /// stale centroid left here for a local search to anchor to.
        case lost

        var lock: Lock? {
            switch self {
            case .tracking(let lock): lock
            case .occluded(let lock, _): lock
            case .initial, .lost: nil
            }
        }
    }

    public let configuration: Configuration
    private let detector: PlateDetector

    private var phase: Phase = .initial
    /// Frames since the last *full-frame* detection specifically (not
    /// since the last successful local search) — this is what
    /// `Configuration.redetectionIntervalFrames` counts against, so the
    /// periodic-re-detection cadence is fixed regardless of how well local
    /// search happens to be doing.
    private var framesSinceFullDetect: Int = 0
    private var lastFrameTimestamp: TimeInterval?

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.detector = PlateDetector(configuration: configuration.detectorConfiguration)
    }

    // MARK: - Per-frame entry point

    /// Advances the tracker by one frame and returns that frame's result.
    /// `timestamp` is capture time, seconds, same clock as `RepSignal
    /// .Sample.t` and the frame source (SPEC §4.4) — plain `TimeInterval`
    /// rather than `CMTime` so this file (like `PlateDetector`) has no
    /// `CoreMedia`/`AVFoundation` dependency; a caller on the live
    /// `TimedFrame` path converts `timestamp.seconds` once at the call
    /// site.
    public mutating func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> FrameResult {
        let dt = frameIntervalSeconds(currentTimestamp: timestamp)
        framesSinceFullDetect += 1
        let lock = phase.lock

        // Whether the *immediately preceding* processed frame was itself a
        // real, uninterrupted measurement — see `makeLock`'s doc for why
        // this (not merely "is there a previous lock at all") is what
        // gates velocity computation.
        let wasContinuouslyTracking: Bool = { if case .tracking = phase { true } else { false } }()

        let observation: PlateObservation?
        if let lock, framesSinceFullDetect < configuration.redetectionIntervalFrames {
            observation = localSearch(pixelBuffer, lock: lock, timestamp: timestamp, dt: dt)
        } else {
            // Either never locked / just lost (SPEC §8: "always after a
            // loss"), or the periodic cadence forces a full pass this
            // frame regardless of local search's own odds — the whole
            // point of a scheduled re-detection is that it doesn't wait to
            // be asked.
            framesSinceFullDetect = 0
            observation = detector.detect(in: pixelBuffer, previousCenter: lock?.center)
        }

        if let observation {
            phase = .tracking(
                makeLock(
                    from: observation, previous: lock, timestamp: timestamp,
                    previousWasContinuous: wasContinuouslyTracking
                )
            )
            return .measured(observation)
        }

        // Nothing found this frame.
        guard let lock else {
            // Nothing to bridge from — never locked, or already lost.
            phase = .lost
            return .lost
        }

        let framesLost: Int =
            if case .occluded(_, let previous) = phase { previous + 1 } else { 1 }

        guard framesLost <= configuration.maxInterpolatedFrames else {
            // Freeze rather than guess: past the window, this is a loss,
            // full stop — no further prediction, no centroid.
            phase = .lost
            return .lost
        }

        phase = .occluded(lock, framesLost: framesLost)
        return .interpolated(predictedObservation(lock: lock, timestamp: timestamp, framesLost: framesLost))
    }

    // MARK: - Timing

    private mutating func frameIntervalSeconds(currentTimestamp: TimeInterval) -> TimeInterval {
        defer { lastFrameTimestamp = currentTimestamp }
        guard let last = lastFrameTimestamp else { return configuration.assumedFrameIntervalSeconds }
        let dt = currentTimestamp - last
        guard dt.isFinite, dt > 0 else { return configuration.assumedFrameIntervalSeconds }
        return dt
    }

    // MARK: - Lock / prediction

    /// `previousWasContinuous` gates velocity computation deliberately: it
    /// is only trustworthy between two *consecutive* real measurements of
    /// (presumably) the same object. If the previous frame was itself
    /// bridged by interpolation or recovered by a periodic/loss
    /// re-detection, `previous.center` may be several frames stale, or —
    /// in the periodic-re-detection-corrects-a-bad-lock case — an entirely
    /// different object's position. Dividing that displacement by the
    /// elapsed gap would produce a velocity that is not a measurement of
    /// anything real, and `predictedCenter` would then extrapolate it
    /// straight into the next occlusion or search-radius calculation.
    /// Safer default: velocity resets to zero (hold position, no motion
    /// assumed) until two genuinely back-to-back measurements re-establish
    /// it. A real occlusion bridged mid-motion is unaffected by this — the
    /// velocity used to predict *through* the gap was already computed
    /// cleanly, before the gap started; this only concerns the *new* lock
    /// formed once a measurement lands again.
    private func makeLock(
        from observation: PlateObservation, previous: Lock?, timestamp: TimeInterval, previousWasContinuous: Bool
    ) -> Lock {
        var velocityX = 0.0
        var velocityY = 0.0
        if previousWasContinuous, let previous {
            let dt = timestamp - previous.lastMeasuredTimestamp
            if dt.isFinite, dt > 0 {
                velocityX = (observation.center.x - previous.center.x) / dt
                velocityY = (observation.center.y - previous.center.y) / dt
            }
        }
        return Lock(
            center: observation.center,
            majorAxisPx: observation.majorAxisPx,
            minorAxisPx: observation.minorAxisPx,
            orientation: observation.orientation,
            measuredConfidence: observation.confidence,
            velocityXPxPerSecond: velocityX,
            velocityYPxPerSecond: velocityY,
            lastMeasuredTimestamp: timestamp
        )
    }

    /// Dead-reckoned centre at `timestamp`: last measured centre plus last
    /// measured velocity times elapsed time since that measurement.
    private func predictedCenter(lock: Lock, timestamp: TimeInterval) -> CGPoint {
        let dt = timestamp - lock.lastMeasuredTimestamp
        guard dt.isFinite, dt > 0 else { return lock.center }
        return CGPoint(
            x: lock.center.x + lock.velocityXPxPerSecond * dt,
            y: lock.center.y + lock.velocityYPxPerSecond * dt
        )
    }

    /// `framesLost` is `1...Configuration.maxInterpolatedFrames` by the
    /// time this is called (the caller already checked). Confidence decays
    /// linearly from the last measured confidence toward (but never
    /// reaching) zero across the window: at `framesLost == N` (the last
    /// tolerated frame, `N == maxInterpolatedFrames`), the factor is
    /// `1/(N+1)` — small, but still a real, nonzero, distinguishable
    /// number, never silently equal to a fresh measurement's confidence
    /// (SPEC §8 / this task: "interpolated confidence should decay across
    /// the gap rather than sitting at full").
    private func predictedObservation(lock: Lock, timestamp: TimeInterval, framesLost: Int) -> TrackedObservation {
        let center = predictedCenter(lock: lock, timestamp: timestamp)
        let decayFactor = 1.0 - Double(framesLost) / Double(configuration.maxInterpolatedFrames + 1)
        let confidence = max(0, min(1, lock.measuredConfidence * decayFactor))
        return TrackedObservation(
            center: center,
            majorAxisPx: lock.majorAxisPx,
            minorAxisPx: lock.minorAxisPx,
            orientation: lock.orientation,
            confidence: confidence,
            framesSinceMeasurement: framesLost
        )
    }

    // MARK: - Local search

    private func localSearch(_ pixelBuffer: CVPixelBuffer, lock: Lock, timestamp: TimeInterval, dt: TimeInterval)
        -> PlateObservation?
    {
        let anchor = predictedCenter(lock: lock, timestamp: timestamp)
        let radius = searchRadiusPx(lastMajorAxisPx: lock.majorAxisPx, dt: dt)
        let searchRect = CGRect(x: anchor.x - radius, y: anchor.y - radius, width: radius * 2, height: radius * 2)

        guard let (cropBuffer, origin) = croppedPixelBuffer(from: pixelBuffer, rectPixelSpace: searchRect) else {
            // The anchor sits close enough to a frame edge (or the buffer
            // itself is smaller than the search window) that clamping
            // leaves nothing usable to crop. Fall back to a full-frame
            // pass for this one frame rather than forfeit its chance to
            // (re)acquire — this does not reset `framesSinceFullDetect`,
            // it's an edge-case fallback, not the scheduled periodic pass.
            return detector.detect(in: pixelBuffer, previousCenter: anchor)
        }

        let localAnchor = CGPoint(x: anchor.x - origin.x, y: anchor.y - origin.y)
        guard let local = detector.detect(in: cropBuffer, previousCenter: localAnchor) else { return nil }
        return PlateObservation(
            center: CGPoint(x: local.center.x + origin.x, y: local.center.y + origin.y),
            majorAxisPx: local.majorAxisPx,
            minorAxisPx: local.minorAxisPx,
            orientation: local.orientation,
            confidence: local.confidence
        )
    }

    /// The half-width (radius, pixels) of the local-search crop around the
    /// last known/predicted centroid — the whole reason item 1 of this
    /// task exists: not a magic pixel constant, derived.
    ///
    /// **Velocity ceiling.** The number this project actually needs a
    /// bound for is *concentric* bar velocity — the direction a tracked
    /// plate can move fastest between two frames. Reported concentric
    /// velocities for barbell work sit under roughly 1-2 m/s even for
    /// near-maximal to fast sub-maximal reps (the same velocity-based
    /// training literature SPEC §8.1 draws its VL→RIR mapping from).
    /// `Configuration.maxBarVelocityMetresPerSecond` defaults to 2.5 m/s —
    /// already above that range on its own — and `searchMarginMultiplier`
    /// (1.5x default) adds further headroom for frame-delivery jitter (the
    /// true gap between two frames is never exactly `1/fps`) and for the
    /// fact this is an assumed ceiling, not a per-set measurement. The
    /// effective working ceiling is therefore close to 3.75 m/s — still a
    /// small fraction of a typical frame, so the crop stays meaningfully
    /// "local".
    ///
    /// **Metres to pixels, through the observed plate, not a resolution
    /// assumption.** SPEC §8's own scale formula — `pixels_per_metre =
    /// major_axis_px / plate_diameter_m` (`PlateScale.pixelsPerMetre`) —
    /// converts the velocity ceiling using the plate's *last known*
    /// `majorAxisPx` and the configured real diameter. A lifter framed
    /// close to the camera (large `majorAxisPx`) gets a larger pixel
    /// radius for the same physical velocity than one framed further back;
    /// a fixed pixel constant could never track that, and would either be
    /// too tight at close range or too loose (and no longer "local") at
    /// long range.
    ///
    /// **Time, through the actual frame interval, not an assumed frame
    /// rate.** `dt` comes from consecutive real frame timestamps
    /// (`frameIntervalSeconds`), clamped to
    /// `Configuration.maxAssumedFrameGapSeconds` so one unusually long gap
    /// can't balloon the crop toward full-frame size. At 60fps `dt` is
    /// half what it is at 30fps, so the resulting radius is automatically
    /// half as large too — no separate frame-rate branch anywhere in this
    /// file.
    ///
    /// Finally, the plate's own last known radius (`lastMajorAxisPx / 2`)
    /// is added unconditionally: even a plate that hasn't moved at all
    /// needs to fit inside the crop.
    private func searchRadiusPx(lastMajorAxisPx: Double, dt: TimeInterval) -> Double {
        let clampedDt = min(max(dt, 0), configuration.maxAssumedFrameGapSeconds)
        // `?? 0` is unreachable in practice: `lastMajorAxisPx` always comes
        // from a real `PlateObservation` (precondition-enforced positive
        // and finite) and `plateConfiguration.millimetres` is validated
        // positive and finite by `PlateConfigurationCatalog.set` /
        // `PlateConfiguration.isPlausible` upstream of this type. Kept as
        // a fallback of "no motion allowance" rather than a crash if that
        // invariant were ever violated — an honest degenerate case, not a
        // fabricated one.
        let pixelsPerMetre =
            PlateScale.pixelsPerMetre(majorAxisPx: lastMajorAxisPx, diameterMm: configuration.plateConfiguration.millimetres)
            ?? 0
        let motionRadiusPx =
            configuration.maxBarVelocityMetresPerSecond * clampedDt * pixelsPerMetre
            * configuration.searchMarginMultiplier
        return lastMajorAxisPx / 2 + motionRadiusPx
    }

    // MARK: - Cropping

    /// Smallest crop dimension, pixels, `croppedPixelBuffer` will produce.
    /// Below this a crop is not a meaningful search window (too few pixels
    /// for `PlateDetector`'s own `minimumContourPoints` gate to ever pass),
    /// so `croppedPixelBuffer` refuses rather than hand back a buffer that
    /// can never succeed.
    private static let minimumCropDimensionPx = 8

    /// Crops `pixelBuffer` to `rectPixelSpace` (top-left origin, y-down —
    /// this codebase's pixel-space convention, matching `PlateObservation
    /// .center`), clamped to the buffer's own bounds, and copies the
    /// result into a new, correspondingly-sized `CVPixelBuffer`. This is a
    /// real crop-and-copy, not a bounding-box filter over full-frame
    /// results — it's what makes local search actually cheaper than a
    /// full-frame `PlateDetector` pass (SPEC §8: "Cheap"), since
    /// `PlateDetector` runs its real Vision contour pass over whatever
    /// buffer it's handed.
    ///
    /// Implemented as a direct row-by-row `memcpy` between the two
    /// buffers' raw `32BGRA` planes, deliberately **not** a Core Image
    /// `render(_:to:bounds:colorSpace:)` pass: that API's `bounds`
    /// parameter did not crop as documented when exercised against a
    /// `CVPixelBuffer` destination smaller than the source in isolated
    /// testing during this task (every sub-region came back blank,
    /// including trivial origin-anchored cases with no offset and no flip
    /// question at all) — a real, reproducible framework quirk, not a
    /// one-off. A raw scanline copy has no coordinate-system ambiguity to
    /// get wrong: both buffers are the same pixel format, so "top-left
    /// origin, y-down" means the exact same thing on both sides, and this
    /// function copies `cropHeight` rows of `cropWidth * 4` bytes each,
    /// full stop.
    ///
    /// Returns `nil` — never a partial or degenerate crop — when the
    /// requested rectangle doesn't leave a usable region (e.g. the search
    /// window is centred close enough to a frame edge that clamping
    /// collapses a dimension below `minimumCropDimensionPx`), or when
    /// `pixelBuffer` isn't `32BGRA` (the one format this codebase's
    /// capture and synthetic-test pipelines produce, SPEC §4.2). Callers
    /// fall back to a full-frame detect in either case (see
    /// `localSearch`).
    private func croppedPixelBuffer(
        from pixelBuffer: CVPixelBuffer, rectPixelSpace: CGRect
    ) -> (buffer: CVPixelBuffer, origin: CGPoint)? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let clamped = rectPixelSpace.intersection(bounds)
        guard !clamped.isNull, !clamped.isEmpty else { return nil }

        let originX = Int(clamped.origin.x.rounded(.down))
        let originY = Int(clamped.origin.y.rounded(.down))
        let cropWidth = Int(clamped.maxX.rounded(.up)) - originX
        let cropHeight = Int(clamped.maxY.rounded(.up)) - originY
        guard
            cropWidth >= Self.minimumCropDimensionPx, cropHeight >= Self.minimumCropDimensionPx,
            originX >= 0, originY >= 0, originX + cropWidth <= width, originY + cropHeight <= height
        else { return nil }

        var output: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, cropWidth, cropHeight, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &output
        )
        guard status == kCVReturnSuccess, let outputBuffer = output else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outputBuffer, [])
        }
        guard
            let sourceBase = CVPixelBufferGetBaseAddress(pixelBuffer),
            let destinationBase = CVPixelBufferGetBaseAddress(outputBuffer)
        else { return nil }

        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        let bytesPerPixel = 4
        let rowByteCount = cropWidth * bytesPerPixel
        for row in 0..<cropHeight {
            let sourceRow = sourceBase.advanced(by: (originY + row) * sourceBytesPerRow + originX * bytesPerPixel)
            let destinationRow = destinationBase.advanced(by: row * destinationBytesPerRow)
            memcpy(destinationRow, sourceRow, rowByteCount)
        }

        return (outputBuffer, CGPoint(x: Double(originX), y: Double(originY)))
    }
}
