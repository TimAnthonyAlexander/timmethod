import Foundation

/// Ratcheting calibration of `AmplitudeGate`'s `A_min` (SPEC §7.3; this
/// task, W3-04). `AmplitudeGate` (W3-03) treats `A_min` as a fixed,
/// externally-supplied `Configuration.threshold` — this file is what
/// computes the number that gets supplied, both within one set and across a
/// lifter's whole history for an exercise. Nothing here touches
/// `AmplitudeGate.swift`; wiring "recompute `AmplitudeGate.Configuration`
/// after each accepted rep" is a later integration task, not this one.
///
/// ## The bug this exists to prevent
///
/// A naive auto-calibration tracks observed extremes directly — `A_min`
/// follows the largest (or most recent) rep seen. As a lifter fatigues,
/// range of motion shrinks, and a threshold that follows the shrinkage down
/// keeps admitting the shallow rep it exists to reject. There is no
/// documented shipped mitigation for this anywhere ⟨A13⟩ (SPEC §7.3, §19
/// open question 6) — the rule below is **engineering judgment, not prior
/// art**. `RangeCalibrationTests.swift` records that plainly again next to
/// its synthetic to-failure simulation; the real validation is a to-failure
/// fixture with hand annotation (W3-06), which needs footage that doesn't
/// exist yet (W1-06). Nothing here substitutes for that clip — it only
/// gives W3-06 a rule to validate.
///
/// ## The bootstrap problem, and the seed rule
///
/// Acceptance needs `A_min`. `A_min` comes from the first three accepted
/// reps. Something has to gate *those* reps before any `A_min` exists to
/// gate them with — otherwise a single garbage candidate (a twitch during
/// setup, an adjustment of the bar) becomes one of the three reps that
/// defines the whole set's baseline, and everything after it is judged
/// against a baseline built partly from noise.
///
/// The rule (`seedFloor(crossSessionMedian:coldStartFloor:partialFraction:)`):
///
/// - If a cross-session baseline already exists for this exercise (SPEC
///   §7.3's median of session maxima, `CrossSessionBaseline.median`), the
///   bootstrap floor is **50% of that median** — the same fraction that
///   marks the partial/not-a-rep boundary everywhere else in this file, so
///   "plausibly at least a partial rep by this lifter's own history" is the
///   one bar a candidate must clear to be admitted toward establishing a
///   *new* set's range. A twitch during setup is not a partial rep by any
///   history; a real warm-up rep, even a light one, almost always is.
/// - If no cross-session history exists yet (the lifter's first-ever set of
///   this exercise, cold start), the floor is a caller-supplied
///   `coldStartFloor`. The defensible choice for that value is whatever
///   `AmplitudeGate.Configuration.threshold` is *already* statically
///   configured to today, before any ratchet exists — this file makes
///   bootstrap **no more permissive than the shipped, unratcheted gate
///   already is**, rather than inventing a new, weaker floor for the one
///   case where there's the least data to justify one.
///
/// A candidate below the seed floor is rejected outright during bootstrap —
/// it does not count toward the three, does not touch
/// `SetCalibration.establishedAmplitude`, and cannot smuggle a garbage
/// baseline into the reps that follow it. See
/// `RangeCalibrationTests.testBootstrapAttack...` for the specific case this
/// guards.
///
/// This is not a perfect filter — a genuinely small-but-real first rep that
/// happens to clear the floor is still treated as fully establishing, same
/// as SPEC §7.3 specifies for "the first three accepted reps" with no
/// further qualification. That is the judgment call this file makes, named
/// here rather than left implicit.
///
/// ## The ratchet: `SetCalibration`
///
/// `SetCalibration` is the per-set, value-semantics state machine (same
/// shape as `PlateTracker`, `PostureGate`, `ZeroCrossCounter`: a plain
/// struct, `observe` mutates `var` state, no class or actor, two instances
/// fed the same amplitudes in the same order produce the same results).
/// Once `establishedAmplitude` is set (after `establishmentCount` accepted
/// reps, default 3), it **only ever increases** — a rep larger than the
/// established range raises it; a rep smaller never lowers it (SPEC §7.3,
/// this task's Do item 3, the whole point of the task). `A_min` for the set
/// is always `establishedAmplitude * fullFraction` (80%); the 50–80% band
/// is a partial, tallied separately (`partialRepCount`) and never folded
/// into `fullRepCount`; below 50% is not a rep.
///
/// ## Set-scoped state vs. cross-session state — kept structurally apart
///
/// `SetCalibration` resets to a fresh value at the start of every set — it
/// has no notion of "previous set" or "previous session" at all, only
/// `Configuration.seedFloor` (computed once, before the set, from whatever
/// cross-session baseline existed *then*). `CrossSessionBaseline` is the
/// opposite: it never sees an individual rep, only one number per session —
/// that session's maximum established amplitude for the exercise, fed in
/// after the session ends via `recordSessionMaximum`. The two types share no
/// mutable state and neither can reach into the other; the only connection
/// between them is the one-way, one-number-at-a-time data flow
/// `SetCalibration.establishedAmplitude` → (via `sessionMaximum`, which
/// drops any set that never established) → `CrossSessionBaseline
/// .recordSessionMaximum`. That is deliberate: conflating "this set's
/// fatigue-shrunk range" with "this lifter's standard for the exercise" is
/// exactly the mechanism by which fatigue would leak across sessions if the
/// two were the same running number.
///
/// `CrossSessionBaseline` is the **median** of session maxima, not a mean or
/// an EMA (SPEC §7.3, this task's Do item 5, in that order — median is the
/// specific, non-negotiable choice). A mean or an EMA is dragged toward
/// whatever value was seen most recently or most often; a median is not
/// moved by one outlier in either direction regardless of how extreme it is,
/// only by where it falls in sort order. One unusually deep warm-up rep can
/// ratchet a *single set's* `establishedAmplitude` well above the lifter's
/// real standard, and one bad session can produce an unusually low maximum —
/// median absorbs both without the cross-session standard itself moving to
/// track either.
public enum RangeCalibration {

