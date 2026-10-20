import AppKit
import ArmadaleCore
import Observation

/// Where an inline rename field is shown in a window.
enum RenameSurface: Hashable {
    case sidebar
    case tabBar
}

/// Renaming a workspace, tab group or tab in place (DESIGN §1, §8). One per
/// window, owned by its ``WorkspaceActions``: the window's sidebar and tab
/// bar observe ``edit`` and show a text field instead of the title of the
/// row (or tab) it names, so there is at most one edit per window. Starting
/// another edit commits the current one.
///
/// Committing collapses runs of whitespace (newlines and tabs included) to
/// one space, trims the text, and applies it through the ``AppModel``
/// rename intents. Text that is unchanged from what the field started with
/// changes nothing; a blank name is ignored for a workspace or tab group
/// (the old name stays) and clears a tab's custom title (back to the
/// derived title). Cancelling changes nothing.
@Observable
@MainActor
final class InlineRename {
    /// The edit under way.
    struct Edit: Equatable, Identifiable {
        /// Distinguishes edits, also of the same item, so a field that
        /// belonged to an earlier edit can never end a later one.
        let id: Int
        let item: SidebarItem
        let surface: RenameSurface
        /// What the field started with: the item's name, or a tab's custom
        /// title, else its derived title.
        let original: String
    }

    @ObservationIgnored private let model: AppModel
    /// The edit under way, if any.
    private(set) var edit: Edit?
    /// The field's text, kept current by the field as the user types (not
    /// observed: nothing redraws on a keystroke).
    @ObservationIgnored var text = ""
    @ObservationIgnored private var lastID = 0

    /// Where keyboard focus goes back to when an edit ends by Return,
    /// Escape or the window resigning key: what had it before the first
    /// field of a chain of edits took it (a later field of the chain only
    /// sees the earlier field). Kept across edits started while another is
    /// under way; a fresh edit forgets it. Never a rename field, its field
    /// editor, or the window itself.
    @ObservationIgnored private(set) weak var returnFocus: NSResponder?
    /// Focuses the window's focused terminal; where focus goes when
    /// ``returnFocus`` is gone or in another window.
    @ObservationIgnored var focusFallback: () -> Void = {}
    /// The fields alive for each edit (a field can be recreated mid-edit).
    @ObservationIgnored private var liveFields: [Int: Set<ObjectIdentifier>] = [:]

    init(model: AppModel) {
        self.model = model
    }

    /// The edit under way if it is of `item` on `surface`.
    func edit(of item: SidebarItem, on surface: RenameSurface) -> Edit? {
        guard let edit, edit.item == item, edit.surface == surface else { return nil }
        return edit
    }

    /// Starts editing `item` on `surface`, committing the edit under way
    /// first. Does nothing if that edit is already under way (a double
    /// click inside the field), and returns false if the item does not
    /// exist.
    @discardableResult
    func begin(_ item: SidebarItem, on surface: RenameSurface) -> Bool {
        if let edit, edit.item == item, edit.surface == surface { return true }
        guard name(of: item) != nil else { return false }
        if edit == nil { returnFocus = nil }
        commit()
        // The commit may have renamed this very item: start from the model.
        guard let original = name(of: item) else { return false }
        lastID += 1
        text = original
        edit = Edit(id: lastID, item: item, surface: surface, original: original)
        return true
    }

    /// Ends the edit under way, applying ``text``.
    func commit() {
        guard let edit else { return }
        self.edit = nil
        apply(text, to: edit)
    }

    /// Ends the edit under way without changing anything.
    func cancel() {
        edit = nil
    }

    /// Ends edit `id`, committing or cancelling it, if it is still the edit
    /// under way; otherwise does nothing.
    func end(_ id: Int, commit shouldCommit: Bool) {
        guard edit?.id == id else { return }
        if shouldCommit { commit() } else { cancel() }
    }

    // MARK: Fields and focus

    /// Records `responder` (what has keyboard focus as a field appears) as
    /// ``returnFocus``, unless one is recorded already or it is a rename
    /// field (or its field editor) or a window.
    func offerReturnFocus(_ responder: NSResponder?) {
        guard returnFocus == nil, let responder else { return }
        var owner = responder
        if let editor = responder as? NSText, editor.isFieldEditor, let delegate = editor.delegate as? NSResponder {
            owner = delegate
        }
        guard !(owner is RenameTextField), !(owner is NSWindow) else { return }
        returnFocus = owner
    }

    /// Puts keyboard focus back on ``returnFocus`` if it is still in
    /// `window`, else on the window's focused terminal.
    func restoreFocus(in window: NSWindow) {
        if let target = returnFocus, (target as? NSView)?.window === window, window.makeFirstResponder(target) {
            return
        }
        focusFallback()
    }

    /// A field for edit `id` was created.
    func registerField(_ field: ObjectIdentifier, for id: Int) {
        liveFields[id, default: []].insert(field)
    }

    /// A field for edit `id` was taken away.
    func unregisterField(_ field: ObjectIdentifier, for id: Int) {
        liveFields[id]?.remove(field)
        if liveFields[id]?.isEmpty == true { liveFields[id] = nil }
    }

    /// Commits edit `id` if it is still under way and no field shows it any
    /// more (its last field was taken away and none replaced it).
    func endIfNoField(_ id: Int) {
        guard edit?.id == id, liveFields[id] == nil else { return }
        commit()
    }

    // MARK: Rules

    /// What committing `text` does to an item whose field started with
    /// `original`: `nil` changes nothing, else the new name (empty only
    /// for a tab, meaning "back to the derived title").
    nonisolated static func committedName(_ text: String, original: String, allowsEmpty: Bool) -> String? {
        let name = normalized(text)
        guard name != normalized(original) else { return nil }
        guard !name.isEmpty || allowsEmpty else { return nil }
        return name
    }

    /// `text` with every run of whitespace (newlines and tabs included)
    /// made one space, and trimmed.
    nonisolated static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func apply(_ text: String, to edit: Edit) {
        switch edit.item {
        case .workspace(let id):
            guard let name = Self.committedName(text, original: edit.original, allowsEmpty: false) else { return }
            model.renameWorkspace(id, to: name)
        case .tabGroup(let id):
            guard let name = Self.committedName(text, original: edit.original, allowsEmpty: false) else { return }
            model.renameTabGroup(id, to: name)
        case .tab(let id):
            guard let name = Self.committedName(text, original: edit.original, allowsEmpty: true) else { return }
            model.renameTab(id, to: name.isEmpty ? nil : name)
        }
    }

    private func name(of item: SidebarItem) -> String? {
        switch item {
        case .workspace(let id): model.workspace(id)?.name
        case .tabGroup(let id): model.tabGroup(id)?.name
        case .tab(let id): model.tab(id).map { $0.customTitle ?? model.displayTitle(for: $0) }
        }
    }
}
