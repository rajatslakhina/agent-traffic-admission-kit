/// A token bucket in integer milli-tokens with an injected millisecond clock.
///
/// Integer arithmetic keeps it deterministic (the simulator and the tests replay exactly), and
/// the unit choice makes refill cheap: `refillPerSecond` tokens per second is exactly
/// `refillPerSecond` milli-tokens per millisecond.
///
/// A clock that goes backwards is ignored rather than "refunding" negative time: the bucket
/// keeps its last refill instant and waits for the clock to catch up.
public struct TokenBucket: Sendable, Equatable {
    public let capacity: Int64
    public let refillPerSecond: Int64
    public private(set) var milliTokens: Int64
    public private(set) var lastRefillMillis: Int64

    /// - Parameters:
    ///   - capacity: burst size in whole tokens. Clamped to `1...1_000_000`.
    ///   - refillPerSecond: sustained rate. Clamped to `0...1_000_000`; `0` means "never refills".
    ///   - now: the clock reading the bucket starts full at.
    public init(capacity: Int64, refillPerSecond: Int64, now: Int64) {
        self.capacity = Saturating.clamp(capacity, 1, 1_000_000)
        self.refillPerSecond = Saturating.clamp(refillPerSecond, 0, 1_000_000)
        self.milliTokens = Saturating.multiply(self.capacity, 1_000)
        self.lastRefillMillis = now
    }

    public var wholeTokens: Int64 { milliTokens / 1_000 }

    public mutating func refill(now: Int64) {
        guard now > lastRefillMillis else { return }
        let elapsed = Saturating.subtract(now, lastRefillMillis)
        let added = Saturating.multiply(elapsed, refillPerSecond)
        milliTokens = min(Saturating.multiply(capacity, 1_000), Saturating.add(milliTokens, added))
        lastRefillMillis = now
    }

    /// Takes one token if available.
    public mutating func tryTake(now: Int64) -> Bool {
        refill(now: now)
        guard milliTokens >= 1_000 else { return false }
        milliTokens -= 1_000
        return true
    }

    /// Milliseconds until one whole token is available; `0` if one is available now,
    /// `nil` if the bucket never refills and is empty.
    public func millisUntilNextToken(now: Int64) -> Int64? {
        var copy = self
        copy.refill(now: now)
        let missing = 1_000 - copy.milliTokens
        guard missing > 0 else { return 0 }
        return Saturating.ceilDivide(missing, refillPerSecond)
    }
}
