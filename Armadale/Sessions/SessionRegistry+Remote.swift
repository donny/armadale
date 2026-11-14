import AppKit
import ArmadaleCore
import ArmadaleSessions

/// Sessions on SSH hosts (docs/DESIGN.md section 6): one
/// ``RemoteZmxBackend`` per host, made when first needed and replaced when
/// the host's settings change; each host's listing, kept with why it
/// failed (``HostListing``); a removed host's sessions made unavailable.
extension SessionRegistry {
    /// Why a remote session cannot be reached at all: its host was removed
    /// (or remote sessions are off in this run).
    static let hostRemovedReason = "The host this session runs on was removed from Settings › Hosts."

    var unreachableHostReason: String {
        remote == nil ? "Remote sessions are not available in this run." : Self.hostRemovedReason
    }

    /// The backend for `host`, made on first use; `nil` if the host is gone
    /// (or remote sessions are off).
    func remoteBackend(for host: HostID) -> RemoteZmxBackend? {
        guard let remote, let settings = model.host(host) else { return nil }
        if let existing = remoteBackends[host], existing.host == settings { return existing }
        let backend = remote.makeBackend(for: settings)
        let versions = Dictionary(
            model.sessions.filter { $0.remoteHostID == host }.compactMap { session in session.runtimeVersion.map { (session.id, $0) } },
            uniquingKeysWith: { _, last in last })
        Task { await backend.noteRuntimeVersions(versions) }
        remoteBackends[host] = backend
        return backend
    }

    /// The host's listing, started on first use. When it answers it is
    /// kept (``hostListings``) and the host's launch pass runs
    /// (``runHostLaunchPass(host:)``).
    @discardableResult
    func hostListing(for host: HostID) -> Task<HostListing, Never> {
        if let listing = hostListingTasks[host] { return listing }
        guard let backend = remoteBackend(for: host) else { return Task { .unreachable } }
        let listing = Task<HostListing, Never> {
            do {
                return .live(try await backend.liveSessions())
            } catch BackendError.authenticationFailed {
                return .needsUser
            } catch {
                return .unreachable
            }
        }
        hostListingTasks[host] = listing
        Task { [weak self] in
            let answer = await listing.value
            // A listing replaced meanwhile (the host was edited) says nothing.
            guard let self, self.hostListingTasks[host] == listing else { return }
            self.hostListings[host] = answer
            if answer == .needsUser {
                self.hostsAwaitingUser.insert(host)
            } else {
                self.hostsAwaitingUser.remove(host)
            }
            if self.isLaunchPassStarted { await self.runHostLaunchPass(host: host) }
        }
        return listing
    }

    /// Before an automatic retry of a session whose pane has not been shown
    /// in this run: a batch-mode listing first, so no hidden pane ever
    /// starts an interactive sign-in by itself. Unreachable: keep to the
    /// schedule. Needs the user: stop retrying (Reconnect, or showing the
    /// pane, may prompt) and wait for a sign-in elsewhere, after which the
    /// host is listed again and this session reconnects. Answered: connect.
    /// A pane shown in this run retries as it always has.
    func retryPreflight(for controller: SessionController) async -> SessionController.RetryPreflight {
        let id = controller.session.id
        guard paneViews.view(for: id) == nil, let host = controller.session.remoteHostID,
              let backend = remoteBackend(for: host)
        else { return .connect }
        let answer: SessionController.RetryPreflight
        do {
            _ = try await backend.liveSessions()
            answer = .connect
        } catch BackendError.authenticationFailed(let message) {
            answer = .stop(reason: message)
        } catch {
            answer = .wait
        }
        // Judged against the session as it is now: its pane shown while the
        // host was being asked retries as a shown pane does (it may prompt).
        let currentID = controller.session.id
        guard paneViews.view(for: currentID) == nil else { return .connect }
        if case .stop = answer {
            hostsAwaitingUser.insert(host)
            waitingForUser.insert(currentID)
        }
        return answer
    }

    /// Lists `host` again (a sign-in connected one of its sessions, or its
    /// settings changed): the launch pass then runs for the sessions it
    /// left.
    func relist(_ host: HostID) {
        hostListingTasks[host] = nil
        hostListing(for: host)
    }

