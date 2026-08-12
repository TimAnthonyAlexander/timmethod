import Foundation

/// The fourth box of SPEC §7.2's pipeline — the one `ZeroCrossCounter`
/// (W3-02) explicitly declines to be: "ACCEPT iff amplitude, phase
/// duration, confidence, and posture all clear their own bars." Every
/// threshold that decides whether a `ZeroCrossCounter.Candidate` becomes a
/// counted rep lives here, named, and nowhere else — that concentration is
/// deliberate (this task's brief: "this is where the judgment lives").
///
/// ## Why amplitude, not dwell time (SPEC §7.2)
///
/// The original spec's `MIN_PHASE_MS` of 150–250 ms assumes the lifter
/// pauses at the bottom. Explosive lifters don't, and missing a real rep is
/// a worse failure than counting a twitch. A minimum swept displacement
/// rejects noise for the same reason a dwell requirement does, but stays
/// speed-neutral — a fast rep and a slow rep of the same depth both clear
/// the same amplitude bar. `A_min` (`Threshold`) is therefore the primary
/// gate. The 80 ms phase-duration floor (`minimumPhaseDurationSeconds`)
/// stays only to kill single-frame spikes; it is not a second amplitude
/// gate wearing a stopwatch, and must never grow into one.
///
/// ## The four independent checks
///
/// `evaluate(candidate:signalSamples:postureHistory:)` runs all four checks
/// — amplitude, phase duration, confidence, posture — unconditionally and
/// collects every one that fails into `Rejection.reasons`. It does not
/// short-circuit on the first failure: a rep that failed on both amplitude
/// and confidence is more debuggable as "both" than as whichever one
/// happened to be checked first (this task's brief).
///
/// ## The one thing that *does* short-circuit: scale mismatch
///
/// `A_min` (`Threshold`) is either metres or a fraction of torso length,
/// and which one is valid depends on the `RepSignal.ScaleSource` the
/// candidate's own signal was produced against (SPEC §7.2: "expressed in
/// metres when scale is `plateDiameter` or `lidarBodyHeight`, and as a
/// fraction of torso length otherwise" — `ScaleSource.isMetricallyTrustworthy`
/// already encodes exactly that split). Unlike the four accept criteria,
/// this is not a judgment about one candidate — it's a structural
/// precondition for the other four checks meaning anything at all, since a
/// metres number and a torso-fraction number can both be, say, `0.05`,
/// while meaning wildly different things. `Configuration.init` refuses
/// (`throws ConfigurationError.scaleMismatch`) to construct a gate whose
/// threshold and scale disagree, so a mismatched gate cannot exist to be
/// evaluated in the first place — the "type-level or validated distinction"
/// this task requires. There is no public initializer that bypasses this.
public struct AmplitudeGate: Sendable {

    // MARK: - A_min, scale-typed

    /// `A_min` (SPEC §7.2), carrying its own unit so a caller cannot pass a
    /// metres value where a torso-length fraction was meant, or vice versa,
    /// and have it merely type-check. Which case is *valid* against a given
    /// `RepSignal.ScaleSource` is enforced by `Configuration.init`, not by
    /// this enum alone — see the type doc, "The one thing that does
    /// short-circuit."
    public enum Threshold: Sendable, Equatable {
        /// Metres, peak-to-valley. Valid only when the signal's scale is
        /// `.plateDiameter` or `.lidarBodyHeight` (`isMetricallyTrustworthy
        /// == true`).
        case metres(Double)

        /// Dimensionless fraction of torso length, peak-to-valley. Valid
        /// only when the signal's scale is `.referenceHeight` or
        /// `.torsoRelative` (`isMetricallyTrustworthy == false`).
        case torsoLengthFraction(Double)

        /// The bare numeric threshold, regardless of unit. Only meaningful
        /// once compared against an amplitude expressed in the same unit —
        /// which `Configuration`'s validated pairing with a `ScaleSource`
        /// is what guarantees.
        public var value: Double {
            switch self {
            case .metres(let value): value
            case .torsoLengthFraction(let value): value
            }
        }

        fileprivate var isValid: Bool {
            value.isFinite && value >= 0
        }
    }

    // MARK: - Configuration errors

