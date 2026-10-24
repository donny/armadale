import AppKit
import ArmadaleCore
import ArmadaleSessions
import Foundation
import Synchronization
import Testing

/// An SSH transport for app tests: answers listings from `live` (or fails
/// like an unreachable host), holds answers back until released, and never
/// starts a process (interactive clients are refused).
final class ScriptedTransport: SSHTransport {
    private struct State {
        var live: [String] = []
        var isDown = false
        var isReleased = true
        var commands: [String] = []
    }

    private let state = Mutex(State())

    init(live: [SessionID] = [], released: Bool = true) {
        state.withLock {
            $0.live = live.map { "a-" + $0.raw }
            $0.isReleased = released
        }
    }

    func setDown(_ down: Bool) { state.withLock { $0.isDown = down } }
    func release() { state.withLock { $0.isReleased = true } }
    var commands: [String] { state.withLock { $0.commands } }

    func run(_ host: ArmadaleCore.Host, _ remoteCommand: String, input: Data?) async throws -> CommandResult {
        state.withLock { $0.commands.append(remoteCommand) }
        while !state.withLock({ $0.isReleased }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let (down, live) = state.withLock { ($0.isDown, $0.live) }
        if down {
            return CommandResult(status: 255, stdout: Data(), stderr: Data("ssh: connect to host vm port 22: Connection refused\n".utf8))
        }
        if remoteCommand.contains("ls --short") {
            return CommandResult(status: 0, stdout: Data(live.map { $0 + "\n" }.joined().utf8), stderr: Data())
        }
        return CommandResult(status: 0, stdout: Data(), stderr: Data())
    }

    func interactive(_ host: ArmadaleCore.Host, remoteCommand: String?) throws -> SSHInvocation {
        throw BackendError.unreachable("no interactive sessions in app tests")
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