    /// The hosts of some sessions (a tab's panes), in order, without repeats.
    func hosts(of sessionIDs: [SessionID]) -> [ArmadaleCore.Host] {
        var seen: Set<HostID> = []
        return sessionIDs.compactMap { model.session($0)?.remoteHostID }.filter { seen.insert($0).inserted }.compactMap {
            model.host($0)
        }
    }

    /// Why one of these sessions will not survive quitting although it runs
    /// on a host (it could not take the persistence helper), if any.
    func persistenceNote(of sessionIDs: [SessionID]) -> String? {
        sessionIDs.lazy.compactMap { self.controllers[$0]?.persistenceNote }.first
    }

    /// Settings › Hosts › Test Connection: what the host is, and whether
    /// Armadale's helper is there. Throws when it cannot be reached.
    func testConnection(to host: ArmadaleCore.Host) async throws -> String {
        guard let remote else { throw BackendError.unreachable("Remote sessions are not available in this run.") }
        do {
            let probe = try await RemoteDeployer(host: host, transport: remote.transport).probe()
            let system = probe.platform?.displayName ?? probe.uname
            return probe.platform == nil
                ? "Connected. \(host.displayName) runs \(system), which Armadale can’t keep sessions on."
                : "Connected to \(system)." + (probe.isDeployed ? " The persistence helper is installed." : " The persistence helper will be installed when you first open a session there.")
        } catch let failure as SSHFailure {
            if case .needsInteraction = failure {
                throw BackendError.unreachable(failure.message
                    + " Armadale can’t answer prompts here: open a tab on this host to sign in, then test again.")
            }
            throw BackendError.unreachable(failure.message)
        }
    }

    /// Settings › Hosts › Deploy Now.
    func deployHelper(to host: ArmadaleCore.Host) async throws -> String {
        guard let remote else { throw BackendError.unreachable("Remote sessions are not available in this run.") }
        let deployer = RemoteDeployer(host: host, transport: remote.transport, binary: remote.binary)
        do {
            let deployment = try await deployer.deploy()
            return "Installed the persistence helper " + (deployment.platform.map { "for \($0.displayName) " } ?? "")
                + "in \(host.remoteDirectory) on \(host.displayName)."
        } catch let failure as SSHFailure {
            throw BackendError.unreachable(failure.message)
        }
    }

    /// Host edits apply from each session's next connection: the host gets a
    /// new backend and every controller of its sessions switches to it (a
    /// live client keeps running; its next reattach, reconnect or retry
    /// uses the new settings), and the host is listed again when it had been
    /// listed before (its launch pass then covers whatever still waits). A
    /// removed host's sessions are hung
    /// up and become unavailable, with a backend that refuses everything,
    /// so closing them later ends nothing on the host.
    func observeHosts() {
        let model = model
        hostsTask = Task { [weak self] in
            for await hosts in Observations({ model.hosts }) {
                guard let self else { return }
                let current = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for (id, backend) in self.remoteBackends where current[id] != backend.host {
                    self.remoteBackends[id] = nil
                    let hadListing = self.hostListingTasks.removeValue(forKey: id) != nil
                    self.hostListings[id] = nil
                    self.hostsAwaitingUser.remove(id)
                    let replacement = self.remoteBackend(for: id)
                    for controller in self.controllers.values where controller.session.remoteHostID == id {
                        if let replacement {
                            controller.useBackend(replacement, makeOutputFilter: { ZmxOutputFilter() })
                        } else {
                            self.launchQueue.remove(controller.session.id)
                            controller.detachAsUnavailable(
                                reason: Self.hostRemovedReason, backend: UnavailableBackend(reason: Self.hostRemovedReason))
                        }
                    }
                    if replacement != nil, hadListing { self.hostListing(for: id) }
                }
            }
        }
    }

    /// A workspace's window closed (or opened again): its remote sessions
    /// stop (or resume) retrying lost connections by themselves, whether
    /// their panes were ever shown or not.
    func setWindowOpen(_ isOpen: Bool, for workspace: WorkspaceID) {
        for id in model.sessionIDs(in: workspace) {
            guard let controller = controllers[id] else { continue }
            if isOpen { controller.resumeAutomaticReconnect() } else { controller.pauseAutomaticReconnect() }
        }
    }
}
