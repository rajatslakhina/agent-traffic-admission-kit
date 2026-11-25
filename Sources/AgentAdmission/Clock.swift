import Foundation

/// Millisecond time source. Injected everywhere so tests and the simulator are deterministic.
public protocol AdmissionClock: Sendable {
    func nowMillis() -> Int64
}

/// Monotonic wall-independent clock (`ContinuousClock`), as milliseconds since creation.
public struct MonotonicClock: AdmissionClock {
    private let origin: ContinuousClock.Instant

    public init() { origin = ContinuousClock.now }

    public func nowMillis() -> Int64 {
        let elapsed = origin.duration(to: ContinuousClock.now).components
        let fromSeconds = Saturating.multiply(elapsed.seconds, 1_000)
        // attoseconds is in 0..<1e18, so dividing by 1e15 gives 0..<1000 and cannot overflow.
        return Saturating.add(fromSeconds, elapsed.attoseconds / 1_000_000_000_000_000)
    }
}

/// Milliseconds since 1970 (wall time). Use it for anything persisted across processes, such as
/// an ``IntentKeyCache`` saved to disk. It can jump when the user changes the time; consumers
/// here treat a backwards jump conservatively.
public struct WallClock: AdmissionClock {
    public init() {}
    public func nowMillis() -> Int64 {
        Saturating.int64(Date().timeIntervalSince1970 * 1_000)
    }
}

/// A clock tests and the demo advance by hand.
///
/// `@unchecked Sendable` is sound here: the only stored state is guarded by `lock` on every access.
public final class ManualClock: AdmissionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int64

    public init(startingAt millis: Int64 = 0) { current = millis }

    public func nowMillis() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(byMillis delta: Int64) {
        lock.lock(); defer { lock.unlock() }
        current = Saturating.add(current, max(0, delta))
    }
}

/// SplitMix64: tiny, fast, and fully deterministic for a given seed, which is all the simulator needs.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in the half-open interval (0, 1]: never 0, so `-log(u)` is always finite.
    public mutating func unitOpenClosed() -> Double {
        // 53 random bits mapped to 1...2^53, then scaled.
        let bits = (next() >> 11) &+ 1
        return Double(bits) / 9_007_199_254_740_992.0
    }
}

/// Client-side retry behaviour for agent-shaped callers.
public struct RetryPolicy: Sendable, Equatable {
    /// Total attempts including the first. Clamped to `1...10`.
    public let maxAttempts: Int
    public let baseDelayMillis: Int64
    public let maxDelayMillis: Int64
    /// When `true`, the server's Retry-After is a floor on the delay.
    public let honoursRetryAfter: Bool
    /// Extra random delay as a fraction of the computed delay, `0...1`. Desynchronises a burst of
    /// agents that were all shed at the same instant.
    public let jitterFraction: Double

    public init(maxAttempts: Int, baseDelayMillis: Int64, maxDelayMillis: Int64, honoursRetryAfter: Bool, jitterFraction: Double) {
        self.maxAttempts = min(max(1, maxAttempts), 10)
        self.baseDelayMillis = max(0, baseDelayMillis)
        self.maxDelayMillis = max(self.baseDelayMillis, maxDelayMillis)
        self.honoursRetryAfter = honoursRetryAfter
        self.jitterFraction = jitterFraction.isFinite ? min(max(0, jitterFraction), 1) : 0
    }

    /// Exponential backoff, honours Retry-After, 50% jitter.
    public static let wellBehavedAgent = RetryPolicy(
        maxAttempts: 4, baseDelayMillis: 250, maxDelayMillis: 8_000, honoursRetryAfter: true, jitterFraction: 0.5
    )

    /// What a lot of client code actually does: a fixed short delay, no jitter, ignores hints.
    public static let naiveAgent = RetryPolicy(
        maxAttempts: 4, baseDelayMillis: 200, maxDelayMillis: 200, honoursRetryAfter: false, jitterFraction: 0
    )

    /// A person who sees an error and taps the same button again about a second later.
    public static let personTapsAgain = RetryPolicy(
        maxAttempts: 2, baseDelayMillis: 1_000, maxDelayMillis: 1_000, honoursRetryAfter: true, jitterFraction: 0.5
    )

    /// Delay before the attempt that follows attempt number `attempt` (1-based), or `nil` when
    /// the budget is spent.
    public func delay<R: RandomNumberGenerator>(
        afterAttempt attempt: Int,
        retryAfterMillis: Int64?,
        using rng: inout R
    ) -> Int64? {
        guard attempt >= 1, attempt < maxAttempts else { return nil }
        let exponent = Int64(min(attempt - 1, 30))
        let backoff = min(maxDelayMillis, Saturating.multiply(baseDelayMillis, Int64(1) << exponent))
        var delay = backoff
        if honoursRetryAfter, let hint = retryAfterMillis, hint > 0 {
            delay = max(delay, hint)
        }
        guard jitterFraction > 0, delay > 0 else { return delay }
        let extra = Saturating.int64(Double(delay) * jitterFraction * rng.nextUnit())
        return Saturating.add(delay, max(0, extra))
    }

    /// Worst-case time from the first attempt starting to the last attempt's timeout, assuming
    /// each attempt waits `perAttemptTimeoutMillis` and every hint is at most
    /// `maxRetryAfterMillis`. An idempotency TTL shorter than this can let a late retry execute twice.
    public func horizonMillis(perAttemptTimeoutMillis: Int64, maxRetryAfterMillis: Int64) -> Int64 {
        var total: Int64 = 0
        for attempt in stride(from: 1, to: maxAttempts, by: 1) {
            let exponent = Int64(min(attempt - 1, 30))
            var d = min(maxDelayMillis, Saturating.multiply(baseDelayMillis, Int64(1) << exponent))
            if honoursRetryAfter { d = max(d, maxRetryAfterMillis) }
            d = Saturating.add(d, Saturating.int64(Double(d) * jitterFraction))
            total = Saturating.add(total, Saturating.add(perAttemptTimeoutMillis, d))
        }
        return Saturating.add(total, perAttemptTimeoutMillis)
    }
}

extension RandomNumberGenerator {
    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / 9_007_199_254_740_992.0
    }
}
