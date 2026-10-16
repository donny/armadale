import ArmadaleCore
import Darwin
import Foundation

/// Where and how Armadale's private zmx runs (docs/DESIGN.md section 4,
/// "Isolation"): the runtime directory every zmx invocation uses as
/// `ZMX_DIR`, the environment of those invocations, the mapping between
/// session IDs and zmx session names, and cleanup of zmx's log files.
public struct ZmxRuntime: Sendable, Hashable {
    /// zmx limits `ZMX_DIR + "/" + name` to `sizeof(sun_path) - 1` bytes.
    public static let maxSocketPathLength = 103
    /// Every Armadale session name is this prefix plus a ``SessionID``.
    public static let sessionNamePrefix = "a-"
    /// Length in bytes of every Armadale session name (`a-` + 16 base32).
    public static let sessionNameLength = sessionNamePrefix.utf8.count + ShortIDGenerator.length

    /// The directory zmx keeps its sockets (and `logs/`) in.
    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    /// The runtime for Armadale's state directory: `<state dir>/run`, or
    /// `/tmp/armadale-<uid>` when that path is too long for a socket path.
    public init(stateDirectory: URL, uid: uid_t = getuid()) {
        self.init(directory: Self.directory(forStateDirectory: stateDirectory, uid: uid))
    }

    /// `<state dir>/run` if a session socket in it fits zmx's limit, else
    /// `/tmp/armadale-<uid>`. With the default state directory the fallback
    /// is only needed when `$HOME` is longer than 64 bytes.
    public static func directory(forStateDirectory stateDirectory: URL, uid: uid_t = getuid()) -> String {
        let preferred = (plainPath(stateDirectory) as NSString).appendingPathComponent("run")
        return fits(preferred) ? preferred : "/tmp/armadale-\(uid)"
    }

    /// Whether a session socket in `directory` stays within zmx's limit.
    public static func fits(_ directory: String) -> Bool {
        directory.utf8.count + 1 + sessionNameLength <= maxSocketPathLength
    }

    // MARK: Directory

    /// The runtime directory could not be set up.
    public struct SetupError: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    /// Creates the runtime directory with mode 0700 if needed, and checks
    /// that it is a real directory (not a symlink) owned by this user,
    /// which matters for the shared `/tmp` fallback: another user could
    /// otherwise pre-create it and see every session socket.
    public func prepare() throws(SetupError) {
        if mkdir(directory, 0o700) != 0 {
            let code = errno
            if code == ENOENT {
                let parent = (directory as NSString).deletingLastPathComponent
                do {
                    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                } catch {
                    throw SetupError(description: "Cannot create \(parent): \(error.localizedDescription)")
                }
                if mkdir(directory, 0o700) != 0, errno != EEXIST {
                    throw SetupError(description: "Cannot create \(directory): \(String(cString: strerror(errno)))")
                }
            } else if code != EEXIST {
                throw SetupError(description: "Cannot create \(directory): \(String(cString: strerror(code)))")
            }
        }
        var info = stat()
        guard lstat(directory, &info) == 0 else {
            throw SetupError(description: "Cannot inspect \(directory): \(String(cString: strerror(errno)))")
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw SetupError(description: "\(directory) is not a directory")
        }
        guard info.st_uid == getuid() else {
            throw SetupError(description: "\(directory) belongs to another user")
        }
        if info.st_mode & 0o777 != 0o700, chmod(directory, 0o700) != 0 {
            throw SetupError(description: "Cannot restrict \(directory): \(String(cString: strerror(errno)))")
        }
    }

    // MARK: Environment

    /// The environment of every zmx invocation: `base` without
    /// `ZMX_SESSION`/`ZMX_SESSION_PREFIX` (an inherited `ZMX_SESSION` turns
    /// `attach` into a switch that, in 0.8.1, kills that other session),
    /// with `ZMX_DIR` set to the runtime directory and the detach key off
    /// so Ctrl+\ reaches the program.
    public func environment(base: [String: String]) -> [String: String] {
        var environment = base
        environment["ZMX_SESSION"] = nil
        environment["ZMX_SESSION_PREFIX"] = nil
        environment["ZMX_DIR"] = directory
        environment["ZMX_NO_DETACH_KEY"] = "1"
        return environment
    }

    // MARK: Names

    /// `a-<id>`.
    public static func sessionName(for id: SessionID) -> String {
        sessionNamePrefix + id.raw
    }

    /// The session ID in an Armadale session name; `nil` for any name that
    /// is not exactly `a-` followed by 16 lowercase base32 characters, so
    /// foreign sessions in the same directory are never touched.
    public static func sessionID(fromName name: some StringProtocol) -> SessionID? {
        guard name.hasPrefix(sessionNamePrefix) else { return nil }
        let raw = String(name.dropFirst(sessionNamePrefix.count))
        guard ShortIDGenerator.isWellFormed(raw) else { return nil }
        return SessionID(raw: raw)
    }

    /// The socket of session `id`.
    public func socketPath(for id: SessionID) -> String {
        directory + "/" + Self.sessionName(for: id)
    }

    // MARK: Logs

    /// zmx's log directory, `<runtime>/logs`.
    public var logDirectory: String { directory + "/logs" }

    /// Removes the log of one session that has been killed or has ended
    /// for good (zmx never deletes logs).
    public func removeLog(for id: SessionID) {
        unlink(logDirectory + "/" + Self.sessionName(for: id) + ".log")
    }

    /// Removes `logs/a-<id>.log` files whose session is neither live nor
    /// referenced by the model (zmx never deletes them). Other files,
    /// including zmx's shared `zmx.log`, are left alone. Returns the paths
    /// removed.
    @discardableResult
    public func collectGarbageLogs(live: Set<SessionID>, referenced: Set<SessionID>) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: logDirectory) else { return [] }
        var removed: [String] = []
        for name in names.sorted() where name.hasSuffix(".log") {
            guard let id = Self.sessionID(fromName: name.dropLast(4)),
                  !live.contains(id), !referenced.contains(id)
            else { continue }
            let path = logDirectory + "/" + name
            if unlink(path) == 0 { removed.append(path) }
        }
        return removed
    }
}

/// A file URL's path without percent-encoding or a trailing slash.
func plainPath(_ url: URL) -> String {
    var path = url.standardizedFileURL.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
}
