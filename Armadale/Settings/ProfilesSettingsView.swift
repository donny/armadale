import AppKit
import ArmadaleCore
import SwiftUI

/// Settings › Profiles: the list of launch profiles (add, duplicate,
/// delete) and an editor for the selected one. Profiles are part of the
/// model, so every edit goes through an ``AppModel`` intent and is saved
/// with the layout. Built-in profiles can only be renamed and given another
/// icon; duplicate one to change what it runs.
struct ProfilesSettingsView: View {
    let model: AppModel
    @State private var selection: ProfileID? = Profile.shell.id

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.profiles) { profile in
                        Label {
                            Text(profile.name)
                        } icon: {
                            Image(systemName: ProfileIcon.symbol(profile.icon))
                        }
                        .tag(profile.id)
                    }
                }
                .listStyle(.bordered)
                HStack(spacing: 2) {
                    Button {
                        selection = model.newProfile()
                    } label: {
                        Image(systemName: "plus").frame(width: 22, height: 18)
                    }
                    .help("New Profile")
                    Button {
                        guard let selection else { return }
                        removeSelected(selection)
                    } label: {
                        Image(systemName: "minus").frame(width: 22, height: 18)
                    }
                    .help("Delete Profile")
                    .disabled(selectedProfile?.isBuiltIn ?? true)
                    Button {
                        guard let id = selection else { return }
                        selection = model.duplicateProfile(id) ?? id
                    } label: {
                        Image(systemName: "plus.square.on.square").frame(width: 22, height: 18)
                    }
                    .help("Duplicate Profile")
                    .disabled(selectedProfile == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 6)
            }
            .frame(width: 210)
            .padding([.leading, .vertical], 20)

            if let profile = selectedProfile {
                ProfileEditor(model: model, profile: profile)
                    .id(profile.id)
            } else {
                Text("Select a profile")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var selectedProfile: Profile? {
        selection.flatMap { model.profile($0) }
    }

    private func removeSelected(_ id: ProfileID) {
        let index = model.profiles.firstIndex { $0.id == id } ?? 0
        guard model.deleteProfile(id) else { return }
        let remaining = model.profiles
        selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }
}

/// Edits one profile. Works on a draft that is written to the model on every
/// change (the model cleans it up: blank names, icons and programs).
private struct ProfileEditor: View {
    let model: AppModel
    @State private var draft: Profile
    @State private var argumentsText: String
    @State private var environment: [EnvironmentRow]
    @State private var agentName: String

    init(model: AppModel, profile: Profile) {
        self.model = model
        _draft = State(initialValue: profile)
        _argumentsText = State(initialValue: profile.arguments.joined(separator: "\n"))
        _environment = State(initialValue: profile.environment.sorted { $0.key < $1.key }.map {
            EnvironmentRow(key: $0.key, value: $0.value)
        })
        if case .agent(.other(let name)) = profile.kind {
            _agentName = State(initialValue: name)
        } else {
            _agentName = State(initialValue: "")
        }
    }

    private var isBuiltIn: Bool { draft.isBuiltIn }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                LabeledContent("Icon") {
                    HStack {
                        Image(systemName: ProfileIcon.symbol(draft.icon))
                            .frame(width: 22)
                            .foregroundStyle(ProfileIcon.isValid(draft.icon) ? Color.primary : Color.secondary)
                        TextField("Icon", text: $draft.icon, prompt: Text("SF Symbol name"))
                            .labelsHidden()
                    }
                }
                if !ProfileIcon.isValid(draft.icon) {
                    Text("There is no SF Symbol called “\(draft.icon)”. Names look like “terminal” or “sparkle”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Kind", selection: kind) {
                    ForEach(KindChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                if case .agent(.other) = draft.kind {
                    TextField("Agent", text: $agentName, prompt: Text("e.g. aider"))
                }
                TextField("Program", text: program, prompt: Text(draft.kind == .shell ? "Login shell" : "Name or full path"))
                LabeledContent("Arguments") {
                    TextEditor(text: $argumentsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 54)
                        .scrollContentBackground(.hidden)
                }
            } footer: {
                Text(isBuiltIn
                    ? "Built-in profiles can be renamed and given another icon. To change what one runs, duplicate it."
                    : "One argument per line. A program without a path is looked up on your login shell’s PATH; leave it empty for your login shell.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .disabled(isBuiltIn)

            Section {
                ForEach($environment) { $row in
                    VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Name", text: $row.key, prompt: Text("NAME"))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                        Text("=").foregroundStyle(.secondary)
                        TextField("Value", text: $row.value, prompt: Text("value"))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                        Button {
                            environment.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove Variable")
                    }
                    if let problem = row.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    }
                }
                Button("Add Variable") {
                    environment.append(EnvironmentRow(key: "", value: ""))
                }
            } header: {
                Text("Environment")
            } footer: {
                Text("Changes apply to new sessions, and to a running session when it is respawned. Variables with a problem are not saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .disabled(isBuiltIn)
        }
        .formStyle(.grouped)
        .onChange(of: draft) { commit() }
        .onChange(of: argumentsText) { commit() }
        .onChange(of: environment) { commit() }
        .onChange(of: agentName) {
            if case .agent(.other) = draft.kind { draft.kind = .agent(.other(agentFlavorName)) }
        }
    }

    private var agentFlavorName: String {
        let name = agentName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "agent" : name
    }

    private func commit() {
        var profile = draft
        profile.arguments = argumentsText.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        var variables: [String: String] = [:]
        for row in environment { variables[row.key.trimmingCharacters(in: .whitespaces)] = row.value }
        profile.environment = variables
        model.updateProfile(profile)
    }

    private var program: Binding<String> {
        Binding { draft.program ?? "" } set: { draft.program = $0 }
    }

    private var kind: Binding<KindChoice> {
        Binding { KindChoice(draft.kind) } set: { choice in
            draft.kind = choice.kind(agentName: agentFlavorName)
        }
    }
}

private struct EnvironmentRow: Identifiable, Hashable {
    let id = UUID()
    var key: String
    var value: String

    /// Why this row will not be saved (``Profile/environmentNameProblem(_:)``);
    /// nothing for a row that is still completely empty.
    var problem: String? {
        if key.isEmpty, value.isEmpty { return nil }
        return Profile.environmentNameProblem(key.trimmingCharacters(in: .whitespaces))
    }
}

/// ``Profile/Kind`` as a flat list for the picker.
private enum KindChoice: String, CaseIterable, Identifiable {
    case shell, command, claudeCode, codex, otherAgent

    var id: String { rawValue }

    init(_ kind: Profile.Kind) {
        switch kind {
        case .shell: self = .shell
        case .command: self = .command
        case .agent(.claudeCode): self = .claudeCode
        case .agent(.codex): self = .codex
        case .agent(.other): self = .otherAgent
        }
    }

    var title: String {
        switch self {
        case .shell: "Shell"
        case .command: "Command"
        case .claudeCode: "Agent: Claude Code"
        case .codex: "Agent: Codex"
        case .otherAgent: "Agent: Other"
        }
    }

    func kind(agentName: String) -> Profile.Kind {
        switch self {
        case .shell: .shell
        case .command: .command
        case .claudeCode: .agent(.claudeCode)
        case .codex: .agent(.codex)
        case .otherAgent: .agent(.other(agentName))
        }
    }
}
