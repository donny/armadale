import ArmadaleCore
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
        /// Disconnected, and Armadale is retrying by itself (a remote host
        /// that may come back).
        case reconnecting
        /// Persistent sessions cannot be reached in this run.
        case unavailable
        /// The session's host was removed from Settings; it may still be
        /// running there and is left alone.
        case hostRemoved
    }

    let kind: Kind
    let title: String
    /// Why the session could not be started, if that is why it ended.
    let failure: String?
    /// How the ended program ended, when that is known.
    var exitStatus: ProgramExit?
    /// Whether Return presses the primary button: only in the focused pane
    /// (or the only one on screen), so Return typed into another pane's
    /// terminal never respawns or reconnects this one.
    var isDefaultActionEnabled = true
    /// Respawn, Reconnect or Retry.
    let primary: () -> Void
    let closePane: () -> Void
    /// A click on the dimmed pane around the card focuses the pane, as a
    /// click on a live terminal does (and so gives Return to the button).
    var focusPane: () -> Void = {}

    private var heading: String {
        switch kind {
        case .ended: "Session Ended"
        case .disconnected: "Disconnected"
        case .reconnecting: "Reconnecting…"
        case .unavailable: "Persistent sessions are unavailable"
        case .hostRemoved: "Host removed"
        }
    }

    private var message: String {
        switch kind {
        case .ended:
            switch exitStatus {
            case .exited(let status)?: "The session “\(title)” exited with status \(status)."
            case .signaled(let signal)?: "The session “\(title)” was ended by signal \(signal) (status \(128 + signal))."
            case nil: "The session “\(title)” is no longer running."
            }
        case .disconnected: "Armadale lost its connection to this session. It may still be running."
        case .reconnecting: "Armadale lost its connection to this session and keeps trying to reconnect. "
            + "The session may still be running."
        case .hostRemoved: "The host the session “\(title)” runs on was removed from Settings › Hosts. It may still be "
            + "running there and has been left alone."
        case .unavailable: "Armadale could not start the service that keeps sessions running, so the session "
            + "“\(title)” can’t be reached right now. It may still be running and has been left alone."
        }
    }

    private var primaryTitle: String {
        switch kind {
        case .ended: "Respawn"
        case .disconnected: "Reconnect"
        case .reconnecting: "Reconnect Now"
        case .unavailable, .hostRemoved: "Retry"
        }
    }

    private var symbol: String {
        switch kind {
        case .ended: "terminal"
        case .disconnected, .reconnecting: "bolt.horizontal.circle"
        case .unavailable: "exclamationmark.triangle"
        case .hostRemoved: "network.slash"
        }
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.18))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: focusPane)
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
                if kind == .reconnecting {
                    ProgressView().controlSize(.small)
                }
                if let failure, kind != .unavailable, kind != .hostRemoved {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    // An unavailable session cannot be ended from here: its
                    // runtime is unreachable, and closing would orphan it.
                    // One whose host was removed can only be closed (the
                    // close confirmation says it is left running).
                    if kind != .unavailable {
                        Button("Close Pane", action: closePane)
                    }
                    if kind != .hostRemoved {
                        Button(primaryTitle, action: primary)
                            .keyboardShortcut(isDefaultActionEnabled ? .defaultAction : nil)
                    }
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

#Preview("Ended with a status") {
    SessionPlaceholderView(kind: .ended, title: "zsh", failure: nil, exitStatus: 1, primary: {}, closePane: {})
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
