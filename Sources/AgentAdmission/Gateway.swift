/// One request as the backend sees it.
public struct GatewayRequest: Sendable {
    public let token: ScopeToken
    public let capability: Capability
    /// The entry point the app says this came from. Must match the token's grant.
    public let claimedCaller: CallerClass
    /// Required for writes. Reused on every retry of the same intent (see ``IntentKeyCache``).
    public let idempotencyKey: IdempotencyKey?
    /// Identifies the payload: the same key with a different fingerprint is a conflict. Any
    /// length is accepted; the gateway uses only a fixed-size ``FingerprintDigest`` of it.
    public let fingerprint: String
    /// Computed here, on the caller's task, so hashing a long fingerprint never runs on (and
    /// stalls) the gateway actor.
    let fingerprintDigest: String

    public init(token: ScopeToken, capability: Capability, claimedCaller: CallerClass, idempotencyKey: IdempotencyKey?, fingerprint: String) {
        self.token = token
        self.capability = capability
        self.claimedCaller = claimedCaller
        self.idempotencyKey = idempotencyKey
        self.fingerprint = fingerprint
        self.fingerprintDigest = FingerprintDigest.digest(fingerprint)
    }
}

public enum RequestRejection: Error, Sendable, Equatable {
    case missingIdempotencyKey
    /// The key is in use for a request with a different payload.
    case idempotencyConflict
}

/// The handler threw. Its message is passed through for logging only.
public struct HandlerFailure: Error, Sendable, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
}

public enum GatewayOutcome<Value: Sendable>: Sendable {
    /// `replayed == true` when the value came from an earlier execution of the same key
    /// (a completed replay, or a duplicate that joined the in-flight execution).
    case success(Value, replayed: Bool)
    /// Turned away before the handler ran: this attempt executed nothing.
    case shed(ShedReason, retryAfterMillis: Int64)
    case denied(AuthorizationFailure)
    case rejected(RequestRejection)
    /// An execution for this key is still running (started by this request or an earlier one)
    /// and this request stopped waiting for it: too many waiters, the wait timed out, or this
    /// task was cancelled. The write may still complete; retrying with the **same key** returns
    /// its result without running it twice.
    case inProgress(retryAfterMillis: Int64)
    /// The handler ran and threw. It may or may not have had side effects (see README limits).
    case failed(HandlerFailure)
}

/// Per-traffic-class counters, so dashboards can separate agent load from human load.
public struct ClassCounters: Sendable, Equatable {
    public var admitted = 0
    public var shed = 0
    public var denied = 0
    public var rejected = 0
    /// Served from a completed entry, or joined an in-flight execution that succeeded.
    public var replayed = 0
    /// Requests that stopped waiting for an in-flight execution and got
    /// ``GatewayOutcome/inProgress(retryAfterMillis:)``: duplicates, and the request that
    /// started the execution if it gave up first.
    public var inProgress = 0
    /// Of `shed`, how many were because the idempotency ledger was full of live records.
    public var ledgerFull = 0
    /// Times the handler actually ran.
    public var executed = 0
    /// Requests answered `.failed`: the one that started the execution (if still waiting) and
    /// each joiner. See `executionsFailed` for a per-execution count.
    public var failed = 0
    /// Handler runs that threw, counted once per execution even if nobody was still waiting.
    public var executionsFailed = 0
    public init() {}
}

/// Why ``Gateway/init(validating:authority:clock:)`` refused a configuration.
public struct GatewayConfigurationError: Error, Sendable, Equatable {
    public let issues: [String]
}

/// Where a write's idempotency record lives. Scoping by principal, skill and capability means
/// one caller can never read another caller's stored result by presenting their key.
struct LedgerKey: Hashable, Sendable {
    /// Separate cases, so a principal id can never collide with a token-derived scope.
    enum Scope: Hashable, Sendable {
        case principal(String)
        case token(ScopeToken)
    }
    let scope: Scope
    let skillID: String
    let capability: Capability
    let key: IdempotencyKey
}

