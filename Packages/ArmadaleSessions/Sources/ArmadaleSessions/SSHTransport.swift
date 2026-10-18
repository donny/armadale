import ArmadaleCore
import CryptoKit
import Darwin
import Foundation

/// How Armadale reaches SSH hosts (docs/DESIGN.md section 6): one-shot
/// control commands, uploads, and the command line of an interactive
/// session that runs on a pane's PTY. ``OpenSSHTransport`` is the real
/// implementation; tests use fakes.
///
/// Remote commands are shell command lines, parsed by the user's login
/// shell on the host (``RemoteShell`` builds them). Results are returned
/// whatever their status; ssh's own failures (it could not connect, or
/// authentication needs the user) are status 255, which ``SSHFailure``
/// classifies.
public protocol SSHTransport: Sendable {
    /// Runs `remoteCommand` on `host` non-interactively (no prompts, no
    /// terminal), with `input` on its stdin (else `/dev/null`).
    func run(_ host: ArmadaleCore.Host, _ remoteCommand: String, input: Data?) async throws -> CommandResult
    /// Writes `data` to `remotePath` (absolute or `~/…`) with permissions
    /// `mode`, creating its directory, through a temporary file and an
    /// atomic rename (a running binary is never written over, which Linux
    /// refuses with ETXTBSY anyway). The temporary file is checked before
    /// the rename: its size, and its SHA-256 where the host has a tool for
    /// it; a short or damaged upload (a dropped connection makes the
    /// remote `cat` see an early EOF and succeed) is removed and fails
    /// with ``RemoteShell/uploadSizeMismatchStatus`` or
    /// ``RemoteShell/uploadHashMismatchStatus``. A host without a hash tool
    /// prints ``RemoteShell/noHashToolMarker``.
    func upload(_ host: ArmadaleCore.Host, data: Data, toRemotePath remotePath: String, mode: Int) async throws -> CommandResult
    /// The ssh command line of an interactive session on a PTY running
    /// `remoteCommand` (a login shell when `nil`). Prompts (host keys,
    /// passphrases) appear on that terminal.
    func interactive(_ host: ArmadaleCore.Host, remoteCommand: String?) throws -> SSHInvocation
}

extension SSHTransport {
    /// Runs `remoteCommand` with stdin closed.
    public func run(_ host: ArmadaleCore.Host, _ remoteCommand: String) async throws -> CommandResult {
        try await run(host, remoteCommand, input: nil)
    }

    public func upload(_ host: ArmadaleCore.Host, data: Data, toRemotePath remotePath: String, mode: Int) async throws -> CommandResult {
        let script = RemoteShell.uploadScript(
            to: remotePath, mode: mode, size: data.count, sha256: RemoteShell.sha256Hex(data))
        return try await run(host, RemoteShell.sh(script), input: data)
    }
}

/// A program and its arguments, ready to be spawned.
public struct SSHInvocation: Sendable, Hashable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// What a failed ssh invocation (exit status 255) means.
public enum SSHFailure: Sendable, Hashable {
    /// The host could not be reached, or the connection was lost.
    case unreachable(String)
    /// The host answered, but connecting without prompts failed: an
    /// unknown host key, or a key that needs a passphrase (or a password).
    /// An interactive ssh may be able to prompt for it; whether it does
    /// decides between signing in and ``refused``.
    case needsInteraction(String)
    /// The host refused in a way no prompt can fix (its host key changed,
    /// too many authentication failures).
    case refused(String)

    /// The status ssh exits with when it fails itself.
    public static let exitStatus: Int32 = 255

    /// `nil` unless `result` is ssh's own failure.
    public static func classify(_ result: CommandResult) -> SSHFailure? {
        guard result.status == exitStatus else { return nil }
        let message = summary(of: result)
        let lowered = message.lowercased()
        let whole = result.stderrText.lowercased()
        let refusals = ["remote host identification has changed", "too many authentication failures"]
        if refusals.contains(where: whole.contains) { return .refused(message) }
        let interactive = [
            "host key verification failed", "permission denied", "passphrase", "password",
            "no more authentication methods", "authenticity of host",
        ]
        if interactive.contains(where: lowered.contains) { return .needsInteraction(message) }
        return .unreachable(message)
    }

