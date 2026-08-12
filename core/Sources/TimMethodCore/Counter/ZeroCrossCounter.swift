import Foundation

/// Finds candidate rep cycles in a velocity signal by tracking
/// sign-alternating zero crossings and assembling them as
/// **peak → valley → peak** (SPEC §6, §7.2; this task, W3-02).
///
/// ## What this is not
///
/// SPEC §7.2's diagram is a pipeline: detrend → velocity → zero crossings →
/// candidate rep → **ACCEPT iff** amplitude, phase duration, confidence, and
/// posture all clear their own bars. This file is only the third box —
/// zero crossings assembled into `peak → valley → peak` candidates — never
/// the fourth. It does not know `A_min`, does not know a minimum phase
/// duration, does not read confidence, does not know about the posture
/// gate, and does not know about partial reps. All of that is W3-03's job
/// (this task's Notes: "keep it dumb and pure. All the judgment lives in
/// the gate. Separating them is what makes both testable."). Every
/// `Candidate` this type emits is exactly that — a candidate, offered to
/// the gate, not a counted rep.
///
/// The one exception, and the reason it is an exception, is
/// `Configuration.mergeThreshold` — see that property's doc.
///
/// ## Peak, valley, and "the start position"
///
/// `RepSignal.Sample.x` is positive moving away from the ground along the
/// lift's working axis (`RepSignal.swift`). A **peak** is a local max of
/// `x` — the sample where velocity's sign flips from positive to negative.
/// A **valley** is a local min — velocity flipping negative to positive.
/// SPEC §7.2: "a rep counts on the return to the start position, never on
/// reaching the bottom." This file takes that literally: a candidate is
/// only ever assembled and emitted as `peak → valley → peak`, never
/// `valley → peak → valley`, so the count always advances on a return to a
/// peak — the top of the swing — and never on reaching a valley. Whether
/// the "top" is the anatomical start of a given exercise (lockout before a
/// squat descent) or its anatomical end (lockout after a deadlift pull) is
/// not this file's concern; SPEC §7.2's pseudocode fixes the pattern
/// unconditionally, and downstream calibration / gating is where any
/// exercise-specific reasoning would have to live, not here.
///
/// ## The debounce — what `mergeThreshold` is and is not
///
/// SPEC §6: the PCA/zero-cross route this whole pipeline follows is "not
/// invented here... what NEX Team patented and shipped in HomeCourt:
/// project landmark motion onto PCA axes in a sliding window to get a 1D
/// signal, then zero-cross with a debounce that merges crossings whose
/// magnitude difference falls below a threshold." That merge is
/// implemented here as: every newly-detected extremum's `x` is compared
/// against the most recently **committed** extremum (the opposite end of
/// the crossing pair it would close out); if the swing between them is
/// smaller than `Configuration.mergeThreshold`, the new extremum is
/// discarded and the phase that was already running simply continues
/// through it, as though the brief reversal never happened.
///
/// This is a genuinely different kind of threshold from W3-03's `A_min`:
/// `A_min` decides whether a *complete* peak-valley-peak candidate is a
/// real rep versus a twitch or partial rep — a judgement about reps,
/// tunable per exercise and per lifter via calibration (SPEC §7.3).
/// `mergeThreshold` decides whether a single-sample sign flip in a noisy
/// derivative is a real direction change at all — a judgement about
/// crossing structure, not about reps, made once per track from that
/// track's own measured noise floor (e.g. `JitterMeasurement
/// .peakToPeakMetres`, `SignalConditioning.swift`) and never touched again.
/// A single-sample glitch produces a spurious extremum very close in value
/// to whatever was just committed (the signal has barely moved since);
/// `mergeThreshold` catches exactly that case. It has no opinion about, and
/// does not filter, a spurious extremum that happens to form near the
/// *far* end of a phase (close to the crossing about to happen anyway) —
/// narrowing that further would mean buffering an unbounded number of
/// samples waiting to see whether a later crossing confirms or contradicts
/// it, which would delay every candidate's emission past the sample where
/// the return to the start position actually happened. That delay is
/// precisely what SPEC §7.2's "on the return to the start position" rules
/// out, so this file does not do it.
///
/// ## Value-semantics state machine
///
/// Same shape as `PlateTracker` and `PostureGate` (this task's Notes: "the
/// house pattern here"): a plain `struct`, all mutable state in `var`
/// properties, one `observe(t:x:v:)` call per sample, no class or actor.
/// Two counters fed the same samples in the same order produce the same
/// results — nothing else could make them differ.
///
/// ## Streaming and causal
///
/// `observe(t:x:v:)` consumes one sample at a time, in capture order, and
/// never looks ahead — the shape a live `AsyncStream` drives this with.
/// The only state carried between calls is the current phase, the running
/// extreme within it, and the last few committed extrema; there is no
/// buffering of raw samples and no assumption about how many more samples
/// are coming.
public struct ZeroCrossCounter: Sendable, Equatable {

