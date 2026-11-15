import ArmadaleCore
import ArmadaleSessions
import Darwin
import Foundation

/// What Armadale writes at quit so that the next launch can tell whether
/// macOS ended the sessions it left running (docs/DESIGN.md section 3,
/// "The last quit", and section 8, "Background App Activity"). The file is
/// `last-quit.json` beside `state.json`; it is not part of the state file.
/// A file that cannot be decoded, or of another ``version``, counts as
/// absent.
struct LastQuitRecord: Codable, Equatable, Sendable {
    static let fileName = "last-quit.json"
    static let currentVersion = 1

    var version = Self.currentVersion
    /// The last quit, until the launch check has run on it.
    var quit: Quit?
    /// The time of the last quit after which macOS was found to have ended
    /// sessions; cleared when a later quit's sessions are found alive.
    var lossSeenAt: Date?

    /// One quit.
    struct Quit: Codable, Equatable, Sendable {
        var time: Date
        var kind: Kind
        /// `kern.boottime` in seconds at the quit (``LoginSession``).
        var bootTime: Int64?
        /// The login session's audit session id at the quit.
        var auditSessionID: Int32?
        /// The local persistent sessions that may have been running at the
        /// quit (``CloseRisk/mayBeRunning(_:)``).
        var sessions: [SessionID]
    }

    /// What kind of quit it was.
    enum Kind: String, Codable, Sendable {
        /// A quit the user made that went straight through: the status
        /// menu's Quit, Keep Sessions Running, ⌘Q in menu bar mode, a quit
        /// with nothing running.
        case user
        /// SIGTERM.
        case signal
        /// A quit Apple event with a reason: log out, restart, shut down.
        case system
        /// The quit at the end of End Sessions and Quit.
        case endedSessions
    }

