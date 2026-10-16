import SwiftUI

/// Shown over a pane's last terminal contents when its session has ended.
struct SessionPlaceholderView: View {
    let title: String
    /// Why the session could not be started, if that is why it ended.
    let failure: String?
    let respawn: () -> Void
    let closePane: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.18))
                .ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                Text("Session Ended")
                    .font(.title2.weight(.semibold))
                Text("The session “\(title)” is no longer running.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Button("Close Pane", action: closePane)
                    Button("Respawn", action: respawn)
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

#Preview {
    SessionPlaceholderView(title: "zsh", failure: nil, respawn: {}, closePane: {})
        .frame(width: 640, height: 400)
}
