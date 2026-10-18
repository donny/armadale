import AppKit
import ArmadaleCore
import Foundation
import TerminalSurface
import Testing

/// ``Preferences`` against a private UserDefaults suite: never the app's
/// real domain.
@Suite("Preferences")
@MainActor
struct PreferencesTests {
    private func withSuite(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let suite = TestDefaults()
        defer { suite.remove() }
        try body(suite.defaults, suite.name)
    }

    @Test func defaultsWhenNothingIsStored() {
        withSuite { defaults, _ in
            let preferences = Preferences(defaults: defaults)
            #expect(preferences.defaultProfileID == Profile.shell.id)
            #expect(preferences.defaultWorkingDirectory.isEmpty)
            #expect(preferences.confirmClosingRunningSession)
            #expect(preferences.fontName == Preferences.defaultFontName)
            #expect(preferences.fontSize == Preferences.defaultFontSize)
            #expect(preferences.followsSystemAppearance)
            #expect(preferences.themeID(isDark: false) == ThemeCatalog.defaultLightID)
            #expect(preferences.themeID(isDark: true) == ThemeCatalog.defaultDarkID)
            #expect(preferences.cursorShape == .block)
            #expect(preferences.cursorBlinks)
            #expect(preferences.rendererID == "swiftterm")
            #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("font") }, "reading writes nothing")
        }
    }

    @Test func everySettingPersistsAcrossInstances() {
        withSuite { defaults, _ in
            let preferences = Preferences(defaults: defaults)
            preferences.defaultProfileID = Profile.codex.id
            preferences.defaultWorkingDirectory = "~/src"
            preferences.confirmClosingRunningSession = false
            preferences.fontName = "Menlo-Regular"
            preferences.fontSize = 15
            preferences.followsSystemAppearance = false
            preferences.themeID = "builtin.nord"
            preferences.lightThemeID = "builtin.solarized-light"
            preferences.darkThemeID = "builtin.dracula"
            preferences.cursorShape = .bar
            preferences.cursorBlinks = false
            preferences.rendererID = "other"

            let reloaded = Preferences(defaults: defaults)
            #expect(reloaded.defaultProfileID == Profile.codex.id)
            #expect(reloaded.defaultWorkingDirectory == "~/src")
            #expect(!reloaded.confirmClosingRunningSession)
            #expect(reloaded.fontName == "Menlo-Regular")
            #expect(reloaded.fontSize == 15)
            #expect(!reloaded.followsSystemAppearance)
            #expect(reloaded.themeID(isDark: false) == "builtin.nord", "one theme for both when not following")
            #expect(reloaded.themeID(isDark: true) == "builtin.nord")
            reloaded.followsSystemAppearance = true
            #expect(reloaded.themeID(isDark: false) == "builtin.solarized-light")
            #expect(reloaded.themeID(isDark: true) == "builtin.dracula")
            #expect(reloaded.cursorShape == .bar)
            #expect(!reloaded.cursorBlinks)
            #expect(reloaded.rendererID == "other")
            // The close confirmation keeps its step 4 key.
            #expect(defaults.object(forKey: "confirmClosingRunningSession") as? Bool == false)
        }
    }

    @Test func fontSizeIsClampedAndTheMenuCommandsWriteThrough() {
        withSuite { defaults, _ in
            let preferences = Preferences(defaults: defaults)
            preferences.increaseFontSize()
            #expect(preferences.fontSize == 13)
            #expect(Preferences(defaults: defaults).fontSize == 13, "⌘= is stored")
            preferences.fontSize = 100
            #expect(preferences.fontSize == 48)
            #expect(!preferences.canIncreaseFontSize)
            preferences.increaseFontSize()
            #expect(preferences.fontSize == 48)
            preferences.fontSize = 1
            #expect(preferences.fontSize == 6)
            #expect(!preferences.canDecreaseFontSize)
            preferences.fontSize = 13.6
            #expect(preferences.fontSize == 14)
            preferences.decreaseFontSize()
            #expect(preferences.fontSize == 13)
            preferences.resetFontSize()
            #expect(preferences.fontSize == Preferences.defaultFontSize)
            defaults.set(500.0, forKey: Preferences.Key.fontSize)
            #expect(Preferences(defaults: defaults).fontSize == 48, "a hand-edited value is clamped on read")
        }
    }

