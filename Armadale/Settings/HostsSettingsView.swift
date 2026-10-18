import AppKit
import ArmadaleCore
import SwiftUI

/// What Settings › Hosts can do with a host besides editing it (the app
/// gives it the session registry's transport).
struct HostTools {
    /// Test Connection: a description of the host, or an error.
    var testConnection: @MainActor (ArmadaleCore.Host) async throws -> String
    /// Deploy Now: installs Armadale's persistence helper on the host.
    var deploy: @MainActor (ArmadaleCore.Host) async throws -> String

    /// For windows made without remote support (tests).
    static let unavailable = HostTools(
        testConnection: { _ in throw HostToolsUnavailable() },
        deploy: { _ in throw HostToolsUnavailable() })
}

private struct HostToolsUnavailable: Error, CustomStringConvertible {
    var description: String { "Remote sessions are not available in this run." }
}

/// Settings › Hosts (docs/DESIGN.md section 8): the SSH hosts sessions can
/// run on, with add / remove and an editor. Hosts are part of the model
/// (saved with the layout), so every edit goes through an ``AppModel``
/// intent. Removing a host that sessions run on asks first; those sessions
/// are left running on the host and become unavailable, never killed.
struct HostsSettingsView: View {
    let model: AppModel
    let tools: HostTools
    @State private var selection: HostID?
    @State private var pendingRemoval: HostID?

