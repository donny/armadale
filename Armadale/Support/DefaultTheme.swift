import AppKit
import TerminalSurface

/// The terminal appearance used until Settings exists (step 5): a light and
/// a dark theme that follow the system appearance, in SF Mono 12 when it is
/// installed and Menlo 12 otherwise.
enum DefaultTheme {
    static let light = TerminalTheme(
        name: "Armadale Light",
        ansi: [
            0x1D1F21, 0xC82829, 0x718C00, 0xB07D00, 0x4271AE, 0x8959A8, 0x3E999F, 0xA6A6A6,
            0x5C5F66, 0xE0464A, 0x82A000, 0xD69E00, 0x5B8BD0, 0xA270C4, 0x47B0B7, 0xD9D9D9,
        ].map(TerminalColor.init(hex:)),
        foreground: TerminalColor(hex: 0x24292F),
        background: TerminalColor(hex: 0xFFFFFF),
        cursor: TerminalColor(hex: 0x24292F),
        selection: TerminalColor(hex: 0xB4D5FE))

    static let dark = TerminalTheme(
        name: "Armadale Dark",
        ansi: [
            0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
            0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA,
        ].map(TerminalColor.init(hex:)),
        foreground: TerminalColor(hex: 0xC5C8C6),
        background: TerminalColor(hex: 0x1D1F21),
        cursor: TerminalColor(hex: 0xC5C8C6),
        selection: TerminalColor(hex: 0x373B41))

    /// SF Mono is not installed as a regular font on every Mac.
    static let fontName = NSFont(name: "SFMono-Regular", size: 12) != nil ? "SFMono-Regular" : "Menlo"

    @MainActor
    static func appearance(for appearance: NSAppearance) -> TerminalAppearance {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return TerminalAppearance(fontName: fontName, fontSize: 12, theme: isDark ? dark : light)
    }
}
