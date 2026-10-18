import ArmadaleCore
import Darwin
import Foundation
import Synchronization
import Testing
@testable import ArmadaleSessions

/// A scripted ``SSHTransport``: records every command (and its input) and
/// answers with `respond`. Interactive invocations run `interactiveScript`
/// with `/bin/sh` locally.
final class FakeTransport: SSHTransport {
    struct Call: Sendable, Hashable {
        var command: String
        var input: Data?
    }

    private let calls = Mutex<[Call]>([])
    private let interactiveCalls = Mutex<[String?]>([])
    private let respond: @Sendable (String) -> CommandResult
    let interactiveScript: String

    init(interactiveScript: String = "exit 0", respond: @escaping @Sendable (String) -> CommandResult) {
        self.respond = respond
        self.interactiveScript = interactiveScript
    }

    var commands: [String] { calls.withLock { $0.map(\.command) } }
    var recorded: [Call] { calls.withLock { $0 } }
    var interactiveCommands: [String?] { interactiveCalls.withLock { $0 } }

    func run(_ host: ArmadaleCore.Host, _ remoteCommand: String, input: Data?) async throws -> CommandResult {
        calls.withLock { $0.append(Call(command: remoteCommand, input: input)) }
        return respond(remoteCommand)
    }

    func interactive(_ host: ArmadaleCore.Host, remoteCommand: String?) throws -> SSHInvocation {
        interactiveCalls.withLock { $0.append(remoteCommand) }
        return SSHInvocation(executable: "/bin/sh", arguments: ["-c", interactiveScript], environment: testEnvironment())
    }
}

extension CommandResult {
    static func ok(_ stdout: String = "") -> CommandResult {
        CommandResult(status: 0, stdout: Data(stdout.utf8), stderr: Data())
    }

    static func failed(_ status: Int32, _ stderr: String) -> CommandResult {
        CommandResult(status: status, stdout: Data(), stderr: Data(stderr.utf8))
    }

    static let refused = CommandResult.failed(255, "ssh: connect to host test.invalid port 22: Connection refused\n")
}

/// An ``SSHTransport`` whose "host" is this Mac: commands run with
/// `/bin/sh -c` in an environment whose `HOME` is a private directory, so
/// `~/.armadale` is a sandbox. With it the remote backend runs end to end
/// against the real (macOS) zmx: deployment, the double attach, attach-only,
/// kill. Failures can be switched on to simulate an unreachable host.
final class LoopbackTransport: SSHTransport {
    let home: String
    let environment: [String: String]
    private let runner = CommandRunner()
    private let state = Mutex(State())

    private struct State {
        var isDown = false
        var needsSignIn = false
        var hostKeyChanged = false
        var runs: [String] = []
        var interactiveCount = 0
    }

    /// What ssh prints when the host is down.
    static let downMessage = "ssh: connect to host loopback port 22: Connection refused"

    /// The "login shell" remote commands are handed to, as sshd does.
    let loginShell: String

    init(home: String, loginShell: String = "/bin/sh", environment: [String: String]) {
        self.home = home
        self.environment = environment
        self.loginShell = loginShell
    }

    /// Every command run, in order.
    var runs: [String] { state.withLock { $0.runs } }
    /// How many interactive clients were started.
    var interactiveCount: Int { state.withLock { $0.interactiveCount } }

    /// Every connection fails as ssh does when the host key changed.
    func setHostKeyChanged() { state.withLock { $0.hostKeyChanged = true } }
    static let changedKeyMessage = "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @\nHost key verification failed."

    /// While down, every command and client fails as ssh does (status 255).
    func setDown(_ down: Bool) { state.withLock { $0.isDown = down } }

    /// Until a sign-in client has run (it prompts for a password), control
    /// commands fail as BatchMode ssh does when a key needs a passphrase.
    func requireSignIn() { state.withLock { $0.needsSignIn = true } }

    var signInFlag: String { home + "/.signed-in" }

    func run(_ host: ArmadaleCore.Host, _ remoteCommand: String, input: Data?) async throws -> CommandResult {
        let (down, needsSignIn, changed) = state.withLock { state in
            state.runs.append(remoteCommand)
            return (state.isDown, state.needsSignIn, state.hostKeyChanged)
        }
        if down { return .failed(255, Self.downMessage + "\n") }
        if changed { return .failed(255, Self.changedKeyMessage + "\n") }
        if needsSignIn, !FileManager.default.fileExists(atPath: signInFlag) {
            return .failed(255, "loopback: Permission denied (publickey).\n")
        }
        return try await runner.run(
            executable: loginShell, arguments: ["-c", remoteCommand], environment: environment, input: input,
            timeout: .seconds(20))
    }