    /// The record in `data`; `nil` when it cannot be decoded or has another
    /// version.
    static func decode(_ data: Data) -> LastQuitRecord? {
        struct Header: Decodable { var version: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let header = try? decoder.decode(Header.self, from: data), header.version == currentVersion else {
            return nil
        }
        return try? decoder.decode(LastQuitRecord.self, from: data)
    }

    /// The record a quit writes: the quit (no sessions after End Sessions
    /// and Quit, which ended them) and the run's `lossSeenAt`, carried over.
    static func atQuit(_ quit: Quit, lossSeenAt: Date?) -> LastQuitRecord {
        var quit = quit
        if quit.kind == .endedSessions { quit.sessions = [] }
        return LastQuitRecord(quit: quit, lossSeenAt: lossSeenAt)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// `last-quit.json` in one state directory. Only a launch that uses its
/// state directory has one (``AppDelegate/lastQuitStore(plan:canSave:stateDirectory:)``):
/// a fatal or locked-out launch never reads, writes or removes the file.
struct LastQuitStore: Sendable {
    let url: URL

    init(stateDirectory: URL) {
        url = stateDirectory.appendingPathComponent(LastQuitRecord.fileName)
    }

    /// The record, or `nil` when there is none that this build can read.
    func read() -> LastQuitRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return LastQuitRecord.decode(data)
    }

    /// Writes `record` atomically, or removes the file when the record
    /// holds neither a quit nor a loss.
    func write(_ record: LastQuitRecord) throws {
        guard record.quit != nil || record.lossSeenAt != nil else {
            if unlink(url.path) != 0, errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        try record.encoded().write(to: url, options: .atomic)
    }
}

/// The check at the next launch (docs/DESIGN.md section 8, "Background App
/// Activity"): did macOS end the sessions the last quit left running? Pure;
/// the app gathers what it needs from files (no listing).
enum LastQuitCheck {
    /// The check runs no earlier than this long after the recorded quit:
    /// the system's kill comes up to 5 s after it, so a quicker relaunch
    /// could still find the sessions alive.
    static let delay: TimeInterval = 12
    /// A SIGTERM counts when logged between this long before the quit (the
    /// log has whole seconds) …
    static let windowBefore: TimeInterval = 1
    /// … and this long after it.
    static let windowAfter: TimeInterval = 10
    /// Two boot times this close are the same boot: `kern.boottime` moves
    /// when the clock is set, a restart moves it by the Mac's uptime.
    static let bootTimeTolerance: Int64 = 60

    /// What is known of one recorded session at the check.
    struct Observation: Equatable, Sendable {
        /// Alive by the local rule without a listing
        /// (`ZmxRuntime.isAliveWithoutListing`).
        var isAlive: Bool
        /// When its daemon last logged a SIGTERM, if it did.
        var terminatedAt: Date?
    }

    /// Why nothing can be said.
    enum Undetermined: String, Equatable, Sendable {
        /// The quit was the system's or followed End Sessions and Quit.
        case kindOfQuit = "kind of quit"
        /// The Mac was restarted, or the user logged out, since the quit.
        case newLoginSession = "new login session"
        /// No session was left running.
        case noSessions = "no sessions recorded"
        /// The persistent runtime is not available in this launch.
        case noRuntime = "no persistent runtime"
        /// None was ended by SIGTERM in the window and none is alive.
        case nothingFound = "nothing found"
    }

    enum Verdict: Equatable, Sendable {
        /// At least one recorded session was ended by SIGTERM in the window;
        /// carries how many.
        case ended(Int)
        /// None was ended that way and at least one is alive.
        case survived
        case undetermined(Undetermined)
    }

    /// When the check for `quit` may run.
    static func dueDate(of quit: LastQuitRecord.Quit) -> Date {
        quit.time.addingTimeInterval(delay)
    }

    /// When the check runs at a launch.
    enum Schedule: Equatable, Sendable {
        /// The quit is at least ``delay`` ago: run at once.
        case now
        /// A relaunch sooner than that: run after this many seconds, never
        /// more than ``delay`` (a quit time in the future, the clock set
        /// back, or a hand-edited file, waits no longer than that).
        case after(TimeInterval)
    }

    static func schedule(of quit: LastQuitRecord.Quit, now: Date) -> Schedule {
        let wait = dueDate(of: quit).timeIntervalSince(now)
        // The decoder refuses non-finite numbers; this keeps it so whatever
        // the source, since `min` with NaN would give NaN.
        guard wait.isFinite, wait > 0 else { return .now }
        return .after(min(wait, delay))
    }

    /// The verdict on `quit`. `observations` is `nil` when the persistent
    /// runtime is not available; a session missing from it counts as gone
    /// with no SIGTERM logged.
    static func verdict(
        on quit: LastQuitRecord.Quit, bootTime: Int64?, auditSessionID: Int32?,
        observations: [SessionID: Observation]?
    ) -> Verdict {
        switch quit.kind {
        case .system, .endedSessions: return .undetermined(.kindOfQuit)
        case .user, .signal: break
        }
        guard let recordedBoot = quit.bootTime, let bootTime, sameBoot(recordedBoot, bootTime),
              let recordedSession = quit.auditSessionID, recordedSession == auditSessionID
        else { return .undetermined(.newLoginSession) }
        guard !quit.sessions.isEmpty else { return .undetermined(.noSessions) }
        guard let observations else { return .undetermined(.noRuntime) }
        let earliest = quit.time.addingTimeInterval(-windowBefore)
        let latest = quit.time.addingTimeInterval(windowAfter)
        let seen = quit.sessions.map { observations[$0] ?? Observation(isAlive: false) }
        let ended = seen.count(where: { observation in
            guard let time = observation.terminatedAt else { return false }
            return time >= earliest && time <= latest
        })
        if ended > 0 { return .ended(ended) }
        if seen.contains(where: \.isAlive) { return .survived }
        return .undetermined(.nothingFound)
    }

    /// Whether two boot times are the same boot (within
    /// ``bootTimeTolerance``). Overflow-safe: the recorded one comes from a
    /// file that may hold anything.
    static func sameBoot(_ recorded: Int64, _ current: Int64) -> Bool {
        let (difference, overflow) = recorded.subtractingReportingOverflow(current)
        return !overflow && difference.magnitude <= bootTimeTolerance.magnitude
    }

    /// `lossSeenAt` after the verdict on `quit`: the quit's time when
    /// sessions were ended, cleared when they survived, else unchanged. A
    /// check that ran late (the launch came within ``delay`` of the quit)
    /// never clears it: whether macOS still ends the old run's sessions once
    /// the app is running again is not known, so *survived* there may only
    /// mean the relaunch came first.
    static func lossSeenAt(after verdict: Verdict, on quit: LastQuitRecord.Quit, previous: Date?, ranLate: Bool) -> Date? {
        switch verdict {
        case .ended: quit.time
        case .survived: ranLate ? previous : nil
        case .undetermined: previous
        }
    }

    /// The record written back after the check: the quit removed whatever
    /// the verdict (so a crash cannot run it twice), `lossSeenAt` by
    /// ``lossSeenAt(after:on:previous:ranLate:)``. `LastQuitStore.write`
    /// removes the file when nothing is left.
    static func recordAfterCheck(
        _ verdict: Verdict, on quit: LastQuitRecord.Quit, previous: Date?, ranLate: Bool
    ) -> LastQuitRecord {
        LastQuitRecord(quit: nil, lossSeenAt: lossSeenAt(after: verdict, on: quit, previous: previous, ranLate: ranLate))
    }
}

/// The boot and the login session a quit happened in, so that a later
/// launch can tell a restart or a logout in between.
enum LoginSession {
    /// `kern.boottime`, in seconds since 1970.
    static func bootTime() -> Int64? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return nil }
        return Int64(value.tv_sec)
    }

    /// This process's audit session id (`getaudit_addr`, `ai_asid`): one
    /// per login.
    static func auditSessionID() -> Int32? {
        var info = auditinfo_addr_t()
        guard getaudit_addr(&info, Int32(MemoryLayout<auditinfo_addr_t>.size)) == 0 else { return nil }
        return Int32(info.ai_asid)
    }
}

// MARK: Running the check and writing the record

extension LastQuitCheck {
    /// What a check did.
    struct Outcome {
        var verdict: Verdict
        /// `lossSeenAt` from now on.
        var lossSeenAt: Date?
        /// Writing the record back failed (logged, never shown).
        var writeError: (any Error)?
    }

