import XCTest
@testable import AgentAdmission

final class LaunchDaySimulationTests: XCTestCase {
    // One run of each, shared: the simulator is deterministic, so re-running would only cost time.
    static let naive = LaunchDaySimulator.run(profile: .launchDay, setup: .sizedForTaps)
    static let aware = LaunchDaySimulator.run(profile: .launchDay, setup: .classAware)

    func testSummaryHasARowPerCaller() {
        let text = Self.aware.summary()
        print(Self.naive.summary())
        print(text)
        for caller in CallerClass.allCases { XCTAssertTrue(text.contains(caller.rawValue)) }
    }

    /// An overloaded interactive-only backend where clients time out while queued.
    private func timeoutHeavy(drop: Bool) -> SimulationReport {
        let profile = TrafficProfile(
            durationSeconds: 20, workers: 1, readServiceMillis: 100, writeServiceMillis: 100, clientTimeoutMillis: 300,
            baselineRates: [TrafficClass(.interactiveUI, .write): 15], burstStartSecond: 0, burstEndSecond: 0,
            burstMultiplier: 1, seed: 11
        )
        var config = ClassAwarePolicy.Configuration.standard
        config.shedDepth[.interactive] = 10_000
        var setup = SimulationSetup.classAware
        setup.policy = .classAware(config)
        setup.dropExpiredOnDequeue = drop
        return LaunchDaySimulator.run(profile: profile, setup: setup)
    }

    func testDroppingAbandonedQueuedWorkSavesExecutionsWithoutDoubleRunningWrites() {
        let dropping = timeoutHeavy(drop: true).report(for: TrafficClass(.interactiveUI, .write))
        let keeping = timeoutHeavy(drop: false).report(for: TrafficClass(.interactiveUI, .write))
        XCTAssertGreaterThan(dropping.timedOut, 0, "the scenario must actually time clients out")
        XCTAssertGreaterThan(dropping.droppedExpired, 0)
        XCTAssertEqual(keeping.droppedExpired, 0)
        XCTAssertLessThan(dropping.executions, keeping.executions)
        XCTAssertEqual(dropping.duplicateExecutions, 0)
        XCTAssertEqual(keeping.duplicateExecutions, 0)
        XCTAssertGreaterThanOrEqual(dropping.succeeded, keeping.succeeded)
    }

    func testHeadlineClassAwareKeepsTheInteractiveSLOThroughTheBurst() {
        XCTAssertEqual(Self.aware.violations(of: InteractiveSLO()), [])
    }

    /// The SLO check is only worth something if it fails on a backend that doesn't protect people.
    func testMutantTheSameSLOCheckFailsOnTheClassBlindBaseline() {
        XCTAssertFalse(Self.naive.violations(of: InteractiveSLO()).isEmpty)
    }

    func testHeadlineIdempotencyKeysMeanZeroDuplicateWrites() {
        XCTAssertEqual(Self.aware.duplicateWriteExecutions, 0)
        let writes = Self.aware.perClass.filter { $0.traffic.kind == .write }
        XCTAssertGreaterThan(writes.reduce(0) { $0 + $1.replayed }, 0, "retries must actually reach the ledger, or zero duplicates proves nothing")
    }

    /// Same traffic, same policy, keys switched off: the duplicate counter must light up.
    func testMutantWithoutKeysTheSameTrafficDoubleExecutesWrites() {
        var noKeys = SimulationSetup.classAware
        noKeys.idempotencyKeys = false
        noKeys.dropExpiredOnDequeue = false
        let report = LaunchDaySimulator.run(profile: .launchDay, setup: noKeys)
        XCTAssertGreaterThan(report.duplicateWriteExecutions, 0)
        XCTAssertGreaterThan(Self.naive.duplicateWriteExecutions, 0)
    }

    func testAgentReadsAreShedBeforeAgentWrites() {
        let reads = Self.aware.report(for: TrafficClass(.siriAgent, .read))
        let writes = Self.aware.report(for: TrafficClass(.siriAgent, .write))
        XCTAssertGreaterThan(reads.shed, 0, "the burst should force some shedding")
        let readShedRate = Double(reads.shed) / Double(max(1, reads.attempts))
        let writeShedRate = Double(writes.shed) / Double(max(1, writes.attempts))
        XCTAssertGreaterThan(readShedRate, writeShedRate)
        XCTAssertGreaterThan(writes.successRate, reads.successRate)
    }

    func testInteractiveTrafficIsNeverShedByTheClassAwarePolicy() {
        XCTAssertEqual(Self.aware.aggregate(.interactiveUI).shed, 0)
    }

    func testEveryIntentIsAccountedFor() {
        for report in [Self.naive, Self.aware] {
            for r in report.perClass {
                XCTAssertEqual(r.latencies.count, r.succeeded, "\(report.setupName) \(r.traffic)")
                XCTAssertLessThanOrEqual(r.succeeded, r.intents)
                XCTAssertGreaterThanOrEqual(r.attempts, r.intents)
                XCTAssertEqual(r.latencies, r.latencies.sorted())
            }
            XCTAssertFalse(report.truncated)
        }
    }

    func testDeterministicForASeedAndDifferentForAnother() {
        let again = LaunchDaySimulator.run(profile: .launchDay, setup: .classAware)
        XCTAssertEqual(again, Self.aware)
        var other = TrafficProfile.launchDay
        other.seed = 7
        XCTAssertNotEqual(LaunchDaySimulator.run(profile: other, setup: .classAware).perClass, Self.aware.perClass)
    }

    func testNoBurstMeansNoSheddingForAnyone() {
        var calm = TrafficProfile.launchDay
        calm.burstMultiplier = 1
        let report = LaunchDaySimulator.run(profile: calm, setup: .classAware)
        XCTAssertEqual(report.perClass.reduce(0) { $0 + $1.shed }, 0)
        XCTAssertEqual(report.violations(of: InteractiveSLO()), [])
    }

    func testEmptyAndHostileProfilesDoNotTrapOrRunAway() {
        let empty = TrafficProfile(durationSeconds: 0, workers: 0, readServiceMillis: 0, writeServiceMillis: -5,
                                   clientTimeoutMillis: -1, baselineRates: [:], burstStartSecond: -3, burstEndSecond: -9,
                                   burstMultiplier: .nan, seed: 0)
        let report = LaunchDaySimulator.run(profile: empty, setup: .classAware)
        XCTAssertEqual(report.perClass.reduce(0) { $0 + $1.intents }, 0)
        XCTAssertEqual(report.violations(of: InteractiveSLO()), ["no interactive traffic was simulated"])

        let hostile = TrafficProfile(durationSeconds: 600, workers: 1, readServiceMillis: 1, writeServiceMillis: 1,
                                     clientTimeoutMillis: 1_000, baselineRates: [TrafficClass(.siriAgent, .read): .infinity],
                                     burstStartSecond: 0, burstEndSecond: 0, burstMultiplier: 1, seed: 1)
        let capped = LaunchDaySimulator.run(profile: hostile, setup: .classAware)
        XCTAssertTrue(capped.truncated)
        XCTAssertLessThanOrEqual(capped.report(for: TrafficClass(.siriAgent, .read)).intents, TrafficProfile.maxArrivals)
    }

    func testTimelineCoversTheBurstWindow() {
        let peakDuringBurst = Self.naive.timeline.filter { (30..<60).contains($0.second) }.map(\.maxQueueDepth).max() ?? 0
        let peakBefore = Self.naive.timeline.filter { $0.second < 30 }.map(\.maxQueueDepth).max() ?? 0
        XCTAssertGreaterThan(peakDuringBurst, peakBefore)
    }
}
