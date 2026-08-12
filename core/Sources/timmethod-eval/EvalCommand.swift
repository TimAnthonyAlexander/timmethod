import ArgumentParser
import Foundation
import TimMethodCore

/// Pose backend to run fixtures through (SPEC §4.1). The flag is what turns
/// the Apple Vision vs. MediaPipe choice into a measurement instead of a
/// guess: run the same fixtures through both and read the numbers.
///
/// Meaningless until Wave 5's Track B lands — every run today goes through
/// the same Wave 1 placeholder signal (see `FrameReplay`) regardless of
/// this flag. It is accepted and recorded on `EvalReport.provider` now, not
/// branched on, so results stay attributable once it does matter.
enum PoseProviderKind: String, ExpressibleByArgument, CaseIterable, Sendable {
    case appleVision3D = "apple-vision-3d"
    case mediaPipe = "mediapipe"
}

/// `timmethod-eval` — the headless evaluation harness (SPEC §15).
///
/// Runs fixture clips through the exact `ReplayFrameSource` the app uses,
/// scores predictions from a `RepCounting` conformer against each fixture's
/// ground truth, and reports predicted vs. actual rep counts, MAE,
/// off-by-one accuracy, and false-positive/false-negative reps — per clip
/// and aggregated, with a §15.2-floor regression gate. All scoring
/// arithmetic lives in `TimMethodCore/Eval/`, unit-tested there without
/// spawning this process; this file only parses flags, orchestrates I/O,
/// and formats.
@main
struct EvalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "timmethod-eval",
        abstract: "Evaluation harness for the Tim Method rep counter and pose pipeline.",
        version: TimMethodCore.version
    )

    @Option(
        name: .long,
        help: "Directory of fixture clips (.mov + sidecar ground-truth JSON)."
    )
    var fixtures: String

    @Option(
        name: .long,
        help: "Pose backend to evaluate: apple-vision-3d or mediapipe. Recorded on the report; not yet branched on (Wave 5)."
    )
    var provider: PoseProviderKind = .appleVision3D

    @Option(
        name: .long,
        help: "Path to write the JSON report to. Trace dumps for wrong-count clips are written under <report's directory>/traces/."
    )
    var report: String

    @Option(
        name: .long,
        help: "Only run fixtures whose exercise ID or clip name contains this substring."
    )
    var filter: String?

    @Flag(
        name: .long,
        help: "Print per-fixture detail as each clip is processed."
    )
    var verbose: Bool = false

    @Flag(
        name: .long,
        help: "Pace frame delivery to the clip's own real timing instead of replaying as fast as possible. Off by default: batch scoring must not run in wall-clock time."
    )
    var realtime: Bool = false

    func run() async throws {
        let fixturesURL = URL(fileURLWithPath: fixtures)

        let loadResult: FixtureLoadResult
        do {
            loadResult = try FixtureLoader.load(directory: fixturesURL)
        } catch let error as FixtureLoaderError {
            FileHandle.standardError.write(Data("timmethod-eval: \(error.description)\n".utf8))
            throw ExitCode.failure
        }

        var skipped = loadResult.issues.map(\.description)

        var selected = loadResult.fixtures
        if let filter {
            selected = selected.filter {
                $0.fixture.exerciseId.localizedCaseInsensitiveContains(filter)
                    || $0.videoURL.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(filter)
            }
        }
        selected.sort { $0.videoURL.lastPathComponent < $1.videoURL.lastPathComponent }

        let pacing: ReplayPacing = realtime ? .realtime : .asFastAsPossible
        let counter = StubRepCounter()

        let reportURL = URL(fileURLWithPath: report)
        let tracesDirectory = reportURL.deletingLastPathComponent().appendingPathComponent("traces")

        var evaluations: [ClipEvaluation] = []

        for loaded in selected {
            let name = loaded.videoURL.deletingPathExtension().lastPathComponent
            if verbose { print("timmethod-eval: running \(name)...") }

            do {
                let signal = try await FrameReplay.buildPlaceholderSignal(for: loaded.videoURL, pacing: pacing)
                let prediction = counter.count(signal: signal)
                let evaluation = ClipEvaluator.evaluate(name: name, fixture: loaded.fixture, prediction: prediction)
                evaluations.append(evaluation)

                if !evaluation.isCountCorrect {
                    try TraceDumper.dump(evaluation: evaluation, signal: signal, to: tracesDirectory)
                    if verbose { print("timmethod-eval:   wrong count (true \(evaluation.trueCount), predicted \(evaluation.predictedCount)) — trace written") }
                }
            } catch {
                skipped.append("\(name): replay failed — \(error)")
            }
        }

        let aggregate = AggregateEvaluator.aggregate(evaluations)
        let gate = EvalGate.evaluate(aggregate)

        let evalReport = EvalReport(
            provider: provider.rawValue,
            fixturesDirectory: fixtures,
            filter: filter,
            realtime: realtime,
            generatedAt: Date(),
            clips: evaluations,
            skippedFixtures: skipped,
            aggregate: aggregate,
            gate: gate
        )

        try writeReport(evalReport, to: reportURL)
        print(TerminalTable.render(evalReport))

        if !gate.passed {
            throw ExitCode.failure
        }
    }

    private func writeReport(_ evalReport: EvalReport, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(evalReport)
        try data.write(to: url, options: .atomic)
    }
}
