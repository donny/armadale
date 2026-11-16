import ArmadaleCore
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// A favorite being dragged in the New Session chooser (declared in
    /// Info.plist). Not text, so dropping one on a terminal types nothing,
    /// and not a ``HierarchyDragItem``, so the sidebar and the tab bar do
    /// not take it (nor a favorite row a tab).
    static let armadaleFavorite = UTType(exportedAs: "com.tinylittleapps.armadale.favorite")
}

/// What a favorite row of the chooser drags, to reorder the favorites
/// (DESIGN §8, "New sessions").
struct FavoriteDragItem: Codable, Hashable, Sendable, Transferable {
    let id: FavoriteID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .armadaleFavorite)
    }

    /// The favorite whose drag started last (SwiftUI builds the payload
    /// when a drag begins): a row it hovers over draws the drop indicator
    /// on the edge where it will land, which the drop destination alone
    /// cannot tell (it sees the payload only on the drop). A handled drop
    /// clears it (``NewSessionChooser/drop(_:onto:)``); a cancelled drag
    /// leaves it until the next drag starts, which only matters to the
    /// indicator.
    @MainActor static var lastDragged: FavoriteID?

    /// The payload for a drag of `id`, noting it as ``lastDragged``.
    @MainActor static func dragging(_ id: FavoriteID) -> FavoriteDragItem {
        lastDragged = id
        return FavoriteDragItem(id: id)
    }
}
