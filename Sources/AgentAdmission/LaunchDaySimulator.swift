import Foundation

/// The traffic the backend sees: per-class Poisson arrivals, plus an agent burst window.
public struct TrafficProfile: Sendable, Equatable {
    public var durationSeconds: Int
    public var workers: Int
    public var readServiceMillis: Int64
    public var writeServiceMillis: Int64
    /// How long any client waits for one attempt before giving up on it.
    public var clientTimeoutMillis: Int64
    /// Requests per second outside the burst.
    public var baselineRates: [TrafficClass: Double]
    public var burstStartSecond: Int
    public var burstEndSecond: Int
    /// Multiplies the rate of agent-originated classes (Siri AI, Shortcuts) inside the burst.
    public var burstMultiplier: Double
    /// Fraction of successful responses lost on the way back (a cellular drop after the server
    /// committed). The client sees a timeout and retries; this is why writes need keys even
    /// when the backend is healthy.
    public var responseLossRate: Double
    public var seed: UInt64

    /// Hard ceiling on generated first attempts, so a hostile profile can't allocate without bound.
    public static let maxArrivals = 200_000

    public init(
        durationSeconds: Int, workers: Int, readServiceMillis: Int64, writeServiceMillis: Int64,
        clientTimeoutMillis: Int64, baselineRates: [TrafficClass: Double],
        burstStartSecond: Int, burstEndSecond: Int, burstMultiplier: Double,
        responseLossRate: Double = 0, seed: UInt64
    ) {
        self.durationSeconds = min(max(1, durationSeconds), 600)
        self.workers = min(max(1, workers), 512)
        self.readServiceMillis = Saturating.clamp(readServiceMillis, 1, 60_000)
        self.writeServiceMillis = Saturating.clamp(writeServiceMillis, 1, 60_000)
        self.clientTimeoutMillis = Saturating.clamp(clientTimeoutMillis, 1, 600_000)
        self.baselineRates = baselineRates.mapValues { $0.isNaN ? 0 : min(max(0, $0), 10_000) }
        // Clamped into the run, so `seconds × 1_000` can never overflow.
        self.burstStartSecond = min(max(0, burstStartSecond), self.durationSeconds)
        self.burstEndSecond = min(max(self.burstStartSecond, burstEndSecond), self.durationSeconds)
        self.burstMultiplier = burstMultiplier.isFinite ? min(max(0, burstMultiplier), 1_000) : 1
        self.responseLossRate = responseLossRate.isFinite ? min(max(0, responseLossRate), 0.5) : 0
        self.seed = seed
    }

    /// 90 seconds, a 10× agent burst from 30 s to 60 s, against 8 workers sized for human traffic
    /// (about 40% busy before the burst, about 110% during it before any retries), with 0.5% of
    /// responses lost in transit.
    public static let launchDay = TrafficProfile(
        durationSeconds: 90, workers: 8, readServiceMillis: 40, writeServiceMillis: 80,
        clientTimeoutMillis: 1_500,
        baselineRates: [
            TrafficClass(.interactiveUI, .read): 40, TrafficClass(.interactiveUI, .write): 8,
            TrafficClass(.widget, .read): 10,
            TrafficClass(.siriAgent, .read): 8, TrafficClass(.siriAgent, .write): 2,
            TrafficClass(.shortcut, .read): 2, TrafficClass(.shortcut, .write): 1
        ],
        burstStartSecond: 30, burstEndSecond: 60, burstMultiplier: 10, responseLossRate: 0.005, seed: 0xA11CE
    )

    /// Re-applies the initializer's clamps, for profiles whose properties were mutated after init.
    public func normalized() -> TrafficProfile {
        TrafficProfile(
            durationSeconds: durationSeconds, workers: workers, readServiceMillis: readServiceMillis,
            writeServiceMillis: writeServiceMillis, clientTimeoutMillis: clientTimeoutMillis,
            baselineRates: baselineRates, burstStartSecond: burstStartSecond, burstEndSecond: burstEndSecond,
            burstMultiplier: burstMultiplier, responseLossRate: responseLossRate, seed: seed
        )
    }

    public func serviceMillis(for kind: OperationKind) -> Int64 {
        kind == .read ? readServiceMillis : writeServiceMillis
    }