    /// ssh's last meaningful line of stderr, for messages.
    static func summary(of result: CommandResult) -> String {
        let lines = result.stderrText.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return lines.last ?? "ssh exited with status \(result.status)"
    }

    public var message: String {
        switch self {
        case .unreachable(let message), .needsInteraction(let message), .refused(let message): message
        }
    }

    /// As a backend error: unreachable (retried), or refused (terminal).
    /// Nothing is known about the session either way.
    var backendError: BackendError {
        switch self {
        case .unreachable(let message): .unreachable(message)
        case .needsInteraction(let message), .refused(let message): .authenticationFailed(message)
        }
    }

    /// Whether `text` (an interactive ssh's output so far) ends in a
    /// question for the user: a password, a passphrase, a host key, a code.
    static func isPrompt(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["password:", "passphrase", "are you sure you want to continue connecting", "(yes/no",
                "verification code", "one-time password", "pin for"].contains(where: lowered.contains)
    }
}

/// Building blocks of remote command lines. Every command Armadale runs on
/// a host is a `/bin/sh` script (``sh(_:)``), so it behaves the same
/// whatever the user's login shell is (bash, zsh, fish, tcsh).
public enum RemoteShell {
    /// `word` quoted for POSIX shells.
    public static func quote(_ word: String) -> String {
        LaunchResolver.shellQuoted(word)
    }

    /// A path on the host as a shell word: `~` and `~/…` become the home
    /// directory (`"$HOME"`, which also works where the path follows `=`),
    /// anything else is quoted literally.
    public static func path(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + quote(String(path.dropFirst(2))) }
        return quote(path)
    }

    /// The command line that runs `script` with `/bin/sh` on the host.
    public static func sh(_ script: String) -> String {
        "exec /bin/sh -c " + quote(script)
    }

    /// The upload's temporary file had the wrong size: nothing installed.
    public static let uploadSizeMismatchStatus: Int32 = 5
    /// The upload's temporary file had the wrong SHA-256: nothing installed.
    public static let uploadHashMismatchStatus: Int32 = 6
    /// Printed by an upload on a host with neither `sha256sum` nor
    /// `shasum` (only the size was checked).
    public static let noHashToolMarker = "armadale-no-hash-tool"

    /// Writes stdin to `remotePath` atomically: into a temporary file next
    /// to it, which must have `size` bytes and (where the host can hash)
    /// SHA-256 `sha256` before it is given `mode` and renamed over the
    /// destination. Directories it creates are private (umask 077); existing
    /// ones keep their permissions. Fails with the failing command's status
    /// (or a mismatch status), leaving no temporary file. One line, so any
    /// login shell (csh and fish included) passes it on intact.
    public static func uploadScript(to remotePath: String, mode: Int, size: Int, sha256: String) -> String {
        let directory = (remotePath as NSString).deletingLastPathComponent
        let name = (remotePath as NSString).lastPathComponent
        let octal = String(mode, radix: 8)
        return "umask 077; dir=\(path(directory.isEmpty ? "." : directory)); tmp=\"$dir\"/.\(quote(name)).partial.$$; "
            + "fail() { status=$1; rm -f \"$tmp\"; exit \"$status\"; }; "
            + "mkdir -p \"$dir\" || fail $?; cat > \"$tmp\" || fail $?; "
            + "[ $(wc -c < \"$tmp\") -eq \(size) ] || fail \(uploadSizeMismatchStatus); "
            + "if command -v sha256sum >/dev/null 2>&1; then h=$(sha256sum \"$tmp\"); "
            + "elif command -v shasum >/dev/null 2>&1; then h=$(shasum -a 256 \"$tmp\"); "
            + "else h=none; echo \(noHashToolMarker); fi; "
            + "[ \"$h\" = none ] || [ \"${h%% *}\" = \(sha256) ] || fail \(uploadHashMismatchStatus); "
            + "chmod \(octal) \"$tmp\" && mv -f \"$tmp\" \"$dir\"/\(quote(name)) || fail $?"
    }

    /// Lowercase hex SHA-256 of `data`.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The system's OpenSSH client (docs/DESIGN.md section 6).
