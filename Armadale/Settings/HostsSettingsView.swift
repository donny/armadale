import SwiftUI

/// Settings › Hosts. SSH hosts arrive with remote sessions (DESIGN §12,
/// step 6); until then the tab only says so.
struct HostsSettingsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("Remote hosts are coming")
                .font(.headline)
            Text("A later version of Armadale will let you add SSH hosts here and open sessions on them that keep running on the host, just like local ones. Hosts from your SSH configuration will work by name.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
