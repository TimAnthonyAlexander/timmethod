import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// The real Track A pipeline (SPEC §3, §8), assembled end to end (W3-07):
///
/// ```
/// FrameSource → PlateTracker (→ PlateDetector) → MetricScale → MotionAxis
///   → RepSignal → SignalConditioningPipeline → ZeroCrossCounter
///   → AmplitudeGate (A_min driven by RangeCalibration.SetCalibration)
///   with PostureGate gating every frame
/// ```
///
/// Every component above was built and unit-tested in isolation, each
/// against synthetic input it constructed for itself. Nothing before this
/// file ever ran two of them back to back. That is the entire reason this
/// file exists: the seams between components — not the components
/// themselves — are where isolated units actually fail.
///
/// ## The `RepCounting` seam
///
/// `RepCounting.count(signal:)` takes an already-built `RepSignal` — a bare
/// `[(t, x, confidence)]` sequence with no per-frame `PostureGate` state, no
/// raw tracker output, and no `MotionAxis.Projection.lateral`. That is
/// genuinely too narrow a shape for this pipeline: `AmplitudeGate` needs
/// posture history spanning each candidate's window, and posture history
/// can only be built by advancing `PostureGate` frame by frame alongside
/// `PlateTracker`/`MotionAxis`, which a bare `RepSignal` cannot reconstruct
/// after the fact. `RepCounting.swift` itself (the protocol definition, and
/// `StubRepCounter`) is outside this task's file-ownership boundary, so it
/// is not modified here — ideally `RepCounting` would grow a frame-native
/// method, and that extension is left to a future task.
///
/// `TrackARepCounter` resolves this by being two things:
///
/// 1. **The real entry point**: `run(frames:plateConfiguration:)`, an async
///    method that drives a `FrameSource` frame by frame and returns a
///    `FrameResult` carrying the built `RepSignal`, the `RepCountResult`,
///    and every candidate's gate outcome (accepted or rejected, with
///    reasons) for tracing. `timmethod-eval` (`FrameReplay.swift`) calls
///    this directly — never through the `RepCounting` protocol — because
///    only this path has real per-frame posture evidence to gate on.
/// 2. **An honest, reduced-fidelity `RepCounting` conformer**
///    (`count(signal:)`, below): everything downstream of `RepSignal` —
///    conditioning, zero-crossing, the amplitude gate, and range
///    calibration — run exactly as they do in `run(frames:...)`, but
///    posture is treated as `.open` throughout, since a bare `RepSignal`
///    carries no posture evidence to gate on. This is real, documented
///    degraded fidelity — not a stub — and it is what makes
///    `TrackARepCounter` an actual `RepCounting` conformer, satisfying this
///    task's brief ("One `RepCounting` conformer that runs the real Track A
///    pipeline end to end") without a change to `RepCounting.swift`.
///
/// ## Plate diameter: refused, not assumed
///
/// This type never defaults a plate diameter. `plateConfiguration` is a
/// required, non-optional `PlateConfiguration` on `run(frames:...)` — the
/// decision of *whether* Track A even runs for a given clip belongs to the
/// caller, which reads it from the fixture sidecar via
/// `PlateConfigurationLookup.requireConfiguration()` (see `FrameReplay
/// .swift`) and never reaches this type at all when no diameter is
/// configured. See `PlateConfiguration.swift`'s `PlateConfigurationLookup`
/// for the refusal machinery this reuses rather than reinvents.
///
/// ## Do not tune
///
/// Every parameter this file introduces is either an existing component's
/// own documented default, or derived arithmetically from one (see
/// `derivedDetectorConfiguration`). Nothing here is fit against a fixture.
/// W3-06 tunes against real footage; tuning against the synthetic clips
/// this task's own tests use would fit the generator, not the lift.
public struct TrackARepCounter: Sendable {

    // MARK: - Configuration