    @Test func aDeletedDefaultProfileResetsThePreference() {
        withSuite { defaults, _ in
            let preferences = Preferences(defaults: defaults)
            let model = AppModel(defaultWorkingDirectory: "/")
            let id = model.newProfile()
            preferences.defaultProfileID = id
            #expect(!preferences.reconcileDefaultProfile(with: model.profiles.map(\.id)))
            #expect(preferences.defaultProfileID == id)
            model.deleteProfile(id)
            #expect(preferences.reconcileDefaultProfile(with: model.profiles.map(\.id)))
            #expect(preferences.defaultProfileID == Profile.shell.id)
            #expect(Preferences(defaults: defaults).defaultProfileID == Profile.shell.id, "stored")
        }
    }

    @Test func workingDirectoryResolution() {
        withSuite { defaults, _ in
            let preferences = Preferences(defaults: defaults)
            #expect(preferences.resolvedWorkingDirectory(home: "/Users/me") == "/Users/me")
            preferences.defaultWorkingDirectory = "~"
            #expect(preferences.resolvedWorkingDirectory(home: "/Users/me") == "/Users/me")
            preferences.defaultWorkingDirectory = "~/src/armadale"
            #expect(preferences.resolvedWorkingDirectory(home: "/Users/me") == "/Users/me/src/armadale")
            preferences.defaultWorkingDirectory = "/tmp "
            #expect(preferences.resolvedWorkingDirectory(home: "/Users/me") == "/tmp")
        }
        #expect(ProfileIcon.abbreviatingHome("/Users/me/x", home: "/Users/me") == "~/x")
        #expect(ProfileIcon.abbreviatingHome("/Users/meme", home: "/Users/me") == "/Users/meme")
    }

    @Test func suiteSelection() {
        #expect(Preferences.suiteName(environment: [:], arguments: ["Armadale"]) == nil)
        #expect(Preferences.suiteName(environment: ["ARMADALE_DEFAULTS_SUITE": "s"], arguments: []) == "s")
        #expect(Preferences.suiteName(environment: [:], arguments: ["Armadale", "-ArmadaleDefaultsSuite", "t"]) == "t")
        #expect(Preferences.suiteName(environment: [:], arguments: ["Armadale", "-ArmadaleDefaultsSuite"]) == nil)
        let suite = TestDefaults()
        defer { suite.remove() }
        let name = suite.name
        let preferences = Preferences.forApp(environment: ["ARMADALE_DEFAULTS_SUITE": name], arguments: [])
        #expect(preferences.suiteName == name)
        #expect(preferences.defaults !== UserDefaults.standard)
    }

    @Test func appearanceFollowsThePreferences() {
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let preferences = settings.preferences
        preferences.fontName = "Menlo-Regular"
        preferences.fontSize = 16
        preferences.cursorShape = .underline
        preferences.cursorBlinks = false
        preferences.lightThemeID = "builtin.solarized-light"
        preferences.darkThemeID = "builtin.gruvbox-dark"
        let light = settings.terminalAppearance(isDark: false)
        let dark = settings.terminalAppearance(isDark: true)
        #expect(light.fontName == "Menlo-Regular")
        #expect(light.fontSize == 16)
        #expect(light.cursor == TerminalCursorStyle(shape: .underline, blinks: false))
        #expect(light.theme.name == "Solarized Light")
        #expect(dark.theme.name == "Gruvbox Dark")
        preferences.darkThemeID = "user.gone"
        #expect(settings.terminalAppearance(isDark: true).theme == ThemeCatalog.armadaleDark, "unknown theme falls back")
        #expect(settings.terminalAppearance(for: NSAppearance(named: .darkAqua) ?? NSAppearance()).theme == ThemeCatalog.armadaleDark)
        #expect(settings.terminalAppearance(for: NSAppearance(named: .aqua) ?? NSAppearance()).theme.name == "Solarized Light")
    }
}
