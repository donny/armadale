import AppKit
import ArmadaleCore
import Observation
import SwiftTermSurface
import TerminalSurface

/// Armadale's settings, typed, kept in a `UserDefaults` domain that is
/// injected (tests pass their own suite). Observable, so panes and the
/// Settings window follow every change at once; every write goes straight
/// to the defaults.
///
/// Profiles are not here: they are part of the model (`state.json`).
@MainActor
@Observable
final class Preferences {
    /// UserDefaults keys. `confirmClosingRunningSession` predates this type.
    enum Key {
        static let defaultProfileID = "defaultProfileID"
        static let defaultWorkingDirectory = "defaultWorkingDirectory"
        static let confirmClosingRunningSession = "confirmClosingRunningSession"
        static let fontName = "fontName"
        static let fontSize = "fontSize"
        static let followsSystemAppearance = "themeFollowsSystemAppearance"
        static let themeID = "themeID"
        static let lightThemeID = "lightThemeID"
        static let darkThemeID = "darkThemeID"
        static let cursorShape = "cursorShape"
        static let cursorBlinks = "cursorBlinks"
        static let rendererID = "rendererID"
        static let settingsWindowTopLeft = "settingsWindowTopLeft"
        static let settingsTab = "settingsTab"
    }

    static let fontSizeRange: ClosedRange<Double> = 6...48
    static let defaultFontSize: Double = 12
    /// SF Mono when it is installed as a regular font, else Menlo.
    static let defaultFontName = NSFont(name: "SFMono-Regular", size: 12) != nil ? "SFMono-Regular" : "Menlo"

    @ObservationIgnored let defaults: UserDefaults
    /// The suite `defaults` is, if it is not the standard domain.
    @ObservationIgnored let suiteName: String?

    private var storedDefaultProfileID: String
    private var storedDefaultWorkingDirectory: String
    private var storedConfirmClosing: Bool
    private var storedFontName: String
    private var storedFontSize: Double
    private var storedFollowsSystem: Bool
    private var storedThemeID: String
    private var storedLightThemeID: String
    private var storedDarkThemeID: String
    private var storedCursorShape: TerminalCursorStyle.Shape
    private var storedCursorBlinks: Bool
    private var storedRendererID: String

    init(defaults: UserDefaults, suiteName: String? = nil) {
        self.defaults = defaults
        self.suiteName = suiteName
        storedDefaultProfileID = defaults.string(forKey: Key.defaultProfileID) ?? Profile.shell.id.raw
        storedDefaultWorkingDirectory = defaults.string(forKey: Key.defaultWorkingDirectory) ?? ""
        storedConfirmClosing = defaults.object(forKey: Key.confirmClosingRunningSession) as? Bool ?? true
        storedFontName = defaults.string(forKey: Key.fontName).flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultFontName
        storedFontSize = Self.clampFontSize(defaults.object(forKey: Key.fontSize) as? Double ?? Self.defaultFontSize)
        storedFollowsSystem = defaults.object(forKey: Key.followsSystemAppearance) as? Bool ?? true
        storedThemeID = defaults.string(forKey: Key.themeID) ?? ThemeCatalog.defaultDarkID
        storedLightThemeID = defaults.string(forKey: Key.lightThemeID) ?? ThemeCatalog.defaultLightID
        storedDarkThemeID = defaults.string(forKey: Key.darkThemeID) ?? ThemeCatalog.defaultDarkID
        storedCursorShape = defaults.string(forKey: Key.cursorShape).flatMap(TerminalCursorStyle.Shape.init(rawValue:)) ?? .block
        storedCursorBlinks = defaults.object(forKey: Key.cursorBlinks) as? Bool ?? true
        storedRendererID = defaults.string(forKey: Key.rendererID) ?? SwiftTermSurface.rendererID
    }

    // MARK: General

    /// Profile of new tabs, tab groups and workspaces (⌘T, ⇧⌘N, ⌘N).
    var defaultProfileID: ProfileID {
        get { ProfileID(raw: storedDefaultProfileID) }
        set { storedDefaultProfileID = newValue.raw; defaults.set(newValue.raw, forKey: Key.defaultProfileID) }
    }

    /// Resets ``defaultProfileID`` to the shell if it names none of
    /// `profiles` (the profile was deleted). Returns whether it changed.
    @discardableResult
    func reconcileDefaultProfile(with profiles: [ProfileID]) -> Bool {
        guard !profiles.contains(defaultProfileID) else { return false }
        defaultProfileID = Profile.shell.id
        return true
    }

    /// Where new sessions start, as typed; empty means the home folder.
    var defaultWorkingDirectory: String {
        get { storedDefaultWorkingDirectory }
        set { storedDefaultWorkingDirectory = newValue; defaults.set(newValue, forKey: Key.defaultWorkingDirectory) }
    }

