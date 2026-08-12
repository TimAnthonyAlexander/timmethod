import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

@testable import TimMethodCore

/// Test-only support for `TrackARepCounterTests`: a sinusoidal plate clip
/// generator (`SyntheticPlateClip.movingPlate` only expresses constant
/// per-frame *linear* velocity — this is the "extend it in your own new
/// file" case W3-07's brief calls out explicitly, since a rep is an
/// oscillation, not a straight line) and a `FrameSource` that replays
/// pre-rendered buffers directly, with no `.mov` file or `AVAssetReader`
/// involved — the same "drive the tracker with known-ground-truth buffers"
/// shape `SyntheticPlateClip`/`PlateTrackerTests` already use, one layer up.
///
/// **Synthetic verification only** — see `SyntheticPlateClip`'s own doc:
/// this proves `TrackARepCounter`'s real components are wired together
/// correctly against frames whose ground truth is known exactly. It says
/// nothing about real footage; that is W3-06's job.
enum TrackARepCounterSyntheticClip {
    /// A held-still setup pause, then a plate oscillating on a clean
    /// vertical sinusoid, `centerY - amplitudePx * cos(2π · frequencyHz ·
    /// (t - setupSeconds - leadIn))`.
    ///
    /// **Why a lead-in and a trailing margin, not just `repCount` periods.**
    /// `ZeroCrossCounter` is causal and only commits an extremum once the
    /// *following* sample proves the signal reversed away from it (its own
    /// doc: never delayed further than that, but never earlier either). A
    /// clip that starts or ends exactly on a peak therefore never gets that
    /// peak confirmed — there is no prior sample to prove the first one is
    /// really a local max, and no following sample to prove the last one
    /// is. Concretely, closing `repCount` candidates (`peak → valley →
    /// peak`) needs `repCount + 1` **confirmed** peaks, which needs one
    /// full quarter-period of run-up before the first peak and one quarter
    /// period of run-off after the last — the `leadIn`/trailing margin
    /// below. Getting this wrong doesn't corrupt the signal or the count
    /// subtly; it silently drops exactly the first and/or last candidate.
    ///
    /// **Why a held-still setup pause, not oscillation from frame 1.**
    /// `PostureGate` requires `openDwellSeconds` (150ms) of continuously
    /// good cues before it opens at all (its own doc: "a lifter settles
    /// into position and holds still for at least a moment before
    /// initiating the first rep of a set") — oscillation starting at `t=0`
    /// means the *first* candidate's peak lands before that dwell has
    /// elapsed, so `AmplitudeGate` correctly rejects it on
    /// `.postureNotHeldThroughout(... .awaitingDwell ...)`, exactly as it
    /// should for a candidate that starts before the gate ever opened. That
    /// is not a bug to route around by loosening the gate — no real clip
    /// starts an oscillation before the plate has even been in frame for
    /// 150ms — it is this clip generator being unrealistic. `setupSeconds`
    /// (0.5s: several times `openDwellSeconds`, comfortable margin) fixes
    /// that by holding the plate motionless first, the same way a lifter
    /// actually frames up before a set. A perfectly flat segment reports
    /// zero velocity throughout, so `ZeroCrossCounter` establishes no phase
    /// and commits nothing during it — it contributes no spurious
    /// candidate of its own, only the settling time a real gate needs.
    static func sinusoidalPlateFrames(
        repCount: Int,
        frequencyHz: Double,
        amplitudePx: Double,
        majorAxis: Double,
        sampleRateHz: Double = 30,
        setupSeconds: Double = 0.5
    ) -> [SyntheticPlateClip.Frame] {
        precondition(repCount > 0 && frequencyHz > 0 && sampleRateHz > 0 && setupSeconds >= 0)
        let centerX = Double(SyntheticPlateClip.frameWidth) / 2
        let centerY = Double(SyntheticPlateClip.frameHeight) / 2
        let periodSeconds = 1.0 / frequencyHz
        let leadInSeconds = periodSeconds / 4
        let trailingSeconds = periodSeconds / 4
        let oscillationDurationSeconds = leadInSeconds + Double(repCount) * periodSeconds + trailingSeconds
        let totalDurationSeconds = setupSeconds + oscillationDurationSeconds
        let frameIntervalSeconds = 1.0 / sampleRateHz
        let frameCount = Int((totalDurationSeconds / frameIntervalSeconds).rounded())

        return (0...frameCount).map { index in
            let t = Double(index) * frameIntervalSeconds
            let y: Double
            if t < setupSeconds {
                y = centerY  // held still — see doc, "Why a held-still setup pause"
            } else {
                let oscillationT = t - setupSeconds - leadInSeconds
                y = centerY - amplitudePx * cos(2 * Double.pi * frequencyHz * oscillationT)
            }
            let ellipse = SyntheticPlateFrame.Ellipse(
                center: CGPoint(x: centerX, y: y), majorAxis: majorAxis, minorAxis: majorAxis, rotation: 0
            )
            return SyntheticPlateClip.Frame(ellipse: ellipse, timestamp: t)
        }
    }
}

