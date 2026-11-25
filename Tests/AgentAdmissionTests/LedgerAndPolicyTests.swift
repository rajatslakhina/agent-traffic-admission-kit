import XCTest
@testable import AgentAdmission

/// Counts hashing and equality work, so a test can bound how many keys an operation touches.
/// `@unchecked Sendable` is sound here: each test uses its own instance from a single thread.
private final class WorkCounter: @unchecked Sendable {
    var touches = 0
}

private struct CountingKey: Hashable, Sendable {
    let id: Int
    let counter: WorkCounter
    func hash(into hasher: inout Hasher) {
        counter.touches += 1
        hasher.combine(id)
    }
    static func == (a: CountingKey, b: CountingKey) -> Bool {
        a.counter.touches += 1
        return a.id == b.id
    }
}

private func key(_ s: String) -> IdempotencyKey {
    guard let k = IdempotencyKey(s) else { preconditionFailure("test key \(s) is invalid") }
    return k
}

final class IdempotencyLedgerTests: XCTestCase {
    func testCompletedKeyReplaysUntilTTLThenIsForgotten() {
        var ledger = IdempotencyLedger<IdempotencyKey, Int>(capacity: 4, ttlMillis: 1_000)
        XCTAssertEqual(ledger.begin(key("a"), fingerprint: "f", now: 0), .started)
        ledger.complete(key("a"), value: 42, now: 100)
        guard case let .replay(v) = ledger.lookup(key("a"), fingerprint: "f", now: 1_099) else { return XCTFail("expected replay") }
        XCTAssertEqual(v, 42)
        // Expiry is exclusive at completion + TTL.
        guard case .absent = ledger.lookup(key("a"), fingerprint: "f", now: 1_100) else { return XCTFail("expected absent after TTL") }
        XCTAssertEqual(ledger.begin(key("a"), fingerprint: "f", now: 1_100), .started)
    }

    func testSameKeyDifferentPayloadIsAConflictNotAReplay() {
        var ledger = IdempotencyLedger<IdempotencyKey, Int>(capacity: 4, ttlMillis: 1_000)
        _ = ledger.begin(key("a"), fingerprint: "order-1", now: 0)
        guard case .conflict = ledger.lookup(key("a"), fingerprint: "order-2", now: 1) else { return XCTFail("in-flight conflict") }
        ledger.complete(key("a"), value: 1, now: 2)
        guard case .conflict = ledger.lookup(key("a"), fingerprint: "order-2", now: 3) else { return XCTFail("completed conflict") }
    }

    func testInFlightEntriesAreNeverEvictedSoAFullLedgerRefuses() {
        var ledger = IdempotencyLedger<IdempotencyKey, Int>(capacity: 2, ttlMillis: 1_000)
        XCTAssertEqual(ledger.begin(key("a"), fingerprint: "f", now: 0), .started)
        XCTAssertEqual(ledger.begin(key("b"), fingerprint: "f", now: 0), .started)
        XCTAssertEqual(ledger.begin(key("c"), fingerprint: "f", now: 0), .full)
        guard case .inFlight = ledger.lookup(key("a"), fingerprint: "f", now: 0) else { return XCTFail("a must survive") }
        guard case .inFlight = ledger.lookup(key("b"), fingerprint: "f", now: 0) else { return XCTFail("b must survive") }
    }

    /// Evicting an unexpired completed record would turn the retry of a lost response into a
    /// second execution, so a full ledger refuses instead and only reclaims expired records.
    func testFullLedgerNeverEvictsAnUnexpiredCompletedRecord() {
        var ledger = IdempotencyLedger<IdempotencyKey, Int>(capacity: 2, ttlMillis: 1_000)
        _ = ledger.begin(key("paid"), fingerprint: "f", now: 0)
        ledger.complete(key("paid"), value: 1, now: 0)
        _ = ledger.begin(key("busy"), fingerprint: "f", now: 10)
        XCTAssertEqual(ledger.begin(key("new"), fingerprint: "f", now: 20), .full)
        guard case .replay(1) = ledger.lookup(key("paid"), fingerprint: "f", now: 20) else {
            return XCTFail("the completed record must still replay")
        }
        // Once "paid" expires its slot can be reclaimed.
        XCTAssertEqual(ledger.begin(key("new"), fingerprint: "f", now: 1_000), .started)
        guard case .absent = ledger.lookup(key("paid"), fingerprint: "f", now: 1_000) else { return XCTFail("expired") }
    }

