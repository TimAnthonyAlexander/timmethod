import CoreMedia
import Foundation
import TimMethodCore

/// The frame → `RepSignal`/`RepCountResult` step (SPEC §5, §6, §8) — real
/// Track A now, not the Wave 1 placeholder this file used to be.
///
/// Everything Track A actually does — plate detection, tracking, metric
/// scale, motion axis, conditioning, zero-crossing, the amplitude gate,
/// range calibration — lives in `TrackARepCounter` (`TimMethodCore`). This
/// file's only job is the glue `timmethod-eval` needs around it: build a
/// `ReplayFrameSource` for the fixture's video, decide whether the fixture
/// even has a plate diameter to run Track A against, and hand back an
/// `Outcome` the harness can score or honestly skip.
enum FrameReplay {
    /// One fixture's outcome.
    enum Outcome {
        /// Track A ran to completion; `frameResult` is what
        /// `ClipEvaluator`/`TraceDumper` consume.
        case scored(TrackARepCounter.FrameResult)

        /// Track A never ran at all — a human-readable reason, meant for
        /// `EvalReport.skippedFixtures` (this task item 3 / this task's
        /// Done-when: "a fixture with no configured diameter is refused,
        /// not scored," never silently counted as zero).
        case refused(String)
    }

    /// Runs one fixture's clip through the real Track A pipeline.
    ///
    /// Reuses `PlateConfigurationLookup`'s existing refusal machinery
    /// (`PlateConfiguration.swift`) rather than inventing a second one: a
    /// fixture with no `plateDiameterMm` (or `.bodyweight` equipment, which
    /// never carries one) maps to `.unconfigured`, and
    /// `requireConfiguration()` throws — caught here and turned into
    /// `.refused`, never a silently-assumed 450 mm.
    static func run(
        fixture: Fixture,
        videoURL: URL,
        pacing: ReplayPacing,
        counterConfiguration: TrackARepCounter.Configuration = TrackARepCounter.Configuration()
    ) async throws -> Outcome {
        let lookup: PlateConfigurationLookup =
            if let millimetres = fixture.plateDiameterMm, fixture.equipment != .bodyweight {
                .configured(.custom(millimetres: millimetres))
            } else {
                .unconfigured
            }

        let plateConfiguration: PlateConfiguration
        do {
            plateConfiguration = try lookup.requireConfiguration()
        } catch {
            return .refused(
                "exerciseId \"\(fixture.exerciseId)\": no plate diameter configured — Track A refuses rather than assuming 450mm"
            )
        }

        guard plateConfiguration.isPlausible else {
            return .refused(
                "exerciseId \"\(fixture.exerciseId)\": configured plate diameter \(plateConfiguration.millimetres)mm "
                    + "is outside the plausible range \(PlateConfiguration.plausibleRangeMm) — Track A refuses rather than scoring against it"
            )
        }

        let source = ReplayFrameSource(url: videoURL, pacing: pacing)
        let counter = TrackARepCounter(configuration: counterConfiguration)
        let frameResult = try await counter.run(frames: source, plateConfiguration: plateConfiguration)
        return .scored(frameResult)
    }
}
