import AppKit

/// A one-field sheet for renaming things.
@MainActor
enum TextPrompt {
    /// Asks for a name on `window`. `completion` gets the trimmed text, or
    /// is not called if the user cancels.
    static func ask(
        on window: NSWindow?,
        title: String,
        message: String? = nil,
        initialValue: String,
        placeholder: String = "",
        confirmTitle: String = "Rename",
        completion: @escaping @MainActor (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initialValue
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            completion(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { finish(response) }
            }
        } else {
            finish(alert.runModal())
        }
        field.selectText(nil)
    }
}
