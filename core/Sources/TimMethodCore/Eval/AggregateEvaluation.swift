import Foundation

/// One scalar metric over a set of clips. Carries `sampleCount` alongside
/// `value` so a report reader (or the JSON) never has to guess how much
/// data a percentage or an average is standing on — "98% off-by-one" over 2
/// clips and over 200 means very different things.
public struct Metric: Sendable, Equatable, Codable {
    public var value: Double
    public var sampleCount: Int

    public init(value: Double, sampleCount: Int) {
        self.value = value
        self.sampleCount = sampleCount
    }
}

/// Per-exercise rollup (SPEC §15's "per-exercise breakdown").
public struct ExerciseBreakdown: Sendable, Equatable, Codable {
    public var exerciseId: String
    public var clipCount: Int
    public var countMAE: Metric
    public var offByOneAccuracy: Metric
    public var meanFalsePositives: Metric
    public var meanFalseNegatives: Metric
}

/// Per-camera-angle rollup. `Fixture.CameraPosition` carries
/// `degreesOffPerpendicular` specifically so this breakdown can show
/// accuracy falling off with angle (SPEC §14.3: angle is the documented top
/// failure mode) rather than only reporting a single blended number.
public struct CameraBreakdown: Sendable, Equatable, Codable {
    public var cameraPosition: CameraPosition
    public var degreesOffPerpendicular: Double
    public var clipCount: Int
    public var countMAE: Metric
    public var offByOneAccuracy: Metric
}

/// The aggregate rollup over every scored clip (SPEC §15's "Aggregate"
/// bullet, §15.2's targets table). Every `Metric?` is `nil`, not zero, when
/// there is no clip to compute it from — an empty fixture set or an
/// equipment class nothing in the run belongs to. `EvalGate` depends on
/// that `nil` to distinguish "measured and clean" from "never measured."
public struct AggregateEvaluation: Sendable, Equatable, Codable {
    public var clipCount: Int

    public var countMAEOverall: Metric?
    /// SPEC §15.2 "Count MAE, loaded, plate visible". `loaded` here means
    /// `equipment != .bodyweight` (barbell, dumbbell, machine) — a
    /// deliberate widening of the SPEC row's literal "plate visible"
    /// wording, since `Fixture` has no direct "plate visible" flag and most
    /// dumbbell/machine clips will never carry `plateDiameterMm`. Judgment
    /// call, documented here rather than silently narrowing the floor to
    /// only `plateDiameterMm != nil` clips.
    public var countMAELoaded: Metric?
    public var countMAEBodyweight: Metric?

    public var offByOneAccuracyOverall: Metric?
    public var offByOneAccuracyLoaded: Metric?

    /// SPEC §15.2 "False-positive reps per session" — one fixture clip is
    /// treated as one session for this harness (each fixture is a single
    /// working set, per `fixtures/README.md`).
    public var falsePositivesPerSession: Metric?

    public var perExercise: [ExerciseBreakdown]
    public var perCameraPosition: [CameraBreakdown]
}

/// Computes `AggregateEvaluation` from a batch of `ClipEvaluation`s. Pure,
/// no I/O — see `ClipEvaluator`'s doc comment for why that matters.
public enum AggregateEvaluator {
    public static func aggregate(_ evaluations: [ClipEvaluation]) -> AggregateEvaluation {
        let loaded = evaluations.filter { $0.equipment != .bodyweight }
        let bodyweight = evaluations.filter { $0.equipment == .bodyweight }

        return AggregateEvaluation(
            clipCount: evaluations.count,
            countMAEOverall: countMAE(evaluations),
            countMAELoaded: countMAE(loaded),
            countMAEBodyweight: countMAE(bodyweight),
            offByOneAccuracyOverall: offByOneAccuracy(evaluations),
            offByOneAccuracyLoaded: offByOneAccuracy(loaded),
            falsePositivesPerSession: meanFalsePositives(evaluations),
            perExercise: exerciseBreakdowns(evaluations),
            perCameraPosition: cameraBreakdowns(evaluations)
        )
    }

    static func countMAE(_ evaluations: [ClipEvaluation]) -> Metric? {
        guard !evaluations.isEmpty else { return nil }
        let sum = evaluations.reduce(0.0) { $0 + Double(abs($1.delta)) }
        return Metric(value: sum / Double(evaluations.count), sampleCount: evaluations.count)
    }

    static func offByOneAccuracy(_ evaluations: [ClipEvaluation]) -> Metric? {
        guard !evaluations.isEmpty else { return nil }
        let withinOne = evaluations.count { $0.isWithinOffByOne }
        return Metric(value: Double(withinOne) / Double(evaluations.count), sampleCount: evaluations.count)
    }

    static func meanFalsePositives(_ evaluations: [ClipEvaluation]) -> Metric? {
        guard !evaluations.isEmpty else { return nil }
        let sum = evaluations.reduce(0) { $0 + $1.falsePositiveCount }
        return Metric(value: Double(sum) / Double(evaluations.count), sampleCount: evaluations.count)
    }

    static func meanFalseNegatives(_ evaluations: [ClipEvaluation]) -> Metric? {
        guard !evaluations.isEmpty else { return nil }
        let sum = evaluations.reduce(0) { $0 + $1.falseNegativeCount }
        return Metric(value: Double(sum) / Double(evaluations.count), sampleCount: evaluations.count)
    }

    private static func exerciseBreakdowns(_ evaluations: [ClipEvaluation]) -> [ExerciseBreakdown] {
        let grouped = Dictionary(grouping: evaluations, by: \.exerciseId)
        return grouped.keys.sorted().compactMap { key -> ExerciseBreakdown? in
            guard let group = grouped[key],
                  let mae = countMAE(group),
                  let offByOne = offByOneAccuracy(group),
                  let meanFP = meanFalsePositives(group),
                  let meanFN = meanFalseNegatives(group)
            else { return nil }
            return ExerciseBreakdown(
                exerciseId: key,
                clipCount: group.count,
                countMAE: mae,
                offByOneAccuracy: offByOne,
                meanFalsePositives: meanFP,
                meanFalseNegatives: meanFN
            )
        }
    }

    private static func cameraBreakdowns(_ evaluations: [ClipEvaluation]) -> [CameraBreakdown] {
        // Grouped by raw value rather than the enum itself: `CameraPosition`
        // is `Equatable` but not declared `Hashable`, and it isn't this
        // eval code's file to add a conformance to (Fixtures/ is owned
        // elsewhere).
        let grouped = Dictionary(grouping: evaluations, by: \.cameraPosition.rawValue)
        return CameraPosition.allCases.compactMap { position -> CameraBreakdown? in
            guard let group = grouped[position.rawValue], !group.isEmpty,
                  let mae = countMAE(group),
                  let offByOne = offByOneAccuracy(group)
            else { return nil }
            return CameraBreakdown(
                cameraPosition: position,
                degreesOffPerpendicular: position.degreesOffPerpendicular,
                clipCount: group.count,
                countMAE: mae,
                offByOneAccuracy: offByOne
            )
        }
    }
}

private extension Array {
    func count(where predicate: (Element) -> Bool) -> Int {
        reduce(0) { predicate($1) ? $0 + 1 : $0 }
    }
}