    func rate(for traffic: TrafficClass, atMillis t: Int64) -> Double {
        let base = baselineRates[traffic] ?? 0
        let start = Saturating.multiply(Int64(burstStartSecond), 1_000)
        let end = Saturating.multiply(Int64(burstEndSecond), 1_000)
        let inBurst = t >= start && t < end
        return inBurst && traffic.caller.isAgentOriginated ? base * burstMultiplier : base
    }
}

/// The backend + client behaviour being compared. Each switch can be flipped on its own in the demo.
public struct SimulationSetup: Sendable, Equatable {
    public enum PolicyChoice: Sendable, Equatable {
        case classBlindFIFO(queueCapacity: Int)
        case classAware(ClassAwarePolicy.Configuration)
    }

    public var name: String
    public var policy: PolicyChoice
    /// Clients send one key per write intent and the server dedupes on it. Reads carry no key.
    public var idempotencyKeys: Bool
    public var agentRetry: RetryPolicy
    /// A person who sees an error taps again once. Widgets never retry on their own.
    public var interactiveRetry: RetryPolicy
    /// Skip queued work whose client has already stopped waiting. Safe because it never ran.
    public var dropExpiredOnDequeue: Bool
    /// The simulated server's ``IdempotencyLedger`` (the shipped type, keyed by intent).
    public var ledgerCapacity: Int
    public var ledgerTTLMillis: Int64

    public init(
        name: String, policy: PolicyChoice, idempotencyKeys: Bool, agentRetry: RetryPolicy,
        interactiveRetry: RetryPolicy = .personTapsAgain, dropExpiredOnDequeue: Bool,
        ledgerCapacity: Int = 100_000, ledgerTTLMillis: Int64 = 10 * 60 * 1_000
    ) {
        self.ledgerCapacity = ledgerCapacity
        self.ledgerTTLMillis = ledgerTTLMillis
        self.name = name
        self.policy = policy
        self.idempotencyKeys = idempotencyKeys
        self.agentRetry = agentRetry
        self.interactiveRetry = interactiveRetry
        self.dropExpiredOnDequeue = dropExpiredOnDequeue
    }

    /// A backend sized for taps, unchanged: one FIFO queue, no keys, clients retry on a fixed short delay.
    public static let sizedForTaps = SimulationSetup(
        name: "Sized for taps", policy: .classBlindFIFO(queueCapacity: 256),
        idempotencyKeys: false, agentRetry: .naiveAgent, dropExpiredOnDequeue: false
    )

    /// This package: ordered shedding + buckets, idempotency keys, hint-honouring jittered retries.
    public static let classAware = SimulationSetup(
        name: "Class-aware", policy: .classAware(.standard),
        idempotencyKeys: true, agentRetry: .wellBehavedAgent, dropExpiredOnDequeue: true
    )
}

/// Per-traffic-class results of one run.
public struct ClassReport: Sendable, Equatable, Identifiable {
    public var id: TrafficClass { traffic }
    public let traffic: TrafficClass
    /// Distinct intents (first attempts).
    public internal(set) var intents = 0
    public internal(set) var succeeded = 0
    public internal(set) var attempts = 0
    public internal(set) var shed = 0
    public internal(set) var timedOut = 0
    /// Retries answered from the idempotency ledger (completed replay or joined in-flight).
    public internal(set) var replayed = 0
    /// Queued work skipped because its client had already stopped waiting.
    public internal(set) var droppedExpired = 0
    /// Successful responses lost in transit (the client saw a timeout instead).
    public internal(set) var lostResponses = 0
    /// Handler executions.
    public internal(set) var executions = 0
    /// Executions beyond the first for the same intent. For writes, each one is a double charge.
    public internal(set) var duplicateExecutions = 0
    /// End-to-end latency (first attempt → success), sorted ascending.
    public internal(set) var latencies: [Int64] = []

    public init(traffic: TrafficClass) { self.traffic = traffic }

