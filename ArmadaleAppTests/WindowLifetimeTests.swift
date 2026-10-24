import AppKit
import ArmadaleCore
import ArmadaleSessions
import Foundation
import Testing

/// A backend that never starts anything, so these tests spawn no process.
actor InertBackend: PersistenceBackend {
    func create(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        throw BackendError.runtimeFailure("inert test backend")
    }

    func attach(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        throw BackendError.runtimeFailure("inert test backend")
    }

    func exists(_ id: SessionID) async throws -> Bool { false }
    func liveSessions() async throws -> Set<SessionID> { [] }
    func kill(_ id: SessionID) async throws {}
    func history(_ id: SessionID) async throws -> Data { throw BackendError.historyUnavailable(id) }
    func resolveExit(of session: Session) async -> ExitResolution { .ended(exitStatus: nil) }
}

/// A closed workspace window must let go of everything: its controllers
/// deinit, its pane views leave it, and nothing keeps following the model
/// (which could otherwise move pane views back into the closed window).
/// The window is never ordered on screen.
@Suite("Workspace window lifetime")
@MainActor
struct WindowLifetimeTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<60 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func closingTheWindowReleasesItsControllersAndPanes() async throws {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: [],
            settings: settings)
        let firstSession = try #require(model.sessionIDs(in: workspace).first)

        weak var weakController: WorkspaceWindowController?
        weak var weakContent: NSViewController?
        weak var weakWindow: NSWindow?
        do {
            let controller = WorkspaceWindowController(model: model, workspaceID: workspace, registry: registry)
            weakController = controller
            weakWindow = controller.window
            let split = try #require(controller.window?.contentViewController as? NSSplitViewController)
            weakContent = split.splitViewItems.last?.viewController
            // The content shows the first tab's pane in the window.
            #expect(await eventually { registry.paneView(for: firstSession)?.window === controller.window })
            controller.window?.close()
            #expect(registry.paneView(for: firstSession)?.window == nil, "panes leave the closed window")
        }

        // A new tab in that workspace (as from another window's sidebar) must
        // not be picked up by the closed window's controller.
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let tab = try #require(model.newTab(in: group))
        let newSession = try #require(model.sessionIDs(ofTab: tab).first)
        try await Task.sleep(for: .milliseconds(200))
        #expect(registry.controller(for: newSession) == nil, "nothing showed the new tab")

        #expect(await eventually { weakController == nil }, "WorkspaceWindowController deinit")
        #expect(await eventually { weakContent == nil }, "ContentViewController deinit")
        #expect(await eventually { weakWindow == nil }, "window released")
        print("DEINIT controller: \(weakController == nil), content: \(weakContent == nil), window: \(weakWindow == nil)")
    }

    /// Closing a workspace's last pane deletes the workspace (DESIGN §8,
    /// October 23, 2026), with another workspace left or none: its window
    /// closes exactly once, reports its close once, and the controller is
    /// released by its owner as `AppDelegate` releases it.
    @Test(arguments: [true, false])
    func closingTheLastPaneDeletesTheWorkspaceAndClosesItsWindowOnce(otherWorkspace: Bool) async throws {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: "/")
        let other = otherWorkspace ? model.newWorkspace(name: "Other") : nil
        let workspace = model.newWorkspace(name: "W")
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: [],
            settings: settings)
        let session = try #require(model.sessionIDs(in: workspace).first)
        let pane = try #require(model.selectedTab(in: workspace)?.focusedPaneID)

        // Who holds the controller, and what it reported: as in AppDelegate.
        let log = CloseLog()
        weak var weakController: WorkspaceWindowController?
        weak var weakWindow: NSWindow?
        var observer: (any NSObjectProtocol)?
        do {
            let controller = WorkspaceWindowController(model: model, workspaceID: workspace, registry: registry)
            weakController = controller
            weakWindow = controller.window
            log.owners[workspace] = controller
            controller.onWindowStateChange = { [log] controller, state in
                if model.workspace(controller.workspaceID) == nil { log.reportsAfterDeletion += 1 }
                guard log.owners[controller.workspaceID] === controller else { return }
                if !state.isOpen {
                    log.closeReports += 1
                    log.owners[controller.workspaceID] = nil
                }
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: controller.window, queue: nil
            ) { [log] _ in
                MainActor.assumeIsolated { log.willCloseCount += 1 }
            }
            #expect(await eventually { registry.paneView(for: session)?.window === controller.window })

            // ⌘W on the only pane (no question: nothing runs in it).
            controller.actions.closePane(pane, confirm: false)
        }
        defer { if let observer { NotificationCenter.default.removeObserver(observer) } }

        #expect(model.workspace(workspace) == nil, "the empty workspace left the model")
        #expect(model.workspaces.map(\.id) == (other.map { [$0] } ?? []))
        #expect(model.sessions.count == (otherWorkspace ? 1 : 0))
        #expect(await eventually { log.willCloseCount == 1 }, "the window closed")
        #expect(log.closeReports == 1, "its close was reported once")
        #expect(log.reportsAfterDeletion == 1, "only the close report, which AppDelegate does not record")
        #expect(log.owners.isEmpty)
        #expect(registry.paneView(for: session) == nil, "the closed pane's view is gone")
        #expect(await eventually { weakController == nil }, "WorkspaceWindowController deinit")
        #expect(await eventually { weakWindow == nil }, "window released")
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.willCloseCount == 1, "closed exactly once")
        #expect(log.closeReports == 1)
        #expect(log.reportsAfterDeletion == 1, "nothing reported after the close")
    }
}

