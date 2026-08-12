import Foundation
import TimMethodCore

/// What lands on disk in `out/traces/` for one wrong-count clip (SPEC §15's
/// "Dump the `signalTrace`... Notes" — "the difference between 'the count
/// was wrong' and 'the count was wrong because the third rep only swept 62%
/// amplitude'").
///
/// Self-contained by design: every field needed to make sense of `trace`
/// without re-running the harness or opening the fixture sidecar — which
/// clip, true vs. predicted, why the disagreement was measured the way it
/// was, and (W3-07) exactly why every candidate rep was accepted or
/// rejected, not just the final count.
struct TraceDump: Codable {
    let fixtureName: String
    let exerciseId: String
    let trueCount: Int
    let predictedCount: Int
    let delta: Int
    let fpFnBasis: String
    let falsePositiveCount: Int
    let falseNegativeCount: Int
    /// Human-readable description of `RepSignal.scale` — `RepSignal.ScaleSource`
    /// has no `Codable` conformance (and `Signal/` isn't this task's file
    /// to add one to), so this is rendered by hand.
    let signalScale: String
    let sampleCount: Int
    /// `RepSignal.trace()` — 128-point linearly-resampled `x`, oldest to
    /// newest. See `RepSignal.trace(targetCount:)`'s doc comment for the
    /// resampling method.
    let trace: [Float]

    /// Total frames replayed for this clip, and how many of those a plate
    /// was found on but `MetricScale` rejected the implied scale anyway
    /// (`TrackARepCounter.FrameResult.metricScaleRejectionCount`'s doc).
    /// `nil` when the caller has no `TrackARepCounter.FrameResult` to draw
    /// these from (the `dump(evaluation:signal:to:)` overload, kept for
    /// callers — including existing tests — that only ever had a bare
    /// `RepSignal`).
    let frameCount: Int?
    let metricScaleRejectionCount: Int?

    /// One entry per `ZeroCrossCounter.Candidate` the gate ever judged,
    /// oldest first — this task item 4's whole payoff: "every rejected
    /// candidate's reason reaches the trace dump, so a wrong count on a
    /// real clip is diagnosable without a rebuild." Empty (never absent)
    /// when the caller has no candidate outcomes to report.
    let candidates: [CandidateTraceEntry]
}

/// One judged candidate, rendered for the trace.
struct CandidateTraceEntry: Codable {
    let startPeakT: TimeInterval
    let valleyT: TimeInterval
    let endPeakT: TimeInterval
    let accepted: Bool
    /// Human-readable failure reasons, each carrying the offending numbers
    /// (`AmplitudeGate.FailureReason`'s own doc: "the reason must carry the
    /// offending numbers, not just a category"). Empty when `accepted`.
    let rejectionReasons: [String]
}

enum TraceDumper {
    static func describe(_ scale: RepSignal.ScaleSource) -> String {
        switch scale {
        case .plateDiameter(let mm):
            "plateDiameter(\(mm)mm)"
        case .lidarBodyHeight(let m):
            "lidarBodyHeight(\(m)m)"
        case .referenceHeight:
            "referenceHeight"
        case .torsoRelative:
            "torsoRelative"
        }
    }

    /// Renders one `PostureGate.Reason` for the trace — every case names
    /// itself specifically enough to answer "why not?" without
    /// cross-referencing anything else (`PostureGate.Reason`'s own doc).
    static func describe(_ reason: PostureGate.Reason) -> String {
        switch reason {
        case .noPlateTracked:
            "no plate tracked this frame"
        case .insufficientMotionData:
            "no motion-axis projection yet this frame"
        case .heightImplausible(let deviation, let limit):
            "height deviated \(deviation)m from baseline, over the \(limit)m limit"
        case .nonWorkingAxisUnstable(let lateralRange, let limit):
            "lateral range \(lateralRange)m over the recent window, over the \(limit)m limit"
        case .poseInconsistent(let pose):
            "pose inconsistent (torso \(pose.torsoOrientationScore), landmark \(pose.landmarkLayoutScore))"
        case .awaitingDwell(let elapsed, let required):
            "awaiting open dwell: \(elapsed)s of \(required)s required"
        }
    }