    /// SPEC §7.3's bootstrap seed rule — see this file's top-level doc,
    /// "The bootstrap problem, and the seed rule," for the full reasoning.
    /// Exposed as a pure function so a caller can compute
    /// `SetCalibration.Configuration.seedFloor` once, before a set starts,
    /// from whatever `CrossSessionBaseline.median` currently holds for the
    /// exercise (`nil` if this is the lifter's first-ever set of it).
    public static func seedFloor(
        crossSessionMedian: Double?,
        coldStartFloor: Double,
        partialFraction: Double = SetCalibration.Configuration.defaultPartialFraction
    ) -> Double {
        precondition(
            coldStartFloor.isFinite && coldStartFloor >= 0,
            "RangeCalibration.seedFloor coldStartFloor must be finite and >= 0, got \(coldStartFloor)")
        precondition(
            partialFraction.isFinite && (0...1).contains(partialFraction),
            "RangeCalibration.seedFloor partialFraction must be finite and in 0...1, got \(partialFraction)")
        guard let crossSessionMedian else {
            return coldStartFloor
        }
        precondition(
            crossSessionMedian.isFinite && crossSessionMedian >= 0,
            "RangeCalibration.seedFloor crossSessionMedian must be finite and >= 0, got \(crossSessionMedian)")
        return crossSessionMedian * partialFraction
    }

    /// The single number one session should contribute to
    /// `CrossSessionBaseline` (this task's Done-when: "a set that ends
    /// early must not corrupt the cross-session baseline"; Do item 7 in the
    /// test list). `setEstablishedAmplitudes` is one entry per set run in
    /// the session — each set's own `SetCalibration.establishedAmplitude`
    /// as of when that set ended, `nil` for any set that never reached
    /// `establishmentCount` accepted reps.
    ///
    /// `nil` entries are dropped, never substituted with `0` or otherwise
    /// counted — an early-ended set has no reliable range to report, and
    /// treating it as a low reading would itself erode the cross-session
    /// baseline, which is precisely the failure this function exists to
    /// prevent. If every set in the session ended early, this returns
    /// `nil`: record nothing for the session rather than recording a
    /// fabricated maximum.
    public static func sessionMaximum(setEstablishedAmplitudes: [Double?]) -> Double? {
        setEstablishedAmplitudes.compactMap { $0 }.max()
    }
}

// MARK: - Per-set ratchet

/// The within-set calibration state machine (this file's top-level doc,
/// "The ratchet: `SetCalibration`"). Resets to a fresh value at the start of
/// every set — carries no memory of any other set or session.
public struct SetCalibration: Sendable, Equatable {

    // MARK: - Bands

