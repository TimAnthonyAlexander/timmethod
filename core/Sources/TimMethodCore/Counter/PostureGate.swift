import Foundation

/// Refuses to let the counter (W3-02/W3-03) count outside a genuine lift
/// (SPEC §7.1: "Confidence is not the same question as 'is this person doing
/// the exercise.'"). Standing up, walking to the rack, and lying down all
/// sweep the same signal range a real rep does; without this gate the
/// counter fires during setup and the first thing a lifter sees is a broken
/// number.
///
/// ## The Track A / Track B split — read this before extending the type
///
/// SPEC §7.1 names two families of cue:
///
/// 1. **Pose cues** — torso orientation relative to gravity (the primary
///    cue) and a coarse landmark layout check. Both need a skeleton, and
///    `PoseProvider` (SPEC §4.1) does not exist until Wave 5.
/// 2. **Track A cues** (SPEC §7.1's "for Track A without pose") — plate
///    presence, a plausible plate height range, and stationarity of the
///    non-working axis. All three are available today from `PlateTracker`
///    (W2-01/03) and `MotionAxis` (W2-04).
///
/// This file implements (2) **completely** and defines the seam (1) plugs
/// into — `PoseCueContribution` and `FrameInput.pose` — with **no
/// conforming producer**. That is deliberate, not an oversight: SPEC §16's
/// thermal ladder runs the plate track with pose off under
/// `.serious`/`.critical` load ("plate track alone still counts"), so a gate
/// that only works with pose attached would leave the counter ungated
/// exactly when thermal throttling makes it matter most. `advance(_:t:)`
/// with `FrameInput.pose == nil` is a complete, real, standalone gate, not a
/// degraded stand-in for one that needs pose to function. Nothing here
/// synthesizes a pose score, defaults one to "always passes", or otherwise
/// gives the appearance of a working pose path — the seam exists so Wave 5
/// has one call site to fill in (`FrameInput.pose`), not so this task can
/// pretend to have built it.
///
/// ## Track A cues, and why each one
///
/// - **Plate presence.** If `PlateTracker` isn't tracking anything this
///   frame (`FrameInput.plateTracked == false` — the caller's translation of
///   `PlateTracker.FrameResult.lost` / `MotionAxis.Observation.lost`), there
///   is nothing to gate on: closed, `.noPlateTracked`. Brief occlusions
///   don't reach here at all — `PlateTracker` already bridges up to 5 frames
///   as `.interpolated` (still `plateTracked == true`), so this gate isn't
///   re-litigating that debounce.
/// - **Plausible plate height range.** The one physical scale Track A has
///   without calibration (W3-04 doesn't exist yet either) is the plate's own
///   diameter (SPEC §8). This gate tracks a slow exponential-moving-average
///   baseline of the axial (working-axis) position and requires each
///   frame's *deviation* from that baseline to stay within a band expressed
///   as a multiple of plate diameter — see `defaultOpenHeightDeviationMultiplier`
///   for the derivation. A real rep oscillates around a stable neutral
///   position (the rack height, the floor); racking, unracking from a high
///   shelf, or carrying the plate to a different height all show up as
///   sustained deviation from that baseline.
/// - **Stationarity of the non-working axis.** `MotionAxis.Projection
///   .lateral` is the bar-path deviation SPEC §8 documents as "a real
///   output" that "must never reach the counter" directly — here it is read
///   only as a magnitude, never as a signed displacement, and never
///   forwarded anywhere near `RepSignal`. This gate tracks the recent range
///   (max − min) of `lateral` over a short window and requires it to stay
///   small, again as a multiple of plate diameter. A controlled lift keeps
///   the bar close to one vertical plane; someone walking past the camera
///   translates the plate laterally by more than a plate diameter within a
///   second, which is exactly the "walking past the camera" fixture this
///   task's Done-when targets.
///
/// ## Hysteresis and dwell
///
/// Both height and lateral cues carry **separate open and close limits**
/// (the close limit is always the looser one), and the gate as a whole
/// tracks **elapsed time**, not frame count, in the currently-failing (to
/// close) or currently-passing (to open) direction before it actually
/// flips `State`. Time, not frames, for the same reason `MotionAxis
/// .Configuration.windowDurationSeconds` is time-based (SPEC §16: capture
/// runs 30–60 fps depending on thermal state, so a frame-count dwell would
/// silently mean half as much real time at 60 fps as at 30 fps). See
/// `defaultOpenDwellSeconds` / `defaultCloseDwellSeconds` for the numbers
/// and their justification.
///
/// ## Determinism and cost
///
/// Plain value type, `var` state only, no class/actor/shared mutable state —
/// same shape as `PlateTracker` and `MotionAxis`, for the same reason: two
/// gates fed the same frames in the same order produce the same states. Per
/// frame this does an EMA update, an append to a small bounded ring buffer,
/// and a linear min/max scan over at most a few dozen entries — orders of
/// magnitude under the 5 ms per-frame plate-detection budget (SPEC §16) it
/// has to share the frame with.
public struct PostureGate: Sendable {

