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
/// was.
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

    /// Writes one clip's trace to `<directory>/<fixtureName>.json`, creating
    /// `directory` if it doesn't exist yet.
    static func dump(
        evaluation: ClipEvaluation,
        signal: RepSignal,
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
            trace: signal.trace()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(dump)

        let fileURL = directory.appendingPathComponent(evaluation.name).appendingPathExtension("json")
        try data.write(to: fileURL, options: .atomic)
    }
}