    /// Which band an observed amplitude falls into, relative to the set's
    /// established range (SPEC §7.3, this task's Do item 4). Named
    /// `notARep` rather than `none` so it reads unambiguously next to
    /// `Optional.none` at call sites, and because the spec's own wording is
    /// exactly that: "below 50%: not a rep."
    public enum Band: Sendable, Equatable {
        /// `>= fullFraction` (80%) of the established range. Counts toward
        /// the working rep count.
        case full
        /// `>= partialFraction` (50%) and `< fullFraction` of the
        /// established range. Tallied in a separate ledger
        /// (`partialRepCount`), excluded from the working count, surfaced
        /// in the set summary — never silently dropped.
        case partial
        /// `< partialFraction` (50%) of the established range. Not a rep at
        /// all; not tallied anywhere.
        case notARep
    }

    /// The result of judging one candidate's amplitude (this task's TESTS:
    /// "synthetic — you can construct candidate amplitudes directly").
    /// Carries the established range the decision was made against, not
    /// just the verdict, so a caller (or a test) can see *why* — matching
    /// this codebase's house style of never reporting a bare category
    /// (`AmplitudeGate.FailureReason`'s doc makes the same point).
    public struct Observation: Sendable, Equatable {
        /// The amplitude passed to `observe(amplitude:)`.
        public let amplitude: Double
        public let band: Band
        /// The established range in effect after this observation —
        /// already reflecting any ratchet-up this very candidate triggered
        /// when `band == .full`. `nil` only while still bootstrapping
        /// (fewer than `Configuration.establishmentCount` accepted reps
        /// seen so far).
        public let establishedAmplitude: Double?
        /// `true` while this candidate was judged as one of the reps
        /// establishing the range for the first time (SPEC §7.3's "first
        /// three accepted reps"), rather than against an
        /// already-established range. A bootstrap-phase acceptance is
        /// always `.full` by construction — see this file's top-level doc,
        /// "The bootstrap problem."
        public let isEstablishing: Bool
    }

    // MARK: - Configuration

    public struct Configuration: Sendable, Equatable {
        /// SPEC §7.3: `A_min` = 80% of established amplitude.
        public static let defaultFullFraction: Double = 0.8
        /// SPEC §7.3: the partial band's lower edge.
        public static let defaultPartialFraction: Double = 0.5
        /// SPEC §7.3: "the first three accepted reps."
        public static let defaultEstablishmentCount: Int = 3

        /// The bootstrap floor (this file's top-level doc, "The bootstrap
        /// problem"). Computed once, before the set starts, via
        /// `RangeCalibration.seedFloor`.
        public let seedFloor: Double
        /// SPEC §7.3's 80%.
        public let fullFraction: Double
        /// SPEC §7.3's 50%.
        public let partialFraction: Double
        /// SPEC §7.3's three.
        public let establishmentCount: Int

        public init(
            seedFloor: Double,
            fullFraction: Double = Configuration.defaultFullFraction,
            partialFraction: Double = Configuration.defaultPartialFraction,
            establishmentCount: Int = Configuration.defaultEstablishmentCount
        ) {
            precondition(
                seedFloor.isFinite && seedFloor >= 0,
                "SetCalibration.Configuration.seedFloor must be finite and >= 0, got \(seedFloor)")
            precondition(
                fullFraction.isFinite && (0...1).contains(fullFraction),
                "SetCalibration.Configuration.fullFraction must be finite and in 0...1, got \(fullFraction)")
            precondition(
                partialFraction.isFinite && (0...1).contains(partialFraction),
                "SetCalibration.Configuration.partialFraction must be finite and in 0...1, got \(partialFraction)")
            precondition(
                partialFraction <= fullFraction,
                "SetCalibration.Configuration.partialFraction (\(partialFraction)) must be <= fullFraction (\(fullFraction))")
            precondition(
                establishmentCount >= 1,
                "SetCalibration.Configuration.establishmentCount must be >= 1, got \(establishmentCount)")
            self.seedFloor = seedFloor
            self.fullFraction = fullFraction
            self.partialFraction = partialFraction
            self.establishmentCount = establishmentCount
        }
    }

    public let configuration: Configuration

    // MARK: - State

    /// Amplitudes of accepted (seed-floor-clearing) reps seen so far during
    /// bootstrap. Only ever read to compute the seed max once it reaches
    /// `configuration.establishmentCount`; unused after that.
    private var bootstrapAccepted: [Double] = []

    /// The ratcheting established range. `nil` until `establishmentCount`
    /// reps have cleared `configuration.seedFloor`; once non-nil, only ever
    /// increases (SPEC §7.3: "range expands only" — this task's Do item 3).
    /// This is also exactly the value a caller reports as the set's
    /// contribution to `RangeCalibration.sessionMaximum` — `nil` here
    /// already means "this set never established," which is the condition
    /// that function excludes.
    public private(set) var establishedAmplitude: Double?

