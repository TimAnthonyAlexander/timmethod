import AVFoundation
import CoreMedia
import CoreVideo

/// A single captured video frame paired with its presentation timestamp
/// and, when a rear+LiDAR calibration pass requested it, per-frame depth
/// data.
///
/// This is the one sanctioned `@unchecked Sendable` in `TimMethodCore`
/// (SPEC §4.4). Read the invariant below before adding a second one
/// anywhere else in this codebase. If you find yourself wanting to, you
/// have taken a wrong turn — solve the problem a different way instead
/// (see "If you need more than one consumer" below).
///
/// ### Why this needs `@unchecked` at all
///
/// `CVPixelBuffer` — and `CMSampleBuffer`, which wraps it on the live
/// capture path — is still not `Sendable` as of 2026. It is a Core
/// Foundation object backed by an `IOSurface`-managed pixel plane that
/// Apple has never audited or annotated for the concurrency checker.
/// `@preconcurrency import CoreVideo` does **not** make the warning go
/// away: that annotation only downgrades diagnostics for APIs the compiler
/// treats as merely *unaudited*, but `CVPixelBuffer` isn't unaudited, it is
/// simply not `Sendable`, full stop — there is no conformance for
/// `@preconcurrency` to soften. `AVDepthData` is in the same position.
/// Apple's own AVCam sample cannot build under strict Swift 6 checking
/// without `@preconcurrency import AVFoundation` on its capture delegate,
/// for exactly this reason (SPEC §4.4, source ⟨A7⟩). This is not a
/// temporary gap to wait out; it is not going to be fixed for us.
///
/// ### The invariant that makes `@unchecked` acceptable here
///
/// A `TimedFrame` is handed off to **exactly one** consumer, **exactly
/// once**, over an `AsyncStream`. The producer (`CaptureActor` on the live
/// path, a replay reader on the file path) MUST NOT retain, read, or
/// mutate `buffer` or `depth` after yielding a `TimedFrame` into the
/// stream — ownership of the buffer transfers completely at the point of
/// `yield`, the same way it would for a `sending` value. `CVPixelBuffer` is
/// not internally synchronized, so if a producer kept a second reference
/// and touched it while a consumer was reading it, that would be a real
/// data race the compiler is correctly unable to catch here. The
/// `@unchecked Sendable` conformance is a promise that this
/// single-owner, single-handoff discipline is upheld by every conformer of
/// `FrameSource` — it is not a claim that the buffer is safe to share or
/// mutate from multiple places at once, because it isn't.
///
/// If a future change needs the same frame visible to more than one
/// consumer at a time (e.g. plate detection and pose inference both
/// wanting the same buffer), do not just start passing this struct around
/// more widely — copy the pixel data per consumer, or introduce an actor
/// that owns the buffer and hands out immutable, already-`Sendable`
/// snapshots derived from it (SPEC §4.4).
public struct TimedFrame: @unchecked Sendable {
    /// The frame's raw pixel plane. `32BGRA` on the live capture path
    /// (SPEC §4.2), matched by any replay path so downstream code never
    /// branches on pixel format.
    public let buffer: CVPixelBuffer

    /// Presentation timestamp. Monotonically increasing within a single
    /// `FrameSource` session.
    public let timestamp: CMTime

    /// Per-frame depth. Present only during a rear+LiDAR calibration pass;
    /// `nil` on the standard front-camera path. SPEC §4.2 is explicit that
    /// depth is an occasional, one-time calibration signal, never a
    /// per-frame input — do not add logic downstream that expects this to
    /// be non-nil on every frame.
    public let depth: AVDepthData?

    public init(buffer: CVPixelBuffer, timestamp: CMTime, depth: AVDepthData? = nil) {
        self.buffer = buffer
        self.timestamp = timestamp
        self.depth = depth
    }
}
