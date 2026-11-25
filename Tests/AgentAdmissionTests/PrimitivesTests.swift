import XCTest
@testable import AgentAdmission

final class SaturatingMathTests: XCTestCase {
    func testAddSubtractMultiplySaturateInsteadOfTrapping() {
        XCTAssertEqual(Saturating.add(.max, 1), .max)
        XCTAssertEqual(Saturating.add(.min, -1), .min)
        XCTAssertEqual(Saturating.subtract(.min, 1), .min)
        XCTAssertEqual(Saturating.subtract(.max, -1), .max)
        XCTAssertEqual(Saturating.multiply(.max, 2), .max)
        XCTAssertEqual(Saturating.multiply(.min, 2), .min)
        XCTAssertEqual(Saturating.multiply(.min, -1), .max)
        XCTAssertEqual(Saturating.add(2, 3), 5)
    }

    func testDivisionByZeroAndMinOverMinusOneDoNotTrap() {
        XCTAssertNil(Saturating.divide(10, 0))
        XCTAssertEqual(Saturating.divide(.min, -1), .max)
        XCTAssertNil(Saturating.ceilDivide(10, 0))
        XCTAssertNil(Saturating.ceilDivide(10, -3))
        XCTAssertEqual(Saturating.ceilDivide(10, 3), 4)
        XCTAssertEqual(Saturating.ceilDivide(9, 3), 3)
        XCTAssertEqual(Saturating.ceilDivide(0, 3), 0)
        XCTAssertEqual(Saturating.ceilDivide(.max, 1), .max)
    }

    func testDoubleConversionClampsNaNInfinityAndOutOfRange() {
        XCTAssertEqual(Saturating.int64(.nan, fallback: 7), 7)
        XCTAssertEqual(Saturating.int64(.infinity), .max)
        XCTAssertEqual(Saturating.int64(-.infinity), .min)
        XCTAssertEqual(Saturating.int64(1e300), .max)
        XCTAssertEqual(Saturating.int64(9_223_372_036_854_775_808.0), .max)
        XCTAssertEqual(Saturating.int64(-2.9), -2)
    }

    func testIntConversionClampsToPlatformRange() {
        XCTAssertEqual(Saturating.int(Int64.max), Int.max)
        XCTAssertEqual(Saturating.int(42), 42)
    }

    func testClampWithInvertedBoundsReturnsLowerInsteadOfTrapping() {
        XCTAssertEqual(Saturating.clamp(5, 10, 1), 10)
    }
}

final class TokenBucketTests: XCTestCase {
    func testStartsFullDrainsThenRefillsAtTheConfiguredRate() {
        var bucket = TokenBucket(capacity: 3, refillPerSecond: 10, now: 0)
        XCTAssertTrue(bucket.tryTake(now: 0))
        XCTAssertTrue(bucket.tryTake(now: 0))
        XCTAssertTrue(bucket.tryTake(now: 0))
        XCTAssertFalse(bucket.tryTake(now: 0))
        // 10 tokens/s = one token per 100 ms.
        XCTAssertEqual(bucket.millisUntilNextToken(now: 0), 100)
        XCTAssertFalse(bucket.tryTake(now: 99))
        XCTAssertTrue(bucket.tryTake(now: 100))
    }

    func testRefillNeverExceedsCapacity() {
        var bucket = TokenBucket(capacity: 2, refillPerSecond: 1_000, now: 0)
        bucket.refill(now: 1_000_000)
        XCTAssertEqual(bucket.wholeTokens, 2)
    }

    func testClockGoingBackwardsNeitherRefundsNorTraps() {
        var bucket = TokenBucket(capacity: 1, refillPerSecond: 1, now: 10_000)
        XCTAssertTrue(bucket.tryTake(now: 10_000))
        XCTAssertFalse(bucket.tryTake(now: 0))
        XCTAssertEqual(bucket.lastRefillMillis, 10_000)
        XCTAssertTrue(bucket.tryTake(now: 11_000))
    }

    func testZeroRefillReportsNilWaitInsteadOfDividingByZero() {
        var bucket = TokenBucket(capacity: 1, refillPerSecond: 0, now: 0)
        XCTAssertTrue(bucket.tryTake(now: 0))
        XCTAssertNil(bucket.millisUntilNextToken(now: 5_000))
    }

    func testHugeElapsedTimeAndRatesSaturate() {
        var bucket = TokenBucket(capacity: .max, refillPerSecond: .max, now: .min)
        XCTAssertEqual(bucket.capacity, 1_000_000)
        bucket.refill(now: .max)
        XCTAssertEqual(bucket.wholeTokens, 1_000_000)
    }
}

