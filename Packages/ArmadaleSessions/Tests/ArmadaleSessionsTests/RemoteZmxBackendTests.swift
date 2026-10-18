import ArmadaleCore
import Darwin
import Foundation
import Testing
@testable import ArmadaleSessions

/// The remote backend's command lines and its reading of the host's
/// answers, with a scripted transport.
@Suite("RemoteZmxBackend (scripted host)")
struct RemoteZmxBackendUnitTests {
    private let host = ArmadaleCore.Host(name: "VM", sshDestination: "vm")
    private let id = SessionID(raw: "abcdefghijklmnop")
    private let layout = RemoteLayout(directory: "~/.armadale")

    private func backend(_ respond: @escaping @Sendable (String) -> CommandResult) -> (RemoteZmxBackend, FakeTransport) {
        let transport = FakeTransport(respond: respond)
        var configuration = RemoteZmxBackend.Configuration(host: host, transport: transport)
        configuration.binary = { _ in URL(fileURLWithPath: "/dev/null") }
        return (RemoteZmxBackend(configuration: configuration), transport)
    }

    private func session(_ launch: LaunchSpec = LaunchSpec(), directory: String = "~") -> Session {
        Session(id: id, location: .remote(host: host.id), profileID: Profile.shell.id, launch: launch, workingDirectory: directory)
    }

    @Test func clientCommandLine() {
        let attach = RemoteZmxEndpoint.clientCommand(["attach", "a-abcdefghijklmnop", "true"], layout: layout, version: "0.8.1")
        let script = "unset ZMX_SESSION ZMX_SESSION_PREFIX; exec env ZMX_DIR=\"$HOME\"/.armadale/run ZMX_NO_DETACH_KEY=1 "
            + "\"$HOME\"/.armadale/bin/zmx-0.8.1 attach a-abcdefghijklmnop true"
        #expect(attach == "exec /bin/sh -c '\(script)'")
    }

    @Test func controlCommandLineExitsSpeciallyWithoutTheHelper() {
        let list = RemoteZmxEndpoint.controlCommand(["ls", "--short"], layout: RemoteLayout(directory: "/opt/arm"), version: "0.8.1")
        let script = "unset ZMX_SESSION ZMX_SESSION_PREFIX; z=/opt/arm/bin/zmx-0.8.1; if test -x \"$z\"; then exec "
            + "env ZMX_DIR=/opt/arm/run ZMX_NO_DETACH_KEY=1 \"$z\" ls --short; else exit 97; fi"
        #expect(list == "exec /bin/sh -c '\(script)'")
    }

    @Test func aSessionRunsTheLoginShellInItsDirectoryWithoutRuntimeVariables() {
        let script = RemoteZmxEndpoint.sessionScript(
            for: session(directory: "~/src/my app"), appVersion: "1.0", unsetRuntimeVariables: true)
        #expect(!script.contains("\n"))
        let lines = script.components(separatedBy: "; ")
        #expect(lines.first == "unset ZMX_DIR ZMX_NO_DETACH_KEY ZMX_SESSION ZMX_SESSION_PREFIX")
        #expect(lines.contains("cd \"$HOME\"/'src/my app' 2>/dev/null || cd \"$HOME\""))
        #expect(lines.contains { $0.hasPrefix("export TERM=xterm-256color COLORTERM=truecolor TERM_PROGRAM=Armadale") })
        #expect(lines.contains { $0.contains("ARMADALE_SESSION_ID=abcdefghijklmnop") })
        #expect(lines.last == "exec \"${SHELL:-/bin/sh}\" -l")
        let program = RemoteZmxEndpoint(configuration: RemoteZmxBackend.Configuration(host: host, transport: FakeTransport { _ in .ok() }))
            .sessionProgram(for: session())
        #expect(Array(program.prefix(2)) == ["/bin/sh", "-c"])
    }

    @Test func aProgramRunsThroughTheLoginShellWithTheProfilesEnvironment() {
        let launch = LaunchSpec(program: "claude", arguments: ["--model", "it's"], environment: [
            "FOO": "a b", "ZMX_DIR": "/evil", "ARMADALE_X": "1", "1BAD": "x",
        ])
        let script = RemoteZmxEndpoint.sessionScript(for: session(launch), appVersion: "1.0", unsetRuntimeVariables: false)
        #expect(!script.contains("unset"))
        #expect(script.contains("export FOO='a b'"))
        #expect(!script.contains("/evil") && !script.contains("ARMADALE_X") && !script.contains("1BAD"))
        let run = RemoteShell.quote("exec claude --model 'it'\\''s'")
        #expect(script.hasSuffix("case \"${SHELL##*/}\" in csh|tcsh) exec \"$SHELL\" -c \(run);; *) exec \"${SHELL:-/bin/sh}\" -l -c \(run);; esac"))
    }