    /// Everything that can go wrong constructing a `Configuration`. Every
    /// case names the offending value, matching this codebase's error style
    /// (`PlateConfigurationError`, `MetricScale.RejectionReason`) — a
    /// refused configuration should be debuggable from the error alone.
    public enum ConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
        /// `threshold`'s unit doesn't match what `scale` allows — e.g. a
        /// `.metres` threshold against `.torsoRelative`, or a
        /// `.torsoLengthFraction` threshold against `.plateDiameter`. See
        /// the type doc's "The one thing that does short-circuit."
        case scaleMismatch(threshold: Threshold, scale: RepSignal.ScaleSource)

        /// `threshold`'s numeric value is non-finite or negative.
        case invalidThreshold(Threshold)

        /// `minimumMeanConfidence` (`C_min`) is outside `0...1`.
        case invalidMinimumMeanConfidence(Double)

        /// `minimumPhaseDurationSeconds` is non-finite or negative.
        case invalidMinimumPhaseDurationSeconds(Double)

        public var description: String {
            switch self {
            case .scaleMismatch(let threshold, let scale):
                "AmplitudeGate threshold \(threshold) does not match scale \(scale) — "
                    + "metres thresholds require a metrically-trustworthy scale (plateDiameter/lidarBodyHeight), "
                    + "torso-length-fraction thresholds require the opposite."
            case .invalidThreshold(let threshold):
                "AmplitudeGate threshold \(threshold) must be finite and >= 0"
            case .invalidMinimumMeanConfidence(let value):
                "AmplitudeGate minimumMeanConfidence \(value) must be finite and in 0...1"
            case .invalidMinimumPhaseDurationSeconds(let value):
                "AmplitudeGate minimumPhaseDurationSeconds \(value) must be finite and >= 0"
            }
        }
    }

    // MARK: - Configuration

    public struct Configuration: Sendable, Equatable {
        /// `A_min` (SPEC §7.2), unit-tagged. See `Threshold`.
        public let threshold: Threshold

        /// The `RepSignal.ScaleSource` `threshold` was validated against at
        /// construction. A gate built for one scale must not be reused
        /// against samples produced under a different one — callers wire
        /// one `AmplitudeGate` per `RepSignal` (scale is fixed for the
        /// life of a signal, `RepSignal.scale` is a `let`), same as every
        /// other scale-aware type in this codebase.
        public let scale: RepSignal.ScaleSource

        /// `C_min` (SPEC §7.2): minimum mean `RepSignal.Sample.confidence`
        /// over the candidate's `[startPeak.t, endPeak.t]` window, `0...1`.
        public let minimumMeanConfidence: Double

        /// The 80 ms single-frame-spike floor (SPEC §7.2). Deliberately
        /// **not** a second amplitude gate: this only exists to kill a
        /// one- or two-frame spike that happens to also clear `A_min` (a
        /// large, near-instantaneous sensor glitch). It must stay small
        /// relative to a real rep's "order of a second or more" half-cycle
        /// (SPEC §7.2) — configurable because every threshold in this file
        /// is, not because there is any intent for this one to grow into a
        /// dwell-time gate. Defaults to `AmplitudeGate
        /// .defaultMinimumPhaseDurationSeconds`.
        public let minimumPhaseDurationSeconds: Double

        /// 80 ms — SPEC §7.2's own number for the spike floor, verbatim.
        public static let defaultMinimumPhaseDurationSeconds: Double = 0.080

        /// Validates and constructs a `Configuration`. Throws rather than
        /// preconditions (unlike most `Configuration` types in this
        /// codebase) specifically for `threshold`/`scale` mismatch, so a
        /// caller wiring a mismatched pair gets a catchable, debuggable
        /// refusal instead of a fatal trap or — worse — a silently wrong
        /// comparison (this task's "must not be able to... get a
        /// plausible-looking wrong answer").
        public init(
            threshold: Threshold,
            scale: RepSignal.ScaleSource,
            minimumMeanConfidence: Double,
            minimumPhaseDurationSeconds: Double = Configuration.defaultMinimumPhaseDurationSeconds
        ) throws {
            guard threshold.isValid else {
                throw ConfigurationError.invalidThreshold(threshold)
            }
            switch threshold {
            case .metres:
                guard scale.isMetricallyTrustworthy else {
                    throw ConfigurationError.scaleMismatch(threshold: threshold, scale: scale)
                }
            case .torsoLengthFraction:
                guard !scale.isMetricallyTrustworthy else {
                    throw ConfigurationError.scaleMismatch(threshold: threshold, scale: scale)
                }
            }
            guard minimumMeanConfidence.isFinite, (0...1).contains(minimumMeanConfidence) else {
                throw ConfigurationError.invalidMinimumMeanConfidence(minimumMeanConfidence)
            }
            guard minimumPhaseDurationSeconds.isFinite, minimumPhaseDurationSeconds >= 0 else {
                throw ConfigurationError.invalidMinimumPhaseDurationSeconds(minimumPhaseDurationSeconds)
            }
            self.threshold = threshold
            self.scale = scale
            self.minimumMeanConfidence = minimumMeanConfidence
            self.minimumPhaseDurationSeconds = minimumPhaseDurationSeconds
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Posture query interface

    /// One posture-gate observation this gate can consult — the interface
    /// `evaluate` needs from `PostureGate` (this task: "define the query
    /// interface you need on your own side"). A caller running `PostureGate
    /// .advance(_:t:)` alongside `ZeroCrossCounter.observe(...)` records
    /// one of these per frame (the same `t` as the frame's `RepSignal
    /// .Sample`); `evaluate` then reads back exactly the slice spanning a
    /// given candidate's cycle. This file never drives `PostureGate`
    /// itself — it only reads the history a caller already produced,
    /// keeping `AmplitudeGate` free of `PostureGate`'s own per-frame
    /// stepping logic.
    public struct PostureObservation: Sendable, Equatable {
        /// Capture timestamp, same clock as `RepSignal.Sample.t` and
        /// `ZeroCrossCounter.Extremum.t`.
        public let t: TimeInterval
        /// The gate's state as of this frame (`PostureGate.advance`'s
        /// return value for the frame at `t`).
        public let state: PostureGate.State

        public init(t: TimeInterval, state: PostureGate.State) {
            self.t = t
            self.state = state
        }
    }

    // MARK: - Rejection reasons

    /// Why one accept criterion failed, carrying the offending numbers —
    /// never a bare category (this task: "the reason must carry the
    /// offending numbers, not just a category").
    public enum FailureReason: Sendable, Equatable {
        /// The candidate's amplitude (the smaller of its descent and
        /// ascent legs — see `evaluate`'s doc) fell short of `A_min`.
        case amplitudeTooSmall(amplitude: Double, descent: Double, ascent: Double, requiredAMin: Double)

        /// The candidate's phase duration (the smaller of its descent and
        /// ascent legs) fell short of the 80 ms spike floor.
        case phaseDurationTooShort(
            durationSeconds: Double, descentSeconds: Double, ascentSeconds: Double, requiredSeconds: Double)

        /// Mean `RepSignal.Sample.confidence` over the cycle fell short of
        /// `C_min`.
        case confidenceTooLow(meanConfidence: Double, requiredCMin: Double)

        /// No `RepSignal.Sample` fell within `[startPeak.t, endPeak.t]`, so
        /// mean confidence cannot be computed at all. Failed closed rather
        /// than treated as vacuously passing — an unmeasurable cycle is not
        /// an evidenced one.
        case noConfidenceSamplesInWindow(windowStart: TimeInterval, windowEnd: TimeInterval)

        /// The posture gate was not `.open` for the entire cycle — it
        /// dipped at `dippedAt`, for the reason it was closed at that
        /// instant. Checked across the whole `[startPeak.t, endPeak.t]`
        /// window, not merely at the two endpoints (this task: "throughout,
        /// not endpoints") — a dip strictly inside the window that both
        /// endpoints straddle still fails this.
        case postureNotHeldThroughout(dippedAt: TimeInterval, reason: PostureGate.Reason)

        /// No `PostureObservation` fell within `[startPeak.t, endPeak.t]`,
        /// so "held throughout" cannot be confirmed. Failed closed, same
        /// reasoning as `.noConfidenceSamplesInWindow`.
        case noPostureDataInWindow(windowStart: TimeInterval, windowEnd: TimeInterval)
    }

    /// A rejected candidate's full set of failing reasons — never empty,
    /// and never truncated to the first failure (this task: "reported
    /// honestly rather than short-circuiting").
    public struct Rejection: Sendable, Equatable {
        public let reasons: [FailureReason]

        public init(reasons: [FailureReason]) {
            precondition(!reasons.isEmpty, "AmplitudeGate.Rejection.reasons must not be empty")
            self.reasons = reasons
        }
    }

    /// A candidate that cleared every bar. Carries the measured numbers —
    /// useful for the trace, and for tests asserting *why* something
    /// passed, not only that it did.
    public struct Acceptance: Sendable, Equatable {
        public let amplitude: Double
        public let phaseDurationSeconds: Double
        public let meanConfidence: Double
    }

    public enum Outcome: Sendable, Equatable {
        case accepted(Acceptance)
        case rejected(Rejection)

        public var isAccepted: Bool {
            if case .accepted = self { true } else { false }
        }
    }

    // MARK: - Evaluation

    /// Judges one `ZeroCrossCounter.Candidate` against every accept
    /// criterion in SPEC §7.2's pseudocode, independently, and reports
    /// every failure rather than the first one.
    ///
    /// - Parameters:
    ///   - candidate: the peak → valley → peak cycle to judge.
    ///   - signalSamples: the `RepSignal.Sample`s the candidate's signal was
    ///     built from (or any superset covering the cycle) — filtered here
    ///     to `[startPeak.t, endPeak.t]` to compute mean confidence.
    ///   - postureHistory: one `PostureObservation` per frame the posture
    ///     gate advanced through, covering at least the candidate's window —
    ///     filtered here the same way to check "held throughout."
    ///
    /// **Amplitude and phase duration are both measured per leg** — the
    /// descent (`startPeak` → `valley`) and the ascent (`valley` →
    /// `endPeak`) — and the *smaller* of the two legs is what's compared
    /// against `A_min` / the 80 ms floor. A rep is not fully swept unless
    /// both halves of it are: a candidate that plunges a full range on the
    /// way down but barely rises on the way back up is not the same event
    /// as a clean rep, and using only one leg (or an average that a big
    /// leg could carry a tiny one through) would accept it anyway.
    public func evaluate(
        candidate: ZeroCrossCounter.Candidate,
        signalSamples: [RepSignal.Sample],
        postureHistory: [PostureObservation]
    ) -> Outcome {
        var reasons: [FailureReason] = []

        let descentAmplitude = abs(candidate.startPeak.x - candidate.valley.x)
        let ascentAmplitude = abs(candidate.endPeak.x - candidate.valley.x)
        let amplitude = min(descentAmplitude, ascentAmplitude)
        if amplitude < configuration.threshold.value {
            reasons.append(
                .amplitudeTooSmall(
                    amplitude: amplitude, descent: descentAmplitude, ascent: ascentAmplitude,
                    requiredAMin: configuration.threshold.value))
        }

        let descentSeconds = candidate.valley.t - candidate.startPeak.t
        let ascentSeconds = candidate.endPeak.t - candidate.valley.t
        let phaseDurationSeconds = min(descentSeconds, ascentSeconds)
        if phaseDurationSeconds < configuration.minimumPhaseDurationSeconds {
            reasons.append(
                .phaseDurationTooShort(
                    durationSeconds: phaseDurationSeconds, descentSeconds: descentSeconds, ascentSeconds: ascentSeconds,
                    requiredSeconds: configuration.minimumPhaseDurationSeconds))
        }

        let windowStart = candidate.startPeak.t
        let windowEnd = candidate.endPeak.t
        let confidenceSamples = signalSamples.filter { $0.t >= windowStart && $0.t <= windowEnd }
        var meanConfidence = 0.0
        if confidenceSamples.isEmpty {
            reasons.append(.noConfidenceSamplesInWindow(windowStart: windowStart, windowEnd: windowEnd))
        } else {
            meanConfidence = confidenceSamples.reduce(0.0) { $0 + $1.confidence } / Double(confidenceSamples.count)
            if meanConfidence < configuration.minimumMeanConfidence {
                reasons.append(
                    .confidenceTooLow(meanConfidence: meanConfidence, requiredCMin: configuration.minimumMeanConfidence))
            }
        }

        let postureSamples = postureHistory.filter { $0.t >= windowStart && $0.t <= windowEnd }
        if postureSamples.isEmpty {
            reasons.append(.noPostureDataInWindow(windowStart: windowStart, windowEnd: windowEnd))
        } else if let dip = postureSamples.first(where: { !$0.state.isOpen }) {
            reasons.append(
                .postureNotHeldThroughout(
                    dippedAt: dip.t, reason: dip.state.reason ?? .insufficientMotionData))
        }

        guard reasons.isEmpty else {
            return .rejected(Rejection(reasons: reasons))
        }
        return .accepted(
            Acceptance(amplitude: amplitude, phaseDurationSeconds: phaseDurationSeconds, meanConfidence: meanConfidence))
    }
}
