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

    /// Decoding applies the same validation as ``init(_:)``, so a key from a request body or a
    /// persisted cache can't be empty, oversized or contain control characters.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let valid = IdempotencyKey(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "IdempotencyKey must be 1...128 printable ASCII characters with no spaces"
            )
        }
        self = valid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A fixed-size digest of a caller-supplied payload fingerprint, so a ledger record costs the
/// same whatever the caller sent. Two differently seeded and mixed 64-bit FNV-1a variants
/// (128 bits). Not cryptographic, and it doesn't need to be: the fingerprint is caller-supplied
/// and records are scoped per principal, so a collision gives a caller nothing it couldn't
/// already do to its own records by choosing the fingerprint.
public enum FingerprintDigest {
    public static func digest(_ fingerprint: String) -> String {
        var a: UInt64 = 0xcbf2_9ce4_8422_2325
        var b: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in fingerprint.utf8 {
            a = (a ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            b = (b ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            b = b &+ (b << 7)
        }
        return hex(a) + hex(b)
    }

    private static func hex(_ v: UInt64) -> String {
        let s = String(v, radix: 16)
        return String(repeating: "0", count: max(0, 16 - s.count)) + s
    }
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
///   for peak writes × TTL. Expired records are reclaimed through an expiry heap, one slot per
///   `begin`, so a full ledger costs amortised O(log n) per request, never a table scan.
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
    /// Completed records ordered by expiry, so reclaiming is amortised O(log n) per record and
    /// never a scan of the whole table, even when the ledger sits full under sustained load.
    private var expiries = ExpiryHeap<Key>()
    /// Number of ``purgeExpired(now:)`` calls (the only full-table sweep; `begin` never calls it).
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

    /// Milliseconds until the earliest completed record expires and frees a slot, or `nil` when
    /// no completed record exists (only in-flight work, which frees slots on completion).
    /// A good `Retry-After` for a request shed because the ledger is full.
    public func millisUntilReclaim(now: Int64) -> Int64? {
        guard let earliest = expiries.earliest else { return nil }
        return max(0, Saturating.subtract(earliest, now))
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
        if entries.count >= capacity {
            reclaimExpired(now: now)
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
        expiries.push(expiresAt, key)
        compactIfMostlyStale()
    }

    /// Drops an in-flight key so a retry may execute. Ignored for completed keys.
    public mutating func abandon(_ key: Key) {
        guard let entry = entries[key], case .inFlight = entry.state else { return }
        entries[key] = nil
    }

    /// Full-table sweep of expired records. Not needed for correctness or capacity (``begin``
    /// reclaims through the expiry heap); offered for callers that want to free memory eagerly.
    public mutating func purgeExpired(now: Int64) {
        purgeScans += 1
        entries = entries.filter { _, entry in
            if case let .completed(_, expiresAt) = entry.state { return now < expiresAt }
            return true
        }
        compactIfMostlyStale()
    }

    /// Pops expired pairs off the heap until one slot is free, removing the records they still
    /// describe. A pair is stale (skipped) if its record was already removed or re-recorded with
    /// another expiry. Amortised O(log n) per reclaimed record; stale pairs are bounded by
    /// compaction.
    private mutating func reclaimExpired(now: Int64) {
        // Free only what this `begin` needs: one slot. A whole burst expiring at once is then
        // reclaimed one record per request, not all at once on one unlucky request.
        while entries.count >= capacity, let (expiresAt, key) = expiries.popExpired(now: now) {
            if case let .completed(_, current)? = entries[key]?.state, current == expiresAt {
                entries[key] = nil
            }
        }
    }

    /// Keeps the heap within a constant factor of the live records.
    private mutating func compactIfMostlyStale() {
        guard expiries.count > 2 * entries.count + 64 else { return }
        let snapshot = entries
        expiries.compact { expiresAt, key in
            if case let .completed(_, current)? = snapshot[key]?.state { return current == expiresAt }
            return false
        }
    }
}