///
/// Every invocation shares one connection per host through multiplexing
/// (`ControlMaster=auto`, `ControlPersist=600`), with its control socket in
/// Armadale's runtime directory (``controlDirectory(forRuntimeDirectory:uid:)``),
/// so a workspace with twenty remote panes keeps one TCP connection per
/// host and later commands skip authentication. The user's ssh
/// configuration, keys and agent apply as usual: a destination may be an
/// `ssh_config` alias. `Host.sshConfigFile` replaces that configuration
/// (`-F`).
///
/// - Control commands: `ssh -T -o BatchMode=yes … -- <destination> <command>`
///   through a ``CommandRunner``, so they never prompt (a prompt has no one
///   to answer it), with a timeout.
/// - Interactive sessions: `ssh -tt … -- <destination> <command>`, which the
///   backend spawns on the pane's PTY, so prompts appear in the pane.
public struct OpenSSHTransport: SSHTransport {
    public var executable: String
    /// Where control sockets live (created 0700 on first use).
    public var controlDirectory: String
    /// The ssh client's environment.
    public var environment: [String: String]
    /// `ConnectTimeout`, in seconds.
    public var connectTimeout: Int = 10
    /// Limit for control commands.
    public var commandTimeout: Duration = .seconds(30)
    /// Limit for commands with input (uploads).
    public var uploadTimeout: Duration = .seconds(180)
    private let runner = CommandRunner()

    public init(
        controlDirectory: String,
        environment: [String: String] = OpenSSHTransport.clientEnvironment(),
        executable: String = "/usr/bin/ssh"
    ) {
        self.controlDirectory = controlDirectory
        self.environment = environment
        self.executable = executable
    }