    // MARK: - Pose seam (Wave 5 / Track B, not implemented here)

    /// One frame's pose-derived evidence for SPEC §7.1's two pose cues.
    /// **No type in this codebase constructs one of these yet.** It exists
    /// purely as the shape `PoseProvider` (Wave 5) will produce once it
    /// exists — see the type doc's "Track A / Track B split". A caller with
    /// no pose track simply never sets `FrameInput.pose`, and this gate
    /// runs Track A cues alone.
    public struct PoseCueContribution: Sendable, Equatable {
        /// 0...1: how consistent the measured torso orientation is with the
        /// expected posture for the exercise in progress (SPEC §7.1's
        /// "primary cue"). 1 = fully consistent, 0 = clearly wrong (e.g.
        /// upright and walking during a squat set).
        public var torsoOrientationScore: Double

        /// 0...1: SPEC §7.1's "coarse landmark layout check" — are the
        /// joints arranged roughly like the expected posture at all,
        /// independent of orientation.
        public var landmarkLayoutScore: Double

        public init(torsoOrientationScore: Double, landmarkLayoutScore: Double) {
            precondition(
                torsoOrientationScore.isFinite && (0...1).contains(torsoOrientationScore),
                "PoseCueContribution.torsoOrientationScore must be finite and in 0...1"
            )
            precondition(
                landmarkLayoutScore.isFinite && (0...1).contains(landmarkLayoutScore),
                "PoseCueContribution.landmarkLayoutScore must be finite and in 0...1"
            )
            self.torsoOrientationScore = torsoOrientationScore
            self.landmarkLayoutScore = landmarkLayoutScore
        }
    }

    // MARK: - Gate state

    /// Why the gate is closed right now — SPEC / this task: "a gate that
    /// closes silently is undebuggable after the fact." Every case a caller
    /// can observe is specific enough to answer "why not?" on its own,
    /// without cross-referencing anything else in the trace.
    public enum Reason: Sendable, Equatable {
        /// No plate is being tracked this frame at all (`FrameInput
        /// .plateTracked == false`).
        case noPlateTracked

        /// A plate is tracked, but `MotionAxis` hasn't produced a
        /// projection yet this frame (`FrameInput.axialMetres` /
        /// `.lateralMetres` are `nil` — e.g. still warming up its fitting
        /// window). Distinct from `.noPlateTracked`: there is a plate,
        /// there just isn't a motion-axis sample to evaluate against yet.
        case insufficientMotionData

        /// The axial (working-axis) position has drifted more than
        /// `limitMetres` from the gate's own slow-tracking baseline —
        /// racking, unracking, or carrying the plate to a different height,
        /// not oscillation around a stable position.
        case heightImplausible(deviationMetres: Double, limitMetres: Double)

        /// The non-working axis has swept more than `limitMetres` within
        /// the recent window — the "walking past the camera" signature.
        case nonWorkingAxisUnstable(lateralRangeMetres: Double, limitMetres: Double)

