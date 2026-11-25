import XCTest
@testable import AgentAdmission

/// Counts handler runs and the peak number running at once.
private actor Probe {
    private(set) var runs = 0
    private(set) var running = 0
    private(set) var peak = 0
    func enter() { runs += 1; running += 1; peak = max(peak, running) }
    func leave() { running -= 1 }
}

private struct Boom: Error {}

/// Suspends handlers until the test opens it.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        for c in waiting { c.resume() }
        waiting.removeAll()
    }
}

final class GatewayTests: XCTestCase {
    let reorder = Capability("orders", .write)
    let browse = Capability("menu", .read)

    private func makeGateway(_ config: Gateway<Int>.Configuration = .init()) -> (Gateway<Int>, ManualClock) {
        let clock = ManualClock(startingAt: 0)
        return (Gateway<Int>(configuration: config, clock: clock), clock)
    }

    private func token(_ gateway: Gateway<Int>, caller: CallerClass, caps: Set<Capability>) async throws -> ScopeToken {
        try await gateway.issue(SkillGrant(skillID: "reorder", caller: caller, capabilities: caps, expiresAtMillis: 60_000)).get()
    }

    func testFiftyConcurrentRetriesOfOneWriteExecuteTheHandlerOnce() async throws {
        var config = Gateway<Int>.Configuration()
        config.maxWaitersPerKey = 64
        let (gateway, _) = makeGateway(config)
        let tok = try await token(gateway, caller: .siriAgent, caps: [reorder])
        let probe = Probe()
        let key = IdempotencyKey.mint()
        let request = GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: "usual")

