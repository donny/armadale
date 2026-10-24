import AppKit
import ArmadaleCore
import ArmadaleSessions
import Foundation
import Testing

/// The clean-exit rule in the registry (docs/DESIGN.md section 4, "Ended"):
/// a session that ends with status 0 takes its pane with it, through the
/// same model intent as the placeholder's Close Pane, wherever the pane is
/// (a workspace's only pane takes the workspace with it); and restored
/// sessions recorded as exited cleanly lose their panes at launch. No
/// process is started. The window side of the only pane's clean exit is in
/// `WindowLifetimeTests`.
@Suite("Clean exits close panes")
@MainActor
struct CleanExitTests {
    private func makeRegistry(_ model: AppModel, restored: Set<SessionID> = []) -> (SessionRegistry, AppSettings) {
        _ = NSApplication.shared
        let settings = AppSettings.forTesting()
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: restored,
            settings: settings)
        return (registry, settings)
    }

    private func session(of pane: PaneID, in model: AppModel) throws -> SessionID {
        try #require(model.tab(containing: pane)?.pane(pane)?.sessionID)
    }

    @Test func aCleanExitClosesItsPaneAndOthersKeepThePlaceholder() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let first = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let second = try #require(model.splitPane(first, axis: .vertical))
        let third = try #require(model.splitPane(second, axis: .horizontal))
        let agentTab = try #require(model.newTab(in: group, profile: Profile.claudeCode.id))
        let agentPane = try #require(model.tab(agentTab)?.focusedPaneID)
        let (registry, settings) = makeRegistry(model)
        defer { settings.removeTestDefaults() }

        let killed = try #require(registry.paneView(for: try session(of: third, in: model))).controller
        killed.markEnded(exitCode: .signaled(9))
        let unknown = try #require(registry.paneView(for: try session(of: first, in: model))).controller
        unknown.markEnded()
        let agent = try #require(registry.paneView(for: try session(of: agentPane, in: model))).controller
        agent.markEnded(exitCode: 1)
        #expect(model.tab(containing: third) != nil && model.tab(containing: first) != nil, "signal and unknown stay")
        #expect(model.tab(containing: agentPane) != nil, "a program's non-zero exit stays")

        // The shell leaving with 130 (^C at the prompt, then ^D) closes.
        let shell = try session(of: second, in: model)
        try #require(registry.paneView(for: shell)).controller.markEnded(exitCode: 130)
        #expect(model.tab(containing: second) == nil)
        #expect(model.session(shell) == nil)
        #expect(registry.controller(for: shell) == nil, "the registry let it go, as Close Pane does")
    }

    /// The only pane of the only workspace: a clean exit empties the model
    /// and retires the session, as Close Pane would.
    @Test func theOnlyPaneOfTheOnlyWorkspaceClosesOnACleanExit() async throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let shell = try #require(model.sessionIDs(in: workspace).first)
        let (registry, settings) = makeRegistry(model)
        defer { settings.removeTestDefaults() }
        var retired: [SessionID] = []
        registry.onSessionRetired = { retired.append($0) }

        try #require(registry.paneView(for: shell)).controller.markEnded(exitCode: 0)
        #expect(model.workspace(workspace) == nil)
        #expect(model.workspaces.isEmpty && model.sessions.isEmpty)
        #expect(registry.controller(for: shell) == nil, "the registry let it go, as Close Pane does")
        for _ in 0..<40 where retired.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(retired == [shell])
    }

    /// A program's failure, a death by signal or an unknown end in a
    /// workspace's only pane keeps the placeholder (`nil`: a signal or an
    /// unknown end of the shell itself).
    @Test(arguments: zip(
        [Profile.claudeCode.id, Profile.claudeCode.id, Profile.claudeCode.id, nil, nil] as [ProfileID?],
        [ProgramExit.exited(3), .signaled(15), nil, .signaled(15), nil] as [ProgramExit?]))
    func theOnlyPaneKeepsThePlaceholderWhenTheEndIsNotClean(profile: ProfileID?, exit: ProgramExit?) throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W", profile: profile)
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)
        let (registry, settings) = makeRegistry(model)
        defer { settings.removeTestDefaults() }
        let controller = try #require(registry.paneView(for: try session(of: pane, in: model))).controller
        controller.markEnded(exitCode: exit)
        #expect(model.tab(containing: pane) != nil)
        #expect(model.workspace(workspace) != nil)
        #expect(controller.state == .ended(exitCode: exit))
    }

    /// At launch: restored sessions recorded as exited cleanly lose their
    /// panes in the model's order, a workspace's only pane included (the
    /// workspace goes with it); sessions not restored, or not recorded as
    /// a clean exit, are untouched.
    @Test func restoredSessionsThatExitedCleanlyAreClosedAtLaunch() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let tab1 = try #require(model.selectedTab(in: workspace))
        let tab2 = try #require(model.newTab(in: group))
        let tab3 = try #require(model.newTab(in: group))
        let s1 = try session(of: tab1.focusedPaneID, in: model)
        let s2 = try session(of: try #require(model.tab(tab2)?.focusedPaneID), in: model)
        let s3 = try session(of: try #require(model.tab(tab3)?.focusedPaneID), in: model)
        let other = model.newWorkspace(name: "Other")
        let lone = try session(of: try #require(model.selectedTab(in: other)?.focusedPaneID), in: model)
        let (registry, settings) = makeRegistry(model, restored: [s1, s2, s3, lone])
        defer { settings.removeTestDefaults() }

        let closed = registry.closePanesOfSessionsThatEndedCleanly([s1: 1, s2: .signaled(1), s3: 0, lone: 0])
        #expect(closed == [s1, s3, lone])
        #expect(model.tabGroup(group)?.tabs.map(\.id) == [tab2], "a hangup keeps its tab")
        #expect(model.workspace(other) == nil, "the workspace of an only pane goes with it")
        #expect(registry.closePanesOfSessionsThatEndedCleanly([s2: 0]) == [s2], "the workspace's last pane too")
        #expect(model.workspaces.isEmpty)
    }

    /// A launch where every restored session exited cleanly while Armadale
    /// was not running: the closes run first (AppDelegate, before any
    /// window shows) and empty the model, then
    /// ``AppModel/ensureWorkspacesToOpen()`` makes one fresh "Workspace",
    /// whose new session the pass never saw, and that is all that opens.
    @Test func whenEveryRestoredSessionExitedCleanlyOneFreshWorkspaceOpens() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "armadale-cx-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let runtime = ZmxRuntime(directory: directory)
        let model = AppModel(defaultWorkingDirectory: "/")
        let first = model.newWorkspace(name: "Workspace")
        let second = model.newWorkspace(name: "Other")
        let group = try #require(model.workspace(first)?.selectedTabGroupID)
        _ = model.newTab(in: group)
        _ = model.newTabGroup(in: second)
        let restored = model.sessionOrder
        #expect(restored.count == 4)
        for (index, id) in restored.enumerated() {
            model.setRuntimeVersion("0.8.1", for: id)
            try (index.isMultiple(of: 2) ? "0\n" : "130\n")
                .write(toFile: runtime.exitFilePath(for: id), atomically: true, encoding: .utf8)
        }
        let (registry, settings) = makeRegistry(model, restored: Set(restored))
        defer { settings.removeTestDefaults() }

        #expect(registry.closeLocalSessionsThatEndedCleanly(recordedIn: runtime) == restored)
        #expect(model.workspaces.isEmpty && model.sessions.isEmpty)
        let opened = model.ensureWorkspacesToOpen()
        #expect(opened.count == 1)
        #expect(model.workspaces.map(\.id) == opened)
        #expect(model.workspaces.first?.name == "Workspace", "the name is free again")
        #expect(model.sessions.count == 1)
        #expect(Set(model.sessions.map(\.id)).isDisjoint(with: restored))
    }

    /// The launch pass reads the local exit files (AppDelegate calls this
    /// before any window shows): only restored persistent local sessions
    /// count, and a record's absence or a death by signal keeps the pane.
    @Test func theLaunchPassReadsTheLocalExitFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "armadale-cx-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let runtime = ZmxRuntime(directory: directory)
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let tab1 = try #require(model.selectedTab(in: workspace)?.id)
        for _ in 0..<4 { _ = model.newTab(in: group) }
        let ids = model.sessionIDs(in: workspace)
        #expect(ids.count == 5)
        let (clean, killed, unrecorded, notPersistent, kept) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        for id in [clean, killed, unrecorded, kept] { model.setRuntimeVersion("0.8.1", for: id) }
        try "0\n".write(toFile: runtime.exitFilePath(for: clean), atomically: true, encoding: .utf8)
        try "signal 1\n".write(toFile: runtime.exitFilePath(for: killed), atomically: true, encoding: .utf8)
        try "0\n".write(toFile: runtime.exitFilePath(for: notPersistent), atomically: true, encoding: .utf8)
        let (registry, settings) = makeRegistry(model, restored: Set(ids))
        defer { settings.removeTestDefaults() }

        #expect(registry.closeLocalSessionsThatEndedCleanly(recordedIn: runtime) == [clean])
        #expect(model.tab(tab1) == nil)
        #expect(Set(model.sessionIDs(in: workspace)) == [killed, unrecorded, notPersistent, kept])
    }

    /// Remote restored sessions are closed when their host's first listing
    /// arrives: gone, never shown, and recorded as a clean exit.
    @Test func restoredRemoteSessionsThatExitedCleanlyAreClosedWhenTheHostAnswers() async throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let host = model.addHost(name: "VM", sshDestination: "vm")
        var remote: [SessionID] = []
        for _ in 0..<4 {
            let tab = try #require(model.newTab(in: group, onHost: host))
            let id = try session(of: try #require(model.tab(tab)?.focusedPaneID), in: model)
            model.setRuntimeVersion("0.8.1", for: id)
            remote.append(id)
        }
        let (clean, live, shown, failed) = (remote[0], remote[1], remote[2], remote[3])
        let (registry, settings) = makeRegistry(model, restored: Set(remote))
        defer { settings.removeTestDefaults() }
        _ = registry.paneView(for: shown)
        let backend = RecordingBackend(recorded: [clean: 0, live: 0, shown: 0, failed: .signaled(2)])

        await registry.closeRestoredSessionsThatEndedCleanly(on: host, backend: backend, live: [live])
        #expect(model.session(clean) == nil)
        #expect(model.session(live) != nil, "still running on the host")
        #expect(model.session(shown) != nil, "a shown pane goes through its controller")
        #expect(model.session(failed) != nil)
        // The shown pane (unavailable here: no remote support in tests) is not asked about.
        #expect(await backend.asked == [clean, failed])
    }

    /// A host's first listing can empty a workspace: its only pane, a
    /// restored remote session found gone and recorded as a clean exit,
    /// closes and the workspace goes; another workspace stays.
    @Test func aHostsFirstListingCanEmptyAWorkspace() async throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let other = model.newWorkspace(name: "Other")
        let workspace = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let localTab = try #require(model.selectedTab(in: workspace)?.id)
        let host = model.addHost(name: "VM", sshDestination: "vm")
        let tab = try #require(model.newTab(in: group, onHost: host))
        model.closeTab(localTab)
        let remote = try session(of: try #require(model.tab(tab)?.focusedPaneID), in: model)
        model.setRuntimeVersion("0.8.1", for: remote)
        let (registry, settings) = makeRegistry(model, restored: [remote])
        defer { settings.removeTestDefaults() }

        await registry.closeRestoredSessionsThatEndedCleanly(
            on: host, backend: RecordingBackend(recorded: [remote: 0]), live: [])
        #expect(model.session(remote) == nil)
        #expect(model.workspace(workspace) == nil)
        #expect(model.workspaces.map(\.id) == [other])
    }
}

/// Answers `recordedExitStatuses` from a table and records what was asked.
actor RecordingBackend: PersistenceBackend {
    let recorded: [SessionID: ProgramExit]
    private(set) var asked: Set<SessionID> = []

    init(recorded: [SessionID: ProgramExit]) {
        self.recorded = recorded
    }

    func recordedExitStatuses(of ids: Set<SessionID>) async -> [SessionID: ProgramExit] {
        asked.formUnion(ids)
        return recorded.filter { ids.contains($0.key) }
    }

    func create(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        throw BackendError.runtimeFailure("test backend")
    }

    func attach(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        throw BackendError.runtimeFailure("test backend")
    }

    func exists(_ id: SessionID) async throws -> Bool { false }
    func liveSessions() async throws -> Set<SessionID> { [] }
    func kill(_ id: SessionID) async throws {}
    func history(_ id: SessionID) async throws -> Data { throw BackendError.historyUnavailable(id) }
    func resolveExit(of session: Session) async -> ExitResolution { .ended(exitStatus: nil) }
}
