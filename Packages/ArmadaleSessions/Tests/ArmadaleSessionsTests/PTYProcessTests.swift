import Darwin
import Foundation
import Testing
@testable import ArmadaleSessions

/// Integration tests against real processes. They use zsh or bare binaries,
/// never /bin/sh: macOS's /bin/sh is bash, which acquires the controlling
/// terminal by itself and would hide a broken spawn (docs/DESIGN.md section 7).
@Suite("PTYProcess", .serialized)
struct PTYProcessTests {
    private func zsh(
        _ script: String,
        size: PTYSize = PTYSize(columns: 80, rows: 24),
        directory: String? = nil,
        environment: [String: String] = [:],
        method: PTYProcess.Options.Method = .posixSpawn
    ) throws -> PTYProcess {
        try PTYProcess.spawn(
            program: "/bin/zsh",
            arguments: ["-f", "-c", script],
            environment: testEnvironment(environment),
            workingDirectory: directory,
            size: size,
            options: PTYProcess.Options(method: method))
    }

    @Test func helperIsFoundNextToTheTestBundle() throws {
        let helper = try HelperLocator.cttyExec(environment: [:])
        #expect(helper.lastPathComponent == "ctty-exec")
        #expect(FileManager.default.isExecutableFile(atPath: helper.path))
    }