        let outcomes = await withTaskGroup(of: GatewayOutcome<Int>.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await gateway.handle(request) {
                        await probe.enter()
                        try await Task.sleep(nanoseconds: 20_000_000)
                        await probe.leave()
                        return 7
                    }
                }
            }
            var all: [GatewayOutcome<Int>] = []
            for await o in group { all.append(o) }
            return all
        }

        let runs = await probe.runs
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(outcomes.count, 50)
        var fresh = 0, replayed = 0
        for o in outcomes {
            guard case let .success(v, wasReplayed) = o else { return XCTFail("unexpected \(o)") }
            XCTAssertEqual(v, 7)
            if wasReplayed { replayed += 1 } else { fresh += 1 }
        }
        XCTAssertEqual(fresh, 1)
        XCTAssertEqual(replayed, 49)
        let ledgerCount = await gateway.ledgerCount
        XCTAssertEqual(ledgerCount, 1)
    }

    /// Control for the test above: the same harness with no key really does run concurrently, so
    /// the single execution above is the ledger's doing, not an accident of scheduling.
    func testControlWithoutKeysTheSameHarnessRunsConcurrently() async throws {
        var config = Gateway<Int>.Configuration()
        config.policy.shedDepth = [:]
        config.policy.buckets = [:]
        let (gateway, _) = makeGateway(config)
        let tok = try await token(gateway, caller: .siriAgent, caps: [browse])
        let probe = Probe()
        let request = GatewayRequest(token: tok, capability: browse, claimedCaller: .siriAgent, idempotencyKey: nil, fingerprint: "")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    _ = await gateway.handle(request) {
                        await probe.enter()
                        try await Task.sleep(nanoseconds: 20_000_000)
                        await probe.leave()
                        return 1
                    }
                }
            }
        }
        let runs = await probe.runs
        let peak = await probe.peak
        XCTAssertEqual(runs, 50)
        XCTAssertGreaterThan(peak, 1, "harness must actually overlap handlers")
    }

    func testCompletedWriteReplaysWithoutRunningAgain() async throws {
        let (gateway, clock) = makeGateway()
        let tok = try await token(gateway, caller: .siriAgent, caps: [reorder])
        let probe = Probe()
        let request = GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: .mint(), fingerprint: "p")
        _ = await gateway.handle(request) { await probe.enter(); await probe.leave(); return 1 }
        clock.advance(byMillis: 5_000)
        let second = await gateway.handle(request) { await probe.enter(); await probe.leave(); return 2 }
        guard case let .success(v, replayed) = second else { return XCTFail("expected success") }
        XCTAssertEqual(v, 1)
        XCTAssertTrue(replayed)
        let runs = await probe.runs
        XCTAssertEqual(runs, 1)
    }

    func testShedHappensBeforeTheHandlerRuns() async throws {
        var config = Gateway<Int>.Configuration()
        config.policy.buckets = [TrafficClass(.siriAgent, .read): BucketSpec(capacity: 1, refillPerSecond: 0)]
        let (gateway, _) = makeGateway(config)
        let tok = try await token(gateway, caller: .siriAgent, caps: [browse])
        let probe = Probe()
        let request = GatewayRequest(token: tok, capability: browse, claimedCaller: .siriAgent, idempotencyKey: nil, fingerprint: "")
        _ = await gateway.handle(request) { await probe.enter(); await probe.leave(); return 1 }
        let second = await gateway.handle(request) { await probe.enter(); await probe.leave(); return 1 }
        guard case let .shed(reason, retryAfter) = second else { return XCTFail("expected shed, got \(second)") }
        XCTAssertEqual(reason, .rateLimited)
        XCTAssertEqual(retryAfter, 30_000)
        let runs = await probe.runs
        XCTAssertEqual(runs, 1)
        let counters = await gateway.countersByClass()[TrafficClass(.siriAgent, .read)]
        XCTAssertEqual(counters?.shed, 1)
        XCTAssertEqual(counters?.executed, 1)
    }

    func testWritesWithoutAKeyAreRejectedAndNeverRun() async throws {
        let (gateway, _) = makeGateway()
        let tok = try await token(gateway, caller: .interactiveUI, caps: [reorder])
        let probe = Probe()
        let request = GatewayRequest(token: tok, capability: reorder, claimedCaller: .interactiveUI, idempotencyKey: nil, fingerprint: "")
        let outcome = await gateway.handle(request) { await probe.enter(); return 1 }
        guard case .rejected(.missingIdempotencyKey) = outcome else { return XCTFail("expected rejection") }
        let runs = await probe.runs
        XCTAssertEqual(runs, 0)
    }

    func testAnotherPrincipalPresentingTheSameKeyGetsNoReplay() async throws {
        let (gateway, _) = makeGateway()
        let alice = try await gateway.issue(skillID: "reorder", caller: .siriAgent, capabilities: [reorder], validForMillis: 60_000, principal: "alice").get()
        let mallory = try await gateway.issue(skillID: "reorder", caller: .siriAgent, capabilities: [reorder], validForMillis: 60_000, principal: "mallory").get()
        let key = IdempotencyKey.mint()
        _ = await gateway.handle(GatewayRequest(token: alice, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: "usual")) { 111 }
        let stolen = await gateway.handle(GatewayRequest(token: mallory, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: "usual")) { 222 }
        guard case .success(222, replayed: false) = stolen else { return XCTFail("must not see alice's result, got \(stolen)") }
    }

    func testTokensWithoutAPrincipalAreIsolatedFromEachOther() async throws {
        let (gateway, _) = makeGateway()
        let a = try await token(gateway, caller: .siriAgent, caps: [reorder])
        let b = try await token(gateway, caller: .siriAgent, caps: [reorder])
        let key = IdempotencyKey.mint()
        _ = await gateway.handle(GatewayRequest(token: a, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: "p")) { 1 }
        let other = await gateway.handle(GatewayRequest(token: b, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: "p")) { 2 }
        guard case .success(2, replayed: false) = other else { return XCTFail("got \(other)") }
    }

    func testSamePrincipalReplaysAcrossARefreshedToken() async throws {
        let (gateway, _) = makeGateway()
        let old = try await gateway.issue(skillID: "reorder", caller: .siriAgent, capabilities: [reorder], validForMillis: 60_000, principal: "alice").get()
        let key = IdempotencyKey.mint()
        _ = await gateway.handle(GatewayRequest(token: old, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: "usual")) { 111 }
        await gateway.revoke(old)
        let fresh = try await gateway.issue(skillID: "reorder", caller: .siriAgent, capabilities: [reorder], validForMillis: 60_000, principal: "alice").get()
        let retry = await gateway.handle(GatewayRequest(token: fresh, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: "usual")) { 222 }
        guard case .success(111, replayed: true) = retry else { return XCTFail("got \(retry)") }
    }

    func testSameKeyOnADifferentCapabilityIsADifferentRecord() async throws {
        let (gateway, _) = makeGateway()
        let cancel = Capability("orders.cancel", .write)
        let tok = try await token(gateway, caller: .siriAgent, caps: [reorder, cancel])
        let key = IdempotencyKey.mint()
        _ = await gateway.handle(GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: "x")) { 1 }
        let other = await gateway.handle(GatewayRequest(token: tok, capability: cancel, claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: "x")) { 2 }
        guard case .success(2, replayed: false) = other else { return XCTFail("got \(other)") }
    }

    func testWaitersPerKeyAreCappedAndTheOverflowGetsInProgress() async throws {
        var config = Gateway<Int>.Configuration()
        config.maxWaitersPerKey = 2
        let (gateway, _) = makeGateway(config)
        let tok = try await token(gateway, caller: .siriAgent, caps: [reorder])
        let probe = Probe()
        let gate = Gate()
        let request = GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: .mint(), fingerprint: "p")
        let outcomes = await withTaskGroup(of: GatewayOutcome<Int>.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await gateway.handle(request) {
                        await probe.enter()
                        await gate.wait()   // held open until every request has been answered or parked
                        await probe.leave()
                        return 5
                    }
                }
            }
            // No timing assumption: release the handler only once 2 duplicates are parked and the
            // other 7 have been turned away, however slowly the runner schedules the children.
            var polls = 0
            while polls < 5_000 {
                let parked = await gateway.waiterCount
                let turnedAway = await gateway.countersByClass()[TrafficClass(.siriAgent, .write)]?.inProgress ?? 0
                if parked == 2 && turnedAway == 7 { break }
                polls += 1
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            await gate.open()
            var all: [GatewayOutcome<Int>] = []
            for await o in group { all.append(o) }
            return all
        }
        let runs = await probe.runs
        XCTAssertEqual(runs, 1)
        let inProgress = outcomes.filter { if case .inProgress = $0 { return true }; return false }.count
        let succeeded = outcomes.filter { if case .success(5, _) = $0 { return true }; return false }.count
        XCTAssertEqual(succeeded, 3, "the leader plus two capped waiters")
        XCTAssertEqual(inProgress, 7)
        let waiting = await gateway.waiterCount
        XCTAssertEqual(waiting, 0)
    }

    func testWaitersGiveUpAfterMaxWaitWhileTheWriteFinishesAndARetryReplaysIt() async throws {
        var config = Gateway<Int>.Configuration()
        config.maxWaitMillis = 50
        let (gateway, _) = makeGateway(config)
        let tok = try await token(gateway, caller: .siriAgent, caps: [reorder])
        let request = GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: .mint(), fingerprint: "p")
        async let leader = gateway.handle(request) {
            try await Task.sleep(nanoseconds: 600_000_000)
            return 8
        }
        var polls = 0
        while await gateway.executingCount == 0, polls < 500 {
            polls += 1
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let waiter = await gateway.handle(request) { 9 }
        guard case .inProgress = waiter else { return XCTFail("expected inProgress, got \(waiter)") }
        // The starting request's wait is bounded the same way; the write itself keeps running.
        let leaderResult = await leader
        guard case .inProgress = leaderResult else { return XCTFail("leader got \(leaderResult)") }
        polls = 0
        while await gateway.executingCount > 0, polls < 1_000 {
            polls += 1
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let after = await gateway.handle(request) { 9 }
        guard case .success(8, replayed: true) = after else { return XCTFail("retry should replay, got \(after)") }
    }

    func testACancelledWaiterStopsWaitingAndIsRemoved() async throws {
        let (gateway, _) = makeGateway()
        let tok = try await token(gateway, caller: .siriAgent, caps: [reorder])
        let request = GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: .mint(), fingerprint: "p")
        async let leader = gateway.handle(request) {
            try await Task.sleep(nanoseconds: 800_000_000)
            return 8
        }
        var polls = 0
        while await gateway.executingCount == 0, polls < 500 {
            polls += 1
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let waiterTask = Task { await gateway.handle(request) { 9 } }
        polls = 0
        while await gateway.waiterCount == 0, polls < 500 {
            polls += 1
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        waiterTask.cancel()
        let waiter = await waiterTask.value
        guard case .inProgress = waiter else { return XCTFail("expected inProgress, got \(waiter)") }
        let waiting = await gateway.waiterCount
        XCTAssertEqual(waiting, 0)
        _ = await leader
    }

    func testValidatingInitRejectsAnInvertedShedOrder() {
        var config = Gateway<Int>.Configuration()
        config.policy.shedDepth[.interactive] = 1
        XCTAssertThrowsError(try Gateway<Int>(validating: config, clock: ManualClock())) { error in
            XCTAssertFalse((error as? GatewayConfigurationError)?.issues.isEmpty ?? true)
        }
        XCTAssertNoThrow(try Gateway<Int>(validating: Gateway<Int>.Configuration(), clock: ManualClock()))
    }

    func testAFullLedgerShedsWithoutSpendingABucketToken() async throws {
        var config = Gateway<Int>.Configuration()
        config.ledgerCapacity = 1
        config.ledgerTTLMillis = 1_000
        config.policy.buckets = [TrafficClass(.siriAgent, .write): BucketSpec(capacity: 2, refillPerSecond: 0)]
        let (gateway, clock) = makeGateway(config)
        let tok = try await token(gateway, caller: .siriAgent, caps: [reorder])
        func write(_ fp: String) -> GatewayRequest {
            GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: .mint(), fingerprint: fp)
        }
        guard case .success = await gateway.handle(write("a"), operation: { 1 }) else { return XCTFail("first write") }
        // Ledger holds a's live record: b is shed by the ledger, told to come back when a expires...
        let b = await gateway.handle(write("b"), operation: { 2 })
        guard case .shed(.overloaded, retryAfterMillis: 1_000) = b else { return XCTFail("b should be shed until a expires, got \(b)") }
        let counters = await gateway.countersByClass()[TrafficClass(.siriAgent, .write)]
        XCTAssertEqual(counters?.ledgerFull, 1)
        clock.advance(byMillis: 1_000)
        // ...and must not have spent the bucket's second (last) token.
        let c = await gateway.handle(write("c"), operation: { 3 })
        guard case .success(3, replayed: false) = c else { return XCTFail("c should run with the unspent token, got \(c)") }
    }

    /// Without the abandon on a policy shed, the shed write's claim would pin its key forever.
    func testPolicyShedOfAKeyedWriteReleasesTheClaim() async throws {
        var config = Gateway<Int>.Configuration()
        config.policy.buckets = [TrafficClass(.siriAgent, .write): BucketSpec(capacity: 1, refillPerSecond: 1)]
        let (gateway, clock) = makeGateway(config)
        let tok = try await token(gateway, caller: .siriAgent, caps: [reorder])
        let probe = Probe()
        let first = GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: .mint(), fingerprint: "a")
        let second = GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: .mint(), fingerprint: "b")
        _ = await gateway.handle(first) { 1 }
        guard case .shed(.rateLimited, _) = await gateway.handle(second, operation: { await probe.enter(); return 2 }) else {
            return XCTFail("second should be rate limited")
        }
        let ledgerCount = await gateway.ledgerCount
        XCTAssertEqual(ledgerCount, 1, "the shed write must leave no record behind")
        clock.advance(byMillis: 1_000)
        let retry = await gateway.handle(second) { await probe.enter(); return 2 }
        guard case .success(2, replayed: false) = retry else { return XCTFail("retry should run fresh, got \(retry)") }
        let runs = await probe.runs
        XCTAssertEqual(runs, 1)
    }

    func testOversizedFingerprintsCostAFixedSizeRecordAndStillDetectConflicts() async throws {
        let (gateway, _) = makeGateway()
        let tok = try await token(gateway, caller: .siriAgent, caps: [reorder])
        let key = IdempotencyKey.mint()
        let huge = String(repeating: "p", count: 200_000)
        _ = await gateway.handle(GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: huge)) { 1 }
        let same = await gateway.handle(GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: huge)) { 2 }
        guard case .success(1, replayed: true) = same else { return XCTFail("got \(same)") }
        let other = await gateway.handle(GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: huge + "!")) { 3 }
        guard case .rejected(.idempotencyConflict) = other else { return XCTFail("got \(other)") }
    }

    /// The leader's client giving up must not cancel work that duplicates are sharing.
    func testCancellingTheLeaderNeitherCancelsTheSharedWriteNorFailsItsJoiners() async throws {
        let (gateway, _) = makeGateway()
        let tok = try await token(gateway, caller: .siriAgent, caps: [reorder])
        let probe = Probe()
        let request = GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: .mint(), fingerprint: "p")
        let leader = Task {
            await gateway.handle(request) {
                await probe.enter()
                try await Task.sleep(nanoseconds: 400_000_000)   // throws if this task is cancelled
                await probe.leave()
                return 42
            }
        }
        var polls = 0
        while await gateway.executingCount == 0, polls < 500 {
            polls += 1
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        async let joiner = gateway.handle(request) { 0 }
        try await Task.sleep(nanoseconds: 50_000_000)
        leader.cancel()
        let leaderOutcome = await leader.value
        guard case .inProgress = leaderOutcome else { return XCTFail("cancelled leader should get inProgress, got \(leaderOutcome)") }
        let joined = await joiner
        guard case .success(42, replayed: true) = joined else { return XCTFail("joiner should get the shared result, got \(joined)") }
        let retry = await gateway.handle(request) { 0 }
        guard case .success(42, replayed: true) = retry else { return XCTFail("retry should replay, got \(retry)") }
        let runs = await probe.runs
        let running = await probe.running
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(running, 0, "the handler ran to completion instead of being cancelled")
    }

    func testTheStartingRequestsWaitIsBoundedButTheWriteStillCompletes() async throws {
        var config = Gateway<Int>.Configuration()
        config.maxWaitMillis = 50
        let (gateway, _) = makeGateway(config)
        let tok = try await token(gateway, caller: .siriAgent, caps: [reorder])
        let request = GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: .mint(), fingerprint: "p")
        let first = await gateway.handle(request) {
            try await Task.sleep(nanoseconds: 300_000_000)
            return 7
        }
        guard case .inProgress = first else { return XCTFail("starting request should stop waiting, got \(first)") }
        var polls = 0
        while await gateway.executingCount > 0, polls < 1_000 {
            polls += 1
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let retry = await gateway.handle(request) { 0 }
        guard case .success(7, replayed: true) = retry else { return XCTFail("retry should replay the finished write, got \(retry)") }
    }

    func testAFailureNobodyWaitedForIsStillCountedPerExecution() async throws {
        var config = Gateway<Int>.Configuration()
        config.maxWaitMillis = 20
        let (gateway, _) = makeGateway(config)
        let tok = try await token(gateway, caller: .siriAgent, caps: [reorder])
        let request = GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: .mint(), fingerprint: "p")
        let outcome = await gateway.handle(request) {
            try await Task.sleep(nanoseconds: 200_000_000)
            throw Boom()
        }
        guard case .inProgress = outcome else { return XCTFail("got \(outcome)") }
        var polls = 0
        while await gateway.executingCount > 0, polls < 1_000 {
            polls += 1
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let counters = await gateway.countersByClass()[TrafficClass(.siriAgent, .write)]
        XCTAssertEqual(counters?.executionsFailed, 1)
        XCTAssertEqual(counters?.failed, 0, "nobody was waiting to be told")
        XCTAssertEqual(counters?.inProgress, 1)
    }

    func testAnUnkeyedHandlerFailureIsCountedOnceAndReleasesItsSlot() async throws {
        let (gateway, _) = makeGateway()
        let tok = try await token(gateway, caller: .siriAgent, caps: [browse])
        let request = GatewayRequest(token: tok, capability: browse, claimedCaller: .siriAgent, idempotencyKey: nil, fingerprint: "")
        let outcome = await gateway.handle(request) { throw Boom() }
        guard case .failed = outcome else { return XCTFail("got \(outcome)") }
        let counters = await gateway.countersByClass()[TrafficClass(.siriAgent, .read)]
        XCTAssertEqual(counters?.executionsFailed, 1)
        XCTAssertEqual(counters?.failed, 1)
        let executing = await gateway.executingCount
        XCTAssertEqual(executing, 0)
    }

    func testValidationRejectsAZeroMaxWait() {
        var config = Gateway<Int>.Configuration()
        config.maxWaitMillis = 0
        XCTAssertTrue(config.validationIssues().contains { $0.contains("maxWaitMillis") })
    }

    func testRelativeIssueExpiresOnTheGatewaysOwnClock() async throws {
        let clock = ManualClock(startingAt: 1_000_000)
        let gateway = Gateway<Int>(clock: clock)
        let tok = try await gateway.issue(skillID: "s", caller: .widget, capabilities: [browse], validForMillis: 500).get()
        let request = GatewayRequest(token: tok, capability: browse, claimedCaller: .widget, idempotencyKey: nil, fingerprint: "")
        guard case .success = await gateway.handle(request, operation: { 1 }) else { return XCTFail("should be valid now") }
        clock.advance(byMillis: 500)
        guard case .denied(.expired) = await gateway.handle(request, operation: { 1 }) else { return XCTFail("should expire at +500 ms") }
    }

    func testAnAgentTokenCannotClaimInteractivePriority() async throws {
        let (gateway, _) = makeGateway()
        let tok = try await token(gateway, caller: .siriAgent, caps: [browse])
        let request = GatewayRequest(token: tok, capability: browse, claimedCaller: .interactiveUI, idempotencyKey: nil, fingerprint: "")
        let outcome = await gateway.handle(request) { 1 }
        guard case .denied(.callerClassMismatch(claimed: .interactiveUI, granted: .siriAgent)) = outcome else {
            return XCTFail("expected mismatch, got \(outcome)")
        }
    }

    func testCapabilityOutsideTheSkillIsDeniedAndRevocationTakesEffect() async throws {
        let (gateway, _) = makeGateway()
        let tok = try await token(gateway, caller: .siriAgent, caps: [browse])
        let write = GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: .mint(), fingerprint: "")
        guard case .denied(.capabilityNotGranted) = await gateway.handle(write, operation: { 1 }) else { return XCTFail("expected denial") }
        await gateway.revoke(tok)
        let read = GatewayRequest(token: tok, capability: browse, claimedCaller: .siriAgent, idempotencyKey: nil, fingerprint: "")
        guard case .denied(.unknownToken) = await gateway.handle(read, operation: { 1 }) else { return XCTFail("expected revoked") }
    }

    func testReusedKeyWithADifferentPayloadIsAConflict() async throws {
        let (gateway, _) = makeGateway()
        let tok = try await token(gateway, caller: .siriAgent, caps: [reorder])
        let key = IdempotencyKey.mint()
        _ = await gateway.handle(GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: "latte")) { 1 }
        let other = await gateway.handle(GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: "espresso")) { 2 }
        guard case .rejected(.idempotencyConflict) = other else { return XCTFail("expected conflict, got \(other)") }
    }

    func testFailedHandlerIsNotCachedJoinersSeeTheFailureAndARetryRunsAgain() async throws {
        let (gateway, _) = makeGateway()
        let tok = try await token(gateway, caller: .siriAgent, caps: [reorder])
        let probe = Probe()
        let request = GatewayRequest(token: tok, capability: reorder, claimedCaller: .siriAgent, idempotencyKey: .mint(), fingerprint: "p")
        let outcomes = await withTaskGroup(of: GatewayOutcome<Int>.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await gateway.handle(request) {
                        await probe.enter()
                        try await Task.sleep(nanoseconds: 300_000_000)
                        await probe.leave()
                        throw Boom()
                    }
                }
            }
            var all: [GatewayOutcome<Int>] = []
            for await o in group { all.append(o) }
            return all
        }
        let firstRuns = await probe.runs
        XCTAssertEqual(firstRuns, 1)
        XCTAssertEqual(outcomes.filter { if case .failed = $0 { return true }; return false }.count, 10)
        let retry = await gateway.handle(request) { await probe.enter(); await probe.leave(); return 9 }
        guard case .success(9, replayed: false) = retry else { return XCTFail("expected a fresh run, got \(retry)") }
        let totalRuns = await probe.runs
        XCTAssertEqual(totalRuns, 2)
        let executing = await gateway.executingCount
        XCTAssertEqual(executing, 0)
        let counters = await gateway.countersByClass()[TrafficClass(.siriAgent, .write)]
        XCTAssertEqual(counters?.executed, 2)
        XCTAssertEqual(counters?.failed, 10, "the leader and its 9 joiners all failed")
        XCTAssertEqual(counters?.replayed, 0, "a joined failure is not a replay")
    }

    func testFullLedgerShedsInsteadOfRunningUnprotected() async throws {
        var config = Gateway<Int>.Configuration()
        config.ledgerCapacity = 1
        let (gateway, _) = makeGateway(config)
        let tok = try await token(gateway, caller: .interactiveUI, caps: [reorder])
        let probe = Probe()
        let slow = GatewayRequest(token: tok, capability: reorder, claimedCaller: .interactiveUI, idempotencyKey: .mint(), fingerprint: "a")
        let other = GatewayRequest(token: tok, capability: reorder, claimedCaller: .interactiveUI, idempotencyKey: .mint(), fingerprint: "b")
        async let first = gateway.handle(slow) {
            await probe.enter()
            try await Task.sleep(nanoseconds: 200_000_000)
            await probe.leave()
            return 1
        }
        // Wait until the first request is actually executing, without relying on a fixed sleep alone.
        var polls = 0
        while await gateway.executingCount == 0, polls < 500 {
            polls += 1
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let second = await gateway.handle(other) { await probe.enter(); return 2 }
        guard case .shed(.overloaded, _) = second else { return XCTFail("expected shed, got \(second)") }
        _ = await first
        let runs = await probe.runs
        XCTAssertEqual(runs, 1)
    }
}

