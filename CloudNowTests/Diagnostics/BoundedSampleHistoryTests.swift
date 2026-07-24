@testable import CloudNow
import Testing

@Suite("Bounded sample history")
struct BoundedSampleHistoryTests {
    @Test("A new history is empty and reports its configured capacity")
    func initialState() {
        let history = BoundedSampleHistory<Int>(capacity: 3)

        #expect(history.capacity == 3)
        #expect(history.count == 0)
        #expect(history.isEmpty)
        #expect(!history.isFull)
        #expect(history.elements.isEmpty)
    }

    @Test("Samples remain in insertion order before capacity is reached")
    func insertionOrder() {
        var history = BoundedSampleHistory<Int>(capacity: 4)

        history.append(10)
        history.append(20)
        history.append(30)

        #expect(history.elements == [10, 20, 30])
        #expect(history.count == 3)
        #expect(!history.isFull)
    }

    @Test("Appending at capacity overwrites the oldest sample")
    func oldestSampleIsOverwritten() {
        var history = BoundedSampleHistory<Int>(capacity: 3)
        for value in 1 ... 4 {
            history.append(value)
        }

        #expect(history.elements == [2, 3, 4])
        #expect(history.count == 3)
        #expect(history.isFull)
    }

    @Test("Chronological order survives repeated ring wraparound")
    func repeatedWraparound() {
        var history = BoundedSampleHistory<Int>(capacity: 4)
        for value in 0 ..< 14 {
            history.append(value)
        }

        #expect(history.elements == [10, 11, 12, 13])
    }

    @Test("A one-sample history always contains the newest value")
    func singleSampleCapacity() {
        var history = BoundedSampleHistory<String>(capacity: 1)

        history.append("first")
        history.append("second")
        history.append("third")

        #expect(history.elements == ["third"])
        #expect(history.count == 1)
    }

    @Test(
        "Reset empties wrapped storage and permits clean reuse",
        arguments: [true, false]
    )
    func resetAndReuse(keepingCapacity: Bool) {
        var history = BoundedSampleHistory<Int>(capacity: 3)
        for value in 0 ..< 8 {
            history.append(value)
        }

        history.reset(keepingCapacity: keepingCapacity)

        #expect(history.isEmpty)
        #expect(history.elements.isEmpty)
        #expect(history.capacity == 3)

        history.append(42)
        history.append(43)
        #expect(history.elements == [42, 43])
    }

    @Test("Reading elements returns an independent value")
    func elementsAreIndependent() {
        var history = BoundedSampleHistory<Int>(capacity: 2)
        history.append(1)
        history.append(2)
        var snapshot = history.elements

        snapshot[0] = 99

        #expect(snapshot == [99, 2])
        #expect(history.elements == [1, 2])
    }
}
