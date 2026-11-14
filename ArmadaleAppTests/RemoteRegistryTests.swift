import AppKit
import ArmadaleCore
import ArmadaleSessions
import Foundation
import Synchronization
import Testing

/// An SSH transport for app tests: answers listings from `live` (or fails
/// like an unreachable host, or like one that needs a password), answers
/// exit records from `exitStatuses`, holds answers back until released,
/// can hold every command but listings (what an attach runs first) until
/// `releaseConnects()`, and never starts a process (interactive clients are
/// refused).
final class ScriptedTransport: SSHTransport {
    private struct State {
        var live: [String] = []
        var isDown = false
        var needsUser = false
        var isReleased = true
        var holdsConnects = false
        var heldConnects = 0
        var commands: [String] = []
        var exitStatuses: [String: Int] = [:]
        var presence: String?
        var attachable = false
        var holdsListings = false
        var needsUserDestinations: Set<String> = []
        var interactiveByDestination: [String: Int] = [:]
        var heldListings = 0
        var interactiveCalls = 0
    }

    private let state = Mutex(State())

    init(live: [SessionID] = [], released: Bool = true) {
        state.withLock {
            $0.live = live.map { "a-" + $0.raw }
            $0.isReleased = released
        }
    }

    func setDown(_ down: Bool) { state.withLock { $0.isDown = down } }
    func setNeedsUser(_ value: Bool) { state.withLock { $0.needsUser = value } }
    /// Like ``setNeedsUser(_:)`` for one host only.
    func setNeedsUser(_ value: Bool, for destination: String) {
        state.withLock { if value { $0.needsUserDestinations.insert(destination) } else { $0.needsUserDestinations.remove(destination) } }
    }
    func interactiveCalls(for destination: String) -> Int { state.withLock { $0.interactiveByDestination[destination] ?? 0 } }
    func setLive(_ live: [SessionID]) { state.withLock { $0.live = live.map { "a-" + $0.raw } } }
    func setExitStatuses(_ statuses: [SessionID: Int]) {
        state.withLock { $0.exitStatuses = Dictionary(uniqueKeysWithValues: statuses.map { ("a-" + $0.key.raw, $0.value) }) }
    }
    /// What the helper's presence check answers (`uname`, then its size),
    /// so an attach gets as far as starting its ssh client.
    func setPresence(_ answer: String?) { state.withLock { $0.presence = answer } }
    /// Interactive clients start a stand-in that writes what a zmx attach
    /// writes first and then waits, so attaches succeed.
    func setAttachable(_ value: Bool) { state.withLock { $0.attachable = value } }
    /// How many interactive clients were asked for (attaches and sign-ins).
    var interactiveCalls: Int { state.withLock { $0.interactiveCalls } }
    /// Holds listings (and only them) until `releaseListings()`.
    func holdListings() { state.withLock { $0.holdsListings = true } }
    func releaseListings() { state.withLock { $0.holdsListings = false } }
    var heldListings: Int { state.withLock { $0.heldListings } }
    func holdConnects() { state.withLock { $0.holdsConnects = true } }
    func releaseConnects() { state.withLock { $0.holdsConnects = false } }
    /// Commands other than listings waiting in ``holdConnects()``.
    var heldConnects: Int { state.withLock { $0.heldConnects } }
    var listings: Int { commands.filter { $0.contains("ls --short") }.count }
    func release() { state.withLock { $0.isReleased = true } }
    var commands: [String] { state.withLock { $0.commands } }

