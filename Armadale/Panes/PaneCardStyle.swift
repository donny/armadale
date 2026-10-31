import AppKit
import TerminalSurface

/// The geometry and borders of pane cards (DESIGN §8, "Pane cards"): each
/// leaf of a tab's split tree is a rounded card with a header, set in a
/// gutter that shows the window background, with gaps between siblings.
/// Pure values and functions, so they are tested without a window (as
/// ``TabBarStyle`` is).
enum PaneCardStyle {
    /// Around the whole pane area, on all four sides (the tab bar's margin).
    static let gutter: CGFloat = TabBarStyle.margin
    /// Between sibling cards: a split's divider, drawn as nothing.
    static let gap: CGFloat = 8
    static let cornerRadius: CGFloat = 10
    /// The header row at the top of every card (the tab bar's track height).
    static let headerHeight: CGFloat = TabBarStyle.trackHeight
    /// Between the header and the terminal grid.
    static let headerSpacing: CGFloat = 4
    /// Left, right and bottom padding around the terminal grid; at least the
    /// corner radius, so no corner cell is clipped.
    static let padding: CGFloat = 10

    /// Where a card's terminal sits inside it: below the header and its
    /// spacing, inside the padding.
    static let terminalInsets = NSEdgeInsets(
        top: headerHeight + headerSpacing, left: padding, bottom: padding, right: padding)

    /// The terminal's frame in a card of `bounds` (not flipped: y grows
    /// upwards), never negative.
    static func terminalFrame(in bounds: NSRect) -> NSRect {
        let insets = terminalInsets
        return NSRect(
            x: bounds.minX + insets.left, y: bounds.minY + insets.bottom,
            width: max(bounds.width - insets.left - insets.right, 0),
            height: max(bounds.height - insets.top - insets.bottom, 0))
    }

    /// The header's frame in a card of `bounds` (not flipped): the top
    /// ``headerHeight`` points, or all of a card shorter than that.
    static func headerFrame(in bounds: NSRect) -> NSRect {
        let height = min(headerHeight, max(bounds.height, 0))
        return NSRect(x: bounds.minX, y: bounds.maxY - height, width: max(bounds.width, 0), height: height)
    }

    /// What lies under the header (a placeholder's or the chooser's area).
    static func contentFrame(in bounds: NSRect) -> NSRect {
        NSRect(
            x: bounds.minX, y: bounds.minY, width: max(bounds.width, 0),
            height: max(bounds.height - headerHeight, 0))
    }

    // MARK: Header

    /// The header's horizontal padding: the glyph lines up with the grid.
    static let headerLeading: CGFloat = padding
    static let headerTrailing: CGFloat = 4
    /// The status glyph's width (``StatusGlyph``'s own constant).
    static let glyphWidth: CGFloat = StatusGlyph.width

    /// The header's buttons, left to right, at its trailing end: Split
    /// Right, Split Down, then "…" (the pane menu) last.
    enum HeaderButton: CaseIterable {
        case splitRight, splitDown, menu
    }

    /// Each header button's clickable size.
    static let headerButtonSize = NSSize(width: 24, height: 20)
    /// Between neighbouring header buttons; their symbols are narrower than
    /// the buttons, which leaves room enough between them.
    static let headerButtonSpacing: CGFloat = 0
    /// Strengths of the theme foreground in the header.
    static let titleOpacity: Double = 0.7
    static let directoryOpacity: Double = 0.55
    /// Every header button, at rest and under the pointer.
    static let headerButtonOpacity: Double = 0.55
    static let headerButtonHoverOpacity: Double = 1

    /// The width the header's buttons take: all three, or "…" alone.
    static func headerButtonsWidth(showsSplitButtons: Bool) -> CGFloat {
        let count: CGFloat = showsSplitButtons ? CGFloat(HeaderButton.allCases.count) : 1
        return count * headerButtonSize.width + (count - 1) * headerButtonSpacing
    }

    /// A button's frame in a header of `size` showing all three buttons,
    /// in flipped coordinates (y grows downwards, as an `NSHostingView`'s):
    /// vertically centred, "…" ending ``headerTrailing`` from the header's
    /// trailing edge and the split buttons left of it.
    static func headerButtonFrame(_ button: HeaderButton, inHeaderOf size: NSSize) -> NSRect {
        let fromTrailing: CGFloat = switch button {
        case .menu: 0
        case .splitDown: 1
        case .splitRight: 2
        }
        let trailing = size.width - headerTrailing - fromTrailing * (headerButtonSize.width + headerButtonSpacing)
        let top = (min(size.height, headerHeight) - headerButtonSize.height) / 2
        return NSRect(
            x: trailing - headerButtonSize.width, y: top,
            width: headerButtonSize.width, height: headerButtonSize.height)
    }

    /// The width the title and the working directory share in a header
    /// `headerWidth` wide (what ``PaneHeaderView``'s row leaves them):
    /// everything but the padding, the glyph if any, the buttons shown and
    /// the spacing between them (``textSpacing`` on each side of the
    /// flexible space before the buttons). ``headerTextWidths(available:title:directory:)``
    /// divides it.
    static func headerTextSpace(headerWidth: CGFloat, hasGlyph: Bool, showsSplitButtons: Bool) -> CGFloat {
        let glyph = hasGlyph ? glyphWidth + textSpacing : 0
        let fixed = headerLeading + glyph + 2 * textSpacing
            + headerButtonsWidth(showsSplitButtons: showsSplitButtons) + headerTrailing
        return max(headerWidth - fixed, 0)
    }