    /// A full ledger refuses until a record expires, then admits into the reclaimed slot.
    func testFullLedgerRefusesUntilARecordExpires() {
        var ledger = IdempotencyLedger<Int, Int>(capacity: 2, ttlMillis: 1_000)
        for k in 0..<2 {
            _ = ledger.begin(k, fingerprint: "", now: 0)
            ledger.complete(k, value: k, now: 0)
        }
        for i in 0..<100 { XCTAssertEqual(ledger.begin(100 + i, fingerprint: "", now: 500), .full) }
        XCTAssertEqual(ledger.begin(999, fingerprint: "", now: 1_000), .started)
        XCTAssertEqual(ledger.count, 2)
    }

    /// The saturated steady state: the ledger stays full while records expire one by one and
    /// new writes take their slots. (Work per request is bounded in the CountingKey tests below.)
    func testSaturatedLedgerKeepsAdmittingAsRecordsExpire() {
        // TTL equals capacity in ms, so with one write per ms exactly one record expires per step.
        var ledger = IdempotencyLedger<Int, Int>(capacity: 100, ttlMillis: 100)
        for k in 0..<100 {
            XCTAssertEqual(ledger.begin(k, fingerprint: "", now: Int64(k)), .started)
            ledger.complete(k, value: k, now: Int64(k))
        }
        for step in 0..<1_000 {
            let now = Int64(100 + step)
            // The record completed 100 ms ago (an original, or an earlier refill) has just expired.
            XCTAssertEqual(ledger.begin(10_000 + step, fingerprint: "", now: now), .started, "step \(step)")
            ledger.complete(10_000 + step, value: step, now: now)
            XCTAssertLessThanOrEqual(ledger.count, 100)
        }
        XCTAssertEqual(ledger.count, 100)
    }

    /// Measures work, not a call count: rebuilding the table (the 2.1.0 bug) would touch all
    /// 10,000 keys; reclaiming through the heap touches typically about a dozen. The bound
    /// (capacity / 20) leaves room for hash-seed variance and still separates O(1) from a rebuild;
    /// CI also pins `SWIFT_DETERMINISTIC_HASHING=1`.
    func testReclaimingOneSlotInAFullTenThousandEntryLedgerTouchesABoundedNumberOfKeys() {
        let counter = WorkCounter()
        var ledger = IdempotencyLedger<CountingKey, Int>(capacity: 10_000, ttlMillis: 1_000)
        for i in 0..<10_000 {
            let k = CountingKey(id: i, counter: counter)
            _ = ledger.begin(k, fingerprint: "", now: Int64(i))
            ledger.complete(k, value: i, now: Int64(i))
        }
        // At 1_000 exactly one record (completed at 0) has expired.
        counter.touches = 0
        XCTAssertEqual(ledger.begin(CountingKey(id: -1, counter: counter), fingerprint: "", now: 1_000), .started)
        XCTAssertLessThanOrEqual(counter.touches, 10_000 / 20)
        XCTAssertEqual(ledger.count, 10_000)
    }

    /// When a whole burst expires at once, one `begin` frees one slot instead of paying for all
    /// of them on a single request.
    func testAMassExpiryIsReclaimedOneSlotPerBegin() {
        let counter = WorkCounter()
        var ledger = IdempotencyLedger<CountingKey, Int>(capacity: 5_000, ttlMillis: 1_000)
        for i in 0..<5_000 {
            let k = CountingKey(id: i, counter: counter)
            _ = ledger.begin(k, fingerprint: "", now: 0)
            ledger.complete(k, value: i, now: 0)
        }
        counter.touches = 0
        XCTAssertEqual(ledger.begin(CountingKey(id: -1, counter: counter), fingerprint: "", now: 10_000), .started)
        XCTAssertLessThanOrEqual(counter.touches, 5_000 / 20)
        XCTAssertEqual(ledger.count, 5_000, "only one expired record was reclaimed")
    }

    func testSaturatedSteadyStateWorkStaysBoundedPerRequest() {
        let counter = WorkCounter()
        var ledger = IdempotencyLedger<CountingKey, Int>(capacity: 2_000, ttlMillis: 2_000)
        for i in 0..<2_000 {
            let k = CountingKey(id: i, counter: counter)
            _ = ledger.begin(k, fingerprint: "", now: Int64(i))
            ledger.complete(k, value: i, now: Int64(i))
        }
        counter.touches = 0
        for step in 0..<3_000 {
            let now = Int64(2_000 + step)
            let k = CountingKey(id: 100_000 + step, counter: counter)
            XCTAssertEqual(ledger.begin(k, fingerprint: "", now: now), .started)
            ledger.complete(k, value: step, now: now)
        }
        // A table rebuild per request would be ~2,000 touches each, 6,000,000 in total.
        XCTAssertLessThanOrEqual(counter.touches, 3_000 * 100)
    }

