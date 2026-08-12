import CoreMedia
import Foundation
import TimMethodCore

/// Wave 1 placeholder for the frame → `RepSignal` step (SPEC §5, §6).
///
/// No tracker exists yet: Track A (plate detection → displacement) is Wave
/// 2, Track B (pose → PCA projection) is Wave 5. This function proves the
/// real seam end to end — it drains the real `ReplayFrameSource`, honouring
/// whatever pacing was requested — without pretending to measure any real
/// motion. Every sample's `x` is `0`, which is an honest "nothing was
/// tracked," not a fabricated curve; `scale` is `.torsoRelative`, the one
/// `RepSignal.ScaleSource` case that makes no absolute-measurement claim at
/// all (SPEC §6). `StubRepCounter` naturally counts zero reps over a flat
/// signal for exactly this reason — the wrong-count trace dumps a clean
/// Wave 1 run produces are a correct reflection of "no tracking happened,"
/// not a bug in the harness.
///
/// Once Track A lands, this function is deleted, and its caller is handed a
/// real per-frame `x` from plate-centroid displacement instead — nothing
/// downstream of `RepSignal` (the counter seam, scoring, the gate) needs to
/// change when that happens.
enum FrameReplay {
    static func buildPlaceholderSignal(for videoURL: URL, pacing: ReplayPacing) async throws -> RepSignal {
        let source = ReplayFrameSource(url: videoURL, pacing: pacing)
        try await source.start()

        var signal = RepSignal(scale: .torsoRelative)
        for await frame in source.frames {
            signal.append(t: frame.timestamp.seconds, x: 0, confidence: 1.0)
        }
        await source.stop()

        return signal
    }
}
