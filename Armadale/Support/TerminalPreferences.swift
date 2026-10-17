import AppKit
import Observation
import TerminalSurface

/// Terminal settings that apply to every pane. In memory only until
/// Settings exists (step 5): ⌘= / ⌘- / ⌘0 change the font size of all
/// panes for this run.
@MainActor
@Observable
final class TerminalPreferences {
    static let shared = TerminalPreferences()

    static let defaultFontSize: Double = 12
    static let fontSizeRange: ClosedRange<Double> = 6...48

    private(set) var fontSize: Double = TerminalPreferences.defaultFontSize

    func increaseFontSize() { setFontSize(fontSize + 1) }
    func decreaseFontSize() { setFontSize(fontSize - 1) }
    func resetFontSize() { setFontSize(Self.defaultFontSize) }

    var canIncreaseFontSize: Bool { fontSize < Self.fontSizeRange.upperBound }
    var canDecreaseFontSize: Bool { fontSize > Self.fontSizeRange.lowerBound }

    private func setFontSize(_ size: Double) {
        fontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    /// The appearance for a pane shown in `appearance` (light or dark).
    func terminalAppearance(for appearance: NSAppearance) -> TerminalAppearance {
        DefaultTheme.appearance(for: appearance, fontSize: fontSize)
    }
}