    // MARK: - Extrema and candidates

    /// One extremum of the position signal: a local max (peak) or local
    /// min (valley), at the sample where velocity's sign flipped.
    public struct Extremum: Sendable, Equatable {
        public let t: TimeInterval
        public let x: Double

        public init(t: TimeInterval, x: Double) {
            self.t = t
            self.x = x
        }
    }

    /// Which kind of extremum a point is — or, internally, which kind the
    /// counter is currently accumulating toward.
    public enum Kind: Sendable, Equatable {
        case peak
        case valley
    }

    /// One candidate rep cycle: a full peak → valley → peak swing (this
    /// task's Do items 1–3). Carries every point W3-03's amplitude gate
    /// (SPEC §7.2) needs to judge it — both peaks and the valley, each
    /// with its own time and position — so amplitude (`startPeak.x -
    /// valley.x`, `endPeak.x - valley.x`, or whatever combination W3-03
    /// chooses) and phase duration are both derivable from the candidate
    /// alone, without re-reading the raw signal. Nothing about acceptance,
    /// thresholds, or confidence is carried here — see this file's
    /// top-level doc, "What this is not".
    public struct Candidate: Sendable, Equatable {
        /// The peak this cycle started from — the "start position" SPEC
        /// §7.2 means by "a rep counts on the return to the start
        /// position."
        public let startPeak: Extremum
        /// The bottom of the cycle.
        public let valley: Extremum
        /// The peak this cycle returned to, completing it. This is the
        /// sample on which `observe(t:x:v:)` returns this candidate.
        public let endPeak: Extremum

        public init(startPeak: Extremum, valley: Extremum, endPeak: Extremum) {
            self.startPeak = startPeak
            self.valley = valley
            self.endPeak = endPeak
        }
    }

    // MARK: - Configuration

    public struct Configuration: Sendable, Equatable {
        /// Minimum position-magnitude swing, in whatever unit the caller's
        /// `x` is in (metres for a metric `RepSignal.scale`, a
        /// dimensionless ratio for `.torsoRelative` — this type never
        /// reads `RepSignal.scale` and has no way to know or care which),
        /// a newly-detected extremum must have moved away from the most
        /// recently committed extremum before it is accepted as real. See
        /// this file's top-level doc, "The debounce", for the full
        /// reasoning.
        ///
        /// Defaults to `0`, which disables merging entirely — every
        /// crossing commits. There is no SPEC-given number for this and,
        /// unlike W3-03's `A_min`, no calibration procedure produces one;
        /// it is a per-track sensor-noise floor, not a partial-rep
        /// judgement, so this file does not invent a default beyond "off."
        /// A caller wiring up a real track supplies a value sized to that
        /// track's own measured noise (e.g.
        /// `JitterMeasurement.peakToPeakMetres`).
        public var mergeThreshold: Double

        public init(mergeThreshold: Double = 0) {
            precondition(
                mergeThreshold.isFinite && mergeThreshold >= 0,
                "ZeroCrossCounter.Configuration.mergeThreshold must be finite and >= 0"
            )
            self.mergeThreshold = mergeThreshold
        }
    }

    public let configuration: Configuration

    // MARK: - State

    /// Sign of the currently-established phase direction: `1` while
    /// accumulating toward a peak, `-1` while accumulating toward a
    /// valley, `0` before the first non-zero-velocity sample has been
    /// seen. Deliberately **not** updated when a crossing is merged away
    /// — see `observe(t:x:v:)`.
    private var lastSign: Int = 0

    /// Which extremum kind the current phase is accumulating toward.
    /// `nil` exactly when `lastSign == 0`.
    private var phase: Kind?

    /// The best `x` seen since the current phase began — the running max
    /// while `phase == .peak`, the running min while `phase == .valley`.
    private var runningExtreme: Extremum?

    /// The most recently **committed** extremum, of either kind — the
    /// reference a new candidate's swing is measured against (this file's
    /// top-level doc, "The debounce").
    private var lastCommitted: Extremum?

    /// The most recently committed peak, still waiting to be closed by a
    /// valley and a following peak. `nil` immediately after a peak commits
    /// and closes out any pending candidate — see `observe`.
    private var lastPeak: Extremum?

    /// The most recently committed valley, waiting to be closed by the
    /// next peak.
    private var lastValley: Extremum?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Advancing

