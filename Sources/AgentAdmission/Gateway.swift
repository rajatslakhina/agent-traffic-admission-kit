/// One request as the backend sees it.
public struct GatewayRequest: Sendable {
    public let token: ScopeToken
    public let capability: Capability
    /// The entry point the app says this came from. Must match the token's grant.
    public let claimedCaller: CallerClass
    /// Required for writes. Reused on every retry of the same intent.
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
}

public enum GatewayOutcome<Value: Sendable>: Sendable {
    /// `replayed == true` when the value came from an earlier execution of the same key
    /// (a completed replay, or a duplicate that joined the in-flight execution).
    case success(Value, replayed: Bool)
    /// Turned away before the handler ran: nothing was executed.
    case shed(ShedReason, retryAfterMillis: Int64)
    case denied(AuthorizationFailure)
    case rejected(RequestRejection)
    /// The handler ran and threw. It may or may not have had side effects (see README limits).
    case failed(HandlerFailure)
}

/// Per-traffic-class counters, so dashboards can separate agent load from human load.
public struct ClassCounters: Sendable, Equatable {
    public var admitted = 0
    public var shed = 0
    public var denied = 0
    public var rejected = 0
    /// Served from a completed entry, or joined an in-flight execution.
    public var replayed = 0
    /// Times the handler actually ran.
    public var executed = 0
    public var failed = 0
    public init() {}
}

/// The live, concurrent composition of scope check → idempotency → admission → handler.
///
/// Everything between reading the ledger and marking a key in flight happens without an `await`,
/// so two concurrent requests with the same key cannot both decide to execute (actor
/// reentrancy only happens at suspension points, and there are none in that window). The single
/// suspension is the handler call; state is re-read after it, never assumed.
public actor Gateway<Value: Sendable> {
    public struct Configuration: Sendable {
        public var policy: ClassAwarePolicy.Configuration
        /// Used for the Retry-After estimate; the live gateway has no wait queue, so the depth it
        /// reports to the policy is the number of handlers currently executing.
        public var workers: Int
        public var meanServiceMillis: Int64
        public var ledgerCapacity: Int
        public var ledgerTTLMillis: Int64

        public init(
            policy: ClassAwarePolicy.Configuration = .standard,
            workers: Int = 8,
            meanServiceMillis: Int64 = 50,
            ledgerCapacity: Int = 10_000,
            ledgerTTLMillis: Int64 = 24 * 60 * 60 * 1_000
        ) {
            self.policy = policy
            self.workers = workers
            self.meanServiceMillis = meanServiceMillis
            self.ledgerCapacity = ledgerCapacity
            self.ledgerTTLMillis = ledgerTTLMillis
        }
    }

    public let configuration: Configuration
    private let clock: any AdmissionClock
    private var authority: ScopeAuthority
    private var policy: ClassAwarePolicy
    private var ledger: IdempotencyLedger<Value>
    private var waiters: [IdempotencyKey: [CheckedContinuation<Result<Value, HandlerFailure>, Never>]] = [:]
    private var executing = 0
    private var counters: [TrafficClass: ClassCounters] = [:]

    public init(configuration: Configuration = Configuration(), authority: ScopeAuthority = ScopeAuthority(), clock: any AdmissionClock) {
        self.configuration = configuration
        self.clock = clock
        self.authority = authority
        self.policy = ClassAwarePolicy(configuration: configuration.policy, now: clock.nowMillis())
        self.ledger = IdempotencyLedger(capacity: configuration.ledgerCapacity, ttlMillis: configuration.ledgerTTLMillis)
    }

    // MARK: Grants

    /// Issues a grant whose `expiresAtMillis` is already in this gateway's clock domain.
    public func issue(_ grant: SkillGrant) -> Result<ScopeToken, GrantIssueFailure> {
        authority.issue(grant, now: clock.nowMillis())
    }

    /// Issues a grant valid for `validForMillis` from now on this gateway's clock, so callers
    /// never have to know where the clock's zero is.
    public func issue(
        skillID: String,
        caller: CallerClass,
        capabilities: Set<Capability>,
        validForMillis: Int64
    ) -> Result<ScopeToken, GrantIssueFailure> {
        let now = clock.nowMillis()
        let grant = SkillGrant(
            skillID: skillID, caller: caller, capabilities: capabilities,
            expiresAtMillis: Saturating.add(now, max(0, validForMillis))
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

        // 3. Duplicates are served without admission: they cost a lookup, not a handler run.
        if let key = request.idempotencyKey {
            switch ledger.lookup(key, fingerprint: request.fingerprint, now: now) {
            case let .replay(value):
                bump(traffic) { $0.replayed += 1 }
                return .success(value, replayed: true)
            case .conflict:
                bump(traffic) { $0.rejected += 1 }
                return .rejected(.idempotencyConflict)
            case .inFlight:
                bump(traffic) { $0.replayed += 1 }
                let result = await withCheckedContinuation { continuation in
                    waiters[key, default: []].append(continuation)
                }
                switch result {
                case let .success(value): return .success(value, replayed: true)
                case let .failure(failure): return .failed(failure)
                }
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
        if let key = request.idempotencyKey {
            switch ledger.begin(key, fingerprint: request.fingerprint, now: now) {
            case .started:
                break
            case .full, .alreadyPresent:
                // Not executed, so telling the client to come back is safe.
                bump(traffic) { $0.shed += 1 }
                return .shed(.overloaded, retryAfterMillis: max(1, configuration.policy.minRetryAfterMillis))
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

        if let key = request.idempotencyKey {
            switch result {
            case let .success(value): ledger.complete(key, value: value, now: clock.nowMillis())
            case .failure: ledger.abandon(key)
            }
            let joined = waiters.removeValue(forKey: key) ?? []
            for continuation in joined { continuation.resume(returning: result) }
        }

        switch result {
        case let .success(value):
            return .success(value, replayed: false)
        case let .failure(failure):
            bump(traffic) { $0.failed += 1 }
            return .failed(failure)
        }
    }

    // MARK: Introspection

    public func countersByClass() -> [TrafficClass: ClassCounters] { counters }
    public var executingCount: Int { executing }
    public var ledgerCount: Int { ledger.count }

    private func bump(_ traffic: TrafficClass, _ change: (inout ClassCounters) -> Void) {
        var c = counters[traffic] ?? ClassCounters()
        change(&c)
        counters[traffic] = c
    }
}
