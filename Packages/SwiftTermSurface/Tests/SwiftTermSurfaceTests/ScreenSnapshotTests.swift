import AppKit
import Testing
import TerminalSurface
@testable import SwiftTermSurface

/// Collects what a surface sends towards the program.
@MainActor
private final class InputLog: TerminalSurfaceDelegate {
    var input: [UInt8] = []
    func surface(_ surface: any TerminalSurface, didInput bytes: [UInt8]) { input += bytes }
    func surface(_ surface: any TerminalSurface, didResize size: GridSize) {}
    func surface(_ surface: any TerminalSurface, didSetTitle title: String) {}
    func surface(_ surface: any TerminalSurface, didChangeDirectory url: URL) {}
    func surfaceDidRingBell(_ surface: any TerminalSurface) {}
    func surface(_ surface: any TerminalSurface, didRequestClipboard op: ClipboardOp) {}
    func surface(_ surface: any TerminalSurface, didReceiveNotification title: String, body: String) {}
    func surface(_ surface: any TerminalSurface, didActivateLink link: String) {}
}

/// ``SwiftTermSurface/screenSnapshot()`` (DESIGN §5): fed to a fresh
/// surface of the same size, the snapshot gives the same screen, cell by
/// cell (text, width, colours and attributes), the same cursor, alternate
/// screen, scroll region, pen and modes.
@Suite("SwiftTermSurface screen snapshot")
@MainActor
struct ScreenSnapshotTests {
    private func surface(columns: Int = 40, rows: Int = 12) -> SwiftTermSurface {
        let surface = SwiftTermSurface(appearance: TerminalAppearance(fontName: "Menlo", fontSize: 12))
        surface.setGridSize(columns: columns, rows: rows)
        return surface
    }

    private func feed(_ surface: SwiftTermSurface, _ text: String) {
        surface.feed(Array(text.utf8)[...])
    }