    func run(_ host: ArmadaleCore.Host, _ remoteCommand: String, input: Data?) async throws -> CommandResult {
        state.withLock { $0.commands.append(remoteCommand) }
        while !state.withLock({ $0.isReleased }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let isListing = remoteCommand.contains("ls --short")
        if isListing, state.withLock({ $0.holdsListings }) {
            state.withLock { $0.heldListings += 1 }
            defer { state.withLock { $0.heldListings -= 1 } }
            while state.withLock({ $0.holdsListings }) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        if !isListing, state.withLock({ $0.holdsConnects }) {
            state.withLock { $0.heldConnects += 1 }
            defer { state.withLock { $0.heldConnects -= 1 } }
            while state.withLock({ $0.holdsConnects }) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let (down, needsUser, live, statuses, presence) = state.withLock {
            ($0.isDown, $0.needsUser || $0.needsUserDestinations.contains(host.sshDestination), $0.live, $0.exitStatuses,
             $0.presence)
        }
        if down {
            return CommandResult(status: 255, stdout: Data(), stderr: Data("ssh: connect to host vm port 22: Connection refused\n".utf8))
        }
        if needsUser {
            return CommandResult(status: 255, stdout: Data(), stderr: Data("dev@vm: Permission denied (publickey,password).\n".utf8))
        }
        if isListing {
            return CommandResult(status: 0, stdout: Data(live.map { $0 + "\n" }.joined().utf8), stderr: Data())
        }
        if let presence, remoteCommand.contains("uname -sm; b=") {
            return CommandResult(status: 0, stdout: Data(presence.utf8), stderr: Data())
        }
        if remoteCommand.contains(".exit") {
            let lines = statuses.filter { remoteCommand.contains($0.key) }.map { "\($0.key) \($0.value)\n" }
            return CommandResult(status: 0, stdout: Data(lines.joined().utf8), stderr: Data())
        }
        return CommandResult(status: 0, stdout: Data(), stderr: Data())
    }

    func interactive(_ host: ArmadaleCore.Host, remoteCommand: String?) throws -> SSHInvocation {
        let attachable = state.withLock { state -> Bool in
            state.interactiveCalls += 1
            state.interactiveByDestination[host.sshDestination, default: 0] += 1
            return state.attachable
        }
        guard attachable, remoteCommand?.contains("attach") == true else {
            throw BackendError.unreachable("no interactive sessions in app tests")
        }
        return SSHInvocation(
            executable: "/bin/sh", arguments: ["-c", "printf '\\033[2J\\033[H'; exec sleep 600"],
            environment: ["PATH": "/usr/bin:/bin"])
    }
}

/// How the session registry treats sessions on SSH hosts: per-host probes
/// that never block and never end a session the host has not confirmed
/// gone, removed hosts, and Respawn All Ended.
@Suite("Remote sessions in the registry")
@MainActor
struct RemoteRegistryTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private struct Fixture {
        let model: AppModel
        let registry: SessionRegistry
        let transport: ScriptedTransport
        let remote: SessionID
        let host: HostID
        let settings: AppSettings
    }

    /// A model with one workspace whose only tab runs on a host, and a
    /// registry that restored it, with the transport `makeTransport` makes
    /// for that session.
    private func makeFixture(
        persistent: Bool = true, makeTransport: (SessionID) -> ScriptedTransport = { _ in ScriptedTransport() }
    ) -> Fixture {
        _ = NSApplication.shared // panes make surfaces with NSApp's appearance
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        model.fillEmptyPanes()
        let host = model.addHost(name: "VM", sshDestination: "vm")
        let group = model.workspace(workspace)?.selectedTabGroupID ?? TabGroupID(raw: "missing")
        let local = model.tabGroup(group)?.tabs.first?.id
        let tab = model.newTab(in: group, starting: Profile.shell.id, at: .remote(host: host), workingDirectory: "~") ?? TabID(raw: "missing")
        // Only the remote tab is left.
        if let local { model.closeTab(local) }
        let remote = model.sessionIDs(ofTab: tab).first ?? SessionID(raw: "missing")
        if persistent { model.setRuntimeVersion(ZmxVersion.current, for: remote) }
        let settings = AppSettings.forTesting()
        let transport = makeTransport(remote)
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: true),
            restoredSessionIDs: Set(model.sessions.map(\.id)),
            settings: settings,
            remote: RemoteSessionSupport(transport: transport, cttyExec: nil, appVersion: "test"))
        registry.startLaunchPass()
        return Fixture(model: model, registry: registry, transport: transport, remote: remote, host: host, settings: settings)
    }

    @Test func aRestoredSessionIsStartingUntilItsHostAnswers() async throws {
        let f = makeFixture { _ in ScriptedTransport(released: false) }
        defer { f.settings.removeTestDefaults() }
        #expect(f.registry.status(of: f.remote) == .pending, "launch does not wait for the host")
        // The probe is under way in the background.
        #expect(await eventually { f.transport.commands.contains { $0.contains("ls --short") } })
        #expect(f.registry.status(of: f.remote) == .pending)
        f.transport.release()
        // The host lists nothing: the session is gone.
        #expect(await eventually { f.registry.status(of: f.remote) == .ended })
    }

    @Test func aSessionTheHostListsIsRunning() async throws {
        let f = makeFixture { ScriptedTransport(live: [$0]) }
        defer { f.settings.removeTestDefaults() }
        #expect(await eventually { f.registry.status(of: f.remote) == .running })
        let workspace = try #require(f.model.workspaces.first?.id)
        #expect(!f.registry.hasEndedSessions(in: workspace))
    }

