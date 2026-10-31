import AppKit
import ArmadaleCore
import SwiftUI
import TerminalSurface

/// Settings › Appearance: font, size, theme, cursor and renderer. Every
/// change applies to all open panes at once (the renderer at their next
/// attach).
struct AppearanceSettingsView: View {
    let settings: AppSettings
    /// Where panes keep their own theme; removing a theme clears it there.
    var model: AppModel?
    @Bindable private var preferences: Preferences
    private let themes: ThemeCatalog
    @State private var families = FontChoice.monospacedFamilies()
    @State private var fontPanel = FontPanelBridge()
    @State private var importReport: ImportReport?
    /// Why the font chosen in the font panel was not used.
    @State private var fontProblem: String?
    /// Follows the system's light / dark appearance (the window's).
    @Environment(\.colorScheme) private var colorScheme

    init(settings: AppSettings, model: AppModel? = nil) {
        self.settings = settings
        self.model = model
        self.preferences = settings.preferences
        self.themes = settings.themes
    }

    var body: some View {
        Form {
            Section("Font") {
                LabeledContent("Font") {
                    HStack {
                        Picker("Font", selection: $preferences.fontName) {
                            ForEach(fontChoices) { choice in
                                Text(choice.displayName).tag(choice.postScriptName)
                            }
                        }
                        .labelsHidden()
                        Button("Show Fonts…", action: showFontPanel)
                    }
                }
                LabeledContent("Size") {
                    HStack(spacing: 6) {
                        TextField("Size", value: $preferences.fontSize, format: .number.precision(.fractionLength(0)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 44)
                        Stepper("Size", value: $preferences.fontSize, in: Preferences.fontSizeRange, step: 1)
                            .labelsHidden()
                        Text("pt").foregroundStyle(.secondary)
                    }
                }
                if let fontProblem {
                    Label(fontProblem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Use different themes for light and dark appearance", isOn: $preferences.followsSystemAppearance)
                if preferences.followsSystemAppearance {
                    themePicker("Light appearance", selection: $preferences.lightThemeID, isDark: false)
                    themePicker("Dark appearance", selection: $preferences.darkThemeID, isDark: true)
                } else {
                    themePicker("Theme", selection: $preferences.themeID, isDark: true)
                }
                ThemePreview(appearance: settings.terminalAppearance(isDark: previewIsDark))
                    .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            } header: {
                Text("Theme")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Import a Ghostty theme file to add it to the list. Imported themes are kept in Armadale’s themes folder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !themes.userThemes.isEmpty {
                        Menu("Remove") {
                            ForEach(themes.userThemes) { entry in
                                Button(entry.name) { removeTheme(entry) }
                            }
                        }
                        .menuStyle(.button)
                        .fixedSize()
                        .help("Remove an imported theme")
                    }
                    Button("Import Ghostty Theme…", action: importTheme)
                }
            }

            Section("Cursor") {
                Picker("Shape", selection: $preferences.cursorShape) {
                    Text("Block").tag(TerminalCursorStyle.Shape.block)
                    Text("Underline").tag(TerminalCursorStyle.Shape.underline)
                    Text("Bar").tag(TerminalCursorStyle.Shape.bar)
                }
                .pickerStyle(.segmented)
                Toggle("Blink", isOn: $preferences.cursorBlinks)
            }

            Section {
                Picker("Renderer", selection: renderer) {
                    ForEach(settings.surfaces.factories) { factory in
                        Text(factory.displayName).tag(factory.id)
                    }
                }
            } header: {
                Text("Renderer")
            } footer: {
                Text("New panes use the chosen renderer. Open panes switch the next time they attach to their session: after Respawn or Reconnect, or when Armadale next starts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert(importReport?.title ?? "", isPresented: importReportShown, presenting: importReport) { _ in
            Button("OK") {}
        } message: { report in
            Text(report.message)
        }
        .onDisappear { fontPanel.detach() }
    }

    // MARK: Font

    /// The installed monospaced families, plus the current font if it is
    /// not one of them (picked in the font panel, or not installed any more).
    private var fontChoices: [FontChoice] {
        if families.contains(where: { $0.postScriptName == preferences.fontName }) { return families }
        return families + [FontChoice(postScriptName: preferences.fontName)]
    }

    private func showFontPanel() {
        let preferences = preferences
        let current = NSFont(name: preferences.fontName, size: preferences.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: preferences.fontSize, weight: .regular)
        fontProblem = nil
        fontPanel.show(current: current) { font in
            // A terminal needs every cell the same width.
            guard font.isFixedPitch else {
                fontProblem = "“\(font.displayName ?? font.fontName)” isn’t a monospaced font, so it wasn’t used."
                preferences.fontSize = font.pointSize
                return
            }
            fontProblem = nil
            preferences.fontName = font.fontName
            preferences.fontSize = font.pointSize
        }
    }

    // MARK: Theme

    /// The preview shows the theme for the current system appearance.
    private var previewIsDark: Bool {
        guard preferences.followsSystemAppearance else { return true }
        return colorScheme == .dark
    }

    /// A picker over every theme. A selection naming a theme that no longer
    /// exists shows (and is) the default.
    private func themePicker(_ title: String, selection: Binding<String>, isDark: Bool) -> some View {
        let fallback = isDark ? ThemeCatalog.defaultDarkID : ThemeCatalog.defaultLightID
        let binding = Binding {
            themes.entry(id: selection.wrappedValue)?.id ?? fallback
        } set: { selection.wrappedValue = $0 }
        return Picker(title, selection: binding) {
            Section("Built-in") {
                ForEach(ThemeCatalog.builtIns) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
            if !themes.userThemes.isEmpty {
                Section("Imported") {
                    ForEach(themes.userThemes) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                }
            }
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a Ghostty theme file (lines like “background = #282a36” and “palette = 0=#000000”)."
        let complete: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            importTheme(from: url)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { complete(response) }
            }
        } else {
            complete(panel.runModal())
        }
    }

    /// Removes an imported theme; choices that used it go back to the defaults.
    private func removeTheme(_ entry: ThemeEntry) {
        do {
            try settings.removeUserTheme(entry.id, model: model)
        } catch {
            importReport = ImportReport(
                title: "“\(entry.name)” could not be removed", message: error.localizedDescription)
        }
    }

    private func importTheme(from url: URL) {
        do {
            let result = try themes.importGhosttyTheme(at: url)
            // Use it right away, for the appearance it suits.
            if preferences.followsSystemAppearance {
                if result.entry.isDark { preferences.darkThemeID = result.entry.id } else { preferences.lightThemeID = result.entry.id }
            } else {
                preferences.themeID = result.entry.id
            }
            var message = result.replacedExisting
                ? "It replaces the theme imported earlier under the same name."
                : "It is now selected and listed under Imported."
            if !result.warnings.isEmpty {
                let shown = result.warnings.prefix(5).joined(separator: "\n")
                let more = result.warnings.count > 5 ? "\n…and \(result.warnings.count - 5) more" : ""
                message += "\n\nSome lines were skipped:\n\(shown)\(more)"
            }
            importReport = ImportReport(title: "Imported “\(result.entry.name)”", message: message)
        } catch {
            importReport = ImportReport(
                title: "“\(url.lastPathComponent)” could not be imported",
                message: error.errorDescription ?? String(describing: error))
        }
    }

    private struct ImportReport: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    private var importReportShown: Binding<Bool> {
        Binding { importReport != nil } set: { if !$0 { importReport = nil } }
    }

    // MARK: Renderer

    /// The preference, shown as the default renderer if it names one that
    /// is not available (which is what new panes then get).
    private var renderer: Binding<String> {
        Binding {
            settings.surfaces.factory(for: preferences.rendererID).id
        } set: { preferences.rendererID = $0 }
    }
}

/// A sample of the terminal: text in the theme's colours and the 16 ANSI colours.
private struct ThemePreview: View {
    let appearance: TerminalAppearance

    var body: some View {
        let theme = appearance.theme
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("~/src $ ").foregroundStyle(color(theme.ansi[2]))
                Text("ls --color").foregroundStyle(color(theme.foreground))
                Text(" ")
                Text(" selected ")
                    .foregroundStyle(color(theme.selectionForeground ?? theme.foreground))
                    .background(color(theme.selection))
                Rectangle().fill(color(theme.cursor)).frame(width: 7, height: 14).padding(.leading, 4)
            }
            .font(Font(font))
            HStack(spacing: 3) {
                ForEach(Array(theme.ansi.enumerated()), id: \.offset) { _, ansi in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(ansi))
                        .frame(width: 18, height: 12)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(theme.background), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    private var font: NSFont {
        NSFont(name: appearance.fontName, size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    private func color(_ c: TerminalColor) -> Color {
        Color(.sRGB, red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
    }
}

/// A font in the font popup: a monospaced family's regular face.
struct FontChoice: Identifiable, Hashable {
    let postScriptName: String
    let displayName: String
    var id: String { postScriptName }

    init(postScriptName: String, displayName: String? = nil) {
        self.postScriptName = postScriptName
        self.displayName = displayName ?? NSFont(name: postScriptName, size: 12)?.displayName ?? postScriptName
    }

    /// The regular face of every installed fixed-pitch family, SF Mono first
    /// when it is installed as a regular font.
    @MainActor
    static func monospacedFamilies(fontManager: NSFontManager = .shared) -> [FontChoice] {
        var choices: [FontChoice] = []
        for family in fontManager.availableFontFamilies {
            guard let members = fontManager.availableMembers(ofFontFamily: family) else { continue }
            // Each member is [PostScript name, face name, weight, traits].
            let faces = members.compactMap { member -> (name: String, face: String, traits: UInt)? in
                guard member.count >= 4, let name = member[0] as? String, let face = member[1] as? String else { return nil }
                return (name, face, (member[3] as? NSNumber)?.uintValue ?? 0)
            }
            let upright = faces.filter {
                NSFontTraitMask(rawValue: $0.traits).isDisjoint(with: [.boldFontMask, .italicFontMask])
            }
            guard let regular = upright.first(where: { $0.face == "Regular" }) ?? upright.first ?? faces.first,
                  let font = NSFont(name: regular.name, size: 12), font.isFixedPitch
            else { continue }
            choices.append(FontChoice(postScriptName: regular.name, displayName: family))
        }
        if !choices.contains(where: { $0.postScriptName == "SFMono-Regular" }), NSFont(name: "SFMono-Regular", size: 12) != nil {
            choices.insert(FontChoice(postScriptName: "SFMono-Regular", displayName: "SF Mono"), at: 0)
        }
        return choices
    }
}

/// Connects the system font panel to the terminal font: while the panel is
/// shown for Settings, its changes arrive here.
@MainActor
final class FontPanelBridge: NSObject, NSFontChanging {
    private var current: NSFont?
    private var onChange: ((NSFont) -> Void)?

    func show(current: NSFont, onChange: @escaping (NSFont) -> Void) {
        self.current = current
        self.onChange = onChange
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(current, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    /// Stops receiving font panel changes (the Settings tab went away).
    func detach() {
        if NSFontManager.shared.target === self { NSFontManager.shared.target = nil }
        onChange = nil
    }

    func changeFont(_ sender: NSFontManager?) {
        guard let sender, let current else { return }
        let font = sender.convert(current)
        self.current = font
        onChange?(font)
    }

    func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.collection, .face, .size]
    }
}