/// Close Tab Group on a workspace's last group, through the window's
/// actions as the menu and the sidebar call it: nothing runs (the session
/// was never shown), so nothing is asked, and the workspace is deleted.
@Suite("Closing a workspace's last tab group")
@MainActor
struct CloseLastTabGroupTests {
    @Test func closeTabGroupThroughTheActionsDeletesTheWorkspace() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let other = model.newWorkspace(name: "Other")
        let workspace = model.newWorkspace(name: "W")
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: [],
            settings: settings)
        let actions = WorkspaceActions(model: model, registry: registry, workspaceID: workspace)
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let session = try #require(model.sessionIDs(in: workspace).first)
        actions.closeTabGroup(group)
        #expect(model.workspace(workspace) == nil)
        #expect(model.workspaces.map(\.id) == [other])
        #expect(model.session(session) == nil)
    }

    /// A name being typed is committed before a close reads names for its
    /// question (the sheet must not show the old name).
    @Test func closingCommitsTheRenameUnderWayFirst() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "Workspace 2")
        let second = try #require(model.newTabGroup(in: workspace, name: "Second"))
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: [],
            settings: settings)
        let actions = WorkspaceActions(model: model, registry: registry, workspaceID: workspace)
        #expect(actions.rename.begin(.workspace(workspace), on: .sidebar))
        actions.rename.text = "Renamed"
        actions.closeTabGroup(second)
        #expect(actions.rename.edit == nil)
        #expect(model.workspace(workspace)?.name == "Renamed")
        #expect(model.tabGroup(second) == nil)
    }
}

/// What a window reported while its workspace was deleted, and who holds
/// its controller (``WindowLifetimeTests``).
@MainActor
private final class CloseLog {
    var owners: [WorkspaceID: WorkspaceWindowController] = [:]
    var closeReports = 0
    var reportsAfterDeletion = 0
    var willCloseCount = 0
}

@Suite("SessionRegistry close risk")
@MainActor
struct RegistryCloseRiskTests {
    @Test func restoredSessionAsksUntilTheProbeSaysItIsGone() async throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let restored = Set(model.sessionIDs(in: workspace))
        let session = try #require(restored.first)
        // The inert backend's probe answers "nothing is alive", but only
        // once this test yields to the main actor.
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: restored, settings: settings)
        #expect(registry.status(of: session) == .pending)
        #expect(registry.closeRisk(of: [session]).mayBeRunning, "unknown yet: may be running")

        _ = await registry.liveProbe.value
        for _ in 0..<20 where registry.status(of: session) == .pending {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(registry.status(of: session) == .ended)
        #expect(!registry.closeRisk(of: [session]).mayBeRunning)
    }

    @Test func newSessionNeverShownDoesNotAsk() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let session = try #require(model.sessionIDs(in: workspace).first)
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: [],
            settings: settings)
        #expect(registry.status(of: session) == .pending)
        #expect(!registry.closeRisk(of: [session]).mayBeRunning)
    }
}