    /// The handful of cross-cutting numbers this file needs to wire
    /// components together. Deliberately not a pass-through for every
    /// tunable on every component below it — anything not listed here uses
    /// that component's own shipped default untouched, which is what keeps
    /// this type honest about not tuning anything (see type doc).
    public struct Configuration: Sendable, Equatable {
        /// Feeds both `MetricScale.focalLengthPx` (its sanity-bounds check)
        /// and this file's own derivation of `PlateDetector.Configuration
        /// .minRadiusPx`/`.maxRadiusPx` from the configured plate diameter
        /// (see `derivedDetectorConfiguration`) — the same assumption used
        /// for both, so a detector's search range and the scale's own
        /// distance sanity check agree with each other by construction.
        public var focalLengthPx: Double

        /// `MetricScale.defaultDistanceBoundsMetres` by default. Also feeds
        /// `derivedDetectorConfiguration`'s pixel-radius range: the plate's
        /// apparent size at the near bound sets `maxRadiusPx`, at the far
        /// bound sets `minRadiusPx`.
        public var distanceBoundsMetres: ClosedRange<Double>

        /// `C_min` (SPEC §7.2): the amplitude gate's minimum mean
        /// confidence over a candidate's cycle. No component in this
        /// codebase documents a shipped default for this number — W3-03
        /// (`AmplitudeGate`) takes it as a required, caller-supplied value,
        /// and W3-06 is the task that tunes it against real footage.
        /// `0.5` matches `AmplitudeGateTests`' own default fixture value —
        /// the closest thing to an established convention that exists
        /// today — and is flagged in this task's report as an untuned
        /// placeholder, not a considered choice.
        public var minimumMeanConfidence: Double

        /// The bootstrap floor `RangeCalibration.SetCalibration` uses before
        /// three reps have established a real range, when no cross-session
        /// baseline exists yet (`RangeCalibration.seedFloor`'s
        /// `coldStartFloor` parameter — see that function's doc: "the
        /// defensible choice ... is whatever `AmplitudeGate.Configuration
        /// .threshold` is already statically configured to today"). No
        /// such static value is documented anywhere in this codebase
        /// either; `0.05` (metres) is this task's own untuned placeholder,
        /// flagged in its report the same way `minimumMeanConfidence` is.
        public var coldStartFloorMetres: Double

        public init(
            focalLengthPx: Double = MetricScale.defaultFocalLengthPx,
            distanceBoundsMetres: ClosedRange<Double> = MetricScale.defaultDistanceBoundsMetres,
            minimumMeanConfidence: Double = TrackARepCounter.defaultMinimumMeanConfidence,
            coldStartFloorMetres: Double = TrackARepCounter.defaultColdStartFloorMetres
        ) {
            self.focalLengthPx = focalLengthPx
            self.distanceBoundsMetres = distanceBoundsMetres
            self.minimumMeanConfidence = minimumMeanConfidence
            self.coldStartFloorMetres = coldStartFloorMetres
        }
    }

    /// See `Configuration.minimumMeanConfidence`'s doc.
    public static let defaultMinimumMeanConfidence: Double = 0.5
    /// See `Configuration.coldStartFloorMetres`'s doc.
    public static let defaultColdStartFloorMetres: Double = 0.05

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Frame-native output

    /// One evaluated `ZeroCrossCounter.Candidate`, kept alongside its
    /// `AmplitudeGate.Outcome` — accepted or rejected, with every failing
    /// reason — for tracing (this task item 4: "every rejected candidate's
    /// reason reaches the trace dump").
    public struct CandidateOutcome: Sendable {
        public let candidate: ZeroCrossCounter.Candidate
        public let outcome: AmplitudeGate.Outcome

        public init(candidate: ZeroCrossCounter.Candidate, outcome: AmplitudeGate.Outcome) {
            self.candidate = candidate
            self.outcome = outcome
        }
    }