        /// A pose cue (Wave 5) reported the torso orientation and/or
        /// landmark layout as inconsistent with the exercise in progress.
        /// Never produced by a Track-A-only caller, since `FrameInput.pose`
        /// is `nil` in that case.
        case poseInconsistent(PoseCueContribution)

        /// Every cue currently passes, but the gate hasn't held that state
        /// for `requiredSeconds` yet (the open-side dwell — see type doc
        /// "Hysteresis and dwell"). Distinct from every other case: this is
        /// not a cue failing, it's the debounce not having elapsed.
        case awaitingDwell(elapsedSeconds: Double, requiredSeconds: Double)
    }

    public enum State: Sendable, Equatable {
        case open
        case closed(Reason)

        public var isOpen: Bool { if case .open = self { true } else { false } }

        /// `nil` while `.open` — there is nothing to explain.
        public var reason: Reason? {
            if case .closed(let reason) = self { reason } else { nil }
        }
    }

    // MARK: - Per-frame input

    /// One frame's Track A (and optionally Track B) evidence. A caller
    /// wiring `PlateTracker` + `MotionAxis` into this gate translates
    /// `PlateTracker.FrameResult` into `plateTracked` (`true` for
    /// `.measured` / `.interpolated`, `false` for `.lost`) and
    /// `MotionAxis.Result` into `axialMetres` / `lateralMetres` (both
    /// `nil` for `.gap`, both set for `.projected`) — that translation is
    /// the wiring code's job, not this type's; `PostureGate` never imports
    /// `CoreVideo`/`CoreGraphics` or depends on either of those types
    /// directly, so it has nothing to do with how the plate was found.
    public struct FrameInput: Sendable, Equatable {
        /// Whether a plate is being tracked this frame at all (measured or
        /// bridged by interpolation — see `Reason.noPlateTracked`).
        public var plateTracked: Bool

        /// Metres, along the working axis, signed per `RepSignal.Sample.x`
        /// — `MotionAxis.Projection.axial`, unmodified. `nil` iff no
        /// projection exists this frame (see `Reason.insufficientMotionData`).
        public var axialMetres: Double?

        /// Metres, perpendicular to the working axis — `MotionAxis
        /// .Projection.lateral`, unmodified, used only as a magnitude here
        /// (see type doc). `nil` iff no projection exists this frame.
        public var lateralMetres: Double?

        /// Wave 5's seam (see `PoseCueContribution`). `nil` for every
        /// caller in this codebase today.
        public var pose: PoseCueContribution?

        public init(
            plateTracked: Bool, axialMetres: Double? = nil, lateralMetres: Double? = nil,
            pose: PoseCueContribution? = nil
        ) {
            self.plateTracked = plateTracked
            self.axialMetres = axialMetres
            self.lateralMetres = lateralMetres
            self.pose = pose
        }
    }

    // MARK: - Configuration

    public struct Configuration: Sendable, Equatable {
        /// Metres. Above this, the axial deviation-from-baseline cue keeps
        /// the gate from *opening*, but doesn't close an already-open gate
        /// (see `closeHeightDeviationLimitMetres`).
        public var openHeightDeviationLimitMetres: Double

        /// Metres, `>= openHeightDeviationLimitMetres`. Above this, the
        /// axial cue *closes* an open gate (after `closeDwellSeconds`).
        /// Strictly looser than the open limit — that gap is the hysteresis
        /// band itself.
        public var closeHeightDeviationLimitMetres: Double

        /// Time constant, seconds, of the exponential-moving-average
        /// baseline the height cue measures deviation against. See
        /// `PostureGate.defaultHeightBaselineTimeConstantSeconds`.
        public var heightBaselineTimeConstantSeconds: Double

        /// Metres. Above this, the recent lateral (non-working-axis) range
        /// keeps the gate from opening.
        public var openLateralRangeLimitMetres: Double

        /// Metres, `>= openLateralRangeLimitMetres`. Above this, the
        /// lateral cue closes an open gate.
        public var closeLateralRangeLimitMetres: Double

        /// Seconds of recent history the lateral range is computed over.
        /// See `PostureGate.defaultLateralWindowSeconds`.
        public var lateralWindowSeconds: Double

