import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Test-support: writes a short, synthetic `.mov` via `AVAssetWriter` to
/// `FileManager.default.temporaryDirectory`, for `ReplayFrameSourceTests` to
/// read back through `ReplayFrameSource`. No fixture videos exist in this
/// repo yet (that is W1-06's job), so every `ReplayFrameSourceTests` case
/// round-trips a clip it wrote itself, with known, asserted frame count,
/// frame rate, and per-frame pixel content.
///
/// **Codec choice.** Frames are encoded with `AVVideoCodecType.proRes4444`,
/// not H.264/HEVC. This is still real, codec-based video encoding — not a
/// bypass of the "real video encoding" the task requires — but ProRes 4444
/// is 4:4:4 (no chroma subsampling) and reconstructs a flat, solid-colour
/// test frame with only single-digit-per-channel rounding error from its
/// internal colour-matrix round trip. Measured empirically while building
/// this file: H.264/HEVC's 4:2:0 subsampling plus that same colour-matrix
/// rounding pushed individual channel error into the 20s (out of 255) even
/// for solid colours, which would make a byte-exact round-trip assertion
/// either flaky or dishonestly loose. `ReplayFrameSourceTests` uses a
/// generous, documented tolerance regardless — see
/// `assertColorRoughlyMatches` there — but ProRes 4444 keeps that tolerance
/// meaningfully tight instead of having to swallow the extra 4:2:0 error on
/// top of the unavoidable colour-matrix error.
enum TestMovieWriter {
    struct Clip {
        let url: URL
        let frameCount: Int
        let frameRate: Int32
        let size: CGSize
    }

    enum WriterError: Error {
        case inputNotAddable
        case startWritingFailed((any Error)?)
        case pixelBufferPoolUnavailable
        case pixelBufferCreationFailed(CVReturn)
        case appendFailed((any Error)?)
        case finishWritingFailed((any Error)?)
    }

    /// Writes `frameCount` frames at `frameRate` fps, `size` pixels, to a
    /// freshly named file in the temp directory. Each frame is filled with
    /// one solid BGRA colour from `colorForFrame(index)` — a marker, not
    /// realistic footage, so a delivered frame's content can be checked by
    /// reading back a single pixel rather than comparing whole images.
    ///
    /// Presentation timestamps are `index / frameRate` seconds exactly
    /// (rational `CMTime`, no floating-point drift), so a caller asserting
    /// on delivered timestamps is asserting on an exactly-known ground
    /// truth, not an approximation of one.
    static func writeClip(
        frameCount: Int,
        frameRate: Int32,
        size: CGSize = CGSize(width: 32, height: 32),
        preferredTransform: CGAffineTransform = .identity,
        codec: AVVideoCodecType = .proRes4444,
        colorForFrame: (Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) = { index in
            // `index` is not reduced mod 256 until after the subtraction in
            // the naive form of this formula (`255 - index`), which goes
            // negative — and traps on the `UInt8` conversion — for any
            // index past 255. Reduce first so every component of the
            // formula stays in 0...255 for every non-negative index.
            let m = index % 256
            return (b: UInt8(m), g: UInt8((m * 53) % 256), r: UInt8(255 - m), a: 255)
        }
    ) async throws -> Clip {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-frame-source-tests-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        let writer = try AVAssetWriter(url: url, fileType: .mov)

        let outputSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.transform = preferredTransform
        input.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(input) else {
            throw WriterError.inputNotAddable
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw WriterError.startWritingFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }

            guard let pool = adaptor.pixelBufferPool else {
                throw WriterError.pixelBufferPoolUnavailable
            }
            var pixelBufferOut: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferOut)
            guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
                throw WriterError.pixelBufferCreationFailed(status)
            }
            fill(pixelBuffer: pixelBuffer, with: colorForFrame(index))

            let presentationTime = CMTime(value: CMTimeValue(index), timescale: frameRate)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw WriterError.appendFailed(writer.error)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw WriterError.finishWritingFailed(writer.error)
        }

        return Clip(url: url, frameCount: frameCount, frameRate: frameRate, size: size)
    }

    private static func fill(pixelBuffer: CVPixelBuffer, with color: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        for row in 0..<height {
            let rowBase = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for col in 0..<width {
                let offset = col * 4
                rowBase[offset] = color.b
                rowBase[offset + 1] = color.g
                rowBase[offset + 2] = color.r
                rowBase[offset + 3] = color.a
            }
        }
    }
}