    @Test func listingKillingAndExistence() async throws {
        let (backend, transport) = backend { command in
            if command.contains("ls --short") { return .ok("a-abcdefghijklmnop\nmine\na-bogus\n") }
            if command.contains(" kill ") { return .failed(1, "error: session not found") }
            return .ok()
        }
        #expect(try await backend.liveSessions() == [id])
        #expect(try await backend.exists(id))
        try await backend.kill(id) // "not found" is not an error
        #expect(transport.commands.contains { $0.contains("kill a-abcdefghijklmnop") })
        #expect(transport.commands.last?.contains("rm -f \"$HOME\"/.armadale/run/logs/a-abcdefghijklmnop.log") == true)
    }

    @Test func aHostWithoutTheHelperHasNoSessions() async throws {
        let (backend, _) = backend { _ in .failed(RemoteZmxEndpoint.noRuntimeStatus, "") }
        #expect(try await backend.liveSessions().isEmpty)
        #expect(try await backend.exists(id) == false)
        try await backend.kill(id)
    }

    @Test func aFailedKillIsReported() async throws {
        let (backend, _) = backend { _ in .failed(1, "error: something else") }
        await #expect(throws: BackendError.runtimeFailure("The persistence helper could not end the session.")) {
            try await backend.kill(id)
        }
    }

    @Test func sshExit255IsUnreachable() async throws {
        let (backend, _) = backend { _ in .refused }
        let message = "ssh: connect to host test.invalid port 22: Connection refused"
        await #expect(throws: BackendError.unreachable(message)) { _ = try await backend.liveSessions() }
        await #expect(throws: BackendError.unreachable(message)) { _ = try await backend.exists(id) }
        await #expect(throws: BackendError.unreachable(message)) {
            _ = try await backend.create(session(), size: PTYSize(columns: 80, rows: 24))
        }
        await #expect(throws: BackendError.unreachable(message)) {
            _ = try await backend.attach(session(), size: PTYSize(columns: 80, rows: 24))
        }
    }

    private func signInBackend(
        interactive: String, batch: CommandResult, configure: (inout RemoteZmxBackend.Configuration) -> Void = { _ in }
    ) throws -> (RemoteZmxBackend, FakeTransport) {
        let transport = FakeTransport(interactiveScript: interactive) { _ in batch }
        var configuration = RemoteZmxBackend.Configuration(host: host, transport: transport)
        configuration.cttyExec = try HelperLocator.cttyExec(environment: [:]).path
        configuration.signInPromptTimeout = .seconds(2)
        configure(&configuration)
        return (RemoteZmxBackend(configuration: configuration), transport)
    }

    /// A rejected key: the interactive ssh asks nothing, so there is
    /// nothing to sign in to. Terminal, with ssh's own message.
    @Test func aRejectedKeyFailsForGoodWithSshsMessage() async throws {
        let (backend, transport) = try signInBackend(
            interactive: "echo 'vm: Permission denied (publickey).' >&2; exit 255",
            batch: .failed(255, "vm: Permission denied (publickey).\n"))
        await #expect(throws: BackendError.authenticationFailed("vm: Permission denied (publickey).")) {
            _ = try await backend.attach(session(), size: PTYSize(columns: 80, rows: 24))
        }
        #expect(transport.interactiveCommands.count == 1)
    }

    /// A changed host key: refused at once, no interactive ssh at all.
    @Test func aChangedHostKeyFailsForGoodWithoutASignIn() async throws {
        let (backend, transport) = try signInBackend(
            interactive: "exit 0",
            batch: .failed(255, "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @\nHost key verification failed.\n"))
        await #expect(throws: BackendError.authenticationFailed("Host key verification failed.")) {
            _ = try await backend.create(session(), size: PTYSize(columns: 80, rows: 24))
        }
        #expect(transport.interactiveCommands.isEmpty)
    }

    /// A real prompt starts a sign-in in the pane; nobody answering it
    /// ends it after the sign-in timeout, as a connection failure.
    @Test func anUnansweredPromptTimesOut() async throws {
        let (backend, _) = try signInBackend(
            interactive: "printf 'me@vm password: '; sleep 30",
            batch: .failed(255, "me@vm: Permission denied (publickey,password).\n")
        ) { $0.signInTimeout = .milliseconds(500) }
        let handle = try await backend.attach(session(), size: PTYSize(columns: 80, rows: 24))
        let output = OutputCollector(handle.output)
        await output.wait { $0.contains("password: ") }
        _ = await handle.exitStatus
        #expect(handle.connectionFailure?.contains("timed out") == true)
        await output.waitForEnd()
    }

    @Test func exitResolutionOnlyEndsWhatTheHostSaysIsGone() async {
        let (listed, _) = backend { _ in .ok("a-abcdefghijklmnop\n") }
        #expect(await listed.resolveExit(of: session()) == .detached)
        let (gone, _) = backend { _ in .ok("") }
        #expect(await gone.resolveExit(of: session()) == .ended)
        let (down, _) = backend { _ in .refused }
        #expect(await down.resolveExit(of: session()) == .detached, "an unreachable host proves nothing")
    }
}

