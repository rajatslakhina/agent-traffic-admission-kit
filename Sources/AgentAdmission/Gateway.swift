/// One request as the backend sees it.
public struct GatewayRequest: Sendable {
    public let token: ScopeToken
    public let capability: Capability
    /// The entry point the app says this came from. Must match the token's grant.
    public let claimedCaller: CallerClass
    /// Required for writes. Reused on every retry of the same intent (see ``IntentKeyCache``).
    public let idempotencyKey: IdempotencyKey?
    /// A stable digest of the payload. The same key with a different fingerprint is a conflict.
    public let fingerprint: String

    public init(token: ScopeToken, capability: Capability, claimedCaller: CallerClass, idempotencyKey: IdempotencyKey?, fingerprint: String) {
        self.token = token
        self.capability = capability
        self.claimedCaller = claimedCaller
        self.idempotencyKey = idempotencyKey
        self.fingerprint = fingerprint
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
    /// Another request with the same key is still running and this one stopped waiting for it
    /// (too many waiters, the wait timed out, or this task was cancelled). The write may still
    /// complete; retrying with the **same key** returns its result without running it twice.
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
    /// Duplicates that stopped waiting for an in-flight execution (``GatewayOutcome/inProgress(retryAfterMillis:)``).
    public var inProgress = 0
    /// Times the handler actually ran.
    public var executed = 0
    /// Handler threw, counted once for the request that ran it and once per joiner it failed.
    public var failed = 0
    public init() {}
}

/// Why ``Gateway/init(validating:authority:clock:)`` refused a configuration.
public struct GatewayConfigurationError: Error, Sendable, Equatable {
    public let issues: [String]
}

/// Where a write's idempotency record lives. Scoping by principal, skill and capability means
/// one caller can never read another caller's stored result by presenting their key.
struct LedgerKey: Hashable, Sendable {
    let principal: String
    let skillID: String
    let capability: Capability
    let key: IdempotencyKey
}

/// The live, concurrent composition of scope check → idempotency → admission → handler.
///
/// Everything between reading the ledger and marking a key in flight happens without an `await`,
/// so two concurrent requests with the same key cannot both decide to execute (actor
/// reentrancy only happens at suspension points, and there are none in that window). There are
/// exactly two suspensions, the handler call and a duplicate's wait for it, and neither sits
/// between lookup and claim; state is re-read after each, never assumed.
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
        /// Size for peak writes × TTL: a full ledger sheds new writes rather than evict live records.
        public var ledgerCapacity: Int
        public var ledgerTTLMillis: Int64
        /// Most duplicates allowed to wait on one in-flight key; more get `.inProgress`.
        public var maxWaitersPerKey: Int
        /// Longest a duplicate waits for the in-flight execution before returning `.inProgress`.
        public var maxWaitMillis: Int64

        public init(
            policy: ClassAwarePolicy.Configuration = .standard,
            workers: Int = 8,
            meanServiceMillis: Int64 = 50,
            ledgerCapacity: Int = 10_000,
            ledgerTTLMillis: Int64 = 24 * 60 * 60 * 1_000,
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
        operation: @Sendable () async throws -> Value
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
            LedgerKey(principal: grant.principal ?? "token:" + request.token.rawValue, skillID: grant.skillID, capability: request.capability, key: $0)
        }

        // 3. Duplicates are served without admission: they cost a lookup, not a handler run.
        if let ledgerKey {
            switch ledger.lookup(ledgerKey, fingerprint: request.fingerprint, now: now) {
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

        // 4. Admission. Shedding here is strictly before execution.
        let load = LoadSignal(queueDepth: executing, workers: configuration.workers, meanServiceMillis: configuration.meanServiceMillis)
        if case let .shed(reason, retryAfter) = policy.decide(traffic, load: load, now: now) {
            bump(traffic) { $0.shed += 1 }
            return .shed(reason, retryAfterMillis: retryAfter)
        }

        // 5. Claim the key. No `await` since step 3, so nobody else can have claimed it.
        if let ledgerKey {
            switch ledger.begin(ledgerKey, fingerprint: request.fingerprint, now: now) {
            case .started:
                break
            case .full, .alreadyPresent:
                // Not executed, so telling the client to come back is safe.
                bump(traffic) { $0.shed += 1 }
                return .shed(.overloaded, retryAfterMillis: retryHint)
            }
        }

        bump(traffic) { $0.admitted += 1; $0.executed += 1 }
        executing += 1
        let result: Result<Value, HandlerFailure>
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(HandlerFailure(message: String(describing: error)))
        }
        // Re-entered after the suspension: re-read everything below from actor state.
        executing = max(0, executing - 1)

        if let ledgerKey {
            switch result {
            case let .success(value): ledger.complete(ledgerKey, value: value, now: clock.nowMillis())
            case .failure: ledger.abandon(ledgerKey)
            }
            let joined = waiters.removeValue(forKey: ledgerKey) ?? []
            for waiter in joined { waiter.continuation.resume(returning: result) }
        }

        switch result {
        case let .success(value):
            return .success(value, replayed: false)
        case let .failure(failure):
            bump(traffic) { $0.failed += 1 }
            return .failed(failure)
        }
    }

    // MARK: Joining an in-flight execution

    private var retryHint: Int64 { max(1, configuration.policy.minRetryAfterMillis) }

    /// Waits for the in-flight execution of `key`, bounded in count, time and by cancellation.
    private func join(_ key: LedgerKey, traffic: TrafficClass) async -> GatewayOutcome<Value> {
        guard (waiters[key]?.count ?? 0) < max(0, configuration.maxWaitersPerKey) else {
            bump(traffic) { $0.inProgress += 1 }
            return .inProgress(retryAfterMillis: retryHint)
        }
        let id = nextWaiterID
        nextWaiterID &+= 1
        let timeout = UInt64(max(0, configuration.maxWaitMillis)).multipliedReportingOverflow(by: 1_000_000)
        let timeoutNanos = timeout.overflow ? UInt64.max : timeout.partialValue
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanos)
            await self?.stopWaiting(key, id: id)
        }
        defer { timer.cancel() }

        let result: Result<Value, HandlerFailure>? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.stopWaiting(key, id: id) }
        }

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
    public var waiterCount: Int { waiters.values.reduce(0) { $0 + $1.count } }

    private func bump(_ traffic: TrafficClass, _ change: (inout ClassCounters) -> Void) {
        var c = counters[traffic] ?? ClassCounters()
        change(&c)
        counters[traffic] = c
    }
}
