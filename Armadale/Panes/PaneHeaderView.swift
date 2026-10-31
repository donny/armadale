import AppKit
import ArmadaleCore
import SwiftUI
import TerminalSurface

/// What a pane card's header shows (DESIGN §8, "Pane cards"). The pane
/// view keeps it current from the model (``SessionRegistry/headerModel(for:)``)
/// and from its appearance (``foreground``).
struct PaneHeaderModel: Equatable, Sendable {
    /// The session's glyph (◐ while it needs attention); `nil` shows none
    /// (an empty pane).
    var status: SessionStatus?
    var title: String
    /// The working directory, `~`-abbreviated; `nil` or empty shows nothing.
    var directory: String?
    /// Tints the title with ``StatusGlyph/attentionColor``.
    var needsAttention: Bool = false
    /// The pane theme's foreground, which the header uses at reduced
    /// strengths so it suits any theme.
    var foreground = TerminalColor(hex: 0x808080)

    /// The title of a session's pane: the program's title (OSC 0/2), else
    /// the profile's name. A tab's custom title is the tab's, never a pane's.
    static func title(sessionTitle: String, profileName: String?) -> String {
        if !sessionTitle.isEmpty { return sessionTitle }
        return profileName ?? "Shell"
    }

    /// The directory as shown: nothing when unknown, blank, or the same as
    /// the title (a shell that titles itself with its directory, as zsh
    /// and fish do, would otherwise read "~ ~").
    var shownDirectory: String? {
        guard let directory, !directory.isEmpty, directory != title else { return nil }
        return directory
    }

    /// An empty pane's header: no glyph, "New Session".
    static let newSession = PaneHeaderModel(status: nil, title: "New Session", directory: nil)
}

/// The header row of a pane card: status glyph, title, working directory,
/// and the "…" button that opens the pane menu. Drawn in the pane's
/// appearance, in the theme's foreground at reduced opacity.
struct PaneHeaderView: View {
    let model: PaneHeaderModel
    /// The "…" button was pressed.
    var openMenu: () -> Void = {}

    @State private var isHoveringButton = false

