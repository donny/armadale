import AppKit
import ArmadaleCore
import SwiftUI

/// The New Session dialog (DESIGN §8, "New sessions"): a sheet on the
/// workspace window, for a new session (``WorkspaceActions/newSession(in:)``)
/// and in its favorite modes, "New Favorite" (the pane menu's Save as
/// Favorite…, ``WorkspaceActions/saveAsFavorite(fromSession:)``) and "Edit
/// Favorite" (the chooser's Edit…). The rules are ``NewSessionForm``'s;
/// this is only the view. Return presses Start while the form is valid
/// (Save while it can be saved, ``NewSessionForm/canConfirm``); Escape
/// cancels.
struct NewSessionSheet: View {
    @Bindable var form: NewSessionForm
    let onCancel: @MainActor () -> Void
    /// Start or Save was pressed and the form is valid.
    let onConfirm: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(form.title)
                .font(.headline)
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 8)
            Form {
                // Return in a text field presses Start (or Save): the field
                // takes the key before the default button sees it.
                NewSessionFormFields(form: form, submit: confirm)
            }
            .formStyle(.columns)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            HStack(alignment: .firstTextBaseline) {
                if let problem = form.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(form.primaryButtonTitle, action: confirm)
                .keyboardShortcut(.defaultAction)
                .disabled(!form.canConfirm)
            }
            .padding(20)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func confirm() {
        guard form.canConfirm else { return }
        onConfirm()
    }
}

