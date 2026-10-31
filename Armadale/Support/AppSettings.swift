import AppKit
import ArmadaleCore
import SwiftTermSurface
import TerminalSurface

/// What panes and the Settings window read their configuration from:
/// preferences, the theme catalog and the renderers. One per app (tests
/// make their own, with a private defaults suite and no themes folder).
@MainActor
struct AppSettings {
    let preferences: Preferences
    let themes: ThemeCatalog
    let surfaces: SurfaceRegistry

    /// The app's settings: ``Preferences/shared``, the themes folder in the
    /// state directory, and every registered renderer.
    static let shared = AppSettings(
        preferences: .shared,
        themes: ThemeCatalog(directory: ThemeCatalog.userThemesDirectory()),
        surfaces: .standard)

    /// The terminal appearance for a view shown in `appearance` (light or
    /// dark). `paneThemeID` is a pane's own theme (``Pane/themeID``, DESIGN §8
    /// "Pane context menu"): when the catalog knows it, it is used whatever
    /// the appearance; when it is `nil` or unknown (a theme removed outside
    /// the app, a typo in the state file), the Settings choice for the
    /// appearance is used.
    func terminalAppearance(for appearance: NSAppearance, paneThemeID: String? = nil) -> TerminalAppearance {
        terminalAppearance(isDark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, paneThemeID: paneThemeID)
    }

    func terminalAppearance(isDark: Bool, paneThemeID: String? = nil) -> TerminalAppearance {
        TerminalAppearance(
            fontName: preferences.fontName,
            fontSize: preferences.fontSize,
            theme: theme(isDark: isDark, paneThemeID: paneThemeID),
            cursor: TerminalCursorStyle(shape: preferences.cursorShape, blinks: preferences.cursorBlinks))
    }

    /// The theme a pane shows: its own when the catalog knows it, else the
    /// Settings choice for the appearance.
    func theme(isDark: Bool, paneThemeID: String? = nil) -> TerminalTheme {
        paneTheme(paneThemeID) ?? themes.theme(id: preferences.themeID(isDark: isDark), isDark: isDark)
    }

    /// A pane's own theme, if it has one the catalog knows.
    func paneTheme(_ paneThemeID: String?) -> TerminalTheme? {
        paneThemeID.flatMap { themes.entry(id: $0)?.theme }
    }

    /// Settings › Appearance › Remove: deletes an imported theme; the
    /// Settings choices naming it go back to the defaults and the panes
    /// using it (``AppModel/forgetTheme(_:)``) back to the Settings choice.
    func removeUserTheme(_ id: String, model: AppModel?) throws {
        try themes.removeUserTheme(id: id)
        preferences.forgetTheme(id)
        model?.forgetTheme(id)
    }

    /// The renderer new surfaces are made with.
    var surfaceFactory: SurfaceFactory {
        surfaces.factory(for: preferences.rendererID)
    }

    /// Changes that require re-applying the appearance: any preference it
    /// is made from, or a user theme changing on disk.
    struct AppearanceChange: Hashable, Sendable {
        var inputs: Preferences.AppearanceInputs
        var themesRevision: Int
    }

    var appearanceChange: AppearanceChange {
        AppearanceChange(inputs: preferences.appearanceInputs, themesRevision: themes.revision)
    }
}

extension SurfaceRegistry {
    /// Every renderer built into Armadale; SwiftTerm is the default.
    @MainActor static let standard = SurfaceRegistry(default: SwiftTermSurface.factory)
}
