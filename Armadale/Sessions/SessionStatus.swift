/// What a session's (or a tab's) status glyph shows.
enum SessionStatus: Sendable, Hashable {
    /// Its process is alive (attached, or alive in the backend but not
    /// shown yet).
    case running
    /// Not started yet, connecting, or restored and not yet confirmed alive
    /// or gone by the launch probe.
    case pending
    /// Its process has exited.
    case ended
    /// Armadale lost its connection; it may still be running.
    case disconnected
    /// The persistent runtime is unavailable in this run.
    case unavailable

    /// The summary of several sessions (a tab's panes): a problem wins,
    /// then running, then pending; ended only if every one has ended.
    static func summary(of statuses: [SessionStatus]) -> SessionStatus {
        for candidate in [SessionStatus.disconnected, .unavailable, .running, .pending] where statuses.contains(candidate) {
            return candidate
        }
        return .ended
    }
}

/// Whether closing some sessions needs a confirmation. Pure, so the rule is
/// testable apart from the registry.
struct CloseRisk: Equatable, Sendable {
    /// One session about to be closed.
    struct Item: Sendable {
        var status: SessionStatus
        /// The session may exist in its backend: it was restored from an
        /// earlier run, or a start has been attempted in this one. A session
        /// created in this run whose pane was never shown has no process.
        var mayExist: Bool
        /// Its controller reports a live process.
        var isRunning: Bool = false
    }

    /// Some may still be running (or are disconnected and may be).
    var mayBeRunning: Bool
    /// Some cannot be reached at all; closing leaves them running.
    var unreachable: Bool

    /// A pending session that may exist counts as possibly running: until
    /// the launch probe has answered, a restored session that was never
    /// shown may well be alive, and one that is connecting may be too.
    static func assess(_ items: [Item]) -> CloseRisk {
        let mayBeRunning = items.contains { item in
            switch item.status {
            case .running, .disconnected: true
            case .pending: item.mayExist || item.isRunning
            case .ended, .unavailable: item.isRunning
            }
        }
        return CloseRisk(mayBeRunning: mayBeRunning, unreachable: items.contains { $0.status == .unavailable })
    }
}
