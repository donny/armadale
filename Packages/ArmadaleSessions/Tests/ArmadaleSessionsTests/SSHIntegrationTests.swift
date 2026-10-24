import ArmadaleCore
import Darwin
import Foundation
import Testing
@testable import ArmadaleSessions

/// The ssh destination the integration tests use; they are skipped when it
/// is unset. `ARMADALE_TEST_SSH_CONFIG` optionally names an ssh
/// configuration file for it (`ssh -F`), e.g. the one
/// `limactl show-ssh --format=config default` prints for a Lima VM.
private let testSSHDestination = ProcessInfo.processInfo.environment["ARMADALE_TEST_SSH_HOST"].flatMap { $0.isEmpty ? nil : $0 }
private let testSSHConfig = ProcessInfo.processInfo.environment["ARMADALE_TEST_SSH_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }

/// Against a real SSH host (docs/DESIGN.md section 6): deployment of the
/// helper into `~/.armadale` there, a session created, detached,
/// reattached to the same shell and killed, and the shared connection.
/// Leaves `~/.armadale/bin/zmx-<version>` on the host (it is what a user's
/// first connection would install) but no sessions.
@Suite(
    "SSH integration (ARMADALE_TEST_SSH_HOST)", .serialized,
    .enabled(if: testSSHDestination != nil, "set ARMADALE_TEST_SSH_HOST to an ssh destination to run these"))
final class SSHIntegrationTests {
    let host: ArmadaleCore.Host
    let controlDirectory: String
    let transport: OpenSSHTransport
    let backend: RemoteZmxBackend
    let size = PTYSize(columns: 100, rows: 30)

    init() throws {
        host = ArmadaleCore.Host(name: "Test host", sshDestination: testSSHDestination ?? "unset", sshConfigFile: testSSHConfig)
        controlDirectory = "/tmp/armadale-sshtest-\(getpid())/ssh"
        transport = OpenSSHTransport(controlDirectory: controlDirectory)
        var configuration = RemoteZmxBackend.Configuration(host: host, transport: transport)
        configuration.cttyExec = try HelperLocator.cttyExec(environment: [:]).path
        configuration.appVersion = "test"
        backend = RemoteZmxBackend(configuration: configuration)
    }

    deinit {
        // `ssh -O exit`, run here synchronously (no waiting on another task).
        let exit = Process()
        exit.executableURL = URL(fileURLWithPath: transport.executable)
        exit.arguments = transport.options(for: host) + ["-O", "exit", "--", host.sshDestination]
        exit.environment = transport.environment
        exit.standardOutput = FileHandle.nullDevice
        exit.standardError = FileHandle.nullDevice
        if (try? exit.run()) != nil { exit.waitUntilExit() }
        let directory = (controlDirectory as NSString).deletingLastPathComponent
        if directory.hasPrefix("/tmp/armadale-sshtest-") { try? FileManager.default.removeItem(atPath: directory) }
    }

    @Test func deployCreateAttachAndKill() async throws {
        _ = try await backend.deployer.ensureDeployed()
        let check = try await transport.run(host, "test -x ~/.armadale/bin/zmx-\(ZmxVersion.current) && echo installed")
        #expect(check.stdoutText.contains("installed"), "\(check.stderrText)")

        let session = Session(location: .remote(host: host.id), profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "~")
        let handle = try await backend.create(session, size: size)
        #expect(handle.runtimeVersion == ZmxVersion.current)
        let output = OutputCollector(handle.output)
        handle.write(Array("echo pid=$$ size=$(stty size) zmx=$(env | grep -c '^ZMX_')\r".utf8))
        let text = await output.wait(timeout: .seconds(20)) { $0.contains("zmx=0") }
        let pid = try #require(text.firstMatch(of: /pid=([0-9]+) size=30 100 zmx=0/).map { String($0.1) })
        #expect(try await backend.liveSessions().contains(session.id))

        await handle.terminate()
        await output.waitForEnd()
        #expect(try await backend.exists(session.id), "the session outlives its client")
        #expect(await backend.resolveExit(of: session) == .detached)

        var restored = session
        restored.runtimeVersion = ZmxVersion.current
        let again = try await backend.attach(restored, size: size)
        let replay = OutputCollector(again.output)
        again.write(Array("echo again=$$\r".utf8))
        let replayed = await replay.wait(timeout: .seconds(20)) { $0.contains("again=\(pid)") }
        #expect(replayed.contains("pid=\(pid)"), "the replay shows the earlier output")

        try await backend.kill(session.id)
        await replay.waitForEnd()
        #expect(try await backend.liveSessions().contains(session.id) == false)
        #expect(await backend.resolveExit(of: session) == .ended(exitStatus: nil), "killed: nothing recorded")
    }

    /// The session's wrapper on the host records the shell's exit status
    /// (`~/.armadale/run/a-<id>.exit`): `exit 3` records 3, an `exit` after
    /// a successful command records 0, and both end the session with it.
    /// Closing (kill) removes the records.
    @Test func theShellsExitStatusIsRecordedOnTheHost() async throws {
        for (command, status) in [("exit 3", Int32(3)), ("true; exit", Int32(0))] {
            let session = Session(location: .remote(host: host.id), profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "~")
            let handle = try await backend.create(session, size: size)
            let output = OutputCollector(handle.output)
            handle.write(Array("echo ready-$((20+1))\r".utf8))
            await output.wait(timeout: .seconds(20)) { $0.contains("ready-21") }
            handle.write(Array((command + "\r").utf8))
            await output.waitForEnd(timeout: .seconds(20))
            let file = "~/.armadale/run/a-\(session.id.raw).exit"
            let record = try await transport.run(host, "cat \(file)")
            #expect(record.stdoutText == "\(status)\n", "\(command): \(record.stdoutText) \(record.stderrText)")
            #expect(await backend.resolveExit(of: session) == .ended(exitStatus: .exited(status)), "\(command)")
            try await backend.kill(session.id)
            let gone = try await transport.run(host, "test -e \(file) && echo present || echo absent")
            #expect(gone.stdoutText.contains("absent"), "closing removes the record")
        }
    }

    /// The upload's ssh client is killed mid-transfer (as a dropped link
    /// or the upload timeout would): the host's `cat` sees an early EOF,
    /// the size check fails, and nothing is installed at the final path.
    @Test func aKilledUploadInstallsNothing() async throws {
        let path = "~/.armadale/test-upload/zmx-killed"
        _ = try await transport.run(host, "rm -rf ~/.armadale/test-upload")
        let data = Data(count: 400_000_000)
        let transport = transport
        let host = host
        let upload = Task { try await transport.upload(host, data: data, toRemotePath: path, mode: 0o755) }
        // Find the uploading ssh (its command line names the folder) and kill it.
        var killed = false
        for _ in 0..<200 where !killed {
            try await Task.sleep(for: .milliseconds(20))
            let pids = try await CommandRunner().run(
                executable: "/usr/bin/pgrep", arguments: ["-f", "test-upload.*cat >"], environment: testEnvironment())
            if let pid = pid_t(pids.stdoutText.split(whereSeparator: \.isNewline).first ?? "") {
                try await Task.sleep(for: .milliseconds(150)) // part of it is through
                kill(pid, SIGKILL)
                killed = true
            }
        }
        #expect(killed, "the upload was found and killed")
        let result = try? await upload.value
        #expect(result?.status != 0)
        try await Task.sleep(for: .milliseconds(500)) // the host side finishes
        let check = try await transport.run(
            host, "if test -e ~/.armadale/test-upload/zmx-killed; then echo installed; else echo absent; fi; ls -a ~/.armadale/test-upload 2>/dev/null")
        #expect(check.stdoutText.hasPrefix("absent"), "\(check.stdoutText)")
        _ = try await transport.run(host, "rm -rf ~/.armadale/test-upload")
    }

    /// A truncated helper already on the host (an older Armadale's
    /// interrupted upload) is noticed by its size and replaced.
    @Test func aTruncatedHelperOnTheHostIsReplaced() async throws {
        let binary = try HelperLocator.remoteZmx(for: .linuxAarch64)
        let full = try Data(contentsOf: binary)
        let path = "~/.armadale/bin/zmx-\(ZmxVersion.current)"
        let truncate = try await transport.run(
            host, "mkdir -p ~/.armadale/bin && cat > \(path).tmp && chmod 755 \(path).tmp && mv -f \(path).tmp \(path)",
            input: full.prefix(3_000_000))
        #expect(truncate.status == 0, "\(truncate.stderrText)")
        let deployment = try await backend.deployer.ensureDeployed()
        #expect(deployment.uploaded, "the short copy was not trusted")
        let size = try await transport.run(host, "wc -c < \(path)")
        #expect(Int(size.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) == full.count)
        #expect(try await backend.deployer.ensureDeployed().uploaded == false)
    }

    @Test func aMissingSessionIsNotCreatedByAttach() async throws {
        let session = Session(location: .remote(host: host.id), profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "~")
        await #expect(throws: BackendError.noSuchSession(session.id)) {
            _ = try await backend.attach(session, size: size)
        }
        #expect(try await backend.liveSessions().contains(session.id) == false)
    }

    @Test func theConnectionIsShared() async throws {
        await transport.closeMasterConnection(host)
        #expect(await transport.hasMasterConnection(host) == false)
        let clock = ContinuousClock()
        let first = try await clock.measure {
            let result = try await transport.run(host, "true")
            #expect(result.status == 0, "\(result.stderrText)")
        }
        #expect(await transport.hasMasterConnection(host), "ssh -O check finds the master the first command left")
        let second = try await clock.measure {
            _ = try await transport.run(host, "true")
        }
        #expect(second < first, "first \(first), then \(second)")
        let path = transport.controlPath(for: host)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(path.utf8.count < 100)
    }
}
