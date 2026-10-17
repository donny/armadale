import ArmadaleCore
import Darwin
import Foundation
import Testing
@testable import ArmadaleSessions

/// Integration tests against the real, pinned zmx, each in a private
/// runtime directory. Every test kills the sessions it creates; the suite's
/// `deinit` kills anything left in the directory and removes it.
@Suite("LocalZmxBackend (real zmx)", .serialized)
final class LocalZmxBackendTests {
    let sandbox: ZmxSandbox
    var backend: LocalZmxBackend { sandbox.backend }
    let size = PTYSize(columns: 80, rows: 24)

    init() throws {
        sandbox = try ZmxSandbox(extraEnvironment: [
            // Must never reach zmx: a prefix would rename every session, and
            // ZMX_SESSION turns attach into a switch that kills that session.
            "ZMX_SESSION": "a-bogusbogusbogus", "ZMX_SESSION_PREFIX": "bogus-",
        ])
    }

    deinit {
        sandbox.tearDown()
    }

    private func marker(_ name: String) -> String {
        "\(name)-\(UInt32.random(in: 0...UInt32.max))"
    }

    @Test func createRecordsVersionAndTheFirstOutputHasThePrompt() async throws {
        let session = sandbox.session()
        let handle = try await backend.create(session, size: size)
        #expect(handle.runtimeVersion == ZmxVersion.current)
        let output = OutputCollector(handle.output)
        let text = await output.wait { $0.contains(ZmxSandbox.prompt) }
        // The `created` notice went to the dropped first client, not here.
        #expect(!text.contains("created"))
        #expect(output.bytes.starts(with: Array("\u{1b}[2J".utf8)), "\(text.debugDescription)")
        #expect(try await backend.liveSessions() == [session.id])
        #expect(sandbox.listedNames == ["a-" + session.id.raw])
        try await backend.kill(session.id)
        await output.waitForEnd()
    }

    /// Output the program writes before any client could connect is lost to
    /// the first client (zmx replays only to later ones); the double attach
    /// in `create` must still show it.
    @Test func createKeepsOutputWrittenBeforeTheFirstClientConnected() async throws {
        let early = marker("early")
        let session = sandbox.session(LaunchSpec(program: "/bin/zsh", arguments: ["-f", "-c", "echo \(early); exec /bin/zsh -f"]))
        for _ in 0..<3 {
            let handle = try await backend.create(session, size: size)
            let output = OutputCollector(handle.output)
            await output.wait { $0.contains(early + "\n") }
            try await backend.kill(session.id)
            await output.waitForEnd()
        }
    }

    @Test func detachKeepsTheSessionAndReattachReplaysAndResizes() async throws {
        let session = sandbox.session()
        let handle = try await backend.create(session, size: size)
        let output = OutputCollector(handle.output)
        await output.wait { $0.contains(ZmxSandbox.prompt) }
        let line = marker("marker")
        handle.write(Array("echo \(line); echo $$ > \(sandbox.directory)/pid\r".utf8))
        await output.wait { $0.contains(line + "\n") }
        let shellPID = try await readPID()

        // Simulate quitting the app: only the client goes.
        await handle.terminate()
        await output.waitForEnd()
        #expect(try await backend.liveSessions().contains(session.id))
        #expect(await backend.resolveExit(of: session) == .detached)
        #expect(kill(shellPID, 0) == 0, "the shell survives its client")

        var attached = session
        attached.runtimeVersion = ZmxVersion.current
        let again = try await backend.attach(attached, size: PTYSize(columns: 100, rows: 30))
        #expect(again.runtimeVersion == ZmxVersion.current)
        let replay = OutputCollector(again.output)
        await replay.wait { $0.contains(line + "\n") }
        #expect(replay.bytes.starts(with: Array("\u{1b}[2J".utf8)))

        // The same shell, at the attach size; then a resize reaches it.
        again.write(Array("echo pid=$$ size=$(stty size)\r".utf8))
        await replay.wait { $0.contains("pid=\(shellPID) size=30 100\n") }
        again.resize(PTYSize(columns: 132, rows: 43))
        try await Task.sleep(for: .milliseconds(200))
        again.write(Array("echo resized=$(stty size)\r".utf8))
        await replay.wait { $0.contains("resized=43 132\n") }

        try await backend.kill(session.id)
        await replay.waitForEnd()
        #expect(try await backend.liveSessions().isEmpty)
    }

