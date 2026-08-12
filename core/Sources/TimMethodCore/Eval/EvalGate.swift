import Foundation

/// Outcome of checking one SPEC §15.2 floor against the aggregate.
public enum GateStatus: String, Sendable, Equatable, Codable {
    case pass
    case fail
    /// The metric has no data to check — either nothing in this wave's
    /// pipeline computes it yet (velocity RMSE, set-boundary F1), or this
    /// run had zero clips in the relevant slice. Deliberately distinct from
    /// `.pass`: a skipped check must never read as coverage that didn't
    /// happen, per the task brief ("a green run cannot be mistaken for more
    /// coverage than it had").
    case skippedNoData
}

/// One SPEC §15.2 floor, checked or explicitly not.
public struct FloorCheck: Sendable, Equatable, Codable {
    public var metric: String
    /// Human-readable floor, e.g. `"<= 0.15"` — printed verbatim in the
    /// terminal table and the JSON so the floor is legible without cross-
    /// referencing SPEC §15.2.
    public var floorDescription: String
    public var observed: Double?
    public var status: GateStatus
}

/// The regression-gate verdict (SPEC §15's "Non-zero exit when aggregate
/// falls below the §15.2 floor").
public struct GateResult: Sendable, Equatable, Codable {
    public var checks: [FloorCheck]
    /// `true` iff no check has `status == .fail`. A run with every metric
    /// skipped (e.g. zero fixtures) passes vacuously — there is nothing to
    /// have failed — which is exactly why `checks` must always be printed
    /// alongside `passed`, so a vacuous pass is never mistaken for a real
    /// one.
    public var passed: Bool
}

/// Checks an `AggregateEvaluation` against every floor in SPEC §15.2.
/// Floors, not targets — the target column is the goal to tune towards;
/// the floor is the regression line this harness enforces on every run.
public enum EvalGate {
    public static let countMAELoadedFloor = 0.15
    public static let offByOneAccuracyLoadedFloor = 0.95
    public static let countMAEBodyweightFloor = 0.35
    public static let falsePositivesPerSessionFloor = 1.0
    public static let velocityRMSEFloor = 0.10
    public static let setBoundaryF1Floor = 0.90

    public static func evaluate(_ aggregate: AggregateEvaluation) -> GateResult {
        var checks: [FloorCheck] = []

        checks.append(check(
            metric: "Count MAE, loaded",
            floorDescription: "<= \(countMAELoadedFloor)",
            metricValue: aggregate.countMAELoaded,
            passes: { $0 <= countMAELoadedFloor }
        ))
        checks.append(check(
            metric: "Off-by-one accuracy, loaded",
            floorDescription: ">= \(offByOneAccuracyLoadedFloor)",
            metricValue: aggregate.offByOneAccuracyLoaded,
            passes: { $0 >= offByOneAccuracyLoadedFloor }
        ))
        checks.append(check(
            metric: "Count MAE, bodyweight",
            floorDescription: "<= \(countMAEBodyweightFloor)",
            metricValue: aggregate.countMAEBodyweight,
            passes: { $0 <= countMAEBodyweightFloor }
        ))
        checks.append(check(
            metric: "False positives per session",
            floorDescription: "<= \(falsePositivesPerSessionFloor)",
            metricValue: aggregate.falsePositivesPerSession,
            passes: { $0 <= falsePositivesPerSessionFloor }
        ))
        // Neither of these two is computed by anything in the pipeline yet
        // (mean concentric velocity lands in Wave 4, set-boundary detection
        // in Wave 7's segmenter) — always skipped, never silently passed.
        checks.append(FloorCheck(
            metric: "Mean concentric velocity RMSE",
            floorDescription: "<= \(velocityRMSEFloor) m/s (not evaluated until Wave 4)",
            observed: nil,
            status: .skippedNoData
        ))
        checks.append(FloorCheck(
            metric: "Set-boundary detection F1",
            floorDescription: ">= \(setBoundaryF1Floor) (not evaluated until Wave 7)",
            observed: nil,
            status: .skippedNoData
        ))

        let passed = !checks.contains { $0.status == .fail }
        return GateResult(checks: checks, passed: passed)
    }

    private static func check(
        metric: String,
        floorDescription: String,
        metricValue: Metric?,
        passes: (Double) -> Bool
    ) -> FloorCheck {
        guard let metricValue else {
            return FloorCheck(metric: metric, floorDescription: floorDescription, observed: nil, status: .skippedNoData)
        }
        return FloorCheck(
            metric: metric,
            floorDescription: floorDescription,
            observed: metricValue.value,
            status: passes(metricValue.value) ? .pass : .fail
        )
    }
}