    /// Everything one full clip's replay through `run(frames:...)`
    /// produces: the `RepSignal` it built (for the trace's waveform), the
    /// scored `RepCountResult`, every candidate's gate outcome, and two
    /// frame-level tallies (`frameCount`, `metricScaleRejectionCount`) that
    /// make a wrong count on real footage diagnosable without a rebuild.
    public struct FrameResult: Sendable {
        public let signal: RepSignal
        public let result: RepCountResult
        public let candidateOutcomes: [CandidateOutcome]
        public let frameCount: Int
        /// How many frames `PlateTracker` measured or bridged a plate on,
        /// but `MetricScale` rejected the implied scale (too near, too far,
        /// or an invalid major axis) — see `run(frames:...)`'s doc, "Metric
        /// scale rejection is a gap too."
        public let metricScaleRejectionCount: Int

        public init(
            signal: RepSignal, result: RepCountResult, candidateOutcomes: [CandidateOutcome],
            frameCount: Int, metricScaleRejectionCount: Int
        ) {
            self.signal = signal
            self.result = result
            self.candidateOutcomes = candidateOutcomes
            self.frameCount = frameCount
            self.metricScaleRejectionCount = metricScaleRejectionCount
        }
    }

    // MARK: - The real, frame-native pipeline

    /// Drains `source` frame by frame through the full chain described in
    /// this type's doc, and scores the result. `plateConfiguration` is
    /// required and never defaulted — see type doc, "Plate diameter:
    /// refused, not assumed"; a caller with no configured diameter must not
    /// call this at all (see `FrameReplay.swift`).
    ///
    /// ## Metric scale rejection is a gap too
    ///
    /// `PlateTracker` can report `.measured`/`.interpolated` (a plate was
    /// found) while `MetricScale.observe(majorAxisPx:)` still rejects that
    /// same frame (an implied camera distance outside `distanceBoundsMetres`,
    /// or a non-finite/non-positive major axis) — these are independent
    /// checks over different questions ("is there a plate-shaped contour
    /// here" vs. "does the resulting scale make physical sense"). When that
    /// happens there is no metres position to hand `MotionAxis` for that
    /// frame, so it is fed `.lost` — the same honest "nothing to report"
    /// this codebase uses everywhere else a measurement doesn't clear its
    /// own sanity bar (`MetricScale.RejectionReason`'s own doc: "never
    /// silently clamped").
    ///
    /// ## Posture is recorded every frame, not just at a candidate's close
    ///
    /// `AmplitudeGate.evaluate` reads `postureHistory` filtered to a
    /// candidate's `[startPeak.t, endPeak.t]` window — a window that can
    /// span frames with no `RepSignal` sample at all (a `MotionAxis` gap
    /// mid-window). `PostureGate.advance` is therefore called, and its
    /// result recorded, on **every** processed frame, independent of
    /// whether that frame produced a `RepSignal` sample — the friction the
    /// task brief names directly: "posture state must be retained per
    /// frame, not just sampled at the moment a candidate closes."
    public func run(
        frames source: FrameSource,
        plateConfiguration: PlateConfiguration
    ) async throws -> FrameResult {
        try await source.start()

        var tracker = PlateTracker(
            configuration: PlateTracker.Configuration(
                detectorConfiguration: Self.derivedDetectorConfiguration(
                    plateConfiguration: plateConfiguration,
                    focalLengthPx: configuration.focalLengthPx,
                    distanceBoundsMetres: configuration.distanceBoundsMetres
                ),
                plateConfiguration: plateConfiguration
            )
        )
        var metricScale = MetricScale(
            configuration: plateConfiguration,
            focalLengthPx: configuration.focalLengthPx,
            distanceBoundsMetres: configuration.distanceBoundsMetres
        )
        var motionAxis = MotionAxis()
        var postureGate = PostureGate(
            configuration: .trackA(plateDiameterMetres: plateConfiguration.millimetres / 1000.0)
        )
        var signal = RepSignal(scale: .plateDiameter(mm: plateConfiguration.millimetres))
        var postureHistory: [AmplitudeGate.PostureObservation] = []
        var frameCount = 0
        var metricScaleRejectionCount = 0

        for await frame in source.frames {
            frameCount += 1
            let t = frame.timestamp.seconds

            let trackerResult = tracker.processFrame(frame.buffer, timestamp: t)

            let motionObservation: MotionAxis.Observation
            switch trackerResult {
            case .measured(let observation):
                if let pointMetres = Self.scaledPointMetres(
                    majorAxisPx: observation.majorAxisPx, center: observation.center,
                    metricScale: &metricScale, rejectionCount: &metricScaleRejectionCount
                ) {
                    motionObservation = .measured(pointMetres: pointMetres, confidence: observation.confidence)
                } else {
                    motionObservation = .lost
                }
            case .interpolated(let tracked):
                if let pointMetres = Self.scaledPointMetres(
                    majorAxisPx: tracked.majorAxisPx, center: tracked.center,
                    metricScale: &metricScale, rejectionCount: &metricScaleRejectionCount
                ) {
                    motionObservation = .interpolated(pointMetres: pointMetres, confidence: tracked.confidence)
                } else {
                    motionObservation = .lost
                }
            case .lost:
                motionObservation = .lost
            }

            let motionResult = motionAxis.observe(motionObservation, t: t)
            signal.append(motionResult)  // no-ops on `.gap` — see `RepSignal.append(_ result:)`

            let projection: MotionAxis.Projection? = {
                if case .projected(let projection) = motionResult { projection } else { nil }
            }()
            let postureInput = PostureGate.FrameInput(
                plateTracked: !trackerResult.isLost,
                axialMetres: projection?.axial,
                lateralMetres: projection?.lateral
            )
            let postureState = postureGate.advance(postureInput, t: t)
            postureHistory.append(AmplitudeGate.PostureObservation(t: t, state: postureState))
        }

        await source.stop()

        let (result, candidateOutcomes) = Self.scoreSignal(
            signal, postureHistory: postureHistory, configuration: configuration
        )
        return FrameResult(
            signal: signal, result: result, candidateOutcomes: candidateOutcomes,
            frameCount: frameCount, metricScaleRejectionCount: metricScaleRejectionCount
        )
    }

