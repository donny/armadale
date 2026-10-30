import AppKit
import os
import SwiftUI

/// Debug-level log of inline renaming (which field editor an edit uses).
private let renameLog = Logger(subsystem: "com.tinylittleapps.armadale", category: "rename")

/// The text field of an inline rename (``InlineRename``), shown by the
/// sidebar and the tab bar in place of a title.
///
/// It is an AppKit `NSTextField` rather than a SwiftUI `TextField` so that
/// every way an edit ends is explicit: Return (`insertNewline:`) commits,
/// Escape (`cancelOperation:`) cancels, both through the delegate's
/// `doCommandBy` before the field editor acts on them; the field losing
/// keyboard focus (a click elsewhere, Tab) commits through
/// `controlTextDidEndEditing`; its window resigning key (another window or
/// app, a sheet) commits as well, since the field keeps first responder
/// then. After Return, Escape or the window resigning key, keyboard focus
/// goes back to ``InlineRename/returnFocus`` (the terminal, or an empty
/// pane's chooser), else to the window's focused terminal; after a click
/// elsewhere it stays where the click put it.
///
/// Whenever SwiftUI tears the field down, the edit is committed on the next
/// turn of the main actor, unless a new field has picked the edit up by
/// then (SwiftUI can recreate a field mid-edit), and focus left nowhere is
/// put back. Nothing in the teardown changes the model during SwiftUI's
/// update.
///
/// Names are taken literally: no text replacement, spelling correction,
/// quote, dash or double-space-period substitution (``RenameTextFieldCell``).
///
/// It takes keyboard focus, with all its text selected, once it is in a
/// window (on the next turn of the main actor, after SwiftUI's update).
/// Its font is the SwiftUI `font` it is given, resolved in its environment,
/// so the text does not change size or weight when editing starts.
struct InlineRenameField: NSViewRepresentable {
    let rename: InlineRename
    let edit: InlineRename.Edit
    /// The font of the title it replaces.
    var font: Font = .body

    func makeCoordinator() -> Coordinator {
        Coordinator(rename: rename, editID: edit.id)
    }

    func makeNSView(context: Context) -> RenameTextField {
        let field = RenameTextField(string: rename.text)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .default
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.isAutomaticTextCompletionEnabled = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Name")
        field.delegate = context.coordinator
        field.onMoveToWindow = { [weak coordinator = context.coordinator, weak field] window in
            guard let field else { return }
            coordinator?.field(field, movedTo: window)
        }
        field.font = resolvedFont(in: context.environment)
        rename.registerField(ObjectIdentifier(context.coordinator), for: edit.id)
        return field
    }

    func updateNSView(_ field: RenameTextField, context: Context) {
        // The text is the field's own while editing; only the font follows.
        let font = resolvedFont(in: context.environment)
        if field.font != font { field.font = font }
    }

    static func dismantleNSView(_ field: RenameTextField, coordinator: Coordinator) {
        coordinator.tearDown(field)
    }

    private func resolvedFont(in environment: EnvironmentValues) -> NSFont {
        font.resolve(in: environment.fontResolutionContext).ctFont as NSFont
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let rename: InlineRename
        private let editID: Int
        /// Set once this field has ended its edit, or been torn down.
        private var isFinished = false
        private var hasTakenFocus = false
        private weak var field: RenameTextField?
        private weak var window: NSWindow?
        /// The window's shared field editor and its settings, if AppKit
        /// gave the field that one instead of its own: put back at the end.
        private var borrowedEditor: (editor: NSTextView, settings: TextSubstitutions)?

        init(rename: InlineRename, editID: Int) {
            self.rename = rename
            self.editID = editID
        }

        /// Takes keyboard focus, once. A field recreated mid-edit would take
        /// it again and select all its text, so the next key would replace
        /// what was typed; not seen live (closing a row above the edited one
        /// did not recreate it) and accepted.
        func field(_ field: RenameTextField, movedTo window: NSWindow?) {
            guard let window, !hasTakenFocus, !isFinished else { return }
            hasTakenFocus = true
            self.field = field
            self.window = window
            rename.offerReturnFocus(window.firstResponder)
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: window)
            // After SwiftUI's update: the field must be laid out in its row.
            Task { @MainActor [weak self, weak field, weak window] in
                guard let self, let field, let window, !self.isFinished, field.window === window,
                      self.rename.edit?.id == self.editID
                else { return }
                if window.makeFirstResponder(field) {
                    if let editor = field.currentEditor() as? NSTextView, !(editor is RenameFieldEditor) {
                        self.borrowedEditor = (editor, TextSubstitutions(of: editor))
                        TextSubstitutions.none.apply(to: editor)
                    }
                    field.currentEditor()?.selectAll(nil)
                }
            }
        }