    /// What is known of each recorded session, from files only: alive by
    /// the local rule without a listing, and its log's last SIGTERM. `nil`
    /// without the persistent runtime.
    static func observations(of quit: LastQuitRecord.Quit, in runtime: ZmxRuntime?) -> [SessionID: Observation]? {
        runtime.map { runtime in
            Dictionary(quit.sessions.map { id in
                (id, Observation(isAlive: runtime.isAliveWithoutListing(id), terminatedAt: runtime.lastTerminationSignal(for: id)))
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Runs the check once on `quit` and writes the record back
    /// (``recordAfterCheck(_:on:previous:ranLate:)``) into `store`.
    static func run(
        on quit: LastQuitRecord.Quit, store: LastQuitStore, runtime: ZmxRuntime?, previous: Date?, ranLate: Bool,
        bootTime: Int64?, auditSessionID: Int32?
    ) -> Outcome {
        let found = Self.verdict(
            on: quit, bootTime: bootTime, auditSessionID: auditSessionID, observations: observations(of: quit, in: runtime))
        let record = recordAfterCheck(found, on: quit, previous: previous, ranLate: ranLate)
        var writeError: (any Error)?
        do { try store.write(record) } catch { writeError = error }
        return Outcome(verdict: found, lossSeenAt: record.lossSeenAt, writeError: writeError)
    }
}