/// The live, concurrent composition of scope check → idempotency → admission → handler.
///
/// Everything between reading the ledger and marking a key in flight happens without an `await`,
/// so two concurrent requests with the same key cannot both decide to execute (actor
/// reentrancy only happens at suspension points, and there are none in that window). The only
/// suspensions are the handler call (inline for unkeyed requests) and waiting for a keyed
/// execution's result (the leader and duplicates alike); none sits between lookup and claim, and
/// state is re-read after each, never assumed. A keyed execution runs in its own task, so one
/// caller's cancellation never cancels work other callers are sharing.
///
/// This is a single-process reference implementation: it is meant to run in a server-side
/// Swift process (or to be ported to one), and the demo app runs it in-process to make the
/// behaviour visible. The pure parts (``ClassAwarePolicy``, ``IdempotencyLedger``,
/// ``ScopeAuthority``) are written so a fleet port changes storage, not logic.
public actor Gateway<Value: Sendable> {
    public struct Configuration: Sendable {
        public var policy: ClassAwarePolicy.Configuration
        /// Used for the Retry-After estimate; the live gateway has no wait queue, so the depth it
        /// reports to the policy is the number of handlers currently executing.
        public var workers: Int
        public var meanServiceMillis: Int64
        /// Size for peak sustained writes × TTL: a full ledger sheds new writes rather than evict
        /// live records. The defaults (100,000 × 10 min) cover about 166 writes/s sustained.
        public var ledgerCapacity: Int
        /// Must exceed the clients' retry horizon (``RetryPolicy/horizonMillis(perAttemptTimeoutMillis:maxRetryAfterMillis:)``).
        public var ledgerTTLMillis: Int64
        /// Most duplicates allowed to wait on one in-flight key; more get `.inProgress`.
        public var maxWaitersPerKey: Int
        /// Longest a duplicate waits for the in-flight execution before returning `.inProgress`.
        public var maxWaitMillis: Int64

        public init(
            policy: ClassAwarePolicy.Configuration = .standard,
            workers: Int = 8,
            meanServiceMillis: Int64 = 50,
            ledgerCapacity: Int = 100_000,
            ledgerTTLMillis: Int64 = 10 * 60 * 1_000,
            maxWaitersPerKey: Int = 32,
            maxWaitMillis: Int64 = 10_000
        ) {
            self.policy = policy
            self.workers = workers
            self.meanServiceMillis = meanServiceMillis
            self.ledgerCapacity = ledgerCapacity
            self.ledgerTTLMillis = ledgerTTLMillis
            self.maxWaitersPerKey = maxWaitersPerKey
            self.maxWaitMillis = maxWaitMillis
        }

        /// Policy issues plus gateway-level ones. Empty means valid.
        public func validationIssues() -> [String] {
            var issues = policy.validationIssues()
            if workers < 1 { issues.append("workers must be at least 1") }
            if ledgerCapacity < 1 { issues.append("ledgerCapacity must be at least 1") }
            if ledgerTTLMillis < 1 { issues.append("ledgerTTLMillis must be at least 1") }
            if maxWaitersPerKey < 0 { issues.append("maxWaitersPerKey must not be negative") }
            if maxWaitMillis < 0 { issues.append("maxWaitMillis must not be negative") }
            return issues
        }
    }

    private struct Waiter {
        let id: UInt64
        /// The request that started the execution waits on it like a duplicate does, so its
        /// own cancellation can't cancel the shared work. Leaders don't count toward the cap.
        let isLeader: Bool
        let continuation: CheckedContinuation<Result<Value, HandlerFailure>?, Never>
    }

    public let configuration: Configuration
    private let clock: any AdmissionClock
    private var authority: ScopeAuthority
    private var policy: ClassAwarePolicy
    private var ledger: IdempotencyLedger<LedgerKey, Value>
    private var waiters: [LedgerKey: [Waiter]] = [:]
    private var nextWaiterID: UInt64 = 0
    private var executing = 0
    private var counters: [TrafficClass: ClassCounters] = [:]

    /// Accepts any configuration (values are clamped where they're used). Prefer
    /// ``init(validating:authority:clock:)`` so an inverted shed order fails at startup.
    public init(configuration: Configuration = Configuration(), authority: ScopeAuthority = ScopeAuthority(), clock: any AdmissionClock) {
        self.configuration = configuration
        self.clock = clock
        self.authority = authority
        self.policy = ClassAwarePolicy(configuration: configuration.policy, now: clock.nowMillis())
        self.ledger = IdempotencyLedger(capacity: configuration.ledgerCapacity, ttlMillis: configuration.ledgerTTLMillis)
    }

    /// Refuses a configuration that ``Configuration/validationIssues()`` reports problems with.
    public init(validating configuration: Configuration, authority: ScopeAuthority = ScopeAuthority(), clock: any AdmissionClock) throws {
        let issues = configuration.validationIssues()
        guard issues.isEmpty else { throw GatewayConfigurationError(issues: issues) }
        self.init(configuration: configuration, authority: authority, clock: clock)
    }

    // MARK: Grants

    /// Issues a grant whose `expiresAtMillis` is already in this gateway's clock domain.
    public func issue(_ grant: SkillGrant) -> Result<ScopeToken, GrantIssueFailure> {
        authority.issue(grant, now: clock.nowMillis())
    }

    /// Issues a grant valid for `validForMillis` from now on this gateway's clock, so callers
    /// never have to know where the clock's zero is.
    /// - Parameter principal: whose grant this is (a user or device id). Idempotency records are
    ///   scoped to it. `nil` scopes them to the token itself, which is safe but means a
    ///   refreshed token can't replay results recorded under the old one.
    public func issue(
        skillID: String,
        caller: CallerClass,
        capabilities: Set<Capability>,
        validForMillis: Int64,
        principal: String? = nil
    ) -> Result<ScopeToken, GrantIssueFailure> {
        let now = clock.nowMillis()
        let grant = SkillGrant(
            skillID: skillID, caller: caller, capabilities: capabilities,
            expiresAtMillis: Saturating.add(now, max(0, validForMillis)), principal: principal
        )
        return authority.issue(grant, now: now)
    }

    public func revoke(_ token: ScopeToken) {
        authority.revoke(token)
    }

    // MARK: Requests

    public func handle(
        _ request: GatewayRequest,
        operation: @escaping @Sendable () async throws -> Value
    ) async -> GatewayOutcome<Value> {
        let now = clock.nowMillis()

        // 1. Who is this, really? The grant decides the class, never the claim alone.
        let grant: SkillGrant
        switch authority.authorize(request.token, capability: request.capability, claimedCaller: request.claimedCaller, now: now) {
        case let .success(g): grant = g
        case let .failure(reason):
            // The claim is unverified, so attribute the denial to the claimed class.
            bump(TrafficClass(request.claimedCaller, request.capability.kind)) { $0.denied += 1 }
            return .denied(reason)
        }
        let traffic = TrafficClass(grant.caller, request.capability.kind)

        // 2. Writes must be idempotent.
        if traffic.kind == .write && request.idempotencyKey == nil {
            bump(traffic) { $0.rejected += 1 }
            return .rejected(.missingIdempotencyKey)
        }

        let ledgerKey = request.idempotencyKey.map {
            LedgerKey(
                scope: grant.principal.map(LedgerKey.Scope.principal) ?? .token(request.token),
                skillID: grant.skillID, capability: request.capability, key: $0
            )
        }

        // Fixed-size, whatever the caller sent, and already computed off the actor.
        let fingerprint = request.fingerprintDigest

        // 3. Duplicates are served without admission: they cost a lookup, not a handler run.
        if let ledgerKey {
            switch ledger.lookup(ledgerKey, fingerprint: fingerprint, now: now) {
            case let .replay(value):
                bump(traffic) { $0.replayed += 1 }
                return .success(value, replayed: true)
            case .conflict:
                bump(traffic) { $0.rejected += 1 }
                return .rejected(.idempotencyConflict)
            case .inFlight:
                return await join(ledgerKey, traffic: traffic)
            case .absent:
                break
            }
        }

        // 4. Claim the key first, so a full ledger sheds before the policy spends a token.
        //    No `await` since step 3, so nobody else can have claimed it.
        if let ledgerKey {
            switch ledger.begin(ledgerKey, fingerprint: fingerprint, now: now) {
            case .started:
                break
            case .full:
                // Not executed, so telling the client to come back is safe. A full ledger only
                // frees up when a record expires, so the hint is that time, not a fixed 250 ms.
                bump(traffic) { $0.shed += 1; $0.ledgerFull += 1 }
                let wait = ledger.millisUntilReclaim(now: now) ?? configuration.policy.maxRetryAfterMillis
                return .shed(.overloaded, retryAfterMillis: clampedRetry(wait))
            case .alreadyPresent:
                bump(traffic) { $0.shed += 1 }
                return .shed(.overloaded, retryAfterMillis: retryHint)
            }
        }

        // 5. Admission. Shedding here is strictly before execution; release the claim if shed.
        let load = LoadSignal(queueDepth: executing, workers: configuration.workers, meanServiceMillis: configuration.meanServiceMillis)
        if case let .shed(reason, retryAfter) = policy.decide(traffic, load: load, now: now) {
            if let ledgerKey { ledger.abandon(ledgerKey) }
            bump(traffic) { $0.shed += 1 }
            return .shed(reason, retryAfterMillis: retryAfter)
        }

        bump(traffic) { $0.admitted += 1; $0.executed += 1 }
        executing += 1

        guard let ledgerKey else {
            // No key, no duplicates to share with: run inline, and let cancellation reach it.
            let result = await Self.run(operation)
            executing = max(0, executing - 1)
            if case .failure = result { bump(traffic) { $0.executionsFailed += 1 } }
            return outcome(of: result, traffic: traffic)
        }

        // 6. A keyed execution is shared with every duplicate that joins it, so it runs in its
        //    own task: the leader's client cancelling (Siri giving up, a dropped connection) must
        //    not cut the write off halfway or fail healthy joiners. The leader then waits for it
        //    exactly like a joiner. Its waiter is registered below before this actor can run the
        //    task's completion, so the result can't be missed.
        let id = nextWaiterID
        nextWaiterID &+= 1
        Task { [self] in
            let result = await Self.run(operation)
            self.finish(ledgerKey, traffic: traffic, result: result)
        }
        // Bounded like a joiner's wait: the execution has its own task, so giving up here is safe.
        let result = await waitForResult(ledgerKey, id: id, isLeader: true, timeoutMillis: configuration.maxWaitMillis)
        guard let result else {
            bump(traffic) { $0.inProgress += 1 }
            return .inProgress(retryAfterMillis: retryHint)
        }
        return outcome(of: result, traffic: traffic)
    }

    private static func run(_ operation: @Sendable () async throws -> Value) async -> Result<Value, HandlerFailure> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(HandlerFailure(message: String(describing: error)))
        }
    }

    private func outcome(of result: Result<Value, HandlerFailure>, traffic: TrafficClass) -> GatewayOutcome<Value> {
        switch result {
        case let .success(value):
            return .success(value, replayed: false)
        case let .failure(failure):
            bump(traffic) { $0.failed += 1 }
            return .failed(failure)
        }
    }

    /// Records a shared execution's result and wakes everyone waiting on it (leader included).
    private func finish(_ key: LedgerKey, traffic: TrafficClass, result: Result<Value, HandlerFailure>) {
        executing = max(0, executing - 1)
        switch result {
        case let .success(value): ledger.complete(key, value: value, now: clock.nowMillis())
        case .failure:
            ledger.abandon(key)
            bump(traffic) { $0.executionsFailed += 1 }
        }
        let waiting = waiters.removeValue(forKey: key) ?? []
        for waiter in waiting { waiter.continuation.resume(returning: result) }
    }

    // MARK: Joining an in-flight execution

    private var retryHint: Int64 { max(1, configuration.policy.minRetryAfterMillis) }

    private func clampedRetry(_ millis: Int64) -> Int64 {
        Saturating.clamp(millis, retryHint, max(retryHint, configuration.policy.maxRetryAfterMillis))
    }

    /// A duplicate waits for the in-flight execution of `key`, bounded in count, time and by
    /// cancellation.
    private func join(_ key: LedgerKey, traffic: TrafficClass) async -> GatewayOutcome<Value> {
        let joined = waiters[key]?.reduce(0) { $0 + ($1.isLeader ? 0 : 1) } ?? 0
        guard joined < max(0, configuration.maxWaitersPerKey) else {
            bump(traffic) { $0.inProgress += 1 }
            return .inProgress(retryAfterMillis: retryHint)
        }
        let id = nextWaiterID
        nextWaiterID &+= 1
        let result = await waitForResult(key, id: id, isLeader: false, timeoutMillis: configuration.maxWaitMillis)
        switch result {
        case let .success(value)?:
            bump(traffic) { $0.replayed += 1 }
            return .success(value, replayed: true)
        case let .failure(failure)?:
            bump(traffic) { $0.failed += 1 }
            return .failed(failure)
        case nil:
            bump(traffic) { $0.inProgress += 1 }
            return .inProgress(retryAfterMillis: retryHint)
        }
    }

    /// Suspends until `finish` resumes this waiter (the result) or it stops waiting (`nil`:
    /// timeout, or the calling task was cancelled).
    private func waitForResult(
        _ key: LedgerKey, id: UInt64, isLeader: Bool, timeoutMillis: Int64?
    ) async -> Result<Value, HandlerFailure>? {
        var timer: Task<Void, Never>?
        if let timeoutMillis {
            let timeout = UInt64(max(0, timeoutMillis)).multipliedReportingOverflow(by: 1_000_000)
            let timeoutNanos = timeout.overflow ? UInt64.max : timeout.partialValue
            timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanos)
                // Cancelled because the result arrived: skip the pointless actor hop.
                guard !Task.isCancelled else { return }
                await self?.stopWaiting(key, id: id)
            }
        }
        defer { timer?.cancel() }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiters[key, default: []].append(Waiter(id: id, isLeader: isLeader, continuation: continuation))
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.stopWaiting(key, id: id) }
        }
    }

    /// Resumes one waiter with "stopped waiting". A no-op if the leader already resumed it, so a
    /// continuation is never resumed twice.
    private func stopWaiting(_ key: LedgerKey, id: UInt64) {
        guard var list = waiters[key], let index = list.firstIndex(where: { $0.id == id }) else { return }
        let waiter = list.remove(at: index)
        waiters[key] = list.isEmpty ? nil : list
        waiter.continuation.resume(returning: nil)
    }

    // MARK: Introspection

    public func countersByClass() -> [TrafficClass: ClassCounters] { counters }
    public var executingCount: Int { executing }
    public var ledgerCount: Int { ledger.count }
    /// Duplicates currently waiting (leaders waiting on their own execution aren't counted).
    public var waiterCount: Int { waiters.values.reduce(0) { acc, list in acc + list.reduce(0) { $0 + ($1.isLeader ? 0 : 1) } } }

    private func bump(_ traffic: TrafficClass, _ change: (inout ClassCounters) -> Void) {
        var c = counters[traffic] ?? ClassCounters()
        change(&c)
        counters[traffic] = c
    }
}
