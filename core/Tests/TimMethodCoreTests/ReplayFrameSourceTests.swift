import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import TimMethodCore

@Suite("ReplayFrameSource")
struct ReplayFrameSourceTests {

    // MARK: - Timestamps

    @Test("a 10s 60fps clip yields ~600 frames with strictly monotonic timestamps matching the source rate")
    func tenSecondSixtyFpsClip() async throws {
        let clip = try await TestMovieWriter.writeClip(
            frameCount: 600,
            frameRate: 60,
            size: CGSize(width: 16, height: 16)
        )
        defer { try? FileManager.default.removeItem(at: clip.url) }

        let clock = ContinuousClock()
        let started = clock.now

        let source = ReplayFrameSource(url: clip.url)
        try await source.start()

        var received: [TimedFrame] = []
        for await frame in source.frames {
            received.append(frame)
        }

        let elapsed = clock.now - started

        #expect(received.count == 600)

        let timestamps = received.map(\.timestamp)
        for index in 1..<timestamps.count {
            #expect(timestamps[index].seconds > timestamps[index - 1].seconds)
        }

        // Spot-check a handful of consecutive deltas against the source's
        // true 1/60 s spacing, not an assumed or rounded one.
        for index in [1, 250, 599] {
            let delta = timestamps[index].seconds - timestamps[index - 1].seconds
            #expect(abs(delta - (1.0 / 60.0)) < 1e-6)
        }

        // Total span should be (600 - 1) / 60 s of source timing.
        let totalSpan = timestamps[599].seconds - timestamps[0].seconds
        #expect(abs(totalSpan - (599.0 / 60.0)) < 1e-4)

        // Default pacing is `.asFastAsPossible`: replaying a clip whose own
        // duration is ~10s must take nowhere near 10s of real wall time.
        // Measured well under 1s while writing this test on real hardware;
        // 5s is a generous ceiling that still decisively rules out
        // accidental realtime pacing.
        #expect(elapsed < .seconds(5))
    }

    @Test("clips at frame rates other than 60 report their own true timestamps", arguments: [24, 30])
    func nonSixtyFpsClipReportsOwnRate(frameRate: Int) async throws {
        let clip = try await TestMovieWriter.writeClip(
            frameCount: 12,
            frameRate: Int32(frameRate),
            size: CGSize(width: 16, height: 16)
        )
        defer { try? FileManager.default.removeItem(at: clip.url) }

        let source = ReplayFrameSource(url: clip.url)
        try await source.start()

        var received: [TimedFrame] = []
        for await frame in source.frames {
            received.append(frame)
        }

        #expect(received.count == clip.frameCount)

        let expectedDelta = 1.0 / Double(frameRate)
        for index in 1..<received.count {
            let delta = received[index].timestamp.seconds - received[index - 1].timestamp.seconds
            #expect(abs(delta - expectedDelta) < 1e-6)
            // Regression guard: this must not be a synthesised 60 Hz clock.
            #expect(abs(delta - (1.0 / 60.0)) > 1e-6)
        }
    }

    // MARK: - Content

    @Test("frame content survives the round trip through real video encoding")
    func frameContentSurvivesRoundTrip() async throws {
        let markers: [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)] = [
            (b: 0, g: 0, r: 255, a: 255),  // red
            (b: 0, g: 255, r: 0, a: 255),  // green
            (b: 255, g: 0, r: 0, a: 255),  // blue
            (b: 255, g: 255, r: 255, a: 255),  // white
            (b: 0, g: 0, r: 0, a: 255),  // black
        ]
        let clip = try await TestMovieWriter.writeClip(
            frameCount: markers.count,
            frameRate: 10,
            size: CGSize(width: 16, height: 16),
            colorForFrame: { markers[$0] }
        )
        defer { try? FileManager.default.removeItem(at: clip.url) }

        let source = ReplayFrameSource(url: clip.url)
        try await source.start()

        var received: [TimedFrame] = []
        for await frame in source.frames {
            received.append(frame)
        }

        #expect(received.count == markers.count)

