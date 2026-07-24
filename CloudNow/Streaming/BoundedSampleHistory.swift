import Foundation

/// Fixed-capacity, append-only sample storage that preserves chronological order.
///
/// Appends are O(1). Reading `elements` materializes at most `capacity` values in
/// oldest-to-newest order, regardless of whether the internal ring has wrapped.
nonisolated struct BoundedSampleHistory<Element> {
    let capacity: Int

    private var storage: [Element] = []
    private var nextWriteIndex = 0

    init(capacity: Int) {
        precondition(capacity > 0, "A bounded sample history requires a positive capacity")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    var count: Int {
        storage.count
    }

    var isEmpty: Bool {
        storage.isEmpty
    }

    var isFull: Bool {
        storage.count == capacity
    }

    var elements: [Element] {
        guard isFull, nextWriteIndex > 0 else {
            return storage
        }

        return Array(storage[nextWriteIndex...]) + storage[..<nextWriteIndex]
    }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
            return
        }

        storage[nextWriteIndex] = element
        nextWriteIndex = (nextWriteIndex + 1) % capacity
    }

    mutating func reset(keepingCapacity: Bool = true) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        nextWriteIndex = 0
        if keepingCapacity {
            storage.reserveCapacity(capacity)
        }
    }
}

extension BoundedSampleHistory: Sendable where Element: Sendable {}
