/// A fixed-capacity ring buffer with O(1) append.
///
/// Once `count` reaches `capacity`, appending overwrites the oldest element.
/// This is the backing storage for `RepSignal.samples` (SPEC §6): a rep's
/// signal only ever needs a bounded window of history, so a growing array
/// would just be paying an unbounded allocation cost for data nothing reads.
///
/// Value semantics: `RingBuffer` is a struct backed by a Swift `Array`, so
/// copies are independent (copy-on-write, same as any other Swift value
/// type). It is `Sendable` whenever `Element` is, with no `@unchecked` escape
/// hatch needed — every stored property is itself a plain Sendable value.
///
/// This is a data structure, not a framework: fixed capacity, append,
/// oldest-first iteration, indexed access, and "give me the last N". Nothing
/// else.
public struct RingBuffer<Element> {
    /// Backing storage, indexed by physical slot. `nil` entries only occur
    /// in slots that have never been written (i.e. beyond `count` while the
    /// buffer is still filling for the first time).
    private var storage: [Element?]

    /// Physical slot holding the oldest logical element (index 0).
    private var head: Int

    /// Number of logical elements currently held, `0...capacity`.
    public private(set) var count: Int

    /// Fixed maximum number of elements this buffer can hold.
    public let capacity: Int

    /// Creates an empty ring buffer that holds at most `capacity` elements.
    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
        self.head = 0
        self.count = 0
    }

    public var isEmpty: Bool { count == 0 }
    public var isFull: Bool { count == capacity }

    /// Appends `element` as the newest sample. O(1).
    ///
    /// When the buffer is already full, this overwrites the oldest element
    /// (logical index 0) and advances `head`, so the buffer always holds the
    /// most recent `capacity` elements ever appended.
    public mutating func append(_ element: Element) {
        let writeSlot = (head + count) % capacity
        storage[writeSlot] = element
        if count == capacity {
            head = (head + 1) % capacity
        } else {
            count += 1
        }
    }

    /// Indexed access in logical order: `self[0]` is the oldest element
    /// currently held, `self[count - 1]` is the newest.
    public subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count, "RingBuffer index out of range")
        // Force-unwrap is safe: every slot within `count` of `head` has been
        // written at least once by `append`.
        return storage[(head + index) % capacity]!
    }

    /// The most recent `n` elements, oldest-first. Returns fewer than `n` if
    /// the buffer holds fewer than `n` elements; never throws or crashes.
    public func suffix(_ n: Int) -> [Element] {
        let take = Swift.max(0, Swift.min(n, count))
        return (0..<take).map { self[count - take + $0] }
    }
}

extension RingBuffer: Sequence {
    /// Iterates oldest-first (logical index 0 through `count - 1`).
    public func makeIterator() -> AnyIterator<Element> {
        var index = 0
        return AnyIterator {
            guard index < self.count else { return nil }
            defer { index += 1 }
            return self[index]
        }
    }
}

extension RingBuffer: Sendable where Element: Sendable {}
