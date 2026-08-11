import CoreMedia
import CoreVideo

@testable import TimMethodCore

/// A synthetic `FrameSource` for tests: no camera, no file I/O, just
/// `CVPixelBufferCreate`d `32BGRA` buffers (matching the live pipeline's
/// pixel format, SPEC §4.2) with monotonically increasing `CMTime`
/// timestamps.
///
/// `start()` yields exactly `frameCount` frames, back to back, synchronously
/// — there is no background `Task`, no delay, and no real-time pacing.
/// That is deliberate: it makes the backpressure tests deterministic. When
/// a test `await`s `start()` and then `stop()` *before* it ever begins
/// iterating `frames`, every yield has already run against the buffering
/// policy by the time the test starts reading, so overflow (if any) has
/// already happened rather than being a race the test might or might not
/// observe.
actor StubFrameSource: FrameSource {
    nonisolated let frames: AsyncStream<TimedFrame>
    private let continuation: AsyncStream<TimedFrame>.Continuation
    private let frameCount: Int
    private let frameDuration: CMTime

    /// - Parameters:
    ///   - frameCount: how many synthetic frames `start()` yields.
    ///   - bufferBound: the `.bufferingNewest` bound backing `frames`. Kept
    ///     explicit per-instance (rather than a single constant) so tests
    ///     can pick a bound that makes the scenario under test obvious —
    ///     large enough to hold everything when proving in-order delivery,
    ///     small enough to force overflow when proving drop-oldest.
    ///   - frameDuration: spacing between consecutive synthetic timestamps.
    ///     Defaults to one tick at 60 fps to match SPEC §4.2's live frame
    ///     rate, though the stub never actually waits this long.
    init(
        frameCount: Int,
        bufferBound: Int,
        frameDuration: CMTime = CMTime(value: 1, timescale: 60)
    ) {
        self.frameCount = frameCount
        self.frameDuration = frameDuration
        var continuation: AsyncStream<TimedFrame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .bufferingNewest(bufferBound)) {
            continuation = $0
        }
        self.continuation = continuation
    }

    func start() async throws {
        for index in 0..<frameCount {
            let buffer = try Self.makeSyntheticPixelBuffer()
            let timestamp = CMTimeMultiply(frameDuration, multiplier: Int32(index))
            continuation.yield(TimedFrame(buffer: buffer, timestamp: timestamp))
        }
    }

    func stop() async {
        continuation.finish()
    }

    private static func makeSyntheticPixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            4,
            4,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw StubFrameSourceError.pixelBufferCreationFailed(status: status)
        }
        return buffer
    }
}

enum StubFrameSourceError: Error {
    case pixelBufferCreationFailed(status: CVReturn)
}
