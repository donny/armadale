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
        #expect(SwiftTermSurface.notification(from: 9, payload: Array("4;1;50".utf8)) == nil)
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
}