    @Test func attachToAMissingSessionThrowsAndLeavesNothing() async throws {
        let session = sandbox.session()
        await #expect(throws: BackendError.noSuchSession(session.id)) {
            _ = try await backend.attach(session, size: size)
        }
        #expect(try await backend.liveSessions().isEmpty)
        #expect(sandbox.listedNames.isEmpty)
        #expect(await backend.resolveExit(of: session) == .ended)
    }

    @Test func programExitEndsTheSession() async throws {
        let session = sandbox.session()
        let handle = try await backend.create(session, size: size)
        let output = OutputCollector(handle.output)
        await output.wait { $0.contains(ZmxSandbox.prompt) }
        handle.write(Array("exit 7\r".utf8))
        // A zmx client's exit status means nothing, so none is reported.
        #expect(await handle.exitStatus == nil)
        await output.waitForEnd()
        #expect(await backend.resolveExit(of: session) == .ended)
        #expect(try await backend.liveSessions().isEmpty)
        #expect(try await backend.exists(session.id) == false)
        // The client's reset sequence ends the raw stream; the filter drops it.
        #expect(output.bytes.suffix(ZmxOutputFilter.detachSequence.count) == ZmxOutputFilter.detachSequence[...])
        let raw = output.bytes
        let shown = await MainActor.run {
            var filter = ZmxOutputFilter()
            return filter.filter(raw) + filter.finish()
        }
        #expect(!shown.isEmpty)
        #expect(!shown.suffix(ZmxOutputFilter.detachSequence.count).elementsEqual(ZmxOutputFilter.detachSequence))
    }

    @Test func killEndsALiveSessionAndToleratesAMissingOne() async throws {
        let session = sandbox.session()
        let handle = try await backend.create(session, size: size)
        let output = OutputCollector(handle.output)
        await output.wait { $0.contains(ZmxSandbox.prompt) }
        try await backend.kill(session.id)
        #expect(await handle.exitStatus == nil)
        await output.waitForEnd()
        #expect(try await backend.liveSessions().isEmpty)
        try await backend.kill(session.id)
        try await backend.kill(SessionID.generate())
    }

    @Test func sessionEnvironmentAndArgv0() async throws {
        let session = sandbox.session(directory: "/usr/share")
        let handle = try await backend.create(session, size: size)
        let output = OutputCollector(handle.output)
        await output.wait { $0.contains(ZmxSandbox.prompt) }
        let done = marker("done")
        handle.write(Array(
            "echo \"argv0=$0 pwd=$PWD id=$ARMADALE_SESSION_ID zmx-vars=[$(env | grep '^ZMX')] term=$TERM\"; echo \(done)\r".utf8))
        let text = await output.wait { $0.contains(done + "\n") }
        // No ZMX_* at all: not the runtime directory, not the detach-key
        // switch, not the ZMX_SESSION zmx itself sets (ctty-exec --unset).
        #expect(text.contains(
            "argv0=-zsh pwd=/usr/share id=\(session.id.raw) zmx-vars=[] term=xterm-256color\n"),
            "\(text)")
        // The argv[0] trampoline is silent in the daemon's child.
        #expect(!text.contains("ctty-exec"))
        // The prefix did not rename the session, and the inherited
        // ZMX_SESSION did not turn the attach into a switch.
        #expect(sandbox.listedNames == ["a-" + session.id.raw])
        try await backend.kill(session.id)
        await output.waitForEnd()
    }

    /// A program that exits before the client can attach for real: create
    /// reports it as a failure and leaves nothing behind.
    @Test func createOfAProgramThatExitsAtOnceFails() async throws {
        let session = sandbox.session(LaunchSpec(program: "/usr/bin/true"))
        do {
            let handle = try await backend.create(session, size: size)
            Issue.record("create returned a client for a program that exited: \(handle)")
        } catch let error as BackendError {
            guard case .runtimeFailure(let message) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(message.hasPrefix("The session ended as soon as it started."), "\(message)")
            #expect(!message.contains("zmx"))
        }
        #expect(try await backend.liveSessions().isEmpty)
    }

    @Test func historyOfALiveSessionIsVT() async throws {
        let session = sandbox.session()
        let handle = try await backend.create(session, size: size)
        let output = OutputCollector(handle.output)
        await output.wait { $0.contains(ZmxSandbox.prompt) }
        let line = marker("history")
        handle.write(Array("print -P \"%F{red}red%f \(line)\"\r".utf8))
        await output.wait { $0.contains(line + "\n") }
        let history = try await backend.history(session.id)
        let text = String(decoding: history, as: UTF8.self)
        #expect(text.contains(line))
        #expect(text.contains("\u{1b}["), "VT escapes are kept")
        try await backend.kill(session.id)
        await output.waitForEnd()
        await #expect(throws: BackendError.historyUnavailable(session.id)) {
            _ = try await backend.history(session.id)
        }
    }

    @Test func foreignSessionsInTheDirectoryAreIgnored() async throws {
        // Created with zmx directly, under a name Armadale never uses.
        let foreign = try PTYProcess.spawn(
            program: sandbox.zmx, arguments: ["attach", "work", "/bin/sleep", "60"],
            environment: sandbox.runtime.environment(base: testEnvironment()), size: size)
        let output = OutputCollector(foreign.output)
        #expect(await eventually { self.sandbox.listedNames.contains("work") })
        #expect(try await backend.liveSessions().isEmpty)
        await foreign.terminate()
        sandbox.zmxSync(["kill", "work"])
        await output.waitForEnd()
    }

    private func readPID() async throws -> pid_t {
        let path = sandbox.directory + "/pid"
        var text = ""
        _ = await eventually {
            text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return text.hasSuffix("\n")
        }
        return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

/// The session controller over real zmx: the end of a session shows as
/// ended without the client's reset reaching the surface, and a client
/// that merely died is replaced by a reattach.
@Suite("SessionController over real zmx", .serialized)
@MainActor
final class SessionControllerZmxTests {
    let sandbox: ZmxSandbox

    init() throws {
        sandbox = try ZmxSandbox()
    }

    deinit {
        sandbox.tearDown()
    }

    private func makeController(_ session: Session, surface: RecordingSurface) -> SessionController {
        SessionController(
            session: session, backend: sandbox.backend, makeSurface: { surface },
            makeOutputFilter: { ZmxOutputFilter() })
    }

    @Test func exitShowsEndedWithoutTheResetSequence() async throws {
        let surface = RecordingSurface()
        let controller = makeController(sandbox.session(), surface: surface)
        await controller.start(.create)
        #expect(controller.state == .attached)
        #expect(controller.session.runtimeVersion == ZmxVersion.current)
        #expect(await eventually { surface.text.contains(ZmxSandbox.prompt) })
        surface.delegate?.surface(surface, didInput: Array("echo bye-now; exit\r".utf8))
        #expect(await eventually { controller.state.isEnded })
        #expect(controller.state == .ended(exitCode: nil))
        #expect(surface.text.contains("bye-now"))
        #expect(!surface.text.contains("\u{1b}c"), "RIS must not reach the surface")
        #expect(sandbox.listedNames.isEmpty)
    }

    @Test func aDeadClientIsReplacedByAReattach() async throws {
        let surface = RecordingSurface()
        let session = sandbox.session()
        let controller = makeController(session, surface: surface)
        await controller.start(.create)
        #expect(await eventually { surface.text.contains(ZmxSandbox.prompt) })
        surface.delegate?.surface(surface, didInput: Array("echo before-$$\r".utf8))
        #expect(await eventually { surface.text.contains("before-") })
        // Kill the client process behind the controller's back.
        let clients = sandbox.zmxSync(["ls"]).output
        #expect(clients.contains("clients=1"))
        let pids = try clientPIDs(of: session)
        #expect(pids.count == 1)
        for pid in pids { kill(pid, SIGKILL) }
        // It comes back on its own: a fresh client, the same shell, a replay.
        #expect(try await eventually {
            let now = try self.clientPIDs(of: session)
            return now.count == 1 && now != pids
        })
        #expect(await eventually { controller.state == .attached && surface.text.contains("before-") })
        surface.delegate?.surface(surface, didInput: Array("echo after-reattach\r".utf8))
        #expect(await eventually { surface.text.contains("after-reattach\r\n") })
        await controller.close()
        #expect(sandbox.listedNames.isEmpty)
    }

    /// One second of `yes` against a renderer that cannot keep up. zmx's
    /// client buffers without limit, so without help the pane would work
    /// through the backlog for a minute or more while the client grows; the
    /// controller instead sees the client's footprint pass 16 MB, drops it
    /// and reattaches, and the pane shows the prompt after ^C within seconds.
    /// The flood runs until the client's footprint has passed the limit and
    /// the controller has reattached (or 15 s pass): on a loaded machine `yes`
    /// may need far longer than 1 s to fill the client's buffer. If it never
    /// gets there the mitigation was not exercised, which is recorded as a
    /// known issue rather than a failure.
    ///
    /// What the mitigation bounds is the backlog (under the limit), so after
    /// ^C the prompt arrives once that has been rendered. The test renderer
    /// is throttled to ~6 MB/s, which drains a full backlog in under 5 s;
    /// on a loaded machine it can be far slower (about 355 KB/s was measured
    /// with 12 busy loops). Then the 5 s bound cannot hold, which is recorded
    /// as a known issue with the measured rate, but the prompt must still
    /// arrive within 60 s.
    @Test func aFloodIsCutShortByReattaching() async throws {
        let limit = SessionController.defaultClientFootprintLimit
        let result = try await flood(
            footprintLimit: limit, timeout: .seconds(60), floodDuration: .seconds(15), stopOnceReattachedPast: limit)
        print("FLOOD WITH REATTACH: flooded for \(result.floodedFor); prompt after ^C: \(String(describing: result.promptAfter)); "
            + "drained \(result.drainRateKBps) KB/s; peak client RSS \(result.peakClientRSSKB) KB, "
            + "footprint \(result.peakClientFootprintKB) KB; reattaches \(result.reattaches)")
        guard result.peakClientFootprintKB * 1024 > limit || result.reattaches > 0 else {
            let why = "The flood never grew the client past \(limit / 1024 / 1024) MB within 15 s "
                + "(machine too busy to produce it); the reattach was not exercised."
            withKnownIssue(Comment(rawValue: why)) {
                Issue.record("peak footprint \(result.peakClientFootprintKB) KB")
            }
            return
        }
        #expect(result.reattaches >= 1)
        #expect(result.promptAfter != nil, "no prompt within 60 s of ^C")
        guard let promptAfter = result.promptAfter, promptAfter >= .seconds(5) else { return }
        let rendererCanDrainLimitIn5s = Double(result.drainRateKBps) * 1024 * 5 >= Double(limit)
        if rendererCanDrainLimitIn5s {
            Issue.record("prompt after \(promptAfter) although the renderer drained \(result.drainRateKBps) KB/s")
        } else {
            let why = "The renderer drained only \(result.drainRateKBps) KB/s (machine loaded), too slow to clear a "
                + "\(limit / 1024 / 1024) MB backlog in 5 s; the prompt came after \(promptAfter)."
            withKnownIssue(Comment(rawValue: why)) {
                Issue.record("prompt after \(promptAfter)")
            }
        }
    }

    /// The same without the mitigation, for comparison (slow; opt in with
    /// ARMADALE_FLOOD_BASELINE=1). Prints its measurements.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARMADALE_FLOOD_BASELINE"] != nil))
    func floodBaselineWithoutReattach() async throws {
        let seconds = Int(ProcessInfo.processInfo.environment["ARMADALE_FLOOD_BASELINE"] ?? "") ?? 300
        let result = try await flood(footprintLimit: nil, timeout: .seconds(seconds))
        print("FLOOD BASELINE: prompt after ^C: \(String(describing: result.promptAfter)); "
            + "peak client RSS \(result.peakClientRSSKB) KB, footprint \(result.peakClientFootprintKB) KB; reattaches \(result.reattaches)")
    }

    /// Fast output that the pane keeps up with (about 450 KB/s for 5 s, the
    /// rate of an animated full-screen UI) never grows the client, so it is
    /// never reattached: no reset, no lost scrollback.
    @Test func steadyFastOutputIsNeverReattached() async throws {
        let surface = RecordingSurface()
        let session = sandbox.session()
        let controller = makeController(session, surface: surface)
        await controller.start(.create)
        #expect(await eventually { surface.text.contains(ZmxSandbox.prompt) })
        let resetsBefore = surface.scrollbackClears
        let fedBefore = surface.fed.count
        let clock = ContinuousClock()
        let start = clock.now
        // 50 rounds of 450 lines of 100 bytes, 85 ms apart (about 450 KB/s).
        surface.delegate?.surface(surface, didInput: Array(
            "perl -e '$|=1; my $l = (\"x\" x 99) . \"\\n\"; for (1..50) { print $l x 450; select(undef,undef,undef,0.085) } print \"steady-\" . \"done\\n\"'\r".utf8))
        var peakFootprint: UInt64 = 0
        while clock.now - start < .seconds(20), !surface.text.contains("steady-done\r\n") {
            for pid in try clientPIDs(of: session) {
                peakFootprint = max(peakFootprint, ProcessFootprint.bytes(of: pid) ?? 0)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let elapsed = clock.now - start
        let bytes = surface.fed.count - fedBefore
        print("STEADY OUTPUT: \(bytes) bytes in \(elapsed) (≈ \(Int(Double(bytes) / 1024 / (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))) KB/s); "
            + "reattaches \(controller.floodReattaches); peak client footprint \(peakFootprint / 1024) KB")
        #expect(surface.text.contains("steady-done\r\n"))
        #expect(controller.floodReattaches == 0)
        #expect(surface.scrollbackClears == resetsBefore, "the pane was never reset")
        #expect(!String(decoding: surface.fed[fedBefore...], as: UTF8.self).contains("\u{1b}c"), "no RIS")
        #expect(bytes >= 50 * 450 * 100, "all output arrived: \(bytes)")
        await controller.close()
    }

    private struct FloodResult {
        var floodedFor: Duration
        var promptAfter: Duration?
        /// Output rendered per second between ^C and the prompt (or the timeout).
        var drainRateKBps: Int
        var peakClientRSSKB: Int
        var peakClientFootprintKB: UInt64
        var reattaches: Int
    }

    /// Floods a session with `yes`, then sends ^C and waits for the prompt.
    /// The flood lasts `floodDuration`, or, with `stopOnceReattachedPast`,
    /// only until a client's footprint has passed that many bytes and the
    /// controller has reattached at least once and is attached again (then
    /// a moment more).
    private func flood(
        footprintLimit: UInt64?, timeout: Duration, floodDuration: Duration = .seconds(1),
        stopOnceReattachedPast threshold: UInt64? = nil
    ) async throws -> FloodResult {
        let surface = RecordingSurface()
        let session = sandbox.session()
        let controller = makeController(session, surface: surface)
        controller.clientFootprintLimit = footprintLimit
        await controller.start(.create)
        #expect(await eventually { surface.text.contains(ZmxSandbox.prompt) })
        surface.feedDelay = 0.01 // at most ~6 MB/s, far below what yes produces
        surface.delegate?.surface(surface, didInput: Array("yes\r".utf8))
        var peak = 0
        var peakFootprint: UInt64 = 0
        func sample() throws {
            peak = max(peak, try clientRSS(of: session))
            for pid in try clientPIDs(of: session) {
                peakFootprint = max(peakFootprint, ProcessFootprint.bytes(of: pid) ?? 0)
            }
        }
        let clock = ContinuousClock()
        let floodStart = clock.now
        var reattachedAt: ContinuousClock.Instant?
        while clock.now - floodStart < floodDuration {
            try sample()
            if let threshold, peakFootprint > threshold, controller.floodReattaches > 0, controller.state.isAttached {
                // Input sent while the reattach is still connecting is not
                // delivered: wait until the new client is attached, then a
                // moment more, before interrupting.
                if let reattachedAt {
                    if clock.now - reattachedAt > .milliseconds(500) { break }
                } else {
                    reattachedAt = clock.now
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let floodedFor = clock.now - floodStart
        surface.delegate?.surface(surface, didInput: [0x03])
        let interrupted = clock.now
        let fedAtInterrupt = surface.fed.count
        var promptAfter: Duration?
        while clock.now - interrupted < timeout {
            try sample()
            let screen = surface.textSinceReset
            if let range = screen.range(of: "^C") ?? screen.range(of: "y\r\n" + ZmxSandbox.prompt),
               screen[range.upperBound...].contains(ZmxSandbox.prompt) {
                promptAfter = clock.now - interrupted
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let drainSeconds = (clock.now - interrupted).components
        let seconds = Double(drainSeconds.seconds) + Double(drainSeconds.attoseconds) / 1e18
        let drainRateKBps = seconds > 0 ? Int(Double(surface.fed.count - fedAtInterrupt) / 1024 / seconds) : 0
        surface.feedDelay = 0
        let reattaches = controller.floodReattaches
        await controller.close()
        return FloodResult(
            floodedFor: floodedFor, promptAfter: promptAfter, drainRateKBps: drainRateKBps, peakClientRSSKB: peak, peakClientFootprintKB: peakFootprint / 1024,
            reattaches: reattaches)
    }

    /// The largest resident size, in KB, of `session`'s attached clients.
    private func clientRSS(of session: Session) throws -> Int {
        let pids = try clientPIDs(of: session)
        guard !pids.isEmpty else { return 0 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int($0) }.max() ?? 0
    }

    /// PIDs of `zmx attach a-<id> /usr/bin/true`-style clients of `session`
    /// (not the daemon, whose parent is launchd).
    private func clientPIDs(of session: Session) throws -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let name = "a-" + session.id.raw
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, fields[2].contains("attach \(name)"), fields[1] != "1" else { return nil }
            return pid_t(fields[0])
        }
    }
}
