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
        let (gateway, _) = makeGateway()
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
    func testShedWriteSaysNothingChangedAndRoundsTheWaitUp() {
        let f = FallbackPresenter.fallback(for: GatewayOutcome<Int>.shed(.overloaded, retryAfterMillis: 4_001), kind: .write, action: "place your order")
        XCTAssertEqual(f?.retryAfterSeconds, 5)
        XCTAssertEqual(f?.mayHaveExecuted, false)
        XCTAssertTrue(f?.spoken.contains("Nothing was changed") ?? false)
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
        XCTAssertFalse(f?.spoken.contains("Nothing was changed") ?? true)
    }

    func testSuccessHasNoFallback() {
        XCTAssertNil(FallbackPresenter.fallback(for: GatewayOutcome<Int>.success(1, replayed: false), kind: .write, action: "x"))
    }

    func testHugeRetryAfterDoesNotTrap() {
        let f = FallbackPresenter.fallback(for: GatewayOutcome<Int>.shed(.overloaded, retryAfterMillis: .max), kind: .write, action: "x")
        XCTAssertNotNil(f?.retryAfterSeconds)
    }
}