final class RetryPolicyTests: XCTestCase {
    func testBudgetIsExhaustedAfterMaxAttempts() {
        var rng = SplitMix64(seed: 1)
        let policy = RetryPolicy(maxAttempts: 3, baseDelayMillis: 100, maxDelayMillis: 1_000, honoursRetryAfter: false, jitterFraction: 0)
        XCTAssertEqual(policy.delay(afterAttempt: 1, retryAfterMillis: nil, using: &rng), 100)
        XCTAssertEqual(policy.delay(afterAttempt: 2, retryAfterMillis: nil, using: &rng), 200)
        XCTAssertNil(policy.delay(afterAttempt: 3, retryAfterMillis: nil, using: &rng))
        XCTAssertNil(policy.delay(afterAttempt: 0, retryAfterMillis: nil, using: &rng))
    }

    func testRetryAfterIsAFloorOnlyWhenHonoured() {
        var rng = SplitMix64(seed: 1)
        let honours = RetryPolicy(maxAttempts: 4, baseDelayMillis: 100, maxDelayMillis: 1_000, honoursRetryAfter: true, jitterFraction: 0)
        let ignores = RetryPolicy(maxAttempts: 4, baseDelayMillis: 100, maxDelayMillis: 1_000, honoursRetryAfter: false, jitterFraction: 0)
        XCTAssertEqual(honours.delay(afterAttempt: 1, retryAfterMillis: 5_000, using: &rng), 5_000)
        XCTAssertEqual(ignores.delay(afterAttempt: 1, retryAfterMillis: 5_000, using: &rng), 100)
    }

    func testJitterStaysWithinTheConfiguredFractionAndVaries() {
        var rng = SplitMix64(seed: 99)
        let policy = RetryPolicy(maxAttempts: 2, baseDelayMillis: 1_000, maxDelayMillis: 1_000, honoursRetryAfter: false, jitterFraction: 0.5)
        var seen = Set<Int64>()
        for _ in 0..<200 {
            let d = policy.delay(afterAttempt: 1, retryAfterMillis: nil, using: &rng)
            guard let d else { return XCTFail("expected a delay") }
            XCTAssertGreaterThanOrEqual(d, 1_000)
            XCTAssertLessThanOrEqual(d, 1_500)
            seen.insert(d)
        }
        XCTAssertGreaterThan(seen.count, 50, "jitter that doesn't vary doesn't desynchronise anything")
    }

    func testExtremeInputsAreClampedAndDoNotTrap() {
        var rng = SplitMix64(seed: 3)
        let policy = RetryPolicy(maxAttempts: 1_000, baseDelayMillis: .max, maxDelayMillis: .max, honoursRetryAfter: true, jitterFraction: .nan)
        XCTAssertEqual(policy.maxAttempts, 10)
        XCTAssertEqual(policy.jitterFraction, 0)
        XCTAssertEqual(policy.delay(afterAttempt: 9, retryAfterMillis: .max, using: &rng), .max)
        XCTAssertEqual(policy.horizonMillis(perAttemptTimeoutMillis: .max, maxRetryAfterMillis: .max), .max)
    }

    func testDefaultLedgerTTLOutlivesTheWellBehavedAgentsRetryHorizon() {
        let horizon = RetryPolicy.wellBehavedAgent.horizonMillis(
            perAttemptTimeoutMillis: TrafficProfile.launchDay.clientTimeoutMillis,
            maxRetryAfterMillis: ClassAwarePolicy.Configuration.standard.maxRetryAfterMillis
        )
        XCTAssertGreaterThan(Gateway<Int>.Configuration().ledgerTTLMillis, horizon)
    }

    func testHorizonCoversEveryWaitAndEveryAttempt() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelayMillis: 100, maxDelayMillis: 1_000, honoursRetryAfter: false, jitterFraction: 0)
        // timeout + 100 + timeout + 200 + timeout
        XCTAssertEqual(policy.horizonMillis(perAttemptTimeoutMillis: 1_000, maxRetryAfterMillis: 0), 3_300)
    }
}

final class PercentileTests: XCTestCase {
    func testNearestRankOnSmallAndEmptyInputs() {
        XCTAssertNil(Percentile.nearestRank([], 0.99))
        XCTAssertNil(Percentile.nearestRank([1, 2], .nan))
        XCTAssertEqual(Percentile.nearestRank([7], 0.99), 7)
        let hundred = (1...100).map(Int64.init)
        XCTAssertEqual(Percentile.nearestRank(hundred, 0.99), 99)
        XCTAssertEqual(Percentile.nearestRank(hundred, 0.50), 50)
        XCTAssertEqual(Percentile.nearestRank(hundred, 0), 1)
        XCTAssertEqual(Percentile.nearestRank(hundred, 5), 100)
    }
}

final class BinaryHeapTests: XCTestCase {
    func testPopsInOrderAndHandlesEmpty() {
        var heap = BinaryHeap<Int>(<)
        XCTAssertNil(heap.pop())
        var rng = SplitMix64(seed: 5)
        let values = (0..<500).map { _ in Int(rng.next() % 1_000) }
        values.forEach { heap.push($0) }
        var out: [Int] = []
        while let v = heap.pop() { out.append(v) }
        XCTAssertEqual(out, values.sorted())
    }
}

