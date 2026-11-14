import ArmadaleCore

/// What to do with a session when it is started: when its pane is first
/// shown, or when the launch attaches it (``LaunchAttachPlan``).
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

/// Decides how restored sessions are brought up. Pure, so it can be tested
/// without the app.
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
    ///   - live: the backend's live sessions at launch (locally: listed, or
    ///     with a socket); `nil` if unknown.
    public func action(for session: Session, restored: Bool, live: Set<SessionID>?) -> RestoreAction {
        guard restored else { return .create }
        if !backendIsPersistent, Self.isPersistent(session) { return .markUnavailable }
        if let live, !live.contains(session.id) { return .markEnded }
        return .attach
    }
}