    init(model: AppModel, tools: HostTools) {
        self.model = model
        self.tools = tools
        _selection = State(initialValue: model.hosts.first?.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.hosts) { host in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(host.displayName)
                                if host.displayName != host.sshDestination, !host.sshDestination.isEmpty {
                                    Text(host.sshDestination)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "network")
                        }
                        .tag(host.id)
                    }
                }
                .listStyle(.bordered)
                HStack(spacing: 2) {
                    Button {
                        selection = model.addHost()
                    } label: {
                        Image(systemName: "plus").frame(width: 22, height: 18)
                    }
                    .help("Add Host")
                    Button {
                        guard let selection else { return }
                        requestRemoval(selection)
                    } label: {
                        Image(systemName: "minus").frame(width: 22, height: 18)
                    }
                    .help("Remove Host")
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 6)
            }
            .frame(width: 210)
            .padding([.leading, .vertical], 20)

            if let host = selectedHost {
                HostEditor(model: model, host: host, tools: tools)
                    .id(host.id)
            } else {
                emptyState
            }
        }
        .alert(removalTitle, isPresented: isConfirmingRemoval, presenting: pendingRemoval) { id in
            Button("Remove", role: .destructive) { remove(id) }
            Button("Cancel", role: .cancel) {}
        } message: { id in
            Text(removalMessage(for: id))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Hosts")
                .font(.headline)
            Text("Add an SSH host to open sessions on it that keep running there, like local ones, while Armadale is closed. Hosts from your SSH configuration work by name.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("Add Host") { selection = model.addHost() }
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedHost: ArmadaleCore.Host? {
        selection.flatMap { model.host($0) }
    }

    // MARK: Removing

    private func requestRemoval(_ id: HostID) {
        if model.sessionIDs(onHost: id).isEmpty {
            remove(id)
        } else {
            pendingRemoval = id
        }
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding { pendingRemoval != nil } set: { if !$0 { pendingRemoval = nil } }
    }

    private var removalTitle: String {
        pendingRemoval.flatMap { model.host($0) }.map { "Remove “\($0.displayName)”?" } ?? "Remove this host?"
    }

    private func removalMessage(for id: HostID) -> String {
        let count = model.sessionIDs(onHost: id).count
        let sessions = count == 1 ? "A session runs" : "\(count) sessions run"
        return "\(sessions) on this host. \(count == 1 ? "It stays" : "They stay") in \(count == 1 ? "its pane" : "their panes") and \(count == 1 ? "keeps" : "keep") running on the host, but Armadale won’t be able to reach \(count == 1 ? "it" : "them")."
    }

    private func remove(_ id: HostID) {
        let index = model.hosts.firstIndex { $0.id == id } ?? 0
        model.removeHost(id)
        let remaining = model.hosts
        selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        pendingRemoval = nil
    }
}

/// Edits one host. Works on a draft that is written to the model when a
/// field's editing ends (focus leaves it, Return, Choose…), before Test
/// Connection and Deploy Now, and when the editor goes away; never per
/// keystroke, so a half-typed destination never reaches the sessions.
private struct HostEditor: View {
    let model: AppModel
    let tools: HostTools
    @State private var draft: ArmadaleCore.Host
    @State private var portText: String
    @State private var status: Status?
    @State private var isWorking = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case name, destination, port, remoteDirectory
    }

    private enum Status: Equatable {
        case success(String)
        case failure(String)
    }

    init(model: AppModel, host: ArmadaleCore.Host, tools: HostTools) {
        self.model = model
        self.tools = tools
        _draft = State(initialValue: host)
        _portText = State(initialValue: host.port.map(String.init) ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text(draft.sshDestination.isEmpty ? "My Server" : draft.sshDestination))
                    .focused($focus, equals: .name)
                TextField("Destination", text: $draft.sshDestination, prompt: Text("user@example.com or a name from ~/.ssh/config"))
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .destination)
                if let problem = destinationProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                TextField("Port", text: $portText, prompt: Text("From your SSH configuration (22)"))
                    .focused($focus, equals: .port)
                if portIsInvalid {
                    Label("A port is a number from 1 to 65535.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                FileField(title: "Identity file", path: optional(\.identityFile), prompt: "From your SSH configuration", commit: commit)
                FileField(title: "SSH config file", path: optional(\.sshConfigFile), prompt: "~/.ssh/config", commit: commit)
            } header: {
                Text("Authentication")
            } footer: {
                Text("Armadale uses your own ssh, with your keys, agent and SSH configuration. A config file set here replaces ~/.ssh/config for this host. If ssh needs a passphrase, a password or a new host key, it asks in the session’s pane.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Remote folder", text: $draft.remoteDirectory, prompt: Text(ArmadaleCore.Host.defaultRemoteDirectory))
                    .focused($focus, equals: .remoteDirectory)
                if let problem = ArmadaleCore.Host.remoteDirectoryProblem(draft.remoteDirectory), !draft.remoteDirectory.isEmpty {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("On the Host")
            } footer: {
                Text("To keep sessions running on the host, Armadale installs its persistence helper in this folder and keeps the sessions’ files in it. It writes nothing anywhere else on the host. Linux and macOS hosts (ARM64 and x86-64) are supported; on others, sessions end when Armadale quits.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Test Connection") { run(tools.testConnection) }
                    Button("Deploy Now") { run(tools.deploy) }
                        .help("Install Armadale’s persistence helper on the host now, replacing any copy there")
                    if isWorking {
                        ProgressView().controlSize(.small).padding(.leading, 4)
                    }
                    Spacer()
                }
                .disabled(isWorking || destinationProblem != nil)
                if let status {
                    switch status {
                    case .success(let message):
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .textSelection(.enabled)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onSubmit { commit() }
        .onChange(of: focus) { commit() }
        .onDisappear { commit() }
    }

    private var destinationProblem: String? {
        ArmadaleCore.Host.destinationProblem(draft.sshDestination.trimmingCharacters(in: .whitespaces))
    }

    private var portIsInvalid: Bool {
        let text = portText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        guard let port = Int(text) else { return true }
        return !(1...65535).contains(port)
    }

    private func commit() {
        var host = draft
        host.port = Int(portText.trimmingCharacters(in: .whitespaces))
        guard let saved = model.host(host.id) else { return }
        let before = saved
        model.updateHost(host)
        if model.host(host.id) != before { status = nil }
    }

    private func optional(_ keyPath: WritableKeyPath<ArmadaleCore.Host, String?>) -> Binding<String> {
        Binding { draft[keyPath: keyPath] ?? "" } set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
    }

    private func run(_ action: @escaping @MainActor (ArmadaleCore.Host) async throws -> String) {
        commit()
        guard let host = model.host(draft.id) else { return }
        isWorking = true
        status = nil
        Task {
            do {
                status = .success(try await action(host))
            } catch {
                status = .failure(String(describing: error))
            }
            isWorking = false
        }
    }
}

/// A path text field with Choose… (an open panel that shows hidden files,
/// starting in ~/.ssh).
private struct FileField: View {
    let title: String
    @Binding var path: String
    let prompt: String
    /// Saves the host (when editing ends or a file was chosen).
    let commit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: $path, prompt: Text(prompt))
                    .labelsHidden()
                    .focused($isFocused)
                    .onChange(of: isFocused) { if !isFocused { commit() } }
                Button("Choose…") { choose() }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let ssh = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".ssh")
        panel.directoryURL = path.isEmpty ? ssh : URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let chosen = url.path(percentEncoded: false)
            let home = NSHomeDirectory()
            MainActor.assumeIsolated {
                path = chosen.hasPrefix(home + "/") ? "~" + chosen.dropFirst(home.count) : chosen
                commit()
            }
        }
    }
}