    /// Reps counted in the working count — every `.full` observation,
    /// including the bootstrap-establishing ones.
    public private(set) var fullRepCount: Int = 0

    /// Reps in the partial ledger (SPEC §7.3: "counted in a separate
    /// ledger... excluded from the working rep count"). Never merged into
    /// `fullRepCount`.
    public private(set) var partialRepCount: Int = 0

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Observing

    /// Judges one candidate's amplitude and, if it qualifies, advances the
    /// ratchet. One call per accepted-by-`AmplitudeGate` candidate, in
    /// order — this type takes a bare `Double` rather than
    /// `ZeroCrossCounter.Candidate` deliberately, so it has no dependency on
    /// the counter's internal shape and a caller (or a test) can drive it
    /// directly from a measured amplitude.
    public mutating func observe(amplitude: Double) -> Observation {
        precondition(
            amplitude.isFinite && amplitude >= 0,
            "SetCalibration.observe amplitude must be finite and >= 0, got \(amplitude)")

        if let established = establishedAmplitude {
            let fullThreshold = established * configuration.fullFraction
            let partialThreshold = established * configuration.partialFraction
            let band: Band
            if amplitude >= fullThreshold {
                band = .full
                fullRepCount += 1
                // Ratchet: range expands only. A smaller rep never lowers
                // `establishedAmplitude` — there is no branch for that case
                // anywhere in this function, which is the point.
                if amplitude > established {
                    establishedAmplitude = amplitude
                }
            } else if amplitude >= partialThreshold {
                band = .partial
                partialRepCount += 1
            } else {
                band = .notARep
            }
            return Observation(
                amplitude: amplitude, band: band, establishedAmplitude: establishedAmplitude, isEstablishing: false)
        }

        // Bootstrap phase: gate against the seed floor only. See this
        // file's top-level doc, "The bootstrap problem, and the seed rule."
        guard amplitude >= configuration.seedFloor else {
            return Observation(amplitude: amplitude, band: .notARep, establishedAmplitude: nil, isEstablishing: true)
        }

        bootstrapAccepted.append(amplitude)
        fullRepCount += 1
        if bootstrapAccepted.count >= configuration.establishmentCount {
            establishedAmplitude = bootstrapAccepted.max()
        }
        return Observation(
            amplitude: amplitude, band: .full, establishedAmplitude: establishedAmplitude, isEstablishing: true)
    }
}

// MARK: - Cross-session baseline

/// The per-exercise cross-session standard (this file's top-level doc,
/// "Set-scoped state vs. cross-session state — kept structurally apart").
/// Holds one number per session — that session's maximum established
/// amplitude for the exercise — and reports their **median**, never a mean
/// or an EMA (SPEC §7.3, this task's Do item 5).
public struct CrossSessionBaseline: Sendable, Equatable {

    /// One entry per session that produced at least one established set
    /// (`RangeCalibration.sessionMaximum` already excludes sessions where
    /// every set ended early). Insertion order, not sorted — `median` sorts
    /// on read.
    public private(set) var sessionMaxima: [Double]

    public init(sessionMaxima: [Double] = []) {
        for amplitude in sessionMaxima {
            precondition(
                amplitude.isFinite && amplitude >= 0,
                "CrossSessionBaseline sessionMaxima entries must be finite and >= 0, got \(amplitude)")
        }
        self.sessionMaxima = sessionMaxima
    }

    /// Records one more session's maximum. Callers should only ever pass a
    /// non-nil `RangeCalibration.sessionMaximum(setEstablishedAmplitudes:)`
    /// result here — a session where every set ended early contributes
    /// nothing and this method should simply not be called for it.
    public mutating func recordSessionMaximum(_ amplitude: Double) {
        precondition(
            amplitude.isFinite && amplitude >= 0,
            "CrossSessionBaseline.recordSessionMaximum amplitude must be finite and >= 0, got \(amplitude)")
        sessionMaxima.append(amplitude)
    }

    /// The cross-session baseline: the median of `sessionMaxima`. `nil`
    /// until at least one session has been recorded — that `nil` is exactly
    /// what `RangeCalibration.seedFloor`'s `crossSessionMedian` parameter
    /// expects for a lifter's first-ever session of an exercise (cold
    /// start).
    public var median: Double? {
        guard !sessionMaxima.isEmpty else { return nil }
        let sorted = sessionMaxima.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
