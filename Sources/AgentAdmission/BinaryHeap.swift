/// A minimal array-backed binary heap. `areInIncreasingOrder(a, b)` means `a` pops before `b`.
struct BinaryHeap<Element> {
    private var items: [Element] = []
    private let areInIncreasingOrder: (Element, Element) -> Bool

    init(_ areInIncreasingOrder: @escaping (Element, Element) -> Bool) {
        self.areInIncreasingOrder = areInIncreasingOrder
    }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    mutating func push(_ element: Element) {
        items.append(element)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard areInIncreasingOrder(items[child], items[parent]) else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Element? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var best = parent
            if left < items.count, areInIncreasingOrder(items[left], items[best]) { best = left }
            if right < items.count, areInIncreasingOrder(items[right], items[best]) { best = right }
            guard best != parent else { break }
            items.swapAt(parent, best)
            parent = best
        }
        return top
    }
}
