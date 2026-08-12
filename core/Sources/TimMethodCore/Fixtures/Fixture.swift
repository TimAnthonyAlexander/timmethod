import Foundation

/// The sidecar ground-truth schema for one fixture clip (SPEC §15).
///
/// A fixture is a `.mov` plus a `.json` file of the same base name carrying
/// this type, JSON-encoded. `FixtureLoader` pairs the two and validates the
/// JSON before anything downstream (`ReplayFrameSource`, the counter, the
/// eval harness) ever sees it.
///
/// This type is deliberately conservative to extend and expensive to get
/// wrong: per the task that introduced it, "changing this format later
/// invalidates every recorded ground truth." Two fields exist here beyond
/// what SPEC §15's `## Do` list spells out — `referenceMeanConcentricVelocity`
/// and `trueSetBoundaries` — because §15.2 sets scoring targets for velocity
/// RMSE and set-boundary F1 that are literally unmeasurable without a
/// reference to score against, and adding them after fixtures exist would
/// mean re-labelling every clip that could carry them. Both are optional:
/// most clips will never have a criterion velocity measurement or a
/// multi-set recording, and **absent means "not scoreable for this
/// metric," never "zero."** See `fixtures/README.md`.
public struct Fixture: Codable, Sendable, Equatable {
    /// Matches `Exercise.id` (SPEC §12) — a stable string identifier such as
    /// `"back_squat"`, not the display name. The eval harness groups and
    /// reports by this.
    public var exerciseId: String

    /// What the lifter is moving. Closed set, not free text, so the harness
    /// can group results by equipment class the way SPEC §15.2's targets do
    /// (loaded vs. bodyweight have different MAE targets).
    public var equipment: Equipment

    /// Diameter of the tracked plate/end-cap, millimetres, when `equipment`
    /// carries one Track A (SPEC §8) can lock onto — a loaded barbell, or a
    /// round-headed (non-hex) dumbbell, per SPEC §19 open question 5. `nil`
    /// for hex dumbbells, machines, and always for `.bodyweight`:
    /// `FixtureLoader` rejects a non-nil value on a bodyweight clip, because
    /// there is no plate in frame to measure.
    public var plateDiameterMm: Double?

    /// Ground-truth count of full reps performed in the clip. What the
    /// harness scores predicted counts against for SPEC §15.2's MAE and
    /// off-by-one targets. Zero is valid (e.g. a clip recorded to test
    /// false-positive rejection). Never negative.
    public var trueRepCount: Int

    /// Of `trueRepCount`, how many were partial reps (50–80% of range, per
    /// SPEC §12's `WorkSet.partialReps`) rather than full-range reps. A
    /// subset of `trueRepCount`, not an additional count on top of it —
    /// `FixtureLoader` rejects `truePartialCount > trueRepCount`. Never
    /// negative.
    public var truePartialCount: Int

    /// Camera angle relative to the lift's plane of motion. Closed set with
    /// an explicit degree mapping (`degreesOffPerpendicular`), not free
    /// text: SPEC §14.3 documents camera angle as the top failure mode, with
    /// accuracy degrading past roughly 30° off-perpendicular, so the harness
    /// has to be able to break results down by angle rather than by
    /// whatever string a labeller happened to type.
    public var cameraPosition: CameraPosition

    /// Free-text description of the lighting conditions (e.g. "overhead
    /// fluorescent, no windows", "backlit by a window"). SPEC §14.3 flags
    /// backlighting and low light as landmark-confidence killers; this is
    /// what lets a failing clip be triaged back to a lighting cause without
    /// re-watching the footage.
    public var lightingNote: String

    /// Which source this clip came from — one of the datasets in SPEC
    /// §15.1's table (`"FLEX"`, `"MM-Fit"`, `"Fitness-AQA"`, `"InfiniteRep"`,
    /// `"RepCount-A"`) or `"own"` for self-recorded clips. Free text rather
    /// than a closed enum: this is provenance for a human reading the
    /// sidecar, not something the harness branches on — `licence` is the
    /// field that answers the machine-checkable question.
    public var sourceDataset: String

    /// Closed enum, not free text, with an explicit
    /// `allowsCommercialUse` property — this is the field that makes SPEC
    /// §19 open question 9 ("licence swap before any distribution") a query
    /// instead of a re-read of every sidecar in the set. FLEX and
    /// Fitness-AQA are non-commercial (SPEC §15.1); the day this ships, the
    /// fixture set has to be rebuildable from the clips where this is
    /// `true`.
    public var licence: Licence

    /// Timestamp (seconds, clip-relative, same clock as
    /// `TimedFrame.timestamp`/`CMSampleBuffer` presentation time) of each
    /// counted rep, oldest first. Optional — most clips won't have this
    /// labelled — and when present must be strictly increasing;
    /// `FixtureLoader` rejects an out-of-order array rather than silently
    /// accepting labeller error.
    public var perRepTimestamps: [TimeInterval]?

    /// Reference mean concentric velocity, metres/second, one entry per rep
    /// in the same order as `perRepTimestamps` — present **only** on clips
    /// where a criterion measurement exists (a linear encoder, published
    /// dataset ground truth). SPEC §15.2 targets ≤ 0.05 m/s RMSE for this
    /// metric; without a reference value per clip that target cannot be
    /// scored at all, only asserted. Absent means "no criterion measurement
    /// for this clip," not "velocity was zero." Positive by construction —
    /// concentric motion is defined positive per `RepSignal.Sample.x`'s sign
    /// convention (SPEC §6) — so `FixtureLoader` rejects a zero or negative
    /// entry as mislabelled rather than a real measurement.
    public var referenceMeanConcentricVelocity: [Double]?

