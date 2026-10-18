import Foundation
import Testing
import TerminalSurface

@Suite("Ghostty theme parser")
struct GhosttyThemeTests {
    /// A theme as Ghostty ships them, plus comments, blank lines, quoting,
    /// spacing variants, keys Armadale does not use, and bad lines.
    private let sample = """
        # Dracula-ish, for tests
        # palette entries 0-15

        palette = 0=#21222c
        palette = 1=#ff5555
        palette=2=#50FA7B
        palette = 3 = #f1fa8c
        palette = 4=bd93f9
        palette = 5=#ff79c6
        palette = 6=#8be9fd
        palette = 7=#f8f8f2
        palette = 8=#6272a4
        palette = 9=#ff6e6e
        palette = 10=#69ff94
        palette = 11=#ffffa5
        palette = 12=#d6acff
        palette = 13=#ff92df
        palette = 14=#a4ffff
        palette = 15=#ffffff
        palette = 200=#123456
        background = #282a36
        foreground = "#f8f8f2"
        cursor-color = #f8f8f2
        cursor-text = #282a36
        selection-background = #44475a
        selection-foreground = #fff
        this line is nonsense
        palette = 300=#000000
        palette = x=#000000
        background = blurple
        = #ffffff
        """

    @Test func parsesColoursCommentsAndReportsBadLines() throws {
        let result = try GhosttyTheme.parse(sample, name: "Sample")
        let theme = result.theme
        #expect(theme.name == "Sample")
        #expect(theme.ansi.count == 16)
        #expect(theme.ansi[0] == TerminalColor(hex: 0x21222C))
        #expect(theme.ansi[2] == TerminalColor(hex: 0x50FA7B), "upper-case hex, no spaces")
        #expect(theme.ansi[3] == TerminalColor(hex: 0xF1FA8C), "spaces around the inner =")
        #expect(theme.ansi[4] == TerminalColor(hex: 0xBD93F9), "no #")
        #expect(theme.ansi[15] == TerminalColor(hex: 0xFFFFFF))
        #expect(theme.background == TerminalColor(hex: 0x282A36), "a bad later value keeps the good one")
        #expect(theme.foreground == TerminalColor(hex: 0xF8F8F2), "quoted value")
        #expect(theme.cursor == TerminalColor(hex: 0xF8F8F2))
        #expect(theme.selection == TerminalColor(hex: 0x44475A))
        #expect(theme.selectionForeground == TerminalColor(hex: 0xFFFFFF), "#rgb shorthand")
        #expect(result.ignoredKeys == ["cursor-text"])
        #expect(result.warnings.count == 5, "\(result.warnings)")
        #expect(result.warnings.contains { $0.hasPrefix("line 27:") }, "nonsense line")
        #expect(result.warnings.contains { $0.hasPrefix("line 28:") }, "palette index out of range")
        #expect(result.warnings.contains { $0.hasPrefix("line 29:") }, "palette index not a number")
        #expect(result.warnings.contains { $0.hasPrefix("line 30:") && $0.contains("blurple") }, "unknown colour name")
        #expect(result.warnings.contains { $0.hasPrefix("line 31:") }, "missing key")
    }

    @Test func missingColoursAreDerived() throws {
        let result = try GhosttyTheme.parse("background = #000000\nforeground = #ffffff\n", name: "Mono")
        let theme = result.theme
        #expect(theme.cursor == theme.foreground)
        #expect(theme.selection == TerminalColor(hex: 0x4D4D4D))
        #expect(theme.selectionForeground == nil)
        #expect(theme.ansi == TerminalTheme.defaultANSI)
        #expect(result.warnings.isEmpty)
    }

    @Test func crlfLineEndingsAreAccepted() throws {
        let theme = try GhosttyTheme.parse("background = #102030\r\npalette = 1=#aabbcc\r\n", name: "x").theme
        #expect(theme.background == TerminalColor(hex: 0x102030))
        #expect(theme.ansi[1] == TerminalColor(hex: 0xAABBCC))
    }