    @Test func anUnreachableHostNeverEndsItsSessions() async throws {
        let f = makeFixture { _ in
            let transport = ScriptedTransport()
            transport.setDown(true)
            return transport
        }
        defer { f.settings.removeTestDefaults() }
        #expect(await eventually { f.transport.commands.count >= 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.registry.status(of: f.remote) == .pending)
        let workspace = try #require(f.model.workspaces.first?.id)
        #expect(!f.registry.hasEndedSessions(in: workspace))
        // Respawn All Ended leaves it alone.
        f.registry.respawnAllEnded(in: workspace)
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.model.session(f.remote) != nil, "not replaced")
        #expect(!f.transport.commands.contains { $0.contains(" kill ") })
    }

    @Test func respawnAllEndedOnlyTouchesAHostThatAnswersAgain() async throws {
        let f = makeFixture()
        defer { f.settings.removeTestDefaults() }
        #expect(await eventually { f.registry.status(of: f.remote) == .ended })
        let workspace = try #require(f.model.workspaces.first?.id)
        #expect(f.registry.hasEndedSessions(in: workspace))
        // Down by the time Respawn All Ended runs: its fresh listing fails.
        f.transport.setDown(true)
        let listings = f.transport.commands.filter { $0.contains("ls --short") }.count
        f.registry.respawnAllEnded(in: workspace)
        #expect(await eventually { f.transport.commands.filter { $0.contains("ls --short") }.count > listings })
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.model.session(f.remote) != nil, "not respawned while the host is down")
    }

    @Test func aPlainSessionFromAnEarlierRunHasEnded() async throws {
        let f = makeFixture(persistent: false)
        defer { f.settings.removeTestDefaults() }
        #expect(f.registry.status(of: f.remote) == .ended)
        let workspace = try #require(f.model.workspaces.first?.id)
        #expect(f.registry.hasEndedSessions(in: workspace))
    }

    @Test func aSessionWhoseHostWasRemovedIsUnavailableAndLeftRunning() async throws {
        let f = makeFixture()
        defer { f.settings.removeTestDefaults() }
        f.model.removeHost(f.host)
        #expect(f.registry.status(of: f.remote) == .unavailable)
        #expect(f.registry.closeRisk(of: [f.remote]).unreachable, "closing always asks")
        let controller = try #require(f.registry.paneView(for: f.remote)?.controller)
        #expect(controller.state == .unavailable(reason: SessionRegistry.hostRemovedReason))
        f.registry.close(f.remote)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!f.transport.commands.contains { $0.contains(" kill ") }, "never killed")
    }

    @Test func remoteSessionsGetAReconnectScheduleAndTheHostBadge() async throws {
        let f = makeFixture()
        defer { f.settings.removeTestDefaults() }
        let controller = try #require(f.registry.paneView(for: f.remote)?.controller)
        #expect(controller.reconnectSchedule == ReconnectSchedule())
        #expect(f.registry.hosts(of: [f.remote]).map(\.id) == [f.host])
        #expect(f.registry.remoteBackend(for: f.host) === f.registry.remoteBackend(for: f.host), "one backend per host")
    }

    @Test func editingAHostGivesItANewBackend() async throws {
        let f = makeFixture()
        defer { f.settings.removeTestDefaults() }
        let before = try #require(f.registry.remoteBackend(for: f.host))
        var edited = try #require(f.model.host(f.host))
        edited.port = 2222
        f.model.updateHost(edited)
        let after = try #require(f.registry.remoteBackend(for: f.host))
        #expect(before !== after)
        #expect(after.host.port == 2222)
    }

    /// Removing a host whose pane exists: the pane becomes unavailable with
    /// a backend that refuses everything; closing it kills nothing.
    @Test func removingAHostMakesItsPanesUnavailableAndUnkillable() async throws {
        let f = makeFixture()
        defer { f.settings.removeTestDefaults() }
        let controller = try #require(f.registry.paneView(for: f.remote)?.controller)
        _ = f.registry.remoteBackend(for: f.host)
        f.model.removeHost(f.host)
        #expect(await eventually { controller.state == .unavailable(reason: SessionRegistry.hostRemovedReason) })
        #expect(controller.activeBackend is UnavailableBackend)
        f.registry.close(f.remote)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!f.transport.commands.contains { $0.contains(" kill ") })
    }

    /// Editing a host: its panes' next connect uses the new settings.
    @Test func editingAHostSwitchesItsPanesToTheNewBackend() async throws {
        let f = makeFixture()
        defer { f.settings.removeTestDefaults() }
        let controller = try #require(f.registry.paneView(for: f.remote)?.controller)
        var edited = try #require(f.model.host(f.host))
        edited.port = 2222
        f.model.updateHost(edited)
        #expect(await eventually {
            (controller.activeBackend as? RemoteZmxBackend)?.host.port == 2222
        })
        #expect((controller.activeBackend as? RemoteZmxBackend) === f.registry.remoteBackend(for: f.host))
    }

    /// File › New Tab on Host and New Tab with Profile are gone (step 10:
    /// every new pane asks, and the New Session dialog picks the host).
    @Test func theFileMenuHasNoHostOrProfileSubmenus() throws {
        let main = MainMenu.make(installsSpecialMenus: false)
        let file = try #require(main.items.first { $0.title == "File" }?.submenu)
        #expect(!file.items.contains { $0.title == "New Tab on Host" })
        #expect(!file.items.contains { $0.title == "New Tab with Profile" })
        #expect(!file.items.contains { $0.submenu != nil }, "no submenus left in File")
        #expect(file.items.prefix(3).map(\.title) == ["New Workspace", "New Tab Group", "New Tab"])
    }
}