        /// Seconds every cue must hold "pass" before a closed gate opens.
        /// See `PostureGate.defaultOpenDwellSeconds`.
        public var openDwellSeconds: Double

        /// Seconds every cue must hold "fail (even the loose bound)" before
        /// an open gate closes. See `PostureGate.defaultCloseDwellSeconds`.
        public var closeDwellSeconds: Double

        /// 0...1. Below this, `min(torsoOrientationScore, landmarkLayoutScore)`
        /// keeps the gate from opening. Only consulted when `FrameInput
        /// .pose` is non-`nil`.
        public var poseOpenThreshold: Double

        /// 0...1, `<= poseOpenThreshold`. Below this, the pose cue closes
        /// an open gate.
        public var poseCloseThreshold: Double

        /// Assumed inter-frame interval, seconds, used only for the very
        /// first frame (no previous timestamp to derive a real one from) or
        /// if two consecutive timestamps are non-monotonic — same role,
        /// same reasoning, as `PlateTracker.Configuration
        /// .assumedFrameIntervalSeconds`.
        public var assumedFrameIntervalSeconds: Double

        public init(
            openHeightDeviationLimitMetres: Double,
            closeHeightDeviationLimitMetres: Double,
            heightBaselineTimeConstantSeconds: Double = PostureGate.defaultHeightBaselineTimeConstantSeconds,
            openLateralRangeLimitMetres: Double,
            closeLateralRangeLimitMetres: Double,
            lateralWindowSeconds: Double = PostureGate.defaultLateralWindowSeconds,
            openDwellSeconds: Double = PostureGate.defaultOpenDwellSeconds,
            closeDwellSeconds: Double = PostureGate.defaultCloseDwellSeconds,
            poseOpenThreshold: Double = PostureGate.defaultPoseOpenThreshold,
            poseCloseThreshold: Double = PostureGate.defaultPoseCloseThreshold,
            assumedFrameIntervalSeconds: Double = PostureGate.defaultAssumedFrameIntervalSeconds
        ) {
            precondition(
                openHeightDeviationLimitMetres.isFinite && openHeightDeviationLimitMetres > 0,
                "PostureGate.Configuration.openHeightDeviationLimitMetres must be finite and positive"
            )
            precondition(
                closeHeightDeviationLimitMetres.isFinite
                    && closeHeightDeviationLimitMetres >= openHeightDeviationLimitMetres,
                "PostureGate.Configuration.closeHeightDeviationLimitMetres must be finite and >= openHeightDeviationLimitMetres"
            )
            precondition(
                heightBaselineTimeConstantSeconds.isFinite && heightBaselineTimeConstantSeconds > 0,
                "PostureGate.Configuration.heightBaselineTimeConstantSeconds must be finite and positive"
            )
            precondition(
                openLateralRangeLimitMetres.isFinite && openLateralRangeLimitMetres > 0,
                "PostureGate.Configuration.openLateralRangeLimitMetres must be finite and positive"
            )
            precondition(
                closeLateralRangeLimitMetres.isFinite
                    && closeLateralRangeLimitMetres >= openLateralRangeLimitMetres,
                "PostureGate.Configuration.closeLateralRangeLimitMetres must be finite and >= openLateralRangeLimitMetres"
            )
            precondition(
                lateralWindowSeconds.isFinite && lateralWindowSeconds > 0,
                "PostureGate.Configuration.lateralWindowSeconds must be finite and positive"
            )
            precondition(
                openDwellSeconds.isFinite && openDwellSeconds >= 0,
                "PostureGate.Configuration.openDwellSeconds must be finite and >= 0"
            )
            precondition(
                closeDwellSeconds.isFinite && closeDwellSeconds >= 0,
                "PostureGate.Configuration.closeDwellSeconds must be finite and >= 0"
            )
            precondition(
                poseOpenThreshold.isFinite && (0...1).contains(poseOpenThreshold),
                "PostureGate.Configuration.poseOpenThreshold must be finite and in 0...1"
            )
            precondition(
                poseCloseThreshold.isFinite && (0...1).contains(poseCloseThreshold)
                    && poseCloseThreshold <= poseOpenThreshold,
                "PostureGate.Configuration.poseCloseThreshold must be finite, in 0...1, and <= poseOpenThreshold"
            )
            precondition(
                assumedFrameIntervalSeconds.isFinite && assumedFrameIntervalSeconds > 0,
                "PostureGate.Configuration.assumedFrameIntervalSeconds must be finite and positive"
            )
            self.openHeightDeviationLimitMetres = openHeightDeviationLimitMetres
            self.closeHeightDeviationLimitMetres = closeHeightDeviationLimitMetres
            self.heightBaselineTimeConstantSeconds = heightBaselineTimeConstantSeconds
            self.openLateralRangeLimitMetres = openLateralRangeLimitMetres
            self.closeLateralRangeLimitMetres = closeLateralRangeLimitMetres
            self.lateralWindowSeconds = lateralWindowSeconds
            self.openDwellSeconds = openDwellSeconds
            self.closeDwellSeconds = closeDwellSeconds
            self.poseOpenThreshold = poseOpenThreshold
            self.poseCloseThreshold = poseCloseThreshold
            self.assumedFrameIntervalSeconds = assumedFrameIntervalSeconds
        }