/// A `FrameSource` that replays a fixed, pre-rendered sequence of
/// `(CVPixelBuffer, TimeInterval)` pairs — no camera, no file I/O, no
/// pacing. `start()` yields every frame synchronously, matching
/// `StubFrameSource`'s own documented shape; `bufferBound` defaults to the
/// full frame count specifically so a synchronous, all-at-once `start()`
/// (like this one, like `StubFrameSource`'s) never drops frames to
/// `.bufferingNewest` overflow before the consumer has even begun
/// iterating — this type is a deterministic full-clip replay for
/// `TrackARepCounter` tests, not a backpressure test.
actor PrerenderedFrameSource: FrameSource {
    nonisolated let frames: AsyncStream<TimedFrame>
    private let continuation: AsyncStream<TimedFrame>.Continuation
    /// `TimedFrame` (not a raw `(CVPixelBuffer, TimeInterval)` tuple) is
    /// what's stored here and what this initializer accepts —
    /// `CVPixelBuffer` itself isn't `Sendable` (see `TimedFrame`'s own
    /// doc), so a tuple wrapping it isn't either, and cannot cross this
    /// initializer's actor-isolation boundary. `TimedFrame`'s documented
    /// `@unchecked Sendable` single-handoff invariant is the one sanctioned
    /// way to carry a buffer across it — see `timedFrames(from:)` below for
    /// the (isolation-boundary-free) conversion from `SyntheticPlateClip
    /// .render(_:)`'s raw tuple output.
    private let rendered: [TimedFrame]

    init(rendered: [TimedFrame], bufferBound: Int? = nil) {
        self.rendered = rendered
        var continuation: AsyncStream<TimedFrame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .bufferingNewest(bufferBound ?? Swift.max(rendered.count, 1))) {
            continuation = $0
        }
        self.continuation = continuation
    }

    /// Converts `SyntheticPlateClip.render(_:)`'s own output shape into
    /// `[TimedFrame]` — a plain, non-isolated `static func` (no `self` to
    /// isolate to), so a caller does this conversion in its own context
    /// *before* calling `init(rendered:)`, rather than handing a
    /// non-`Sendable` tuple array across the actor-isolation boundary that
    /// initializer sits behind.
    static func timedFrames(from rendered: [(buffer: CVPixelBuffer, timestamp: TimeInterval)]) -> [TimedFrame] {
        rendered.map { TimedFrame(buffer: $0.buffer, timestamp: CMTime(seconds: $0.timestamp, preferredTimescale: 600)) }
    }

    /// Yields every frame, then finishes the stream — mirroring
    /// `ReplayFrameSource.pump`'s real behaviour of finishing once reading
    /// is done, on its own, rather than waiting to be told to. A consumer
    /// that drains `frames` with `for await` before ever calling `stop()`
    /// (the normal shape: drain fully, `stop()` after) would otherwise
    /// block forever — nothing else would ever tell the stream there are
    /// no more frames coming.
    func start() async throws {
        for frame in rendered {
            continuation.yield(frame)
        }
        continuation.finish()
    }

    func stop() async {
        continuation.finish()
    }
}