    func testMillisUntilReclaimPointsAtTheEarliestExpiry() {
        var ledger = IdempotencyLedger<Int, Int>(capacity: 2, ttlMillis: 1_000)
        XCTAssertNil(ledger.millisUntilReclaim(now: 0))
        _ = ledger.begin(1, fingerprint: "", now: 0)
        XCTAssertNil(ledger.millisUntilReclaim(now: 0), "in-flight records have no expiry")
        ledger.complete(1, value: 1, now: 200)
        XCTAssertEqual(ledger.millisUntilReclaim(now: 500), 700)
        XCTAssertEqual(ledger.millisUntilReclaim(now: 5_000), 0)
    }

    func testAbandonFreesAnInFlightKeyButNotACompletedOne() {
        var ledger = IdempotencyLedger<IdempotencyKey, Int>(capacity: 4, ttlMillis: 1_000)
        _ = ledger.begin(key("a"), fingerprint: "f", now: 0)
        ledger.abandon(key("a"))
        guard case .absent = ledger.lookup(key("a"), fingerprint: "f", now: 0) else { return XCTFail("abandoned key should be absent") }
        _ = ledger.begin(key("b"), fingerprint: "f", now: 0)
        ledger.complete(key("b"), value: 7, now: 0)
        ledger.abandon(key("b"))
        guard case .replay = ledger.lookup(key("b"), fingerprint: "f", now: 1) else { return XCTFail("completed key must not be abandoned") }
    }

    func testBeginTwiceIsRefusedAndCompleteOnUnknownKeyIsIgnored() {
        var ledger = IdempotencyLedger<IdempotencyKey, Int>(capacity: 4, ttlMillis: 1_000)
        _ = ledger.begin(key("a"), fingerprint: "f", now: 0)
        XCTAssertEqual(ledger.begin(key("a"), fingerprint: "f", now: 0), .alreadyPresent)
        ledger.complete(key("zzz"), value: 1, now: 0)
        XCTAssertEqual(ledger.count, 1)
    }

    func testHugeTTLSaturatesInsteadOfOverflowing() {
        var ledger = IdempotencyLedger<IdempotencyKey, Int>(capacity: 1, ttlMillis: .max)
        _ = ledger.begin(key("a"), fingerprint: "f", now: .max - 1)
        ledger.complete(key("a"), value: 1, now: .max - 1)
        guard case .replay = ledger.lookup(key("a"), fingerprint: "f", now: .max - 1) else { return XCTFail("expected replay") }
    }
}

final class ClassAwarePolicyTests: XCTestCase {
    func testStandardConfigurationIsValid() {
        XCTAssertEqual(ClassAwarePolicy.Configuration.standard.validationIssues(), [])
    }

