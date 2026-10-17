import SwiftUI

/// The status glyph of a tab (tab bar and sidebar): running, pending,
/// ended, disconnected or unavailable.
struct StatusGlyph: View {
    let status: SessionStatus

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 12)
            .help(help)
            .accessibilityLabel(help)
    }

    private var symbol: String {
        switch status {
        case .running: "circle.fill"
        case .pending: "circle.dotted"
        case .ended: "circle"
        case .disconnected: "exclamationmark.triangle.fill"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    private var size: CGFloat {
        switch status {
        case .running, .pending, .ended: 7
        case .disconnected, .unavailable: 9
        }
    }

    private var color: Color {
        switch status {
        case .running: .green
        case .pending, .ended: .secondary
        case .disconnected: .orange
        case .unavailable: .yellow
        }
    }

    private var help: String {
        switch status {
        case .running: "Running"
        case .pending: "Starting"
        case .ended: "Ended"
        case .disconnected: "Disconnected"
        case .unavailable: "Unavailable"
        }
    }
}
