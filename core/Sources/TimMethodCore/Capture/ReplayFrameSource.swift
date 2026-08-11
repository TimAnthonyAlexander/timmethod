import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// How `ReplayFrameSource` paces frame delivery (SPEC §5, §15).
///
/// `.asFastAsPossible` is the default: `timmethod-eval` scores hundreds of
/// fixture clips and must not spend real wall-clock time doing it — a 10 s
/// clip should take a small fraction of a second to replay, gated only by
/// decode speed and how quickly the consumer drains `frames`.
///
/// `.realtime` sleeps between frames to reproduce the clip's own inter-frame
/// spacing, derived from its real presentation timestamps (never a
/// synthesised uniform clock — see `ReplayFrameSource`'s type doc). This is
/// for interactively watching a replay behave the way it would live. W1-05
/// wires a `--realtime` CLI flag on `timmethod-eval` to this parameter; this
/// type only defines the enum and the pacing behaviour, no flag parsing.
public enum ReplayPacing: Sendable, Equatable {
    case asFastAsPossible
    case realtime
}

/// Errors thrown by `ReplayFrameSource.start()`.
///
/// A reader that fails *after* `start()` has already returned successfully
/// (mid-read, once frames are already flowing) cannot surface through this
/// enum — `FrameSource.frames` is a plain `AsyncStream`, not a throwing one,
/// per the SPEC §5 protocol this type conforms to. That case instead ends
/// the stream cleanly (`continuation.finish()`), which is the other sanctioned
/// outcome the task brief allows: never a crash, never an empty stream
/// silently misread as a zero-rep clip when reading never even attempted —
/// every case below fires before any frame could have been produced.
public enum ReplayFrameSourceError: Error, Sendable, Equatable {
    /// `url` does not exist on disk. Checked explicitly (rather than letting
    /// asset loading surface some opaque, codec-flavoured NSError) so this
    /// specific, common mistake gets a specific, testable case.
    case fileNotFound(URL)

    /// `url` exists but AVFoundation could not load it as a readable asset
    /// (corrupt file, unsupported container, permissions, ...).
    case assetUnreadable(url: URL, underlying: any Error)

    /// The asset has no video track at all — an audio-only file, for
    /// instance. Distinct from `assetUnreadable`: the file is perfectly
    /// readable, it just isn't a video.
    case noVideoTrack(URL)

    /// Building the `AVVideoComposition` that applies the track's rotation
    /// (see the type doc's "Rotation" section) failed.
    case compositionUnavailable(url: URL, underlying: any Error)

    /// `AVAssetReader(asset:)` itself threw.
    case readerCreationFailed(url: URL, underlying: any Error)

    /// The composited video output could not be attached to the reader.
    /// Not expected in practice (it would mean the output was built from
    /// tracks the reader's own asset doesn't own) but reader.canAdd(_:)
    /// exists precisely so this is a checked failure, not a trap.
    case outputNotAddable(URL)

    /// `AVAssetReader.startReading()` returned `false` before any sample
    /// was ever read.
    case startReadingFailed(url: URL, underlying: (any Error)?)

    public static func == (lhs: ReplayFrameSourceError, rhs: ReplayFrameSourceError) -> Bool {
        switch (lhs, rhs) {
        case (.fileNotFound(let a), .fileNotFound(let b)):
            return a == b
        case (.assetUnreadable(let au, _), .assetUnreadable(let bu, _)):
            return au == bu
        case (.noVideoTrack(let a), .noVideoTrack(let b)):
            return a == b
        case (.compositionUnavailable(let au, _), .compositionUnavailable(let bu, _)):
            return au == bu
        case (.readerCreationFailed(let au, _), .readerCreationFailed(let bu, _)):
            return au == bu
        case (.outputNotAddable(let a), .outputNotAddable(let b)):
            return a == b
        case (.startReadingFailed(let au, _), .startReadingFailed(let bu, _)):
            return au == bu
        default:
            return false
        }
    }
}

