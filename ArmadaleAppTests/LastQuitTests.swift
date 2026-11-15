import ArmadaleCore
import Darwin
import ArmadaleSessions
import Foundation
import Testing

/// Sessions macOS ends after a quit (docs/DESIGN.md section 8, "Background
/// App Activity"): the record written at quit, the verdict at the next
/// launch, and the login-session facts it compares. Reading the helper's
/// log is tested in ArmadaleSessions, through the real helper; the alerts
/// and the switch itself are checked live.
@Suite("Last quit record and check")
struct LastQuitTests {
    private let boot: Int64 = 1_794_000_000
    private let asid: Int32 = 100_017
    private let quitTime = Date(timeIntervalSince1970: 1_794_717_110.4)
    private let one = SessionID(raw: "aaaaaaaaaaaaaaaa")
    private let two = SessionID(raw: "bbbbbbbbbbbbbbbb")
    private let three = SessionID(raw: "cccccccccccccccc")

    private func quit(_ kind: LastQuitRecord.Kind = .user, sessions: [SessionID]? = nil) -> LastQuitRecord.Quit {
        LastQuitRecord.Quit(
            time: quitTime, kind: kind, bootTime: boot, auditSessionID: asid, sessions: sessions ?? [one, two])
    }

    private func at(_ offset: TimeInterval) -> Date { quitTime.addingTimeInterval(offset) }

    private func verdict(
        _ quit: LastQuitRecord.Quit, boot: Int64?? = nil, asid: Int32?? = nil,
        _ observations: [SessionID: LastQuitCheck.Observation]?
    ) -> LastQuitCheck.Verdict {
        LastQuitCheck.verdict(
            on: quit, bootTime: boot ?? self.boot, auditSessionID: asid ?? self.asid, observations: observations)
    }

    private func gone(terminatedAt: Date? = nil) -> LastQuitCheck.Observation {
        LastQuitCheck.Observation(isAlive: false, terminatedAt: terminatedAt)
    }

    private let alive = LastQuitCheck.Observation(isAlive: true)

    // MARK: Verdict

    @Test func aSIGTERMJustAfterTheQuitIsALoss() {
        // The log has whole seconds: 1 s before the quit to 10 s after it.
        // The quit is at …110.4, so the earliest counted line says …109.
        for offset: TimeInterval in [-1, -0.4, 0, 0.6, 1, 5, 10] {
            #expect(verdict(quit(), [one: gone(terminatedAt: at(offset))]) == .ended(1), "at \(offset) s")
        }
        for offset: TimeInterval in [-1.5, -60, 10.5, 30, 3600] {
            #expect(verdict(quit(), [one: gone(terminatedAt: at(offset))]) == .undetermined(.nothingFound), "at \(offset) s")
        }
        // A SIGTERM signal quit counts like the user's.
        #expect(verdict(quit(.signal), [one: gone(terminatedAt: at(1))]) == .ended(1))
    }