    /// One frame's `PlateTracker` centroid (pixel space, from either a
    /// `.measured` or `.interpolated` `FrameResult` — both carry a
    /// `majorAxisPx`/`center`), converted through `MetricScale` into a
    /// metres position, or `nil` if `MetricScale` rejects the implied
    /// scale (see `run(frames:...)`'s doc, "Metric scale rejection is a
    /// gap too"). Isolated as a `static` helper — rather than inlined
    /// twice — so the `.measured` and `.interpolated` call sites can never
    /// drift into handling that rejection differently from each other; the
    /// caller alone decides which `MotionAxis.Observation` case to wrap the
    /// result in, since that distinction (measured vs. bridged) must
    /// survive into `MotionAxis`.
    private static func scaledPointMetres(
        majorAxisPx: Double, center: CGPoint, metricScale: inout MetricScale, rejectionCount: inout Int
    ) -> CGPoint? {
        switch metricScale.observe(majorAxisPx: majorAxisPx) {
        case .accepted(let estimate):
            return CGPoint(x: center.x * estimate.metresPerPixel, y: center.y * estimate.metresPerPixel)
        case .rejected:
            rejectionCount += 1
            return nil
        }
    }

    // MARK: - Plate-detector search range, derived (never a tunable)

    /// `PlateDetector.Configuration` deliberately never sees a plate
    /// diameter or subject distance — that derivation belongs to whatever
    /// wires a configured `PlateConfiguration` to it (`PlateDetector`'s own
    /// doc). This is that derivation: the plate's apparent pixel radius at
    /// `distanceBoundsMetres.lowerBound` (the closest a subject is ever
    /// assumed to stand, `MetricScale`'s own sanity bound) sets
    /// `maxRadiusPx`; at `.upperBound` (the farthest) sets `minRadiusPx`.
    /// Plain pinhole projection, using the same `focalLengthPx` assumption
    /// `MetricScale` already uses for its own distance sanity check — so
    /// the detector's search range and the scale's own bounds agree with
    /// each other by construction, rather than being two independently
    /// guessed numbers that could silently disagree.
    ///
    /// The resulting range is wide (roughly 16x at the shipped defaults,
    /// 0.5-8m) by construction, since Track A has to work across whatever
    /// framing a lifter actually uses. See this task's report for the
    /// judgment call that this may be worth narrowing per-clip once real
    /// footage exists (W3-06) rather than staying this permissive.
    static func derivedDetectorConfiguration(
        plateConfiguration: PlateConfiguration,
        focalLengthPx: Double,
        distanceBoundsMetres: ClosedRange<Double>
    ) -> PlateDetector.Configuration {
        let diameterMetres = plateConfiguration.millimetres / 1000.0
        let maxRadiusPx = (diameterMetres * focalLengthPx / distanceBoundsMetres.lowerBound) / 2
        let minRadiusPx = (diameterMetres * focalLengthPx / distanceBoundsMetres.upperBound) / 2
        return PlateDetector.Configuration(minRadiusPx: minRadiusPx, maxRadiusPx: maxRadiusPx)
    }