        /// The constructor an actual Track A caller should use: derives the
        /// height and lateral bands from the plate's own real diameter (SPEC
        /// §8) — the only physical scale Track A has without per-exercise
        /// calibration (W3-04) — via the multipliers documented on
        /// `PostureGate.defaultOpenHeightDeviationMultiplier` and friends.
        public static func trackA(
            plateDiameterMetres: Double,
            heightBaselineTimeConstantSeconds: Double = PostureGate.defaultHeightBaselineTimeConstantSeconds,
            lateralWindowSeconds: Double = PostureGate.defaultLateralWindowSeconds,
            openDwellSeconds: Double = PostureGate.defaultOpenDwellSeconds,
            closeDwellSeconds: Double = PostureGate.defaultCloseDwellSeconds,
            assumedFrameIntervalSeconds: Double = PostureGate.defaultAssumedFrameIntervalSeconds
        ) -> Configuration {
            precondition(
                plateDiameterMetres.isFinite && plateDiameterMetres > 0,
                "PostureGate.Configuration.trackA(plateDiameterMetres:) requires a finite, positive diameter"
            )
            return Configuration(
                openHeightDeviationLimitMetres: plateDiameterMetres * PostureGate.defaultOpenHeightDeviationMultiplier,
                closeHeightDeviationLimitMetres: plateDiameterMetres * PostureGate.defaultCloseHeightDeviationMultiplier,
                heightBaselineTimeConstantSeconds: heightBaselineTimeConstantSeconds,
                openLateralRangeLimitMetres: plateDiameterMetres * PostureGate.defaultOpenLateralRangeMultiplier,
                closeLateralRangeLimitMetres: plateDiameterMetres * PostureGate.defaultCloseLateralRangeMultiplier,
                lateralWindowSeconds: lateralWindowSeconds,
                openDwellSeconds: openDwellSeconds,
                closeDwellSeconds: closeDwellSeconds,
                assumedFrameIntervalSeconds: assumedFrameIntervalSeconds
            )
        }
    }

    // MARK: - Default numbers, and why

    /// 2.0×. `MotionAxisTests`' own squat fixture (`verticalSquatProjectsCleanly`)
    /// uses a 0.30 m amplitude — a peak-to-peak excursion of 0.60 m, i.e.
    /// roughly ±0.30 m (~0.67 plate diameters at the 0.45 m Olympic/bumper
    /// diameter, SPEC §8) around its centre once the EMA baseline has
    /// settled near that centre. 2.0× diameter (0.90 m at that same
    /// diameter) leaves comfortable headroom above that for a deeper squat,
    /// a taller lifter, or a baseline that hasn't fully settled yet, while
    /// staying well under the multi-metre one-directional travel of
    /// actually carrying the plate somewhere else.
    public static let defaultOpenHeightDeviationMultiplier: Double = 2.0

