import ArmadaleCore
import Foundation
import Testing
@testable import ArmadaleSessions

@Suite("SSHTransport")
struct SSHTransportTests {
    private let host = ArmadaleCore.Host(name: "VM", sshDestination: "me@vm.example")

    // MARK: Control sockets

    /// The default state directory with a realistic user name: ssh's `%C`
    /// would not fit there, the token does.
    @Test func controlPathFitsUnderTheDefaultStateDirectory() {
        let runtime = ZmxRuntime.directory(forStateDirectory: URL(fileURLWithPath: "/Users/donny/Library/Application Support/Armadale"))
        #expect(runtime == "/Users/donny/Library/Application Support/Armadale/run")
        let directory = OpenSSHTransport.controlDirectory(forRuntimeDirectory: runtime, uid: 501)
        #expect(directory == runtime + "/ssh")
        let transport = OpenSSHTransport(controlDirectory: directory, environment: [:])
        let path = transport.controlPath(for: host)
        #expect(path.utf8.count < 100, "\(path) is \(path.utf8.count) bytes")
        // ssh first binds the socket with a 17-character suffix.
        #expect(path.utf8.count + OpenSSHTransport.masterTemporarySuffixLength <= ZmxRuntime.maxSocketPathLength)
    }

    @Test func aLongStateDirectoryFallsBackToTmp() {
        let runtime = "/Users/a-rather-long-user-name/Library/Application Support/Armadale/run"
        #expect(OpenSSHTransport.controlDirectory(forRuntimeDirectory: runtime, uid: 501) == "/tmp/armadale-501/ssh")
        let path = OpenSSHTransport(controlDirectory: "/tmp/armadale-501/ssh", environment: [:]).controlPath(for: host)
        #expect(path.utf8.count + OpenSSHTransport.masterTemporarySuffixLength <= ZmxRuntime.maxSocketPathLength)
    }

    @Test func theTokenIsStableAndChangesWithTheConnection() {
        let token = OpenSSHTransport.controlToken(for: host)
        #expect(token.count == OpenSSHTransport.controlTokenLength)
        #expect(token.allSatisfy { $0.isHexDigit })
        #expect(OpenSSHTransport.controlToken(for: host) == token)
        var renamed = host
        renamed.name = "Other name"
        #expect(OpenSSHTransport.controlToken(for: renamed) == token, "the display name does not matter")
        var other = host
        other.port = 2222
        #expect(OpenSSHTransport.controlToken(for: other) != token)
        other = host
        other.sshDestination = "you@vm.example"
        #expect(OpenSSHTransport.controlToken(for: other) != token)
    }

    // MARK: Command lines

    @Test func controlCommandsAreBatchModeAndMultiplexed() {
        var host = host
        host.port = 2222
        host.identityFile = "/keys/id"
        host.sshConfigFile = "/tmp/lima.conf"
        let transport = OpenSSHTransport(controlDirectory: "/tmp/run dir/ssh", environment: [:])
        let arguments = transport.controlArguments(host, "uname -sm")
        #expect(Array(arguments.prefix(3)) == ["-T", "-o", "BatchMode=yes"])
        #expect(arguments.suffix(3) == ["--", "me@vm.example", "uname -sm"])
        #expect(arguments.contains("ControlMaster=auto"))
        #expect(arguments.contains("ControlPersist=600"))
        #expect(arguments.contains("ControlPath=\"/tmp/run dir/ssh/\(OpenSSHTransport.controlToken(for: host))\""))
        #expect(arguments.contains("LogLevel=ERROR"))
        #expect(arguments.contains("ConnectTimeout=10"))
        for (flag, value) in [("-F", "/tmp/lima.conf"), ("-p", "2222"), ("-i", "/keys/id")] {
            let index = arguments.firstIndex(of: flag)
            #expect(index.map { arguments[$0 + 1] } == value, "\(flag)")
        }
        // Options come before the destination, which follows `--`, so a
        // destination can never be read as an option.
        let dash = arguments.firstIndex(of: "--") ?? 0
        #expect(arguments.firstIndex(of: "-F").map { $0 < dash } == true)
    }

