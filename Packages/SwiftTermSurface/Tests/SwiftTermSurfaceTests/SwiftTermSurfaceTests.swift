import AppKit
import Testing
import TerminalSurface
@testable import SwiftTermSurface

@MainActor
private final class RecordingDelegate: TerminalSurfaceDelegate {
    var titles: [String] = []
    var bells = 0
    var directories: [URL] = []

    func surface(_ surface: any TerminalSurface, didInput bytes: [UInt8]) {}
    func surface(_ surface: any TerminalSurface, didResize size: GridSize) {}
    func surface(_ surface: any TerminalSurface, didSetTitle title: String) { titles.append(title) }
    func surface(_ surface: any TerminalSurface, didChangeDirectory url: URL) { directories.append(url) }
    func surfaceDidRingBell(_ surface: any TerminalSurface) { bells += 1 }
    func surface(_ surface: any TerminalSurface, didRequestClipboard op: ClipboardOp) {}
    func surface(_ surface: any TerminalSurface, didReceiveNotification title: String, body: String) {}
    var links: [String] = []
    func surface(_ surface: any TerminalSurface, didActivateLink link: String) { links.append(link) }
}

@Suite("SwiftTermSurface")
@MainActor
struct SwiftTermSurfaceTests {
    @Test func notificationParsing() {
        #expect(SwiftTermSurface.notification(from: 9, payload: Array("done".utf8))! == ("", "done"))
        #expect(SwiftTermSurface.notification(from: 9, payload: Array("4;1;50".utf8)) == nil, "ConEmu progress")
        #expect(SwiftTermSurface.notification(from: 9, payload: Array("9;/Users/me/repo".utf8)) == nil, "ConEmu cwd")
        #expect(SwiftTermSurface.notification(from: 9, payload: Array("1;500".utf8)) == nil, "ConEmu sleep")
        #expect(SwiftTermSurface.notification(from: 9, payload: Array("12".utf8)) == nil, "ConEmu prompt mark")
        #expect(SwiftTermSurface.notification(from: 9, payload: []) == nil)
        #expect(SwiftTermSurface.notification(from: 9, payload: Array("3 tests failed; see log".utf8))! == ("", "3 tests failed; see log"))
        #expect(SwiftTermSurface.notification(from: 9, payload: Array("Claude Code: Done".utf8))! == ("", "Claude Code: Done"))
        #expect(SwiftTermSurface.notification(from: 777, payload: Array("notify;Build;ok;really".utf8))! == ("Build", "ok;really"))
        #expect(SwiftTermSurface.notification(from: 777, payload: Array("other;x".utf8)) == nil)
        #expect(SwiftTermSurface.notification(from: 2, payload: []) == nil)
    }

    @Test func directoryParsing() {
        #expect(SwiftTermSurface.directoryURL("file://mac.local/Users/me")?.path == "/Users/me")
        #expect(SwiftTermSurface.directoryURL("/tmp")?.path == "/tmp")
        #expect(SwiftTermSurface.directoryURL("relative") == nil)
    }

    @Test func feedingTitleAndBellReachesDelegate() async throws {
        let surface = SwiftTermSurface()
        let delegate = RecordingDelegate()
        surface.delegate = delegate
        surface.apply(TerminalAppearance(fontName: "Menlo", fontSize: 12))
        surface.feed(Array("\u{1b}]2;hello\u{07}\u{07}text".utf8)[...])
        // SwiftTerm may deliver delegate callbacks asynchronously on the main actor.
        for _ in 0..<50 where delegate.titles.isEmpty || delegate.bells == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(delegate.titles == ["hello"])
        #expect(delegate.bells == 1)
        #expect(surface.gridSize.columns > 0)
        #expect(surface.gridSize.cellWidth > 0)
    }

    @Test func cellSizeIsSwiftTermsUnroundedCellAndFitsTheView() throws {
        let surface = SwiftTermSurface(appearance: TerminalAppearance(fontName: "Menlo", fontSize: 12))
        surface.view.setFrameSize(NSSize(width: 800, height: 500))
        let size = surface.gridSize
        let bounds = surface.view.bounds
        #expect(size.columns > 0 && size.rows > 0)
        #expect(Double(size.columns) * size.cellWidth <= Double(bounds.width))
        #expect(Double(size.rows) * size.cellHeight <= Double(bounds.height))

        // Menlo 12 advances 7.2246 pt per glyph; SwiftTerm snaps that to the
        // backing pixel grid. Rounding up to whole points (8) would overstate
        // the pixel size reported to the PTY by ~10%.
        let font = try #require(NSFont(name: "Menlo", size: 12))
        let advance = Double(font.advancement(forGlyph: font.glyph(withName: "W")).width)
        #expect(abs(size.cellWidth - advance) < 0.5)
        #expect(size.cellWidth < 7.75)
        // Every column fits: one more would not.
        #expect(Double(size.columns + 1) * size.cellWidth > Double(bounds.width) - size.cellWidth)
    }

    @Test func linkActivationIsForwardedNotOpened() {
        let surface = SwiftTermSurface()
        let delegate = RecordingDelegate()
        surface.delegate = delegate
        surface.simulateLinkActivation("https://example.com")
        #expect(delegate.links == ["https://example.com"])
    }

    /// The Edit menu's Copy / Paste / Select All are nil-targeted, so they
    /// reach SwiftTerm through the responder chain when the terminal view is
    /// first responder.
    @Test func editMenuActionsReachTheTerminalView() {
        let view = SwiftTermSurface().view
        #expect(view.acceptsFirstResponder)
        #expect(view.responds(to: #selector(NSText.copy(_:))))
        #expect(view.responds(to: #selector(NSText.paste(_:))))
        #expect(view.responds(to: #selector(NSText.selectAll(_:))))
    }

    /// Re-applying the appearance (every tab switch does) keeps the cursor
    /// the program chose; only a changed cursor preference overrides it.
    @Test func reapplyingKeepsTheProgramsCursorStyle() async throws {
        let appearance = TerminalAppearance(fontName: "Menlo", fontSize: 12, cursor: TerminalCursorStyle(shape: .block, blinks: true))
        let surface = SwiftTermSurface(appearance: appearance)
        #expect(surface.cursorStyleParameter == 1)
        surface.feed(Array("\u{1b}[6 q".utf8)[...]) // steady bar, as vim in insert mode
        for _ in 0..<50 where surface.cursorStyleParameter != 6 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(surface.cursorStyleParameter == 6)

        surface.apply(appearance)
        var themed = appearance
        themed.fontSize = 14
        themed.theme.background = TerminalColor(hex: 0x101010)
        surface.apply(themed)
        #expect(surface.cursorStyleParameter == 6, "same cursor preference: the program's choice stays")

        themed.cursor = TerminalCursorStyle(shape: .underline, blinks: false)
        surface.apply(themed)
        #expect(surface.cursorStyleParameter == 4, "a changed preference applies")
    }
}
