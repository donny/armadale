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
    /// It rang the bell or posted a notification while nobody was looking
    /// (DESIGN §10). Only ever shown: ``withAttention(_:)`` makes it from
    /// one of the others, and close confirmation never sees it.
    case attention

    /// Precedence, most important first (DESIGN §1): a problem, then
    /// attention, then running, then pending; ended only if every one has
    /// ended.
    static let precedence: [SessionStatus] = [.disconnected, .unavailable, .attention, .running, .pending, .ended]

    /// The summary of several sessions (a tab's panes): the most important
    /// status any of them has (``precedence``).
    static func summary(of statuses: [SessionStatus]) -> SessionStatus {
        for candidate in precedence where statuses.contains(candidate) {
            return candidate
        }
        return .ended
    }

    /// What a session needing attention shows: attention, unless it is
    /// disconnected or unavailable, which matter more (it may be gone).
    func withAttention(_ needsAttention: Bool) -> SessionStatus {
        guard needsAttention else { return self }
        switch self {
        case .disconnected, .unavailable: return self
        case .running, .pending, .ended, .attention: return .attention
        }
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
            case .running, .disconnected, .attention: true
            case .pending: item.mayExist || item.isRunning
            case .ended, .unavailable: item.isRunning
            }
        }
        return CloseRisk(mayBeRunning: mayBeRunning, unreachable: items.contains { $0.status == .unavailable })
    }
}
