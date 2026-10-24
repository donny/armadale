import AppKit
import ArmadaleCore
import SwiftUI

/// Settings › General: notifications, close confirmation, quitting with
/// running sessions. (The default profile and directory went with step 10:
/// every new pane asks, DESIGN §8 "New sessions".)
struct GeneralSettingsView: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Notify when an unfocused pane needs attention", isOn: $preferences.notifyOnAttention)
                Toggle("Only for agent profiles", isOn: $preferences.notifyOnlyForAgents)
                    .disabled(!preferences.notifyOnAttention)
                Toggle("Play sound", isOn: $preferences.notificationPlaysSound)
                    .disabled(!preferences.notifyOnAttention)
            } header: {
                Text("Notifications")
            } footer: {
                Text("A pane needs attention when its program rings the bell or posts a notification while you aren’t looking at it. Its tab shows ◐, and the Dock icon counts them. Armadale asks for permission to show notifications the first time it has one to show.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Ask before closing a pane with a running process", isOn: $preferences.confirmClosingRunningSession)
                Picker("When quitting with running sessions", selection: $preferences.quitWithRunningSessions) {
                    ForEach(Preferences.QuitWithRunningSessions.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
            } footer: {
                Text("Armadale always reopens your windows at launch and reconnects to the sessions in them. Sessions kept running in the menu bar can be reopened or ended from Armadale’s icon there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Small helpers shared by the settings tabs.
enum ProfileIcon {
    /// `name` if it is an SF Symbol, else a placeholder symbol.
    static func symbol(_ name: String) -> String {
        isValid(name) ? name : "questionmark.square.dashed"
    }

    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// `/Users/me/x` → `~/x`.
    static func abbreviatingHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
