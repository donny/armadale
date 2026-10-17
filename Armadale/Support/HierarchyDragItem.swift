import ArmadaleCore
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// A tab or tab group being dragged inside Armadale (declared in
    /// Info.plist). Deliberately not text, so dropping one on a terminal
    /// never types its ID into the shell.
    static let armadaleHierarchyItem = UTType(exportedAs: "com.tinylittleapps.armadale.hierarchy-item")
}

/// What the tab bar and the sidebar drag: a tab (to reorder it, or to move
/// it to another tab group) or a tab group (to reorder groups).
enum HierarchyDragItem: Codable, Hashable, Sendable, Transferable {
    case tab(TabID)
    case tabGroup(TabGroupID)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .armadaleHierarchyItem)
    }
}
