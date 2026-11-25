import Foundation

/// A client-minted key that names one *user intent*, not one HTTP attempt. Mint it when the
/// person (or the assistant on their behalf) decides to act, and send the same key on every
/// retry of that intent, so the server can execute the write at most once.
public struct IdempotencyKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// Validates the key: 1...128 printable ASCII characters, no spaces.
    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 128,
              rawValue.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }
        self.rawValue = rawValue
    }

    /// A fresh random key (UUID v4: 122 random bits).
    public static func mint() -> IdempotencyKey {
        // A UUID string is 36 printable ASCII characters, so validation cannot fail.
        IdempotencyKey(unchecked: UUID().uuidString)
    }

    private init(unchecked: String) { self.rawValue = unchecked }

    public var description: String { rawValue }
}

/// The pure bookkeeping behind at-most-once writes, shared by the simulator (keyed by intent)
/// and the live ``Gateway`` (keyed by principal, skill, capability and idempotency key).
///
/// * A key is **in flight** from ``begin(_:fingerprint:now:)`` until ``complete(_:value:now:)``
///   or ``abandon(_:)``.
/// * A **completed** key replays its stored value until `ttlMillis` after completion. After
///   that it is forgotten, so a retry arriving later than the TTL executes again: the TTL must
///   be longer than the client's whole retry horizon (see ``RetryPolicy/horizonMillis``).
/// * **Nothing unexpired is ever evicted**, in flight or completed. Evicting a completed entry
///   early would turn a retry of a lost response into a second execution. When the ledger is
///   full of live entries, ``begin(_:fingerprint:now:)`` returns ``BeginResult/full`` and the
///   caller sheds the request instead of running it unprotected (fail closed). Size `capacity`
///   for peak writes × TTL.
/// * A key reused with a **different fingerprint** (a different payload) is a conflict, not a
///   replay: replaying the old result for a new request would be silently wrong.
/// * Failures are **not** cached: ``abandon(_:)`` drops the entry, so the client's next retry
///   executes again. This is correct only if the handler fails atomically (see README limits).
/// * In-flight records have **no lease**. A handler that never returns pins its key (retries
///   get "in progress") and holds a slot. Bound handler time inside the handler itself; the
///   ledger can't safely expire a claim whose work may still commit.
public struct IdempotencyLedger<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    public enum Lookup: Sendable {
        case absent
        case replay(Value)
        case inFlight
        case conflict
    }

    public enum BeginResult: Sendable, Equatable {
        case started
        /// Every slot holds an unexpired entry; nothing can be evicted without risking a double run.
        case full
        /// The key is already present; call ``lookup(_:fingerprint:now:)`` first.
        case alreadyPresent
    }

    enum State: Sendable {
        case inFlight
        case completed(Value, expiresAt: Int64)
    }

    struct Entry: Sendable {
        let fingerprint: String
        var state: State
    }

    public let capacity: Int
    public let ttlMillis: Int64
    private var entries: [Key: Entry] = [:]
    /// Earliest expiry among completed records, so a full ledger only rescans when something
    /// can actually be reclaimed (no O(capacity) work per request while overloaded).
    private var earliestExpiry: Int64?
    /// Number of full scans performed. Exposed for tests.
    public private(set) var purgeScans = 0

    public init(capacity: Int, ttlMillis: Int64) {
        self.capacity = max(1, capacity)
        self.ttlMillis = max(1, ttlMillis)
    }

    public var count: Int { entries.count }

    public var inFlightCount: Int {
        entries.values.reduce(0) { acc, e in
            if case .inFlight = e.state { return acc + 1 }
            return acc
        }
    }

    public func lookup(_ key: Key, fingerprint: String, now: Int64) -> Lookup {
        guard let entry = entries[key] else { return .absent }
        switch entry.state {
        case .inFlight:
            return entry.fingerprint == fingerprint ? .inFlight : .conflict
        case let .completed(value, expiresAt):
            guard now < expiresAt else { return .absent }
            return entry.fingerprint == fingerprint ? .replay(value) : .conflict
        }
    }

    public mutating func begin(_ key: Key, fingerprint: String, now: Int64) -> BeginResult {
        if let existing = entries[key] {
            if case let .completed(_, expiresAt) = existing.state, now >= expiresAt {
                entries[key] = nil
            } else {
                return .alreadyPresent
            }
        }
        if entries.count >= capacity, let earliest = earliestExpiry, now >= earliest {
            // O(n) over a bounded n, and only when at least one record has expired.
            purgeExpired(now: now)
        }
        guard entries.count < capacity else { return .full }
        entries[key] = Entry(fingerprint: fingerprint, state: .inFlight)
        return .started
    }

    /// Marks an in-flight key completed. Ignored for keys that are not in flight.
    public mutating func complete(_ key: Key, value: Value, now: Int64) {
        guard var entry = entries[key], case .inFlight = entry.state else { return }
        let expiresAt = Saturating.add(now, ttlMillis)
        entry.state = .completed(value, expiresAt: expiresAt)
        entries[key] = entry
        earliestExpiry = min(earliestExpiry ?? expiresAt, expiresAt)
    }

    /// Drops an in-flight key so a retry may execute. Ignored for completed keys.
    public mutating func abandon(_ key: Key) {
        guard let entry = entries[key], case .inFlight = entry.state else { return }
        entries[key] = nil
    }

    public mutating func purgeExpired(now: Int64) {
        purgeScans += 1
        var earliest: Int64?
        entries = entries.filter { _, entry in
            guard case let .completed(_, expiresAt) = entry.state else { return true }
            guard now < expiresAt else { return false }
            earliest = min(earliest ?? expiresAt, expiresAt)
            return true
        }
        earliestExpiry = earliest
    }
}