    @Test func aFileWithoutColoursIsRejectedWithItsWarnings() {
        #expect(throws: GhosttyTheme.ParseError.noColors(warnings: [])) {
            try GhosttyTheme.parse("# only a comment\nfont-size = 13\n", name: "x")
        }
        #expect(throws: GhosttyTheme.ParseError.noColors(warnings: [])) {
            try GhosttyTheme.parse("", name: "x")
        }
        do {
            _ = try GhosttyTheme.parse("background: #000000\nforeground = beige\n", name: "x")
            Issue.record("expected a rejection")
        } catch {
            guard case .noColors(let warnings) = error else { return }
            #expect(warnings.count == 2, "\(warnings)")
            #expect(warnings.first?.hasPrefix("line 1:") == true)
            #expect(error.description.contains("beige"), "the reason is shown to the user")
        }
    }

    @Test func basicColourNamesMeanTheDefaultPalette() throws {
        #expect(GhosttyTheme.paletteIndex(forColorName: "Black") == 0)
        #expect(GhosttyTheme.paletteIndex(forColorName: "white") == 7)
        #expect(GhosttyTheme.paletteIndex(forColorName: "bright red") == 9)
        #expect(GhosttyTheme.paletteIndex(forColorName: "light-cyan") == 14)
        #expect(GhosttyTheme.paletteIndex(forColorName: "BrightWhite") == 15)
        #expect(GhosttyTheme.paletteIndex(forColorName: "grey") == 8)
        #expect(GhosttyTheme.paletteIndex(forColorName: "gray") == 8)
        #expect(GhosttyTheme.paletteIndex(forColorName: "lightgray") == 7)
        #expect(GhosttyTheme.paletteIndex(forColorName: "beige") == nil)

        let dark = try GhosttyTheme.parse("background = black\nforeground = bright white\npalette = 1=bright red\n", name: "n")
        #expect(dark.warnings.isEmpty)
        #expect(dark.theme.background == TerminalTheme.defaultANSI[0])
        #expect(dark.theme.foreground == TerminalTheme.defaultANSI[15])
        #expect(dark.theme.ansi[1] == TerminalTheme.defaultANSI[9])
    }

    @Test func aLightBackgroundWithoutPaletteGetsTheLightDefaults() throws {
        let light = try GhosttyTheme.parse("background = #fdfdfd\nforeground = #222222\npalette = 4=blue\n", name: "l").theme
        #expect(Array(light.ansi[0..<4]) == Array(TerminalTheme.defaultLightANSI[0..<4]))
        #expect(light.ansi[4] == TerminalTheme.defaultLightANSI[4], "names follow the chosen palette")
        let dark = try GhosttyTheme.parse("background = #101010\n", name: "d").theme
        #expect(dark.ansi == TerminalTheme.defaultANSI)
    }

    @Test func hexStrings() {
        #expect(TerminalColor(hexString: "#0a0B0c") == TerminalColor(hex: 0x0A0B0C))
        #expect(TerminalColor(hexString: "abc") == TerminalColor(hex: 0xAABBCC))
        #expect(TerminalColor(hexString: "#12345") == nil)
        #expect(TerminalColor(hexString: "#gggggg") == nil)
        #expect(TerminalColor(hexString: "+12345") == nil)
    }

    @Test func themesWithoutSelectionForegroundStillDecode() throws {
        let json = #"{"name":"t","ansi":[],"foreground":{"red":1,"green":2,"blue":3},"#
            + #""background":{"red":0,"green":0,"blue":0},"cursor":{"red":1,"green":2,"blue":3},"#
            + #""selection":{"red":9,"green":9,"blue":9}}"#
        let theme = try JSONDecoder().decode(TerminalTheme.self, from: Data(json.utf8))
        #expect(theme.selectionForeground == nil)
        #expect(theme.ansi.count == 16)
    }
}
