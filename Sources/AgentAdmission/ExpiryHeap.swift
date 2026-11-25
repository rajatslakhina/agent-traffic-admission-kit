/// A `Sendable` min-heap of `(expiresAt, key)` pairs, used to reclaim expired records in
/// amortised O(log n) per record instead of scanning a whole table.
///
/// Entries are never updated in place: callers push a new pair when a record's expiry changes
/// and treat a popped pair as stale if the record no longer has that expiry. ``compact(keeping:)``
/// bounds the stale backlog.
struct ExpiryHeap<Key: Hashable & Sendable>: Sendable {
    private(set) var items: [(expiresAt: Int64, key: Key)] = []

    var count: Int { items.count }
    var earliest: Int64? { items.first?.expiresAt }

    mutating func push(_ expiresAt: Int64, _ key: Key) {
        items.append((expiresAt, key))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].expiresAt < items[parent].expiresAt else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    /// Pops the earliest pair if it has expired at `now`.
    mutating func popExpired(now: Int64) -> (expiresAt: Int64, key: Key)? {
        guard let first = items.first, first.expiresAt <= now else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var best = parent
            if left < items.count, items[left].expiresAt < items[best].expiresAt { best = left }
            if right < items.count, items[right].expiresAt < items[best].expiresAt { best = right }
            guard best != parent else { break }
            items.swapAt(parent, best)
            parent = best
        }
        return top
    }

    /// Rebuilds the heap from only the pairs `isLive` accepts. O(n log n); callers run it rarely
    /// (when stale pairs outnumber live records), so its cost is amortised.
    mutating func compact(keeping isLive: (Int64, Key) -> Bool) {
        let live = items.filter { isLive($0.expiresAt, $0.key) }
        items.removeAll(keepingCapacity: true)
        for pair in live { push(pair.expiresAt, pair.key) }
    }
}