    /// 3.0×. The hysteresis gap above `defaultOpenHeightDeviationMultiplier`
    /// — 50% looser, wide enough that a rep landing exactly at the open edge
    /// doesn't immediately threaten to close the gate on the very next
    /// frame's rounding noise.
    public static let defaultCloseHeightDeviationMultiplier: Double = 3.0

    /// 3.0 s. Matches SPEC §7.2's own rolling-median detrend window exactly
    /// — the spec's own answer to "how slow does a baseline have to update
    /// to not absorb a rep's own oscillation." A rep's full concentric +
    /// eccentric cycle is "order of a second or more" per §7.2, so a 3 s
    /// baseline time constant sits comfortably above single-rep timescale
    /// (won't chase the oscillation) while being fast enough that a lifter
    /// who's genuinely relocated is judged against their new position within
    /// a handful of reps, not held flagged against a stale one indefinitely.
    public static let defaultHeightBaselineTimeConstantSeconds: Double = 3.0

    /// 0.5×. Bar-path deviation during a controlled lift, even with
    /// imperfect form, stays well under half the plate's own diameter — the
    /// plate visibly doesn't drift sideways by nearly its own width during
    /// one rep. 0.225 m at the 0.45 m Olympic/bumper diameter.
    public static let defaultOpenLateralRangeMultiplier: Double = 0.5

    /// 0.75×. The hysteresis gap above `defaultOpenLateralRangeMultiplier`.
    /// A person actually walking (roughly 1.2–1.4 m/s at normal gait)
    /// crossing in front of the camera sweeps the plate laterally by more
    /// than a full plate diameter within the 1 s default window
    /// (`defaultLateralWindowSeconds`) — both bands sit far below that, so
    /// walking is not a boundary case for this cue, it's a clear miss.
    public static let defaultCloseLateralRangeMultiplier: Double = 0.75

    /// 1.0 s. Long enough to catch sustained lateral translation (walking)
    /// rather than one noisy frame; short enough that the gate reacts to
    /// someone starting to walk away well within the multi-second gap
    /// between a set ending and the next one starting, and doesn't average
    /// a real walk-away down to nothing.
    public static let defaultLateralWindowSeconds: Double = 1.0

    /// 0.15 s. SPEC §7.2's own spike floor for a rep *phase* is 80 ms; a
    /// lifter settles into position and holds still for at least a moment
    /// before initiating the first rep of a set (SPEC §14.3's setup/framing
    /// flow is a deliberate step before a set starts). 150 ms is long
    /// enough to debounce single- and double-frame noise at both the 30 fps
    /// floor and 60 fps ceiling (SPEC §16) — 4.5 to 9 frames — while being a
    /// small fraction of even a fast rep's "order of a second" half-cycle,
    /// so the gate is reliably open before the first rep's own amplitude
    /// gate (SPEC §7.2: "posture gate held throughout") needs it to be.
    public static let defaultOpenDwellSeconds: Double = 0.15

    /// 0.4 s. Deliberately longer than the open dwell: a false close mid-set
    /// fragments one set into several (this task's stated why), which is a
    /// worse failure than a false open being slightly early, so the bar to
    /// close is set higher. 400 ms is still well under the gap between racking
    /// a set and starting to walk away, so a genuine end-of-set is not
    /// meaningfully delayed.
    public static let defaultCloseDwellSeconds: Double = 0.4

    /// 0.6. Placeholder pending Wave 5 tuning against real pose output — no
    /// caller in this codebase sets `FrameInput.pose` yet, so this default
    /// is never exercised. Kept above the close threshold's midpoint so a
    /// pose-equipped caller defaults to the same "loose to stay open,
    /// tighter to open" hysteresis shape as the Track A cues, not because
    /// 0.6 has been validated against anything.
    public static let defaultPoseOpenThreshold: Double = 0.6

    /// 0.4. See `defaultPoseOpenThreshold` — same caveat, never exercised.
    public static let defaultPoseCloseThreshold: Double = 0.4

