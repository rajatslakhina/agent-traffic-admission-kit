/// Why a request was turned away before it did any work.
public enum ShedReason: String, Sendable, Codable, Hashable {
    /// The caller class used up its token bucket.
    case rateLimited
    /// The backend is past the queue depth this class is allowed to add to.
    case overloaded
}

/// A policy's verdict for one request. Shedding always happens **before** the handler runs,
/// which is what lets a client say "nothing was changed" truthfully.
public enum AdmissionDecision: Sendable, Equatable {
    /// Admit; higher `priority` is served first from the wait queue.
    case admit(priority: Int)
    /// Turn away with a hint. `retryAfterMillis == 0` means "no hint" (the class-blind baseline).
    case shed(ShedReason, retryAfterMillis: Int64)

    public var isAdmitted: Bool {
        if case .admit = self { return true }
        return false
    }
}

/// What the backend knows about its own load at decision time.
public struct LoadSignal: Sendable, Equatable {
    /// Requests admitted but not yet executing (simulator) or currently executing (live gateway).
    public var queueDepth: Int
    public var workers: Int
    public var meanServiceMillis: Int64

    public init(queueDepth: Int, workers: Int, meanServiceMillis: Int64) {
        self.queueDepth = max(0, queueDepth)
        self.workers = max(1, workers)
        self.meanServiceMillis = max(1, meanServiceMillis)
    }

    /// Rough time for the current backlog to drain: `depth × service / workers`, rounded up.
    public var estimatedDrainMillis: Int64 {
        let work = Saturating.multiply(Int64(queueDepth), meanServiceMillis)
        return Saturating.ceilDivide(work, Int64(workers)) ?? 0
    }
}

/// A decision procedure the simulator and the live ``Gateway`` share, so the code the demo
/// measures is the code that would run.
public protocol AdmissionPolicy: Sendable {
    var name: String { get }
    mutating func decide(_ traffic: TrafficClass, load: LoadSignal, now: Int64) -> AdmissionDecision
}

/// Token-bucket parameters for one traffic class.
public struct BucketSpec: Sendable, Equatable, Codable {
    public var capacity: Int64
    public var refillPerSecond: Int64

    public init(capacity: Int64, refillPerSecond: Int64) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
    }
}

/// Priority admission with ordered shedding: agent reads go first, then widgets, then agent
/// writes, and interactive UI last. Each tier has a queue depth past which it may not add work,
/// and agent-shaped and widget traffic additionally draws from a per-(caller, kind) token bucket.
///
/// Overload is checked **before** the bucket, so a shed request never burns a token.
public struct ClassAwarePolicy: AdmissionPolicy {
    public struct Configuration: Sendable, Equatable {
        /// A tier is shed when `queueDepth >= shedDepth[tier]`. A tier with no entry is never
        /// shed for overload.
        public var shedDepth: [ShedTier: Int]
        /// One bucket per (caller, kind), so an agent's reads can't spend its writes' budget.
        /// Classes with no entry are not rate limited.
        public var buckets: [TrafficClass: BucketSpec]
        public var minRetryAfterMillis: Int64
        public var maxRetryAfterMillis: Int64

        public init(
            shedDepth: [ShedTier: Int],
            buckets: [TrafficClass: BucketSpec],
            minRetryAfterMillis: Int64 = 250,
            maxRetryAfterMillis: Int64 = 30_000
        ) {
            self.shedDepth = shedDepth
            self.buckets = buckets
            self.minRetryAfterMillis = minRetryAfterMillis
            self.maxRetryAfterMillis = maxRetryAfterMillis
        }

        /// Defaults used by the demo and the README numbers.
        public static let standard = Configuration(
            shedDepth: [.agentRead: 8, .widget: 16, .agentWrite: 32, .interactive: 256],
            buckets: [
                TrafficClass(.siriAgent, .read): BucketSpec(capacity: 60, refillPerSecond: 40),
                TrafficClass(.siriAgent, .write): BucketSpec(capacity: 30, refillPerSecond: 20),
                TrafficClass(.shortcut, .read): BucketSpec(capacity: 15, refillPerSecond: 10),
                TrafficClass(.shortcut, .write): BucketSpec(capacity: 10, refillPerSecond: 5),
                TrafficClass(.widget, .read): BucketSpec(capacity: 30, refillPerSecond: 15),
                TrafficClass(.widget, .write): BucketSpec(capacity: 10, refillPerSecond: 5)
            ]
        )