        /// Ends this field's edit if it is still the one under way (once).
        /// With `restoreFocus`, and if the field has keyboard focus, focus
        /// goes back to the rename's return place.
        func finish(commit: Bool, restoreFocus: Bool) {
            guard !isFinished else { return }
            isFinished = true
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
            returnBorrowedEditor()
            guard rename.edit?.id == editID else { return }
            if let field { rename.text = field.stringValue }
            let hadFocus = field.map { $0.currentEditor() != nil } ?? false
            rename.end(editID, commit: commit)
            if restoreFocus, hadFocus, let window { rename.restoreFocus(in: window) }
        }

        /// SwiftUI took the field away. Only bookkeeping happens now; the
        /// edit is ended, and focus put back, on the next turn.
        func tearDown(_ field: RenameTextField) {
            field.delegate = nil
            field.onMoveToWindow = nil
            isFinished = true
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
            returnBorrowedEditor()
            rename.unregisterField(ObjectIdentifier(self), for: editID)
            Task { @MainActor [rename, editID, weak window] in
                rename.endIfNoField(editID)
                if let window, window.firstResponder == nil || window.firstResponder === window {
                    rename.restoreFocus(in: window)
                }
            }
        }

        private func returnBorrowedEditor() {
            guard let (editor, settings) = borrowedEditor else { return }
            borrowedEditor = nil
            settings.apply(to: editor)
        }

        @objc private func windowDidResignKey(_ notification: Notification) {
            finish(commit: true, restoreFocus: true)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            let editor = notification.userInfo?["NSFieldEditor"].map { String(describing: type(of: $0)) } ?? "none"
            renameLog.debug("Inline rename: editing with field editor \(editor, privacy: .public)")
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field, !isFinished, rename.edit?.id == editID else { return }
            rename.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finish(commit: true, restoreFocus: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(commit: false, restoreFocus: true)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            // Focus went elsewhere (a click, Tab): it stays there. Ending
            // editing can also come from AppKit while SwiftUI is removing
            // the field; the model is changed on the next turn, and only if
            // the field is still in its window (else teardown decides).
            Task { @MainActor [weak self] in
                guard let self, let field = self.field, field.window != nil else { return }
                self.finish(commit: true, restoreFocus: false)
            }
        }
    }
}

/// The NSTextField of an ``InlineRenameField``; reports when it is put in a
/// window so it can take keyboard focus there.
final class RenameTextField: NSTextField {
    var onMoveToWindow: ((NSWindow?) -> Void)?

    override class var cellClass: AnyClass? {
        get { RenameTextFieldCell.self }
        set {}
    }

    /// The field's own field editor (``RenameFieldEditor``), which the
    /// window's delegate hands out for it as well as the cell.
    var privateFieldEditor: NSTextView? {
        (cell as? RenameTextFieldCell)?.fieldEditor(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?(window)
    }
}

extension View {
    /// `draggable(item)`, left out while the view's title is being edited
    /// in place, so that dragging in the field selects text instead.
    @ViewBuilder
    func draggable(_ item: HierarchyDragItem, unlessEditing isEditing: Bool) -> some View {
        if isEditing { self } else { draggable(item) }
    }

