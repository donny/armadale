import AppKit
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

    /// The terminal appearance for a view shown in `appearance` (light or dark).
    func terminalAppearance(for appearance: NSAppearance) -> TerminalAppearance {
        terminalAppearance(isDark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    func terminalAppearance(isDark: Bool) -> TerminalAppearance {
        TerminalAppearance(
            fontName: preferences.fontName,
            fontSize: preferences.fontSize,
            theme: themes.theme(id: preferences.themeID(isDark: isDark), isDark: isDark),
            cursor: TerminalCursorStyle(shape: preferences.cursorShape, blinks: preferences.cursorBlinks))
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