final class FallbackPresenterTests: XCTestCase {
    func testShedWriteSaysThisRequestDidNotGoThroughAndRoundsTheWaitUp() {
        let f = FallbackPresenter.fallback(for: GatewayOutcome<Int>.shed(.overloaded, retryAfterMillis: 4_001), kind: .write, action: "place your order")
        XCTAssertEqual(f?.retryAfterSeconds, 5)
        XCTAssertEqual(f?.mayHaveExecuted, false)
        XCTAssertTrue(f?.spoken.contains("this request didn't go through") ?? false)
        XCTAssertTrue(f?.spoken.contains("about 5 seconds") ?? false)
    }

    func testOneSecondIsSingularAndNoHintSaysAMoment() {
        let one = FallbackPresenter.fallback(for: GatewayOutcome<Int>.shed(.rateLimited, retryAfterMillis: 1), kind: .read, action: "check your orders")
        XCTAssertTrue(one?.spoken.contains("about 1 second,") ?? false)
        let none = FallbackPresenter.fallback(for: GatewayOutcome<Int>.shed(.overloaded, retryAfterMillis: 0), kind: .read, action: "check your orders")
        XCTAssertNil(none?.retryAfterSeconds)
        XCTAssertTrue(none?.spoken.contains("in a moment") ?? false)
    }

