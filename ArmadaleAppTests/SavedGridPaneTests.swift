import AppKit
import ArmadaleCore
import ArmadaleSessions
import Foundation
import Testing

/// A session attached at its saved grid while its pane was not on screen
/// (DESIGN §4 "Restore at launch", §5, §8): its pane view, made later, does
/// not resize it by being made, by entering a window or by a layout at the
/// same grid; a layout at another grid resizes it exactly once. Real
/// SwiftTerm surfaces, no process, no window on screen.
@Suite("Panes of sessions attached at their saved size")
@MainActor
struct SavedGridPaneTests {
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private struct Fixture {
        let model: AppModel
        let registry: SessionRegistry
        let backend: LaunchTestBackend
        let settings: AppSettings
        let hidden: SessionID
        let handle: TestHandle
    }

    /// Two restored sessions, the second's tab not shown, saved at 101×33
    /// and attached at it by the launch pass.
    private func attachedHidden() async throws -> Fixture {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        _ = model.newTab(in: group)
        model.fillEmptyPanes()
        let sessions = model.sessionOrder
        for id in sessions { model.setRuntimeVersion(ZmxVersion.current, for: id) }
        model.setGridSizes([sessions[1]: SessionGridSize(columns: 101, rows: 33)])
        let backend = LaunchTestBackend(alive: Set(sessions))
        let settings = AppSettings.forTesting()
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(backend: backend, makeOutputFilter: { IdentityOutputFilter() }, isPersistent: true),
            restoredSessionIDs: Set(sessions), settings: settings)
        registry.startLaunchPass()
        let controller = try #require(registry.controller(for: sessions[1]))
        #expect(await eventually { controller.state == .attached })
        let handle = try #require(await backend.handle(sessions[1]))
        return Fixture(model: model, registry: registry, backend: backend, settings: settings, hidden: sessions[1], handle: handle)
    }

    private func window(_ size: NSSize = NSSize(width: 1600, height: 1000)) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        return window
    }

    @Test func thePaneOfASessionAttachedAtItsSavedGridSendsNoResizeAtTheSameGrid() async throws {
        let f = try await attachedHidden()
        defer { f.settings.removeTestDefaults() }
        let pane = try #require(f.registry.paneView(for: f.hidden))
        let surface = pane.controller.surface
        #expect(surface.gridSize.columns == 101 && surface.gridSize.rows == 33, "making the pane view kept the grid")
        let window = window()
        defer { window.close() }
        // Laid out by a split tree at the pane's own size: the same grid.
        let tree = SplitTreeView(frame: NSRect(origin: .zero, size: pane.frame.size))
        window.contentView?.addSubview(tree)
        tree.update(layout: .pane(PaneID(raw: "p"))) { _ in pane }
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(pane.window === window)
        #expect(surface.gridSize.columns == 101 && surface.gridSize.rows == 33)
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.handle.resizes.isEmpty, "no resize: \(f.handle.resizes)")
    }

    @Test func aDifferentLaidOutGridSendsExactlyOneResize() async throws {
        let f = try await attachedHidden()
        defer { f.settings.removeTestDefaults() }
        let pane = try #require(f.registry.paneView(for: f.hidden))
        let window = window()
        defer { window.close() }
        let tree = SplitTreeView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        window.contentView?.addSubview(tree)
        tree.update(layout: .pane(PaneID(raw: "p"))) { _ in pane }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let grid = pane.controller.surface.gridSize
        #expect(grid.columns != 101)
        #expect(f.handle.resizes.map { "\($0.columns)x\($0.rows)" } == ["\(grid.columns)x\(grid.rows)"])
        // The new size is the session's from now on.
        f.registry.flushGridSizes()
        #expect(f.model.session(f.hidden)?.gridSize == SessionGridSize(columns: grid.columns, rows: grid.rows))
    }
}

/// Measurement and guard for relaunch: a restored session whose pane is on
/// screen at launch is attached once, at its laid-out size, and sent no
/// resize afterwards (the cause of the extra SIGWINCH recorded in
/// HANDOFF.md was looked for here; docs/HISTORY.md, section 8). The
/// window is laid out but never ordered on screen.
@Suite("Relaunch of a visible pane")
@MainActor
struct RelaunchResizeTests {
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    @Test(arguments: [false, true])
    func aVisibleRestoredPaneIsAttachedOnceAndNotResized(saved: Bool) async throws {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        model.fillEmptyPanes()
        let session = try #require(model.sessionOrder.first)
        model.setRuntimeVersion(ZmxVersion.current, for: session)
        model.updateWindowState(WindowState(
            frame: WindowFrame(x: 100, y: 100, width: 1200, height: 800), sidebarWidth: 220,
            sidebarCollapsed: false, isOpen: true, isFullScreen: false), for: workspace)
        if saved { model.setGridSizes([session: SessionGridSize(columns: 120, rows: 40)]) }
        let backend = LaunchTestBackend(alive: [session])
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(backend: backend, makeOutputFilter: { IdentityOutputFilter() }, isPersistent: true),
            restoredSessionIDs: [session], settings: settings)
        let controller = WorkspaceWindowController(model: model, workspaceID: workspace, registry: registry)
        defer { controller.window?.close() }
        let session0 = try #require(registry.controller(for: session))
        #expect(await eventually { session0.state == .attached })
        try await Task.sleep(for: .milliseconds(300))
        let attaches = await backend.attachSizes[session] ?? []
        let handle = try #require(await backend.handle(session))
        let grid = session0.surface.gridSize
        print("RELAUNCH saved=\(saved): attached at \(attaches.map { "\($0.columns)x\($0.rows) px\($0.pixelWidth)x\($0.pixelHeight)" }), then resizes \(handle.resizes.map { "\($0.columns)x\($0.rows)" }), grid now \(grid)")
        #expect(attaches.count == 1, "one attach, by the shown pane (not the launch pass)")
        #expect(handle.resizes.isEmpty, "no resize after the attach: \(handle.resizes)")
        #expect(attaches.first.map { Int($0.columns) == grid.columns && Int($0.rows) == grid.rows } == true)
    }
}
