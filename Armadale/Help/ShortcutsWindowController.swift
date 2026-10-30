import AppKit
import SwiftUI

/// Help › Keyboard Shortcuts: one window with the read-only table of key
/// equivalents, generated from the menu bar (``ShortcutTable``). It is
/// reference, not configuration, which is why it lives under Help and not
/// in Settings (moved on October 29, 2026). The app keeps a single
/// instance; it is ordered out in menu bar mode like Settings.
@MainActor
final class ShortcutsWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    static let title = "Keyboard Shortcuts"
    static let contentSize = NSSize(width: 620, height: 560)

    /// Called when the window closes (in menu bar mode the app delegate
    /// then gives up being the active app).
    var onClose: (() -> Void)?

    init(rows: [ShortcutTable.Row]) {
        let hosting = NSHostingController(rootView: ShortcutsView(rows: rows))
        hosting.sizingOptions = []
        hosting.view.frame.size = Self.contentSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.contentViewController = hosting
        window.title = Self.title
        window.contentMinSize = NSSize(width: 460, height: 320)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("shortcuts")
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// ⌘W is bound to File › Close Pane, which only workspace windows
    /// handle; here it closes this window, as in Settings.
    @objc func closePane(_ sender: Any?) {
        window?.performClose(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closePane(_:)) {
            menuItem.title = "Close \(Self.title)"
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// The table itself: command, shortcut and menu, with a note that every
/// command is also in the menu bar.
struct ShortcutsView: View {
    let rows: [ShortcutTable.Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(rows) {
                TableColumn("Command", value: \.command)
                TableColumn("Shortcut") { row in
                    Text(row.shortcut).monospacedDigit()
                }
                .width(min: 90, ideal: 130)
                TableColumn("Menu", value: \.menu)
                    .width(min: 70, ideal: 90)
            }
            Text("Armadale’s own shortcuts; every command is also in the menu bar. Shortcuts can’t be changed in Armadale yet. Other keys go to the terminal, apart from system shortcuts such as window tiling.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}