/// The remote backend end to end against the real zmx, with this Mac as
/// the "host" (``LoopbackTransport``): deployment into a private `HOME`,
/// the double attach, attach-only, reconnecting, the plain-ssh fallback and
/// the interactive sign-in.
@Suite("RemoteZmxBackend (loopback host, real zmx)", .serialized)
final class RemoteZmxBackendLoopbackTests {
    let size = PTYSize(columns: 80, rows: 24)
    var sandboxes: [RemoteSandbox] = []

    deinit {
        for sandbox in sandboxes { sandbox.tearDown() }
    }

    private func makeSandbox(
        binaryAvailable: Bool = true, loginShell: String = "/bin/sh", userShell: String = "/bin/zsh"
    ) throws -> RemoteSandbox {
        let sandbox = try RemoteSandbox(binaryAvailable: binaryAvailable, loginShell: loginShell, userShell: userShell)
        sandboxes.append(sandbox)
        return sandbox
    }

    private func pid(in output: OutputCollector, marker: String) async -> String? {
        let text = await output.wait { $0.range(of: marker + "=[0-9]+\n", options: .regularExpression) != nil }
        guard let range = text.range(of: marker + "=[0-9]+\n", options: .regularExpression) else { return nil }
        return String(text[range].dropFirst(marker.count + 1).dropLast())
    }

    @Test func deployCreateDetachReattachAndKill() async throws {
        let sandbox = try makeSandbox()
        let backend = sandbox.backend
        let session = sandbox.session()
        let handle = try await backend.create(session, size: size)
        #expect(handle.runtimeVersion == ZmxVersion.current)
        #expect(handle.persistenceNote == nil)
        #expect(access(sandbox.deployedBinary, X_OK) == 0, "deployed to ~/.armadale/bin")
        let output = OutputCollector(handle.output)
        await output.wait { $0.contains(remotePrompt) }
        #expect(!output.text.contains("created"))
        handle.write(Array("echo pid=$$; echo dir=$PWD; echo zmxvars=$(env | grep -c '^ZMX_')\r".utf8))
        let shell = await pid(in: output, marker: "pid")
        await output.wait { $0.contains("dir=/usr/share\n") && $0.contains("zmxvars=0\n") }
        #expect(sandbox.listedNames == ["a-" + session.id.raw])

        // The client goes (the app quits); the session stays.
        await handle.terminate()
        await output.waitForEnd()
        #expect(try await backend.liveSessions() == [session.id])
        #expect(await backend.resolveExit(of: session) == .detached)

        var restored = session
        restored.runtimeVersion = ZmxVersion.current
        let again = try await backend.attach(restored, size: size)
        let replay = OutputCollector(again.output)
        await replay.wait { $0.contains("zmxvars=0") }
        again.write(Array("echo again=$$\r".utf8))
        #expect(await pid(in: replay, marker: "again") == shell)

        try await backend.kill(session.id)
        await replay.waitForEnd()
        #expect(try await backend.liveSessions().isEmpty)
        #expect(await backend.resolveExit(of: session) == .ended)
        #expect(!FileManager.default.fileExists(atPath: sandbox.runDirectory + "/logs/a-\(session.id.raw).log"))
    }