    /// Advances by one sample, in capture order — the shape a live
    /// `AsyncStream` of conditioned `(t, x, v)` triples drives this with,
    /// matching `PlateTracker.processFrame` / `PostureGate.advance`'s
    /// house pattern (this task's Notes). `x` is the detrended position at
    /// this sample's own timestamp (`RollingMedianDetrend`'s output); `v`
    /// is `SignalConditioningPipeline`'s velocity at the same timestamp
    /// (`VelocitySample.v`, `Derivative.centralDifference`).
    ///
    /// Returns a `Candidate` exactly on the sample where a peak commits
    /// and completes a peak → valley → peak triple — i.e. exactly on the
    /// return to the start position (this task's Do item 5), never
    /// earlier and never delayed to see further samples first. Returns
    /// `nil` on every other call: a phase still in progress, a valley
    /// committing (which closes nothing on its own — see this file's
    /// top-level doc, "Peak, valley, and 'the start position'"), or a
    /// crossing merged away by the debounce.
    public mutating func observe(t: TimeInterval, x: Double, v: Double) -> Candidate? {
        let sign = v > 0 ? 1 : (v < 0 ? -1 : 0)

        guard sign != 0 else {
            // No directional information from this sample (exact-zero
            // velocity). It can still extend the running extreme.
            updateRunningExtreme(t: t, x: x)
            return nil
        }

        guard lastSign != 0 else {
            // First directional sample ever: establishes the initial
            // phase. Nothing to compare against yet, so nothing commits.
            lastSign = sign
            phase = sign > 0 ? .peak : .valley
            runningExtreme = Extremum(t: t, x: x)
            return nil
        }

        guard sign != lastSign else {
            // Same direction as before: the current phase continues.
            updateRunningExtreme(t: t, x: x)
            return nil
        }

        guard let candidate = runningExtreme, let endingPhase = phase else {
            // Unreachable in practice — `lastSign != 0` always implies
            // both are set — but stay safe rather than force-unwrap.
            lastSign = sign
            phase = sign > 0 ? .peak : .valley
            runningExtreme = Extremum(t: t, x: x)
            return nil
        }

        // Velocity's sign flipped: `candidate` is the extremum the ending
        // phase produced. Decide whether it is real or noise.
        let swing = lastCommitted.map { abs(candidate.x - $0.x) } ?? .infinity
        guard swing >= configuration.mergeThreshold else {
            // Debounce: merge this crossing away. The phase that was
            // already running keeps running, unaffected, through this
            // sample — as though the flip never happened.
            updateRunningExtreme(t: t, x: x)
            return nil
        }

        lastCommitted = candidate
        var emitted: Candidate?
        switch endingPhase {
        case .peak:
            if let priorPeak = lastPeak, let priorValley = lastValley {
                emitted = Candidate(startPeak: priorPeak, valley: priorValley, endPeak: candidate)
            }
            lastPeak = candidate
            lastValley = nil
        case .valley:
            lastValley = candidate
        }

        // Start the next phase at this sample.
        lastSign = sign
        phase = sign > 0 ? .peak : .valley
        runningExtreme = Extremum(t: t, x: x)

        return emitted
    }

    private mutating func updateRunningExtreme(t: TimeInterval, x: Double) {
        guard let phase else { return }
        guard let current = runningExtreme else {
            runningExtreme = Extremum(t: t, x: x)
            return
        }
        switch phase {
        case .peak:
            if x > current.x { runningExtreme = Extremum(t: t, x: x) }
        case .valley:
            if x < current.x { runningExtreme = Extremum(t: t, x: x) }
        }
    }

    // MARK: - Batch convenience

    /// Runs `observe(t:x:v:)` over a `SignalConditioningPipeline
    /// .condition(_:)` result, oldest to newest, matching each velocity
    /// sample to the detrended position at its own timestamp
    /// (`Derivative.centralDifference` stamps every `VelocitySample.t`
    /// with its source sample's own `t`, so this is an exact lookup, never
    /// an interpolation; a velocity sample with no matching timestamp —
    /// which should not happen given the two arrays come from the same
    /// pipeline run, but is possible if a caller hand-assembles mismatched
    /// arrays — is skipped rather than paired with a fabricated position).
    /// Built on the same streaming `observe` a live counter calls frame by
    /// frame, so batch and streaming use can never numerically disagree —
    /// the same discipline `RollingMedianDetrend.detrend` follows for its
    /// own streaming primitive.
    public static func candidates(
        detrended: [RepSignal.Sample],
        velocity: [VelocitySample],
        configuration: Configuration = Configuration()
    ) -> [Candidate] {
        var positionByTime: [TimeInterval: Double] = Dictionary(minimumCapacity: detrended.count)
        for sample in detrended {
            positionByTime[sample.t] = sample.x
        }

        var counter = ZeroCrossCounter(configuration: configuration)
        var results: [Candidate] = []
        for sample in velocity {
            guard let x = positionByTime[sample.t] else { continue }
            if let candidate = counter.observe(t: sample.t, x: x, v: sample.v) {
                results.append(candidate)
            }
        }
        return results
    }
}
