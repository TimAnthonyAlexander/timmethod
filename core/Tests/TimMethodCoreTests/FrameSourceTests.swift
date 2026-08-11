import CoreMedia
import Testing

@testable import TimMethodCore

@Suite("FrameSource / TimedFrame")
struct FrameSourceTests {

    @Test("consumer receives every frame in order with monotonic timestamps")
    func deliversFramesInOrder() async throws {
        // Buffer bound comfortably exceeds frameCount, so nothing is
        // dropped and this test is purely about ordering.
        let source = StubFrameSource(frameCount: 5, bufferBound: 8)
        try await source.start()
        await source.stop()

        var received: [TimedFrame] = []
        for await frame in source.frames {
            received.append(frame)
        }

        #expect(received.count == 5)
        let timestamps = received.map(\.timestamp.value)
        #expect(timestamps == [0, 1, 2, 3, 4])
        for index in 1..<timestamps.count {
            #expect(timestamps[index] > timestamps[index - 1])
        }
    }

    @Test("overflow drops the OLDEST frames, keeping only the newest bufferBound")
    func dropsOldestOnOverflow() async throws {
        // A small, explicit bound: 2 is large enough that "drops one
        // element" and "keeps everything" would look identical only by
        // coincidence, but small enough that pushing 5 frames forces
        // multiple drops and leaves an unambiguous survivor set to assert
        // on. Both calls below are awaited to completion before the
        // `for await` loop starts, so all 5 yields have already run
        // through the buffering policy — this is not a timing-dependent
        // race, the drops have already happened by the time we read.
        let bufferBound = 2
        let frameCount = 5
        let source = StubFrameSource(frameCount: frameCount, bufferBound: bufferBound)

        try await source.start()
        await source.stop()

        var received: [TimedFrame] = []
        for await frame in source.frames {
            received.append(frame)
        }

        // If the policy were backwards (.bufferingOldest, or a manual
        // "drop newest" queue) this would instead observe timestamps
        // [0, 1] — the two OLDEST pushed frames. Observing [3, 4] proves
        // it is the oldest frames that were discarded, not the newest.
        #expect(received.count == bufferBound)
        let expectedTimestamps: [CMTimeValue] = [3, 4]
        #expect(received.map(\.timestamp.value) == expectedTimestamps)
    }

    @Test("stop() finishes the stream so for-await completes instead of hanging")
    func stopTerminatesStream() async throws {
        // Zero frames are ever yielded. Without stop() calling
        // continuation.finish(), this `for await` has nothing else that
        // could possibly end it and would hang forever — so completing at
        // all, with zero elements, is the thing under test here, distinct
        // from the ordering/backpressure tests above.
        let source = StubFrameSource(frameCount: 0, bufferBound: 4)
        try await source.start()
        await source.stop()

        var count = 0
        for await _ in source.frames {
            count += 1
        }
        #expect(count == 0)
    }
}
