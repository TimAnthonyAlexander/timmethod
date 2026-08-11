import Testing

@testable import TimMethodCore

@Suite("RingBuffer")
struct RingBufferTests {
    @Test("partial fill keeps insertion order and does not overwrite")
    func partialFillKeepsOrder() {
        var buffer = RingBuffer<Int>(capacity: 5)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)

        #expect(buffer.count == 3)
        #expect(buffer.capacity == 5)
        #expect(!buffer.isFull)
        #expect(Array(buffer) == [1, 2, 3])
        #expect(buffer[0] == 1)
        #expect(buffer[2] == 3)
    }

    @Test("overfilling past capacity drops the oldest elements")
    func wraparoundDropsOldest() {
        var buffer = RingBuffer<Int>(capacity: 5)
        for value in 0..<8 {
            buffer.append(value)
        }

        // Capacity is 5, 8 elements were appended (0...7): only the last 5
        // (3, 4, 5, 6, 7) should remain, oldest first.
        #expect(buffer.count == 5)
        #expect(buffer.isFull)
        #expect(Array(buffer) == [3, 4, 5, 6, 7])
        #expect(buffer[0] == 3)
        #expect(buffer[4] == 7)
    }

    @Test("count saturates at capacity and never exceeds it")
    func countSaturatesAtCapacity() {
        var buffer = RingBuffer<Int>(capacity: 4)
        for value in 0..<100 {
            buffer.append(value)
            #expect(buffer.count <= 4)
        }
        #expect(buffer.count == 4)
    }

    @Test("indexed access is oldest-first after wraparound")
    func indexedAccessOrderingAfterWraparound() {
        var buffer = RingBuffer<String>(capacity: 3)
        for letter in ["a", "b", "c", "d", "e"] {
            buffer.append(letter)
        }
        // Appended a...e into capacity 3: c, d, e remain.
        #expect(buffer[0] == "c")
        #expect(buffer[1] == "d")
        #expect(buffer[2] == "e")
    }

    @Test("suffix returns the most recent N, oldest-first, clamped to count")
    func suffixReturnsMostRecent() {
        var buffer = RingBuffer<Int>(capacity: 10)
        for value in 0..<6 {
            buffer.append(value)
        }
        #expect(buffer.suffix(3) == [3, 4, 5])
        #expect(buffer.suffix(0) == [])
        // Asking for more than count returns everything, not a crash.
        #expect(buffer.suffix(100) == [0, 1, 2, 3, 4, 5])
    }

    @Test("suffix after wraparound only ever sees currently-held elements")
    func suffixAfterWraparound() {
        var buffer = RingBuffer<Int>(capacity: 4)
        for value in 0..<10 {
            buffer.append(value)
        }
        // Held: 6, 7, 8, 9.
        #expect(buffer.suffix(2) == [8, 9])
        #expect(buffer.suffix(4) == [6, 7, 8, 9])
    }

    @Test("empty buffer has zero count and empty iteration")
    func emptyBuffer() {
        let buffer = RingBuffer<Int>(capacity: 5)
        #expect(buffer.count == 0)
        #expect(buffer.isEmpty)
        #expect(Array(buffer) == [])
    }

    @Test("value semantics: copies are independent")
    func valueSemantics() {
        var original = RingBuffer<Int>(capacity: 4)
        original.append(1)
        original.append(2)

        var copy = original
        copy.append(3)

        #expect(Array(original) == [1, 2])
        #expect(Array(copy) == [1, 2, 3])
    }
}