    func interactive(_ host: ArmadaleCore.Host, remoteCommand: String?) throws -> SSHInvocation {
        let (down, needsSignIn, changed) = state.withLock { state in
            state.interactiveCount += 1
            return (state.isDown, state.needsSignIn, state.hostKeyChanged)
        }
        let script: String
        if changed {
            script = "printf '%s\\n' \(RemoteShell.quote(Self.changedKeyMessage)) >&2; exit 255"
        } else if down {
            script = "echo '\(Self.downMessage)' >&2; exit 255"
        } else if needsSignIn, !FileManager.default.fileExists(atPath: signInFlag) {
            // The sign-in prompts, then (like a ControlMaster left up) lets
            // later commands through; anything else fails like BatchMode.
            script = remoteCommand == RemoteShell.sh("exit 0")
                ? "printf 'Password: '; read answer; [ \"$answer\" = secret ] && touch \(RemoteShell.quote(signInFlag))"
                : "echo 'loopback: Permission denied (publickey).' >&2; exit 255"
        } else {
            script = remoteCommand ?? "exec \"$SHELL\" -l"
        }
        return SSHInvocation(executable: loginShell, arguments: ["-c", script], environment: environment)
    }
}

/// A private "host" for remote backend tests: a short `HOME`
/// (`/tmp/armadale-rt-<pid>-<random>`, so `~/.armadale/run` fits socket
/// paths), a test zsh, and a ``RemoteZmxBackend`` over a
/// ``LoopbackTransport`` that deploys the real macOS zmx.
final class RemoteSandbox: Sendable {
    let home: String
    let transport: LoopbackTransport
    let backend: RemoteZmxBackend
    let zmx: String
    let host: ArmadaleCore.Host

    init(
        binaryAvailable: Bool = true, loginShell: String = "/bin/sh", userShell: String = "/bin/zsh",
        configure: (inout RemoteZmxBackend.Configuration) -> Void = { _ in }
    ) throws {
        zmx = try testZmx()
        let random = String(UInt32.random(in: 0...UInt32.max), radix: 36)
        home = "/tmp/armadale-rt-\(getpid())-\(random)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try "PS1='armadale-test%# '\nunsetopt PROMPT_SP\n".write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
        transport = LoopbackTransport(home: home, loginShell: loginShell, environment: testEnvironment([
            "HOME": home, "ZDOTDIR": home, "SHELL": userShell,
            // Must never reach zmx on the "host" either.
            "ZMX_SESSION": "a-bogusbogusbogus",
        ]))
        host = ArmadaleCore.Host(name: "Loopback", sshDestination: "loopback")
        var configuration = RemoteZmxBackend.Configuration(host: host, transport: transport)
        let zmx = zmx
        configuration.binary = { platform in
            guard binaryAvailable else { throw HelperLocator.NotFound(name: "zmx", searched: []) }
            #if arch(arm64)
            #expect(platform == .macosAarch64)
            #endif
            return URL(fileURLWithPath: zmx)
        }
        configuration.cttyExec = try HelperLocator.cttyExec(environment: [:]).path
        configuration.localDirectory = home
        configuration.appVersion = "test"
        configure(&configuration)
        backend = RemoteZmxBackend(configuration: configuration)
    }

    var runDirectory: String { home + "/.armadale/run" }
    var deployedBinary: String { home + "/.armadale/bin/zmx-\(ZmxVersion.current)" }

    func session(_ launch: LaunchSpec = LaunchSpec(), directory: String = "/usr/share") -> Session {
        Session(location: .remote(host: host.id), profileID: Profile.shell.id, launch: launch, workingDirectory: directory)
    }

    /// Names `zmx ls --short` lists on the "host".
    var listedNames: [String] {
        zmxSync(["ls", "--short"]).split(whereSeparator: \.isNewline).map(String.init)
    }

    @discardableResult
    func zmxSync(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = arguments
        process.environment = ZmxRuntime(directory: runDirectory).environment(base: testEnvironment())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func tearDown() {
        if FileManager.default.fileExists(atPath: runDirectory) {
            for name in listedNames { zmxSync(["kill", name]) }
        }
        if home.hasPrefix("/tmp/armadale-rt-") {
            try? FileManager.default.removeItem(atPath: home)
        }
    }
}

/// The test shell's prompt in a ``RemoteSandbox``.
let remotePrompt = "armadale-test% "
