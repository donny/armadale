import ArmadaleCore
import ArmadaleSessions
import Foundation

/// Restore at launch (docs/DESIGN.md section 4, "Restore at launch"):
/// panes on screen are started by ``startIfNeeded(_:)`` as their window
/// lays them out; every other restored session is brought up here once its
/// location's first listing has answered, in sidebar order
/// (``AppModel/sessionOrder``, closed workspaces included), as
/// ``LaunchAttachPlan`` says: alive with a saved size → attached at that
/// size, a few at a time (``LaunchAttachQueue``); alive without one → left
/// until its pane is first shown; gone → ended through its controller with
/// its recorded exit status. A host whose listing needs the user starts
/// nothing for panes not on screen until one of its sessions connects.
extension SessionRegistry {
    /// Where a session's attach is paced.
    static func lane(of session: Session) -> LaunchAttachQueue.Lane {
        session.remoteHostID.map(LaunchAttachQueue.Lane.host) ?? .local
    }

    /// The restored sessions the launch pass may still bring up, in sidebar
    /// order: not started because a pane showed them, not attached, not
    /// queued, and at `lane`.
    private func waitingRestoredSessions(in lane: LaunchAttachQueue.Lane) -> [SessionController] {
        model.sessionOrder.compactMap { id in
            guard restoredSessionIDs.contains(id), !startRequested.contains(id), !launchQueue.isQueued(id),
                  launchQueue.inFlight[id] == nil, let controller = controllers[id], controller.state == .detached,
                  Self.lane(of: controller.session) == lane
            else { return nil }
            return controller
        }
    }

    /// The local launch pass, once the local listing has answered
    /// (``localListed``, ``localSockets``). Runs again after a successful
    /// ``retryPersistence()``.
    /// Under the plain PTY fallback the persistent restored sessions are
    /// unavailable already; plain ones from an earlier run are not listed,
    /// so they end.
    func runLocalLaunchPass() async {
        var gone: [SessionController] = []
        var attach: [LaunchAttachQueue.Item] = []
        for controller in waitingRestoredSessions(in: .local) {
            let session = controller.session
            let liveness = LaunchAttachPlan.localLiveness(of: session.id, listed: localListed, sockets: localSockets)
            switch LaunchAttachPlan.disposition(liveness, savedSize: model.session(session.id)?.gridSize) {
            case .attach: attach.append(.init(id: session.id, lane: .local))
            case .markEnded: gone.append(controller)
            case .leave: break
            }
        }
        await markEnded(gone)
        launchQueue.enqueue(attach)
        pumpLaunchQueue()
    }

    /// The launch pass of `host`, once its listing has answered
    /// (``hostListings``). A host that needs the user is left alone: its
    /// sessions wait until one of its panes is shown and signs in, then
    /// the host is listed again (``relist(_:)``).
    ///
    /// The host's attached sessions are capped
    /// (``LaunchAttachPlan/maximumHiddenAttachedPerHost``): sessions past the
    /// cap, in sidebar order, stay not attached until their pane is shown.
    func runHostLaunchPass(host: HostID) async {
        guard let listing = hostListings[host], remoteBackend(for: host) != nil else { return }
        var gone: [SessionController] = []
        var attach: [LaunchAttachQueue.Item] = []
        // Hidden sessions whose retries stopped because the host needed the
        // user: the host answers again, so they reconnect (within the cap).
        // The marker stays until the session connects, is closed or is
        // respawned, so one dropped at the cap is still reconnected when its
        // pane is shown.
        if case .live = listing {
            for id in model.sessionOrder where waitingForUser.contains(id) && !launchQueue.isQueued(id)
                && launchQueue.inFlight[id] == nil {
                // Only this host's: another host's answer says nothing about
                // whether that one would prompt.
                guard let controller = controllers[id], controller.session.remoteHostID == host,
                      controller.state.isDisconnected, !controller.isReconnecting, paneViews.view(for: id) == nil
                else { continue }
                attach.append(.init(id: id, lane: .host(host), kind: .retry))
            }
        }
        for controller in waitingRestoredSessions(in: .host(host)) {
            let session = controller.session
            guard RestorePolicy.isPersistent(session) else { continue }
            let liveness: LaunchLiveness
            switch listing {
            case .needsUser: return
            case .unreachable: liveness = .unknown
            case .live(let live): liveness = live.contains(session.id) ? .alive : .gone
            }
            switch LaunchAttachPlan.disposition(liveness, savedSize: model.session(session.id)?.gridSize) {
            case .attach: attach.append(.init(id: session.id, lane: .host(host)))
            case .markEnded: gone.append(controller)
            case .leave: break
            }
        }
        await markEnded(gone)
        let queued = launchQueue.queued.count { $0.lane == .host(host) }
        let room = LaunchAttachPlan.maximumHiddenAttachedPerHost - heldSessions(on: host) - queued
        launchQueue.enqueue(Array(attach.prefix(max(0, room))))
        pumpLaunchQueue()
    }

