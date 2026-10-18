import ArmadaleCore
import Foundation
import Observation
import TerminalSurface

/// A theme the user can pick: built in, or imported into the themes folder.
struct ThemeEntry: Identifiable, Hashable, Sendable {
    /// Stable identifier stored in preferences: `builtin.<slug>` or
    /// `user.<file name>`, always lower-case (file names on macOS are
    /// usually case-insensitive, so "Nord+" and "nord+" are one theme).
    let id: String
    var theme: TerminalTheme
    var isBuiltIn: Bool

    var name: String { theme.name }
    /// Whether the background is dark (for grouping and previews).
    var isDark: Bool { theme.background.luminance < 0.4 }
}

/// The themes Armadale knows: the built-ins below, plus user themes kept as
/// JSON in `<state dir>/themes/<name>.json` (imported from Ghostty theme
/// files with ``importGhosttyTheme(at:)``).
@MainActor
@Observable
final class ThemeCatalog {
    static let defaultLightID = "builtin.armadale-light"
    static let defaultDarkID = "builtin.armadale-dark"

    private(set) var userThemes: [ThemeEntry] = []
    /// Incremented whenever a user theme is added, replaced or removed, so
    /// panes showing it re-apply it.
    private(set) var revision = 0
    /// Where user themes live; `nil` for built-ins only (tests).
    @ObservationIgnored let directory: URL?
    /// The file of each user theme, by ID.
    @ObservationIgnored private var files: [String: URL] = [:]

    init(directory: URL?) {
        self.directory = directory
        reload()
    }

