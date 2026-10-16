import Foundation
import Testing
import TerminalSurface

@Suite("TerminalAppearance")
struct TerminalAppearanceTests {
    @Test func themeAlwaysHasSixteenANSIColors() {
        let short = TerminalTheme(
            name: "t", ansi: [TerminalColor(hex: 0x010203)],
            foreground: .init(hex: 0), background: .init(hex: 0), cursor: .init(hex: 0), selection: .init(hex: 0))
        #expect(short.ansi.count == 16)
        #expect(short.ansi[0] == TerminalColor(red: 1, green: 2, blue: 3))
        #expect(TerminalTheme.default.ansi.count == 16)
    }

    @Test func hexColorDescription() {
        #expect(TerminalColor(hex: 0x0A0B0C).description == "#0a0b0c")
    }

    @Test func appearanceRoundTrips() throws {
        let appearance = TerminalAppearance(fontName: "Menlo", fontSize: 14, cursor: TerminalCursorStyle(shape: .bar, blinks: false))
        let data = try JSONEncoder().encode(appearance)
        #expect(try JSONDecoder().decode(TerminalAppearance.self, from: data) == appearance)
    }
}
