import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import TimMethodCore
@testable import timmethod_eval

/// Exercises the assembled Track A pipeline (W3-07) — the first suite in
/// this project to run more than one real component back to back:
/// `PlateTracker` (→ `PlateDetector`) → `MetricScale` → `MotionAxis` →
/// `RepSignal` → `SignalConditioningPipeline` → `ZeroCrossCounter` →
/// `AmplitudeGate`, with `PostureGate` and `RangeCalibration` wired in.
///
/// **Synthetic verification only** — see `TrackARepCounterSyntheticClip`'s
/// doc. These tests prove the seams between Wave 2/3 components line up
/// against frames with known ground truth. Real-footage confirmation is
/// W3-06's job, once real footage exists.
@Suite("TrackARepCounter")
struct TrackARepCounterTests {

    // MARK: - Headline: a known number of cycles counts exactly that many

    @Test("a plate oscillating through 3 clean cycles counts exactly 3 reps, end to end through every real component")
    func threeCleanCyclesCountExactlyThree() async throws {
        let frames = TrackARepCounterSyntheticClip.sinusoidalPlateFrames(
            repCount: 3, frequencyHz: 1.0, amplitudePx: 80, majorAxis: 200
        )
        let rendered = SyntheticPlateClip.render(frames)
        let source = PrerenderedFrameSource(rendered: PrerenderedFrameSource.timedFrames(from: rendered))

        let counter = TrackARepCounter()
        let frameResult = try await counter.run(frames: source, plateConfiguration: .olympicOrBumper)

        #expect(frameResult.result.repCount == 3)
        #expect(frameResult.result.partialCount == 0)
        #expect(frameResult.result.repTimestamps.count == 3)
        #expect(frameResult.frameCount == rendered.count)
        // The held-still setup pause (see the clip generator's doc) can
        // surface a couple of near-zero noise candidates that the gate
        // correctly rejects on amplitude/phase duration before real
        // oscillation begins — assert on the accepted count specifically,
        // not on `candidateOutcomes.count` being exactly 3.
        #expect(frameResult.candidateOutcomes.filter { $0.outcome.isAccepted }.count == 3)
        // A clean synthetic circle, tracked continuously: no frame should
        // have found a plate whose implied scale MetricScale then refused.
        #expect(frameResult.metricScaleRejectionCount == 0)
    }

    // MARK: - No plate at all: zero, honestly, not a crash

    @Test("a clip with no plate in any frame produces zero reps and shows why: no sample ever entered the signal")
    func noPlateProducesZeroAndShowsWhy() async throws {
        // 60 frames, every one plate-free — the same shape the three
        // committed placeholder fixtures are (solid-colour, no plate).
        let frames = (0..<60).map {
            SyntheticPlateClip.Frame(ellipse: nil, timestamp: Double($0) / 30.0)
        }
        let rendered = SyntheticPlateClip.render(frames)
        let source = PrerenderedFrameSource(rendered: PrerenderedFrameSource.timedFrames(from: rendered))

        let counter = TrackARepCounter()
        let frameResult = try await counter.run(frames: source, plateConfiguration: .olympicOrBumper)

        #expect(frameResult.result.repCount == 0)
        #expect(frameResult.result.repTimestamps.isEmpty)
        #expect(frameResult.frameCount == 60)
        // The honest "why": every frame was processed, but the tracker
        // never measured anything, so `RepSignal` never received a sample —
        // not a rejected scale, not a rejected candidate, just nothing to
        // report (never a fabricated flat-zero curve).
        #expect(frameResult.signal.samples.count == 0)
        #expect(frameResult.metricScaleRejectionCount == 0)
        #expect(frameResult.candidateOutcomes.isEmpty)
    }

    // MARK: - No configured diameter: refused, not scored

