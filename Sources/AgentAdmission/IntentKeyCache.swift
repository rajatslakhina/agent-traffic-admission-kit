/// Keeps one ``IdempotencyKey`` per *intent* alive across `AppIntent.perform()` calls.
///
/// The trap this exists for: minting the key inside `perform()` gives every invocation a new
/// key, and an assistant's retry is a new invocation, so nothing would ever be deduplicated.
/// The key has to outlive `perform()`. This cache hands back the same key for the same intent
/// signature (e.g. `"reorder:" + order.digest`) until the intent succeeds (``clear(_:)``) or the
/// window passes, so a retry after a lost response reuses the key and gets a replay.
///
/// Trade-off, chosen on purpose: two *deliberate*, identical requests inside the window while
/// the first hasn't been cleared are treated as one. Clear on success to keep the window to
/// "retries of an unfinished intent".
///
/// Honest limit: this is in-memory, so it lives as long as the process. If the system runs
/// your intent in a fresh process for a retry, persist entries (e.g. in an app-group
/// `UserDefaults`) with the same semantics, and feed it ``WallClock`` (not ``MonotonicClock``,
/// whose zero is process start). A reading earlier than an entry's mint time reuses the key:
/// when the clock is in doubt, the cache errs toward deduplicating. Wrap it in ``IntentKeys``
/// to share one across concurrent `perform()` calls.
public struct IntentKeyCache: Sendable {
    private struct Entry: Sendable {
        let key: IdempotencyKey
        let mintedAt: Int64
    }

    public let windowMillis: Int64
    public let capacity: Int
    private var entries: [String: Entry] = [:]

    /// - Parameters:
    ///   - windowMillis: how long an un-cleared intent keeps its key. Clamped to at least 1.
    ///   - capacity: most signatures kept; the oldest is dropped beyond it. Clamped to at least 1.
    public init(windowMillis: Int64 = 2 * 60 * 1_000, capacity: Int = 256) {
        self.windowMillis = max(1, windowMillis)
        self.capacity = max(1, capacity)
    }

    public var count: Int { entries.count }

    /// The key for `signature`: the existing one inside the window, otherwise a fresh one.
    public mutating func key(for signature: String, now: Int64, mint: () -> IdempotencyKey = IdempotencyKey.mint) -> IdempotencyKey {
        // A reading before the mint time (clock skew, a process-relative clock) counts as inside
        // the window: reusing a key can at worst merge two identical intents; minting one can
        // double-charge.
        if let entry = entries[signature], Saturating.subtract(now, entry.mintedAt) < windowMillis {
            return entry.key
        }
        if entries[signature] == nil, entries.count >= capacity {
            entries = entries.filter { Saturating.subtract(now, $0.value.mintedAt) < windowMillis }
            if entries.count >= capacity, let oldest = entries.min(by: { $0.value.mintedAt < $1.value.mintedAt })?.key {
                entries[oldest] = nil
            }
        }
        let key = mint()
        entries[signature] = Entry(key: key, mintedAt: now)
        return key
    }

    /// Call when the intent succeeded, so the next identical request is a new intent.
    public mutating func clear(_ signature: String) {
        entries[signature] = nil
    }
}

/// An actor around ``IntentKeyCache`` so every `perform()` in the process shares one cache
/// safely under Swift 6 concurrency.
public actor IntentKeys {
    private var cache: IntentKeyCache
    private let clock: any AdmissionClock

    public init(clock: any AdmissionClock = WallClock(), windowMillis: Int64 = 2 * 60 * 1_000, capacity: Int = 256) {
        self.clock = clock
        self.cache = IntentKeyCache(windowMillis: windowMillis, capacity: capacity)
    }

    public func key(for signature: String) -> IdempotencyKey {
        cache.key(for: signature, now: clock.nowMillis())
    }

    public func clear(_ signature: String) {
        cache.clear(signature)
    }
}
