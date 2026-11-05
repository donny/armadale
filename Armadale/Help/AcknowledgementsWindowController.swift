import AppKit

/// Help › Acknowledgements: one window with the third-party notices the
/// MIT licenses of SwiftTerm and the persistence helper require in every
/// copy of the app (`Contents/Resources/Acknowledgements.txt`, kept in step
/// with THIRD_PARTY_LICENSES.md by ``AcknowledgementsTests``). Read-only,
/// selectable text; the app keeps a single instance, ordered out in menu
/// bar mode like Settings and Keyboard Shortcuts.
@MainActor
final class AcknowledgementsWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    static let title = "Acknowledgements"
    static let contentSize = NSSize(width: 560, height: 520)
    /// The resource's name and extension in the bundle.
    static let resourceName = "Acknowledgements"
    static let resourceExtension = "txt"

    /// Called when the window closes (in menu bar mode the app delegate
    /// then gives up being the active app).
    var onClose: (() -> Void)?

    /// The text view showing the notices.
    let textView: NSTextView

    /// The bundled notices: the app's bundle, or the test bundle when the
    /// app's sources are compiled into it. `nil` if the resource is missing.
    static func bundledText(in bundle: Bundle = Bundle(for: AcknowledgementsWindowController.self)) -> String? {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// `existing`, or a new controller showing the bundled text when there
    /// is none yet: the app delegate keeps one, so asking again brings the
    /// same window forward.
    static func reusing(_ existing: AcknowledgementsWindowController?) -> AcknowledgementsWindowController {
        existing ?? AcknowledgementsWindowController(
            text: bundledText() ?? "The acknowledgements are missing from this copy of Armadale.")
    }

    init(text: String) {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = NSRect(origin: .zero, size: Self.contentSize)
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        textView = scrollView.documentView as? NSTextView ?? NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = text

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.contentView = scrollView
        window.initialFirstResponder = textView
        window.title = Self.title
        window.contentMinSize = NSSize(width: 360, height: 240)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("acknowledgements")
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