    /// 1/30 s. Same value and role as `PlateTracker.Configuration
    /// .defaultAssumedFrameIntervalSeconds` — conservative (larger, so a
    /// dwell timer under-counts elapsed time rather than over-counts it) fallback for the very first frame or a non-monotonic timestamp.
    public static let defaultAssumedFrameIntervalSeconds: Double = 1.0 / 30.0

    /// Ring-buffer capacity for the lateral-range window: enough entries to
    /// hold `lateralWindowSeconds` of history at the SPEC §16 60 fps
    /// ceiling, plus the same ~33% headroom `MotionAxis
    /// .defaultMaxWindowEntries` uses for the same reason (a burst of
    /// unusually fast frame delivery shouldn't evict entries the time
    /// filter would otherwise still consider in-window).
    private static func lateralWindowCapacity(lateralWindowSeconds: Double) -> Int {
        Swift.max(8, Int((lateralWindowSeconds * 60.0 * 4.0 / 3.0).rounded(.up)))
    }

    // MARK: - State

    /// One entry in the lateral-range window. A named struct, not a tuple —
    /// tuples cannot be made to conform to `Sendable` for the purposes of
    /// satisfying `RingBuffer`'s conditional `Element: Sendable`
    /// constraint, since tuple types cannot conform to protocols at all.
    private struct LateralSample: Sendable {
        let t: TimeInterval
        let value: Double
    }

    public let configuration: Configuration

