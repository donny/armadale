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

    @Test func newerSnapshotWinsOverFailedOne() async throws {
        final class Switch { var fail = true }
        let failing = Switch()
        var written: [String] = []
        let saver = StateSaver(interval: .milliseconds(20), retryDelay: { _ in .seconds(60) }) { state in
            if failing.fail { throw Boom() }
            written.append(state.workspaces[0].name)
        }
        saver.schedule(state("old"))
        saver.flush()                         // fails, "old" pending with a 60 s retry
        failing.fail = false
        saver.schedule(state("new"))          // replaces it and restarts the short timer
        try await Task.sleep(for: .milliseconds(300))
        #expect(written == ["new"])
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
}
