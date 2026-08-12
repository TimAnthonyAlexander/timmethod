import Foundation

/// How `ClipEvaluation`'s false-positive/false-negative counts were
/// derived (SPEC §15's "Per-clip: ... false positives, false negatives").
///
/// `Fixture.perRepTimestamps` is optional and usually absent (see
/// `Fixture.swift`'s doc comment). Per-rep matching is only meaningful when
/// both a ground-truth timestamp per rep *and* a predicted timestamp per
/// rep exist; when either is missing, the harness must not pretend to know
/// *which* rep disagreed, only *how many* did. This type is what makes that
/// distinction visible in the report instead of silently blending an exact
/// count with a guessed one.
public enum FPFNBasis: String, Sendable, Equatable, Codable {
    /// `Fixture.perRepTimestamps` and `RepCountResult.repTimestamps` were
    /// both available; false positives/negatives are the unmatched
    /// timestamps from a nearest-neighbour match within a tolerance window.
    /// Precise, and per-rep timestamps are populated on the evaluation.
    case timestampMatched

    /// At least one side had no timestamps. False positives/negatives are
    /// derived from `|predictedCount - trueCount|` alone — honest about
    /// what counts alone can tell you (how many reps disagree) and silent
    /// about what they can't (which ones, or where in the signal). Per-rep
    /// timestamps on the evaluation are `nil` in this case, never `[]`
    /// standing in for "none found."
    case countDerived
}

/// Score for one fixture clip against one counter prediction (SPEC §15's
/// "Per-clip" bullet). Pure data — produced by `ClipEvaluator.evaluate`,
/// which does no I/O, so this is unit-testable against hand-built
/// `Fixture`/`RepCountResult` values without touching a filesystem or a
/// video.
public struct ClipEvaluation: Sendable, Equatable, Codable {
    /// The fixture's base filename (e.g. `"barbell_back_squat"`) — stable,
    /// unique per clip, and what trace-dump filenames and table rows key
    /// off of.
    public var name: String
    public var exerciseId: String
    public var equipment: Equipment
    public var cameraPosition: CameraPosition

    public var trueCount: Int
    public var predictedCount: Int
    /// `predictedCount - trueCount`. Positive means the counter over-counted.
    public var delta: Int
    public var isCountCorrect: Bool
    /// `abs(delta) <= 1` — deliberately `<=`, not `==`, per SPEC §15.2's
    /// "off-by-one accuracy": a clip the counter got exactly right also
    /// counts as within-one, it isn't a disjoint bucket from "correct."
    public var isWithinOffByOne: Bool

    public var truePartialCount: Int
    /// `nil` when the counter does not classify partials at all — see
    /// `RepCountResult.partialCount`.
    public var predictedPartialCount: Int?

    public var falsePositiveCount: Int
    public var falseNegativeCount: Int
    public var fpFnBasis: FPFNBasis
    /// Non-nil only when `fpFnBasis == .timestampMatched`.
    public var falsePositiveTimestamps: [TimeInterval]?
    /// Non-nil only when `fpFnBasis == .timestampMatched`.
    public var falseNegativeTimestamps: [TimeInterval]?
    /// The tolerance window used for timestamp matching. Non-nil only when
    /// `fpFnBasis == .timestampMatched` — recorded so a report reader can
    /// judge how strict the match was without reading source.
    public var matchToleranceSeconds: TimeInterval?

    public init(
        name: String,
        exerciseId: String,
        equipment: Equipment,
        cameraPosition: CameraPosition,
        trueCount: Int,
        predictedCount: Int,
        truePartialCount: Int,
        predictedPartialCount: Int?,
        falsePositiveCount: Int,
        falseNegativeCount: Int,
        fpFnBasis: FPFNBasis,
        falsePositiveTimestamps: [TimeInterval]?,
        falseNegativeTimestamps: [TimeInterval]?,
        matchToleranceSeconds: TimeInterval?
    ) {
        self.name = name
        self.exerciseId = exerciseId
        self.equipment = equipment
        self.cameraPosition = cameraPosition
        self.trueCount = trueCount
        self.predictedCount = predictedCount
        self.delta = predictedCount - trueCount
        self.isCountCorrect = self.delta == 0
        self.isWithinOffByOne = abs(self.delta) <= 1
        self.truePartialCount = truePartialCount
        self.predictedPartialCount = predictedPartialCount
        self.falsePositiveCount = falsePositiveCount
        self.falseNegativeCount = falseNegativeCount
        self.fpFnBasis = fpFnBasis
        self.falsePositiveTimestamps = falsePositiveTimestamps
        self.falseNegativeTimestamps = falseNegativeTimestamps
        self.matchToleranceSeconds = matchToleranceSeconds
    }
}