    public var failed: Int { max(0, intents) - min(max(0, succeeded), max(0, intents)) }
    public var successRate: Double { intents <= 0 ? 1 : Double(min(max(0, succeeded), intents)) / Double(intents) }
    public func percentile(_ p: Double) -> Int64? { Percentile.nearestRank(latencies, p) }
    /// Success rate for display, rounded **down** to 0.1%, so "100%" appears only when every
    /// intent succeeded and a 99.96% run can't round itself up to perfect.
    public var successPercentText: String {
        guard intents > 0, succeeded < intents else { return "100%" }
        let ok = Int64(max(0, succeeded))
        let (scaled, overflow) = ok.multipliedReportingOverflow(by: 1_000)
        var tenths: Int64
        if overflow {
            tenths = Saturating.int64((Double(ok) / Double(intents) * 1_000).rounded(.down))
        } else {
            tenths = Saturating.divide(scaled, Int64(intents)) ?? 0
        }
        // succeeded < intents here, so never print a perfect score.
        tenths = Saturating.clamp(tenths, 0, 999)
        return "\(tenths / 10).\(tenths % 10)%"
    }

    public var p50: Int64? { percentile(0.50) }
    public var p99: Int64? { percentile(0.99) }

    mutating func merge(_ other: ClassReport) {
        intents += other.intents; succeeded += other.succeeded; attempts += other.attempts
        shed += other.shed; timedOut += other.timedOut; replayed += other.replayed
        droppedExpired += other.droppedExpired; executions += other.executions
        lostResponses += other.lostResponses
        duplicateExecutions += other.duplicateExecutions
        latencies.append(contentsOf: other.latencies)
        latencies.sort()
    }
}

/// One-second sample for the timeline chart.
public struct SecondSample: Sendable, Equatable, Identifiable {
    public var id: Int { second }
    public let second: Int
    public var maxQueueDepth = 0
    public var shedAgent = 0
    public var shedHuman = 0
}

/// A floor on how the interactive path must behave through the burst.
public struct InteractiveSLO: Sendable, Equatable {
    public var p99Millis: Int64
    /// Fraction of interactive intents allowed to fail (shed or time out).
    public var maxFailureRate: Double
    public init(p99Millis: Int64 = 300, maxFailureRate: Double = 0.001) {
        self.p99Millis = p99Millis
        self.maxFailureRate = maxFailureRate
    }
}

public struct SimulationReport: Sendable, Equatable {
    public let setupName: String
    public let perClass: [ClassReport]
    public let timeline: [SecondSample]
    /// Busy worker-time ÷ (workers × simulated duration). Can exceed 1 when work drains past the end.
    public let utilization: Double
    /// `true` if `TrafficProfile.maxArrivals` capped the generated traffic.
    public let truncated: Bool
    /// `true` if the calling task was cancelled mid-run; the numbers are then partial.
    public let cancelled: Bool

    public func report(for traffic: TrafficClass) -> ClassReport {
        perClass.first { $0.traffic == traffic } ?? ClassReport(traffic: traffic)
    }

    /// All kinds for one caller, merged.
    public func aggregate(_ caller: CallerClass) -> ClassReport {
        var merged = ClassReport(traffic: TrafficClass(caller, .read))
        for r in perClass where r.traffic.caller == caller { merged.merge(r) }
        return merged
    }

    public var duplicateWriteExecutions: Int {
        perClass.filter { $0.traffic.kind == .write }.reduce(0) { $0 + $1.duplicateExecutions }
    }

    /// A plain-text table, one row per caller class, for logs and the README.
    public func summary() -> String {
        var lines = ["\(setupName): utilization \(Int((utilization * 100).rounded()))%, duplicate writes \(duplicateWriteExecutions)"]
        lines.append("caller         intents  ok     p50   p99  shed  timeout  replayed  dropped  dupExec")
        for caller in CallerClass.allCases {
            let r = aggregate(caller)
            let cols: [String] = [
                caller.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0),
                String(r.intents), r.successPercentText, r.p50.map(String.init) ?? "-", r.p99.map(String.init) ?? "-",
                String(r.shed), String(r.timedOut), String(r.replayed), String(r.droppedExpired), String(r.duplicateExecutions)
            ]
            lines.append(cols.joined(separator: "  "))
        }
        return lines.joined(separator: "\n")
    }

    /// Empty when the interactive path met the SLO.
    public func violations(of slo: InteractiveSLO) -> [String] {
        let ui = aggregate(.interactiveUI)
        var out: [String] = []
        guard ui.intents > 0 else { return ["no interactive traffic was simulated"] }
        if let p99 = ui.p99 {
            if p99 > slo.p99Millis { out.append("interactive p99 \(p99) ms > \(slo.p99Millis) ms") }
        } else {
            out.append("no interactive request succeeded")
        }
        let failureRate = 1 - ui.successRate
        if failureRate > slo.maxFailureRate {
            out.append("interactive failure rate \(failureRate) > \(slo.maxFailureRate)")
        }
        return out
    }
}

