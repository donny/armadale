import Darwin
import ArmadaleCore
import Foundation
import Testing
@testable import ArmadaleSessions

/// `ctty-exec --exit-file`, the recorder zmx runs around a local session's
/// program (docs/DESIGN.md sections 4 and 7), on real PTYs. The recorder is
/// started the way zmx starts it: as a session leader whose controlling
/// terminal is the PTY (through the `ctty-exec` trampoline `PTYProcess`
/// uses), with the program as its child. zsh and bare programs only (see
/// ``PTYProcessTests``).
@Suite("ctty-exec exit recorder", .serialized)
struct ExitRecorderTests {
    let directory: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "armadale-exit-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    private var exitFile: String { directory + "/a-abcdefghijklmnop.exit" }

    /// The recorder running `program` (with `argv0`) on a new PTY.
    private func record(_ program: String, argv0: String, _ arguments: [String] = []) throws -> PTYProcess {
        let helper = try HelperLocator.cttyExec(environment: [:]).path
        return try PTYProcess.spawn(
            program: helper,
            arguments: ["--unset", "ARMADALE_HIDDEN", "--exit-file", exitFile, program, argv0] + arguments,
            environment: testEnvironment(["ARMADALE_HIDDEN": "1"]),
            size: PTYSize(columns: 80, rows: 24))
    }

    private var recorded: String? {
        (try? String(contentsOfFile: exitFile, encoding: .utf8))
    }

    /// The file is complete when it appears (written then renamed).
    private func recordedStatus() async -> ProgramExit? {
        _ = await eventually(timeout: .seconds(5)) { recorded != nil }
        return recorded.flatMap { ZmxRuntime.parseExitRecord($0) }
    }

    @Test func aCleanExitIsRecordedAsZero() async throws {
        let process = try record("/bin/zsh", argv0: "zsh", ["-f", "-c", "exit 0"])
        let output = OutputCollector(process.output)
        #expect(await process.termination == .exited(0))
        #expect(recorded == "0\n")
        #expect(!FileManager.default.fileExists(atPath: exitFile + ".tmp"))
        await output.waitForEnd()
    }

    /// The program gets argv[0] as given (`-zsh`, a login shell) and the
    /// environment without the `--unset` variables, exactly as an exec
    /// would; its status is recorded and becomes the recorder's own.
    @Test func aStatusIsRecordedAndArgv0AndEnvironmentArePassedOn() async throws {
        let process = try record("/bin/zsh", argv0: "-zsh", ["-f", "-c", "echo argv0=$0 hidden=${ARMADALE_HIDDEN-unset}; exit 3"])
        let output = OutputCollector(process.output)
        #expect(await process.termination == .exited(3))
        #expect(await output.waitForEnd() == "argv0=-zsh hidden=unset\n")
        #expect(await recordedStatus() == 3)
    }

    /// A death by signal is recorded as such (`signal N`), apart from a
    /// normal exit with the same number; the recorder exits 128 + N.
    @Test func aDeathBySignalIsRecordedApartFromANormalExit() async throws {
        let process = try record("/bin/zsh", argv0: "zsh", ["-f", "-c", "kill -9 $$"])
        let output = OutputCollector(process.output)
        #expect(await process.termination == .exited(128 + SIGKILL))
        #expect(await recordedStatus() == .signaled(SIGKILL))
        #expect(recorded == "signal 9\n")
        await output.waitForEnd()
        try? FileManager.default.removeItem(atPath: exitFile)
        let normal = try record("/bin/zsh", argv0: "zsh", ["-f", "-c", "exit 137"])
        let normalOutput = OutputCollector(normal.output)
        #expect(await normal.termination == .exited(137))
        #expect(await recordedStatus() == .exited(137))
        await normalOutput.waitForEnd()
        try? FileManager.default.removeItem(atPath: exitFile)
        await output.waitForEnd()
    }

    /// A bare program stays in the recorder's process group, the
    /// terminal's foreground group: ^C reaches both, and only the program
    /// dies of it. The recorder lives on to record that.
    @Test func controlCEndsABareProgramAndTheRecorderRecordsIt() async throws {
        let process = try record("/bin/sleep", argv0: "sleep", ["30"])
        let output = OutputCollector(process.output)
        try await Task.sleep(for: .milliseconds(300)) // the recorder has started the program
        process.write([0x03])
        #expect(await process.termination == .exited(128 + SIGINT))
        #expect(await recordedStatus() == .signaled(SIGINT))
        await output.waitForEnd()
    }