/// Restore at launch on hosts (docs/DESIGN.md section 4, "Restore at
/// launch"): once a host's first listing has answered, its restored
/// sessions whose panes are not shown are attached at their saved size (two
/// at a time), left without one, or ended; an unreachable host gets the
/// attach attempt; a host that needs the user starts nothing hidden until
/// one of its sessions connects. The scripted transport answers the
/// helper's presence check, so an attach gets as far as its ssh client,
/// which the transport refuses as unreachable: "attached" here means
/// "tried, and left Disconnected", never ended.
@Suite("Launch attach on hosts")
@MainActor
struct RemoteLaunchAttachTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    struct Fixture {
        let model: AppModel
        let registry: SessionRegistry
        let transport: ScriptedTransport
        let host: HostID
        let sessions: [SessionID]
        let settings: AppSettings
        let binary: URL
        @MainActor func cleanUp() {
            settings.removeTestDefaults()
            try? FileManager.default.removeItem(at: binary.deletingLastPathComponent())
        }
    }

    /// `count` restored persistent sessions on one host, each in its own
    /// tab, the first `sized` with a saved grid of 101×33; `configure` sets
    /// the transport up before the registry lists the host.
    private func makeFixture(
        count: Int, sized: Int, removeHost: Bool = false, closedWindow: Bool = false,
        schedule: ReconnectSchedule = ReconnectSchedule(budget: .zero), startPass: Bool = true,
        configure: (ScriptedTransport, [SessionID]) -> Void = { _, _ in }
    ) throws -> Fixture {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let local = try #require(model.tabGroup(group)?.tabs.first?.id)
        let host = model.addHost(name: "VM", sshDestination: "vm")
        for _ in 0..<count {
            _ = try #require(model.newTab(in: group, starting: Profile.shell.id, at: .remote(host: host), workingDirectory: "~"))
        }
        model.closeTab(local)
        let sessions = model.sessionOrder
        for id in sessions { model.setRuntimeVersion(ZmxVersion.current, for: id) }
        model.setGridSizes(Dictionary(uniqueKeysWithValues: sessions.prefix(sized).map { ($0, SessionGridSize(columns: 101, rows: 33)) }))
        if removeHost { model.removeHost(host) }
        if closedWindow {
            model.updateWindowState(WindowState(
                frame: nil, sidebarWidth: nil, sidebarCollapsed: false, isOpen: false, isFullScreen: false), for: workspace)
        }
        // A stand-in for the bundled helper: the presence check reports its size.
        let folder = FileManager.default.temporaryDirectory.appending(path: "armadale-rl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appending(path: "zmx")
        try Data(count: 1234).write(to: binary)
        let transport = ScriptedTransport()
        transport.setPresence("Linux aarch64\n1234\n")
        configure(transport, sessions)
        let settings = AppSettings.forTesting()
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: true),
            restoredSessionIDs: Set(sessions), settings: settings,
            remote: RemoteSessionSupport(
                transport: transport, cttyExec: nil, appVersion: "test",
                reconnectSchedule: schedule, binary: { _ in binary }))
        if startPass { registry.startLaunchPass() }
        return Fixture(
            model: model, registry: registry, transport: transport, host: host, sessions: sessions, settings: settings,
            binary: binary)
    }

    /// Commands that are neither listings nor exit records: what an attach
    /// runs.
    private func connects(_ transport: ScriptedTransport) -> [String] {
        transport.commands.filter { !$0.contains("ls --short") && !$0.contains(".exit") }
    }

    @Test func afterTheFirstListingEachSessionGetsItsDisposition() async throws {
        let f = try makeFixture(count: 4, sized: 1) { transport, sessions in
            transport.setLive([sessions[0], sessions[1]])
            transport.setExitStatuses([sessions[2]: 0, sessions[3]: 137])
        }
        defer { f.cleanUp() }
        let (sized, unsized, clean, killed) = (f.sessions[0], f.sessions[1], f.sessions[2], f.sessions[3])
        let attached = try #require(f.registry.controller(for: sized))
        #expect(await eventually { attached.state.isDisconnected }, "attach tried; the client is refused here")
        #expect(attached.surface.gridSize.columns == 101 && attached.surface.gridSize.rows == 33, "at its saved size")
        #expect(f.model.session(clean) == nil, "gone and exited cleanly: its pane closed")
        #expect(f.registry.controller(for: killed)?.state == .ended(exitCode: .signaled(9)))
        #expect(f.transport.commands.filter { $0.contains(".exit") && $0.contains("printf") }.count == 1, "the records in one command")
        #expect(f.registry.controller(for: unsized)?.state == .detached, "no size: left until shown")
        #expect(f.registry.status(of: unsized) == .running)
        #expect(f.registry.controller(for: unsized)?.hasSurface == false)
    }

    @Test func anUnreachableHostGetsTheAttachAttemptAndNothingIsEnded() async throws {
        let f = try makeFixture(count: 2, sized: 1) { transport, _ in transport.setDown(true) }
        defer { f.cleanUp() }
        let sized = try #require(f.registry.controller(for: f.sessions[0]))
        #expect(await eventually { sized.state.isDisconnected })
        #expect(f.registry.status(of: f.sessions[0]) == .disconnected)
        #expect(f.registry.status(of: f.sessions[1]) == .pending, "no size: left, starting")
        let workspace = try #require(f.model.workspaces.first?.id)
        #expect(!f.registry.hasEndedSessions(in: workspace))
    }

    /// A host that needs the user: no attach for a hidden pane (none may sit
    /// at a password prompt); once one of its sessions connects (a shown
    /// pane signed in), the host is listed again and the rest follow.
    @Test func aHostThatNeedsTheUserStartsNothingHiddenUntilOneConnects() async throws {
        let f = try makeFixture(count: 3, sized: 3) { transport, _ in transport.setNeedsUser(true) }
        defer { f.cleanUp() }
        #expect(await eventually { f.registry.hostListings[f.host] == .needsUser })
        try await Task.sleep(for: .milliseconds(100))
        #expect(connects(f.transport).isEmpty, "nothing spawned for hidden panes")
        #expect(f.sessions.allSatisfy { f.registry.status(of: $0) == .pending })
        #expect(f.transport.listings == 1)

        // The user signs in through a shown pane; the host now answers.
        f.transport.setNeedsUser(false)
        f.transport.setLive([f.sessions[0], f.sessions[1]])
        let shown = try #require(f.registry.controller(for: f.sessions[0]))
        f.registry.sessionController(shown, didChangeState: .attached)
        #expect(await eventually { f.transport.listings == 2 }, "listed again")
        let other = try #require(f.registry.controller(for: f.sessions[1]))
        #expect(await eventually { other.state.isDisconnected }, "attach tried")
        #expect(await eventually { f.registry.status(of: f.sessions[2]) == .ended }, "gone")
    }

    @Test func atMostTwoAttachesAreInFlightPerHost() async throws {
        let f = try makeFixture(count: 5, sized: 5) { transport, sessions in
            transport.setLive(sessions)
            transport.holdConnects()
        }
        defer { f.cleanUp() }
        let lane = LaunchAttachQueue.Lane.host(f.host)
        #expect(await eventually { f.registry.launchQueue.inFlightCount(in: lane) == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.registry.launchQueue.inFlightCount(in: lane) == 2)
        #expect(f.registry.launchQueue.queued.count == 3)
        #expect(f.transport.heldConnects >= 1)
        f.transport.releaseConnects()
        #expect(await eventually { f.registry.launchQueue.isIdle })
        #expect(f.sessions.allSatisfy { f.registry.controller(for: $0)?.state.isDisconnected == true })
    }

    /// A session whose host was removed is unavailable from the start:
    /// nothing is listed, attached or killed.
    @Test func aRemovedHostsSessionsAreUnavailableFromTheStart() async throws {
        let f = try makeFixture(count: 2, sized: 2, removeHost: true)
        defer { f.cleanUp() }
        for id in f.sessions {
            #expect(f.registry.status(of: id) == .unavailable)
            #expect(f.registry.controller(for: id)?.state == .unavailable(reason: SessionRegistry.hostRemovedReason))
        }
        f.registry.close(f.sessions[0])
        _ = await f.registry.endAllSessions()
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.transport.commands.isEmpty, "never listed, attached or killed")
    }
    // MARK: The host's cap

    private var cap: Int { LaunchAttachPlan.maximumHiddenAttachedPerHost }

    private func attached(_ f: Fixture) -> [SessionID] {
        f.sessions.filter { f.registry.controller(for: $0)?.state == .attached }
    }

    /// Nine live sessions with saved sizes: six attached, in sidebar order,
    /// three left not attached until shown.
    @Test func theLaunchKeepsAtMostSixOfAHostsSessionsAttached() async throws {
        let f = try makeFixture(count: 9, sized: 9) { transport, sessions in
            transport.setLive(sessions)
            transport.setAttachable(true)
        }
        defer {
            f.registry.detachAllNow()
            f.cleanUp()
        }
        #expect(await eventually { attached(f).count == cap && f.registry.launchQueue.isIdle })
        try await Task.sleep(for: .milliseconds(200))
        #expect(attached(f) == Array(f.sessions.prefix(cap)), "sidebar order decides")
        for id in f.sessions.dropFirst(cap) {
            #expect(f.registry.controller(for: id)?.state == .detached)
            #expect(f.registry.status(of: id) == .running, "alive, not attached")
        }
    }

    /// Panes on screen count toward the cap, and a pane shown beyond it
    /// still starts.
    @Test func shownPanesCountAndAPaneShownBeyondTheCapStarts() async throws {
        let f = try makeFixture(count: 9, sized: 9, startPass: false) { transport, sessions in
            transport.setLive(sessions)
            transport.setAttachable(true)
        }
        defer {
            f.registry.detachAllNow()
            f.cleanUp()
        }
        // The last two are on screen at launch.
        let shown = Array(f.sessions.suffix(2))
        for id in shown {
            _ = f.registry.paneView(for: id)
            f.registry.startIfNeeded(id)
        }
        f.registry.startLaunchPass()
        #expect(await eventually { attached(f).count == cap && f.registry.launchQueue.isIdle })
        try await Task.sleep(for: .milliseconds(200))
        #expect(Set(attached(f)) == Set(shown + f.sessions.prefix(cap - 2)))
        // A pane the user shows past the cap starts all the same.
        let beyond = f.sessions[cap - 2]
        #expect(f.registry.controller(for: beyond)?.state == .detached)
        _ = f.registry.paneView(for: beyond)
        f.registry.startIfNeeded(beyond)
        #expect(await eventually { f.registry.controller(for: beyond)?.state == .attached })
        #expect(attached(f).count == cap + 1)
    }

    // MARK: No sign-in from a hidden pane

    /// A hidden session's automatic retry asks the host in batch mode
    /// first: when the host needs the user, it stops, Disconnected with the
    /// reason, and no interactive ssh is started; after a sign-in elsewhere
    /// the host is listed again and it reconnects.
    @Test func aHiddenRetryNeverStartsASignIn() async throws {
        let f = try makeFixture(
            count: 2, sized: 2, schedule: ReconnectSchedule(initialDelay: .milliseconds(50), budget: .seconds(5))
        ) { transport, sessions in
            transport.setLive(sessions)
            transport.setDown(true)
        }
        defer {
            f.registry.detachAllNow()
            f.cleanUp()
        }
        let hidden = try #require(f.registry.controller(for: f.sessions[1]))
        #expect(await eventually { hidden.state.isDisconnected })
        let before = f.transport.interactiveCalls
        // The host is back, but needs a password now.
        f.transport.setDown(false)
        f.transport.setNeedsUser(true)
        #expect(await eventually { hidden.state.isDisconnected && !hidden.isReconnecting && hidden.failure?.contains("Permission denied") == true })
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.transport.interactiveCalls == before, "no sign-in in a hidden pane")
        #expect(f.registry.hostsAwaitingUser.contains(f.host))

        // The user signs in through a shown pane, which connects.
        f.transport.setNeedsUser(false)
        f.transport.setAttachable(true)
        let shown = try #require(f.registry.controller(for: f.sessions[0]))
        _ = f.registry.paneView(for: f.sessions[0])
        await shown.reconnect()
        #expect(shown.state == .attached)
        #expect(await eventually { hidden.state == .attached }, "listed again, then reconnected")
    }

    /// A pane shown in this run keeps today's behaviour: its retry may
    /// start a sign-in (it is on screen to answer it).
    @Test func aShownPanesRetryIsNotHeldBack() async throws {
        let f = try makeFixture(
            count: 1, sized: 1, schedule: ReconnectSchedule(initialDelay: .milliseconds(50), budget: .seconds(5))
        ) { transport, sessions in
            transport.setLive(sessions)
            transport.setDown(true)
        }
        defer {
            f.registry.detachAllNow()
            f.cleanUp()
        }
        _ = f.registry.paneView(for: f.sessions[0])
        let controller = try #require(f.registry.controller(for: f.sessions[0]))
        #expect(await eventually { controller.state.isDisconnected })
        let before = f.transport.interactiveCalls
        f.transport.setDown(false)
        f.transport.setNeedsUser(true)
        #expect(await eventually { f.transport.interactiveCalls > before }, "the retry went to the backend, which may prompt")
    }

    // MARK: Relisting, pausing

    /// The signed-in pane found its session gone: the host was reached all
    /// the same, so it is listed again.
    @Test func aHostIsListedAgainWhenTheSignedInSessionTurnsOutGone() async throws {
        let f = try makeFixture(count: 2, sized: 2) { transport, _ in transport.setNeedsUser(true) }
        defer { f.cleanUp() }
        #expect(await eventually { f.registry.hostListings[f.host] == .needsUser })
        f.transport.setNeedsUser(false)
        let shown = try #require(f.registry.controller(for: f.sessions[0]))
        shown.markEnded()
        #expect(await eventually { f.transport.listings == 2 })
    }

    /// Controllers of a workspace whose window was closed at the last quit
    /// start with their automatic retries paused: an unreachable host is
    /// not asked again until the window opens.
    @Test func retriesStartPausedForAWorkspaceClosedAtTheLastQuit() async throws {
        let f = try makeFixture(
            count: 1, sized: 1, closedWindow: true,
            schedule: ReconnectSchedule(initialDelay: .milliseconds(50), budget: .seconds(5))
        ) { transport, sessions in
            transport.setLive(sessions)
            transport.setDown(true)
        }
        defer { f.cleanUp() }
        let controller = try #require(f.registry.controller(for: f.sessions[0]))
        #expect(await eventually { controller.state.isDisconnected })
        let commands = f.transport.commands.count
        try await Task.sleep(for: .milliseconds(400))
        #expect(!controller.isReconnecting)
        #expect(f.transport.commands.count == commands, "nothing retried while the window is closed")
        let workspace = try #require(f.model.workspaces.first?.id)
        f.registry.setWindowOpen(true, for: workspace)
        #expect(await eventually { f.transport.commands.count > commands }, "retries once it opens")
    }
    // MARK: Round 3

    private var quick: ReconnectSchedule { ReconnectSchedule(initialDelay: .milliseconds(50), budget: .seconds(5)) }

    /// A pane shown while its hidden session's retry is asking the host
    /// connects as a shown pane does (it may prompt): the answer is judged
    /// against the session as it is when it arrives.
    @Test func aPaneShownWhileItsRetryAsksConnectsAsAShownPane() async throws {
        let f = try makeFixture(count: 1, sized: 1, schedule: quick) { transport, sessions in
            transport.setLive(sessions)
            transport.setDown(true)
        }
        defer {
            f.registry.detachAllNow()
            f.cleanUp()
        }
        let id = f.sessions[0]
        let controller = try #require(f.registry.controller(for: id))
        #expect(await eventually { controller.state.isDisconnected })
        f.transport.setDown(false)
        f.transport.setNeedsUser(true)
        f.transport.holdListings()
        #expect(await eventually { f.transport.heldListings >= 1 }, "a retry is asking the host")
        let before = f.transport.interactiveCalls
        _ = f.registry.paneView(for: id)
        f.transport.releaseListings()
        #expect(await eventually { f.transport.interactiveCalls > before }, "connected, so the backend may prompt")
        #expect(!f.registry.waitingForUser.contains(id))
    }

    /// A session stopped for "needs the user" reconnects once by itself when
    /// its pane is first shown (and may prompt there).
    @Test func aStoppedSessionReconnectsWhenItsPaneIsShown() async throws {
        let f = try makeFixture(count: 1, sized: 1, schedule: quick) { transport, sessions in
            transport.setLive(sessions)
            transport.setDown(true)
        }
        defer {
            f.registry.detachAllNow()
            f.cleanUp()
        }
        let id = f.sessions[0]
        let controller = try #require(f.registry.controller(for: id))
        #expect(await eventually { controller.state.isDisconnected })
        f.transport.setDown(false)
        f.transport.setNeedsUser(true)
        #expect(await eventually { f.registry.waitingForUser.contains(id) && !controller.isReconnecting })
        // The user signs in elsewhere; showing the pane reconnects it.
        f.transport.setNeedsUser(false)
        f.transport.setAttachable(true)
        _ = f.registry.paneView(for: id)
        f.registry.startIfNeeded(id)
        #expect(await eventually { controller.state == .attached }, "no click needed")
        #expect(!f.registry.waitingForUser.contains(id), "cleared once connected")
    }

    /// A stopped session the host pass drops at the cap keeps its marker,
    /// so showing its pane still reconnects it.
    @Test func aStoppedSessionDroppedAtTheCapStillReconnectsWhenShown() async throws {
        let f = try makeFixture(count: cap + 1, sized: cap + 1, schedule: quick) { transport, sessions in
            transport.setLive(sessions)
            transport.setDown(true)
        }
        defer {
            f.registry.detachAllNow()
            f.cleanUp()
        }
        let hidden = Array(f.sessions.prefix(cap))
        let last = try #require(f.sessions.last)
        #expect(await eventually { hidden.allSatisfy { f.registry.controller(for: $0)?.state.isDisconnected == true } })
        #expect(f.registry.controller(for: last)?.state == .detached, "past the cap")
        f.transport.setDown(false)
        f.transport.setNeedsUser(true)
        #expect(await eventually { hidden.allSatisfy { f.registry.waitingForUser.contains($0) } })
        #expect(await eventually { hidden.allSatisfy { f.registry.controller(for: $0)?.isReconnecting == false } })
        // A sign-in through the last pane; the pass then has room for five.
        f.transport.setNeedsUser(false)
        f.transport.setAttachable(true)
        _ = f.registry.paneView(for: last)
        f.registry.startIfNeeded(last)
        #expect(await eventually { attached(f).count == cap && f.registry.launchQueue.isIdle })
        let dropped = hidden.filter { f.registry.controller(for: $0)?.state.isDisconnected == true }
        #expect(dropped.count == 1)
        let left = try #require(dropped.first)
        #expect(f.registry.waitingForUser.contains(left), "its marker outlived the drop")
        _ = f.registry.paneView(for: left)
        f.registry.startIfNeeded(left)
        #expect(await eventually { f.registry.controller(for: left)?.state == .attached })
    }

    /// Only an end that shows the host was reached lists it again: closing
    /// a pane of that host, or End Sessions and Quit, does not.
    @Test func endsTheAppCausesDoNotListTheHostAgain() async throws {
        let f = try makeFixture(count: 3, sized: 3) { transport, _ in transport.setNeedsUser(true) }
        defer { f.cleanUp() }
        #expect(await eventually { f.registry.hostListings[f.host] == .needsUser })
        f.transport.setNeedsUser(false)
        f.registry.close(f.sessions[0])
        await f.registry.endAllSessions(only: [f.sessions[1]])
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.transport.listings == 1)
        #expect(f.registry.hostsAwaitingUser.contains(f.host))
    }
    /// A host's answer reconnects only its own stopped sessions: another
    /// host's, stopped because it needs the user, stays as it is (no
    /// interactive client, Disconnected, still waiting).
    @Test func aHostsAnswerReconnectsOnlyItsOwnStoppedSessions() async throws {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let local = try #require(model.tabGroup(group)?.tabs.first?.id)
        let hostA = model.addHost(name: "A", sshDestination: "vm-a")
        let hostB = model.addHost(name: "B", sshDestination: "vm-b")
        for host in [hostA, hostB] {
            _ = try #require(model.newTab(in: group, starting: Profile.shell.id, at: .remote(host: host), workingDirectory: "~"))
        }
        model.closeTab(local)
        let (onA, onB) = (model.sessionOrder[0], model.sessionOrder[1])
        for id in [onA, onB] { model.setRuntimeVersion(ZmxVersion.current, for: id) }
        model.setGridSizes([onA: SessionGridSize(columns: 101, rows: 33), onB: SessionGridSize(columns: 101, rows: 33)])
        let folder = FileManager.default.temporaryDirectory.appending(path: "armadale-rl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = folder.appending(path: "zmx")
        try Data(count: 1234).write(to: binary)
        let transport = ScriptedTransport(live: [onA, onB])
        transport.setPresence("Linux aarch64\n1234\n")
        transport.setDown(true)
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: true),
            restoredSessionIDs: [onA, onB], settings: settings,
            remote: RemoteSessionSupport(
                transport: transport, cttyExec: nil, appVersion: "test", reconnectSchedule: quick, binary: { _ in binary }))
        defer { registry.detachAllNow() }
        registry.startLaunchPass()
        let (a, b) = (try #require(registry.controller(for: onA)), try #require(registry.controller(for: onB)))
        #expect(await eventually { a.state.isDisconnected && b.state.isDisconnected })
        // Both hosts are back, both need a password: both stop.
        transport.setDown(false)
        transport.setNeedsUser(true, for: "vm-a")
        transport.setNeedsUser(true, for: "vm-b")
        #expect(await eventually {
            registry.waitingForUser == [onA, onB] && !a.isReconnecting && !b.isReconnecting
        })
        let bCalls = transport.interactiveCalls(for: "vm-b")
        // Host A answers now (a sign-in elsewhere); it is listed again.
        transport.setNeedsUser(false, for: "vm-a")
        transport.setAttachable(true)
        registry.relist(hostA)
        #expect(await eventually { a.state == .attached }, "A's own reconnects")
        try await Task.sleep(for: .milliseconds(200))
        #expect(transport.interactiveCalls(for: "vm-b") == bCalls, "no interactive client for B")
        #expect(b.state.isDisconnected && !b.isReconnecting)
        #expect(registry.waitingForUser.contains(onB))
        #expect(registry.hostsAwaitingUser.contains(hostB))
    }
}