/// Feeds a `.mov` file through the exact same `FrameSource` seam
/// `LiveFrameSource` feeds the camera through (SPEC §5), so tuning the
/// counter, tracker, and eval harness never requires standing in front of a
/// camera, and the Simulator — which has no camera — can still run the
/// harness.
///
/// ### Reading pattern
///
/// `AVAssetReader` + `AVAssetReaderTrackOutput`-family output +
/// `copyNextSampleBuffer()` is the Apple-endorsed pattern for exactly this
/// (SPEC §5 / §15 notes: an Apple media engineer describes it on the
/// developer forums, and Apple's own "Action & Vision" sample ships a dual
/// live/file capture controller built the same way). This type uses
/// `AVAssetReaderVideoCompositionOutput` rather than the plain
/// `AVAssetReaderTrackOutput` specifically to honour rotation — see below.
///
/// ### Pixel format
///
/// Output is `32BGRA`, requested explicitly via the output's video settings
/// — the same format the live capture path emits (SPEC §4.2). Downstream
/// code depends on this: it must never brach on pixel format to tell replay
/// from live, and this type is what makes that guarantee true.
///
/// ### Timestamps are the file's own
///
/// `TimedFrame.timestamp` is `CMSampleBufferGetPresentationTimeStamp`,
/// unmodified. This type never synthesises a uniform clock from an assumed
/// frame rate. Fixture clips (SPEC §15.1) are pulled from several different
/// datasets at several different frame rates; a fabricated 60 Hz clock would
/// silently corrupt every velocity measurement (SPEC §8.1) computed against
/// a clip that was not actually shot at 60 Hz. This is the single most
/// important correctness requirement on this type — see
/// `ReplayFrameSourceTests` for the regression coverage.
///
/// A subtlety worth being explicit about: `AVAssetReaderVideoCompositionOutput`
/// re-times frames according to the `AVVideoComposition` it is given, which
/// in general does *not* have to match the source track's own timing. The
/// composition built here (`AVVideoComposition.Configuration(for: asset)`)
/// is documented by Apple to fall back to the original source track's timing
/// whenever the asset has exactly one video track — true for every fixture
/// this type will ever read — rather than resampling to a synthesised
/// nominal frame rate. That is what keeps this type's pixel format and
/// rotation handling compatible with its "real timestamps" requirement; it
/// is not incidental, and `ReplayFrameSourceTests` proves it holds in
/// practice (60 fps and non-60 fps clips both come back with their own true
/// per-frame spacing), not only in the docs.
///
/// ### Rotation
///
/// `AVAssetReaderTrackOutput` does not apply the track's `preferredTransform`
/// — a portrait-recorded fixture would arrive sideways, which breaks plate
/// detection and pose alike. The supported fix is exactly what SPEC §5
/// prescribes: build an `AVVideoComposition` that does honour the transform
/// (and sizes its `renderSize` to the rotated bounding box) and read through
/// `AVAssetReaderVideoCompositionOutput` instead of the plain track output.
///
/// The construction API used here, `AVVideoComposition.Configuration(for:)`
/// plus `AVVideoComposition(configuration:)`, is the *current* non-deprecated
/// spelling of that on this SDK: `AVMutableVideoComposition` and its
/// `videoComposition(withPropertiesOf:)` factory — the API named in this
/// type's originating task brief — are themselves deprecated as of this
/// SDK's macOS 26 target ("Use `AVVideoComposition.Configuration` instead"),
/// so using them here would violate this package's zero-warnings build
/// policy. `Configuration(for:)` does the identical job: it produces
/// instructions and a `renderSize` that respect each video track's
/// `preferredTransform`. `ReplayFrameSourceTests` proves this with a clip
/// carrying a 90° `preferredTransform` and asserts the delivered buffers'
/// dimensions come out rotated, not raw.
///
/// ### Errors
///
/// See `ReplayFrameSourceError`.
///
/// ### Concurrency
///
/// `AVAssetReader` and its outputs are `NS_SWIFT_NONSENDABLE` on this SDK —
/// deliberately, not merely unaudited. `start()` builds them as ordinary
/// local values and hands them, once, into a `Task.detached` closure that
/// owns them for the rest of their lifetime; nothing here ever touches them
/// again afterwards, and they never cross back out. That single one-way
/// transfer is what lets this compile clean under Swift 6's complete
/// strict-concurrency checking without an `@unchecked Sendable` anywhere in
/// this file — `TimedFrame` (SPEC §4.4) remains the one sanctioned exception
/// in this package.
///
/// The read loop deliberately runs on `Task.detached`, not as an
/// actor-isolated method of this type, specifically so a concurrent call to
/// `stop()` is never queued up behind a long, synchronous
/// `copyNextSampleBuffer()` burst — `stop()` must be able to run and finish
/// the stream immediately regardless of what the read loop is doing.
///
/// ### Backpressure
///
/// `frames` is built with `.bufferingNewest(bufferBound)` per the
/// `FrameSource` protocol's mandatory policy (SPEC §5) — never `.unbounded`,
/// never `.bufferingOldest`. `bufferBound` defaults to a small, explicit
/// value (see the initializer) rather than a value tied to any particular
/// clip's length: per the protocol doc, this is "enough slack to absorb
/// ordinary scheduler jitter", not a promise that every frame the reader
/// produces is guaranteed to reach a slow consumer. In practice, for
/// `.asFastAsPossible` batch scoring, real decode-and-convert work per frame
/// dominates trivial per-frame consumer work (appending to an array,
/// pushing through pose inference), so the reader rarely if ever outruns the
/// consumer enough to trigger a drop — but this type does not and cannot
/// promise that for an arbitrarily slow downstream consumer, because the
/// protocol it conforms to specifically forbids buffering around that
/// problem instead of dropping. See this file's test suite for how that is
/// proven for the read patterns this type is actually used with.
public actor ReplayFrameSource: FrameSource {
    public nonisolated let frames: AsyncStream<TimedFrame>
    private let continuation: AsyncStream<TimedFrame>.Continuation

    private let url: URL
    private let pacing: ReplayPacing

    private var readTask: Task<Void, Never>?
    private var didStart = false

    /// - Parameters:
    ///   - url: the `.mov` file to replay.
    ///   - pacing: see `ReplayPacing`. Defaults to `.asFastAsPossible`.
    ///   - bufferBound: the `.bufferingNewest` bound backing `frames`. `4` —
    ///     a couple of frames' worth of slack, matching the guidance on
    ///     `FrameSource.frames` — is enough to smooth over ordinary
    ///     scheduler jitter between the detached read loop and whatever is
    ///     consuming `frames`, without masking a genuinely slow consumer by
    ///     queueing arbitrarily deep.
    public init(url: URL, pacing: ReplayPacing = .asFastAsPossible, bufferBound: Int = 4) {
        self.url = url
        self.pacing = pacing
        var continuation: AsyncStream<TimedFrame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .bufferingNewest(bufferBound)) {
            continuation = $0
        }
        self.continuation = continuation
    }

    public func start() async throws {
        guard !didStart else { return }
        didStart = true

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReplayFrameSourceError.fileNotFound(url)
        }

        let asset = AVURLAsset(url: url)

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw ReplayFrameSourceError.assetUnreadable(url: url, underlying: error)
        }
        guard !tracks.isEmpty else {
            throw ReplayFrameSourceError.noVideoTrack(url)
        }

        let composition: AVVideoComposition
        do {
            let configuration = try await AVVideoComposition.Configuration(for: asset)
            composition = AVVideoComposition(configuration: configuration)
        } catch {
            throw ReplayFrameSourceError.compositionUnavailable(url: url, underlying: error)
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ReplayFrameSourceError.readerCreationFailed(url: url, underlying: error)
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: outputSettings)
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw ReplayFrameSourceError.outputNotAddable(url)
        }
        reader.add(output)

        guard reader.startReading() else {
            throw ReplayFrameSourceError.startReadingFailed(url: url, underlying: reader.error)
        }

        let pacing = self.pacing
        let continuation = self.continuation
        readTask = Task.detached {
            await Self.pump(reader: reader, output: output, pacing: pacing, continuation: continuation)
        }
    }

    public func stop() async {
        readTask?.cancel()
        readTask = nil
        // Finish immediately rather than waiting for the detached loop to
        // notice cancellation: any `for await` over `frames` must complete
        // promptly, and AsyncStream.Continuation.finish() is documented
        // idempotent, so the loop's own finish() call once it exits is a
        // harmless no-op.
        continuation.finish()
    }

    /// The read loop. Deliberately a `static` function taking its state as
    /// parameters, not an actor-isolated method — see the type doc's
    /// "Concurrency" section for why.
    private static func pump(
        reader: AVAssetReader,
        output: AVAssetReaderVideoCompositionOutput,
        pacing: ReplayPacing,
        continuation: AsyncStream<TimedFrame>.Continuation
    ) async {
        let clock = ContinuousClock()
        var origin: ContinuousClock.Instant?
        var firstTimestamp: CMTime?

        while !Task.isCancelled, let sampleBuffer = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if pacing == .realtime {
                if origin == nil {
                    // First frame: establish the wall-clock origin against
                    // this frame's own timestamp, so every later frame is
                    // paced relative to the file's real timing, not to
                    // frame index or an assumed rate.
                    origin = clock.now
                    firstTimestamp = timestamp
                } else if let origin, let firstTimestamp {
                    let elapsedSeconds = (timestamp - firstTimestamp).seconds
                    if elapsedSeconds > 0 {
                        let target = origin.advanced(by: .seconds(elapsedSeconds))
                        try? await Task.sleep(until: target, clock: clock)
                    }
                }
            }

            continuation.yield(TimedFrame(buffer: pixelBuffer, timestamp: timestamp))

            if pacing == .asFastAsPossible {
                // No pacing delay, but still cooperatively yield: this is
                // what lets a concurrent stop() actually get scheduled
                // between frames instead of only after the whole clip has
                // been read, and keeps the detached task from monopolising
                // one worker thread across a long burst with zero
                // suspension points.
                await Task.yield()
            }
        }

        reader.cancelReading()
        continuation.finish()
    }
}
