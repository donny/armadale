import ArmadaleCore
import Foundation
import Observation

/// The decisions of the New Session chooser an empty pane shows (DESIGN §8,
/// "New sessions"), without any view: the favorites it lists, which one is
/// selected, and what a click, a key or a button does. ``NewSessionPaneView``
/// shows it and ``EmptyPaneView`` feeds it keys; the tests drive it
/// directly.
///
/// Keys: ↓ and ↑ move the selection through the favorites that can start
/// (broken ones are skipped) and clamp at the ends; above the first
/// favorite is no selection, where it starts. Return starts the selected
/// favorite or, with none selected, opens the New Session dialog. Escape is
/// Cancel, which closes the pane. Keys only count while the pane is the
/// focused one, or the only one on screen (``isKeyTarget``).
@MainActor
@Observable
final class NewSessionChooser {
    @ObservationIgnored let model: AppModel
    @ObservationIgnored let paneID: PaneID
    @ObservationIgnored private weak var actions: WorkspaceActions?

    /// The favorite chosen with the arrow keys, if any. It may name one
    /// that has since been removed or broken; ``selectedFavoriteID`` is
    /// what counts.
    private(set) var selection: FavoriteID?

    /// Whether Return and Escape act on this chooser: its pane is the
    /// focused pane of a split, or the only pane on screen.
    var isKeyTarget = true

    init(model: AppModel, paneID: PaneID, actions: WorkspaceActions?) {
        self.model = model
        self.paneID = paneID
        self.actions = actions
    }

    /// What the arrow keys and Return and Escape do.
    enum Key {
        case up, down, confirm, cancel
    }

    // MARK: What is shown

    /// Every favorite, in the model's order (which the chooser's drag and
    /// Move Up / Move Down keep), broken ones too.
    var favorites: [Favorite] { model.favorites }

    /// Why `favorite` cannot start ("Host removed", "Profile removed"), or
    /// `nil` when it can.
    func problem(of favorite: Favorite) -> String? {
        model.favoriteProblem(favorite)
    }

    /// The favorites that can start, in order: the ones the arrow keys
    /// move through.
    private var startable: [FavoriteID] {
        favorites.filter { problem(of: $0) == nil }.map(\.id)
    }

    /// The selection, if it still names a favorite that can start.
    var selectedFavoriteID: FavoriteID? {
        guard let selection, startable.contains(selection) else { return nil }
        return selection
    }

    /// Whether Return would open the New Session dialog (no favorite is
    /// selected): its button then shows as the default one.
    var returnOpensDialog: Bool { selectedFavoriteID == nil }

    // MARK: Keys

    /// Handles a key; returns whether it did anything.
    @discardableResult
    func handle(_ key: Key) -> Bool {
        switch key {
        case .down: return moveSelection(by: 1)
        case .up: return moveSelection(by: -1)
        case .confirm:
            guard isKeyTarget else { return false }
            if let selected = selectedFavoriteID { return start(selected) }
            newSession()
            return true
        case .cancel:
            guard isKeyTarget else { return false }
            cancel()
            return true
        }
    }

    /// Moves the selection `offset` places through the startable favorites,
    /// clamped: ↓ from no selection picks the first, ↑ from the first goes
    /// back to no selection, and neither end wraps. Returns whether the
    /// selection changed.
    @discardableResult
    func moveSelection(by offset: Int) -> Bool {
        let ids = startable
        // Position 0 is "no selection", favorites follow from 1.
        let current = selectedFavoriteID.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let target = min(max(current + offset, 0), ids.count)
        let newSelection = target == 0 ? nil : ids[target - 1]
        guard newSelection != selection else { return false }
        selection = newSelection
        return true
    }

    /// Selects `id` (or nothing), e.g. when the pointer picks a row.
    func select(_ id: FavoriteID?) {
        selection = id
    }

    // MARK: Actions

    /// A click on a favorite (or Return on the selected one): starts it in
    /// this pane. A broken or removed favorite does nothing. Returns whether
    /// a session was started.
    @discardableResult
    func start(_ id: FavoriteID) -> Bool {
        actions?.startFavorite(id, in: paneID) != nil
    }

    /// New Session…: the dialog, as a sheet on the window.
    func newSession() {
        actions?.newSession(in: paneID)
    }

    /// Cancel: closes the pane (and, with it, an empty tab, group and
    /// workspace).
    func cancel() {
        actions?.cancelNewSession(in: paneID)
    }

    /// A favorite's Edit…: the dialog in edit mode.
    func edit(_ id: FavoriteID) {
        actions?.editFavorite(id)
    }

    /// A favorite's Remove, without a question. The selection goes with it.
    func remove(_ id: FavoriteID) {
        if selection == id { selection = nil }
        actions?.removeFavorite(id)
    }

    // MARK: Order

    /// Whether Move Up (`offset` -1) or Move Down (+1) can move `id`: not
    /// the first up, nor the last down. Broken favorites move too.
    func canMove(_ id: FavoriteID, by offset: Int) -> Bool {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return false }
        return favorites.indices.contains(index + offset)
    }

    /// Move Up (`offset` -1) or Move Down (+1) in the context menu or as an
    /// accessibility action: `id` swaps places with its neighbour. The
    /// order is the model's, so every chooser follows; the arrow keys'
    /// selection follows the favorite (it is an ID). Returns whether it
    /// moved.
    @discardableResult
    func move(_ id: FavoriteID, by offset: Int) -> Bool {
        guard canMove(id, by: offset), let index = favorites.firstIndex(where: { $0.id == id }) else { return false }
        // The index counts after removal: one up is index - 1, one down
        // index + 1 (past the neighbour that slid into its place).
        model.moveFavorite(id, to: index + offset)
        return true
    }

    /// Where a favorite dropped on a row lands, as in the tab bar: it takes
    /// that row's place, so it ends up above the row when it came from
    /// below and below the row when it came from above.
    enum DropEdge: Equatable {
        case above, below
    }

    /// The index (after removal, as ``AppModel/moveFavorite(_:to:)``
    /// counts it) `dragged` moves to when dropped on the row of `target`,
    /// in `order`: the target's own index. `nil` when either is not in
    /// `order` or they are the same favorite (nothing moves).
    static func dropIndex(of dragged: FavoriteID, onto target: FavoriteID, in order: [FavoriteID]) -> Int? {
        guard dragged != target, order.contains(dragged), let index = order.firstIndex(of: target) else { return nil }
        return index
    }

    /// Which edge of `target`'s row shows the drop indicator while
    /// `dragged` is over it: where it will land. `nil` when the drop would
    /// move nothing.
    static func dropEdge(of dragged: FavoriteID, onto target: FavoriteID, in order: [FavoriteID]) -> DropEdge? {
        guard dropIndex(of: dragged, onto: target, in: order) != nil,
              let from = order.firstIndex(of: dragged), let to = order.firstIndex(of: target)
        else { return nil }
        return from < to ? .below : .above
    }

    /// Favorites dropped on the row of `target`: the first takes its
    /// place. Returns whether anything moved. Whatever happens, the drag is
    /// over: ``FavoriteDragItem/lastDragged`` is cleared (the drop itself
    /// goes by the dropped items, never by it).
    @discardableResult
    func drop(_ items: [FavoriteDragItem], onto target: FavoriteID) -> Bool {
        FavoriteDragItem.lastDragged = nil
        guard let dragged = items.first?.id,
              let index = Self.dropIndex(of: dragged, onto: target, in: favorites.map(\.id))
        else { return false }
        model.moveFavorite(dragged, to: index)
        return true
    }
}