/// Scores one clip. No I/O, no dependency on `ReplayFrameSource` or
/// `FixtureLoader` — takes already-loaded ground truth and an
/// already-computed prediction, so `EvalTests` can hand-build both sides
/// and assert on the arithmetic directly (SPEC §15's regression-gate goal
/// depends on this being trustworthy, which starts with it being testable).
public enum ClipEvaluator {
    /// Default window for nearest-neighbour timestamp matching, seconds.
    /// A judgment call: wide enough to tolerate the counter marking a rep's
    /// completion a fraction of a second away from the labeller's own
    /// keyboard-toggle timing (SPEC §15.1 notes 1–5× real-time labelling
    /// precision), tight enough that two genuinely different reps in a
    /// normal-tempo set are never matched to each other.
    public static let defaultMatchTolerance: TimeInterval = 0.75

    public static func evaluate(
        name: String,
        fixture: Fixture,
        prediction: RepCountResult,
        matchTolerance: TimeInterval = defaultMatchTolerance
    ) -> ClipEvaluation {
        let delta = prediction.repCount - fixture.trueRepCount

        let falsePositiveCount: Int
        let falseNegativeCount: Int
        let basis: FPFNBasis
        let falsePositiveTimestamps: [TimeInterval]?
        let falseNegativeTimestamps: [TimeInterval]?
        let toleranceUsed: TimeInterval?

        if let trueTimestamps = fixture.perRepTimestamps, !prediction.repTimestamps.isEmpty {
            let match = matchTimestamps(true: trueTimestamps, predicted: prediction.repTimestamps, tolerance: matchTolerance)
            falsePositiveCount = match.falsePositives.count
            falseNegativeCount = match.falseNegatives.count
            basis = .timestampMatched
            falsePositiveTimestamps = match.falsePositives
            falseNegativeTimestamps = match.falseNegatives
            toleranceUsed = matchTolerance
        } else {
            // Refuse rather than guess which rep disagreed — only the count
            // of disagreements is honestly derivable from counts alone.
            falsePositiveCount = max(0, delta)
            falseNegativeCount = max(0, -delta)
            basis = .countDerived
            falsePositiveTimestamps = nil
            falseNegativeTimestamps = nil
            toleranceUsed = nil
        }

        return ClipEvaluation(
            name: name,
            exerciseId: fixture.exerciseId,
            equipment: fixture.equipment,
            cameraPosition: fixture.cameraPosition,
            trueCount: fixture.trueRepCount,
            predictedCount: prediction.repCount,
            truePartialCount: fixture.truePartialCount,
            predictedPartialCount: prediction.partialCount,
            falsePositiveCount: falsePositiveCount,
            falseNegativeCount: falseNegativeCount,
            fpFnBasis: basis,
            falsePositiveTimestamps: falsePositiveTimestamps,
            falseNegativeTimestamps: falseNegativeTimestamps,
            matchToleranceSeconds: toleranceUsed
        )
    }

    /// Greedy nearest-neighbour matching, not a globally-optimal bipartite
    /// assignment — a deliberate simplicity trade-off for the small
    /// per-clip rep counts (single digits to low tens) this harness scores.
    /// Predicted timestamps are matched in time order against the closest
    /// still-unmatched true timestamp within `tolerance`; anything left
    /// over on either side is a false positive or false negative.
    private static func matchTimestamps(
        true trueTimestamps: [TimeInterval],
        predicted: [TimeInterval],
        tolerance: TimeInterval
    ) -> (falsePositives: [TimeInterval], falseNegatives: [TimeInterval]) {
        var matchedTrueIndices = Set<Int>()
        var falsePositives: [TimeInterval] = []

        for predictedTime in predicted.sorted() {
            var bestIndex: Int?
            var bestDistance = Double.infinity
            for (index, trueTime) in trueTimestamps.enumerated() where !matchedTrueIndices.contains(index) {
                let distance = abs(trueTime - predictedTime)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            if let bestIndex, bestDistance <= tolerance {
                matchedTrueIndices.insert(bestIndex)
            } else {
                falsePositives.append(predictedTime)
            }
        }

        let falseNegatives = trueTimestamps.enumerated()
            .filter { !matchedTrueIndices.contains($0.offset) }
            .map(\.element)

        return (falsePositives, falseNegatives)
    }
}
