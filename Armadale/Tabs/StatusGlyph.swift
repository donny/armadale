import SwiftUI

/// The status glyph of a tab (tab bar and sidebar): running, pending,
/// ended, disconnected, unavailable, or ◐ attention. A tab with no session
/// (only empty panes, showing the New Session chooser) has none: `nil`
/// keeps the glyph's place empty.
struct StatusGlyph: View {
    let status: SessionStatus?

    var body: some View {
        if let status {
            Image(systemName: Self.symbol(status))
                .font(.system(size: Self.size(status), weight: .semibold))
                .foregroundStyle(Self.color(status))
                .frame(width: 12)
                .help(Self.help(status))
                .accessibilityLabel(Self.help(status))
        } else {
            Color.clear
                .frame(width: 12, height: 1)
                .accessibilityHidden(true)
        }
    }

    private static func symbol(_ status: SessionStatus) -> String {
        switch status {
        case .running: "circle.fill"
        case .pending: "circle.dotted"
        case .ended: "circle"
        case .disconnected: "exclamationmark.triangle.fill"
        case .unavailable: "exclamationmark.triangle"
        case .attention: "circle.lefthalf.filled"
        }
    }

    private static func size(_ status: SessionStatus) -> CGFloat {
        switch status {
        case .running, .pending, .ended: 7
        case .attention: 8
        case .disconnected, .unavailable: 9
        }
    }

    private static func color(_ status: SessionStatus) -> Color {
        switch status {
        case .running: .green
        case .pending, .ended: .secondary
        case .disconnected: .orange
        case .unavailable: .yellow
        case .attention: StatusGlyph.attentionColor
        }
    }

    private static func help(_ status: SessionStatus) -> String {
        switch status {
        case .running: "Running"
        case .pending: "Starting"
        case .ended: "Ended"
        case .disconnected: "Disconnected"
        case .unavailable: "Unavailable"
        case .attention: "Needs attention"
        }
    }

    /// The colour of attention: the glyph, the tab highlight, the sidebar
    /// counts.
    static let attentionColor = Color.purple
}

/// The number of panes needing attention, as a small capsule (sidebar tab
/// group and workspace rows). Nothing when zero.
struct AttentionCount: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 14)
                .background(StatusGlyph.attentionColor, in: Capsule())
                .help(count == 1 ? "1 pane needs attention" : "\(count) panes need attention")
                .accessibilityLabel(count == 1 ? "1 pane needs attention" : "\(count) panes need attention")
        }
    }
}