    /// Ground-truth start/end times (seconds, clip-relative) of each working
    /// set in the clip, oldest first — most fixture clips are a single set
    /// and will carry either `nil` or one boundary, but a clip covering
    /// SPEC §15.1's "walk out of frame mid-set and come back" case, or a
    /// multi-set recording, needs more than one. Optional: SPEC §15.2 targets
    /// ≥ 0.95 F1 for set-boundary detection, unscoreable without this.
    /// Absent means "not labelled for set boundaries," not "no sets."
    public var trueSetBoundaries: [SetBoundary]?

    /// One labelled working set within a clip. `endTime` must be strictly
    /// after `startTime`, and boundaries must not overlap — see
    /// `FixtureLoader`.
    public struct SetBoundary: Codable, Sendable, Equatable {
        public var startTime: TimeInterval
        public var endTime: TimeInterval

        public init(startTime: TimeInterval, endTime: TimeInterval) {
            self.startTime = startTime
            self.endTime = endTime
        }
    }

    public init(
        exerciseId: String,
        equipment: Equipment,
        plateDiameterMm: Double? = nil,
        trueRepCount: Int,
        truePartialCount: Int = 0,
        cameraPosition: CameraPosition,
        lightingNote: String,
        sourceDataset: String,
        licence: Licence,
        perRepTimestamps: [TimeInterval]? = nil,
        referenceMeanConcentricVelocity: [Double]? = nil,
        trueSetBoundaries: [SetBoundary]? = nil
    ) {
        self.exerciseId = exerciseId
        self.equipment = equipment
        self.plateDiameterMm = plateDiameterMm
        self.trueRepCount = trueRepCount
        self.truePartialCount = truePartialCount
        self.cameraPosition = cameraPosition
        self.lightingNote = lightingNote
        self.sourceDataset = sourceDataset
        self.licence = licence
        self.perRepTimestamps = perRepTimestamps
        self.referenceMeanConcentricVelocity = referenceMeanConcentricVelocity
        self.trueSetBoundaries = trueSetBoundaries
    }
}

/// What the lifter is moving (SPEC §12's `Exercise.equipment` set).
public enum Equipment: String, Codable, Sendable, Equatable, CaseIterable {
    case barbell
    case dumbbell
    case bodyweight
    case machine
}

/// Camera angle relative to the lift's plane of motion (SPEC §14.3).
///
/// Cases are angle buckets, not a raw degree `Double`, because fixtures are
/// hand-labelled from footage, not measured with a protractor — "roughly
/// 30° off to the left" is what a labeller can actually assert. Each case
/// still carries an explicit `degreesOffPerpendicular`, so the harness can
/// group and threshold by angle numerically instead of pattern-matching on
/// case names.
public enum CameraPosition: String, Codable, Sendable, Equatable, CaseIterable {
    /// Camera on the plane of motion, square to the lifter — the reference
    /// angle SPEC §14.3's accuracy claims are measured relative to.
    case perpendicular
    case oblique15
    case oblique30
    case oblique45
    case oblique60
    /// Camera facing the lifter head-on (or from directly behind) — the
    /// motion axis is foreshortened to near zero, the worst case for Track A.
    case frontal90

    /// Approximate degrees off-perpendicular from the lift's plane of
    /// motion. What makes this enum queryable by angle rather than only by
    /// case identity.
    public var degreesOffPerpendicular: Double {
        switch self {
        case .perpendicular: 0
        case .oblique15: 15
        case .oblique30: 30
        case .oblique45: 45
        case .oblique60: 60
        case .frontal90: 90
        }
    }

    /// Whether this position sits within the accuracy-preserving envelope
    /// SPEC §14.3 documents (accuracy degrades past roughly 30°
    /// off-perpendicular). Inclusive of exactly 30°.
    public var isWithinRecommendedEnvelope: Bool {
        degreesOffPerpendicular <= 30
    }
}

/// Licence terms a fixture clip's source was published under, and whether
/// those terms permit commercial use (SPEC §15.1, §19 open question 9).
///
/// Closed enum, not a free-text field, specifically so "which fixtures can
/// ship with a commercial product" is a filter (`fixtures.filter {
/// $0.licence.allowsCommercialUse }`), not a re-read of every sidecar's
/// prose the day this matters.
public enum Licence: String, Codable, Sendable, Equatable, CaseIterable {
    /// CC BY 4.0 — commercially clean. InfiniteRep (SPEC §15.1).
    case ccBy4
    /// CC BY-NC-SA 4.0, academic request form — non-commercial. FLEX (SPEC
    /// §15.1), the primary source; the reason this field exists at all.
    case ccByNcSa4
    /// Non-commercial, gated access. Fitness-AQA (SPEC §15.1).
    case nonCommercialGated
    /// Open download, no commercial restriction stated by the publisher.
    /// MM-Fit (SPEC §15.1).
    case openUnrestricted
    /// No explicit licence found for the source at time of writing — must
    /// be verified before any commercial use, not assumed clean.
    /// RepCount-A (SPEC §15.1).
    case unverifiedCommercialUse
    /// Self-recorded footage. Full rights, commercially clean by
    /// construction.
    case ownFootage

    /// Whether a fixture under this licence may ship as part of a
    /// commercial product. `false` errs toward the conservative reading for
    /// `.unverifiedCommercialUse` — "no explicit licence found" is not the
    /// same claim as "verified permissive," and treating it as clean by
    /// default is exactly the mistake SPEC §19 open question 9 exists to
    /// prevent.
    public var allowsCommercialUse: Bool {
        switch self {
        case .ccBy4, .openUnrestricted, .ownFootage:
            true
        case .ccByNcSa4, .nonCommercialGated, .unverifiedCommercialUse:
            false
        }
    }
}
