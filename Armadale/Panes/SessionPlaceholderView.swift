import SwiftUI

/// Shown over a pane's last terminal contents when its session is not
/// connected: ended (Respawn), disconnected (Reconnect), or unavailable
/// because the persistent runtime could not be set up (Retry).
struct SessionPlaceholderView: View {
    enum Kind {
        /// The session's program exited, or the session is gone.
        case ended
        /// Armadale lost its connection; the session may still be running.
        case disconnected
        /// Persistent sessions cannot be reached in this run.
        case unavailable
    }

    let kind: Kind
    let title: String
    /// Why the session could not be started, if that is why it ended.
    let failure: String?
    /// Respawn, Reconnect or Retry.
    let primary: () -> Void
    let closePane: () -> Void

    private var heading: String {
        switch kind {
        case .ended: "Session Ended"
        case .disconnected: "Disconnected"
        case .unavailable: "Persistent sessions are unavailable"
        }
    }

    private var message: String {
        switch kind {
        case .ended: "The session “\(title)” is no longer running."
        case .disconnected: "Armadale lost its connection to this session. It may still be running."
        case .unavailable: "Armadale could not start the service that keeps sessions running, so the session "
            + "“\(title)” can’t be reached right now. It may still be running and has been left alone."
        }
    }

    private var primaryTitle: String {
        switch kind {
        case .ended: "Respawn"
        case .disconnected: "Reconnect"
        case .unavailable: "Retry"
        }
    }

    private var symbol: String {
        switch kind {
        case .ended: "terminal"
        case .disconnected: "bolt.horizontal.circle"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.18))
                .ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                Text(heading)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let failure, kind != .unavailable {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    // An unavailable session cannot be ended from here: its
                    // runtime is unreachable, and closing would orphan it.
                    if kind != .unavailable {
                        Button("Close Pane", action: closePane)
                    }
                    Button(primaryTitle, action: primary)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                .padding(.top, 8)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .frame(maxWidth: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
            .padding(24)
        }
    }
}

#Preview("Ended") {
    SessionPlaceholderView(kind: .ended, title: "zsh", failure: nil, primary: {}, closePane: {})
        .frame(width: 640, height: 400)
}

#Preview("Disconnected") {
    SessionPlaceholderView(kind: .disconnected, title: "zsh", failure: nil, primary: {}, closePane: {})
        .frame(width: 640, height: 400)
}

#Preview("Unavailable") {
    SessionPlaceholderView(kind: .unavailable, title: "zsh", failure: nil, primary: {}, closePane: {})
        .frame(width: 640, height: 400)
}