    func testInvertedThresholdsAreReportedByValidation() {
        var config = ClassAwarePolicy.Configuration.standard
        config.shedDepth[.interactive] = 4
        let issues = config.validationIssues()
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues.first?.contains("interactive") ?? false)
    }

    func testShedsAgentReadsFirstAndInteractiveLast() {
        let config = ClassAwarePolicy.Configuration(
            shedDepth: [.agentRead: 2, .widget: 4, .agentWrite: 6, .interactive: 8], buckets: [:]
        )
        func admitted(_ t: TrafficClass, depth: Int) -> Bool {
            var p = ClassAwarePolicy(configuration: config, now: 0)
            return p.decide(t, load: LoadSignal(queueDepth: depth, workers: 1, meanServiceMillis: 10), now: 0).isAdmitted
        }
        XCTAssertTrue(admitted(TrafficClass(.siriAgent, .read), depth: 1))
        XCTAssertFalse(admitted(TrafficClass(.siriAgent, .read), depth: 2))
        XCTAssertTrue(admitted(TrafficClass(.widget, .read), depth: 3))
        XCTAssertFalse(admitted(TrafficClass(.widget, .read), depth: 4))
        XCTAssertFalse(admitted(TrafficClass(.widget, .write), depth: 4))
        XCTAssertTrue(admitted(TrafficClass(.siriAgent, .write), depth: 5))
        XCTAssertFalse(admitted(TrafficClass(.shortcut, .write), depth: 6))
        XCTAssertTrue(admitted(TrafficClass(.interactiveUI, .write), depth: 7))
        XCTAssertFalse(admitted(TrafficClass(.interactiveUI, .read), depth: 8))
    }

    func testOverloadShedDoesNotBurnATokenAndCarriesADrainHint() {
        let config = ClassAwarePolicy.Configuration(
            shedDepth: [.agentWrite: 1], buckets: [TrafficClass(.siriAgent, .write): BucketSpec(capacity: 1, refillPerSecond: 1)],
            minRetryAfterMillis: 10, maxRetryAfterMillis: 10_000
        )
        var p = ClassAwarePolicy(configuration: config, now: 0)
        let busy = LoadSignal(queueDepth: 40, workers: 4, meanServiceMillis: 50)
        XCTAssertEqual(p.decide(TrafficClass(.siriAgent, .write), load: busy, now: 0), .shed(.overloaded, retryAfterMillis: 500))
        // The overload shed must not have spent the bucket's only token.
        let idle = LoadSignal(queueDepth: 0, workers: 4, meanServiceMillis: 50)
        XCTAssertTrue(p.decide(TrafficClass(.siriAgent, .write), load: idle, now: 0).isAdmitted)
        XCTAssertEqual(p.decide(TrafficClass(.siriAgent, .write), load: idle, now: 0), .shed(.rateLimited, retryAfterMillis: 1_000))
    }

    func testInteractiveTrafficIsNotRateLimitedByDefault() {
        var p = ClassAwarePolicy(now: 0)
        let idle = LoadSignal(queueDepth: 0, workers: 8, meanServiceMillis: 50)
        for _ in 0..<5_000 {
            XCTAssertTrue(p.decide(TrafficClass(.interactiveUI, .read), load: idle, now: 0).isAdmitted)
        }
    }

    func testRetryHintIsClampedAndNeverZero() {
        var p = ClassAwarePolicy(now: 0)
        let huge = LoadSignal(queueDepth: Int.max, workers: 1, meanServiceMillis: .max)
        XCTAssertEqual(p.decide(TrafficClass(.siriAgent, .read), load: huge, now: 0), .shed(.overloaded, retryAfterMillis: 30_000))
        let tiny = LoadSignal(queueDepth: 8, workers: 512, meanServiceMillis: 1)
        XCTAssertEqual(p.decide(TrafficClass(.siriAgent, .read), load: tiny, now: 0), .shed(.overloaded, retryAfterMillis: 250))
    }
}

/// A deliberately broken policy: it protects agents and sheds people first.
private struct InvertedPolicy: AdmissionPolicy {
    var name: String { "Inverted (mutant)" }
    mutating func decide(_ traffic: TrafficClass, load: LoadSignal, now: Int64) -> AdmissionDecision {
        let limit = 8 * (ShedTier.allCases.count - traffic.shedTier.rawValue)
        return load.queueDepth >= limit ? .shed(.overloaded, retryAfterMillis: 1) : .admit(priority: 0)
    }
}

final class ShedOrderAuditTests: XCTestCase {
    func testShippedPolicyPassesTheAudit() {
        XCTAssertEqual(ShedOrderAudit.audit { ClassAwarePolicy(now: 0) }, [])
    }

    func testAuditCatchesAPolicyThatShedsPeopleBeforeAgents() {
        let violations = ShedOrderAudit.audit { InvertedPolicy() }
        XCTAssertFalse(violations.isEmpty)
        XCTAssertTrue(violations.contains { $0.admittedTier == .agentRead && $0.shedTier == .interactive })
    }

    func testAuditCatchesAMisconfiguredClassAwarePolicy() {
        var config = ClassAwarePolicy.Configuration.standard
        config.shedDepth[.agentWrite] = 4   // below agentRead's 8
        XCTAssertFalse(ShedOrderAudit.audit { ClassAwarePolicy(configuration: config, now: 0) }.isEmpty)
    }

    func testAuditClampsAHostileDepthInsteadOfRunningAway() {
        XCTAssertEqual(ShedOrderAudit.audit(maxDepth: .max) { ClassBlindFIFOPolicy(queueCapacity: 16) }, [])
        XCTAssertEqual(ShedOrderAudit.audit(maxDepth: .min) { ClassAwarePolicy(now: 0) }, [])
    }

    func testClassBlindBaselineIsOrderNeutralSoTheAuditPassesIt() {
        // Documented: FIFO never sheds one tier while admitting another, it just doesn't prefer anyone.
        XCTAssertEqual(ShedOrderAudit.audit { ClassBlindFIFOPolicy(queueCapacity: 16) }, [])
    }
}

final class ScopeAuthorityTests: XCTestCase {
    let orders = Capability("orders", .write)
    let menu = Capability("menu", .read)

