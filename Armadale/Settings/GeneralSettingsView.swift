import AppKit
import ArmadaleCore
import SwiftUI

/// Settings › General: default profile, default directory, notifications,
/// close confirmation.
struct GeneralSettingsView: View {
    let model: AppModel
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Default profile", selection: defaultProfile) {
                    ForEach(model.profiles) { profile in
                        Label(profile.name, systemImage: ProfileIcon.symbol(profile.icon)).tag(profile.id)
                    }
                }
                LabeledContent("Default directory") {
                    HStack {
                        TextField("Default directory", text: $preferences.defaultWorkingDirectory, prompt: Text("Home folder"))
                            .labelsHidden()
                        Button("Choose…", action: chooseDirectory)
                    }
                }
                if let problem = directoryProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("New tabs, tab groups and windows (⌘T, ⇧⌘N, ⌘N) use this profile and start in this directory. Splitting a pane keeps the pane’s own profile and directory.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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
            } footer: {
                Text("Armadale always reopens your windows at launch and reconnects to the sessions in them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The preference, shown as the shell if it names a deleted profile
    /// (which is what new tabs then get).
    private var defaultProfile: Binding<ProfileID> {
        Binding {
            let id = preferences.defaultProfileID
            return model.profile(id) == nil ? Profile.shell.id : id
        } set: { preferences.defaultProfileID = $0 }
    }

    private var directoryProblem: String? {
        guard !preferences.defaultWorkingDirectory.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let path = preferences.resolvedWorkingDirectory()
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/") else { return "Use a full path (starting with / or ~)." }
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "This folder doesn’t exist; new sessions start in your home folder instead."
        }
        return nil
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder new sessions start in."
        panel.directoryURL = URL(fileURLWithPath: preferences.resolvedWorkingDirectory(), isDirectory: true)
        let preferences = preferences
        let apply: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            preferences.defaultWorkingDirectory = ProfileIcon.abbreviatingHome(url.path)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { apply(response) }
            }
        } else {
            apply(panel.runModal())
        }
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