public enum Percentile {
    /// Nearest-rank percentile of an ascending array; `nil` for an empty array or a non-finite `p`.
    public static func nearestRank(_ sorted: [Int64], _ p: Double) -> Int64? {
        guard !sorted.isEmpty, p.isFinite else { return nil }
        let clamped = min(max(p, 0), 1)
        let rank = Saturating.int(Saturating.int64((clamped * Double(sorted.count)).rounded(.up)))
        let index = min(max(rank - 1, 0), sorted.count - 1)
        return sorted[index]
    }
}

/// A deterministic discrete-event simulation of one backend under a launch-day agent burst.
///
/// It runs the same ``ClassAwarePolicy`` the live ``Gateway`` runs, so the numbers the demo
/// shows come from the shipped decision code, not a re-implementation. Same profile + setup +
/// seed gives the same report, bit for bit. It checks `Task.isCancelled` every 4,096 events
/// and returns a partial report marked ``SimulationReport/cancelled`` if the caller gave up.
public enum LaunchDaySimulator {
    public static func run(profile: TrafficProfile, setup: SimulationSetup) -> SimulationReport {
        var engine = Engine(profile: profile.normalized(), setup: setup)
        return engine.run()
    }
}

// MARK: - Engine

private struct Engine {
    struct Intent {
        let traffic: TrafficClass
        let firstArrival: Int64
        var attempt = 0
        /// When the client stops waiting for the current attempt; `.min` while no attempt is pending.
        var waitingUntil: Int64 = .min
        var done = false
        var executions = 0
        /// The job currently holding this intent's ledger claim.
        var inFlightJob: Int?
    }

    struct Job {
        /// Index into `jobs`.
        let id: Int
        let intent: Int
        let attempt: Int
        let priority: Int
        let seq: Int
        let service: Int64
    }

    enum Kind { case arrival(intent: Int, attempt: Int), timeout(intent: Int, attempt: Int), completion(job: Int) }

    struct Event {
        let time: Int64
        let seq: Int
        let kind: Kind
    }

    enum Policy {
        case fifo(ClassBlindFIFOPolicy)
        case aware(ClassAwarePolicy)

        mutating func decide(_ t: TrafficClass, load: LoadSignal, now: Int64) -> AdmissionDecision {
            switch self {
            case var .fifo(p): let d = p.decide(t, load: load, now: now); self = .fifo(p); return d
            case var .aware(p): let d = p.decide(t, load: load, now: now); self = .aware(p); return d
            }
        }
    }

    let profile: TrafficProfile
    let setup: SimulationSetup
    var rng: SplitMix64
    var policy: Policy
    var intents: [Intent] = []
    var jobs: [Job] = []
    var events = BinaryHeap<Event> { a, b in a.time != b.time ? a.time < b.time : a.seq < b.seq }
    var queue = BinaryHeap<Job> { a, b in a.priority != b.priority ? a.priority > b.priority : a.seq < b.seq }
    var seq = 0
    var freeWorkers: Int
    var busyMillis: Int64 = 0
    var reports: [TrafficClass: ClassReport] = [:]
    var timeline: [Int: SecondSample] = [:]
    var truncated = false
    let meanService: Int64
    var ledger: IdempotencyLedger<Int, Void>

    init(profile: TrafficProfile, setup: SimulationSetup) {
        self.profile = profile
        self.setup = setup
        self.rng = SplitMix64(seed: profile.seed)
        switch setup.policy {
        case let .classBlindFIFO(capacity): policy = .fifo(ClassBlindFIFOPolicy(queueCapacity: capacity))
        case let .classAware(config): policy = .aware(ClassAwarePolicy(configuration: config, now: 0))
        }
        freeWorkers = profile.workers
        ledger = IdempotencyLedger(capacity: setup.ledgerCapacity, ttlMillis: setup.ledgerTTLMillis)
        meanService = max(1, (profile.readServiceMillis + profile.writeServiceMillis) / 2)
        for t in TrafficClass.all { reports[t] = ClassReport(traffic: t) }
    }

    mutating func nextSeq() -> Int { seq += 1; return seq }

    mutating func schedule(_ time: Int64, _ kind: Kind) {
        events.push(Event(time: time, seq: nextSeq(), kind: kind))
    }

