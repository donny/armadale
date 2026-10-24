import ArmadaleCore
import CryptoKit
import Foundation

/// A system Armadale bundles its persistence helper (zmx) for.
public enum RemotePlatform: String, Sendable, Hashable, CaseIterable {
    case linuxAarch64 = "linux-aarch64"
    case linuxX86_64 = "linux-x86_64"
    case macosAarch64 = "macos-aarch64"
    case macosX86_64 = "macos-x86_64"

    /// The platform `uname -sm` describes (`Linux aarch64`, `Darwin arm64`),
    /// or `nil` for anything else (other systems and architectures; a
    /// Windows host does not even get this far).
    public init?(uname: String) {
        let words = uname.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard let system = words.first, let machine = words.last, words.count >= 2 else { return nil }
        switch (system, machine) {
        case ("linux", "aarch64"), ("linux", "arm64"): self = .linuxAarch64
        case ("linux", "x86_64"), ("linux", "amd64"): self = .linuxX86_64
        case ("darwin", "arm64"), ("darwin", "aarch64"): self = .macosAarch64
        case ("darwin", "x86_64"): self = .macosX86_64
        default: return nil
        }
    }

    /// For people: "Linux (ARM64)".
    public var displayName: String {
        switch self {
        case .linuxAarch64: "Linux (ARM64)"
        case .linuxX86_64: "Linux (x86-64)"
        case .macosAarch64: "macOS (Apple silicon)"
        case .macosX86_64: "macOS (Intel)"
        }
    }
}

/// Where Armadale's files live on a host: `<directory>/bin/zmx-<version>`
/// (the helper) and `<directory>/run` (its sessions, the remote `ZMX_DIR`).
/// Paths are as configured (`~/.armadale/…`); ``RemoteShell/path(_:)``
/// turns them into shell words.
public struct RemoteLayout: Sendable, Hashable {
    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    public func binary(version: String) -> String { directory + "/bin/zmx-" + version }
    public var runDirectory: String { directory + "/run" }
    public var logDirectory: String { runDirectory + "/logs" }
    /// Where a session's wrapper records its shell's exit status.
    public func exitFile(for id: SessionID) -> String {
        runDirectory + "/" + ZmxRuntime.sessionName(for: id) + ZmxRuntime.exitFileSuffix
    }
}

/// The outcome of making sure a host has the helper.
public struct RemoteDeployment: Sendable, Hashable {
    /// The host's platform.
    public var platform: RemotePlatform?
    public var version: String
    /// The helper was uploaded now (it was missing, of the wrong size, or a
    /// redeploy was asked for).
    public var uploaded: Bool
    /// For an upload: whether the host could check its SHA-256 (else only
    /// its size was checked).
    public var hashVerified: Bool = false
}

