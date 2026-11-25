# AgentAdmission

**Your backend's newest client is Siri AI. It doesn't tap: it bursts, and it retries. AgentAdmission is the admission-control and idempotency layer that keeps people's taps fast when that traffic arrives, and makes sure an agent's retried write runs at most once.**

[![CI](https://github.com/rajatslakhina/agent-traffic-admission-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/agent-traffic-admission-kit/actions/workflows/ci.yml)
![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![iOS 17+ · macOS 14+ · Linux](https://img.shields.io/badge/iOS%2017%2B%20%C2%B7%20macOS%2014%2B%20%C2%B7%20Linux-blue)

Demo app: (added after the companion repo is pushed — see below)

| Launch-day burst, same traffic, same 8 workers | Sized for taps (class-blind FIFO) | **AgentAdmission** (class-aware) |
|---|---|---|
| Interactive UI p99 | 4,255 ms | **92 ms** |
| Interactive UI intents that succeeded | 73.2% | **100%** |
| Interactive UI requests shed | 1,395 | **0** |
| Writes executed more than once (double charges) | 486 | **0** |
| Siri AI intents that succeeded | 40.9% | **69.9%** |

*These numbers come from `LaunchDaySimulator.run(profile: .launchDay, …)`. A golden test pins every simulation result on this page, and the full tables are [below](#the-numbers).*

## Why this matters

Apple has [opened Siri AI to all developers](https://developer.apple.com/news?id=gdk2umrf) in the iOS 27.3 beta. [Many expect](https://macworld.com/article/3276244/with-ios-27-3-the-siri-ai-floodgates-are-about-to-open.html) a flood of App Intents–based skills when it ships. That brings a new kind of client to endpoints that were sized for people:

- **It arrives in bursts.** One feature launch or one viral "ask Siri to reorder" moment, and thousands of assistants plan the same tool call in the same minute.
- **It retries differently.** A person taps once and waits. An agent framework retries on a timer, often with no jitter and no idea what `Retry-After` means.
- **Its failures are spoken.** When a call fails, Siri has to say *something*. "Something went wrong" after a payment is the worst thing it could say.

The result is a priority inversion:

1. Agent traffic fills the one FIFO queue.
2. People's taps wait behind it, and people time out.
3. Agents retry into the same queue.
4. Every timed-out write that is retried without a key runs twice.

No single request is buggy. The problem lies in how the system is designed, so this package solves it at that level.

## Where it runs

`Gateway` is a **single-process reference implementation** of the server side. You can run it in a server-side Swift process (Vapor, Hummingbird) or port it to your backend's language. CI builds and tests it on Linux as well as macOS. The demo app runs it in-process so you can watch it work on a phone.

The pure parts do no I/O, so a fleet port changes storage, not logic: `ClassAwarePolicy`, `IdempotencyLedger`, `ScopeAuthority`, `TokenBucket`. The client-side pieces belong in the iOS app: `IdempotencyKey`, `IntentKeyCache` (and its actor wrapper `IntentKeys`, on `WallClock`), `RetryPolicy`, `FallbackPresenter`.

## Design

```
 App entry point                 Server (Gateway actor)
 ───────────────                 ──────────────────────────────────────────────────────────
 SwiftUI tap      ─┐
 AppIntent.perform ─┼─ token + capability + key ─▶ 1 ScopeAuthority  who is this, really?
 Widget timeline  ─┘   (key outlives perform(),     2 write without key? reject
                        see IntentKeyCache)         3 IdempotencyLedger  replay / join / conflict
                                                     4 claim key (full ledger → shed)
                                                     5 ClassAwarePolicy   shed in tier order, buckets
                                                       → run handler
                                                     6 complete / abandon → wake joiners
 FallbackPresenter ◀── GatewayOutcome ───────────────┘
 ("this request didn't go through. Try again in about 3 seconds.")
```

### Decisions and the alternatives they beat

**1. Shed by traffic class in a fixed order, not by arrival.** There are four tiers. The lowest is shed first:

1. agent reads
2. widgets
3. agent writes
4. interactive UI

Each tier has a load depth past which it may not add work: `8 / 16 / 32 / 256` by default. In the simulator, the wait queue also serves higher tiers first. The live `Gateway` has no queue (see the limits below).

- *Rejected: one global rate limit.* It caps the total, but whoever arrives first wins, and during a burst that's the agents.
- *Rejected: dropping all agent traffic under load.* An agent write is a real person's spoken intent ("order my usual"). It should beat a widget refresh, which the system retries anyway.

You can check the order mechanically:

- `ShedOrderAudit` probes a policy at every depth from 0 to 512. It reports any depth where a lower tier is admitted while a higher tier is shed.
- `Configuration.validationIssues()` flags thresholds that would invert the order.
- `Gateway(validating:clock:)` refuses to start with them.

**2. One token bucket per (caller, kind), not per caller.** If Siri AI reads and writes shared one bucket, a read storm would spend the writes' budget. Agent writes would then be shed *more* often than agent reads, the opposite of decision 1. An early version of this package did exactly that, and the `testAgentReadsAreShedBeforeAgentWrites` simulator test caught it.

**3. The caller class comes from the token's grant, not from the request.** Each skill gets a grant with:

- one caller class
- a set of capabilities (`orders.write`, `menu.read`)
- an expiry
- an optional principal (user or device)

A grant can be revoked at any time. If a request claims `.interactiveUI` with a token issued to `.siriAgent`, it is **denied**, not silently corrected. A misrouted token fails loudly in development instead of quietly stealing priority in production.

- *Rejected: trusting an `X-Caller-Class` header.* That's a priority knob any client can turn.

**4. Idempotency keys name intents, not attempts. The ledger is scoped per principal and fails closed.**

- **The key must outlive `AppIntent.perform()`.** An assistant's retry is a fresh `perform()` call, so a key minted inside `perform()` would never deduplicate anything. `IntentKeyCache` returns the same key for the same intent signature until the intent succeeds or a time window passes.
- **Records are scoped.** Each record is keyed by `(principal, skill, capability, key)`. Another caller who presents your key can't read your stored result. The same key on a different capability is a different record.
- **Duplicates replay or join.** A completed record replays until its TTL expires. A concurrent duplicate **joins** the in-flight execution instead of running again.
- **Joining is bounded.** There are at most `maxWaitersPerKey` waiters, each waits at most `maxWaitMillis`, and cancelled waiters are removed. A waiter that stops waiting gets `.inProgress`, which tells the client to retry with the same key, never to start over.
- **A different payload is a conflict.** The same key with a different payload fingerprint is a **conflict**. Replaying the old result for a new request would be silently wrong.
- **Nothing unexpired is ever evicted, in flight or completed.** Evicting a completed record early would turn the retry of a lost response into a double charge. A full ledger sheds new writes instead of running them unprotected.

**5. No `await` between "is this key known?" and "this key is mine".** `Gateway` is an actor, and actor reentrancy happens only at suspension points.

- Authorization, ledger lookup, claiming the key and admission all run synchronously. The key is claimed before the policy runs, so a full ledger sheds without spending a bucket token, and a policy shed releases the claim.
- There are exactly two suspensions: the handler call, and a duplicate's wait for it. Neither sits between lookup and claim, and state is re-read after each.
- `testFiftyConcurrentRetriesOfOneWriteExecuteTheHandlerOnce` sends fifty concurrent copies of the same write, and the handler runs exactly once. A control test proves the same harness really does overlap handlers when there's no key.

**6. Shed strictly before execution, so the spoken fallback tells the truth about this attempt.** `FallbackPresenter` builds every sentence from what the outcome guarantees *for this attempt*. It never claims an earlier attempt did nothing, because it can't know that.

- A shed write says "this request didn't go through. Try again in about 5 seconds."
- `.inProgress` says the work is still running and won't be started again while it runs.
- An expired or revoked grant says the permission is no longer valid and asks the person to refresh it.
- A failed read says to try again; only a failed write says to check first.
- A handler failure guarantees nothing, so it says "It may not have finished, so open the app to check before trying again". Tests assert that this message never claims the request didn't go through.

**7. The simulator runs the shipped decision code.** `LaunchDaySimulator` is a deterministic discrete-event simulation: seeded SplitMix64, Poisson arrivals, integer milliseconds. It calls the same `ClassAwarePolicy.decide` and the same `IdempotencyLedger` (keyed by intent) that the live `Gateway` uses. The numbers on this page come from the code you'd deploy, not from a model of it.

### Failure modes handled

| Failure | What happens |
|---|---|
| Agent burst past capacity | Agent reads are shed first, with a drain-time `Retry-After`. Interactive UI is never shed in the launch-day run |
| Response lost after the server committed | A retry with the same key replays the stored result; the handler doesn't run again |
| 50 concurrent retries of one write | One handler run. The others join it, up to `maxWaitersPerKey`; the rest get `.inProgress` |
| In-flight execution hangs | Each joiner gives up after `maxWaitMillis` with `.inProgress`, and cancelled joiners are removed. The record itself has no lease (see limits) |
| Another principal presents your key | They get a separate record and can't read your result |
| Same key, different payload | `.rejected(.idempotencyConflict)`, and nothing runs |
| Handler throws | Not cached. Joiners get the failure, and the next retry runs again |
| Ledger full of unexpired records | The write is shed with a retry hint instead of running unprotected |
| Client gave up while queued *(simulator)* | The work is skipped at dequeue. It never ran, so this is safe |
| Token for another class or skill, expired, or revoked | Denied before anything else |
| Inverted shed thresholds | `Gateway(validating:)` throws `GatewayConfigurationError` |
| Clock goes backwards | Buckets ignore it instead of refunding tokens |
| Hostile inputs (`Int.max` seconds, NaN rates, zero workers, extreme counters) | Clamped. Every arithmetic path on the public API saturates, so nothing traps |

## The numbers

`TrafficProfile.launchDay` runs 90 seconds of traffic against 8 workers. Reads take 40 ms and writes take 80 ms.

- **Baseline:** 71 requests per second, with the workers about 40% busy.
- **Burst:** from 30 s to 60 s, Siri AI and Shortcuts traffic rises 10×. That puts the backend at about 110% of capacity before any retries.
- **Lost responses:** 0.5% of successful responses are lost in transit.
- **Client behaviour:** clients give up on an attempt after 1.5 s. People tap again once. Agents retry up to 4 attempts in total.

`setup: .sizedForTaps` is a class-blind FIFO queue, 256 deep, with no keys. Agents retry every 200 ms with no jitter.

```
caller         intents  ok     p50   p99  shed  timeout  replayed  dropped  dupExec
interactiveUI   4312  73.2%  40  4255  1395  1063  0  0  372
widget          813  70.7%  40  1481  137  101  0  0  0
shortcut        1074  42.1%  447  6485  1769  743  0  0  379
siriAgent       3615  40.9%  521  6435  6138  2494  0  0  1253
```

`setup: .classAware` is this package: ordered shedding and buckets, keys on every write, and agents that honour `Retry-After` with exponential backoff and 50% jitter.

```
caller         intents  ok     p50   p99  shed  timeout  replayed  dropped  dupExec
interactiveUI   4312  100%  40  92  0  23  4  0  19
widget          813  99.3%  40  87  0  5  0  0  0
shortcut        1074  62.9%  104  2546  2171  2  1  0  1
siriAgent       3615  69.9%  88  2475  6164  16  6  0  6
```

How to read the tables:

- **Latencies** are milliseconds from an intent's first attempt to its success.
- **`ok`** is rounded down to 0.1%, so `100%` means every intent succeeded.
- **`dupExec`** counts handler runs beyond the first for one intent. On the class-aware side, every one of them is a **read** retried after a lost response. Reads carry no key, and re-running a read is harmless. Duplicate **writes** are 486 vs 0.

Agent intents still fail under a 10× burst: 30.1% of Siri AI intents and 37.1% of Shortcuts intents. That is the design working as intended. They fail fast, before running, with an honest retry hint, instead of taking people down with them.

### Tests that would fail against a broken implementation

Each property above is tested alongside a broken counterpart:

- **Interactive SLO** (`p99 ≤ 300 ms`, at most 0.1% failures): the check passes for `.classAware`, and the *same* check is asserted to **fail** on `.sizedForTaps`.
- **Zero duplicate writes:** asserted to be 0 with keys. A second check confirms retries actually reached the ledger, because otherwise zero proves nothing. With keys switched off, the same traffic is asserted to produce a **non-zero** count.
- **Shed order:** the shipped policy passes `ShedOrderAudit`. A deliberately inverted policy and a misconfigured `ClassAwarePolicy` are both asserted to **fail** it.
- **At most one run under concurrency:** 50 concurrent same-key writes run once. The no-key control proves the harness really runs handlers concurrently (peak > 1).
- **No cross-principal replay:** a second principal who presents the same key and payload gets a fresh execution, not the first principal's result.
- **Fail closed:** a full ledger refuses new writes instead of evicting a live record. A tiny simulated ledger sheds more and still double-runs nothing.
- **Golden numbers:** `testGoldenNumbersQuotedInTheREADME` pins every simulation result quoted on this page and in the release notes. The profile's inputs (71 req/s, ~40% / ~110% load) are arithmetic on `TrafficProfile.launchDay`'s rates and service times.

## Usage

Server side:

```swift
import AgentAdmission

// Defaults: TTL 10 min (above the well-behaved agent's retry horizon), capacity 100,000 records,
// i.e. about 166 writes/s sustained before the ledger fails closed. Size both for your traffic.
let gateway = try Gateway<OrderReceipt>(validating: .init(), clock: MonotonicClock())

// When a user enables your Siri AI skill, issue it a narrow, class-bound grant.
let token = try await gateway.issue(
    skillID: "reorder-usual",
    caller: .siriAgent,
    capabilities: [Capability("orders", .write)],
    validForMillis: 60 * 60 * 1_000,
    principal: userID
).get()

let outcome = await gateway.handle(GatewayRequest(
    token: token, capability: Capability("orders", .write),
    claimedCaller: .siriAgent, idempotencyKey: key, fingerprint: order.digest
)) {
    try await orders.place(order)
}
```

App side. The key has to survive the assistant calling `perform()` again:

```swift
// One shared, actor-isolated cache for the process, on wall-clock time.
enum Keys { static let intents = IntentKeys(clock: WallClock()) }

// Inside AppIntent.perform():
let signature = "reorder:\(order.digest)"
let key = await Keys.intents.key(for: signature)              // same key on every retry
let outcome = try await api.reorder(order, idempotencyKey: key)
if case .success = outcome { await Keys.intents.clear(signature) } // the next reorder is a new intent

if let fallback = FallbackPresenter.fallback(for: outcome, kind: .write, action: "place your order") {
    return .result(dialog: IntentDialog(stringLiteral: fallback.spoken))
}
```

Add it with SwiftPM:

```swift
.package(url: "https://github.com/rajatslakhina/agent-traffic-admission-kit.git", from: "2.1.0")
```

## Honest limits

- **At most once, not exactly once.** The guarantee is at most one handler run per idempotency key, while its record is retained (TTL and capacity), within one process.
  - A shed write runs zero times.
  - A failed run isn't cached.
  - A crash between the handler committing and the ledger recording loses the record.
  - A real fleet needs the ledger and buckets in shared storage (Redis, DynamoDB conditional writes), with the handler's commit and the record written atomically.
- **Buckets are global per traffic class, not per user.** One user's runaway Shortcut can spend the whole class's budget. Per-user fairness (a second, keyed bucket layer) is the next thing I'd add.
- **Caller class is bound when the grant is issued, not attested.** This stops honest-but-buggy clients and confused-deputy agent paths from borrowing UI priority. It does not stop a malicious client that holds a UI token from replaying it on the agent path. That needs App Attest or similar.
- **Failures aren't cached.** That is correct only if the handler fails atomically. A handler that charges a card and then throws needs its own compensation. That's why the fallback text says "check before retrying".
- **TTL must outlive the retry horizon, and capacity must cover peak writes × TTL.** A retry that arrives after its record expired runs again; `RetryPolicy.horizonMillis(...)` tells you the horizon to compare against. A full ledger sheds writes (fails closed) rather than evicting records.
- **No lease on in-flight records.** A handler that never returns pins its key: retries get `.inProgress` indefinitely, the record holds a ledger slot, and it counts toward load. Bound handler time inside the handler; the ledger can't safely expire a claim whose work may still commit.
- **`IntentKeyCache` is in-memory.** Inside its window it treats identical requests as one until you call `clear` on success. If the system retries your intent in a fresh process, persist the cache and keep `WallClock` (a backwards reading reuses the key, erring toward dedup).
- **The live gateway has no wait queue.** It uses the count of executing handlers as its load signal, while the simulator models a real queue. The policy code is shared; only the load signal differs.
- **Simulated, not load-tested.** The numbers come from the deterministic simulator, not a production fleet. They show the shape of the effect; they are not a capacity plan.
- **`ManualClock` is `@unchecked Sendable`.** Its only state is guarded by an `NSLock` on every access.

## Verification

- `swift build -Xswiftc -warnings-as-errors` and `swift test` (94 XCTest cases) run clean from an empty `.build` on Xcode 27.2 / Swift 6.4.2.
- CI runs on every push to `main`, every `v*` tag and every pull request, with three jobs:
  - macOS build and test, with warnings treated as errors
  - Linux build and test, in a Swift 6.0 container
  - an iOS build with `xcodebuild … -destination 'generic/platform=iOS Simulator'`
- The [Actions tab](https://github.com/rajatslakhina/agent-traffic-admission-kit/actions) shows each job's current result.

## License

MIT
