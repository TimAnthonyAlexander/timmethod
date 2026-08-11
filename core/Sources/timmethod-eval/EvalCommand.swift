import ArgumentParser
import TimMethodCore

/// Pose backend to run fixtures through (SPEC §4.1). The flag is what turns
/// the Apple Vision vs. MediaPipe choice into a measurement instead of a
/// guess: run the same fixtures through both and read the numbers.
enum PoseProviderKind: String, ExpressibleByArgument, CaseIterable, Sendable {
    case appleVision3D = "apple-vision-3d"
    case mediaPipe = "mediapipe"
}

/// `timmethod-eval` — the headless evaluation harness (SPEC §15).
///
/// Runs fixture clips through the exact tracker, counter, and Tim Method code
/// the app uses via `ReplayFrameSource`, and reports predicted vs. actual rep
/// counts, MAE, off-by-one accuracy, and false-positive/false-negative reps.
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
        help: "Pose backend to evaluate: apple-vision-3d or mediapipe."
    )
    var provider: PoseProviderKind = .appleVision3D

    @Option(
        name: .long,
        help: "Path to write the JSON report to."
    )
    var report: String

    @Option(
        name: .long,
        help: "Only run fixtures whose name contains this substring."
    )
    var filter: String?

    @Flag(
        name: .long,
        help: "Print per-fixture detail as each clip is processed."
    )
    var verbose: Bool = false

    func run() async throws {
        print("timmethod-eval: not implemented yet (see W1-05).")
    }
}
