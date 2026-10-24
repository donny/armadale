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
}