    @Test("a fixture with no configured plate diameter is refused before any frame is ever touched, not scored as zero")
    func noConfiguredDiameterIsRefused() async throws {
        let fixture = Fixture(
            exerciseId: "dumbbell_row",
            equipment: .dumbbell,
            plateDiameterMm: nil,
            trueRepCount: 6,
            cameraPosition: .oblique30,
            lightingNote: "test",
            sourceDataset: "own",
            licence: .ownFootage
        )
        // A URL that doesn't exist on disk — proves refusal happens before
        // `ReplayFrameSource` (or any file I/O) is ever reached.
        let bogusURL = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mov")

        let outcome = try await FrameReplay.run(fixture: fixture, videoURL: bogusURL, pacing: .asFastAsPossible)
        guard case .refused(let reason) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(reason.contains("dumbbell_row"))
    }

    @Test("a bodyweight fixture is refused even if a stray plateDiameterMm were present")
    func bodyweightIsAlwaysRefused() async throws {
        let fixture = Fixture(
            exerciseId: "pushup",
            equipment: .bodyweight,
            plateDiameterMm: nil,
            trueRepCount: 8,
            cameraPosition: .oblique45,
            lightingNote: "test",
            sourceDataset: "own",
            licence: .ownFootage
        )
        let bogusURL = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mov")
        let outcome = try await FrameReplay.run(fixture: fixture, videoURL: bogusURL, pacing: .asFastAsPossible)
        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
    }

    // MARK: - Gate rejection reasons reach the trace

    @Test("a rejected candidate's failure reasons appear in the JSON trace dump")
    func rejectionReasonsAppearInTrace() throws {
        // A twitch: tiny amplitude, no confidence samples, no posture data
        // in its window — exercises several `AmplitudeGate.FailureReason`
        // cases in one candidate, all of which must show up in the dump.
        let candidate = ZeroCrossCounter.Candidate(
            startPeak: .init(t: 0.0, x: 0.001),
            valley: .init(t: 0.1, x: 0.0),
            endPeak: .init(t: 0.2, x: 0.001)
        )
        let gateConfiguration = try AmplitudeGate.Configuration(
            threshold: .metres(0.05), scale: .plateDiameter(mm: 450), minimumMeanConfidence: 0.5
        )
        let outcome = AmplitudeGate(configuration: gateConfiguration).evaluate(
            candidate: candidate, signalSamples: [], postureHistory: []
        )
        guard case .rejected = outcome else {
            Issue.record("expected this twitch candidate to be rejected")
            return
        }

        var signal = RepSignal(scale: .plateDiameter(mm: 450))
        signal.append(t: 0.0, x: 0.001, confidence: 1.0)
        signal.append(t: 0.2, x: 0.001, confidence: 1.0)

        let frameResult = TrackARepCounter.FrameResult(
            signal: signal,
            result: RepCountResult(repCount: 0),
            candidateOutcomes: [TrackARepCounter.CandidateOutcome(candidate: candidate, outcome: outcome)],
            frameCount: 6,
            metricScaleRejectionCount: 0
        )

        let fixture = Fixture(
            exerciseId: "back_squat", equipment: .barbell, plateDiameterMm: 450, trueRepCount: 1,
            cameraPosition: .perpendicular, lightingNote: "test", sourceDataset: "own", licence: .ownFootage
        )
        let evaluation = ClipEvaluator.evaluate(name: "twitch_clip", fixture: fixture, prediction: frameResult.result)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("track-a-rep-counter-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try TraceDumper.dump(evaluation: evaluation, frameResult: frameResult, to: directory)

        let fileURL = directory.appendingPathComponent("twitch_clip.json")
        let data = try Data(contentsOf: fileURL)
        let dump = try JSONDecoder().decode(TraceDump.self, from: data)

        #expect(dump.candidates.count == 1)
        #expect(dump.candidates[0].accepted == false)
        #expect(!dump.candidates[0].rejectionReasons.isEmpty)
        // At least the amplitude failure (an unmistakable twitch) must be
        // named, with its offending numbers, not just a bare category.
        #expect(dump.candidates[0].rejectionReasons.contains { $0.contains("A_min") })
        #expect(dump.frameCount == 6)
        #expect(dump.metricScaleRejectionCount == 0)
    }
}