    /// The ssh client's environment: the app's, without what describes the
    /// terminal Armadale was started from and without any `ZMX_*` (an
    /// inherited `ZMX_SESSION` must not reach anything), with
    /// `TERM=xterm-256color`, which ssh sends to the host for interactive
    /// sessions. `SSH_AUTH_SOCK` is kept, so the user's agent works.
    public static func clientEnvironment(
        _ base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = LaunchResolver.scrubbed(base).filter { !$0.key.hasPrefix("ZMX_") }
        environment["TERM"] = "xterm-256color"
        if environment["PATH", default: ""].isEmpty { environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        return environment
    }

    // MARK: Control sockets

    /// Length of the per-host token that names a control socket.
    public static let controlTokenLength = 16
    /// ssh binds a new master's socket at `ControlPath` plus `.` and 16
    /// random characters, then renames it, so the path must leave room.
    static let masterTemporarySuffixLength = 17

    /// `<runtime directory>/ssh` when a control socket there (with ssh's
    /// temporary suffix) fits a Unix socket path, else
    /// `/tmp/armadale-<uid>/ssh`. ssh's own `%C` (40 characters) would not
    /// fit under the default state directory, so the socket is named by a
    /// shorter token of the connection's parameters instead.
    public static func controlDirectory(forRuntimeDirectory runtimeDirectory: String, uid: uid_t = getuid()) -> String {
        let preferred = runtimeDirectory + "/ssh"
        return fitsControlSocket(in: preferred) ? preferred : "/tmp/armadale-\(uid)/ssh"
    }

    static func fitsControlSocket(in directory: String) -> Bool {
        directory.utf8.count + 1 + controlTokenLength + masterTemporarySuffixLength <= ZmxRuntime.maxSocketPathLength
    }

    /// 16 hex characters of a hash of everything that decides where a
    /// connection goes, so editing a host never reuses another host's
    /// connection.
    public static func controlToken(for host: ArmadaleCore.Host) -> String {
        let key = [host.sshDestination, host.port.map(String.init) ?? "", host.identityFile ?? "", host.sshConfigFile ?? ""]
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(controlTokenLength / 2).map { String(format: "%02x", $0) }.joined()
    }

    /// The host's control socket.
    public func controlPath(for host: ArmadaleCore.Host) -> String {
        controlDirectory + "/" + Self.controlToken(for: host)
    }

    // MARK: Command lines

    /// Options every invocation for `host` uses.
    public func options(for host: ArmadaleCore.Host) -> [String] {
        var options: [String] = []
        if let config = host.sshConfigFile, !config.isEmpty {
            options += ["-F", (config as NSString).expandingTildeInPath]
        }
        if let port = host.port { options += ["-p", String(port)] }
        if let identity = host.identityFile, !identity.isEmpty {
            options += ["-i", (identity as NSString).expandingTildeInPath]
        }
        // An -o value is parsed like a configuration line: quoted, so the
        // spaces of "Application Support" survive, and with % doubled,
        // because ControlPath expands % tokens.
        let controlPath = controlPath(for: host).replacingOccurrences(of: "%", with: "%%")
        options += [
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=600",
            "-o", "ControlPath=\"\(controlPath)\"",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            // Without it ssh prints "Shared connection to … closed." on the
            // pane's terminal after the session's last output, and
            // warnings before its first.
            "-o", "LogLevel=ERROR",
        ]
        return options
    }

    /// `ssh -T -o BatchMode=yes <options> -- <destination> <command>`.
    public func controlArguments(_ host: ArmadaleCore.Host, _ remoteCommand: String) -> [String] {
        ["-T", "-o", "BatchMode=yes"] + options(for: host) + ["--", host.sshDestination, remoteCommand]
    }

    /// `ssh -tt <options> -- <destination> [command]`.
    public func interactiveArguments(_ host: ArmadaleCore.Host, _ remoteCommand: String?) -> [String] {
        ["-tt"] + options(for: host) + ["--", host.sshDestination] + (remoteCommand.map { [$0] } ?? [])
    }

    // MARK: SSHTransport

    public func run(_ host: ArmadaleCore.Host, _ remoteCommand: String, input: Data?) async throws -> CommandResult {
        if let problem = ArmadaleCore.Host.destinationProblem(host.sshDestination) { throw BackendError.unreachable(problem) }
        prepareControlDirectory()
        do {
            return try await runner.run(
                executable: executable, arguments: controlArguments(host, remoteCommand),
                environment: environment, input: input,
                timeout: input == nil ? commandTimeout : uploadTimeout)
        } catch let timeout as CommandRunner.TimedOut {
            throw BackendError.unreachable("\(host.displayName) did not answer within \(timeout.timeout).")
        } catch {
            throw BackendError.runtimeFailure(String(describing: error))
        }
    }

    public func interactive(_ host: ArmadaleCore.Host, remoteCommand: String?) throws -> SSHInvocation {
        if let problem = ArmadaleCore.Host.destinationProblem(host.sshDestination) { throw BackendError.unreachable(problem) }
        prepareControlDirectory()
        return SSHInvocation(executable: executable, arguments: interactiveArguments(host, remoteCommand), environment: environment)
    }

    /// Whether a master connection to `host` is up (`ssh -O check`).
    public func hasMasterConnection(_ host: ArmadaleCore.Host) async -> Bool {
        let result = try? await runner.run(
            executable: executable, arguments: options(for: host) + ["-O", "check", "--", host.sshDestination],
            environment: environment, timeout: .seconds(5))
        return result?.status == 0
    }

    /// Closes the master connection to `host`, if any (`ssh -O exit`).
    public func closeMasterConnection(_ host: ArmadaleCore.Host) async {
        _ = try? await runner.run(
            executable: executable, arguments: options(for: host) + ["-O", "exit", "--", host.sshDestination],
            environment: environment, timeout: .seconds(5))
    }

    /// Creates the control directory (0700, owned by this user) if needed.
    private func prepareControlDirectory() {
        do {
            try ZmxRuntime(directory: controlDirectory).prepare()
        } catch {
            NSLog("Armadale: ssh control directory: %@", error.description)
        }
    }
}