    @Test func helperOverrideWinsAndMissingHelperIsReported() throws {
        let override = try HelperLocator.cttyExec(environment: [HelperLocator.cttyExecOverride: "/usr/bin/true"])
        #expect(override.path == "/usr/bin/true")
        #expect(throws: HelperLocator.NotFound.self) {
            try HelperLocator.locate("no-such-helper", override: nil, mainBundle: .main)
        }
    }

    /// (a) The child is a session leader with the PTY as its controlling
    /// terminal (TPGID is its own process group), at the requested size.
    @Test(arguments: [PTYProcess.Options.Method.posixSpawn, .forkpty])
    func acquiresControllingTerminalAtRequestedSize(method: PTYProcess.Options.Method) async throws {
        let process = try zsh(
            "ps -o tpgid= -p $$; stty size", size: PTYSize(columns: 100, rows: 30), method: method)
        let output = OutputCollector(process.output)
        let lines = await output.waitForEnd().split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(await process.termination == .exited(0))
        #expect(lines.count == 2)
        #expect(Int32(lines.first ?? "") == process.pid, "TPGID must be the child's own group: \(lines)")
        #expect(lines.last == "30 100")
        #expect(process.ttyPath.hasPrefix("/dev/ttys"))
    }

    /// (b) A resize reaches a running zsh as SIGWINCH (which needs a
    /// controlling terminal) and `stty size` reports the new size.
    @Test func resizeDeliversSIGWINCHAndNewSize() async throws {
        let process = try zsh(
            "trap 'stty size; exit 0' WINCH; echo ready; while true; do /bin/sleep 0.05; done",
            size: PTYSize(columns: 80, rows: 24))
        let output = OutputCollector(process.output)
        await output.wait { $0.contains("ready") }
        process.resize(PTYSize(columns: 120, rows: 40))
        let text = await output.waitForEnd()
        #expect(text.contains("40 120"))
        #expect(await process.exitStatus == 0)
    }

    /// (c) ^C written to the master interrupts the foreground job.
    @Test func controlCInterruptsSleep() async throws {
        let process = try zsh("echo ready; /bin/sleep 5; echo done")
        let output = OutputCollector(process.output)
        await output.wait { $0.contains("ready") }
        let start = ContinuousClock.now
        process.write([0x03])
        let termination = await process.termination
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(3), "took \(elapsed)") // immediate locally; generous for CI
        #expect(termination == .signaled(SIGINT) || termination == .exited(128 + SIGINT), "\(String(describing: termination))")
        #expect(!(await output.waitForEnd()).contains("done"))
    }

    /// (d)
    @Test func startsInWorkingDirectory() async throws {
        let process = try zsh("pwd", directory: "/usr/share")
        let text = await OutputCollector(process.output).waitForEnd()
        #expect(text == "/usr/share\n")
    }

    /// (e)
    @Test func passesEnvironment() async throws {
        let value = "héllo wörld $HOME 'quoted'"
        let process = try zsh("printf '%s' \"$ARMADALE_ROUNDTRIP\"", environment: ["ARMADALE_ROUNDTRIP": value])
        #expect(await OutputCollector(process.output).waitForEnd() == value)
    }

    /// (f)
    @Test func propagatesExitStatus() async throws {
        let process = try zsh("exit 7")
        let output = OutputCollector(process.output)
        #expect(await process.exitStatus == 7)
        #expect(await process.termination == .exited(7))
        await output.waitForEnd()
        #expect(!process.isRunning)
    }

    /// (g) A flood arrives complete, in batches of at most 64 KB, coalesced.
    @Test func floodArrivesCompleteInBoundedBatches() async throws {
        let process = try PTYProcess.spawn(
            // BSD seq's default %g format prints 1e+06; ask for integers.
            program: "/usr/bin/seq", arguments: ["-f", "%.0f", "1", "1000000"],
            environment: testEnvironment(), size: PTYSize(columns: 80, rows: 24))
        let output = OutputCollector(process.output)
        await output.waitForEnd()
        let bytes = output.bytes
        let sizes = output.batchSizes
        // Digits of 1…1,000,000 plus "\r\n" per line.
        let digits = 9 * 1 + 90 * 2 + 900 * 3 + 9_000 * 4 + 90_000 * 5 + 900_000 * 6 + 7
        #expect(bytes.count == digits + 2 * 1_000_000)
        #expect(bytes.reduce(0) { $0 + ($1 == 10 ? 1 : 0) } == 1_000_000)
        #expect(bytes.suffix(9) == Array("1000000\r\n".utf8))
        #expect((sizes.max() ?? 0) <= OutputBuffer.maxBatch)
        // Coalescing: under a flood nearly every byte arrives in a full
        // 64 KB batch (small batches only at the leading edge, after the
        // 16 ms interval, and at the end).
        let inFullBatches = sizes.filter { $0 == OutputBuffer.maxBatch }.reduce(0, +)
        #expect(Double(inFullBatches) / Double(bytes.count) > 0.8, "\(sizes.count) batches: \(sizes.prefix(40))")
        #expect(await process.exitStatus == 0)
    }

    /// Large input is written completely despite partial writes and EAGAIN.
    @Test func largeInputSurvivesPartialWrites() async throws {
        let process = try zsh("stty raw -echo; echo ready; head -c 200000 | wc -c")
        let output = OutputCollector(process.output)
        await output.wait { $0.contains("ready") }
        process.write([UInt8](repeating: UInt8(ascii: "a"), count: 200_000))
        let text = await output.waitForEnd()
        #expect(text.contains("200000"), "\(text)")
    }

    /// (h) A child that ignores SIGHUP is killed after the grace period.
    /// zsh execs the last command, so the sleep itself inherits the ignored
    /// SIGHUP.
    @Test func terminateKillsStubbornChild() async throws {
        let process = try zsh("trap '' HUP; echo ready; /bin/sleep 100")
        let output = OutputCollector(process.output)
        await output.wait { $0.contains("ready") }
        try await Task.sleep(for: .milliseconds(100)) // let zsh exec the sleep
        let start = ContinuousClock.now
        await process.terminate()
        let elapsed = ContinuousClock.now - start
        // 2 s grace period, then SIGKILL; the upper bound is generous for CI.
        #expect(elapsed >= .milliseconds(1900) && elapsed < .seconds(8), "took \(elapsed)")
        #expect(await process.termination == .signaled(SIGKILL))
        #expect(kill(process.pid, 0) != 0)
        await output.waitForEnd()
    }

    /// A shell that survives SIGHUP is killed together with its job.
    @Test func terminateKillsStubbornShellAndItsJob() async throws {
        let process = try zsh("trap 'echo hup' HUP; /bin/sleep 100 & echo pid:$!; while true; do /bin/sleep 0.05; done")
        let output = OutputCollector(process.output)
        let text = await output.wait { $0.contains("pid:") && $0.hasSuffix("\n") }
        let jobPID = pid_t(text.split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        await process.terminate()
        #expect(await process.termination == .signaled(SIGKILL))
        #expect(await output.waitForEnd().contains("hup"), "SIGHUP comes first")
        #expect(jobPID > 0)
        var gone = false
        for _ in 0..<100 where !gone {
            gone = kill(jobPID, 0) != 0
            if !gone { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(gone, "the shell's job \(jobPID) survived")
    }

    /// terminate() of a well-behaved child returns promptly via SIGHUP.
    @Test func terminateUsesSIGHUPFirst() async throws {
        let process = try PTYProcess.spawn(
            program: "/bin/sleep", arguments: ["100"], environment: testEnvironment(), size: PTYSize(columns: 80, rows: 24))
        let start = ContinuousClock.now
        await process.terminate()
        #expect(ContinuousClock.now - start < .milliseconds(1900), "no SIGKILL grace period needed")
        #expect(await process.termination == .signaled(SIGHUP))
    }

    /// (i) No descriptor leaks across many spawn/exit cycles, nor when a
    /// running process is simply dropped.
    @Test func noFileDescriptorLeaks() async throws {
        let before = openFileDescriptorCount()
        for _ in 0..<50 {
            let process = try PTYProcess.spawn(
                program: "/usr/bin/true", environment: testEnvironment(), size: PTYSize(columns: 80, rows: 24))
            await OutputCollector(process.output).waitForEnd()
            #expect(await process.exitStatus == 0)
        }
        #expect(openFileDescriptorCount() == before)

        var pid: pid_t = 0
        do {
            let process = try PTYProcess.spawn(
                program: "/bin/sleep", arguments: ["30"], environment: testEnvironment(), size: PTYSize(columns: 80, rows: 24))
            pid = process.pid
        }
        // Dropped: the master closes, the terminal hangs up, the child dies
        // of SIGHUP and is reaped.
        var reaped = false
        for _ in 0..<200 where !reaped {
            reaped = kill(pid, 0) != 0 && openFileDescriptorCount() == before
            if !reaped { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(reaped, "dropped process \(pid) still alive or fds leaked (\(openFileDescriptorCount()) vs \(before))")
    }

    @Test func missingProgramFailsToSpawn() {
        #expect(throws: SpawnError.self) {
            try PTYProcess.spawn(
                program: "no-such-program-armadale", environment: testEnvironment(), size: PTYSize(columns: 80, rows: 24))
        }
    }
}
