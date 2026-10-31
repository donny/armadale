import AppKit
import Testing
import TerminalSurface
@testable import SwiftTermSurface

/// Records what reaches the surface view's superview (the host's pane).
@MainActor
private final class HostView: NSView {
    var rightDowns: [NSEvent] = []
    override func rightMouseDown(with event: NSEvent) { rightDowns.append(event) }
    override func rightMouseUp(with event: NSEvent) {}
}

@MainActor
private final class InputRecorder: TerminalSurfaceDelegate {
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

/// The surface view's mouse rules for the host's context menu (DESIGN §8,
/// "Pane context menu"): a right-click goes to a program that asked for the
/// mouse and otherwise to the host; Shift + right-click always to the host;
/// Control-click is a right-click.
@Suite("Context clicks")
@MainActor
struct ContextClickTests {
    private func make() -> (SwiftTermSurface, HostView, InputRecorder) {
        let surface = SwiftTermSurface()
        let host = HostView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        surface.view.frame = host.bounds
        host.addSubview(surface.view)
        let recorder = InputRecorder()
        surface.delegate = recorder
        return (surface, host, recorder)
    }

    /// A mouse event at a point in the terminal. Right-button events are
    /// made through ``ContextClick/rightButtonEvent(_:from:)``, since
    /// `NSEvent.mouseEvent(with:…)` gives them button number 0 (the left
    /// button), unlike real ones.
    private func event(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let isRight = [.rightMouseDown, .rightMouseUp, .rightMouseDragged].contains(type)
        let base = try #require(NSEvent.mouseEvent(
            with: isRight ? .leftMouseDown : type, location: NSPoint(x: 40, y: 200), modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        return isRight ? try #require(ContextClick.rightButtonEvent(type, from: base)) : base
    }