    func testHandlerFailureNeverClaimsNothingHappened() {
        let f = FallbackPresenter.fallback(for: GatewayOutcome<Int>.failed(HandlerFailure(message: "x")), kind: .write, action: "place your order")
        XCTAssertNil(f?.mayHaveExecuted)
        XCTAssertFalse(f?.spoken.contains("didn't go through") ?? true)
    }

    func testDenialDoesNotAssumeTheCallerIsAShortcut() {
        let f = FallbackPresenter.fallback(for: GatewayOutcome<Int>.denied(.capabilityNotGranted(Capability("orders", .write))), kind: .write, action: "place your order")
        XCTAssertEqual(f?.spoken, "I'm not allowed to place your order from here. Open the app to do it there.")
        XCTAssertEqual(f?.mayHaveExecuted, false)
    }

    func testExpiredOrRevokedGrantAsksForARefreshNotAPermissionChange() {
        for outcome in [GatewayOutcome<Int>.denied(.expired), .denied(.unknownToken)] {
            let f = FallbackPresenter.fallback(for: outcome, kind: .write, action: "place your order")
            XCTAssertEqual(f?.spoken, "My permission to place your order is no longer valid. Open the app to refresh it.")
        }
    }

    func testInProgressSaysItWontRestartWhileRunningAndDoesNotClaimNothingHappened() {
        let f = FallbackPresenter.fallback(for: GatewayOutcome<Int>.inProgress(retryAfterMillis: 250), kind: .write, action: "place your order")
        XCTAssertTrue(f?.spoken.contains("won't start it again while it's running") ?? false)
        // A failed execution is abandoned and a retry runs again, so promise nothing about the outcome.
        XCTAssertFalse(f?.spoken.contains("how it went") ?? true)
        XCTAssertEqual(f?.mayHaveExecuted, true)
        XCTAssertEqual(f?.retryAfterSeconds, 1)
        XCTAssertFalse(f?.spoken.contains("didn't go through") ?? true)
    }

    func testFailedReadGetsReadAdviceNotCheckBeforeRetrying() {
        let f = FallbackPresenter.fallback(for: GatewayOutcome<Int>.failed(HandlerFailure(message: "x")), kind: .read, action: "check the menu")
        XCTAssertEqual(f?.spoken, "I couldn't check the menu right now. Try again, or open the app.")
    }

    func testSuccessHasNoFallback() {
        XCTAssertNil(FallbackPresenter.fallback(for: GatewayOutcome<Int>.success(1, replayed: false), kind: .write, action: "x"))
    }

    func testHugeRetryAfterDoesNotTrap() {
        let f = FallbackPresenter.fallback(for: GatewayOutcome<Int>.shed(.overloaded, retryAfterMillis: .max), kind: .write, action: "x")
        XCTAssertNotNil(f?.retryAfterSeconds)
    }
}
