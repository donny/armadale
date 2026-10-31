import AppKit

/// The modifier rules for a pane's context menu, shared by the surfaces'
/// views and the host's panes (``TerminalSurface``'s contract; DESIGN §8,
/// "Pane context menu"). Pure functions.
public enum ContextClick {
    /// Shift + right-click always opens the host's menu, never reaching the
    /// program inside.
    public static func bypassesProgram(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.shift)
    }

    /// A left-button press with Control held, and Command not held, is a
    /// right-click. With Command it stays a left click, so ⌘-click on a
    /// link still opens it.
    ///
    /// Such a click reaches a program that asked for the mouse as a right
    /// button, exactly as a right-click would. To make Control-click always
    /// open the host's menu instead, a surface's view would send it up the
    /// responder chain rather than through its right-click path
    /// (`HostTerminalView.mouseDown` in `SwiftTermSurface`, one line).
    public static func isSecondaryClick(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.control) && !modifiers.contains(.command)
    }

    /// Whether `event` is a left-button press that is a right-click
    /// (``isSecondaryClick(_:)``).
    public static func isSecondaryClick(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .leftMouseDown else { return false }
        return isSecondaryClick(event.modifierFlags)
    }

    /// `event` (a left-button event) as a right-button event of `type`
    /// (`.rightMouseDown`, `.rightMouseDragged` or `.rightMouseUp`),
    /// without Control. Made from a copy of its `CGEvent`, so it keeps its
    /// window, location, click count and timestamp, and has button number 1
    /// (`NSEvent.mouseEvent(with:…)` would leave it 0, the left button).
    public static func rightButtonEvent(_ type: NSEvent.EventType, from event: NSEvent) -> NSEvent? {
        let cgType: CGEventType
        switch type {
        case .rightMouseDown: cgType = .rightMouseDown
        case .rightMouseDragged: cgType = .rightMouseDragged
        case .rightMouseUp: cgType = .rightMouseUp
        default: return nil
        }
        guard let copy = event.cgEvent?.copy() else { return nil }
        copy.type = cgType
        copy.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.right.rawValue))
        copy.flags.remove(.maskControl)
        return NSEvent(cgEvent: copy)
    }
}