/// The dialog's fields. `submit` is Return in a text field: the sheet's
/// Start or Save.
struct NewSessionFormFields: View {
    @Bindable var form: NewSessionForm
    var submit: @MainActor () -> Void = {}
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case name, destination, directory, model, arguments
    }

    var body: some View {
        Section {
            if form.isFavoriteMode {
                nameField
            }
            Picker("Location", selection: $form.isRemote) {
                Text("Local").tag(false)
                Text("SSH").tag(true)
            }
            .pickerStyle(.segmented)
            if form.isRemote {
                LabeledContent("Host") {
                    hostPicker
                }
                if form.isAddingHost {
                    destinationField
                }
            }
            LabeledContent("Directory") {
                HStack {
                    TextField("Directory", text: $form.workingDirectory, prompt: Text(form.directoryPrompt))
                        .labelsHidden()
                        .autocorrectionDisabled()
                        .focused($focus, equals: .directory)
                    if !form.isRemote {
                        Button("Choose…") { chooseDirectory() }
                    }
                }
            }
            // Attached once, to a row that is always shown.
            .onSubmit(submit)
            .onChange(of: form.model.hosts.map(\.id)) { form.hostsDidChange() }
            // New Host… (chosen, or picked at once when SSH has no host
            // saved) gives the Destination field keyboard focus, once it
            // is in the form.
            .onChange(of: form.isAddingHost) { _, adding in
                guard adding else { return }
                Task { @MainActor in focus = .destination }
            }
            profilePicker
        }

        if form.showsAgentOptions || form.showsAdditionalArguments {
            Section {
                if let row = form.skipPermissionsRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(row.title, isOn: $form.skipPermissions)
                        flagNote(row.flag)
                    }
                    .help("Adds \(row.flag)")
                }
                if let row = form.continueRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(row.title, isOn: $form.continueConversation)
                        flagNote(row.flag)
                    }
                    .help("Adds \(row.flag)")
                }
                if let row = form.sandboxRow {
                    Picker(row.title, selection: $form.sandbox) {
                        Text("Default").tag("")
                        ForEach(form.sandboxModes, id: \.self) { mode in
                            Text(mode).tag(mode)
                        }
                    }
                    .help("Adds \(row.flag) <mode>; Default adds nothing")
                }
                if let row = form.modelRow {
                    LabeledContent(row.title) {
                        VStack(alignment: .leading, spacing: 2) {
                            TextField(row.title, text: $form.modelName, prompt: Text(form.modelPrompt))
                                .labelsHidden()
                                .autocorrectionDisabled()
                                .focused($focus, equals: .model)
                                .onSubmit(submit)
                            flagNote("\(row.flag) <model>; empty adds nothing")
                        }
                    }
                }
                if form.showsAdditionalArguments {
                    LabeledContent("Additional arguments") {
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Additional arguments", text: $form.additionalArguments, prompt: Text("Optional"))
                                .labelsHidden()
                                .autocorrectionDisabled()
                                .font(.system(.body, design: .monospaced))
                                .focused($focus, equals: .arguments)
                                .onSubmit(submit)
                            flagNote("Added last, split like a shell: spaces separate, quotes group")
                        }
                    }
                }
            } header: {
                Text("Options")
            }
        }

        if !form.isFavoriteMode {
            Section {
                Toggle("Add to Favorites", isOn: $form.addToFavorites)
                if form.addToFavorites {
                    nameField
                }
            }
        }
    }

    private var nameField: some View {
        TextField("Name", text: $form.name)
            .focused($focus, equals: .name)
            .onSubmit(submit)
    }

    /// The saved hosts, then New Host…, after a divider when anything is
    /// above it. "Choose a Host" only while nothing is chosen; a favorite's
    /// removed host as "Host removed".
    private var hostPicker: some View {
        let hasItemsAbove = form.hostChoice == .unchosen || form.hostIsMissing || !form.model.hosts.isEmpty
        return Picker("Host", selection: $form.hostChoice) {
            if form.hostChoice == .unchosen {
                Text("Choose a Host").tag(NewSessionForm.HostChoice.unchosen)
            }
            if form.hostIsMissing, let missing = form.selectedHostID {
                Text("Host removed").tag(NewSessionForm.HostChoice.host(missing))
            }
            ForEach(form.model.hosts) { host in
                Text(host.displayName).tag(NewSessionForm.HostChoice.host(host.id))
            }
            if hasItemsAbove {
                Divider()
            }
            Text("New Host…").tag(NewSessionForm.HostChoice.newHost)
        }
        .labelsHidden()
    }

    /// New Host…'s destination: `user@host` or an alias from the ssh
    /// configuration, which are offered while typing. Return confirms
    /// like the other fields.
    private var destinationField: some View {
        LabeledContent("Destination") {
            VStack(alignment: .leading, spacing: 2) {
                TextField(
                    "Destination", text: $form.newHostDestination,
                    prompt: Text("user@example.com or an SSH alias"))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .focused($focus, equals: .destination)
                    .onSubmit(submit)
                    .textInputSuggestions {
                        ForEach(form.aliasSuggestions, id: \.self) { alias in
                            Text(alias).textInputCompletion(alias)
                        }
                    }
                flagNote("Saved as a host when you \(form.isFavoriteMode ? "save" : "start"); port, key and other settings are in Settings › Hosts")
            }
        }
    }

    private var profilePicker: some View {
        Picker("Profile", selection: $form.profileID) {
            if form.profileIsMissing {
                Text("Profile removed").tag(form.profileID)
            }
            ForEach(form.model.profiles) { profile in
                Label(profile.name, systemImage: ProfileIcon.symbol(profile.icon))
                    .tag(profile.id)
            }
        }
    }

    private func flagNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// An open panel for a folder, starting at the field's directory; the
    /// home folder is written as `~`.
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        let home = form.model.defaultWorkingDirectory
        let typed = form.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = typed.isEmpty || typed == "~"
            ? home : (typed.hasPrefix("~/") ? home + typed.dropFirst() : typed)
        panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        let form = form
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            form.workingDirectory = ProfileIcon.abbreviatingHome(url.path(percentEncoded: false), home: home)
        }
        // A sheet on the window the form is in (the dialog's), so the panel
        // cannot outlive it.
        guard let window = NSApp.keyWindow else {
            panel.begin { response in MainActor.assumeIsolated { finish(response) } }
            return
        }
        panel.beginSheetModal(for: window) { response in MainActor.assumeIsolated { finish(response) } }
    }
}