        /// Problems that would make the policy contradict its own shed order. Empty means valid.
        public func validationIssues() -> [String] {
            var issues: [String] = []
            let ordered = ShedTier.allCases.sorted()
            for (lower, higher) in zip(ordered, ordered.dropFirst()) {
                let lo = shedDepth[lower] ?? Int.max
                let hi = shedDepth[higher] ?? Int.max
                if lo > hi {
                    issues.append("shedDepth[\(higher)] (\(hi)) is below shedDepth[\(lower)] (\(lo)): \(higher) would be shed before \(lower)")
                }
            }
            for (tier, depth) in shedDepth where depth < 0 {
                issues.append("shedDepth[\(tier)] is negative (\(depth))")
            }
            if minRetryAfterMillis < 1 { issues.append("minRetryAfterMillis must be at least 1") }
            if maxRetryAfterMillis < minRetryAfterMillis { issues.append("maxRetryAfterMillis is below minRetryAfterMillis") }
            for (traffic, spec) in buckets where spec.capacity < 1 || spec.refillPerSecond < 0 {
                issues.append("bucket for \(traffic) has capacity < 1 or negative refill")
            }
            return issues
        }
    }

    public let configuration: Configuration
    public private(set) var buckets: [TrafficClass: TokenBucket]
    public var name: String { "Class-aware" }

    public init(configuration: Configuration = .standard, now: Int64) {
        self.configuration = configuration
        var buckets: [TrafficClass: TokenBucket] = [:]
        for (traffic, spec) in configuration.buckets {
            buckets[traffic] = TokenBucket(capacity: spec.capacity, refillPerSecond: spec.refillPerSecond, now: now)
        }
        self.buckets = buckets
    }

    public mutating func decide(_ traffic: TrafficClass, load: LoadSignal, now: Int64) -> AdmissionDecision {
        let tier = traffic.shedTier
        if let limit = configuration.shedDepth[tier], load.queueDepth >= limit {
            return .shed(.overloaded, retryAfterMillis: clampRetry(load.estimatedDrainMillis))
        }
        if var bucket = buckets[traffic] {
            let took = bucket.tryTake(now: now)
            let wait = bucket.millisUntilNextToken(now: now)
            buckets[traffic] = bucket
            guard took else {
                return .shed(.rateLimited, retryAfterMillis: clampRetry(wait ?? configuration.maxRetryAfterMillis))
            }
        }
        return .admit(priority: tier.rawValue)
    }

    private func clampRetry(_ millis: Int64) -> Int64 {
        let lower = max(1, configuration.minRetryAfterMillis)
        return Saturating.clamp(millis, lower, max(lower, configuration.maxRetryAfterMillis))
    }
}

/// The baseline most backends start from: one FIFO queue sized for human-paced traffic, no idea
/// who is calling, and a bare "busy" with no retry hint when the queue is full.
public struct ClassBlindFIFOPolicy: AdmissionPolicy {
    public let queueCapacity: Int
    public var name: String { "Class-blind FIFO" }

    public init(queueCapacity: Int = 256) {
        self.queueCapacity = max(1, queueCapacity)
    }

    public mutating func decide(_ traffic: TrafficClass, load: LoadSignal, now: Int64) -> AdmissionDecision {
        load.queueDepth >= queueCapacity ? .shed(.overloaded, retryAfterMillis: 0) : .admit(priority: 0)
    }
}

/// Checks that a policy sheds in tier order: at every queue depth, if some tier is admitted then
/// every higher tier is admitted too. Buckets are bypassed by probing with a fresh policy per
/// call, so only the overload rule is audited.
public enum ShedOrderAudit {
    public struct Violation: Sendable, Equatable, CustomStringConvertible {
        public let queueDepth: Int
        /// A lower-priority tier that was admitted...
        public let admittedTier: ShedTier
        /// ...while this higher-priority tier was shed at the same depth.
        public let shedTier: ShedTier
        public var description: String {
            "at depth \(queueDepth): \(admittedTier) admitted but higher-priority \(shedTier) shed"
        }
    }

    /// - Parameter makePolicy: builds a fresh policy for each probe so token buckets never interfere.
    public static func audit<P: AdmissionPolicy>(
        maxDepth: Int = 512,
        makePolicy: () -> P
    ) -> [Violation] {
        var violations: [Violation] = []
        let representative: [ShedTier: TrafficClass] = [
            .agentRead: TrafficClass(.siriAgent, .read),
            .widget: TrafficClass(.widget, .read),
            .agentWrite: TrafficClass(.siriAgent, .write),
            .interactive: TrafficClass(.interactiveUI, .write)
        ]
        for depth in 0...max(0, maxDepth) {
            var admittedTiers: [ShedTier: Bool] = [:]
            for tier in ShedTier.allCases {
                guard let traffic = representative[tier] else { continue }
                var policy = makePolicy()
                let load = LoadSignal(queueDepth: depth, workers: 1, meanServiceMillis: 1)
                admittedTiers[tier] = policy.decide(traffic, load: load, now: 0).isAdmitted
            }
            for low in ShedTier.allCases where admittedTiers[low] == true {
                for high in ShedTier.allCases where high > low && admittedTiers[high] == false {
                    violations.append(Violation(queueDepth: depth, admittedTier: low, shedTier: high))
                }
            }
        }
        return violations
    }
}