    private var title: some View {
        Text(model.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(model.needsAttention
                ? AnyShapeStyle(StatusGlyph.attentionColor)
                : AnyShapeStyle(Color(nsColor: PaneCardStyle.nsColor(model.foreground)).opacity(PaneCardStyle.titleOpacity)))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    var body: some View {
        let foreground = Color(nsColor: PaneCardStyle.nsColor(model.foreground))
        HStack(spacing: PaneCardStyle.textSpacing) {
            if let status = model.status {
                StatusGlyph(status: status)
            }
            // The title and the directory share the width by
            // ``PaneCardStyle/headerTextWidths(available:title:directory:)``.
            HeaderTextLayout {
                title
                if let directory = model.shownDirectory {
                    Text(directory)
                        .font(.system(size: 12))
                        .foregroundStyle(foreground.opacity(PaneCardStyle.directoryOpacity))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Dropped by the layout (no width) without a stray "…".
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .clipped()
                }
            }
            Spacer(minLength: 0)
            Button(action: openMenu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: PaneCardStyle.menuButtonSize.width, height: PaneCardStyle.menuButtonSize.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(foreground.opacity(
                isHoveringButton ? PaneCardStyle.menuButtonHoverOpacity : PaneCardStyle.menuButtonOpacity))
            .onHover { isHoveringButton = $0 }
            .help("Pane Menu")
            .accessibilityLabel("Pane Menu")
        }
        .padding(.leading, PaneCardStyle.headerLeading)
        .padding(.trailing, PaneCardStyle.headerTrailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

/// Lays out a header's title and, if any, its working directory side by
/// side, in the widths ``PaneCardStyle/headerTextWidths(available:title:directory:)``
/// gives; a dropped directory gets no width.
struct HeaderTextLayout: Layout {
    private func ideal(_ subviews: Subviews) -> (title: CGFloat, directory: CGFloat?, height: CGFloat) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return (sizes.first?.width ?? 0, sizes.count > 1 ? sizes[1].width : nil, sizes.map(\.height).max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = ideal(subviews)
        let whole = ideal.title + (ideal.directory.map { $0 + PaneCardStyle.textSpacing } ?? 0)
        let width = proposal.width.map { min($0, whole) } ?? whole
        return CGSize(width: width, height: proposal.height.map { min($0, ideal.height) } ?? ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = ideal(subviews)
        let widths = PaneCardStyle.headerTextWidths(
            available: bounds.width, title: ideal.title, directory: ideal.directory)
        guard let title = subviews.first else { return }
        title.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: widths.title, height: bounds.height))
        guard subviews.count > 1 else { return }
        let x = bounds.minX + widths.title + PaneCardStyle.textSpacing
        subviews[1].place(
            at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: widths.directory ?? 0, height: bounds.height))
    }
}

/// Hosts a card's ``PaneHeaderView`` in a ``PaneView`` or ``EmptyPaneView``.
/// The header is the pane's own, never the program's: a click on it focuses
/// the pane (as a click on the padding does), the "…" button opens the pane
/// menu below itself, and a right-click (or Control-click) anywhere on it
/// opens the same menu at the pointer. Nothing here reaches the terminal or
/// the chooser below, which lie outside the header's frame.
@MainActor
final class PaneHeaderHostingView: NSHostingView<PaneHeaderView> {
    /// Focuses the pane (``PaneView/focusTerminal()``, ``EmptyPaneView/focusPane()``).
    var focusPane: () -> Void = {}
    /// The pane's menu, built fresh (``PaneView/paneMenu()``).
    var makeMenu: () -> NSMenu? = { nil }
    /// Shows the "…" button's menu at a point of this view. Popping a menu
    /// up runs a modal loop, so tests replace it.
    var presentMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }
    /// Shows the right-click menu for an event; replaced in tests.
    var presentContextMenu: (NSMenu, NSEvent, NSView) -> Void = { menu, event, view in
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// What the header shows; setting a different one redraws it.
    var model: PaneHeaderModel {
        get { rootView.model }
        set {
            guard newValue != rootView.model else { return }
            rootView = PaneHeaderView(model: newValue, openMenu: rootView.openMenu)
        }
    }

    /// A header showing `model`, wired to its own menu button.
    static func make(model: PaneHeaderModel) -> PaneHeaderHostingView {
        let header = PaneHeaderHostingView(rootView: PaneHeaderView(model: model))
        header.sizingOptions = []
        header.rootView = PaneHeaderView(model: model) { [weak header] in header?.openMenuFromButton() }
        return header
    }

    /// The "…" button: focus the pane, then the menu as a pull-down under
    /// the button.
    func openMenuFromButton() {
        focusPane()
        guard let menu = makeMenu() else { return }
        var origin = PaneCardStyle.menuOrigin(
            inHeaderOf: bounds.size, menuWidth: menu.size.width, roomRightOfHeader: roomRightOfHeader)
        if !isFlipped { origin.y = bounds.height - origin.y }
        presentMenu(menu, origin, self)
    }

    /// The width of the window's content right of this header's trailing
    /// edge (the gutter, or another pane), so the "…" menu can stay inside
    /// the window.
    private var roomRightOfHeader: CGFloat {
        guard let content = window?.contentView else { return .infinity }
        let trailing = convert(NSPoint(x: bounds.maxX, y: bounds.midY), to: content).x
        return max(content.bounds.maxX - trailing, 0)
    }

    override func mouseDown(with event: NSEvent) {
        focusPane()
        super.mouseDown(with: event)
    }

    /// Right-click: focus the pane, then the menu at the pointer.
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        presentContextMenu(menu, event, self)
    }

    /// AppKit asks for it on a Control-click (and accessibility's Show
    /// Menu); the pane is focused first, as a click would.
    override func menu(for event: NSEvent) -> NSMenu? {
        focusPane()
        return makeMenu()
    }
}