final class FingerprintDigestTests: XCTestCase {
    func testDigestIsFixedSizeAndSeparatesDifferentPayloads() {
        let long = String(repeating: "x", count: 1_000_000)
        XCTAssertEqual(FingerprintDigest.digest(long).count, 32)
        XCTAssertEqual(FingerprintDigest.digest("").count, 32)
        XCTAssertEqual(FingerprintDigest.digest("latte"), FingerprintDigest.digest("latte"))
        XCTAssertNotEqual(FingerprintDigest.digest("latte"), FingerprintDigest.digest("espresso"))
        XCTAssertNotEqual(FingerprintDigest.digest(long), FingerprintDigest.digest(long + "y"))
    }
}

final class IdempotencyKeyTests: XCTestCase {
    func testDecodingAppliesTheSameValidationAsTheInitializer() throws {
        let decoder = JSONDecoder()
        for bad in ["\"\"", "\"a b\"", "\"" + String(repeating: "a", count: 129) + "\""] {
            XCTAssertThrowsError(try decoder.decode(IdempotencyKey.self, from: Data(bad.utf8)), bad)
        }
        let key = IdempotencyKey.mint()
        let data = try JSONEncoder().encode(key)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(key.rawValue)\"")
        XCTAssertEqual(try decoder.decode(IdempotencyKey.self, from: data), key)
    }

    func testValidation() {
        XCTAssertNil(IdempotencyKey(""))
        XCTAssertNil(IdempotencyKey("has space"))
        XCTAssertNil(IdempotencyKey(String(repeating: "a", count: 129)))
        XCTAssertNil(IdempotencyKey("émoji"))
        XCTAssertNotNil(IdempotencyKey(String(repeating: "a", count: 128)))
        XCTAssertNotEqual(IdempotencyKey.mint(), IdempotencyKey.mint())
    }
}

final class SuccessPercentTextTests: XCTestCase {
    func testRoundsDownSoNearlyPerfectNeverShowsAsPerfect() {
        var r = ClassReport(traffic: TrafficClass(.interactiveUI, .read))
        XCTAssertEqual(r.successPercentText, "100%")
        r.intents = 10_000
        r.succeeded = 9_996
        XCTAssertEqual(r.successPercentText, "99.9%")
        r.succeeded = 10_000
        XCTAssertEqual(r.successPercentText, "100%")
        r.succeeded = 4_097
        XCTAssertEqual(r.successPercentText, "40.9%")
        r.succeeded = 0
        XCTAssertEqual(r.successPercentText, "0.0%")
    }
}

final class IntentKeyCacheTests: XCTestCase {
    func testSameIntentGetsTheSameKeyAcrossInvocationsUntilClearedOrExpired() {
        var cache = IntentKeyCache(windowMillis: 1_000, capacity: 8)
        let first = cache.key(for: "reorder:usual", now: 0)
        XCTAssertEqual(cache.key(for: "reorder:usual", now: 999), first, "a retry inside the window reuses the key")
        XCTAssertNotEqual(cache.key(for: "reorder:other", now: 10), first)
        cache.clear("reorder:usual")
        let afterSuccess = cache.key(for: "reorder:usual", now: 20)
        XCTAssertNotEqual(afterSuccess, first, "a new intent after success gets a new key")
        XCTAssertNotEqual(cache.key(for: "reorder:usual", now: 1_020), afterSuccess, "the window ends")
    }

    func testCapacityIsBounded() {
        var cache = IntentKeyCache(windowMillis: 10_000, capacity: 3)
        for i in 0..<10 { _ = cache.key(for: "s\(i)", now: Int64(i)) }
        XCTAssertEqual(cache.count, 3)
    }

    /// A persisted cache read by a process-relative clock sees "future" mint times. Reusing the
    /// key is the safe direction: minting a new one would let a retry double-charge.
    func testClockGoingBackwardsReusesTheKeyInsteadOfMintingANewOne() {
        var cache = IntentKeyCache(windowMillis: 10_000, capacity: 3)
        let k = cache.key(for: "x", now: 1_000_000)
        XCTAssertEqual(cache.key(for: "x", now: 5), k)
    }

    func testIntentKeysActorSharesOneKeyAcrossConcurrentCallers() async {
        let keys = IntentKeys(clock: ManualClock(startingAt: 0))
        let all = await withTaskGroup(of: IdempotencyKey.self) { group in
            for _ in 0..<20 { group.addTask { await keys.key(for: "reorder:usual") } }
            var out = Set<IdempotencyKey>()
            for await k in group { out.insert(k) }
            return out
        }
        XCTAssertEqual(all.count, 1)
        await keys.clear("reorder:usual")
        let fresh = await keys.key(for: "reorder:usual")
        XCTAssertFalse(all.contains(fresh))
    }

    func testWallClockIsEpochMilliseconds() {
        // 2020-01-01 in epoch ms; any machine running this test is past it.
        XCTAssertGreaterThan(WallClock().nowMillis(), 1_577_836_800_000)
    }
}