    @Test func interactiveSessionsGetATerminalAndNoBatchMode() throws {
        let transport = OpenSSHTransport(controlDirectory: "/tmp/x/ssh", environment: ["TERM": "dumb"])
        let invocation = try transport.interactive(host, remoteCommand: "exec /bin/sh -c 'true'")
        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.arguments.first == "-tt")
        #expect(!invocation.arguments.contains("BatchMode=yes"))
        #expect(invocation.arguments.suffix(3) == ["--", "me@vm.example", "exec /bin/sh -c 'true'"])
        #expect(try transport.interactive(host, remoteCommand: nil).arguments.last == "me@vm.example")
    }

    @Test func aDestinationThatLooksLikeAnOptionIsRefused() async {
        let transport = OpenSSHTransport(controlDirectory: "/tmp/x/ssh", environment: [:])
        let evil = ArmadaleCore.Host(name: "x", sshDestination: "-oProxyCommand=touch /tmp/pwned")
        await #expect(throws: BackendError.self) { _ = try await transport.run(evil, "true") }
        #expect(throws: BackendError.self) { _ = try transport.interactive(evil, remoteCommand: nil) }
    }

    @Test func theClientEnvironmentHasNoRuntimeVariables() {
        let environment = OpenSSHTransport.clientEnvironment([
            "PATH": "/usr/bin", "SSH_AUTH_SOCK": "/agent", "ZMX_SESSION": "a-x", "ZMX_DIR": "/d",
            "ARMADALE_STATE_DIR": "/s", "TMUX": "1", "TERM": "xterm-ghostty",
        ])
        #expect(environment["SSH_AUTH_SOCK"] == "/agent")
        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment.keys.allSatisfy { !$0.hasPrefix("ZMX_") && !$0.hasPrefix("ARMADALE_") })
        #expect(environment["TMUX"] == nil)
    }

    // MARK: Failures and quoting

    @Test func sshFailuresAreClassified() {
        #expect(SSHFailure.classify(.ok()) == nil)
        #expect(SSHFailure.classify(.failed(1, "Permission denied")) == nil, "only ssh's own status counts")
        #expect(SSHFailure.classify(.refused) == .unreachable("ssh: connect to host test.invalid port 22: Connection refused"))
        #expect(SSHFailure.classify(.failed(255, "me@vm: Permission denied (publickey).\n"))
            == .needsInteraction("me@vm: Permission denied (publickey)."))
        #expect(SSHFailure.classify(.failed(255, "Host key verification failed.\n")) == .needsInteraction("Host key verification failed."))
        #expect(SSHFailure.classify(.failed(255, "")) == .unreachable("ssh exited with status 255"))
    }

    @Test func remotePathsExpandHomeAndQuoteTheRest() {
        #expect(RemoteShell.path("~") == "\"$HOME\"")
        #expect(RemoteShell.path("~/.armadale/bin/zmx-0.8.1") == "\"$HOME\"/.armadale/bin/zmx-0.8.1")
        #expect(RemoteShell.path("~/my dir") == "\"$HOME\"/'my dir'")
        #expect(RemoteShell.path("/opt/it's") == "'/opt/it'\\''s'")
        #expect(RemoteShell.sh("echo hi") == "exec /bin/sh -c 'echo hi'")
    }

    @Test func theUploadScriptChecksTheTemporaryFileBeforeRenamingIt() {
        let script = RemoteShell.uploadScript(to: "~/.armadale/bin/zmx-0.8.1", mode: 0o755, size: 42, sha256: "ab12")
        #expect(script.hasPrefix("umask 077; dir=\"$HOME\"/.armadale/bin; tmp=\"$dir\"/.zmx-0.8.1.partial.$$; "))
        #expect(script.contains("[ $(wc -c < \"$tmp\") -eq 42 ] || fail 5"))
        #expect(script.contains("[ \"${h%% *}\" = ab12 ] || fail 6"))
        #expect(script.hasSuffix("chmod 755 \"$tmp\" && mv -f \"$tmp\" \"$dir\"/zmx-0.8.1 || fail $?"))
        // The rename comes after both checks.
        let rename = script.range(of: "mv -f")?.lowerBound
        #expect(rename.map { $0 > (script.range(of: "fail 6")?.lowerBound ?? script.endIndex) } == true)
        #expect(!script.contains("\n"))
    }

    /// sshd hands every remote command to the user's login shell. Each one
    /// Armadale sends is a single line, and parses both in tcsh (macOS
    /// ships /bin/tcsh; csh rejects a newline inside quotes) and in sh: the
    /// outer `exec /bin/sh -c` is swapped for `/bin/sh -n -c`, so the
    /// command is parsed, never run.
    @Test func everyRemoteCommandIsOneLineThatTcshAndShAccept() async throws {
        let layout = RemoteLayout(directory: "~/my folder/.armadale")
        let session = Session(
            id: SessionID(raw: "abcdefghijklmnop"), location: .remote(host: host.id), profileID: Profile.shell.id,
            launch: LaunchSpec(program: "claude", arguments: ["--say", "it's \"quoted\" $HOME `x`"], environment: ["FOO": "a; b"]),
            workingDirectory: "~/src/my app")
        let script = RemoteZmxEndpoint.sessionScript(
            for: session, appVersion: "1.0", unsetRuntimeVariables: true, exitFile: layout.exitFile(for: session.id))
        let commands = [
            RemoteZmxEndpoint.clientCommand(["attach", "a-abcdefghijklmnop", "/bin/sh", "-c", script], layout: layout, version: "0.8.1"),
            RemoteZmxEndpoint.clientCommand(["attach", "a-abcdefghijklmnop", "true"], layout: layout, version: "0.8.1"),
            RemoteZmxEndpoint.controlCommand(["ls", "--short"], layout: layout, version: "0.8.1"),
            RemoteShell.sh(RemoteShell.uploadScript(to: layout.binary(version: "0.8.1"), mode: 0o755, size: 10, sha256: "ab")),
            RemoteShell.sh(RemoteDeployer.verifyScript(layout: layout, version: "0.8.1")),
            RemoteShell.sh(RemoteDeployer.presenceCheck(layout.binary(version: "0.8.1"))),
            RemoteShell.sh(RemoteZmxEndpoint.sessionScript(for: session, appVersion: "1.0", unsetRuntimeVariables: false)),
            RemoteShell.sh("exit 0"),
            RemoteZmxEndpoint.exitStatusCommand(for: [session.id, SessionID(raw: "qrstuvwxyz234567")], layout: layout),
        ]
        let runner = CommandRunner()
        for command in commands {
            #expect(!command.contains("\n"), "\(command)")
            #expect(command.hasPrefix("exec /bin/sh -c "))
            let parseOnly = "exec /bin/sh -n -c " + command.dropFirst("exec /bin/sh -c ".count)
            for shell in ["/bin/tcsh", "/bin/sh", "/bin/zsh"] {
                let result = try await runner.run(
                    executable: shell, arguments: ["-c", parseOnly], environment: testEnvironment(["HOME": "/tmp"]))
                #expect(result.status == 0, "\(shell): \(result.stderrText) in \(command)")
            }
        }
        // The session script itself (run by /bin/sh inside the session).
        let inner = try await runner.run(executable: "/bin/sh", arguments: ["-n", "-c", script], environment: testEnvironment())
        #expect(inner.status == 0, "\(inner.stderrText)")
    }

    /// The upload script really works (run by the local /bin/sh), and a
    /// failing write leaves nothing behind.
    @Test func theUploadScriptRunsUnderSh() async throws {
        let home = "/tmp/armadale-up-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        defer { if home.hasPrefix("/tmp/armadale-up-") { try? FileManager.default.removeItem(atPath: home) } }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let transport = LoopbackTransport(home: home, environment: testEnvironment(["HOME": home]))
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let result = try await transport.upload(host, data: payload, toRemotePath: "~/.armadale/bin/tool", mode: 0o755)
        #expect(result.status == 0, "\(result.stderrText)")
        let written = home + "/.armadale/bin/tool"
        #expect(FileManager.default.contents(atPath: written) == payload)
        #expect(access(written, X_OK) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home + "/.armadale/bin") == ["tool"])

        // A stream cut short (the connection dropped mid-upload): remote
        // `cat` sees EOF and succeeds, but nothing is installed.
        let full = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let script = RemoteShell.uploadScript(
            to: "~/.armadale/bin/short", mode: 0o755, size: full.count, sha256: RemoteShell.sha256Hex(full))
        let short = try await transport.run(host, RemoteShell.sh(script), input: full.prefix(100_000))
        #expect(short.status == RemoteShell.uploadSizeMismatchStatus)
        // Right size, wrong bytes.
        var damaged = full
        damaged[1000] ^= 0xFF
        let corrupt = try await transport.run(host, RemoteShell.sh(script), input: damaged)
        #expect(corrupt.status == RemoteShell.uploadHashMismatchStatus)
        #expect(!FileManager.default.fileExists(atPath: home + "/.armadale/bin/short"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: home + "/.armadale/bin") == ["tool"], "no temporary file left")

        // A directory that cannot be created.
        try Data().write(to: URL(fileURLWithPath: home + "/blocked"))
        let failed = try await transport.upload(host, data: payload, toRemotePath: "~/blocked/bin/tool", mode: 0o755)
        #expect(failed.status != 0)
    }
}