    mutating func generateArrivals() {
        let end = Int64(profile.durationSeconds) * 1_000
        var boundaries: [Int64] = [
            Saturating.multiply(Int64(profile.burstStartSecond), 1_000),
            Saturating.multiply(Int64(profile.burstEndSecond), 1_000),
            end
        ]
        boundaries = boundaries.filter { $0 > 0 && $0 <= end }.sorted()
        var arrivals: [(Int64, TrafficClass)] = []
        for traffic in TrafficClass.all {
            var t: Double = 0
            while t < Double(end) {
                let now = Saturating.int64(t)
                let nextBoundary = boundaries.first { $0 > now } ?? end
                let rate = profile.rate(for: traffic, atMillis: now)
                guard rate > 0 else { t = Double(nextBoundary); continue }
                let gap = -log(rng.unitOpenClosed()) / rate * 1_000
                let candidate = t + gap
                if candidate >= Double(nextBoundary) {
                    // Memoryless: restart the draw at the rate change.
                    t = Double(nextBoundary)
                    continue
                }
                t = candidate
                arrivals.append((Saturating.int64(t), traffic))
                if arrivals.count >= TrafficProfile.maxArrivals { truncated = true; break }
            }
            if truncated { break }
        }
        arrivals.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.description < $1.1.description }
        for (time, traffic) in arrivals {
            intents.append(Intent(traffic: traffic, firstArrival: time))
            schedule(time, .arrival(intent: intents.count - 1, attempt: 1))
            reports[traffic]?.intents += 1
        }
    }

    mutating func run() -> SimulationReport {
        generateArrivals()
        var processed = 0
        var cancelled = false
        while let event = events.pop() {
            processed &+= 1
            // Cooperative cancellation, checked cheaply: a superseded run in an app stops early.
            if processed % 4_096 == 0, Task.isCancelled { cancelled = true; break }
            let now = event.time
            switch event.kind {
            case let .arrival(i, a): arrive(i, attempt: a, now: now)
            case let .timeout(i, a): timeOut(i, attempt: a, now: now)
            case let .completion(j): complete(j, now: now)
            }
        }
        let capacity = Double(profile.workers) * Double(profile.durationSeconds) * 1_000
        let perClass = TrafficClass.all.compactMap { t -> ClassReport? in
            guard var r = reports[t] else { return nil }
            r.latencies.sort()
            return r
        }
        return SimulationReport(
            setupName: setup.name,
            perClass: perClass,
            timeline: timeline.keys.sorted().compactMap { timeline[$0] },
            utilization: capacity > 0 ? Double(busyMillis) / capacity : 0,
            truncated: truncated,
            cancelled: cancelled
        )
    }

    mutating func sample(_ now: Int64, _ change: (inout SecondSample) -> Void) {
        let second = Saturating.int(now / 1_000)
        // Bounded: events stop when the queue drains, and the drain is finite.
        var s = timeline[second] ?? SecondSample(second: second)
        change(&s)
        timeline[second] = s
    }

    mutating func arrive(_ i: Int, attempt: Int, now: Int64) {
        guard intents.indices.contains(i), !intents[i].done else { return }
        let traffic = intents[i].traffic
        intents[i].attempt = attempt
        intents[i].waitingUntil = Saturating.add(now, profile.clientTimeoutMillis)
        schedule(intents[i].waitingUntil, .timeout(intent: i, attempt: attempt))
        reports[traffic]?.attempts += 1

        if keyed(i) {
            switch ledger.lookup(i, fingerprint: "", now: now) {
            case .replay:
                reports[traffic]?.replayed += 1
                succeed(i, now: now)
                return
            case .inFlight:
                // Joined: the in-flight execution will answer this attempt too.
                reports[traffic]?.replayed += 1
                return
            case .absent, .conflict:
                break
            }
        }

        let load = LoadSignal(queueDepth: queue.count, workers: profile.workers, meanServiceMillis: meanService)
        switch policy.decide(traffic, load: load, now: now) {
        case let .shed(_, retryAfter):
            reports[traffic]?.shed += 1
            sample(now) { s in
                if traffic.caller.isAgentOriginated { s.shedAgent += 1 } else { s.shedHuman += 1 }
            }
            failAttempt(i, attempt: attempt, retryAfter: retryAfter, now: now)
        case let .admit(priority):
            if keyed(i), ledger.begin(i, fingerprint: "", now: now) != .started {
                // Ledger full of live records: shed rather than run unprotected.
                reports[traffic]?.shed += 1
                failAttempt(i, attempt: attempt, retryAfter: 250, now: now)
                return
            }
            let job = Job(id: jobs.count, intent: i, attempt: attempt, priority: priority, seq: nextSeq(), service: profile.serviceMillis(for: traffic.kind))
            jobs.append(job)
            if keyed(i) { intents[i].inFlightJob = job.id }
            queue.push(job)
            let depth = queue.count
            sample(now) { $0.maxQueueDepth = max($0.maxQueueDepth, depth) }
            dispatch(now: now)
        }
    }

    /// Writes carry an idempotency key when the setup uses keys; reads never do (as with the Gateway).
    func keyed(_ i: Int) -> Bool {
        setup.idempotencyKeys && intents.indices.contains(i) && intents[i].traffic.kind == .write
    }

    mutating func timeOut(_ i: Int, attempt: Int, now: Int64) {
        guard intents.indices.contains(i), !intents[i].done, intents[i].attempt == attempt,
              intents[i].waitingUntil != .min else { return }
        reports[intents[i].traffic]?.timedOut += 1
        failAttempt(i, attempt: attempt, retryAfter: nil, now: now)
    }

    mutating func failAttempt(_ i: Int, attempt: Int, retryAfter: Int64?, now: Int64) {
        intents[i].waitingUntil = .min
        let traffic = intents[i].traffic
        // Agents retry on their own; a person taps again (with the same key, held by the screen);
        // a widget waits for the system's next timeline reload.
        let retry: RetryPolicy?
        switch traffic.caller {
        case .siriAgent, .shortcut: retry = setup.agentRetry
        case .interactiveUI: retry = setup.interactiveRetry
        case .widget: retry = nil
        }
        if let retry, let delay = retry.delay(afterAttempt: attempt, retryAfterMillis: retryAfter, using: &rng) {
            schedule(Saturating.add(now, delay), .arrival(intent: i, attempt: attempt + 1))
        } else {
            intents[i].done = true
        }
    }

    mutating func succeed(_ i: Int, now: Int64) {
        intents[i].done = true
        intents[i].waitingUntil = .min
        let traffic = intents[i].traffic
        reports[traffic]?.succeeded += 1
        reports[traffic]?.latencies.append(Saturating.subtract(now, intents[i].firstArrival))
    }

    mutating func complete(_ j: Int, now: Int64) {
        guard jobs.indices.contains(j) else { return }
        freeWorkers += 1
        let job = jobs[j]
        let i = job.intent
        if keyed(i), intents[i].inFlightJob == j {
            intents[i].inFlightJob = nil
            ledger.complete(i, value: (), now: now)
        }
        let answersCurrent = keyed(i) || job.attempt == intents[i].attempt
        if !intents[i].done, answersCurrent, now <= intents[i].waitingUntil {
            if profile.responseLossRate > 0, rng.nextUnit() < profile.responseLossRate {
                // Committed server-side, but the client never hears back; its timeout will fire.
                reports[intents[i].traffic]?.lostResponses += 1
            } else {
                succeed(i, now: now)
            }
        }
        dispatch(now: now)
    }

    mutating func dispatch(now: Int64) {
        while freeWorkers > 0, let job = queue.pop() {
            let i = job.intent
            guard intents.indices.contains(i) else { continue }
            if setup.dropExpiredOnDequeue {
                let stale = intents[i].done
                    || intents[i].waitingUntil < now
                    || (!keyed(i) && job.attempt != intents[i].attempt)
                if stale {
                    // Never executed, so dropping is safe. Release the claim so a later retry runs it.
                    if intents[i].inFlightJob == job.id {
                        intents[i].inFlightJob = nil
                        ledger.abandon(i)
                    }
                    reports[intents[i].traffic]?.droppedExpired += 1
                    continue
                }
            }
            freeWorkers -= 1
            intents[i].executions += 1
            if intents[i].executions > 1 { reports[intents[i].traffic]?.duplicateExecutions += 1 }
            reports[intents[i].traffic]?.executions += 1
            busyMillis = Saturating.add(busyMillis, job.service)
            schedule(Saturating.add(now, job.service), .completion(job: job.id))
        }
    }
}