    /// Whether a header `headerWidth` wide shows the split buttons: only
    /// while a pane's title (with its glyph) keeps at least
    /// ``minimumTextWidth`` beside all three buttons. A narrower header
    /// shows "…" alone, whose menu splits too, so the title is not
    /// squeezed out (DESIGN §8, "Pane cards").
    static func showsSplitButtons(headerWidth: CGFloat) -> Bool {
        headerTextSpace(headerWidth: headerWidth, hasGlyph: true, showsSplitButtons: true) >= minimumTextWidth
    }

    /// Where the "…" button's pull-down menu opens, in a header of `size`
    /// whose coordinates are flipped (y grows downwards, as an
    /// `NSHostingView`'s): under the button, its leading edge at the
    /// button's leading edge; or, when a menu `menuWidth` wide would run
    /// past the window's right edge (`roomRightOfHeader` is the window
    /// width right of the header's trailing edge), its trailing edge at the
    /// button's trailing edge.
    static func menuOrigin(inHeaderOf size: NSSize, menuWidth: CGFloat = 0, roomRightOfHeader: CGFloat = .infinity)
        -> NSPoint {
        let button = headerButtonFrame(.menu, inHeaderOf: size)
        let roomFromLeading = size.width - button.minX + roomRightOfHeader
        let x = menuWidth > roomFromLeading ? button.maxX - menuWidth : button.minX
        return NSPoint(x: x, y: button.maxY + 2)
    }

    /// The least width the title or the working directory is shown in.
    static let minimumTextWidth: CGFloat = 40
    /// The most of the header's text width the directory takes while the
    /// title is truncated.
    static let directoryShare: CGFloat = 0.4
    /// Between the title and the directory.
    static let textSpacing: CGFloat = 6

    /// The widths the title and the working directory are drawn in, in
    /// `available` points, from their untruncated widths (DESIGN §8, "Pane
    /// cards", *As built*). Both whole when they fit. Otherwise the
    /// directory keeps up to ``directoryShare`` of the width (at least
    /// ``minimumTextWidth``, never more than it needs, and all the title
    /// leaves when the title fits whole) and the title is truncated to the
    /// rest; when that would leave the title under ``minimumTextWidth``,
    /// the directory is dropped (`nil`) and the title takes the width.
    static func headerTextWidths(available: CGFloat, title: CGFloat, directory: CGFloat?)
        -> (title: CGFloat, directory: CGFloat?) {
        let available = max(available, 0)
        guard let directory, directory > 0 else { return (min(title, available), nil) }
        if title + textSpacing + directory <= available { return (title, directory) }
        // The title whole, the directory truncated to what is left.
        let left = available - textSpacing - title
        if left >= min(directory, max(minimumTextWidth, available * directoryShare)) {
            return (title, min(directory, left))
        }
        let share = min(directory, max(minimumTextWidth, (available * directoryShare).rounded(.down)))
        let titleWidth = available - textSpacing - share
        guard titleWidth >= minimumTextWidth else { return (min(title, available), nil) }
        return (titleWidth, share)
    }

    // MARK: Borders

    /// The border a card draws for its focus style: a hairline in the
    /// theme's foreground on every card, replaced by the accent border on
    /// the focused card of several.
    struct Border: Equatable {
        enum Kind: Equatable { case hairline, focus }
        var kind: Kind
        var width: CGFloat
        /// Resolve with the card's appearance current (the accent colour
        /// differs between light and dark).
        var color: NSColor
    }

    static let hairlineWidth: CGFloat = 0.5
    static let hairlineOpacity: CGFloat = 0.12
    static let focusWidth: CGFloat = 1.5
    static let focusOpacity: CGFloat = 0.55

    static func border(for style: PaneView.FocusStyle, foreground: TerminalColor) -> Border {
        switch style {
        case .alone, .unfocused:
            Border(kind: .hairline, width: hairlineWidth, color: nsColor(foreground).withAlphaComponent(hairlineOpacity))
        case .focused:
            Border(kind: .focus, width: focusWidth, color: NSColor.controlAccentColor.withAlphaComponent(focusOpacity))
        }
    }

    /// Applies the card's look to a pane view's layer and its border
    /// overlay: rounded, clipped, filled with `background`, bordered.
    @MainActor
    static func apply(
        to card: NSView, overlay: NSView, style: PaneView.FocusStyle, theme: TerminalTheme
    ) {
        let border = border(for: style, foreground: theme.foreground)
        card.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let layer = card.layer {
                layer.cornerRadius = cornerRadius
                layer.cornerCurve = .continuous
                layer.masksToBounds = true
                layer.backgroundColor = nsColor(theme.background).cgColor
            }
            if let layer = overlay.layer {
                layer.backgroundColor = nil
                layer.cornerRadius = cornerRadius
                layer.cornerCurve = .continuous
                layer.borderWidth = border.width
                layer.borderColor = border.color.cgColor
            }
        }
    }

    static func nsColor(_ color: TerminalColor) -> NSColor {
        NSColor(
            srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255, alpha: 1)
    }
}