    /// The themes folder in the state directory.
    static func userThemesDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        StateLocation.directory(environment: environment).appendingPathComponent("themes", isDirectory: true)
    }

    /// Built-ins first, then user themes by name.
    var all: [ThemeEntry] { Self.builtIns + userThemes }

    /// The theme with `id`, compared case-insensitively.
    func entry(id: String) -> ThemeEntry? {
        let key = id.lowercased()
        return all.first { $0.id == key }
    }

    /// The theme `id` names, or the default light or dark one if it is
    /// unknown (a removed user theme).
    func theme(id: String, isDark: Bool) -> TerminalTheme {
        entry(id: id)?.theme ?? (isDark ? Self.armadaleDark : Self.armadaleLight)
    }

    // MARK: User themes

    /// Reads the themes folder again. Files that cannot be read are logged
    /// and skipped.
    func reload() {
        guard let directory else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var themes: [ThemeEntry] = []
        var locations: [String: URL] = [:]
        for file in files where file.pathExtension == "json" {
            let id = Self.userID(fileStem: file.deletingPathExtension().lastPathComponent)
            guard locations[id] == nil else {
                NSLog("Armadale: skipping theme %@: another file has the same name", file.path)
                continue
            }
            do {
                let theme = try JSONDecoder().decode(TerminalTheme.self, from: Data(contentsOf: file))
                themes.append(ThemeEntry(id: id, theme: theme, isBuiltIn: false))
                locations[id] = file
            } catch {
                NSLog("Armadale: skipping theme %@: %@", file.path, String(describing: error))
            }
        }
        self.files = locations
        userThemes = themes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        revision &+= 1
    }

    /// What an import produced.
    struct ImportResult {
        var entry: ThemeEntry
        /// Lines of the file that were skipped.
        var warnings: [String]
        /// Whether a user theme with the same name was replaced.
        var replacedExisting: Bool
    }

    enum ImportError: Error, LocalizedError {
        case unreadable(String)
        case notATheme(String)
        case cannotSave(String)
        case noThemesFolder

        var errorDescription: String? {
            switch self {
            case .unreadable(let reason): "The file could not be read: \(reason)"
            case .notATheme(let reason): reason
            case .cannotSave(let reason): "The theme could not be saved: \(reason)"
            case .noThemesFolder: "There is no folder to keep imported themes in."
            }
        }
    }

    /// Reads a Ghostty theme file (``GhosttyTheme``) and saves it as a user
    /// theme named after the file. Importing a file with the same name again
    /// replaces the earlier import.
    func importGhosttyTheme(at url: URL) throws(ImportError) -> ImportResult {
        guard let directory else { throw .noThemesFolder }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        let name = Self.themeName(forFile: url)
        let parsed: GhosttyTheme.Result
        do {
            parsed = try GhosttyTheme.parse(text, name: name)
        } catch {
            throw .notATheme(error.description)
        }
        let stem = Self.fileStem(for: name)
        let id = Self.userID(fileStem: stem)
        // Same name in another case: replace that file rather than add a twin.
        let destination = files[id] ?? directory.appendingPathComponent(stem).appendingPathExtension("json")
        let replaced = files[id] != nil || FileManager.default.fileExists(atPath: destination.path)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(parsed.theme).write(to: destination, options: .atomic)
        } catch {
            throw .cannotSave(error.localizedDescription)
        }
        reload()
        let entry = ThemeEntry(id: id, theme: parsed.theme, isBuiltIn: false)
        return ImportResult(entry: entry, warnings: parsed.warnings, replacedExisting: replaced)
    }

    /// Deletes an imported theme's file and refreshes the list. Built-in
    /// themes cannot be removed. Preferences naming it fall back to the
    /// default theme (``Preferences/forgetTheme(_:)``).
    func removeUserTheme(id: String) throws {
        guard let file = files[id.lowercased()] else { return }
        defer { reload() }
        try FileManager.default.removeItem(at: file)
    }

    private static let userPrefix = "user."

    private static func userID(fileStem: String) -> String { userPrefix + fileStem.lowercased() }

    /// A Ghostty theme file's name is the theme's name (`Dracula+`, or
    /// `Catppuccin Mocha.conf`).
    static func themeName(forFile url: URL) -> String {
        let last = url.lastPathComponent
        let name = ["conf", "ghostty", "theme", "txt"].contains(url.pathExtension.lowercased())
            ? url.deletingPathExtension().lastPathComponent : last
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Imported Theme" : trimmed
    }

    /// A file name for a theme name: no path separators, no leading dot.
    static func fileStem(for name: String) -> String {
        var stem = String(name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }.prefix(100))
        while stem.hasPrefix(".") { stem.removeFirst() }
        return stem.isEmpty ? "theme" : stem
    }

    // MARK: Built-in themes

    static let builtIns: [ThemeEntry] = [
        ThemeEntry(id: defaultLightID, theme: armadaleLight, isBuiltIn: true),
        ThemeEntry(id: defaultDarkID, theme: armadaleDark, isBuiltIn: true),
        ThemeEntry(id: "builtin.solarized-light", theme: solarizedLight, isBuiltIn: true),
        ThemeEntry(id: "builtin.solarized-dark", theme: solarizedDark, isBuiltIn: true),
        ThemeEntry(id: "builtin.dracula", theme: dracula, isBuiltIn: true),
        ThemeEntry(id: "builtin.nord", theme: nord, isBuiltIn: true),
        ThemeEntry(id: "builtin.one-dark", theme: oneDark, isBuiltIn: true),
        ThemeEntry(id: "builtin.gruvbox-dark", theme: gruvboxDark, isBuiltIn: true),
    ]

    private static func theme(
        _ name: String, ansi: [UInt32], foreground: UInt32, background: UInt32, cursor: UInt32, selection: UInt32
    ) -> TerminalTheme {
        TerminalTheme(
            name: name, ansi: ansi.map(TerminalColor.init(hex:)), foreground: TerminalColor(hex: foreground),
            background: TerminalColor(hex: background), cursor: TerminalColor(hex: cursor),
            selection: TerminalColor(hex: selection))
    }

    /// Armadale's own light theme (the step 2–4 default).
    static let armadaleLight = theme(
        "Armadale Light",
        ansi: [0x1D1F21, 0xC82829, 0x718C00, 0xB07D00, 0x4271AE, 0x8959A8, 0x3E999F, 0xA6A6A6,
               0x5C5F66, 0xE0464A, 0x82A000, 0xD69E00, 0x5B8BD0, 0xA270C4, 0x47B0B7, 0xD9D9D9],
        foreground: 0x24292F, background: 0xFFFFFF, cursor: 0x24292F, selection: 0xB4D5FE)

    /// Armadale's own dark theme (Tomorrow Night colours).
    static let armadaleDark = theme(
        "Armadale Dark",
        ansi: [0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
               0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA],
        foreground: 0xC5C8C6, background: 0x1D1F21, cursor: 0xC5C8C6, selection: 0x373B41)

    /// Solarized (Ethan Schoonover): the 16-colour terminal mapping, shared
    /// by light and dark (base02, red, green, yellow, blue, magenta, cyan,
    /// base2; base03, orange, base01, base00, base0, violet, base1, base3).
    private static let solarizedANSI: [UInt32] = [
        0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    ]

    static let solarizedLight = theme(
        "Solarized Light", ansi: solarizedANSI,
        foreground: 0x657B83, background: 0xFDF6E3, cursor: 0x586E75, selection: 0xEEE8D5)

    static let solarizedDark = theme(
        "Solarized Dark", ansi: solarizedANSI,
        foreground: 0x839496, background: 0x002B36, cursor: 0x93A1A1, selection: 0x073642)

    /// Dracula (draculatheme.com specification).
    static let dracula = theme(
        "Dracula",
        ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
               0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF],
        foreground: 0xF8F8F2, background: 0x282A36, cursor: 0xF8F8F2, selection: 0x44475A)

    /// Nord (nordtheme.com): nord1, 11, 14, 13, 9, 15, 8, 5; nord3, 11, 14,
    /// 13, 9, 15, 7, 6.
    static let nord = theme(
        "Nord",
        ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
               0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4],
        foreground: 0xD8DEE9, background: 0x2E3440, cursor: 0xD8DEE9, selection: 0x434C5E)

    /// One Dark (Atom; the onedark.vim terminal palette).
    static let oneDark = theme(
        "One Dark",
        ansi: [0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
               0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF],
        foreground: 0xABB2BF, background: 0x282C34, cursor: 0x528BFF, selection: 0x3E4451)

    /// Gruvbox Dark (morhetz), medium contrast.
    static let gruvboxDark = theme(
        "Gruvbox Dark",
        ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
               0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2],
        foreground: 0xEBDBB2, background: 0x282828, cursor: 0xEBDBB2, selection: 0x504945)
}
