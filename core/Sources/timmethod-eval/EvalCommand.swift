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
        help: "Directory of fixture clips (.mov + sidecar ground-truth JSON). Required unless --jitter-report."
    )
    var fixtures: String?

    @Option(
        name: .long,
        help: "Pose backend to evaluate: apple-vision-3d or mediapipe. Recorded on the report; not yet branched on (Wave 5)."
    )
    var provider: PoseProviderKind = .appleVision3D

    @Option(
        name: .long,
        help: "Path to write the JSON report to. Trace dumps for wrong-count clips are written under <report's directory>/traces/. Required unless --jitter-report."
    )
    var report: String?

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

    @Flag(
        name: .long,
        help: """
            Measure static-subject signal noise (SPEC §4.1 / §7.2; W3-01) instead of running the eval harness. \
            Requires --signal. Per-backend comparison is explicitly deferred: no PoseProvider implementation \
            exists yet (Wave 5) and no real static-subject footage exists yet (W1-06 is still open) — this mode \
            measures whatever --signal points it at, and nothing is fabricated about how that generalises to a \
            real pose backend.
            """
    )
    var jitterReport: Bool = false

    @Option(
        name: .long,
        help: """
            --jitter-report only: path to a JSON file of static-hold samples, an array of \
            {"t": seconds, "x": metres[, "confidence": 0...1]} objects, oldest first.
            """
    )
    var signal: String?

    @Option(
        name: .long,
        help: """
            --jitter-report only: a known rep peak-to-valley amplitude in metres to compare the measured jitter \
            against, so the report can print the ratio that actually decides whether smoothing is worth its lag \
            cost. Omit to get the raw jitter numbers without a ratio — this is never guessed.
            """
    )
    var repAmplitudeReferenceMeters: Double?

    mutating func validate() throws {
        if jitterReport {
            guard signal != nil else {
                throw ValidationError("--jitter-report requires --signal <path>.")
            }
            if let repAmplitudeReferenceMeters, repAmplitudeReferenceMeters <= 0 {
                throw ValidationError("--rep-amplitude-reference-meters must be positive.")
            }
        } else {
            guard fixtures != nil else {
                throw ValidationError("Missing expected argument '--fixtures <fixtures>'")
            }
            guard report != nil else {
                throw ValidationError("Missing expected argument '--report <report>'")
            }
        }
    }

    func run() async throws {
        if jitterReport {
            try runJitterReport()
            return
        }

        // `validate()` guarantees these are non-nil whenever `jitterReport`
        // is false; the guard is defensive, not expected to fire.
        guard let fixtures, let report else { throw ExitCode.failure }

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

        let reportURL = URL(fileURLWithPath: report)
        let tracesDirectory = reportURL.deletingLastPathComponent().appendingPathComponent("traces")

        var evaluations: [ClipEvaluation] = []

        for loaded in selected {
            let name = loaded.videoURL.deletingPathExtension().lastPathComponent
            if verbose { print("timmethod-eval: running \(name)...") }

            do {
                switch try await FrameReplay.run(fixture: loaded.fixture, videoURL: loaded.videoURL, pacing: pacing) {
                case .refused(let reason):
                    skipped.append("\(name): \(reason)")
                    if verbose { print("timmethod-eval:   refused — \(reason)") }

                case .scored(let frameResult):
                    let evaluation = ClipEvaluator.evaluate(name: name, fixture: loaded.fixture, prediction: frameResult.result)
                    evaluations.append(evaluation)

                    if !evaluation.isCountCorrect {
                        try TraceDumper.dump(evaluation: evaluation, frameResult: frameResult, to: tracesDirectory)
                        if verbose { print("timmethod-eval:   wrong count (true \(evaluation.trueCount), predicted \(evaluation.predictedCount)) — trace written") }
                    }
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

    /// `--jitter-report` (SPEC §4.1 / §7.2; W3-01 item 4). All the actual
    /// jitter arithmetic lives in `TimMethodCore.JitterAnalysis` — see
    /// `JitterReport.swift` for the read-a-file / format-for-terminal
    /// plumbing this delegates to, and its doc comment for the scope note
    /// this mode is required to be honest about (no pose backend, no real
    /// static-hold footage yet).
    private func runJitterReport() throws {
        // `validate()` guarantees `signal` is non-nil here.
        guard let signalPath = signal else { throw ExitCode.failure }

        let cliReport: JitterCLIReport
        do {
            cliReport = try JitterReportRunner.run(
                signalPath: signalPath,
                repAmplitudeReferenceMetres: repAmplitudeReferenceMeters
            )
        } catch let error as JitterReportError {
            FileHandle.standardError.write(Data("\(error.description)\n".utf8))
            throw ExitCode.failure
        }

        print(JitterReportRunner.render(cliReport))

        // Reuses `--report` when it's supplied (it's optional in this mode,
        // unlike eval mode) so a jitter run leaves the same kind of durable
        // JSON artifact an eval run does, without requiring it.
        if let report {
            let reportURL = URL(fileURLWithPath: report)
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(cliReport)
            try data.write(to: reportURL, options: .atomic)
        }
    }
}