    func grant(_ caller: CallerClass = .siriAgent, expires: Int64 = 1_000) -> SkillGrant {
        SkillGrant(skillID: "reorder", caller: caller, capabilities: [orders, menu], expiresAtMillis: expires)
    }

    func testAllowsOnlyGrantedCapabilitiesForTheGrantedClass() throws {
        var authority = ScopeAuthority()
        let token = try authority.issue(grant(), now: 0).get()
        XCTAssertEqual(try authority.authorize(token, capability: orders, claimedCaller: .siriAgent, now: 1).get().skillID, "reorder")
        XCTAssertEqual(authority.authorize(token, capability: Capability("payments", .write), claimedCaller: .siriAgent, now: 1),
                       .failure(.capabilityNotGranted(Capability("payments", .write))))
        XCTAssertEqual(authority.authorize(token, capability: orders, claimedCaller: .interactiveUI, now: 1),
                       .failure(.callerClassMismatch(claimed: .interactiveUI, granted: .siriAgent)))
    }

    func testExpiryIsExclusiveAndRevocationIsImmediate() throws {
        var authority = ScopeAuthority()
        let token = try authority.issue(grant(expires: 100), now: 0).get()
        XCTAssertEqual(authority.authorize(token, capability: menu, claimedCaller: .siriAgent, now: 100), .failure(.expired))
        let other = try authority.issue(grant(expires: 1_000), now: 0).get()
        authority.revoke(other)
        XCTAssertEqual(authority.authorize(other, capability: menu, claimedCaller: .siriAgent, now: 1), .failure(.unknownToken))
    }

    func testIssueRejectsEmptyExpiredAndOverCapacityGrants() {
        var authority = ScopeAuthority(maxGrants: 1)
        XCTAssertEqual(authority.issue(SkillGrant(skillID: "x", caller: .widget, capabilities: [], expiresAtMillis: 10), now: 0), .failure(.emptyCapabilities))
        XCTAssertEqual(authority.issue(grant(expires: 5), now: 5), .failure(.alreadyExpired))
        XCTAssertNotNil(try? authority.issue(grant(expires: 10), now: 0).get())
        XCTAssertEqual(authority.issue(grant(expires: 20), now: 1), .failure(.tooManyGrants))
        // Once the first grant expires its slot is reclaimed.
        XCTAssertNotNil(try? authority.issue(grant(expires: 30), now: 10).get())
    }

    func testCollidingTokenSourceNeverOverwritesALiveGrant() throws {
        var authority = ScopeAuthority()
        let first = try authority.issue(grant(.interactiveUI), now: 0) { "same" }.get()
        let second = try authority.issue(grant(.siriAgent), now: 0) { "same" }.get()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try authority.authorize(first, capability: menu, claimedCaller: .interactiveUI, now: 1).get().caller, .interactiveUI)
    }

    func testAFullAuthorityReclaimsExpiredGrantsAsTheyLapse() throws {
        var authority = ScopeAuthority(maxGrants: 3)
        for i in 0..<3 {
            _ = try authority.issue(grant(expires: Int64(100 + i)), now: 0).get()
        }
        XCTAssertEqual(authority.issue(grant(expires: 500), now: 50), .failure(.tooManyGrants))
        // One grant lapses at 100: exactly one slot frees up.
        XCTAssertNotNil(try? authority.issue(grant(expires: 500), now: 100).get())
        XCTAssertEqual(authority.issue(grant(expires: 500), now: 100), .failure(.tooManyGrants))
        XCTAssertEqual(authority.grantCount, 3)
    }

    func testRevokedThenReissuedTokenIsNotReclaimedByItsOldExpiry() throws {
        var authority = ScopeAuthority(maxGrants: 2)
        let a = try authority.issue(grant(expires: 100), now: 0) { "A" }.get()
        authority.revoke(a)
        let again = try authority.issue(grant(expires: 1_000), now: 0) { "A" }.get()
        XCTAssertEqual(again, a)
        _ = try authority.issue(grant(expires: 1_000), now: 0) { "B" }.get()
        // At 100 the stale (100, "A") heap entry pops; the live "A" (expiring at 1000) must survive.
        XCTAssertEqual(authority.issue(grant(expires: 1_000), now: 100), .failure(.tooManyGrants))
        XCTAssertNotNil(try? authority.authorize(a, capability: menu, claimedCaller: .siriAgent, now: 100).get())
    }

    func testTokenDescriptionDoesNotLeakTheSecret() {
        let token = ScopeToken(rawValue: "SECRET-VALUE-1234")
        XCTAssertFalse(token.description.contains("SECRET"))
    }
}
