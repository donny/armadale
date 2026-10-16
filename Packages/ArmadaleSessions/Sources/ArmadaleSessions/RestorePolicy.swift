import ArmadaleCore

/// What to do with a pane's session when it is first shown.
public enum RestoreAction: Sendable, Hashable {
    /// A session new in this run: create it.
    case create
    /// A restored session that may be alive: attach (never create).
    case attach
    /// A restored session known to be gone: show it as ended.
    case markEnded
    /// A restored persistent session while the persistent runtime is not
    /// available: leave it alone (it may still be running).
    case markUnavailable
}

/// Decides how restored sessions are brought up, and which may be replaced
/// by Respawn All Ended. Pure, so it can be tested without the app.
public struct RestorePolicy: Sendable, Hashable {
    /// Whether the backend in use keeps sessions across launches. `false`
    /// when Armadale fell back to plain PTY sessions because the persistent
    /// runtime could not be set up.
    public var backendIsPersistent: Bool

    public init(backendIsPersistent: Bool) {
        self.backendIsPersistent = backendIsPersistent
    }

    /// Whether `session` was made by the persistent runtime and so may
    /// outlive the app (it records the runtime version that created it).
    public static func isPersistent(_ session: Session) -> Bool {
        session.runtimeVersion != nil
    }

    /// - Parameters:
    ///   - restored: the session was recorded by an earlier run.
    ///   - live: the backend's live sessions at launch; `nil` if unknown.
    public func action(for session: Session, restored: Bool, live: Set<SessionID>?) -> RestoreAction {
        guard restored else { return .create }
        if !backendIsPersistent, Self.isPersistent(session) { return .markUnavailable }
        if let live, !live.contains(session.id) { return .markEnded }
        return .attach
    }

    /// Whether Respawn All Ended may replace a restored session whose pane
    /// has not been shown yet: only one known to be gone, never one that is
    /// unavailable (it may still be running).
    public func mayRespawnUnshown(_ session: Session, restored: Bool, live: Set<SessionID>?) -> Bool {
        restored && live != nil && action(for: session, restored: restored, live: live) == .markEnded
    }
}