        for (index, frame) in received.enumerated() {
            let actual = readBGRA(at: (x: 0, y: 0), from: frame.buffer)
            assertColorRoughlyMatches(actual, markers[index], frameIndex: index)
        }
    }

    // MARK: - Rotation

    @Test("a portrait clip arrives upright")
    func portraitClipArrivesUpright() async throws {
        // A track encoded landscape (64x48) carrying the standard iOS
        // "portrait" preferredTransform (90° clockwise). A conformer that
        // ignored the transform (a plain AVAssetReaderTrackOutput) would
        // deliver 64x48 buffers unchanged; honouring it must deliver 48x64.
        let encodedSize = CGSize(width: 64, height: 48)
        let portraitTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: encodedSize.height, ty: 0)

        let clip = try await TestMovieWriter.writeClip(
            frameCount: 3,
            frameRate: 10,
            size: encodedSize,
            preferredTransform: portraitTransform,
            colorForFrame: { _ in (b: 128, g: 128, r: 128, a: 255) }
        )
        defer { try? FileManager.default.removeItem(at: clip.url) }

        let source = ReplayFrameSource(url: clip.url)
        try await source.start()

        var received: [TimedFrame] = []
        for await frame in source.frames {
            received.append(frame)
        }

        #expect(received.count == 3)
        for frame in received {
            #expect(CVPixelBufferGetWidth(frame.buffer) == 48)
            #expect(CVPixelBufferGetHeight(frame.buffer) == 64)
        }
    }

    // MARK: - Errors

    @Test("a missing file throws fileNotFound rather than crashing or yielding an empty stream")
    func missingFileThrows() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-frame-source-tests-missing-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        let source = ReplayFrameSource(url: url)
        do {
            try await source.start()
            Issue.record("expected start() to throw for a missing file")
        } catch ReplayFrameSourceError.fileNotFound(let missingURL) {
            #expect(missingURL == url)
        } catch {
            Issue.record("expected .fileNotFound, got \(error)")
        }
    }

    @Test("a file with no video track throws noVideoTrack rather than crashing or yielding an empty stream")
    func noVideoTrackThrows() async throws {
        // .caf (Core Audio Format), not .mov/.m4a: it natively stores the
        // linear PCM `AVAudioFormat.settings` used below without needing a
        // compressed-audio encoder configured, so this stays a plain,
        // reliably-writable "valid file, zero video tracks" fixture.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-frame-source-tests-audio-only-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else {
            Issue.record("could not construct AVAudioFormat")
            return
        }
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            Issue.record("could not construct AVAudioPCMBuffer")
            return
        }
        buffer.frameLength = 1024
        try audioFile.write(from: buffer)

        let source = ReplayFrameSource(url: url)
        do {
            try await source.start()
            Issue.record("expected start() to throw for an audio-only file")
        } catch ReplayFrameSourceError.noVideoTrack(let noTrackURL) {
            #expect(noTrackURL == url)
        } catch {
            Issue.record("expected .noVideoTrack, got \(error)")
        }
    }

    // MARK: - stop()

    @Test("stop() mid-read terminates the stream promptly instead of playing out the rest of the clip")
    func stopTerminatesStreamPromptly() async throws {
        let clip = try await TestMovieWriter.writeClip(
            frameCount: 20,
            frameRate: 20,
            size: CGSize(width: 16, height: 16)
        )
        defer { try? FileManager.default.removeItem(at: clip.url) }

        let source = ReplayFrameSource(url: clip.url)
        try await source.start()

        // Deterministically stop after exactly one frame — no wall-clock
        // race to get "mid-read" right, unlike stopping after a fixed delay.
        var iterator = source.frames.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first != nil)

        await source.stop()

        var received = first == nil ? 0 : 1
        while let _ = await iterator.next() {
            received += 1
        }

        #expect(received < clip.frameCount)
    }

    // MARK: - Pacing

    @Test("realtime pacing paces frame delivery to match the source clip's own timestamps")
    func realtimePacingMatchesSourceTiming() async throws {
        // 4 frames at 4fps spans 3/4 s from the first to the last frame.
        let clip = try await TestMovieWriter.writeClip(
            frameCount: 4,
            frameRate: 4,
            size: CGSize(width: 16, height: 16)
        )
        defer { try? FileManager.default.removeItem(at: clip.url) }

        let clock = ContinuousClock()
        let started = clock.now

        let source = ReplayFrameSource(url: clip.url, pacing: .realtime)
        try await source.start()

        var received: [TimedFrame] = []
        for await frame in source.frames {
            received.append(frame)
        }

        let elapsed = clock.now - started

        #expect(received.count == 4)
        #expect(elapsed >= .milliseconds(600))
        #expect(elapsed < .seconds(3))
    }
}

// MARK: - Pixel readback helpers

/// Reads the BGRA bytes of a single pixel from a locked `CVPixelBuffer`.
/// Test-only: production code never inspects pixel content by hand, it
/// hands buffers to CoreImage/Vision.
private func readBGRA(at point: (x: Int, y: Int), from pixelBuffer: CVPixelBuffer) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        return (0, 0, 0, 0)
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let rowBase = base.advanced(by: point.y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
    let offset = point.x * 4
    return (rowBase[offset], rowBase[offset + 1], rowBase[offset + 2], rowBase[offset + 3])
}

/// Asserts `actual` is close enough to `expected` to prove the pixel content
/// really did round-trip through `ReplayFrameSource`, while tolerating the
/// real (small, measured) rounding error `TestMovieWriter`'s doc comment
/// describes: a lossy codec's internal colour-matrix round trip, not a bug.
/// A tolerance of 40 (out of 255) is comfortably above the largest error
/// observed while building this test (~21, on ProRes 4444 at 16x16) but
/// nowhere near loose enough to pass if channels were, say, swapped or the
/// buffer were reading back a completely different frame's marker.
private func assertColorRoughlyMatches(
    _ actual: (b: UInt8, g: UInt8, r: UInt8, a: UInt8),
    _ expected: (b: UInt8, g: UInt8, r: UInt8, a: UInt8),
    frameIndex: Int,
    tolerance: Int = 40
) {
    func close(_ a: UInt8, _ b: UInt8) -> Bool {
        abs(Int(a) - Int(b)) <= tolerance
    }
    #expect(close(actual.b, expected.b), "frame \(frameIndex): blue \(actual.b) vs expected \(expected.b)")
    #expect(close(actual.g, expected.g), "frame \(frameIndex): green \(actual.g) vs expected \(expected.g)")
    #expect(close(actual.r, expected.r), "frame \(frameIndex): red \(actual.r) vs expected \(expected.r)")
    #expect(close(actual.a, expected.a), "frame \(frameIndex): alpha \(actual.a) vs expected \(expected.a)")
}