    /// `draggable(item, preview:)`, left out while editing in place.
    @ViewBuilder
    func draggable(
        _ item: HierarchyDragItem, unlessEditing isEditing: Bool, @ViewBuilder preview: () -> some View
    ) -> some View {
        if isEditing { self } else { draggable(item, preview: preview) }
    }
}

/// The cell of a ``RenameTextField``: edits with a field editor of its own
/// with every automatic substitution off, so a name is taken literally and
/// the window's shared field editor is left as it is.
final class RenameTextFieldCell: NSTextFieldCell {
    private var editor: RenameFieldEditor?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        if let editor { return editor }
        let made = RenameFieldEditor()
        made.isFieldEditor = true
        TextSubstitutions.none.apply(to: made)
        editor = made
        return made
    }
}

/// The private field editor of a ``RenameTextFieldCell``. It also stops
/// the system's "Add period with double-space", which the text view's
/// substitution flags do not: the text input system replaces the space
/// typed before with ". " when a second space follows, through
/// `insertText(_:replacementRange:)`.
final class RenameFieldEditor: NSTextView {
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = self.string as NSString
        if replacementRange.location != NSNotFound, replacementRange.length == 1,
           NSMaxRange(replacementRange) <= text.length,
           let inserted = (string as? String) ?? (string as? NSAttributedString)?.string,
           let literal = Self.substitutionOverride(
               inserted: inserted, replacedText: text.substring(with: replacementRange)) {
            super.insertText(literal, replacementRange: replacementRange)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// What to insert instead of `inserted` replacing `replacedText`, or
    /// `nil` to insert it as it is: a period substituted for a typed space
    /// (". " replacing " ") becomes that space again ("  ").
    nonisolated static func substitutionOverride(inserted: String, replacedText: String) -> String? {
        guard replacedText == " ", inserted.hasPrefix(". ") else { return nil }
        return " " + inserted.dropFirst()
    }
}

/// The automatic text substitutions of a text view.
struct TextSubstitutions {
    var replacement: Bool
    var spellingCorrection: Bool
    var completion: Bool
    var quotes: Bool
    var dashes: Bool
    var dataDetection: Bool
    var linkDetection: Bool
    var checkingTypes: NSTextCheckingTypes

    /// Everything off: what a rename field edits with.
    static let none = TextSubstitutions(
        replacement: false, spellingCorrection: false, completion: false, quotes: false, dashes: false,
        dataDetection: false, linkDetection: false, checkingTypes: 0)

    init(
        replacement: Bool, spellingCorrection: Bool, completion: Bool, quotes: Bool, dashes: Bool,
        dataDetection: Bool, linkDetection: Bool, checkingTypes: NSTextCheckingTypes
    ) {
        self.replacement = replacement
        self.spellingCorrection = spellingCorrection
        self.completion = completion
        self.quotes = quotes
        self.dashes = dashes
        self.dataDetection = dataDetection
        self.linkDetection = linkDetection
        self.checkingTypes = checkingTypes
    }

    @MainActor
    init(of view: NSTextView) {
        self.init(
            replacement: view.isAutomaticTextReplacementEnabled,
            spellingCorrection: view.isAutomaticSpellingCorrectionEnabled,
            completion: view.isAutomaticTextCompletionEnabled,
            quotes: view.isAutomaticQuoteSubstitutionEnabled,
            dashes: view.isAutomaticDashSubstitutionEnabled,
            dataDetection: view.isAutomaticDataDetectionEnabled,
            linkDetection: view.isAutomaticLinkDetectionEnabled,
            checkingTypes: view.enabledTextCheckingTypes)
    }

    @MainActor
    func apply(to view: NSTextView) {
        view.isAutomaticTextReplacementEnabled = replacement
        view.isAutomaticSpellingCorrectionEnabled = spellingCorrection
        view.isAutomaticTextCompletionEnabled = completion
        view.isAutomaticQuoteSubstitutionEnabled = quotes
        view.isAutomaticDashSubstitutionEnabled = dashes
        view.isAutomaticDataDetectionEnabled = dataDetection
        view.isAutomaticLinkDetectionEnabled = linkDetection
        view.enabledTextCheckingTypes = checkingTypes
    }
}
