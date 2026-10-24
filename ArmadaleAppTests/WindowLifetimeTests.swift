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
