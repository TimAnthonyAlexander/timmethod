/// A source of live or replayed video frames.
///
/// Both the on-device camera and a recorded `.mov` file satisfy this one
/// protocol (SPEC §5), so everything downstream — pose tracking, plate
/// detection, the rep counter, the set/rest segmenter, the eval harness —
/// depends only on `FrameSource` and never knows or cares which one it is
/// talking to. That is what makes the counting pipeline testable
/// headlessly: tuning it against a fixture video is a matter of changing a
/// parameter and rerunning `timmethod-eval`, not doing squats in front of a
/// live camera between changes.
///
/// `LiveFrameSource` (wrapping `AVCaptureVideoDataOutput`) and
/// `ReplayFrameSource` (reading a `.mov` via `AVAssetReader`) are later
/// tasks; this protocol, and a synthetic stub used only in tests, are the
/// whole of what this file defines.
///
/// ### Backpressure
///
/// A conforming type's `frames` stream MUST be built with
/// `AsyncStream(bufferingPolicy: .bufferingNewest(_:))`, never `.unbounded`
/// and never `.bufferingOldest(_:)`. A stale frame is worthless to a
/// realtime rep counter — if the consumer falls behind, the right move is
/// to skip straight to the newest frame, not to work through a backlog of
/// frames the lifter has already moved past. This mirrors
/// `AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames = true` on the
/// live capture path (SPEC §4.2): drop, never queue.
///
/// `AsyncStream.Continuation.BufferingPolicy` naming is easy to get
/// backwards, and getting it backwards here is a silent correctness bug,
/// not a crash: `.bufferingNewest(n)` keeps the newest `n` elements and
/// silently discards the OLDEST one on overflow — that is the policy this
/// protocol requires. `.bufferingOldest(n)` does the reverse (keeps the
/// oldest `n`, drops incoming new frames instead), which is exactly the
/// staleness this protocol exists to avoid, and must never be used here.
///
/// There is no single bound mandated for every conformer — a live 60 fps
/// camera and a synthetic test source have different needs — but the bound
/// MUST be small and explicit, and each conformer documents and justifies
/// its own choice next to where it configures the stream. As a rule of
/// thumb, a couple of frames (tens of milliseconds at 60 fps) is enough
/// slack to absorb ordinary scheduler jitter between producer and consumer
/// without letting the pipeline meaningfully fall behind the lift.
public protocol FrameSource: Sendable {
    /// Frames as they become available. Iterating this stream is the only
    /// sanctioned way to consume frames — there is no pull-based or
    /// random-access API by design. See `TimedFrame`'s single-consumer,
    /// single-handoff ownership invariant before holding onto a frame
    /// beyond a single iteration of a `for await` loop.
    var frames: AsyncStream<TimedFrame> { get }

    /// Begins producing frames onto `frames`. Safe to call once per
    /// session; a source that has already been stopped is not required to
    /// support being started again.
    func start() async throws

    /// Stops producing frames and finishes the `frames` stream, so any
    /// `for await` loop over it completes instead of hanging forever.
    func stop() async
}