    @Test func endedCountsEveryRecordedSessionEndedSoAndBeatsOneAlive() {
        let all = quit(sessions: [one, two, three])
        #expect(verdict(all, [one: gone(terminatedAt: at(5)), two: gone(terminatedAt: at(5)), three: alive]) == .ended(2),
                "not every session: a force quit may not reach sessions of an earlier run")
        #expect(verdict(all, [one: gone(terminatedAt: at(5)), two: gone(terminatedAt: at(5)),
                              three: gone(terminatedAt: at(5))]) == .ended(3))
        // A session the observations miss counts as gone without a line.
        #expect(verdict(all, [one: gone(terminatedAt: at(1))]) == .ended(1))
        // Only recorded sessions count.
        #expect(verdict(quit(sessions: [one]), [one: alive, two: gone(terminatedAt: at(1))]) == .survived)
    }

    @Test func aliveWithoutALossSurvives() {
        #expect(verdict(quit(), [one: alive, two: gone()]) == .survived)
        // A SIGTERM long after the quit (the Dock's stop item a minute later,
        // a kill by hand) is no loss; another session alive says survived.
        #expect(verdict(quit(), [one: alive, two: gone(terminatedAt: at(60))]) == .survived)
    }

    @Test func nothingFoundIsUndetermined() {
        // Gone with no SIGTERM line: the helper's kill, a program that ended,
        // a pane closed since and its log removed.
        #expect(verdict(quit(), [one: gone(), two: gone()]) == .undetermined(.nothingFound))
        #expect(verdict(quit(), [:]) == .undetermined(.nothingFound))
    }

    @Test func theSystemsQuitAndEndSessionsAndQuitAreUndetermined() {
        let lost = [one: gone(terminatedAt: at(1))]
        #expect(verdict(quit(.system), lost) == .undetermined(.kindOfQuit), "logout, restart, shutdown")
        #expect(verdict(quit(.endedSessions), lost) == .undetermined(.kindOfQuit))
    }

    @Test func aRestartOrALogoutSinceIsUndetermined() {
        let lost = [one: gone(terminatedAt: at(1))]
        #expect(verdict(quit(), boot: boot + 3600, lost) == .undetermined(.newLoginSession), "restarted")
        #expect(verdict(quit(), asid: asid + 1, lost) == .undetermined(.newLoginSession), "logged out and in")
        #expect(verdict(quit(), boot: .some(nil), lost) == .undetermined(.newLoginSession), "boot time unknown now")
        #expect(verdict(quit(), asid: .some(nil), lost) == .undetermined(.newLoginSession))
        var unrecorded = quit()
        unrecorded.bootTime = nil
        #expect(verdict(unrecorded, lost) == .undetermined(.newLoginSession))
        unrecorded = quit()
        unrecorded.auditSessionID = nil
        #expect(verdict(unrecorded, lost) == .undetermined(.newLoginSession))
        // The boot time moves a little when the clock is set: the same boot.
        #expect(verdict(quit(), boot: boot + 30, lost) == .ended(1))
        #expect(verdict(quit(), boot: boot - LastQuitCheck.bootTimeTolerance, lost) == .ended(1))
        #expect(verdict(quit(), boot: boot + LastQuitCheck.bootTimeTolerance + 1, lost) == .undetermined(.newLoginSession))
    }

    @Test func noSessionsOrNoRuntimeIsUndetermined() {
        #expect(verdict(quit(sessions: []), [:]) == .undetermined(.noSessions))
        #expect(verdict(quit(), nil) == .undetermined(.noRuntime))
    }

    @Test func theCheckWaitsTwelveSecondsAfterTheQuit() {
        #expect(LastQuitCheck.dueDate(of: quit()) == at(12))
        // Longer than the system's latest kill (5 s) plus the window's end.
        #expect(LastQuitCheck.delay > LastQuitCheck.windowAfter)
    }

    @Test func lossSeenAtFollowsTheVerdict() {
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let q = quit()
        for late in [false, true] {
            #expect(LastQuitCheck.lossSeenAt(after: .ended(2), on: q, previous: nil, ranLate: late) == quitTime)
            #expect(LastQuitCheck.lossSeenAt(after: .ended(1), on: q, previous: earlier, ranLate: late) == quitTime)
            for reason in [LastQuitCheck.Undetermined.kindOfQuit, .newLoginSession, .noSessions, .noRuntime, .nothingFound] {
                #expect(LastQuitCheck.lossSeenAt(after: .undetermined(reason), on: q, previous: earlier, ranLate: late) == earlier)
                #expect(LastQuitCheck.lossSeenAt(after: .undetermined(reason), on: q, previous: nil, ranLate: late) == nil)
            }
        }
        #expect(LastQuitCheck.lossSeenAt(after: .survived, on: q, previous: earlier, ranLate: false) == nil)
        // A check that had to wait never clears it: whether macOS still ends
        // the old run's sessions once the app runs again is not known.
        #expect(LastQuitCheck.lossSeenAt(after: .survived, on: q, previous: earlier, ranLate: true) == earlier)
        #expect(LastQuitCheck.lossSeenAt(after: .survived, on: q, previous: nil, ranLate: true) == nil)
    }

    @Test func theScheduleRunsNowOrWaitsAtMostTheDelay() {
        let q = quit()
        #expect(LastQuitCheck.schedule(of: q, now: at(12)) == .now)
        #expect(LastQuitCheck.schedule(of: q, now: at(3600)) == .now)
        #expect(LastQuitCheck.schedule(of: q, now: at(2)) == .after(10))
        #expect(LastQuitCheck.schedule(of: q, now: at(11.5)) == .after(0.5))
        // A quit in the future (clock set back, hand-edited file): capped.
        #expect(LastQuitCheck.schedule(of: q, now: at(-3600)) == .after(LastQuitCheck.delay))
        var far = q
        far.time = Date(timeIntervalSince1970: 1e308)
        #expect(LastQuitCheck.schedule(of: far, now: Date()) == .after(LastQuitCheck.delay))
        far.time = Date(timeIntervalSince1970: -1e308)
        #expect(LastQuitCheck.schedule(of: far, now: Date()) == .now)
        far.time = Date(timeIntervalSince1970: .nan)
        #expect(LastQuitCheck.schedule(of: far, now: Date()) == .now, "never a NaN wait")
    }

    /// Values read from the file may be anything: no arithmetic on them traps.
    @Test func extremeValuesFromTheFileDoNotTrap() {
        let lost = [one: gone(terminatedAt: at(1))]
        for recorded in [Int64.min, Int64.max, -1, -1_794_000_000] {
            var q = quit()
            q.bootTime = recorded
            #expect(verdict(q, lost) == .undetermined(.newLoginSession), "\(recorded)")
            #expect(verdict(q, boot: .some(Int64.min), lost) == (recorded == Int64.min ? .ended(1) : .undetermined(.newLoginSession)))
            #expect(verdict(q, boot: .some(Int64.max), lost) == (recorded == Int64.max ? .ended(1) : .undetermined(.newLoginSession)))
        }
        #expect(!LastQuitCheck.sameBoot(Int64.min, Int64.max))
        #expect(!LastQuitCheck.sameBoot(Int64.max, Int64.min))
        #expect(LastQuitCheck.sameBoot(Int64.min, Int64.min + 60))
        #expect(!LastQuitCheck.sameBoot(Int64.min, Int64.min + 61))
        // Dates far away: compared, never computed into a trap.
        var far = quit()
        far.time = Date(timeIntervalSince1970: 1e308)
        #expect(verdict(far, [one: gone(terminatedAt: at(1))]) == .undetermined(.nothingFound))
        far.time = Date(timeIntervalSince1970: -1e308)
        #expect(verdict(far, [one: alive]) == .survived)
        // The decoder refuses what JSON cannot hold; an extreme finite time
        // and boot time decode.
        #expect(LastQuitRecord.decode(Data(#"{"version": 1, "quit": {"time": 1e400, "kind": "user", "sessions": []}}"#.utf8)) == nil)
        let extreme = LastQuitRecord.decode(Data(
            #"{"version": 1, "quit": {"time": 1e308, "kind": "user", "bootTime": -9223372036854775808, "auditSessionID": -2147483648, "sessions": []}}"#.utf8))
        #expect(extreme?.quit?.bootTime == Int64.min)
        #expect(LastQuitRecord.decode(Data(#"{"version": 1, "quit": {"time": 1, "kind": "user", "bootTime": 9223372036854775808, "sessions": []}}"#.utf8)) == nil,
                "out of range for Int64")
    }

    // MARK: Record and file

    @Test func theRecordRoundTripsAndOtherVersionsCountAsAbsent() throws {
        let record = LastQuitRecord(quit: quit(.signal, sessions: [one]), lossSeenAt: Date(timeIntervalSince1970: 1_794_000_123))
        #expect(LastQuitRecord.decode(try record.encoded()) == record)
        let evaluated = LastQuitRecord(quit: nil, lossSeenAt: Date(timeIntervalSince1970: 5))
        #expect(LastQuitRecord.decode(try evaluated.encoded()) == evaluated)
        let text = String(decoding: try record.encoded(), as: UTF8.self)
        #expect(text.contains("\"version\" : 1"), "\(text)")
        #expect(text.contains("\"endedSessions\"") == false && text.contains("\"signal\""))

        var newer = record
        newer.version = 2
        #expect(LastQuitRecord.decode(try newer.encoded()) == nil)
        #expect(LastQuitRecord.decode(Data("garbage".utf8)) == nil)
        #expect(LastQuitRecord.decode(Data(#"{"quit": null}"#.utf8)) == nil, "no version")
        #expect(LastQuitRecord.decode(Data(#"{"version": 1, "quit": {"kind": "elsewhere"}}"#.utf8)) == nil)
        #expect(LastQuitRecord.decode(Data(#"{"version": 1}"#.utf8)) == LastQuitRecord())
    }

    @Test func theStoreWritesReadsAndRemovesAnEmptyRecord() throws {
        let dir = try TemporaryStateDirectory()
        let store = dir.store
        #expect(store.url.lastPathComponent == "last-quit.json")
        #expect(store.read() == nil)
        let record = LastQuitRecord(quit: quit(), lossSeenAt: nil)
        try store.write(record)
        #expect(store.read() == record)
        // After the check: the quit goes, a loss stays.
        let loss = LastQuitRecord(quit: nil, lossSeenAt: quitTime)
        try store.write(loss)
        #expect(store.read() == loss)
        // Neither: the file goes; removing it twice is fine.
        try store.write(LastQuitRecord())
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
        try store.write(LastQuitRecord())
        try Data("garbage".utf8).write(to: store.url)
        #expect(store.read() == nil)
    }

    @Test func theRecordWrittenAtQuitCarriesTheLossAndEmptiesEndedSessions() throws {
        let loss = Date(timeIntervalSince1970: 1_790_000_000)
        let user = LastQuitRecord.atQuit(quit(.user, sessions: [one, two]), lossSeenAt: loss)
        #expect(user.quit == quit(.user, sessions: [one, two]))
        #expect(user.lossSeenAt == loss, "carried over from the run")
        #expect(LastQuitRecord.atQuit(quit(.signal), lossSeenAt: nil).quit?.sessions == [one, two])
        let ended = LastQuitRecord.atQuit(quit(.endedSessions, sessions: [one]), lossSeenAt: loss)
        #expect(ended.quit?.sessions == [], "End Sessions and Quit ended them")
        #expect(ended.quit?.kind == .endedSessions)
        #expect(ended.lossSeenAt == loss)
        // Written and read back through the store.
        let dir = try TemporaryStateDirectory()
        try dir.store.write(user)
        #expect(dir.store.read() == user)
    }

    @Test func theRecordAfterACheckDropsTheQuit() {
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let q = quit()
        #expect(LastQuitCheck.recordAfterCheck(.ended(1), on: q, previous: nil, ranLate: false)
            == LastQuitRecord(quit: nil, lossSeenAt: quitTime))
        #expect(LastQuitCheck.recordAfterCheck(.survived, on: q, previous: earlier, ranLate: false) == LastQuitRecord())
        #expect(LastQuitCheck.recordAfterCheck(.survived, on: q, previous: earlier, ranLate: true)
            == LastQuitRecord(quit: nil, lossSeenAt: earlier))
        #expect(LastQuitCheck.recordAfterCheck(.undetermined(.noRuntime), on: q, previous: earlier, ranLate: false)
            == LastQuitRecord(quit: nil, lossSeenAt: earlier))
    }

    /// The check against files: a runtime directory with a log holding the
    /// SIGTERM line, one with a live socket, and none; the record written
    /// back, or removed when nothing is left.
    @Test func runningTheCheckAgainstFiles() throws {
        let dir = try TemporaryStateDirectory()
        let runtime = ZmxRuntime(directory: dir.url.path + "/run")
        try runtime.prepare()
        try FileManager.default.createDirectory(atPath: runtime.logDirectory, withIntermediateDirectories: true)
        // The quit happened now-ish; one session's log has the line 1 s after.
        // Whole seconds, so it survives the file's round trip exactly.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        var q = quit(sessions: [one, two])
        q.time = now
        let line = "[\(Int64(now.timeIntervalSince1970) + 1)] [info] (default): SIGTERM received, shutting down gracefully session=a-\(one.raw)\n"
        try line.write(toFile: runtime.logDirectory + "/a-\(one.raw).log", atomically: true, encoding: .utf8)
        try dir.store.write(LastQuitRecord(quit: q, lossSeenAt: nil))

        let ended = LastQuitCheck.run(
            on: q, store: dir.store, runtime: runtime, previous: nil, ranLate: false, bootTime: boot, auditSessionID: asid)
        #expect(ended.verdict == .ended(1))
        #expect(ended.lossSeenAt == now)
        #expect(ended.writeError == nil)
        #expect(dir.store.read() == LastQuitRecord(quit: nil, lossSeenAt: now), "the quit is gone, the loss kept")

        // Without the runtime: undetermined, the quit removed all the same.
        try dir.store.write(LastQuitRecord(quit: q, lossSeenAt: now))
        let noRuntime = LastQuitCheck.run(
            on: q, store: dir.store, runtime: nil, previous: now, ranLate: false, bootTime: boot, auditSessionID: asid)
        #expect(noRuntime.verdict == .undetermined(.noRuntime))
        #expect(dir.store.read() == LastQuitRecord(quit: nil, lossSeenAt: now))

        // A live session (its socket, no exit record) and no SIGTERM line:
        // survived, the loss cleared and the file removed.
        let socket = try UnixSocket(path: runtime.socketPath(for: two))
        defer { socket.close() }
        let alive = quit(sessions: [two])
        try dir.store.write(LastQuitRecord(quit: alive, lossSeenAt: now))
        let survived = LastQuitCheck.run(
            on: alive, store: dir.store, runtime: runtime, previous: now, ranLate: false, bootTime: boot, auditSessionID: asid)
        #expect(survived.verdict == .survived)
        #expect(survived.lossSeenAt == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.store.url.path))
        // The same found by a late check keeps the loss.
        try dir.store.write(LastQuitRecord(quit: alive, lossSeenAt: now))
        let late = LastQuitCheck.run(
            on: alive, store: dir.store, runtime: runtime, previous: now, ranLate: true, bootTime: boot, auditSessionID: asid)
        #expect(late.verdict == .survived)
        #expect(late.lossSeenAt == now)
        #expect(dir.store.read() == LastQuitRecord(quit: nil, lossSeenAt: now))
    }

    @Test func theKindOfQuit() {
        #expect(AppDelegate.kindOfQuit(isSignal: false, isSystem: false, sessionsEnded: false) == .user)
        #expect(AppDelegate.kindOfQuit(isSignal: true, isSystem: false, sessionsEnded: false) == .signal)
        #expect(AppDelegate.kindOfQuit(isSignal: false, isSystem: true, sessionsEnded: false) == .system)
        #expect(AppDelegate.kindOfQuit(isSignal: false, isSystem: false, sessionsEnded: true) == .endedSessions)
        // SIGTERM wins: logout's signal after End Sessions and Quit started.
        #expect(AppDelegate.kindOfQuit(isSignal: true, isSystem: true, sessionsEnded: true) == .signal)
        #expect(AppDelegate.kindOfQuit(isSignal: false, isSystem: true, sessionsEnded: true) == .system)
    }

    // MARK: Login session

    @Test func theBootTimeAndAuditSessionAreReadAndStable() throws {
        let boot = try #require(LoginSession.bootTime())
        #expect(boot > 1_600_000_000)
        #expect(TimeInterval(boot) < Date().timeIntervalSince1970)
        #expect(LoginSession.bootTime() == boot)
        let session = try #require(LoginSession.auditSessionID())
        #expect(LoginSession.auditSessionID() == session)
    }
}

/// A short state directory of the test's own under `/tmp` (socket paths are
/// limited to 104 bytes), removed when the value goes.
final class TemporaryStateDirectory {
    let url: URL
    var store: LastQuitStore { LastQuitStore(stateDirectory: url) }
    init() throws {
        let random = String(UInt32.random(in: 0...UInt32.max), radix: 36)
        url = URL(fileURLWithPath: "/tmp/armadale-test-\(getpid())-\(random)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    deinit {
        if url.path.hasPrefix("/tmp/armadale-test-") { try? FileManager.default.removeItem(at: url) }
    }
}

/// A bound Unix socket at `path`: what a live daemon leaves in the runtime
/// directory.
struct UnixSocket {
    let descriptor: Int32
    let path: String

    init(path: String) throws {
        self.path = path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func close() {
        Darwin.close(descriptor)
        unlink(path)
    }
}
