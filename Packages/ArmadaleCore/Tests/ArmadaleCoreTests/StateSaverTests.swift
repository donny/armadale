import Foundation
import Testing
@testable import ArmadaleCore

/// Timing margins: every positive assertion waits at least 250 ms beyond
/// the moment the write is due. Negative assertions ("not written yet") are
/// safe at any margin because timers never fire early.
@Suite("StateSaver", .serialized)
@MainActor
struct StateSaverTests {
    private func state(_ name: String) -> PersistedState {
        var state = PersistedState()
        state.workspaces = [Workspace(name: name)]
        return state
    }

    private struct Boom: Error {}

    @Test func burstOfSchedulesWritesOnceWithLatestSnapshot() async throws {
        var written: [String] = []
        let saver = StateSaver(interval: .milliseconds(50)) { written.append($0.workspaces[0].name) }
        saver.schedule(state("1"))
        saver.schedule(state("2"))
        saver.schedule(state("3"))
        #expect(written.isEmpty)
        try await Task.sleep(for: .milliseconds(350))
        #expect(written == ["3"])
        #expect(saver.saveCount == 1)
        #expect(!saver.hasPending)
    }

    @Test func eachScheduleRestartsTheTimer() async throws {
        var written: [String] = []
        let saver = StateSaver(interval: .milliseconds(400)) { written.append($0.workspaces[0].name) }
        saver.schedule(state("1"))           // due at 400 ms
        try await Task.sleep(for: .milliseconds(250))
        saver.schedule(state("2"))           // restarts: due at 650 ms
        try await Task.sleep(for: .milliseconds(250))
        #expect(written.isEmpty, "at 500 ms: the first timer was cancelled, the second is not due")
        try await Task.sleep(for: .milliseconds(450))
        #expect(written == ["2"])             // at 950 ms, 300 ms after due
    }

    @Test func flushWritesImmediatelyAndCancelsTimer() async throws {
        var written: [String] = []
        let saver = StateSaver(interval: .milliseconds(50)) { written.append($0.workspaces[0].name) }
        saver.schedule(state("now"))
        saver.flush()
        #expect(written == ["now"])
        try await Task.sleep(for: .milliseconds(300))
        #expect(written == ["now"], "no second write after flush")
        saver.flush()
        #expect(written == ["now"], "flush with nothing pending is a no-op")
    }

    @Test func cancelDropsPendingSnapshot() async throws {
        var written: [String] = []
        let saver = StateSaver(interval: .milliseconds(30)) { written.append($0.workspaces[0].name) }
        saver.schedule(state("x"))
        saver.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(written.isEmpty)
    }

    @Test func failedWriteKeepsSnapshotAndReportsError() {
        var failures: [Int] = []
        let saver = StateSaver(interval: .milliseconds(10), retryDelay: { _ in .seconds(60) }) { _ in throw Boom() }
        saver.onWriteFailure = { _, count in failures.append(count) }
        saver.schedule(state("x"))
        saver.flush()
        #expect(saver.lastError is Boom)
        #expect(saver.saveCount == 0)
        #expect(saver.hasPending, "snapshot restored for retry")
        #expect(saver.consecutiveFailures == 1)
        #expect(failures == [1])
        saver.cancel()
    }

    @Test func retriesAfterBackoffAndRecovers() async throws {
        var attempts = 0
        var written: [String] = []
        let saver = StateSaver(interval: .milliseconds(10), retryDelay: { _ in .milliseconds(50) }) { state in
            attempts += 1
            if attempts < 3 { throw Boom() }
            written.append(state.workspaces[0].name)
        }
        saver.schedule(state("persist me"))
        saver.flush()                         // attempt 1 fails; retries at +50 ms, +100 ms
        #expect(attempts == 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(attempts == 3)
        #expect(written == ["persist me"])
        #expect(saver.lastError == nil)
        #expect(saver.consecutiveFailures == 0)
        #expect(!saver.hasPending)
    }

    /// A newer snapshot scheduled during the backoff replaces the failed
    /// one, and is written at the retry's time (not after the debounce:
    /// item 4 of the review, November 14, 2026).
    @Test func newerSnapshotWinsOverFailedOne() async throws {
        final class Switch { var fail = true }
        let failing = Switch()
        var written: [String] = []
        let saver = StateSaver(interval: .milliseconds(20), retryDelay: { _ in .milliseconds(150) }) { state in
            if failing.fail { throw Boom() }
            written.append(state.workspaces[0].name)
        }
        saver.schedule(state("old"))
        saver.flush()                         // fails, "old" pending with a 150 ms retry
        failing.fail = false
        saver.schedule(state("new"))          // replaces it; the retry's timer stays
        #expect(saver.isRetryPending)
        try await Task.sleep(for: .milliseconds(500))
        #expect(written == ["new"])
        #expect(!saver.isRetryPending)
    }

    @Test func exponentialBackoffSchedule() {
        let delays = (1...8).map { StateSaver.exponentialBackoff($0) }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
    }

