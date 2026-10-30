import AppKit
import Testing

/// The sidebar's list never takes keyboard focus (DESIGN §1, October 29,
/// 2026): ``WorkspaceWindow`` refuses a table or outline view inside its
/// sidebar, and only that.
@Suite("Sidebar focus")
@MainActor
struct SidebarFocusTests {
    @Test func theWindowRefusesOnlyTheSidebarsList() {
        _ = NSApplication.shared
        let window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let content = NSView(frame: NSRect(x: 200, y: 0, width: 200, height: 300))
        window.contentView?.addSubview(sidebar)
        window.contentView?.addSubview(content)
        window.sidebarView = sidebar

        // A table or outline view accepts first responder only with a column.
        let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        outline.addTableColumn(NSTableColumn(identifier: .init("name")))
        sidebar.addSubview(outline)
        let field = RenameTextField(string: "Name")
        field.frame = NSRect(x: 0, y: 250, width: 200, height: 22)
        sidebar.addSubview(field)
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        content.addSubview(table)

        var changes: [NSResponder?] = []
        window.onFirstResponderChange = { changes.append($0) }

        #expect(window.makeFirstResponder(table), "a table outside the sidebar takes focus")
        #expect(window.firstResponder === table)
        #expect(changes.count == 1 && changes.last! === table)

        #expect(!window.makeFirstResponder(outline), "the sidebar's list is refused")
        #expect(window.firstResponder === table, "focus stays where it was")
        #expect(changes.count == 1, "a refused change is not reported")

        // The field hands focus on to its field editor, a nested change
        // that is reported too.
        #expect(window.makeFirstResponder(field), "a rename field in the sidebar takes focus")
        #expect(changes.count > 1, "the accepted change is reported")
        let editor = window.firstResponder as? NSText
        #expect(editor?.delegate === field, "the field's editor has focus")
        #expect(changes.last! === editor)
        window.close()
    }
}