    private var state: State = .closed(.insufficientMotionData)
    private var dwellSeconds: Double = 0
    private var lastTimestamp: TimeInterval?
    private var heightBaseline: Double?
    private var lateralWindow: RingBuffer<LateralSample>

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.lateralWindow = RingBuffer(
            capacity: Self.lateralWindowCapacity(lateralWindowSeconds: configuration.lateralWindowSeconds)
        )
    }

    /// The most recent `State` returned by `advance(_:t:)`, or the initial
    /// closed state (`.insufficientMotionData`) before the first frame.
    public var currentState: State { state }

    // MARK: - Per-frame entry point

    /// Advances the gate by one frame and returns that frame's `State` —
    /// the value a caller records into the per-frame trace (SPEC / this
    /// task item "gate state recorded per frame in the trace"; this type
    /// produces that state, wiring it into a persisted trace structure is
    /// the counter/trace owner's job, not this file's). `t` is capture
    /// time, seconds, same clock as `RepSignal.Sample.t`. Must be called
    /// once per frame, in capture order — same causal contract as
    /// `PlateTracker.processFrame` and `MotionAxis.observe`.
    public mutating func advance(_ input: FrameInput, t: TimeInterval) -> State {
        let dt = frameIntervalSeconds(currentTimestamp: t)
        let evaluation = evaluate(input, t: t, dt: dt)

        switch state {
        case .open:
            if evaluation.meetsClose {
                dwellSeconds = 0
                state = .open
            } else {
                dwellSeconds += dt
                if dwellSeconds >= configuration.closeDwellSeconds {
                    state = .closed(evaluation.reason ?? .insufficientMotionData)
                    dwellSeconds = 0
                }
                // Still open until the close dwell fully elapses — a
                // frame that briefly fails the loose bound does not
                // instantly close the gate (that's the whole point of the
                // dwell requirement).
            }

        case .closed:
            if evaluation.meetsOpen {
                dwellSeconds += dt
                if dwellSeconds >= configuration.openDwellSeconds {
                    state = .open
                    dwellSeconds = 0
                } else {
                    state = .closed(.awaitingDwell(elapsedSeconds: dwellSeconds, requiredSeconds: configuration.openDwellSeconds))
                }
            } else {
                dwellSeconds = 0
                state = .closed(evaluation.reason ?? .insufficientMotionData)
            }
        }

        return state
    }

    // MARK: - Timing

    private mutating func frameIntervalSeconds(currentTimestamp: TimeInterval) -> TimeInterval {
        defer { lastTimestamp = currentTimestamp }
        guard let last = lastTimestamp else { return configuration.assumedFrameIntervalSeconds }
        let dt = currentTimestamp - last
        guard dt.isFinite, dt > 0 else { return configuration.assumedFrameIntervalSeconds }
        return dt
    }

    // MARK: - Cue evaluation

    private struct Evaluation {
        var meetsOpen: Bool
        var meetsClose: Bool
        var reason: Reason?
    }

    private mutating func evaluate(_ input: FrameInput, t: TimeInterval, dt: TimeInterval) -> Evaluation {
        guard input.plateTracked else {
            return Evaluation(meetsOpen: false, meetsClose: false, reason: .noPlateTracked)
        }
        guard let axial = input.axialMetres, let lateral = input.lateralMetres else {
            return Evaluation(meetsOpen: false, meetsClose: false, reason: .insufficientMotionData)
        }

        let heightDeviation = updateHeightBaseline(axial: axial, dt: dt)
        let lateralRangeValue = lateralRange(current: lateral, t: t)

        var meetsOpen = true
        var meetsClose = true
        var reason: Reason?

        if heightDeviation > configuration.closeHeightDeviationLimitMetres {
            meetsOpen = false
            meetsClose = false
            reason =
                reason
                ?? .heightImplausible(deviationMetres: heightDeviation, limitMetres: configuration.closeHeightDeviationLimitMetres)
        } else if heightDeviation > configuration.openHeightDeviationLimitMetres {
            meetsOpen = false
            reason =
                reason
                ?? .heightImplausible(deviationMetres: heightDeviation, limitMetres: configuration.openHeightDeviationLimitMetres)
        }

        if lateralRangeValue > configuration.closeLateralRangeLimitMetres {
            meetsOpen = false
            meetsClose = false
            reason =
                reason
                ?? .nonWorkingAxisUnstable(
                    lateralRangeMetres: lateralRangeValue, limitMetres: configuration.closeLateralRangeLimitMetres)
        } else if lateralRangeValue > configuration.openLateralRangeLimitMetres {
            meetsOpen = false
            reason =
                reason
                ?? .nonWorkingAxisUnstable(
                    lateralRangeMetres: lateralRangeValue, limitMetres: configuration.openLateralRangeLimitMetres)
        }

        if let pose = input.pose {
            let poseScore = Swift.min(pose.torsoOrientationScore, pose.landmarkLayoutScore)
            if poseScore < configuration.poseCloseThreshold {
                meetsOpen = false
                meetsClose = false
                reason = reason ?? .poseInconsistent(pose)
            } else if poseScore < configuration.poseOpenThreshold {
                meetsOpen = false
                reason = reason ?? .poseInconsistent(pose)
            }
        }

        return Evaluation(meetsOpen: meetsOpen, meetsClose: meetsClose, reason: reason)
    }

    /// Updates the slow EMA baseline and returns the deviation of `axial`
    /// from the baseline **as it was before this frame's update** — so the
    /// returned deviation reflects how far this frame actually sits from
    /// where the baseline already was, not from wherever it's about to move
    /// to once this frame is folded in.
    private mutating func updateHeightBaseline(axial: Double, dt: TimeInterval) -> Double {
        guard let baseline = heightBaseline else {
            heightBaseline = axial
            return 0
        }
        let deviation = abs(axial - baseline)
        let tau = configuration.heightBaselineTimeConstantSeconds
        let alpha = dt > 0 ? 1 - exp(-dt / tau) : 0
        heightBaseline = baseline + alpha * (axial - baseline)
        return deviation
    }

    /// Appends `current` to the lateral window and returns the window's
    /// range (max − min) after filtering to `lateralWindowSeconds` of
    /// history — same time-filter-over-a-ring-buffer idiom as `MotionAxis
    /// .observe`'s own windowing.
    private mutating func lateralRange(current: Double, t: TimeInterval) -> Double {
        lateralWindow.append(LateralSample(t: t, value: current))
        let entries = lateralWindow.suffix(lateralWindow.capacity)
            .filter { t - $0.t <= configuration.lateralWindowSeconds }
        guard let minValue = entries.map(\.value).min(), let maxValue = entries.map(\.value).max() else { return 0 }
        return maxValue - minValue
    }
}
