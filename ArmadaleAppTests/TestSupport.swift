import AppKit
import ArmadaleCore
import ArmadaleSessions
import SwiftTermSurface
import TerminalSurface

/// The real SwiftTerm surface, recording every grid size it reports (the
/// sizes a pane's program would be sent as PTY resizes).
@MainActor
final class CountingSurface: TerminalSurface, TerminalSurfaceDelegate {
    let inner = SwiftTermSurface()
    weak var delegate: (any TerminalSurfaceDelegate)?
    private(set) var sizes: [GridSize] = []

    init() {
        inner.delegate = self
    }

    func resetLog() { sizes.removeAll() }

    var view: NSView { inner.view }
    var gridSize: GridSize { inner.gridSize }
    func feed(_ bytes: ArraySlice<UInt8>) { inner.feed(bytes) }
    func apply(_ appearance: TerminalAppearance) { inner.apply(appearance) }
    func clearScrollback() { inner.clearScrollback() }
    func scrollToBottom() { inner.scrollToBottom() }
    func find(_ query: String, direction: FindDirection) { inner.find(query, direction: direction) }
    var selectedText: String? { inner.selectedText }

    func surface(_ surface: any TerminalSurface, didInput bytes: [UInt8]) {
        delegate?.surface(self, didInput: bytes)
    }

    func surface(_ surface: any TerminalSurface, didResize size: GridSize) {
        sizes.append(size)
        delegate?.surface(self, didResize: size)
    }

    func surface(_ surface: any TerminalSurface, didSetTitle title: String) {
        delegate?.surface(self, didSetTitle: title)
    }

    func surface(_ surface: any TerminalSurface, didChangeDirectory url: URL) {
        delegate?.surface(self, didChangeDirectory: url)
    }

    func surfaceDidRingBell(_ surface: any TerminalSurface) {
        delegate?.surfaceDidRingBell(self)
    }

    func surface(_ surface: any TerminalSurface, didRequestClipboard op: ClipboardOp) {
        delegate?.surface(self, didRequestClipboard: op)
    }

    func surface(_ surface: any TerminalSurface, didReceiveNotification title: String, body: String) {
        delegate?.surface(self, didReceiveNotification: title, body: body)
    }

    func surface(_ surface: any TerminalSurface, didActivateLink link: String) {
        delegate?.surface(self, didActivateLink: link)
    }
}

/// A real ``PaneView`` over a never-started session, with a counting surface.
@MainActor
func makeCountingPane() -> (PaneView, CountingSurface) {
    let session = Session(profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "/")
    var surface: CountingSurface?
    let controller = SessionController(session: session, backend: EphemeralBackend(), makeSurface: {
        let made = CountingSurface()
        surface = made
        return made
    })
    // `makeSurface` runs synchronously in the initializer.
    return (PaneView(controller: controller), surface ?? CountingSurface())
}
