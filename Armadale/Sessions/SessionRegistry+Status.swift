import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation
import TerminalSurface

/// Status (docs/DESIGN.md sections 1 and 8): each session's status and
/// glyph, close risk and the running count, and what a pane's header shows.
extension SessionRegistry {
    // MARK: Status

    /// The status of one session, from its controller; for a restored
    /// session that is not attached (its location has not answered, its
    /// host needs the user, or it has no saved size yet), from its
    /// location's listing at launch: alive → running, else starting.
    func status(of sessionID: SessionID) -> SessionStatus {
        guard let controller = controllers[sessionID] else {
            return model.session(sessionID) == nil ? .ended : .pending
        }
        // A host removed a moment ago: its controllers are hung up on the
        // next turn (``observeHosts()``), but the session is unreachable now.
        if isOnRemovedHost(controller) { return .unavailable }
        switch controller.state {
        case .attached: return .running
        case .ended: return .ended
        case .disconnected: return .disconnected
        case .unavailable: return .unavailable
        case .attaching: return .pending
        case .detached: return notAttachedStatus(of: controller.session)
        }
    }

    /// The one place the launch listing still gives a status: a restored
    /// session that is not attached. Its answer is not refreshed until the
    /// session is attached (docs/DESIGN.md section 1).
    private func notAttachedStatus(of session: Session) -> SessionStatus {
        guard restoredSessionIDs.contains(session.id) else { return .pending }
        if let host = session.remoteHostID {
            guard case .live(let live)? = hostListings[host] else { return .pending }
            return live.contains(session.id) ? .running : .pending
        }
        return localSockets.contains(session.id) || localListed?.contains(session.id) == true ? .running : .pending
    }

    /// The summary of several sessions (a tab's panes).
    func status(of sessionIDs: [SessionID]) -> SessionStatus {
        SessionStatus.summary(of: sessionIDs.map { status(of: $0) })
    }

    /// What a session's glyph shows: its status, or attention
    /// (``SessionStatus/withAttention(_:)``).
    func glyphStatus(of sessionID: SessionID) -> SessionStatus {
        status(of: sessionID).withAttention(attention?.needsAttention(sessionID) ?? false)
    }

    /// The glyph of several sessions (a tab's panes), by
    /// ``SessionStatus/precedence``.
    func glyphStatus(of sessionIDs: [SessionID]) -> SessionStatus {
        SessionStatus.summary(of: sessionIDs.map { glyphStatus(of: $0) })
    }

    /// Whether closing these sessions needs a confirmation (``CloseRisk``).
    func closeRisk(of sessionIDs: [SessionID]) -> CloseRisk {
        CloseRisk.assess(sessionIDs.map(riskItem(for:)))
    }

    /// How many of the model's sessions may still have a live process, by
    /// the close-confirmation rule (``CloseRisk/mayBeRunning(_:)``): what a
    /// quit asks about and the status item's menu shows.
    func runningSessionCount() -> Int {
        QuitDecision.runningCount(model.sessions.map { riskItem(for: $0.id) })
    }

    /// The local sessions of the persistent runtime that may still have a
    /// live process (``CloseRisk/mayBeRunning(_:)``): what a quit that keeps
    /// sessions leaves to the system (docs/DESIGN.md section 8, "Background
    /// App Activity"). None in the plain PTY fallback, where a quit ends
    /// them anyway; remote sessions leave no local process.
    func localSessionsThatMayOutliveQuit() -> [SessionID] {
        guard sessionsSurviveQuit else { return [] }
        return model.sessions.filter { Self.mayOutliveQuit($0, risk: riskItem(for: $0.id)) }.map(\.id)
    }

    /// One session's part of ``localSessionsThatMayOutliveQuit()``: local,
    /// made by the persistent runtime, and possibly running.
    nonisolated static func mayOutliveQuit(_ session: Session, risk: CloseRisk.Item) -> Bool {
        session.remoteHostID == nil && RestorePolicy.isPersistent(session) && CloseRisk.mayBeRunning(risk)
    }

    /// The sessions that may still have a live process and end with any
    /// quit (docs/DESIGN.md section 8, "Updates"): local ones on the plain
    /// PTY fallback, and those on a host that could not take the
    /// persistence helper (their client carries a persistence note).
    func sessionsThatEndAtQuit() -> [SessionID] {
        model.sessions.filter { session in
            let controller = controllers[session.id]
            return Self.endsAtQuit(
                session, risk: riskItem(for: session.id),
                isPlainLocal: controller?.activeBackend is EphemeralBackend,
                hasPersistenceNote: controller?.persistenceNote != nil)
        }.map(\.id)
    }

    /// One session's part of ``sessionsThatEndAtQuit()``. A session made by
    /// the persistent runtime (it records the runtime's version) survives
    /// a quit wherever it runs.
    nonisolated static func endsAtQuit(
        _ session: Session, risk: CloseRisk.Item, isPlainLocal: Bool, hasPersistenceNote: Bool
    ) -> Bool {
        guard CloseRisk.mayBeRunning(risk), !RestorePolicy.isPersistent(session) else { return false }
        return session.remoteHostID == nil ? isPlainLocal : hasPersistenceNote
    }

    func riskItem(for id: SessionID) -> CloseRisk.Item {
        let controller = controllers[id]
        return CloseRisk.Item(
            status: status(of: id),
            mayExist: restoredSessionIDs.contains(id) || controller.map { $0.state != .detached } ?? false,
            isRunning: controller?.isRunning ?? false)
    }

    /// What the header of `sessionID`'s pane card shows (DESIGN §8, "Pane
    /// cards"): its glyph (◐ while it needs attention), the session's title
    /// else its profile's name, its working directory once its program has
    /// reported it (else nothing: unknown), and its attention.
    func headerModel(for sessionID: SessionID) -> PaneHeaderModel {
        guard let session = model.session(sessionID) else {
            return PaneHeaderModel(status: glyphStatus(of: sessionID), title: "Shell", directory: nil)
        }
        return PaneHeaderModel(
            status: glyphStatus(of: sessionID),
            title: PaneHeaderModel.title(sessionTitle: session.title, profileName: model.profile(session.profileID)?.name),
            directory: reportedDirectories.contains(sessionID)
                ? model.abbreviatedDirectory(session.workingDirectory, location: session.location) : nil,
            needsAttention: attention?.needsAttention(sessionID) ?? false)
    }

    func displayName(of session: Session) -> String {
        if !session.title.isEmpty { return session.title }
        return model.profile(session.profileID)?.name ?? "Shell"
    }
}