    @Test func savesToDiskThroughStateStore() async throws {
        let dir = try TempDirectory()
        let saver = StateSaver(url: dir.stateFile, interval: .milliseconds(20))
        saver.schedule(state("disk"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(StateStore.load(from: dir.stateFile).state?.workspaces.map(\.name) == ["disk"])
    }

    // MARK: Longest wait

    @Test func delayIsTheDebounceCutShortByTheLongestWait() {
        let delay = { (elapsed: Int) in
            StateSaver.delay(elapsed: .milliseconds(elapsed), interval: .milliseconds(500), maximumDelay: .seconds(2))
        }
        #expect(delay(0) == .milliseconds(500))
        #expect(delay(1500) == .milliseconds(500))
        #expect(delay(1800) == .milliseconds(200))
        #expect(delay(2000) == .zero)
        #expect(delay(5000) == .zero)
    }

    /// With an injected clock: a later schedule never moves the write past
    /// the longest wait, counted from the first change not yet written, and
    /// a write starts the count again.
    @Test func laterSchedulesNeverMoveTheWritePastTheLongestWait() {
        final class Clock: @unchecked Sendable { var now = ContinuousClock.now }
        let clock = Clock()
        let start = clock.now
        var written: [String] = []
        let saver = StateSaver(
            interval: .milliseconds(500), maximumDelay: .seconds(2), now: { clock.now }
        ) { written.append($0.workspaces[0].name) }
        saver.schedule(state("0"))
        #expect(saver.lastScheduledDelay == .milliseconds(500))
        clock.now = start + .milliseconds(1200)
        saver.schedule(state("1"))
        #expect(saver.lastScheduledDelay == .milliseconds(500))
        clock.now = start + .milliseconds(1700)
        saver.schedule(state("2"))
        #expect(saver.lastScheduledDelay == .milliseconds(300))
        clock.now = start + .milliseconds(2600)
        saver.schedule(state("3"))
        #expect(saver.lastScheduledDelay == .zero)
        saver.flush()
        #expect(written == ["3"])
        clock.now = start + .milliseconds(2700)
        saver.schedule(state("4"))
        #expect(saver.lastScheduledDelay == .milliseconds(500), "the count starts again after a write")
        saver.cancel()
        clock.now = start + .seconds(9)
        saver.schedule(state("5"))
        #expect(saver.lastScheduledDelay == .milliseconds(500), "and after a cancel")
        saver.cancel()
    }

    /// While a retry is pending, a schedule replaces the snapshot and
    /// leaves the retry's timer alone; a flush still writes at once and
    /// ends the retry state, after which schedules debounce again.
    @Test func aScheduleDuringTheBackoffLeavesTheRetryTimerAlone() {
        final class Clock: @unchecked Sendable { var now = ContinuousClock.now }
        final class Switch { var fail = true }
        let clock = Clock(), failing = Switch()
        let start = clock.now
        var written: [String] = []
        var attempts = 0
        let saver = StateSaver(
            interval: .milliseconds(500), maximumDelay: .seconds(2), retryDelay: { _ in .seconds(60) },
            now: { clock.now }
        ) { state in
            attempts += 1
            if failing.fail { throw Boom() }
            written.append(state.workspaces[0].name)
        }
        saver.schedule(state("x"))
        #expect(saver.lastScheduledDelay == .milliseconds(500))
        clock.now = start + .seconds(5)
        saver.flush()
        #expect(saver.isRetryPending)
        for n in 1...5 {
            clock.now = start + .seconds(5 + n)
            saver.schedule(state("y\(n)"))
        }
        #expect(saver.lastScheduledDelay == .milliseconds(500), "no schedule set a timer during the backoff")
        #expect(saver.isRetryPending && saver.hasPending && attempts == 1)
        failing.fail = false
        saver.flush()                          // still at once
        #expect(written == ["y5"] && attempts == 2)
        #expect(!saver.isRetryPending)
        clock.now = start + .seconds(20)
        saver.schedule(state("z"))
        #expect(saver.lastScheduledDelay == .milliseconds(500), "debounce again after the retry state ends")
        saver.cancel()
        #expect(!saver.isRetryPending)
    }

    /// In real time: a steady stream of changes during the backoff neither
    /// brings the retry forward nor puts it off. With a 10 s longest wait
    /// and changes every 20 ms, a debounce would never fire within the
    /// 1.5 s stream; the 200 ms retry does.
    @Test func aSteadyStreamDuringTheBackoffDoesNotPutTheRetryOff() async throws {
        final class Switch { var fail = true }
        let failing = Switch()
        var attempts = 0
        var written: [String] = []
        let saver = StateSaver(
            interval: .milliseconds(200), maximumDelay: .seconds(10), retryDelay: { _ in .milliseconds(200) }
        ) { state in
            attempts += 1
            if failing.fail { throw Boom() }
            written.append(state.workspaces[0].name)
        }
        saver.schedule(state("first"))
        saver.flush()
        let failedAt = ContinuousClock.now
        failing.fail = false
        // Not earlier: changes right after the failure do not trigger an attempt.
        for n in 1...3 {
            saver.schedule(state("early\(n)"))
            try await Task.sleep(for: .milliseconds(20))
        }
        if ContinuousClock.now - failedAt < .milliseconds(200) {
            #expect(attempts == 1, "no attempt before the retry is due")
        }
        let end = ContinuousClock.now + .milliseconds(1500)
        var n = 0
        while ContinuousClock.now < end {
            n += 1
            saver.schedule(state("\(n)"))
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!written.isEmpty, "the retry wrote while changes kept coming")
        saver.cancel()
    }

    /// In real time, with margins that cannot flake: changes every 20 ms,
    /// far closer than the 300 ms debounce, for 3 s. Without a longest
    /// wait nothing would be written until they stop; with 600 ms several
    /// writes happen (about five), and at least two are required. A slow
    /// machine only spaces the changes further apart, which writes more.
    @Test func aSteadyStreamStillWritesWithinTheLongestWait() async throws {
        var written: [String] = []
        let saver = StateSaver(interval: .milliseconds(300), maximumDelay: .milliseconds(600)) {
            written.append($0.workspaces[0].name)
        }
        let end = ContinuousClock.now + .seconds(3)
        var n = 0
        while ContinuousClock.now < end {
            n += 1
            saver.schedule(state("\(n)"))
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(written.count >= 2, "\(written.count) writes")
        saver.flush()
        #expect(written.last == "\(n)")
    }
}
