# AgentAdmission

**Your backend's newest client is Siri AI. It doesn't tap, it bursts, and it retries. This package is the admission-control and idempotency layer that keeps people's taps fast and agents' writes exactly-once when that traffic arrives.**

[![CI](https://github.com/rajatslakhina/agent-traffic-admission-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/agent-traffic-admission-kit/actions/workflows/ci.yml)
![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![iOS 17+ · macOS 14+](https://img.shields.io/badge/iOS%2017%2B%20%C2%B7%20macOS%2014%2B-blue)

Demo app: (added after the companion repo is pushed — see below)

| Launch-day burst, same traffic, same 8 workers | Sized for taps (class-blind FIFO) | **AgentAdmission** (class-aware) |
|---|---|---|
| Interactive UI p99 | 4,255 ms | **92 ms** |
| Interactive UI intents that succeeded | 73.2% | **100%** |
| Interactive UI requests shed | 1,395 | **0** |
| Writes executed more than once (double charges) | 486 | **0** |
| Siri AI intents that succeeded | 40.9% | **70.0%** |

*From `LaunchDaySimulator.run(profile: .launchDay, …)`; the test suite asserts the SLO and the zero, and the full tables are [below](#the-numbers).*

## Why this matters

iOS 27.3 opens Siri AI and App Intents–based skills to every developer. When that reaches the public, a new kind of client shows up at endpoints that were sized for people:

- **It arrives in bursts.** One feature launch, one viral "ask Siri to reorder" moment, and thousands of assistants plan the same tool call in the same minute.
- **It retries differently.** A person taps once and waits. An agent framework retries on a timer, often with no jitter and no idea what `Retry-After` means.
- **Its failures are spoken.** When the call fails, Siri has to say *something*, and "something went wrong" after a payment is the worst possible sentence.

The failure is a priority inversion: agent traffic fills the one FIFO queue, people's taps wait behind it, people time out, agents retry into the same queue, and every timed-out write that gets retried without a key runs twice. None of it is a bug in any single request. It's a system design problem, so this package treats it as one.

## Design

```
 App entry point                 Server (this package's Gateway actor)
 ───────────────                 ──────────────────────────────────────────────────────────
 SwiftUI tap      ─┐
 AppIntent.perform ─┼─ token + capability + key ─▶ 1 ScopeAuthority  who is this, really?
 Widget timeline  ─┘   (key minted at intent)       2 write without key? reject
                                                     3 IdempotencyLedger  replay / join / conflict
                                                     4 ClassAwarePolicy   shed in tier order, buckets
                                                     5 claim key → run handler (only await)
                                                     6 complete / abandon → wake joiners
 FallbackPresenter ◀── GatewayOutcome ───────────────┘
 ("Nothing was changed. Try again in about 3 seconds.")
```

### Decisions and the alternatives they beat

**1. Shed by traffic class in a fixed order, not by arrival.** Four tiers, shed lowest first: agent reads → widgets → agent writes → interactive UI. Each tier has a queue depth past which it may not add work (`8 / 16 / 32 / 256` by default), and the wait queue serves higher tiers first.
*Rejected: one global rate limit.* It caps the total, but whoever arrives first wins, and during a burst that's the agents. *Rejected: dropping all agent traffic under load.* An agent write is a real person's spoken intent ("order my usual"); it should beat a widget refresh, which the system retries anyway.
The order is a checked invariant, not a comment: `ShedOrderAudit` probes a policy at every depth from 0 to 512 and reports any depth where a lower tier is admitted while a higher one is shed, and `Configuration.validationIssues()` flags thresholds that would invert it.

**2. One token bucket per (caller, kind), not per caller.** If Siri AI reads and writes share one bucket, a read storm spends the writes' budget, and agent writes end up shed *more* than agent reads, which is the opposite of decision 1. An early version of this package did exactly that, and `testAgentReadsAreShedBeforeAgentWrites` caught it in the simulator.

**3. The caller class comes from the token's grant, not from the request.** Each skill gets a grant: one caller class, a set of capabilities (`orders.write`, `menu.read`), an expiry, revocable at any time. A request that claims `.interactiveUI` with a token issued to `.siriAgent` is **denied**, not silently corrected, so a misrouted token is loud in development instead of quietly stealing priority in production.
*Rejected: trusting a `X-Caller-Class` header.* That's a priority knob any client can turn.

**4. Idempotency keys name intents, not attempts, and the ledger never evicts in-flight work.** The device mints the key when the person (or the assistant on their behalf) decides to act and reuses it on every retry. The ledger:
- replays a completed key's result until its TTL expires;
- makes a concurrent duplicate **join** the in-flight execution instead of running again;
- treats the same key with a different payload fingerprint as a **conflict**, because replaying the old result for a new request would be silently wrong;
- never evicts an in-flight entry (that would let a retry run the write twice while the first is still running). When it's full of in-flight work it sheds instead of executing unprotected.

**5. No `await` between "is this key known?" and "this key is mine".** The `Gateway` is an actor, and actor reentrancy only happens at suspension points. Authorization, ledger lookup, admission and claiming the key are all synchronous; the handler call is the single `await`, and state is re-read after it. Fifty concurrent copies of the same write run the handler exactly once (`testFiftyConcurrentRetriesOfOneWriteExecuteTheHandlerOnce`), and a control test proves the same harness really does overlap handlers when there's no key.

**6. Shed strictly before execution, so the spoken fallback can tell the truth.** `FallbackPresenter` builds every sentence from what the outcome guarantees. A shed write says "Nothing was changed. Try again in about 5 seconds." A handler failure guarantees nothing, so it says "It may not have finished, so open the app to check before trying again", and the tests assert it never claims nothing happened.

**7. The simulator runs the shipped policy.** `LaunchDaySimulator` is a deterministic discrete-event simulation (seeded SplitMix64, Poisson arrivals, integer milliseconds) that calls the same `ClassAwarePolicy.decide` the live `Gateway` calls. The numbers in this README come from the code you'd deploy, not from a model of it.

### Failure modes handled

| Failure | What happens |
|---|---|
| Agent burst past capacity | Agent reads shed first with a drain-time `Retry-After`; UI keeps its queue position |
| Response lost after the server committed | Retry with the same key replays the stored result; no second execution |
| 50 concurrent retries of one write | One handler run; 49 join it |
| Same key, different payload | `.rejected(.idempotencyConflict)`, nothing runs |
| Handler throws | Not cached; joiners get the failure; the next retry runs again |
| Ledger full of in-flight work | Shed with a retry hint instead of running without protection |
| Client gave up while queued | Work skipped at dequeue (it never ran, so this is safe) |
| Token for another class or skill, expired, revoked | Denied before anything else |
| Clock goes backwards | Buckets ignore it instead of refunding tokens |
| Hostile config (`Int64.max`, NaN rates, zero workers) | Clamped; every arithmetic path is saturating, nothing traps |

## The numbers

`TrafficProfile.launchDay`: 90 s against 8 workers (reads 40 ms, writes 80 ms). Baseline is about 70 req/s, roughly 40% busy. From 30 s to 60 s, Siri AI and Shortcuts traffic goes up 10×, which puts the backend at about 110% before any retries. 0.5% of successful responses are lost in transit, and clients give up on an attempt after 1.5 s. People tap again once; agents retry up to 4 attempts.

`setup: .sizedForTaps`: class-blind FIFO (256 deep), no keys, agents retry every 200 ms with no jitter.

```
caller         intents  ok     p50   p99  shed  timeout  replayed  dropped  dupExec
interactiveUI   4312  73.2%  40  4255  1395  1063  0  0  372
widget          813  70.7%  40  1481  137  101  0  0  0
shortcut        1074  42.1%  447  6485  1769  743  0  0  379
siriAgent       3615  40.9%  521  6435  6138  2494  0  0  1253
```

`setup: .classAware`: this package. Ordered shedding and buckets, keys, agents honour `Retry-After` with exponential backoff and 50% jitter.

```
caller         intents  ok     p50   p99  shed  timeout  replayed  dropped  dupExec
interactiveUI   4312  100%  40  92  0  20  20  0  0
widget          813  99.3%  40  90  0  5  0  0  0
shortcut        1074  63.3%  101  2549  2149  3  3  0  0
siriAgent       3615  70.0%  86  2488  6118  16  13  0  0
```

Latencies are milliseconds from the intent's first attempt to its success; `ok` is rounded down to 0.1%, so `100%` means every intent succeeded. `dupExec` counts handler runs beyond the first for one intent (reads and writes); writes alone are 486 vs 0. Agent intents still fail under a 10× burst, about 30% of them, and that's the design working as intended: they fail fast, before execution, with an honest retry hint, instead of taking people down with them.

### Tests that would fail against a broken implementation

The properties above are enforced with a broken counterpart next to each one:

- **Interactive SLO** (`p99 ≤ 300 ms`, ≤ 0.1% failures): passes for `.classAware`, and the *same* check is asserted to **fail** on `.sizedForTaps`.
- **Zero duplicate writes:** asserted to be 0 with keys, with a check that retries actually reached the ledger (otherwise zero proves nothing), and asserted **non-zero** for the same traffic with keys switched off.
- **Shed order:** the shipped policy passes `ShedOrderAudit`; a deliberately inverted policy and a misconfigured `ClassAwarePolicy` are both asserted to **fail** it.
- **Exactly-once under concurrency:** 50 concurrent same-key writes run once; the no-key control proves the harness really runs handlers concurrently (peak > 1).
- **Dropping abandoned work:** a timeout-heavy scenario asserts drops happen, executions go *down*, and duplicates stay at 0, against the same run with dropping off.

## Usage

```swift
import AgentAdmission

let gateway = Gateway<OrderReceipt>(clock: MonotonicClock())

// When the app registers its Siri AI skill, issue it a narrow, class-bound grant.
let token = try await gateway.issue(
    skillID: "reorder-usual",
    caller: .siriAgent,
    capabilities: [Capability("orders", .write)],
    validForMillis: 60 * 60 * 1_000
).get()

// In AppIntent.perform(): mint the key once per intent, reuse it on every retry.
let key = IdempotencyKey.mint()
let outcome = await gateway.handle(GatewayRequest(
    token: token, capability: Capability("orders", .write),
    claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: order.digest
)) {
    try await orders.place(order)
}

if let fallback = FallbackPresenter.fallback(for: outcome, kind: .write, action: "place your order") {
    return .result(dialog: IntentDialog(stringLiteral: fallback.spoken))
}
```

Add it with SwiftPM:

```swift
.package(url: "https://github.com/rajatslakhina/agent-traffic-admission-kit.git", from: "1.0.0")
```

## Honest limits

- **The `Gateway` is a single-process actor.** It demonstrates the design and is fully tested, but a real fleet needs the ledger and buckets in shared storage (Redis, DynamoDB conditional writes). The pure `IdempotencyLedger` and `ClassAwarePolicy` are written so that port changes storage, not logic.
- **Buckets are global per traffic class, not per user.** One user's runaway Shortcut can spend the class budget for everyone. Per-user fairness (a second, keyed bucket layer) is the next thing I'd add.
- **Caller class is bound at grant time, not attested.** This stops honest-but-buggy clients and confused-deputy agent paths from borrowing UI priority. It does not stop a malicious client that holds a UI token from replaying it on the agent path; that needs App Attest or similar.
- **Failures aren't cached.** That's correct only if the handler fails atomically. A handler that charges a card and then throws needs its own compensation; the fallback text says "check before retrying" for exactly this reason.
- **TTL must outlive the retry horizon.** A retry that arrives after its key expired runs again. `RetryPolicy.horizonMillis(...)` computes the worst case so you can check the TTL against it; the gateway doesn't enforce it.
- **The live gateway has no wait queue.** It uses executing-handler count as the load signal. The simulator models a real queue. The policy code is shared; the load signal differs.
- **Simulated, not load-tested.** The numbers are from the deterministic simulator, not a production fleet. They show the shape of the effect; they're not a capacity plan.
- **`ManualClock` is `@unchecked Sendable`.** Its only state is guarded by an `NSLock` on every access.

## Verification

- `swift build -Xswiftc -warnings-as-errors` and `swift test` (71 XCTest cases) run clean from an empty `.build` on Xcode 27.2 / Swift 6.4.2, and both run in CI on every push.
- CI also builds the package for iOS with `xcodebuild … -destination 'generic/platform=iOS Simulator'`.
- See the [Actions tab](https://github.com/rajatslakhina/agent-traffic-admission-kit/actions) for each job's current result.

## License

MIT