    /// Snapshots `original`, feeds it to a fresh surface of its size and
    /// compares the two screens.
    @discardableResult
    private func roundTrip(
        _ original: SwiftTermSurface, then more: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> SwiftTermSurface {
        let log = InputLog()
        original.delegate = log
        let snapshot = original.screenSnapshot()
        // An answer sent late would come on a later turn of the main queue.
        try await Task.sleep(for: .milliseconds(50))
        await MainActor.run {}
        #expect(log.input.isEmpty, "the terminal's answers never reach the program", sourceLocation: sourceLocation)
        let copy = surface(columns: original.gridSize.columns, rows: original.gridSize.rows)
        copy.feed(snapshot[...])
        if let more {
            // What the program writes next lands in the same place.
            feed(original, more)
            feed(copy, more)
        }
        let before = try #require(original.screenState(), sourceLocation: sourceLocation)
        let after = try #require(copy.screenState(), sourceLocation: sourceLocation)
        let differences = before.differences(from: after)
        #expect(differences.isEmpty, "\(differences.prefix(12))", sourceLocation: sourceLocation)
        #expect(before == after, sourceLocation: sourceLocation)
        return copy
    }

    @Test func colorsAttributesWideCharactersAndTheCursor() async throws {
        let original = surface()
        feed(original, "\u{1b}[1;31mbold red\u{1b}[0m plain \u{1b}[38;2;10;20;30;48;5;200mtrue\u{1b}[0m\r\n")
        feed(original, "\u{1b}[3;4:3;58;5;9mitalic curly\u{1b}[0m \u{1b}[2;9mdim strike\u{1b}[0m \u{1b}[7;5;8minv\u{1b}[0m\r\n")
        feed(original, "\u{1b}[4m\u{1b}[94;103mbright\u{1b}[0m \u{1b}[21mdouble\u{1b}[0m\r\n")
        feed(original, "漢字 👍 e\u{301} 🇯🇵 ❤️ x\r\n")
        feed(original, "\u{1b}[44m\u{1b}[Kblue line\u{1b}[0m\r\n")
        feed(original, "\u{1b}[7;30Hfar right\u{1b}[9;3Hgap   \u{1b}[45m \u{1b}[0m end")
        // A pen with nothing written in it yet, the cursor away from home,
        // the cursor hidden.
        feed(original, "\u{1b}[10;17H\u{1b}[1;3;32;48;2;1;2;3m\u{1b}[?25l")
        let state = try #require(original.screenState())
        #expect(state.cursorColumn == 16 && state.cursorRow == 9)
        #expect(!state.modes.cursorVisible)
        #expect(state.cells[3].map(\.width).contains(2), "wide characters on row 4")
        try await roundTrip(original)
    }

    @Test func theAlternateScreenWithARegionOriginModeAndNoWraparound() async throws {
        let original = surface()
        feed(original, "primary screen\r\n")
        feed(original, "\u{1b}[?1049h\u{1b}[H\u{1b}[2J\u{1b}[1;1H\u{1b}[36mstatus\u{1b}[0m\u{1b}[12;1H> prompt")
        feed(original, "\u{1b}[3;10r\u{1b}[?6h\u{1b}[?7l\u{1b}[2;5H\u{1b}[33m")
        let state = try #require(original.screenState())
        #expect(state.isAlternate)
        #expect(state.scrollTop == 2 && state.scrollBottom == 9)
        #expect(state.modes.originMode && !state.modes.wraparound)
        try await roundTrip(original)
    }

    @Test func thePrimaryScreenAtAShellPrompt() async throws {
        let original = surface(columns: 80, rows: 24)
        for index in 0..<40 { feed(original, "line \(index) \u{1b}[32mok\u{1b}[0m\r\n") }
        feed(original, "~/src $ ")
        try await roundTrip(original)
    }

    /// A cursor waiting to wrap after the last column (a row drawn to the
    /// full width, as agent interfaces draw them) stays waiting: what the
    /// program writes next lands on the next row in both. With a wide
    /// character and a combining mark in the last column too.
    @Test(arguments: ["\u{1b}[34m" + String(repeating: "─", count: 40), String(repeating: "x", count: 38) + "漢",
                      String(repeating: "y", count: 39) + "e\u{301}"])
    func aCursorWaitingToWrapStaysWaiting(row: String) async throws {
        let original = surface()
        feed(original, "top\r\n" + row)
        let state = try #require(original.screenState())
        #expect(state.cursorColumn == 40, "waiting to wrap")
        try await roundTrip(original, then: "\u{1b}[0mnext line")
    }

    /// Reverse video and a saved cursor (DECSC) come through.
    @Test func reverseVideoAndTheSavedCursor() async throws {
        let original = surface()
        feed(original, "\u{1b}[5;7H\u{1b}[1;35m\u{1b}7\u{1b}[0m\u{1b}[?5hscreen\u{1b}[2;2H")
        let state = try #require(original.screenState())
        #expect(state.modes.reverseVideo)
        #expect(state.savedColumn == 6 && state.savedRow == 4)
        let copy = try await roundTrip(original, then: "\u{1b}8restored")
        #expect(try #require(copy.screenState()).cells[4].prefix(14).map(\.text).joined() == "      restored")
    }

    /// Scrolled back, the snapshot is still the live screen (the view goes
    /// to the bottom first), never the scrollback on view.
    @Test func aViewScrolledBackGivesTheLiveScreen() throws {
        let original = surface()
        for index in 0..<100 { feed(original, "row \(index)\r\n") }
        feed(original, "live")
        original.scrollToTop()
        #expect(try #require(original.screenState()).cells[0].prefix(5).map(\.text).joined() == "row 0", "scrolled back")
        let copy = surface()
        copy.feed(original.screenSnapshot()[...])
        let live = try #require(copy.screenState())
        #expect(live.cells[11].prefix(4).map(\.text).joined() == "live")
        #expect(live.cells[0].prefix(6).map(\.text).joined() == "row 89")
        #expect(try #require(original.screenState()) == live, "and the view is at the bottom again")
    }

    /// The modes the snapshot asks for are read from the terminal's
    /// answers; anything else in them is ignored.
    @Test func modeAnswersAreParsed() {
        let answers = Array("\u{1b}[?25;2$y\u{1b}[?6;1$y\u{1b}[?7;4$y\u{1b}[?5;3$y\u{1b}[?1;1$y\u{1b}[?99;0$y".utf8)
        let modes = SnapshotModes(answers: answers)
        #expect(!modes.cursorVisible && modes.originMode && !modes.wraparound && modes.reverseVideo)
        #expect(SnapshotModes(answers: []) == SnapshotModes())
    }
}