    /// Lets SwiftTerm's input callbacks, which may hop to the main actor, arrive.
    private func settle() async throws {
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Mouse reporting (X10 button events, SGR encoding), as `vim` with
    /// `mouse=a` or tmux with `mouse on` asks for it.
    private static let mouseOn = Array("\u{1b}[?1000h\u{1b}[?1006h".utf8)[...]

    @Test func rules() {
        #expect(ContextClick.bypassesProgram([.shift]))
        #expect(ContextClick.bypassesProgram([.shift, .control]))
        #expect(!ContextClick.bypassesProgram([]))
        #expect(!ContextClick.bypassesProgram([.control, .option]))
        #expect(ContextClick.isSecondaryClick([.control]))
        #expect(ContextClick.isSecondaryClick([.control, .shift]))
        #expect(ContextClick.isSecondaryClick([.control, .option]))
        #expect(!ContextClick.isSecondaryClick([.control, .command]), "⌘ keeps a left click (links)")
        #expect(!ContextClick.isSecondaryClick([.shift]))
        #expect(!ContextClick.isSecondaryClick(NSEvent.ModifierFlags()))
    }

    @Test func eventsThatAreSecondaryClicks() throws {
        #expect(ContextClick.isSecondaryClick(try event(.leftMouseDown, [.control])))
        #expect(!ContextClick.isSecondaryClick(try event(.leftMouseDown, [.control, .command])))
        #expect(!ContextClick.isSecondaryClick(try event(.leftMouseDown)))
        #expect(!ContextClick.isSecondaryClick(try event(.leftMouseUp, [.control])), "only the press")
        #expect(!ContextClick.isSecondaryClick(try event(.rightMouseDown, [.control])))
        #expect(!ContextClick.isSecondaryClick(nil as NSEvent?))
    }

    /// ⌘+Control-click stays a left click: it never reaches the host as a
    /// right-click, and a program that asked for the mouse gets a left
    /// button.
    @Test func commandControlClickIsStillALeftClick() async throws {
        let (surface, host, recorder) = make()
        surface.view.mouseDown(with: try event(.leftMouseDown, [.control, .command]))
        surface.view.mouseUp(with: try event(.leftMouseUp, [.control, .command]))
        #expect(host.rightDowns.isEmpty)

        surface.feed(Self.mouseOn)
        surface.view.mouseDown(with: try event(.leftMouseDown, [.control, .command]))
        surface.view.mouseUp(with: try event(.leftMouseUp, [.control, .command]))
        #expect(host.rightDowns.isEmpty)
        try await settle()
        // Left button (0) with the Control bit (16).
        #expect(String(decoding: recorder.input, as: UTF8.self).hasPrefix("\u{1b}[<16;"))
    }

    @Test func aControlClickBecomesARightButtonEvent() throws {
        let click = try event(.leftMouseDown, [.control, .shift])
        let right = try #require(ContextClick.rightButtonEvent(.rightMouseDown, from: click))
        #expect(right.type == .rightMouseDown)
        #expect(right.buttonNumber == 1)
        #expect(right.locationInWindow == click.locationInWindow)
        #expect(right.clickCount == 1)
        #expect(!right.modifierFlags.contains(.control))
        #expect(right.modifierFlags.contains(.shift))
        #expect(try #require(ContextClick.rightButtonEvent(.rightMouseUp, from: click)).type == .rightMouseUp)
        #expect(try #require(ContextClick.rightButtonEvent(.rightMouseDragged, from: click)).type == .rightMouseDragged)
        #expect(ContextClick.rightButtonEvent(.leftMouseDown, from: click) == nil)
    }

    @Test func aRightClickGoesToTheHostWhenNoProgramAskedForTheMouse() async throws {
        let (surface, host, recorder) = make()
        surface.view.rightMouseDown(with: try event(.rightMouseDown))
        #expect(host.rightDowns.count == 1)
        try await settle()
        #expect(recorder.input.isEmpty)
    }

    @Test func aRightClickGoesToAProgramThatAskedForTheMouse() async throws {
        let (surface, host, recorder) = make()
        surface.feed(Self.mouseOn)
        surface.view.rightMouseDown(with: try event(.rightMouseDown))
        #expect(host.rightDowns.isEmpty)
        try await settle()
        #expect(String(decoding: recorder.input, as: UTF8.self).hasPrefix("\u{1b}[<2;"), "right button press")
    }

    @Test func shiftRightClickAlwaysGoesToTheHost() async throws {
        let (surface, host, recorder) = make()
        // Mouse reporting, and the program asks to see Shift too (XTSHIFTESCAPE).
        surface.feed(Self.mouseOn)
        surface.feed(Array("\u{1b}[>1s".utf8)[...])
        surface.view.rightMouseDown(with: try event(.rightMouseDown, [.shift]))
        surface.view.rightMouseUp(with: try event(.rightMouseUp, [.shift]))
        #expect(host.rightDowns.count == 1)
        try await settle()
        #expect(recorder.input.isEmpty)
    }

    @Test func controlClickIsARightClick() async throws {
        let (surface, host, recorder) = make()
        surface.view.mouseDown(with: try event(.leftMouseDown, [.control]))
        surface.view.mouseUp(with: try event(.leftMouseUp, [.control]))
        #expect(host.rightDowns.count == 1)
        #expect(host.rightDowns.first?.type == .rightMouseDown)
        #expect(host.rightDowns.first?.modifierFlags.contains(.control) == false)
        try await settle()
        #expect(recorder.input.isEmpty)

        // With mouse reporting, the program gets a right button, pressed and released.
        surface.feed(Self.mouseOn)
        surface.view.mouseDown(with: try event(.leftMouseDown, [.control]))
        surface.view.mouseUp(with: try event(.leftMouseUp, [.control]))
        #expect(host.rightDowns.count == 1)
        try await settle()
        let sent = String(decoding: recorder.input, as: UTF8.self)
        #expect(sent.hasPrefix("\u{1b}[<2;"), "right button press, no Control bit (16)")
        #expect(sent.contains("m"), "and its release")
    }

    @Test func aPlainClickIsStillTheTerminals() async throws {
        let (surface, host, recorder) = make()
        surface.feed(Self.mouseOn)
        surface.view.mouseDown(with: try event(.leftMouseDown))
        surface.view.mouseUp(with: try event(.leftMouseUp))
        #expect(host.rightDowns.isEmpty)
        try await settle()
        #expect(String(decoding: recorder.input, as: UTF8.self).hasPrefix("\u{1b}[<0;"), "left button press")
    }
}
