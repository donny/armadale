import Foundation
import Testing
@testable import ArmadaleSessions

@Suite("CommandRunner")
struct CommandRunnerTests {
    let runner = CommandRunner()

    @Test func collectsStdoutStderrAndStatusThroughPipes() async throws {
        let result = try await runner.run(
            executable: "/bin/zsh",
            arguments: ["-f", "-c", "[[ -p /dev/stdout ]] && echo out-is-a-pipe; [[ -p /dev/stderr ]] && echo err >&2; exit 3"],
            environment: testEnvironment())
        #expect(result.status == 3)
        #expect(result.stdoutText == "out-is-a-pipe\n")
        #expect(result.stderrText == "err\n")
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let result = try await runner.run(
            executable: "/bin/zsh", arguments: ["-f", "-c", "/usr/bin/yes x | /usr/bin/head -c 3000000; /usr/bin/yes e | /usr/bin/head -c 300000 >&2"],
            environment: testEnvironment())
        #expect(result.status == 0)
        #expect(result.stdout.count == 3_000_000)
        #expect(result.stderr.count == 300_000)
    }

    @Test func timeoutKillsTheCommandAndThrows() async throws {
        let unique = "37.\(Int.random(in: 100_000...999_999))"
        let start = ContinuousClock.now
        await #expect(throws: CommandRunner.TimedOut.self) {
            _ = try await runner.run(
                executable: "/bin/sleep", arguments: [unique], environment: testEnvironment(), timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        let check = try await runner.run(executable: "/usr/bin/pgrep", arguments: ["-f", "sleep \(unique)"], environment: testEnvironment())
        #expect(check.status == 1, "the timed-out command is gone: \(check.stdoutText)")
    }

    @Test func signalStatusAndMissingExecutable() async throws {
        let killed = try await runner.run(executable: "/bin/zsh", arguments: ["-f", "-c", "kill -TERM $$"], environment: testEnvironment())
        #expect(killed.status == 128 + SIGTERM)
        await #expect(throws: CommandRunner.LaunchFailed.self) {
            _ = try await runner.run(executable: "/no/such/program", environment: testEnvironment())
        }
    }

    @Test func zmxSessionVariablesAreAlwaysRemoved() async throws {
        let result = try await runner.run(
            executable: "/usr/bin/env",
            environment: testEnvironment(["ZMX_SESSION": "x", "ZMX_SESSION_PREFIX": "y", "KEEP_ME": "z"]))
        #expect(!result.stdoutText.contains("ZMX_SESSION"))
        #expect(result.stdoutText.contains("KEEP_ME=z\n"))
    }
}