    // MARK: - Batch scoring: conditioning → zero-cross → gate → calibration

    /// The seam the task brief names directly: `AmplitudeGate` needs
    /// `A_min` before it can judge a candidate, and `RangeCalibration
    /// .SetCalibration` needs judged (accepted) candidates before it can
    /// compute one. Resolved as follows, in order, for each candidate:
    ///
    /// 1. Read the **current** floor from `setCalibration` — `establishedAmplitude
    ///    * partialFraction` (50%) once established, or `configuration
    ///    .seedFloor` during bootstrap (`RangeCalibration`'s own seed rule
    ///    — this task reuses it rather than inventing a second bootstrap,
    ///    per the brief).
    /// 2. Build a fresh `AmplitudeGate` for that floor and evaluate the
    ///    candidate. `AmplitudeGate` has no accumulated state of its own —
    ///    `evaluate` is a pure function of `self.configuration` and its
    ///    arguments — so reconstructing it per candidate from
    ///    `AmplitudeGate.Configuration`'s existing public throwing
    ///    initializer is the whole mechanism; nothing in `AmplitudeGate
    ///    .swift` needed to change for this (see this task's report).
    /// 3. **Why the floor is `partialFraction` (50%), not `fullFraction`
    ///    (80%):** `RangeCalibration`'s own doc puts `A_min` at 80% of
    ///    established range, but also documents a 50-80% *partial* band
    ///    that must still be counted (in a separate ledger), not rejected
    ///    outright. If this gate's amplitude floor were 80%, a genuine
    ///    partial rep would never reach `SetCalibration.observe(amplitude:)`
    ///    at all — it would be indistinguishable from noise. Setting the
    ///    floor at 50% instead makes `AmplitudeGate` answer "is this a rep
    ///    at all, even a partial one" (its actual job: amplitude + phase
    ///    duration + confidence + posture), while `SetCalibration.observe`
    ///    — called only on candidates `AmplitudeGate` already accepted —
    ///    makes the separate full-vs-partial call and does the ratcheting.
    ///    `RangeCalibration.seedFloor` already computes its bootstrap floor
    ///    as `crossSessionMedian * partialFraction` for exactly this
    ///    reason — the 50% floor is the one both mechanisms already agree
    ///    on, not a third number this file invents.
    /// 4. On acceptance, feed the accepted `Acceptance.amplitude` to
    ///    `setCalibration.observe(amplitude:)`, which ratchets the
    ///    established range and classifies the rep `.full` or `.partial`.
    ///    A rejected candidate never reaches `setCalibration` — noise must
    ///    not be able to seed or inflate the range (`RangeCalibration`'s
    ///    own "bootstrap attack" concern, generalised past bootstrap).
    ///
    /// `RepCountResult.repCount` is `fullRepCount + partialRepCount` —
    /// matching `Fixture.trueRepCount`'s documented semantics ("of
    /// `trueRepCount`, how many were partial" — partial is a *subset* of
    /// the total, not additional to it) — and `partialCount` is
    /// `partialRepCount` alone. This is a different number from what SPEC
    /// §7.3 calls the live app's "working rep count" (full-only, partials
    /// shown separately) — that is a UI-facing concept this eval-facing
    /// struct does not represent; see this task's report.
    private static func scoreSignal(
        _ signal: RepSignal, postureHistory: [AmplitudeGate.PostureObservation], configuration: Configuration
    ) -> (RepCountResult, [CandidateOutcome]) {
        let samples = Array(signal.samples)
        let (detrended, velocity) = SignalConditioningPipeline.condition(samples)
        let candidates = ZeroCrossCounter.candidates(detrended: detrended, velocity: velocity)

        guard signal.scale.isMetricallyTrustworthy else {
            // Track A always produces `.plateDiameter` scale (see `run`);
            // this only fires if a caller hands a non-metric signal to
            // `count(signal:)` — see that method's doc.
            return (RepCountResult(repCount: 0), [])
        }

        let seedFloor = RangeCalibration.seedFloor(
            crossSessionMedian: nil,  // no cross-session persistence in this eval harness — always cold start
            coldStartFloor: configuration.coldStartFloorMetres
        )
        var setCalibration = SetCalibration(configuration: SetCalibration.Configuration(seedFloor: seedFloor))

        var repTimestamps: [TimeInterval] = []
        var candidateOutcomes: [CandidateOutcome] = []

        for candidate in candidates {
            let currentFloor =
                setCalibration.establishedAmplitude.map { $0 * setCalibration.configuration.partialFraction }
                ?? setCalibration.configuration.seedFloor

            guard
                let gateConfiguration = try? AmplitudeGate.Configuration(
                    threshold: .metres(currentFloor),
                    scale: signal.scale,
                    minimumMeanConfidence: configuration.minimumMeanConfidence
                )
            else { continue }
            let gate = AmplitudeGate(configuration: gateConfiguration)

            let outcome = gate.evaluate(candidate: candidate, signalSamples: samples, postureHistory: postureHistory)
            candidateOutcomes.append(CandidateOutcome(candidate: candidate, outcome: outcome))

            if case .accepted(let acceptance) = outcome {
                repTimestamps.append(candidate.endPeak.t)
                _ = setCalibration.observe(amplitude: acceptance.amplitude)
            }
        }

        let result = RepCountResult(
            repCount: setCalibration.fullRepCount + setCalibration.partialRepCount,
            repTimestamps: repTimestamps,
            partialCount: setCalibration.partialRepCount
        )
        return (result, candidateOutcomes)
    }
}

// MARK: - RepCounting conformance (reduced fidelity — see type doc)

extension TrackARepCounter: RepCounting {
    /// See type doc, "The `RepCounting` seam." Runs everything downstream
    /// of `RepSignal` exactly as `run(frames:...)` does, with posture
    /// treated as `.open` throughout — a bare `RepSignal` carries no
    /// per-frame posture evidence, so there is nothing honest to gate on
    /// here. `timmethod-eval` does not call this; it calls `run(frames:
    /// plateConfiguration:)` directly for full fidelity.
    public func count(signal: RepSignal) -> RepCountResult {
        let alwaysOpenPosture = signal.samples.map { AmplitudeGate.PostureObservation(t: $0.t, state: .open) }
        let (result, _) = Self.scoreSignal(signal, postureHistory: alwaysOpenPosture, configuration: configuration)
        return result
    }
}
