import AppKit
import ArmadaleCore
import ArmadaleSessions
import Foundation
import Testing

/// Return on a pane showing the *Session Ended* placeholder presses its
/// primary button (DESIGN §4, "Ended"): the pane, not its dead terminal,
/// holds keyboard focus while the placeholder is up. The window is never
/// ordered on screen and no process is started.
@Suite("Placeholder keyboard")
@MainActor
struct PlaceholderKeyboardTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<60 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func key(_ keyCode: UInt16, _ characters: String, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: keyCode))
    }

    @Test func returnPressesRespawnOnlyInAFocusedPane() async throws {
        _ = NSApplication.shared
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        model.fillEmptyPanes()
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: [],
            settings: settings)
        let session = try #require(model.sessionIDs(in: workspace).first)
        let pane = try #require(registry.paneView(for: session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.contentView = content
        content.addSubview(pane)

        #expect(!pane.acceptsFirstResponder, "a live terminal keeps keyboard focus")
        pane.focusTerminal()
        #expect(window.firstResponder === pane.controller.surface.view)

        // The program dies: the pane takes keyboard focus from its terminal.
        pane.controller.markEnded(exitCode: .signaled(9))
        #expect(await eventually { window.firstResponder === pane })
        #expect(pane.containsFirstResponder)

        // Another pane of the split is the focused one: Return does nothing.
        pane.focusStyle = .unfocused
        pane.keyDown(with: try key(36, "\r", in: window))
        // Other keys never press anything.
        pane.focusStyle = .focused
        pane.keyDown(with: try key(53, "\u{1b}", in: window))
        pane.keyDown(with: try key(0, "a", in: window))
        try await Task.sleep(for: .milliseconds(150))
        #expect(pane.controller.session.id == session, "not respawned")

        // A click elsewhere took focus; focusing the pane targets the pane.
        window.makeFirstResponder(nil)
        pane.focusTerminal()
        #expect(window.firstResponder === pane)

        // Return in the focused pane respawns it (a new session in the model).
        pane.keyDown(with: try key(36, "\r", in: window))
        #expect(await eventually { pane.controller.session.id != session }, "respawned")
        #expect(model.session(session) == nil)
        #expect(model.session(pane.controller.session.id) != nil)
    }

    /// The dead terminal's cursor is hidden while a placeholder is up, also
    /// after an appearance change (SwiftTerm resets the modes when its font
    /// is set), and shown again once the terminal is live (DESIGN §8,
    /// "Session Ended"). The terminal is asked for mode 25 (DECRQM), since
    /// SwiftTerm keeps the state internal.
    @Test func theCursorIsHiddenUnderAPlaceholderAndShownWhenLive() async throws {
        _ = NSApplication.shared
        let (pane, surface) = makeCountingPane()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane

        func cursorShown() async throws -> Bool {
            surface.inputs = []
            surface.feed(Array("\u{1b}[?25$p".utf8)[...])
            for _ in 0..<50 where surface.inputs.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            let reply = String(decoding: surface.inputs, as: UTF8.self)
            try #require(reply == "\u{1b}[?25;1$y" || reply == "\u{1b}[?25;2$y", "a DECRQM reply")
            return reply == "\u{1b}[?25;1$y"
        }
        #expect(try await cursorShown(), "a live terminal shows its cursor")

        pane.controller.markUnavailable(reason: "test")
        #expect(await eventually { pane.acceptsFirstResponder }, "the placeholder is up")
        #expect(try await !cursorShown(), "hidden under the placeholder")
        pane.viewDidChangeEffectiveAppearance()
        #expect(try await !cursorShown(), "still hidden after the appearance is applied again")

        pane.controller.useBackend(InertBackend(), makeOutputFilter: { IdentityOutputFilter() })
        #expect(await eventually { !pane.acceptsFirstResponder }, "the placeholder is gone")
        #expect(try await cursorShown(), "shown again: the terminal is live")
    }

    /// Asks the terminal for DEC private mode `number` (DECRQM): `true` when
    /// set, `false` when reset.
    private func mode(_ number: Int, of surface: CountingSurface) async throws -> Bool {
        surface.inputs = []
        surface.feed(Array("\u{1b}[?\(number)$p".utf8)[...])
        for _ in 0..<50 where surface.inputs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reply = String(decoding: surface.inputs, as: UTF8.self)
        try #require(reply == "\u{1b}[?\(number);1$y" || reply == "\u{1b}[?\(number);2$y", "a DECRQM reply")
        return reply == "\u{1b}[?\(number);1$y"
    }

    /// A pane entering a window again (a split, a tab switch, a zoom)
    /// leaves its surface alone when the appearance is the same, so the
    /// program's modes survive; a theme change applies, still without a
    /// reset (DESIGN §8, "Pane context menu").
    @Test func reenteringAWindowKeepsTheProgramsModes() async throws {
        _ = NSApplication.shared
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        settings.preferences.followsSystemAppearance = false
        settings.preferences.themeID = "builtin.nord"
        let (pane, surface) = makeCountingPane(settings: settings)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.contentView = holder
        holder.addSubview(pane)
        surface.feed(Array("\u{1b}[?1h\u{1b}[?25l".utf8)[...])
        #expect(try await mode(1, of: surface))
        let applied = surface.applied.count

        pane.removeFromSuperview()
        holder.addSubview(pane)
        #expect(surface.applied.count == applied, "the same appearance is not applied again")
        #expect(try await mode(1, of: surface), "application cursor keys survive")
        #expect(try await !mode(25, of: surface), "the hidden cursor stays hidden")

        settings.preferences.themeID = "builtin.dracula"
        #expect(await eventually { surface.applied.last?.theme.name == "Dracula" })
        #expect(try await mode(1, of: surface), "a theme change keeps them")
    }

    /// A font size change (⌘=) soft-resets SwiftTerm, which shows the
    /// cursor: under a placeholder the pane hides it again after the font
    /// is applied.
    @Test func aFontSizeChangeKeepsTheCursorHiddenUnderAPlaceholder() async throws {
        _ = NSApplication.shared
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let (pane, surface) = makeCountingPane(settings: settings)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        pane.controller.markEnded(exitCode: .signaled(9))
        #expect(await eventually { pane.acceptsFirstResponder }, "the placeholder is up")
        #expect(try await !mode(25, of: surface))

        let size = settings.preferences.fontSize
        settings.preferences.fontSize = size + 2
        #expect(await eventually { surface.applied.last?.fontSize == size + 2 }, "the new size is applied")
        #expect(try await !mode(25, of: surface), "still hidden")
    }
}
