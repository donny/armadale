import ArmadaleCore
import CryptoKit
import Darwin
import Foundation

/// Copies the bundled helpers to `<state dir>/bin/<name>-<version>` and
/// returns the copies to run (docs/DESIGN.md section 4, "Bundling").
///
/// Daemons therefore never hold open a binary inside an app bundle that an
/// update may replace, and the daemon's argv[0] names Armadale's own copy,
/// so `pgrep -f` can find Armadale's daemons.
///
/// - A copy is (re)written when it is missing or its SHA-256 differs from
///   the bundled binary, through a temporary file and an atomic rename, so
///   a running daemon keeps its old inode and nobody ever sees a partial
///   file. Copies are mode 0755.
/// - Older `zmx-<version>` copies are kept while any session still records
///   that version (zmx has no version handshake, so a daemon is always
///   attached with the binary that created it) and removed otherwise.
///   Older `ctty-exec-*` copies are always removed. A client's trampoline
///   execs into the client at once; a session's exit recorder
///   (`--exit-file`) keeps running the copy it was started from for the
///   life of the session, but the running process keeps its inode, so
///   removing the file does not disturb it, and nothing starts an old copy
///   again.
public struct HelperInstaller: Sendable {
    /// The installed helpers.
    public struct Installation: Sendable, Hashable {
        public let binDirectory: URL
        /// The zmx version this Armadale bundles.
        public let zmxVersion: String
        /// The installed copy of the bundled zmx.
        public let zmx: URL
        /// Every installed zmx copy by version, the current one included.
        public let zmxCopies: [String: URL]
        /// The installed copy of `ctty-exec`.
        public let cttyExec: URL

        /// The zmx copy for sessions created by `version`; the current one
        /// when `version` is `nil` or its copy is gone.
        public func zmx(forVersion version: String?) -> URL {
            version.flatMap { zmxCopies[$0] } ?? zmx
        }

        /// The zmx binaries as ``LocalZmxBackend`` takes them.
        public var zmxExecutables: ZmxExecutables {
            ZmxExecutables(
                currentVersion: zmxVersion,
                byVersion: zmxCopies.mapValues { plainPath($0) })
        }
    }

    /// Installing failed.
    public struct InstallError: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    public let binDirectory: URL
    public let zmxSource: URL
    public let zmxVersion: String
    public let cttyExecSource: URL
    /// Names the `ctty-exec` copy; the app's version.
    public let cttyExecVersion: String

    public init(binDirectory: URL, zmxSource: URL, zmxVersion: String, cttyExecSource: URL, cttyExecVersion: String) {
        self.binDirectory = binDirectory
        self.zmxSource = zmxSource
        self.zmxVersion = zmxVersion
        self.cttyExecSource = cttyExecSource
        self.cttyExecVersion = cttyExecVersion
    }

    /// The installer for the running app: helpers from ``HelperLocator``
    /// (honouring `ARMADALE_ZMX` and `ARMADALE_CTTY_EXEC`), copies in
    /// `bin/` of the state directory (honouring `ARMADALE_STATE_DIR`).
    public static func forApp(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) throws(HelperLocator.NotFound) -> HelperInstaller {
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return HelperInstaller(
            binDirectory: StateLocation.directory(environment: environment).appending(path: "bin", directoryHint: .isDirectory),
            zmxSource: try HelperLocator.zmx(environment: environment, mainBundle: bundle),
            zmxVersion: ZmxVersion.current,
            cttyExecSource: try HelperLocator.cttyExec(environment: environment, mainBundle: bundle),
            cttyExecVersion: appVersion)
    }

    /// Makes sure both copies exist and match the bundled binaries, removes
    /// copies nothing needs any more, and returns what to run.
    ///
    /// - Parameter referencedZmxVersions: `runtimeVersion` of every session
    ///   in the model; their zmx copies are kept.
    public func install(referencedZmxVersions: Set<String>) throws(InstallError) -> Installation {
        let directory = plainPath(binDirectory)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw InstallError(description: "Cannot create \(directory): \(error.localizedDescription)")
        }
        let zmxName = "zmx-\(zmxVersion)"
        let cttyName = "ctty-exec-\(cttyExecVersion)"
        try ensureCopy(of: zmxSource, named: zmxName, in: directory)
        try ensureCopy(of: cttyExecSource, named: cttyName, in: directory)

        var zmxCopies: [String: URL] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names {
            let path = directory + "/" + name
            if name.hasPrefix("zmx-") {
                let version = String(name.dropFirst(4))
                if version == zmxVersion || referencedZmxVersions.contains(version) {
                    zmxCopies[version] = URL(fileURLWithPath: path)
                } else {
                    unlink(path)
                }
            } else if name.hasPrefix("ctty-exec-"), name != cttyName {
                unlink(path)
            } else if name.hasPrefix("."), name.contains(".partial-") {
                unlink(path) // left over from an interrupted install
            }
        }
        return Installation(
            binDirectory: URL(fileURLWithPath: directory, isDirectory: true),
            zmxVersion: zmxVersion,
            zmx: URL(fileURLWithPath: directory + "/" + zmxName),
            zmxCopies: zmxCopies,
            cttyExec: URL(fileURLWithPath: directory + "/" + cttyName))
    }

    /// Writes `source` to `directory/name` unless an identical copy is there.
    private func ensureCopy(of source: URL, named name: String, in directory: String) throws(InstallError) {
        let destination = directory + "/" + name
        let contents: Data
        do {
            contents = try Data(contentsOf: source, options: .mappedIfSafe)
        } catch {
            throw InstallError(description: "Cannot read \(plainPath(source)): \(error.localizedDescription)")
        }
        if let existing = try? Data(contentsOf: URL(fileURLWithPath: destination), options: .mappedIfSafe),
           Self.sha256(existing) == Self.sha256(contents) {
            if access(destination, X_OK) != 0 { chmod(destination, 0o755) }
            return
        }
        // Contents only (no extended attributes such as quarantine); the
        // code signature is part of the Mach-O and comes along.
        let temporary = directory + "/.\(name).partial-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: temporary, contents: contents, attributes: [.posixPermissions: 0o755])
        else {
            throw InstallError(description: "Cannot write \(temporary)")
        }
        chmod(temporary, 0o755) // createFile's permissions are subject to the umask
        guard rename(temporary, destination) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary)
            throw InstallError(description: "Cannot install \(destination): \(reason)")
        }
    }

    static func sha256(_ data: Data) -> SHA256.Digest {
        SHA256.hash(data: data)
    }
}

/// The installed zmx binaries, by the version that created each session.
public struct ZmxExecutables: Sendable, Hashable {
    public let currentVersion: String
    /// Absolute paths by version; must contain ``currentVersion``.
    public let byVersion: [String: String]

    public init(currentVersion: String, byVersion: [String: String]) {
        self.currentVersion = currentVersion
        self.byVersion = byVersion
    }

    /// A single binary used for every version (tests).
    public init(path: String, version: String = ZmxVersion.current) {
        self.init(currentVersion: version, byVersion: [version: path])
    }

    /// The binary of the current version.
    public var current: String { byVersion[currentVersion] ?? byVersion.values.sorted().first ?? "zmx" }

    /// The binary and version to use for a session created by `version`;
    /// the current one when `version` is `nil` or has no installed copy.
    public func executable(forVersion version: String?) -> (path: String, version: String) {
        if let version, let path = byVersion[version] { return (path, version) }
        return (current, currentVersion)
    }
}
