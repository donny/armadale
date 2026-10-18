import AppKit
import ArmadaleCore
import ArmadaleSessions
import SwiftTermSurface
import TerminalSurface
import Testing

/// A second renderer, so the renderer switch can be tested while SwiftTerm
/// is the only real one.
@MainActor
final class StubRendererSurface: TerminalSurface {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    weak var delegate: (any TerminalSurfaceDelegate)?
    var gridSize = GridSize(columns: 80, rows: 24, cellWidth: 7, cellHeight: 14)
    private(set) var appearance: TerminalAppearance

    init(appearance: TerminalAppearance) {
        self.appearance = appearance
    }

    func feed(_ bytes: ArraySlice<UInt8>) {}
    func apply(_ appearance: TerminalAppearance) { self.appearance = appearance }
    func clearScrollback() {}
    func scrollToBottom() {}
    func find(_ query: String, direction: FindDirection) {}
    var selectedText: String? { nil }
}

/// Settings reach panes that already exist: appearance at once, the
/// renderer at the next attach.
@Suite("Settings applied to panes")
@MainActor
struct SettingsApplyTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<60 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func makeRegistry(settings: AppSettings) -> (AppModel, SessionRegistry, WorkspaceID) {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: [],
            settings: settings)
        return (model, registry, workspace)
    }

    @Test func changingTheFontSizeThroughPreferencesUpdatesAnExistingPane() async throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace) = makeRegistry(settings: settings)
        let sessionID = try #require(model.sessionIDs(in: workspace).first)
        let pane = try #require(registry.paneView(for: sessionID))
        let surface = try #require(pane.controller.surface as? SwiftTermSurface)
        #expect(surface.appearance.fontSize == Preferences.defaultFontSize)
        // Let the pane's observation start before changing anything.
        try await Task.sleep(for: .milliseconds(50))

        settings.preferences.fontSize = 20
        #expect(await eventually { surface.appearance.fontSize == 20 }, "font size applied: \(surface.appearance.fontSize)")

        settings.preferences.increaseFontSize() // ⌘=
        #expect(await eventually { surface.appearance.fontSize == 21 })

        settings.preferences.followsSystemAppearance = false
        settings.preferences.themeID = "builtin.dracula"
        #expect(await eventually { surface.appearance.theme.name == "Dracula" }, "theme applied")
        settings.preferences.cursorShape = .bar
        #expect(await eventually { surface.appearance.cursor.shape == .bar }, "cursor applied")

        // A pane created afterwards starts with the current settings.
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let tab = try #require(model.newTab(in: group))
        let newSession = try #require(model.sessionIDs(ofTab: tab).first)
        let newSurface = try #require(registry.paneView(for: newSession)?.controller.surface as? SwiftTermSurface)
        #expect(newSurface.appearance.fontSize == 21)
        #expect(newSurface.appearance.theme.name == "Dracula")
    }

    @Test func importedThemeChangesReachPanesUsingThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("armadale-apply-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = AppSettings.forTesting()
        defer { base.removeTestDefaults() }
        let settings = AppSettings(
            preferences: base.preferences, themes: ThemeCatalog(directory: root.appendingPathComponent("themes")),
            surfaces: base.surfaces)
        let (model, registry, workspace) = makeRegistry(settings: settings)
        let sessionID = try #require(model.sessionIDs(in: workspace).first)
        let surface = try #require(registry.paneView(for: sessionID)?.controller.surface as? SwiftTermSurface)
        try await Task.sleep(for: .milliseconds(50))

        let file = root.appendingPathComponent("Mine")
        try "background = #123456\nforeground = #fedcba\n".write(to: file, atomically: true, encoding: .utf8)
        let imported = try settings.themes.importGhosttyTheme(at: file)
        settings.preferences.followsSystemAppearance = false
        settings.preferences.themeID = imported.entry.id
        #expect(await eventually { surface.appearance.theme.background == TerminalColor(hex: 0x123456) })

        try "background = #654321\nforeground = #fedcba\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try settings.themes.importGhosttyTheme(at: file)
        #expect(await eventually { surface.appearance.theme.background == TerminalColor(hex: 0x654321) },
                "re-importing the same theme updates panes using it")
    }

    @Test func aRendererChangeAppliesToNewPanesAtOnceAndToExistingOnesAtTheirNextAttach() async throws {
        let surfaces = SurfaceRegistry(
            default: SwiftTermSurface.factory,
            others: [SurfaceFactory(id: "stub", displayName: "Stub") { StubRendererSurface(appearance: $0) }])
        let settings = AppSettings.forTesting(surfaces: surfaces)
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace) = makeRegistry(settings: settings)
        let sessionID = try #require(model.sessionIDs(in: workspace).first)
        let pane = try #require(registry.paneView(for: sessionID))
        let original = pane.controller.surface
        #expect(original is SwiftTermSurface)
        #expect(pane.rendererID == "swiftterm")
        try await Task.sleep(for: .milliseconds(50))

        settings.preferences.rendererID = "stub"
        #expect(await eventually { pane.pendingRendererID == "stub" }, "existing pane is marked")
        #expect(pane.controller.surface === original, "a live surface is not torn down")
        #expect(pane.controller.hasPendingSurfaceReplacement)

        // New panes use the new renderer straight away.
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let tab = try #require(model.newTab(in: group))
        let newSession = try #require(model.sessionIDs(ofTab: tab).first)
        let newPane = try #require(registry.paneView(for: newSession))
        #expect(newPane.controller.surface is StubRendererSurface)
        #expect(newPane.rendererID == "stub")

        // The next attach (here a respawn) replaces the old pane's surface.
        settings.preferences.fontSize = 18
        await pane.controller.respawn()
        let replaced = try #require(pane.controller.surface as? StubRendererSurface)
        #expect(replaced.view.superview === pane, "the new surface is shown in the pane")
        #expect(original.view.superview == nil, "the old one is gone")
        #expect(pane.rendererID == "stub")
        #expect(pane.pendingRendererID == nil)
        #expect(replaced.appearance.fontSize == 18)
        #expect(!pane.controller.hasPendingSurfaceReplacement)

        // Back to the default: marked again; choosing the current renderer cancels.
        settings.preferences.rendererID = "swiftterm"
        #expect(await eventually { pane.pendingRendererID == "swiftterm" })
        settings.preferences.rendererID = "stub"
        #expect(await eventually { pane.pendingRendererID == nil })
        #expect(!pane.controller.hasPendingSurfaceReplacement)

        // An unknown renderer (removed in a later version) means the default.
        settings.preferences.rendererID = "gone"
        let third = try #require(model.newTab(in: group))
        let thirdSession = try #require(model.sessionIDs(ofTab: third).first)
        #expect(registry.paneView(for: thirdSession)?.controller.surface is SwiftTermSurface)
    }

    @Test func respawnUsesTheProfileAsItIsNow() async throws {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (model, registry, workspace) = makeRegistry(settings: settings)
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let profileID = model.newProfile()
        var profile = try #require(model.profile(profileID))
        profile.kind = .command
        profile.program = "top"
        model.updateProfile(profile)
        let tab = try #require(model.newTab(in: group, profile: profileID))
        let sessionID = try #require(model.sessionIDs(ofTab: tab).first)
        let controller = try #require(registry.paneView(for: sessionID)?.controller)

        profile.program = "htop"
        model.updateProfile(profile)
        controller.markEnded()
        await controller.respawn()
        #expect(controller.session.id != sessionID)
        #expect(controller.session.launch == LaunchSpec(program: "htop"))
        #expect(model.session(controller.session.id)?.launch == LaunchSpec(program: "htop"))
    }

    @Test func theSettingsWindowRestoresItsTabAndRemembersTheChoice() throws {
        _ = NSApplication.shared
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        settings.preferences.settingsTab = "profiles"
        let model = AppModel(defaultWorkingDirectory: "/")
        let controller = SettingsWindowController(model: model, settings: settings) {
            MainMenu.make(installsSpecialMenus: false)
        }
        #expect(controller.selectedTab == .profiles)
        #expect(controller.window?.toolbarStyle == .preference)
        controller.show(.appearance)
        #expect(settings.preferences.settingsTab == "appearance")
        #expect(abs((controller.window?.contentLayoutRect.height ?? 0) - SettingsWindowController.Tab.appearance.contentSize.height) < 1)
        controller.window?.close()
    }
}
