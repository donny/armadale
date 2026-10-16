import ArmadaleCore
import Foundation

/// Creates, attaches to and manages persistent sessions for one location
/// (this Mac, or one SSH host). Implementations are actors or otherwise
/// thread-safe; everything crossing the boundary is `Sendable`.
public protocol PersistenceBackend: Sendable {
    /// Attaches to `session`, creating it if it does not exist.
    func create(_ session: Session) async throws -> any ProcessHandle
    /// Attaches to `session` only if it already exists; never creates one.
    func attach(_ session: Session) async throws -> any ProcessHandle
    /// Whether the session is alive.
    func exists(_ id: SessionID) async throws -> Bool
    /// All live sessions this backend owns.
    func liveSessions() async throws -> Set<SessionID>
    /// Ends the session and reaps its daemon.
    func kill(_ id: SessionID) async throws
    /// The session's retained output, for display after it has ended.
    func history(_ id: SessionID) async throws -> Data
}

/// A PTY window size, as passed to `TIOCSWINSZ`.
public struct PTYSize: Sendable, Hashable {
    public var columns: UInt16
    public var rows: UInt16
    /// Width of the text area in pixels (0 if unknown).
    public var pixelWidth: UInt16
    /// Height of the text area in pixels (0 if unknown).
    public var pixelHeight: UInt16

    public init(columns: UInt16, rows: UInt16, pixelWidth: UInt16 = 0, pixelHeight: UInt16 = 0) {
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// A running client process attached to a session, usually through a PTY.
public protocol ProcessHandle: AnyObject, Sendable {
    /// Output bytes, delivered in coalesced batches. Finishes when the
    /// process closes its side of the PTY.
    var output: AsyncStream<[UInt8]> { get }
    /// Writes input to the process.
    func write(_ bytes: [UInt8]) async
    /// Resizes the PTY.
    func resize(_ size: PTYSize) async
    /// Asks the process to exit (SIGHUP, then SIGKILL after a grace period).
    func terminate() async
    /// Suspends until the process exits, then returns its exit code, or
    /// `nil` if it was killed by a signal or its status is unknown.
    var exitStatus: Int32? { get async }
}

/// The runtime state of a session as seen by its pane.
public enum SessionState: Sendable, Hashable {
    /// Not attached; the session may or may not be alive.
    case detached
    /// An attach is in progress.
    case attaching
    /// The pane's PTY is running the client.
    case attached
    /// The session's process has exited.
    case ended(exitCode: Int32?)
    /// The transport died; the session may still be alive on the host.
    case disconnected(reason: String)

    /// Whether the pane is connected to a live process.
    public var isAttached: Bool {
        if case .attached = self { return true }
        return false
    }

    /// Whether the session can never produce more output without a respawn.
    public var isEnded: Bool {
        if case .ended = self { return true }
        return false
    }
}