    @Test func attachToAMissingSessionThrowsAndLeavesNothing() async throws {
        let sandbox = try makeSandbox()
        let session = sandbox.session()
        await #expect(throws: BackendError.noSuchSession(session.id)) {
            _ = try await sandbox.backend.attach(session, size: size)
        }
        #expect(sandbox.listedNames.isEmpty)
    }

    @Test func aMissingWorkingDirectoryFallsBackToHome() async throws {
        let sandbox = try makeSandbox()
        let session = sandbox.session(directory: "/no/such/directory")
        let handle = try await sandbox.backend.create(session, size: size)
        let output = OutputCollector(handle.output)
        await output.wait { $0.contains(remotePrompt) }
        handle.write(Array("echo dir=$PWD\r".utf8))
        await output.wait { $0.contains("dir=\(sandbox.home)\n") }
        try await sandbox.backend.kill(session.id)
        await output.waitForEnd()
    }

    @Test func anUnreachableHostIsReportedAsSuch() async throws {
        let sandbox = try makeSandbox()
        sandbox.transport.setDown(true)
        let session = sandbox.session()
        await #expect(throws: BackendError.unreachable(LoopbackTransport.downMessage)) {
            _ = try await sandbox.backend.create(session, size: size)
        }
        await #expect(throws: BackendError.self) { _ = try await sandbox.backend.liveSessions() }
        #expect(await sandbox.backend.resolveExit(of: session) == .detached)
    }

    /// The pane's client dies (ssh killed, or the network went away) while
    /// the host is down; the controller keeps the session, retries on its
    /// schedule, and reconnects to the same shell when the host is back.
    @MainActor
    @Test func theControllerReconnectsToTheSameShellWhenTheHostIsBack() async throws {
        let sandbox = try makeSandbox()
        let session = sandbox.session()
        let surface = RecordingSurface()
        let controller = SessionController(
            session: session, backend: sandbox.backend, makeSurface: { surface }, makeOutputFilter: { ZmxOutputFilter() })
        controller.reconnectSchedule = ReconnectSchedule(
            initialDelay: .milliseconds(100), maximumDelay: .milliseconds(300), budget: .seconds(20))
        await controller.start(.create)
        #expect(controller.state == .attached)
        #expect(await eventually { surface.text.contains(remotePrompt) })
        controller.surface.delegate?.surface(surface, didInput: Array("echo first=$$\r".utf8))
        #expect(await eventually { surface.text.range(of: "first=[0-9]+", options: .regularExpression) != nil })
        let firstPID = surface.text.firstMatch(of: /first=([0-9]+)/).map { String($0.1) }

        sandbox.transport.setDown(true)
        try killClient(of: session)
        #expect(await eventually(timeout: .seconds(15)) { controller.state.isDisconnected })
        #expect(controller.isReconnecting)
        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.state.isDisconnected, "never ended while the host is down")

        sandbox.transport.setDown(false)
        #expect(await eventually(timeout: .seconds(15)) { controller.state == .attached })
        #expect(!controller.isReconnecting)
        controller.surface.delegate?.surface(surface, didInput: Array("echo second=$$\r".utf8))
        #expect(await eventually { surface.textSinceReset.range(of: "second=[0-9]+", options: .regularExpression) != nil })
        let secondPID = surface.textSinceReset.firstMatch(of: /second=([0-9]+)/).map { String($0.1) }
        #expect(firstPID != nil && firstPID == secondPID)
        await controller.close()
        #expect(sandbox.listedNames.isEmpty)
    }

    @MainActor
    @Test func aHostThatCannotTakeTheHelperGetsAPlainShell() async throws {
        let sandbox = try makeSandbox(binaryAvailable: false)
        let session = sandbox.session()
        let surface = RecordingSurface()
        let controller = SessionController(session: session, backend: sandbox.backend, makeSurface: { surface })
        await controller.start(.create)
        #expect(controller.state == .attached)
        let note = try #require(controller.persistenceNote)
        #expect(note.contains("persistence helper"))
        #expect(!note.lowercased().contains("zmx"))
        #expect(controller.session.runtimeVersion == nil, "not recorded as persistent")
        #expect(await eventually { surface.text.contains(remotePrompt) })
        #expect(sandbox.listedNames.isEmpty, "no daemon")
        controller.surface.delegate?.surface(surface, didInput: Array("exit\r".utf8))
        #expect(await eventually(timeout: .seconds(10)) { controller.state.isEnded })
    }

    @MainActor
    @Test func aHostThatNeedsAPasswordSignsInInThePane() async throws {
        let sandbox = try makeSandbox()
        sandbox.transport.requireSignIn()
        let session = sandbox.session()
        let surface = RecordingSurface()
        let controller = SessionController(
            session: session, backend: sandbox.backend, makeSurface: { surface }, makeOutputFilter: { ZmxOutputFilter() })
        await controller.start(.create)
        #expect(controller.state == .attached, "the sign-in is shown in the pane")
        #expect(await eventually { surface.text.contains("Password: ") })
        controller.surface.delegate?.surface(surface, didInput: Array("secret\r".utf8))
        #expect(await eventually(timeout: .seconds(15)) { surface.text.contains(remotePrompt) })
        #expect(controller.session.runtimeVersion == ZmxVersion.current)
        controller.surface.delegate?.surface(surface, didInput: Array("echo signed-$((6*7))\r".utf8))
        #expect(await eventually { surface.text.contains("signed-42") })
        #expect(sandbox.listedNames == ["a-" + session.id.raw])
        await controller.close()
        #expect(sandbox.listedNames.isEmpty)
    }

    /// A wrong password: the sign-in ends without reaching the session.
    /// The pane shows ssh's last words and is not retried by itself.
    @MainActor
    @Test func aFailedSignInIsNotRetriedInALoop() async throws {
        let sandbox = try makeSandbox()
        sandbox.transport.requireSignIn()
        let surface = RecordingSurface()
        let controller = SessionController(
            session: sandbox.session(), backend: sandbox.backend, makeSurface: { surface }, makeOutputFilter: { ZmxOutputFilter() })
        controller.reconnectSchedule = ReconnectSchedule(
            initialDelay: .milliseconds(50), maximumDelay: .milliseconds(100), budget: .seconds(20))
        await controller.start(.create)
        #expect(await eventually { surface.text.contains("Password: ") })
        controller.surface.delegate?.surface(surface, didInput: Array("wrong\r".utf8))
        #expect(await eventually(timeout: .seconds(10)) { controller.state.isDisconnected })
        #expect(!controller.isReconnecting)
        try await Task.sleep(for: .seconds(3))
        #expect(sandbox.transport.interactiveCount == 1, "no retry loop")
        #expect(controller.state.isDisconnected)
    }

    /// A changed host key: Disconnected with ssh's message, no retries.
    @MainActor
    @Test func aChangedHostKeyIsNotRetried() async throws {
        let sandbox = try makeSandbox()
        sandbox.transport.setHostKeyChanged()
        let controller = SessionController(
            session: sandbox.session(), backend: sandbox.backend, makeSurface: { RecordingSurface() })
        controller.reconnectSchedule = ReconnectSchedule(
            initialDelay: .milliseconds(50), maximumDelay: .milliseconds(100), budget: .seconds(20))
        await controller.start(.attach)
        #expect(controller.state == .disconnected(reason: "Host key verification failed."))
        #expect(!controller.isReconnecting)
        let runs = sandbox.transport.runs.count
        try await Task.sleep(for: .seconds(2))
        #expect(sandbox.transport.runs.count == runs, "nothing more was tried")
        #expect(sandbox.transport.interactiveCount == 0)
    }

    /// A host whose login shell is tcsh: every command Armadale sends must
    /// survive being handed to it (sshd runs remote commands with the
    /// login shell). Deploy, create, reattach and kill, end to end.
    @Test func everythingWorksWhenTheLoginShellIsTcsh() async throws {
        let sandbox = try makeSandbox(loginShell: "/bin/tcsh")
        let backend = sandbox.backend
        let session = sandbox.session()
        let handle = try await backend.create(session, size: size)
        let output = OutputCollector(handle.output)
        await output.wait { $0.contains(remotePrompt) }
        handle.write(Array("echo tcsh-pid=$$\r".utf8))
        let shell = await pid(in: output, marker: "tcsh-pid")
        await handle.terminate()
        await output.waitForEnd()
        var restored = session
        restored.runtimeVersion = ZmxVersion.current
        let again = try await backend.attach(restored, size: size)
        let replay = OutputCollector(again.output)
        again.write(Array("echo again=$$\r".utf8))
        #expect(await pid(in: replay, marker: "again") == shell)
        try await backend.kill(session.id)
        await replay.waitForEnd()
        #expect(sandbox.listedNames.isEmpty)
    }

    /// A profile program when the user's shell on the host is tcsh (which
    /// refuses `-l -c`): it still starts.
    @Test func aProgramStartsWhenTheUsersShellIsTcsh() async throws {
        let sandbox = try makeSandbox(loginShell: "/bin/tcsh", userShell: "/bin/tcsh")
        var session = sandbox.session(LaunchSpec(program: "/bin/sh", arguments: ["-c", "echo started-$((6*7)); exec sleep 30"]))
        session.workingDirectory = "~"
        let handle = try await sandbox.backend.create(session, size: size)
        let output = OutputCollector(handle.output)
        await output.wait { $0.contains("started-42") }
        try await sandbox.backend.kill(session.id)
        await output.waitForEnd()
    }

    /// SIGKILLs the session's current attach-only client, as losing the
    /// ssh connection would end it.
    private func killClient(of session: Session) throws {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "attach a-\(session.id.raw) true"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        try pgrep.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        let pids = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
        #expect(!pids.isEmpty, "the client is running")
        for pid in pids { kill(pid, SIGKILL) }
    }
}
