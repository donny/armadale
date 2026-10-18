import ArmadaleCore
import SwiftUI

/// The small host badge of a tab whose sessions run on an SSH host (tab bar
/// and sidebar): a network glyph, with the host's name in the sidebar.
/// Orange when such a session will not survive quitting (the host could not
/// take Armadale's persistence helper).
struct HostBadge: View {
    let hosts: [ArmadaleCore.Host]
    let persistenceNote: String?
    var showsName = false

    var body: some View {
        if let first = hosts.first {
            HStack(spacing: 3) {
                Image(systemName: persistenceNote == nil ? "network" : "exclamationmark.icloud")
                    .font(.system(size: 9, weight: .semibold))
                if showsName {
                    Text(hosts.count == 1 ? first.displayName : "\(first.displayName) +\(hosts.count - 1)")
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(persistenceNote == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            .help(help)
            .accessibilityLabel(help)
        }
    }

    private var help: String {
        let names = hosts.map { host in
            host.displayName == host.sshDestination ? host.displayName : "\(host.displayName) (\(host.sshDestination))"
        }.joined(separator: ", ")
        if let persistenceNote { return "On \(names). Not persistent: \(persistenceNote)" }
        return "On \(names)"
    }
}
