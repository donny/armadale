import ArmadaleCore
import Foundation

/// Creates, attaches to and manages persistent sessions for one location
/// (this Mac, or one SSH host). Implementations are actors or otherwise
/// thread-safe; everything crossing the boundary is `Sendable`.
public protocol PersistenceBackend: Sendable {
    /// Attaches to `session`, creating it if it does not exist. `size` is
    /// the PTY's initial window size, so the program's first output is laid
    /// out for the pane it appears in.
    func create(_ session: Session, size: PTYSize) async throws -> any ProcessHandle
    /// Attaches to `session` only if it already exists; never creates one.
    func attach(_ session: Session, size: PTYSize) async throws -> any ProcessHandle
    /// Whether the session is alive.
    func exists(_ id: SessionID) async throws -> Bool
    /// All live sessions this backend owns.
    func liveSessions() async throws -> Set<SessionID>
    /// Ends the session and reaps its daemon.
    func kill(_ id: SessionID) async throws
    /// The session's scrollback and screen as VT bytes. Live sessions only:
    /// an ended session has no history left to read.
    func history(_ id: SessionID) async throws -> Data
    /// Decides what the exit of a session's client process means. A zmx
    /// client exits both when its session ends and when it is merely
    /// disconnected (its exit status is always 0), so the backend looks at
    /// the session itself. Never throws: a backend that cannot tell answers
    /// ``ExitResolution/detached`` and lets one reattach settle it.
    func resolveExit(of session: Session) async -> ExitResolution
}

/// What the exit of a session's client process meant.
public enum ExitResolution: Sendable, Hashable {
    /// The session is gone (its program exited, or it was killed).
    case ended
    /// Only the client went away; the session is still alive and can be
    /// reattached.
    case detached
}

/// Failures common to every ``PersistenceBackend``.
public enum BackendError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The backend cannot reattach: its sessions do not outlive the app.
    /// For a remote host, `reason` says why the host cannot keep sessions
    /// (an unsupported system, a home directory that cannot be written).
    case notPersistent(reason: String?)
    /// The session does not exist (any more).
    case noSuchSession(SessionID)
    /// The backend keeps no history for this session.
    case historyUnavailable(SessionID)
    /// The session runtime failed: a control command exited with an error
    /// or timed out, or a client could not be started.
    case runtimeFailure(String)
    /// The session's host could not be reached (ssh could not connect, or
    /// the connection was lost). The session may well still be running
    /// there; nothing is known about it.
    case unreachable(String)
    /// The host refused the connection in a way retrying cannot fix: the
    /// key was rejected, the host key changed, or signing in failed. The
    /// session may be alive; the pane stays disconnected until the user
    /// reconnects.
    case authenticationFailed(String)

    public var description: String {
        switch self {
        case .notPersistent(let reason?): reason
        case .notPersistent(nil): "Sessions of this kind do not survive quitting Armadale."
        case .unreachable(let message), .authenticationFailed(let message): message
        case .noSuchSession(let id): "Session \(id) does not exist."
        case .historyUnavailable(let id): "No history is kept for session \(id)."
        case .runtimeFailure(let message): message
        }
    }
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
///
/// `write` and `resize` are synchronous and only enqueue: calls take effect
/// in the order they are made, which async methods called from separate
/// tasks could not guarantee (keystrokes must never be reordered).
public protocol ProcessHandle: AnyObject, Sendable {
    /// Output bytes, delivered in coalesced batches. Finishes when the
    /// process closes its side of the PTY. Supports a single consumer.
    var output: AsyncStream<[UInt8]> { get }
    /// Queues input for the process.
    func write(_ bytes: [UInt8])
    /// Queues a PTY resize (`TIOCSWINSZ`).
    func resize(_ size: PTYSize)
    /// Asks the process to exit (SIGHUP, then SIGKILL after a grace period)
    /// and returns once it has.
    func terminate() async
    /// Suspends until the process exits, then returns its exit code, or
    /// `nil` if it was killed by a signal or its status is unknown.
    var exitStatus: Int32? { get async }
    /// Whether the process has not exited yet.
    var isRunning: Bool { get }
    /// Version of the session runtime this client belongs to, when the
    /// backend has one (the zmx version that created a session). The app
    /// records it on the ``Session`` after a create.
    var runtimeVersion: String? { get }
    /// Disconnects at once, without waiting: hangs up the process and
    /// closes its terminal. Safe to call while the app is quitting.
    func hangUp()
    /// For clients that buffer output without limit (zmx 0.8.1), the client
    /// process's memory footprint in bytes, which is where an output backlog
    /// accumulates when the pane cannot keep up; `nil` for handles that do
    /// not report it (plain PTY processes, where backpressure works). The
    /// controller drops and reattaches a client whose footprint stays large.
    var clientFootprint: UInt64? { get }
    /// Why this client's session will not outlive the app although its
    /// backend is persistent (a remote host that could not take Armadale's
    /// persistence helper, so the session is a plain ssh shell); `nil`
    /// normally. Shown as a "not persistent" badge.
    var persistenceNote: String? { get }
    /// Set once the client has ended without ever connecting to its
    /// session (an interactive sign-in that failed, was abandoned or timed
    /// out): the controller then shows the reason and does not retry by
    /// itself, instead of asking whether the session still exists.
    var connectionFailure: String? { get }
}

extension ProcessHandle {
    public var runtimeVersion: String? { nil }
    public var clientFootprint: UInt64? { nil }
    public var persistenceNote: String? { nil }
    public var connectionFailure: String? { nil }
    public func hangUp() {
        Task { await terminate() }
    }
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
    /// Armadale lost its connection to the session (its client keeps
    /// going away, or cannot attach); the session may still be running.
    case disconnected(reason: String)
    /// The session's runtime is not available in this run (the persistent
    /// backend could not be set up); the session may still be running and
    /// is left alone.
    case unavailable(reason: String)

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

    public var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }

    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}
