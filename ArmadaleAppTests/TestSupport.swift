import AppKit
import ArmadaleCore
import ArmadaleSessions
import SwiftTermSurface
import TerminalSurface

/// The real SwiftTerm surface, recording every grid size it reports (the
/// sizes a pane's program would be sent as PTY resizes).
@MainActor
final class CountingSurface: TerminalSurface, TerminalSurfaceDelegate {
    let inner = SwiftTermSurface()
    weak var delegate: (any TerminalSurfaceDelegate)?
    private(set) var sizes: [GridSize] = []

    init() {
        inner.delegate = self
    }

    func resetLog() { sizes.removeAll() }

    var view: NSView { inner.view }
    var gridSize: GridSize { inner.gridSize }
    func feed(_ bytes: ArraySlice<UInt8>) { inner.feed(bytes) }
    func apply(_ appearance: TerminalAppearance) { inner.apply(appearance) }
    func clearScrollback() { inner.clearScrollback() }
    func scrollToBottom() { inner.scrollToBottom() }
    func find(_ query: String, direction: FindDirection) { inner.find(query, direction: direction) }
    var selectedText: String? { inner.selectedText }

    func surface(_ surface: any TerminalSurface, didInput bytes: [UInt8]) {
        delegate?.surface(self, didInput: bytes)
    }

    func surface(_ surface: any TerminalSurface, didResize size: GridSize) {
        sizes.append(size)
        delegate?.surface(self, didResize: size)
    }

    func surface(_ surface: any TerminalSurface, didSetTitle title: String) {
        delegate?.surface(self, didSetTitle: title)
    }

    func surface(_ surface: any TerminalSurface, didChangeDirectory url: URL) {
        delegate?.surface(self, didChangeDirectory: url)
    }

    func surfaceDidRingBell(_ surface: any TerminalSurface) {
        delegate?.surfaceDidRingBell(self)
    }

    func surface(_ surface: any TerminalSurface, didRequestClipboard op: ClipboardOp) {
        delegate?.surface(self, didRequestClipboard: op)
    }

    func surface(_ surface: any TerminalSurface, didReceiveNotification title: String, body: String) {
        delegate?.surface(self, didReceiveNotification: title, body: body)
    }

    func surface(_ surface: any TerminalSurface, didActivateLink link: String) {
        delegate?.surface(self, didActivateLink: link)
    }
}

/// A real ``PaneView`` over a never-started session, with a counting surface.
/// Its settings are only read, so their defaults suite never touches the
/// disk (see ``TestDefaults``) and needs no cleanup.
@MainActor
func makeCountingPane() -> (PaneView, CountingSurface) {
    let session = Session(profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "/")
    var surface: CountingSurface?
    let controller = SessionController(session: session, backend: EphemeralBackend(), makeSurface: {
        let made = CountingSurface()
        surface = made
        return made
    })
    // `makeSurface` runs synchronously in the initializer.
    return (PaneView(controller: controller, settings: .forTesting(), rendererID: "counting"), surface ?? CountingSurface())
}

extension AppSettings {
    /// Settings for tests: preferences in a private defaults suite kept in
    /// a temporary folder (removed again by ``removeTestDefaults()``), never
    /// in ~/Library/Preferences; built-in themes only; the standard renderers.
    @MainActor
    static func forTesting(surfaces: SurfaceRegistry = .standard) -> AppSettings {
        let suite = TestDefaults()
        return AppSettings(
            preferences: Preferences(defaults: suite.defaults, suiteName: suite.name),
            themes: ThemeCatalog(directory: nil),
            surfaces: surfaces)
    }

    /// Deletes the private defaults suite of a ``forTesting(surfaces:)`` instance.
    @MainActor
    func removeTestDefaults() {
        guard let name = preferences.suiteName else { return }
        TestDefaults.remove(name: name, defaults: preferences.defaults)
    }
}

/// A UserDefaults suite for one test. Its name is an absolute path, which
/// CFPreferences uses as the plist's location: the file lives in its own
/// temporary folder, so nothing is ever written to ~/Library/Preferences
/// (where cfprefsd would recreate an empty plist after the test removed it).
/// The folder is not created here: reading creates nothing, and cfprefsd
/// creates it on the first write, so a test that only reads leaves nothing
/// behind; a test that writes calls ``remove()``.
struct TestDefaults {
    let name: String
    let defaults: UserDefaults

    init() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("armadale-test-defaults-\(UUID().uuidString)", isDirectory: true)
        name = folder.appendingPathComponent("preferences").path
        defaults = UserDefaults(suiteName: name) ?? UserDefaults()
    }

    func remove() { Self.remove(name: name, defaults: defaults) }

    /// Clears the suite and removes its temporary folder.
    static func remove(name: String, defaults: UserDefaults) {
        let folder = URL(fileURLWithPath: name).deletingLastPathComponent()
        guard folder.lastPathComponent.hasPrefix("armadale-test-defaults-") else { return }
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: folder)
    }
}

extension AppModel {
    /// Starts a session, by default the shell on this Mac in the home
    /// directory, in every empty pane of every workspace (what step 10a's
    /// interim did with new panes; a quick way to give fixtures sessions).
    /// Returns the sessions started.
    @discardableResult
    func fillEmptyPanes(
        profile: ProfileID = Profile.shell.id, location: Location = .local, workingDirectory: String = ""
    ) -> [SessionID] {
        let request = SessionRequest(location: location, profileID: profile, workingDirectory: workingDirectory)
        return workspaces.flatMap { emptyPaneIDs(in: $0.id) }.compactMap { startSession(in: $0, request: request) }
    }

    /// A new tab in `group` whose pane runs `profile` at `location` (what
    /// File › New Tab with Profile and New Tab on Host made before step 10).
    func newTab(
        in group: TabGroupID, starting profile: ProfileID, at location: Location = .local,
        workingDirectory: String = ""
    ) -> TabID? {
        guard let tab = newTab(in: group), let pane = self.tab(tab)?.focusedPaneID else { return nil }
        let request = SessionRequest(location: location, profileID: profile, workingDirectory: workingDirectory)
        return startSession(in: pane, request: request) == nil ? nil : tab
    }
}