    /// How many of `host`'s sessions have a client or are getting one:
    /// attached, attaching, retrying by themselves, or started and waiting
    /// (panes on screen and sessions the user started included).
    func heldSessions(on host: HostID, excluding excluded: SessionID? = nil) -> Int {
        controllers.values.count { controller in
            let id = controller.session.id
            guard controller.session.remoteHostID == host, id != excluded else { return false }
            switch controller.state {
            case .attached, .attaching: return true
            case .disconnected: return controller.isReconnecting
            case .detached: return launchQueue.inFlight[id] != nil || startsInProgress.contains(id)
            case .ended, .unavailable: return false
            }
        }
    }

    /// Starts what the queue allows.
    func pumpLaunchQueue() {
        for item in launchQueue.take() {
            startLaunchAttach(item)
        }
    }

    /// A launch attach: a session whose pane view was never made has its
    /// surface given the saved grid first
    /// (``TerminalSurface/setGridSize(columns:rows:)``), so the attach asks
    /// for the size the program already has and sends it no resize; one
    /// with a pane view connects at its terminal's grid. A retry reconnects
    /// a session the first attempt (or a stop for a sign-in) left
    /// disconnected.
    private func startLaunchAttach(_ item: LaunchAttachQueue.Item) {
        guard let controller = controllers[item.id] else {
            launchQueue.finished(item.id, outcome: .done)
            pumpLaunchQueue()
            return
        }
        Task {
            // Its pane was shown in the meantime: ``startIfNeeded(_:)`` has
            // taken it over (at its laid-out size) and reports its end.
            if item.kind == .attach, startRequested.contains(item.id) { return }
            // The host's cap may have been reached meanwhile (panes shown,
            // sessions started): this one waits until its pane is shown.
            if case .host(let host) = item.lane,
               heldSessions(on: host, excluding: item.id) >= LaunchAttachPlan.maximumHiddenAttachedPerHost {
                launchStartFinished(item.id, lane: item.lane, controller: controller, kind: item.kind)
                return
            }
            switch item.kind {
            case .attach:
                if controller.state == .detached, let size = model.session(item.id)?.gridSize {
                    // A terminal in a pane view gets its grid only from that
                    // pane's layout: only a session whose pane view was
                    // never made is given its saved grid.
                    if paneViews.view(for: item.id) == nil {
                        controller.surface.setGridSize(columns: size.columns, rows: size.rows)
                    }
                    await controller.start(.attach)
                }
            case .retry:
                if controller.state.isDisconnected { await controller.reconnect() }
            }
            launchStartFinished(item.id, lane: item.lane, controller: controller, kind: item.kind)
        }
    }

    /// A start counted by the queue has ended: a local first attach that
    /// left its session disconnected is owed one retry once the queue has
    /// drained; the next ones start.
    func launchStartFinished(
        _ id: SessionID, lane: LaunchAttachQueue.Lane, controller: SessionController, kind: LaunchAttachQueue.Kind
    ) {
        let missed = kind == .attach && lane == .local && controller.state.isDisconnected
        launchQueue.finished(id, outcome: missed ? .disconnected : .done)
        pumpLaunchQueue()
    }
}
