import Foundation
import TerminalSurface
import Testing

@Suite("ThemeCatalog")
@MainActor
struct ThemeCatalogTests {
    @Test func everyBuiltInThemeIsComplete() {
        let builtIns = ThemeCatalog.builtIns
        #expect(Set(builtIns.map(\.id)).count == builtIns.count, "unique IDs")
        #expect(Set(builtIns.map(\.name)).count == builtIns.count, "unique names")
        for name in ["Armadale Light", "Armadale Dark", "Solarized Light", "Solarized Dark", "Dracula", "Nord",
                     "One Dark", "Gruvbox Dark"] {
            #expect(builtIns.contains { $0.name == name }, "\(name) is built in")
        }
        for entry in builtIns {
            #expect(entry.isBuiltIn)
            #expect(entry.id.hasPrefix("builtin."))
            #expect(entry.theme.ansi.count == 16, "\(entry.name) has 16 palette entries")
            #expect(entry.theme.foreground != entry.theme.background, "\(entry.name) fg differs from bg")
            #expect(entry.theme.selection != entry.theme.background, "\(entry.name) selection is visible")
            // WCAG contrast ratio; Solarized, low-contrast by design, is about 4.1.
            let (fg, bg) = (entry.theme.foreground.luminance, entry.theme.background.luminance)
            let contrast = (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
            #expect(contrast > 3.5, "\(entry.name) text is readable (\(contrast))")
        }
        #expect(builtIns.first { $0.id == ThemeCatalog.defaultLightID }?.isDark == false)
        #expect(builtIns.first { $0.id == ThemeCatalog.defaultDarkID }?.isDark == true)
        #expect(ThemeCatalog.solarizedLight.ansi == ThemeCatalog.solarizedDark.ansi)
        #expect(ThemeCatalog.dracula.background == TerminalColor(hex: 0x282A36))
        #expect(ThemeCatalog.nord.background == TerminalColor(hex: 0x2E3440))
    }

    @Test func importedGhosttyThemesAreStoredAndReloaded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("armadale-themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let themes = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("My Theme")
        try """
            # comment
            background = #101010
            foreground = #e0e0e0
            palette = 1=#ff0000
            not a line
            """.write(to: source, atomically: true, encoding: .utf8)

        let catalog = ThemeCatalog(directory: themes)
        #expect(catalog.userThemes.isEmpty)
        let revision = catalog.revision
        let result = try catalog.importGhosttyTheme(at: source)
        #expect(result.entry.id == "user.my theme", "IDs are lower-case")
        #expect(result.entry.name == "My Theme")
        #expect(result.entry.isDark)
        #expect(result.warnings.count == 1)
        #expect(!result.replacedExisting)
        #expect(FileManager.default.fileExists(atPath: themes.appendingPathComponent("My Theme.json").path))
        #expect(catalog.revision != revision)
        #expect(catalog.entry(id: "user.My Theme")?.theme.ansi[1] == TerminalColor(hex: 0xFF0000), "lookup ignores case")
        #expect(catalog.entry(id: "user.my theme")?.name == "My Theme")
        #expect(catalog.all.count == ThemeCatalog.builtIns.count + 1)

        let reopened = ThemeCatalog(directory: themes)
        #expect(reopened.userThemes.map(\.id) == ["user.my theme"])
        #expect(reopened.theme(id: "user.My Theme", isDark: true).background == TerminalColor(hex: 0x101010))

        try "background = #fafafa\nforeground = #111111\n".write(to: source, atomically: true, encoding: .utf8)
        let again = try catalog.importGhosttyTheme(at: source)
        #expect(again.replacedExisting)
        #expect(!again.entry.isDark)
        #expect(catalog.userThemes.count == 1)

        // A file named in another case is the same theme: it is replaced.
        let otherCase = root.appendingPathComponent("my theme")
        try "background = #202020\n".write(to: otherCase, atomically: true, encoding: .utf8)
        #expect(try catalog.importGhosttyTheme(at: otherCase).replacedExisting)
        #expect(catalog.userThemes.count == 1)

        let revisionBeforeRemove = catalog.revision
        try catalog.removeUserTheme(id: "user.My Theme")
        #expect(catalog.userThemes.isEmpty, "the list is refreshed without a relaunch")
        #expect(catalog.revision != revisionBeforeRemove)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: themes.path))?.isEmpty == true)
        #expect(catalog.theme(id: "user.My Theme", isDark: false) == ThemeCatalog.armadaleLight)
    }

    @Test func importRejectsFilesWithoutColours() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("armadale-themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("notes.txt")
        try "font-size = 14\n".write(to: source, atomically: true, encoding: .utf8)
        let catalog = ThemeCatalog(directory: root.appendingPathComponent("themes"))
        #expect(throws: ThemeCatalog.ImportError.self) { try catalog.importGhosttyTheme(at: source) }
        #expect(catalog.userThemes.isEmpty)
        #expect(throws: ThemeCatalog.ImportError.self) {
            try catalog.importGhosttyTheme(at: root.appendingPathComponent("missing"))
        }
    }

    @Test func themeFileNames() {
        #expect(ThemeCatalog.themeName(forFile: URL(fileURLWithPath: "/x/Dracula+")) == "Dracula+")
        #expect(ThemeCatalog.themeName(forFile: URL(fileURLWithPath: "/x/Catppuccin Mocha.conf")) == "Catppuccin Mocha")
        #expect(ThemeCatalog.fileStem(for: "a/b:c") == "a-b-c")
        #expect(ThemeCatalog.fileStem(for: "..hidden") == "hidden")
        #expect(ThemeCatalog.fileStem(for: "...") == "theme")
    }

    @Test func removingAThemeInUseFallsBackToTheDefaults() {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let preferences = settings.preferences
        preferences.themeID = "user.Mine"
        preferences.lightThemeID = "user.mine"
        preferences.darkThemeID = "builtin.nord"
        preferences.forgetTheme("user.mine")
        #expect(preferences.themeID == ThemeCatalog.defaultDarkID)
        #expect(preferences.lightThemeID == ThemeCatalog.defaultLightID)
        #expect(preferences.darkThemeID == "builtin.nord", "other choices stay")
    }

    @Test func theLightDefaultPaletteIsArmadaleLights() {
        #expect(ThemeCatalog.armadaleLight.ansi == TerminalTheme.defaultLightANSI)
        #expect(ThemeCatalog.armadaleDark.ansi == TerminalTheme.defaultANSI)
    }
}