    /// Renders one `AmplitudeGate.FailureReason` for the trace. See that
    /// type's doc: every case already carries the offending numbers, this
    /// just turns them into prose.
    static func describe(_ reason: AmplitudeGate.FailureReason) -> String {
        switch reason {
        case .amplitudeTooSmall(let amplitude, let descent, let ascent, let requiredAMin):
            "amplitude \(amplitude) (descent \(descent), ascent \(ascent)) below A_min \(requiredAMin)"
        case .phaseDurationTooShort(let duration, let descent, let ascent, let required):
            "phase duration \(duration)s (descent \(descent)s, ascent \(ascent)s) below \(required)s floor"
        case .confidenceTooLow(let meanConfidence, let requiredCMin):
            "mean confidence \(meanConfidence) below C_min \(requiredCMin)"
        case .noConfidenceSamplesInWindow(let start, let end):
            "no signal samples in [\(start), \(end)] to measure confidence from"
        case .postureNotHeldThroughout(let dippedAt, let reason):
            "posture gate dipped at t=\(dippedAt): \(describe(reason))"
        case .noPostureDataInWindow(let start, let end):
            "no posture data in [\(start), \(end)] to confirm the gate was held"
        }
    }

    private static func candidateTrace(_ outcome: TrackARepCounter.CandidateOutcome) -> CandidateTraceEntry {
        let candidate = outcome.candidate
        switch outcome.outcome {
        case .accepted:
            return CandidateTraceEntry(
                startPeakT: candidate.startPeak.t, valleyT: candidate.valley.t, endPeakT: candidate.endPeak.t,
                accepted: true, rejectionReasons: []
            )
        case .rejected(let rejection):
            return CandidateTraceEntry(
                startPeakT: candidate.startPeak.t, valleyT: candidate.valley.t, endPeakT: candidate.endPeak.t,
                accepted: false, rejectionReasons: rejection.reasons.map(describe)
            )
        }
    }

    /// Writes one clip's trace to `<directory>/<fixtureName>.json`, creating
    /// `directory` if it doesn't exist yet. Full-fidelity overload: carries
    /// the real per-candidate gate outcomes (this task item 4) and the
    /// frame-level tallies `TrackARepCounter.run(frames:...)` produces.
    static func dump(
        evaluation: ClipEvaluation,
        frameResult: TrackARepCounter.FrameResult,
        to directory: URL
    ) throws {
        try dump(
            evaluation: evaluation,
            signal: frameResult.signal,
            candidateOutcomes: frameResult.candidateOutcomes,
            frameCount: frameResult.frameCount,
            metricScaleRejectionCount: frameResult.metricScaleRejectionCount,
            to: directory
        )
    }

    /// Writes one clip's trace to `<directory>/<fixtureName>.json`, creating
    /// `directory` if it doesn't exist yet.
    ///
    /// `candidateOutcomes`/`frameCount`/`metricScaleRejectionCount` default
    /// to empty/`nil` so this remains callable with just a bare `RepSignal`
    /// — the shape it had before this task, which existing tests (and any
    /// future caller with no `TrackARepCounter.FrameResult` at hand) still
    /// use unchanged.
    static func dump(
        evaluation: ClipEvaluation,
        signal: RepSignal,
        candidateOutcomes: [TrackARepCounter.CandidateOutcome] = [],
        frameCount: Int? = nil,
        metricScaleRejectionCount: Int? = nil,
        to directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let dump = TraceDump(
            fixtureName: evaluation.name,
            exerciseId: evaluation.exerciseId,
            trueCount: evaluation.trueCount,
            predictedCount: evaluation.predictedCount,
            delta: evaluation.delta,
            fpFnBasis: evaluation.fpFnBasis.rawValue,
            falsePositiveCount: evaluation.falsePositiveCount,
            falseNegativeCount: evaluation.falseNegativeCount,
            signalScale: describe(signal.scale),
            sampleCount: signal.samples.count,
            trace: signal.trace(),
            frameCount: frameCount,
            metricScaleRejectionCount: metricScaleRejectionCount,
            candidates: candidateOutcomes.map(candidateTrace)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(dump)

        let fileURL = directory.appendingPathComponent(evaluation.name).appendingPathExtension("json")
        try data.write(to: fileURL, options: .atomic)
    }
}