    /// An interactive zsh under the recorder keeps job control: it takes
    /// the terminal's foreground group for itself, ^C interrupts its
    /// foreground job and not the shell (nor the recorder), ^Z stops a
    /// job, and the shell's own exit status is what is recorded.
    @Test func anInteractiveShellKeepsJobControlAndItsExitIsRecorded() async throws {
        let process = try record("/bin/zsh", argv0: "-zsh", ["-f", "-i"])
        let output = OutputCollector(process.output)
        process.write(Array("echo mark-$((40+2)) pid=$$ pgid=$(ps -o pgid= -p $$) tpgid=$(ps -o tpgid= -p $$)\r".utf8))
        let text = await output.wait { $0.range(of: #"mark-42 pid=\d+ pgid=\s*\d+ tpgid=\s*\d+\n"#, options: .regularExpression) != nil }
        let match = try #require(text.firstMatch(of: /mark-42 pid=(\d+) pgid=\s*(\d+) tpgid=\s*(\d+)\n/))
        #expect(match.1 == match.2, "the shell leads its own process group")
        #expect(match.2 == match.3, "and that group is the terminal's foreground group")
        #expect(Int32(match.1) != process.pid, "the shell is the recorder's child")

        process.write(Array("/bin/sleep 30\r".utf8))
        try await Task.sleep(for: .milliseconds(400))
        process.write([0x03])
        process.write(Array("echo after-int=$?-$((1+1))\r".utf8))
        await output.wait { $0.contains("after-int=130-2\n") }

        process.write(Array("/bin/sleep 30\r".utf8))
        try await Task.sleep(for: .milliseconds(400))
        process.write([0x1A]) // ^Z
        process.write(Array("jobs; kill -9 %1; echo after-stop-$((2+1))\r".utf8))
        let stopped = await output.wait { $0.contains("after-stop-3\n") }
        #expect(stopped.contains("suspended"), "\(stopped.suffix(300))")

        #expect(process.isRunning, "neither ^C nor ^Z touched the recorder")
        process.write(Array("exit 5\r".utf8))
        #expect(await process.termination == .exited(5))
        #expect(await recordedStatus() == 5)
        await output.waitForEnd()
    }

    /// zmx ends a session with SIGHUP to its child, the recorder: it passes
    /// it on (once), the program ends, and the recorder exits without
    /// writing anything: the session is being ended from outside, and the
    /// app removes the file of a session it ends.
    @Test(arguments: [true, false])
    func aHangupToTheRecorderEndsTheProgramAndRecordsNothing(interactiveShell: Bool) async throws {
        let process = interactiveShell
            ? try record("/bin/zsh", argv0: "-zsh", ["-f", "-i"])
            : try record("/bin/sleep", argv0: "sleep", ["30"])
        let output = OutputCollector(process.output)
        if interactiveShell {
            // The shell counts the hangups it gets.
            process.write(Array("n=0; trap 'n=$((n+1)); echo hups=$n; exit 0' HUP; echo ready-$((3+4))\r".utf8))
            await output.wait { $0.contains("ready-7\n") }
        } else {
            try await Task.sleep(for: .milliseconds(300))
        }
        kill(process.pid, SIGHUP)
        let termination = await process.termination
        if interactiveShell {
            #expect(termination == .exited(0), "\(termination)")
            #expect(await output.waitForEnd().contains("hups=1\n"), "a shell gets the hangup once")
        } else {
            #expect(termination == .exited(128 + SIGHUP), "\(termination)")
            await output.waitForEnd()
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorded == nil, "nothing is recorded after a forwarded hangup")
        #expect(!FileManager.default.fileExists(atPath: exitFile + ".tmp"))
    }

    /// A signal the recorder's own parent had ignored stays ignored in the
    /// program, as across an exec; one that was not gets its default back.
    @Test func ignoredSignalsStayIgnoredAndOthersAreRestored() async throws {
        let helper = try HelperLocator.cttyExec(environment: [:]).path
        // zsh -c 'trap "" QUIT; exec ctty-exec --exit-file … zsh -c "trap"':
        // the inner zsh lists the signals it starts with ignored.
        let inner = "\(helper) --exit-file \(exitFile) /bin/zsh zsh -f -c trap"
        let process = try PTYProcess.spawn(
            program: "/bin/zsh", arguments: ["-f", "-c", "trap '' QUIT; exec \(inner)"],
            environment: testEnvironment(), size: PTYSize(columns: 80, rows: 24))
        let text = await OutputCollector(process.output).waitForEnd()
        #expect(text.contains("QUIT"), "\(text)")
        #expect(!text.contains("INT") && !text.contains("TSTP") && !text.contains("TTOU"), "\(text)")
        #expect(await recordedStatus() == 0)
    }

    /// A resize reaches the program under the recorder as SIGWINCH.
    @Test func aResizeReachesTheProgram() async throws {
        let process = try record(
            "/bin/zsh", argv0: "zsh", ["-f", "-c", "trap 'stty size; exit 0' WINCH; echo ready; while true; do /bin/sleep 0.05; done"])
        let output = OutputCollector(process.output)
        await output.wait { $0.contains("ready") }
        process.resize(PTYSize(columns: 120, rows: 40))
        #expect(await output.waitForEnd().contains("40 120"))
        #expect(await process.termination == .exited(0))
        #expect(await recordedStatus() == 0)
    }

    /// A program that cannot be started is recorded like a shell's
    /// "command not found" (127).
    @Test func aMissingProgramIsRecordedAs127() async throws {
        let process = try record("/no/such/program", argv0: "nope")
        let output = OutputCollector(process.output)
        #expect(await process.termination == .exited(127))
        #expect(await recordedStatus() == 127)
        #expect(await output.waitForEnd().contains("/no/such/program"))
    }
}
