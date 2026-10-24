import AppKit
import ArmadaleCore
import Combine
import SwiftUI

/// Settings › Favorites (DESIGN §8, "New sessions"): the saved session
/// recipes, in the order the chooser shows them. Drag to reorder; "+"
/// opens the New Session form as "New Favorite" in a sheet; "−" removes.
/// The selected favorite is edited on the right with the same form, saved
/// when a field's editing ends (as in Hosts), never per keystroke. A broken
/// favorite (its host or profile is gone) shows why, and its editor lets
/// another host or profile be picked.
struct FavoritesSettingsView: View {
    let model: AppModel
    /// Add Host…: switches to Settings › Hosts.
    let showHosts: @MainActor () -> Void
    @State private var selection: FavoriteID?
    @State private var newFavorite: NewSessionForm?

    init(model: AppModel, showHosts: @escaping @MainActor () -> Void) {
        self.model = model
        self.showHosts = showHosts
        _selection = State(initialValue: model.favorites.first?.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.favorites) { favorite in
                        FavoriteRow(model: model, favorite: favorite)
                            .tag(favorite.id)
                    }
                    .onMove { source, destination in
                        move(source, to: destination)
                    }
                }
                .listStyle(.bordered)
                HStack(spacing: 2) {
                    Button {
                        newFavorite = NewSessionForm(model: model, mode: .newFavorite)
                    } label: {
                        Image(systemName: "plus").frame(width: 22, height: 18)
                    }
                    .help("New Favorite")
                    Button {
                        guard let selection else { return }
                        remove(selection)
                    } label: {
                        Image(systemName: "minus").frame(width: 22, height: 18)
                    }
                    .help("Remove Favorite")
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 6)
            }
            .frame(width: 230)
            .padding([.leading, .vertical], 20)

            if let favorite = selection.flatMap({ model.favorite($0) }) {
                FavoriteEditor(model: model, favorite: favorite, showHosts: showHosts)
                    .id(favorite.id)
            } else {
                emptyState
            }
        }
        // A quit ends the sheet (AppDelegate.prepareForQuit).
        .onReceive(NotificationCenter.default.publisher(for: .armadaleWillQuit)) { _ in newFavorite = nil }
        .sheet(item: $newFavorite) { form in
            NewSessionSheet(
                form: form, showHosts: showHosts,
                onCancel: { newFavorite = nil },
                onConfirm: {
                    // Once: Return and the button could both arrive.
                    guard newFavorite === form else { return }
                    if let id = form.save() { selection = id }
                    newFavorite = nil
                })
            // Shrinks again when rows go (SSH → Local); the SwiftUI sheet
            // otherwise keeps its largest height.
            .presentationSizing(.fitted)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "star")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.favorites.isEmpty ? "No Favorites" : "Select a favorite")
                .font(.headline)
            if model.favorites.isEmpty {
                Text("A favorite saves a session’s location, directory, profile and options under a name, so a new pane can start it in one step. Add one here, or turn on Add to Favorites in the New Session dialog.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
                Button("New Favorite") { newFavorite = NewSessionForm(model: model, mode: .newFavorite) }
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `List`'s move: `destination` counts the rows before the move;
    /// ``AppModel/moveFavorite(_:to:)`` counts after removing the moved one.
    private func move(_ source: IndexSet, to destination: Int) {
        let favorites = model.favorites
        guard let from = source.first, favorites.indices.contains(from) else { return }
        model.moveFavorite(favorites[from].id, to: destination > from ? destination - 1 : destination)
    }

    private func remove(_ id: FavoriteID) {
        let index = model.favorites.firstIndex { $0.id == id } ?? 0
        model.removeFavorite(id)
        let remaining = model.favorites
        selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }
}

extension NewSessionForm: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// One favorite in the list: its profile's icon, its name, and where it
/// runs, or why it cannot start.
private struct FavoriteRow: View {
    let model: AppModel
    let favorite: Favorite

    var body: some View {
        let problem = model.favoriteProblem(favorite)
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(favorite.name)
                    .foregroundStyle(problem == nil ? Color.primary : Color.secondary)
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: problem == nil
                ? ProfileIcon.symbol(model.profile(favorite.request.profileID)?.icon ?? "")
                : "exclamationmark.triangle")
        }
    }

    /// "This Mac · ~/work", "lima-default · ~".
    private var place: String {
        let request = favorite.request
        let directory = request.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = directory.isEmpty ? "~" : directory
        switch request.location {
        case .local:
            return "This Mac · \(ProfileIcon.abbreviatingHome(shown, home: model.defaultWorkingDirectory))"
        case .remote(let host):
            return "\(model.host(host)?.displayName ?? "Host") · \(shown)"
        }
    }
}

/// Edits one favorite with the New Session form, saved when a field's
/// editing ends, a choice changes, and when the editor goes away.
private struct FavoriteEditor: View {
    @State private var form: NewSessionForm
    let showHosts: @MainActor () -> Void

    init(model: AppModel, favorite: Favorite, showHosts: @escaping @MainActor () -> Void) {
        _form = State(initialValue: NewSessionForm(model: model, mode: .editFavorite(favorite.id)))
        self.showHosts = showHosts
    }

    var body: some View {
        Form {
            NewSessionFormFields(form: form, showHosts: showHosts, commit: commit)
            if let problem = form.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } footer: {
                    Text("This favorite can’t be started until this is fixed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { commit() }
    }

    private func commit() {
        form.save()
    }
}