/// Puts Armadale's persistence helper on one host (docs/DESIGN.md
/// section 6) and checks it is there before every connection.
///
/// - ``ensureDeployed()``: `uname -sm` and the size of
///   `<directory>/bin/zmx-<version>` (one round trip over the shared
///   connection); if it is missing, not executable, or not the size of the
///   bundled binary, a deploy.
/// - A deploy runs `uname -sm`, picks the bundled binary for the platform,
///   uploads it (through a temporary file whose size and, where the host
///   has `sha256sum` or `shasum`, SHA-256 must match the bundled binary
///   before it is renamed into place), and checks that it runs (`zmx
///   version` prints the version). "Matches" means matches the bundled
///   binary, which the build verified against scripts/zmx.lock.
/// - A host that cannot take it (another system or architecture, a
///   directory that cannot be written, a helper that cannot run there, a
///   path too long for a socket) throws ``BackendError/notPersistent(reason:)``.
/// - ssh's own failures throw ``SSHFailure``.
///
/// Only one check or deploy runs at a time; callers arriving meanwhile
/// share its outcome.
public actor RemoteDeployer {
    public let host: ArmadaleCore.Host
    public let layout: RemoteLayout
    public let version: String
    private let transport: any SSHTransport
    /// The bundled binary for a platform.
    private let binary: @Sendable (RemotePlatform) throws -> URL
    private var inFlight: Task<RemoteDeployment, any Error>?

    public init(
        host: ArmadaleCore.Host,
        transport: any SSHTransport,
        version: String = ZmxVersion.current,
        binary: @escaping @Sendable (RemotePlatform) throws -> URL = { try HelperLocator.remoteZmx(for: $0) }
    ) {
        self.host = host
        self.layout = RemoteLayout(directory: host.remoteDirectory)
        self.version = version
        self.transport = transport
        self.binary = binary
    }

    /// Makes sure the helper of ``version`` is on the host, deploying it if
    /// it is not.
    public func ensureDeployed() async throws -> RemoteDeployment {
        try await serialized(force: false)
    }

    /// Settings › Hosts › Deploy Now: uploads and verifies the helper even
    /// if it is there already.
    public func deploy() async throws -> RemoteDeployment {
        try await serialized(force: true)
    }

    /// Settings › Hosts › Test Connection: the host's `uname -sm`, and
    /// whether the helper is installed there. Throws ``SSHFailure`` when
    /// ssh fails.
    public func probe() async throws -> (uname: String, platform: RemotePlatform?, isDeployed: Bool) {
        let result = try await transport.run(host, RemoteShell.sh(Self.presenceCheck(layout.binary(version: version))))
        if let failure = SSHFailure.classify(result) { throw failure }
        let lines = result.stdoutText.split(whereSeparator: \.isNewline).map(String.init)
        guard result.status == 0, let uname = lines.first else {
            throw BackendError.runtimeFailure(Self.describe(result, fallback: "The host did not run the test command."))
        }
        let platform = RemotePlatform(uname: uname)
        let installed = lines.count > 1 ? Int(lines[1].trimmingCharacters(in: .whitespaces)) : nil
        let deployed = platform.flatMap { bundledSize(for: $0) }.map { $0 == installed } ?? false
        return (uname, platform, deployed)
    }

    private func serialized(force: Bool) async throws -> RemoteDeployment {
        if let inFlight, !force { return try await inFlight.value }
        let previous = inFlight
        let task = Task {
            _ = try? await previous?.value
            return try await self.run(force: force)
        }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }
        return try await task.value
    }

    private func run(force: Bool) async throws -> RemoteDeployment {
        if !force {
            let check = try await transport.run(host, RemoteShell.sh(Self.presenceCheck(layout.binary(version: version))))
            if let failure = SSHFailure.classify(check) { throw failure }
            let lines = check.stdoutText.split(whereSeparator: \.isNewline).map(String.init)
            if check.status == 0, lines.count >= 2, let platform = RemotePlatform(uname: lines[0]),
               let installed = Int(lines[1].trimmingCharacters(in: .whitespaces)),
               let bundled = bundledSize(for: platform), installed == bundled {
                return RemoteDeployment(platform: platform, version: version, uploaded: false)
            }
            // Missing, not executable, or a different size (a damaged or
            // older copy): deploy again.
        }
        return try await upload()
    }

    /// `uname -sm`, then the helper's size in bytes, or `absent` when it is
    /// not an executable file.
    static func presenceCheck(_ binary: String) -> String {
        "uname -sm; b=\(RemoteShell.path(binary)); if test -x \"$b\" && test -f \"$b\"; then wc -c < \"$b\"; else echo absent; fi"
    }

    private func bundledSize(for platform: RemotePlatform) -> Int? {
        guard let url = try? binary(platform),
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        else { return nil }
        return size.intValue
    }

    private func upload() async throws -> RemoteDeployment {
        let name = host.displayName
        if let problem = ArmadaleCore.Host.remoteDirectoryProblem(layout.directory) {
            throw BackendError.notPersistent(reason: "The remote folder for \(name) can’t be used: \(problem)")
        }
        // 1. What is it?
        let probe = try await transport.run(host, RemoteShell.sh("uname -sm; printf '%s\\n' \"$HOME\""))
        if let failure = SSHFailure.classify(probe) { throw failure }
        let lines = probe.stdoutText.split(whereSeparator: \.isNewline).map(String.init)
        guard probe.status == 0, let uname = lines.first, let platform = RemotePlatform(uname: uname) else {
            let what = probe.status == 0 ? lines.first.map { "“\($0)”" } ?? "an unknown system" : "a system without a POSIX shell"
            throw BackendError.notPersistent(reason:
                "\(name) runs \(what). Armadale’s persistence helper runs on Linux and macOS (ARM64 and x86-64), "
                + "so sessions on this host end when Armadale quits.")
        }
        // 2. Will its sockets fit?
        let home = lines.count > 1 ? lines[1] : ""
        let runDirectory = Self.expanded(layout.runDirectory, home: home)
        guard ZmxRuntime.fits(runDirectory) else {
            throw BackendError.notPersistent(reason:
                "The folder \(runDirectory) on \(name) is too long a path for session sockets. "
                + "Choose a shorter remote folder in Settings › Hosts.")
        }
        // 3. Upload, checked on the host before it is put in place.
        let data: Data
        do {
            data = try Data(contentsOf: binary(platform), options: .mappedIfSafe)
        } catch {
            throw BackendError.notPersistent(reason:
                "This copy of Armadale doesn’t include its persistence helper for \(platform.displayName).")
        }
        let path = layout.binary(version: version)
        let uploaded = try await transport.upload(host, data: data, toRemotePath: path, mode: 0o755)
        if let failure = SSHFailure.classify(uploaded) { throw failure }
        switch uploaded.status {
        case 0:
            break
        case RemoteShell.uploadSizeMismatchStatus, RemoteShell.uploadHashMismatchStatus:
            NSLog("Armadale: upload of the persistence helper to %@ arrived damaged (status %d); nothing was installed",
                  name, uploaded.status)
            throw BackendError.runtimeFailure(
                "Armadale’s persistence helper was damaged on its way to \(name), so it was not installed. Try again.")
        default:
            throw BackendError.notPersistent(reason:
                "Armadale could not write to \(layout.directory) on \(name): "
                + Self.describe(uploaded, fallback: "the upload failed (status \(uploaded.status))."))
        }
        let hashVerified = !uploaded.stdoutText.contains(RemoteShell.noHashToolMarker)
        if !hashVerified {
            NSLog("Armadale: %@ has neither sha256sum nor shasum; the persistence helper was checked by size only", name)
        }
        // 4. Does it run there?
        let verified = try await transport.run(host, RemoteShell.sh(Self.verifyScript(layout: layout, version: version)))
        if let failure = SSHFailure.classify(verified) { throw failure }
        switch verified.status {
        case 0 where verified.stdoutText.contains(version):
            break
        case 3:
            throw BackendError.notPersistent(reason:
                "Armadale could not create \(layout.runDirectory) on \(name): " + Self.describe(verified, fallback: "permission denied."))
        default:
            NSLog("Armadale: the persistence helper does not run on %@ (status %d): %@",
                  name, verified.status, verified.stderrText + verified.stdoutText)
            _ = try? await transport.run(host, RemoteShell.sh("rm -f " + RemoteShell.path(path)))
            throw BackendError.notPersistent(reason: "\(name) can’t run Armadale’s persistence helper.")
        }
        return RemoteDeployment(platform: platform, version: version, uploaded: true, hashVerified: hashVerified)
    }

    /// Creates the run directory (private: umask 077; an existing one keeps
    /// its permissions, and no parent is ever changed) and runs the
    /// helper's `version`. Exit status 3: the directory could not be made;
    /// anything else non-zero: the helper does not run.
    static func verifyScript(layout: RemoteLayout, version: String) -> String {
        let binary = RemoteShell.path(layout.binary(version: version))
        let run = RemoteShell.path(layout.runDirectory)
        return "umask 077; mkdir -p \(run) || exit 3; env ZMX_DIR=\(run) \(binary) version || exit 4"
    }

    /// `path` with a leading `~` replaced by `home`.
    static func expanded(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    static func describe(_ result: CommandResult, fallback: String) -> String {
        let text = (result.stderrText.isEmpty ? result.stdoutText : result.stderrText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : String(text.suffix(400))
    }
}

extension SSHFailure: Error, CustomStringConvertible {
    public var description: String { message }
}
