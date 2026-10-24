import AppKit
import ArmadaleCore
import SwiftUI

/// The New Session dialog (DESIGN §8, "New sessions"): a sheet on the
/// workspace window (``WorkspaceActions/newSession(in:)``), and in its
/// favorite modes ("New Favorite", "Edit Favorite") a sheet in Settings ›
/// Favorites. The rules are ``NewSessionForm``'s; this is only the view.
/// Return presses Start (or Save) while the form is valid; Escape cancels.
struct NewSessionSheet: View {
    @Bindable var form: NewSessionForm
    /// Add Host…: opens Settings › Hosts; the sheet stays.
    let showHosts: @MainActor () -> Void
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
                NewSessionFormFields(form: form, showHosts: showHosts, commit: {}, submit: confirm)
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
                .disabled(!form.isValid)
            }
            .padding(20)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func confirm() {
        guard form.isValid else { return }
        onConfirm()
    }
}

/// The dialog's fields, shared by the sheet and the Settings › Favorites
/// editor. `commit` is called when a field's editing ends (focus leaves a
/// text field, Return) and whenever a picker, toggle or the Location
/// changes, which is when the Favorites editor saves; the sheet passes a
/// no-op and saves on its button. `submit` is Return in a text field (after
/// `commit`): the sheet's Start or Save, nothing more in the editor.
struct NewSessionFormFields: View {
    @Bindable var form: NewSessionForm
    let showHosts: @MainActor () -> Void
    let commit: @MainActor () -> Void
    var submit: @MainActor () -> Void = {}
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case name, directory, model, arguments
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
                    HStack {
                        hostPicker
                        Button("Add Host…", action: showHosts)
                    }
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
            // Attached once, to a row that is always shown: editing ended
            // (focus left a text field, or Return), and every choice that
            // is not typed.
            .onSubmit { commit(); submit() }
            .onChange(of: focus) { commit() }
            .onChange(of: form.model.hosts.map(\.id)) { form.hostsDidChange() }
            .onChange(of: form.isRemote) { commit() }
            .onChange(of: form.selectedHostID) { commit() }
            .onChange(of: form.profileID) { commit() }
            .onChange(of: form.skipPermissions) { commit() }
            .onChange(of: form.continueConversation) { commit() }
            .onChange(of: form.sandbox) { commit() }
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
                                .onSubmit { commit(); submit() }
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
                                .onSubmit { commit(); submit() }
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
            .onSubmit { commit(); submit() }
    }

    private var hostPicker: some View {
        Picker("Host", selection: $form.selectedHostID) {
            if form.model.hosts.isEmpty {
                Text("No Hosts").tag(HostID?.none)
            } else if form.selectedHostID == nil {
                Text("Choose a Host").tag(HostID?.none)
            }
            if form.hostIsMissing, let missing = form.selectedHostID {
                Text("Host removed").tag(Optional(missing))
            }
            ForEach(form.model.hosts) { host in
                Text(host.displayName).tag(Optional(host.id))
            }
        }
        .labelsHidden()
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
        let commit = commit
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            form.workingDirectory = ProfileIcon.abbreviatingHome(url.path(percentEncoded: false), home: home)
            commit()
        }
        // A sheet on the window the form is in (the New Session sheet, or
        // Settings), so the panel cannot outlive it.
        guard let window = NSApp.keyWindow else {
            panel.begin { response in MainActor.assumeIsolated { finish(response) } }
            return
        }
        panel.beginSheetModal(for: window) { response in MainActor.assumeIsolated { finish(response) } }
    }
}