    /// ``defaultWorkingDirectory`` as an absolute path: `~` expanded, empty
    /// meaning `home`.
    func resolvedWorkingDirectory(home: String = NSHomeDirectory()) -> String {
        let trimmed = defaultWorkingDirectory.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return home }
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2))) }
        return trimmed
    }

    /// Ask before closing a pane, tab or tab group whose process runs.
    var confirmClosingRunningSession: Bool {
        get { storedConfirmClosing }
        set { storedConfirmClosing = newValue; defaults.set(newValue, forKey: Key.confirmClosingRunningSession) }
    }

    // MARK: Appearance

    /// PostScript name of the terminal font.
    var fontName: String {
        get { storedFontName }
        set { storedFontName = newValue; defaults.set(newValue, forKey: Key.fontName) }
    }

    /// Terminal font size in points, kept within ``fontSizeRange``.
    var fontSize: Double {
        get { storedFontSize }
        set {
            let size = Self.clampFontSize(newValue)
            storedFontSize = size
            defaults.set(size, forKey: Key.fontSize)
        }
    }

    /// Use ``lightThemeID`` in light mode and ``darkThemeID`` in dark mode,
    /// rather than ``themeID`` always.
    var followsSystemAppearance: Bool {
        get { storedFollowsSystem }
        set { storedFollowsSystem = newValue; defaults.set(newValue, forKey: Key.followsSystemAppearance) }
    }

    var themeID: String {
        get { storedThemeID }
        set { storedThemeID = newValue; defaults.set(newValue, forKey: Key.themeID) }
    }

    var lightThemeID: String {
        get { storedLightThemeID }
        set { storedLightThemeID = newValue; defaults.set(newValue, forKey: Key.lightThemeID) }
    }

    var darkThemeID: String {
        get { storedDarkThemeID }
        set { storedDarkThemeID = newValue; defaults.set(newValue, forKey: Key.darkThemeID) }
    }

    var cursorShape: TerminalCursorStyle.Shape {
        get { storedCursorShape }
        set { storedCursorShape = newValue; defaults.set(newValue.rawValue, forKey: Key.cursorShape) }
    }

    var cursorBlinks: Bool {
        get { storedCursorBlinks }
        set { storedCursorBlinks = newValue; defaults.set(newValue, forKey: Key.cursorBlinks) }
    }

    /// Identifier of the renderer new surfaces are made with
    /// (``SurfaceRegistry``); an unknown one falls back to the default.
    var rendererID: String {
        get { storedRendererID }
        set { storedRendererID = newValue; defaults.set(newValue, forKey: Key.rendererID) }
    }

    /// A theme was removed: every choice naming it goes back to the default
    /// light or dark theme.
    func forgetTheme(_ id: String) {
        let key = id.lowercased()
        if themeID.lowercased() == key { themeID = ThemeCatalog.defaultDarkID }
        if lightThemeID.lowercased() == key { lightThemeID = ThemeCatalog.defaultLightID }
        if darkThemeID.lowercased() == key { darkThemeID = ThemeCatalog.defaultDarkID }
    }

    /// The theme in use for the given system appearance.
    func themeID(isDark: Bool) -> String {
        guard followsSystemAppearance else { return themeID }
        return isDark ? darkThemeID : lightThemeID
    }

    /// Everything the terminal appearance depends on, for observing.
    var appearanceInputs: AppearanceInputs {
        AppearanceInputs(
            fontName: fontName, fontSize: fontSize, followsSystemAppearance: followsSystemAppearance,
            themeID: themeID, lightThemeID: lightThemeID, darkThemeID: darkThemeID,
            cursor: TerminalCursorStyle(shape: cursorShape, blinks: cursorBlinks))
    }

    struct AppearanceInputs: Hashable, Sendable {
        var fontName: String
        var fontSize: Double
        var followsSystemAppearance: Bool
        var themeID: String
        var lightThemeID: String
        var darkThemeID: String
        var cursor: TerminalCursorStyle
    }

    // MARK: Font size (⌘= / ⌘- / ⌘0)

    func increaseFontSize() { fontSize += 1 }
    func decreaseFontSize() { fontSize -= 1 }
    func resetFontSize() { fontSize = Self.defaultFontSize }
    var canIncreaseFontSize: Bool { fontSize < Self.fontSizeRange.upperBound }
    var canDecreaseFontSize: Bool { fontSize > Self.fontSizeRange.lowerBound }

    private static func clampFontSize(_ size: Double) -> Double {
        guard size.isFinite else { return defaultFontSize }
        return min(max(size.rounded(), fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    // MARK: Settings window

    /// Top-left corner of the Settings window (`NSStringFromPoint`).
    var settingsWindowTopLeft: NSPoint? {
        get { defaults.string(forKey: Key.settingsWindowTopLeft).map(NSPointFromString) }
        set { defaults.set(newValue.map(NSStringFromPoint), forKey: Key.settingsWindowTopLeft) }
    }

    /// The Settings tab last shown.
    var settingsTab: String? {
        get { defaults.string(forKey: Key.settingsTab) }
        set { defaults.set(newValue, forKey: Key.settingsTab) }
    }

    // MARK: Domain

    /// Environment variable naming the UserDefaults suite to use instead of
    /// the app's own domain (tests, debugging). `-ArmadaleDefaultsSuite
    /// <name>` on the command line does the same.
    static let suiteVariable = "ARMADALE_DEFAULTS_SUITE"
    static let suiteArgument = "-ArmadaleDefaultsSuite"

    /// The suite named by ``suiteVariable`` or ``suiteArgument``, if any.
    static func suiteName(environment: [String: String], arguments: [String]) -> String? {
        if let name = environment[suiteVariable], !name.isEmpty { return name }
        if let index = arguments.firstIndex(of: suiteArgument), arguments.indices.contains(index + 1) {
            let name = arguments[index + 1]
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// The app's preferences: in the suite named by ``suiteVariable`` or
    /// ``suiteArgument`` when one is given, else in the standard domain.
    static func forApp(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Preferences {
        guard let name = suiteName(environment: environment, arguments: arguments) else {
            return Preferences(defaults: .standard)
        }
        guard let suite = UserDefaults(suiteName: name) else {
            NSLog("Armadale: cannot use defaults suite %@; using the standard domain", name)
            return Preferences(defaults: .standard)
        }
        return Preferences(defaults: suite, suiteName: name)
    }

    /// The app's preferences.
    static let shared = Preferences.forApp()
}
