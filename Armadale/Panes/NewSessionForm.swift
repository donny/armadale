import ArmadaleCore
import Foundation
import Observation

/// The state and rules of the New Session dialog (DESIGN §8, "New
/// sessions"), without any view: what is chosen, the ``SessionRequest`` it
/// makes, whether it can be started or saved, which options the chosen
/// profile offers, the favorite's name, and what Start and Save do. The
/// dialog (``NewSessionSheet``) and Settings › Favorites
/// (``FavoritesSettingsView``) show it; the tests drive it directly.
@MainActor
@Observable
final class NewSessionForm {
    /// What the form is for.
    enum Mode: Equatable {
        /// Start a session in this empty pane (Start), optionally saving a
        /// favorite of it too.
        case newSession(PaneID)
        /// Settings › Favorites' "+": a new favorite (Save), nothing started.
        case newFavorite
        /// Edit a saved favorite (Save), nothing started.
        case editFavorite(FavoriteID)
    }

    let model: AppModel
    let mode: Mode

    /// SSH (true) or this Mac (false).
    var isRemote: Bool
    /// The host picked, if any; it may name a host that was removed (a
    /// broken favorite). See ``selectedHostID``.
    var hostID: HostID?
    /// As typed; `""` or `~` is the home directory. A local one is shown
    /// with the home folder abbreviated to `~`; a remote one is the host's.
    var workingDirectory: String
    private var storedProfileID: ProfileID
    var skipPermissions = false
    var continueConversation = false
    /// The agent's model; blank is its default.
    var modelName = ""
    /// Codex's sandbox mode; `""` is Codex's default.
    var sandbox = ""
    /// One line, split like a shell (``ShellWords/split(_:)``).
    var additionalArguments = ""
    /// "Add to Favorites" (only in ``Mode/newSession(_:)``).
    var addToFavorites = false
    /// The name the user typed; `nil` while the name follows the proposal.
    private var customName: String?
    /// A broken favorite's options, kept while its profile is missing (no
    /// option rows can be shown for a profile that is gone).
    private let originalOptions: SessionOptions?

    /// A form for `mode`. A new session's directory is that of
    /// `directorySession` (the window's focused pane that has a session),
    /// else home; a favorite's fields are the favorite's.
    init(model: AppModel, mode: Mode, directorySession: SessionID? = nil) {
        self.model = model
        self.mode = mode
        knownHostIDs = model.hosts.map(\.id)
        let favorite: Favorite? = if case .editFavorite(let id) = mode { model.favorite(id) } else { nil }
        if let favorite {
            let request = favorite.request
            if case .remote(let host) = request.location {
                isRemote = true
                hostID = host
            } else {
                isRemote = false
                hostID = nil
            }
            workingDirectory = request.workingDirectory.isEmpty ? "~" : request.workingDirectory
            storedProfileID = request.profileID
            skipPermissions = request.options.skipPermissions
            continueConversation = request.options.continueConversation
            modelName = request.options.model ?? ""
            sandbox = request.options.sandbox ?? ""
            additionalArguments = Self.joinedShellWords(request.options.additionalArguments)
            originalOptions = request.options
            // A name that is what the dialog would propose keeps following
            // the choices; anything else is the user's.
            customName = favorite.name == model.proposedFavoriteName(for: request) ? nil : favorite.name
        } else {
            isRemote = false
            hostID = nil
            storedProfileID = Profile.shell.id
            originalOptions = nil
            if case .newSession = mode {
                workingDirectory = Self.prefilledDirectory(in: model, from: directorySession)
            } else {
                workingDirectory = "~"
            }
        }
    }

    /// The directory a new session's form starts with: that of `session`
    /// (its last known directory, which OSC 7 keeps current), with the home
    /// folder shown as `~`, or `~` when there is no such session or it runs
    /// on a host (its directory is the host's, and the form starts local).
    static func prefilledDirectory(in model: AppModel, from session: SessionID?) -> String {
        guard let session = session.flatMap({ model.session($0) }), session.location == .local else { return "~" }
        let directory = session.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return "~" }
        return ProfileIcon.abbreviatingHome(directory, home: model.defaultWorkingDirectory)
    }

    // MARK: Text

    var title: String {
        switch mode {
        case .newSession: "New Session"
        case .newFavorite: "New Favorite"
        case .editFavorite: "Edit Favorite"
        }
    }

    /// Start for a new session; Save for a favorite.
    var primaryButtonTitle: String {
        if case .newSession = mode { "Start" } else { "Save" }
    }

    /// Whether this form edits a favorite (the name is always shown, and
    /// nothing is started).
    var isFavoriteMode: Bool {
        if case .newSession = mode { false } else { true }
    }

    /// Whether the Name field is shown.
    var showsName: Bool { isFavoriteMode || addToFavorites }

    // MARK: Choices

    var profileID: ProfileID {
        get { storedProfileID }
        set {
            let before = Self.flavor(of: model.profile(storedProfileID))
            storedProfileID = newValue
            // Nothing agent-specific carries over from one agent to another
            // (a dangerous toggle, or a model name the other agent does not
            // know); additional arguments stay.
            if Self.flavor(of: model.profile(newValue)) != before {
                skipPermissions = false
                continueConversation = false
                sandbox = ""
                modelName = ""
            }
        }
    }

    var profile: Profile? { model.profile(profileID) }

    /// The hosts saved when the form last looked (``hostsDidChange()``).
    private var knownHostIDs: [HostID] = []

    /// The saved hosts changed while the form is open (a host added through
    /// Add Host…). A host added while SSH is selected becomes the selected
    /// one: it was added for this session. Otherwise an explicit choice is
    /// kept, and the only host, chosen implicitly, is chosen explicitly once
    /// a second one appears.
    func hostsDidChange() {
        let current = model.hosts.map(\.id)
        let added = current.filter { !knownHostIDs.contains($0) }
        if isRemote, let newest = added.last {
            hostID = newest
        } else if hostID == nil, knownHostIDs.count == 1, current.count > 1, current.contains(knownHostIDs[0]) {
            hostID = knownHostIDs[0]
        }
        knownHostIDs = current
    }

    /// The host the request uses: the one picked (possibly removed), else
    /// the only saved host, else none.
    var selectedHostID: HostID? {
        get {
            if let hostID { return hostID }
            return model.hosts.count == 1 ? model.hosts[0].id : nil
        }
        set { hostID = newValue }
    }

    /// Whether ``selectedHostID`` names a host that is gone.
    var hostIsMissing: Bool {
        selectedHostID.map { model.host($0) == nil } ?? false
    }

    /// Whether ``profileID`` names a profile that is gone.
    var profileIsMissing: Bool { profile == nil }

    /// What is shown in the Directory field's place holder.
    var directoryPrompt: String { isRemote ? "~ (the host’s home folder)" : "~" }

    // MARK: Options

    /// One option the chosen profile's agent has a flag for.
    struct OptionRow: Equatable {
        var title: String
        /// The flag it adds, from ``AgentIntegration``'s table.
        var flag: String
    }

    /// The flag table of the chosen profile's agent, when the profile runs
    /// a program and Armadale knows the agent; a login shell takes no
    /// options at all.
    var optionFlags: OptionFlags? {
        guard let profile, profile.program != nil else { return nil }
        return profile.agentIntegration?.optionFlags
    }

    private var flavor: AgentFlavor? { Self.flavor(of: profile) }

    private static func flavor(of profile: Profile?) -> AgentFlavor? {
        guard case .agent(let flavor) = profile?.kind else { return nil }
        return flavor
    }

    var skipPermissionsRow: OptionRow? {
        guard let flag = optionFlags?.skipPermissions else { return nil }
        let title = switch flavor {
        case .codex: "Skip approvals and sandbox"
        default: "Skip permission checks"
        }
        return OptionRow(title: title, flag: flag)
    }

    var continueRow: OptionRow? {
        guard let flag = optionFlags?.continueConversation else { return nil }
        return OptionRow(title: "Continue the most recent conversation", flag: flag)
    }

    var modelRow: OptionRow? {
        guard let flag = optionFlags?.model else { return nil }
        return OptionRow(title: "Model", flag: flag)
    }

    var sandboxRow: OptionRow? {
        guard let flag = optionFlags?.sandbox else { return nil }
        return OptionRow(title: "Sandbox", flag: flag)
    }

    /// The values the Sandbox picker offers besides Default.
    var sandboxModes: [String] { optionFlags?.sandboxModes ?? [] }

    /// What the Model field shows when empty.
    var modelPrompt: String {
        switch flavor {
        case .claudeCode: "Claude Code’s default"
        case .codex: "Codex’s default"
        default: "The agent’s default"
        }
    }

    /// Whether any agent option is shown.
    var showsAgentOptions: Bool {
        skipPermissionsRow != nil || continueRow != nil || modelRow != nil || sandboxRow != nil
    }

    /// "Additional arguments": for any profile with a program.
    var showsAdditionalArguments: Bool { profile?.program != nil }

    /// The options the form adds: only those the chosen profile shows
    /// (a hidden field adds nothing), none for a login shell. While the
    /// profile is missing, a favorite keeps the options it had.
    var options: SessionOptions {
        guard let profile else { return originalOptions ?? SessionOptions() }
        guard profile.program != nil else { return SessionOptions() }
        let flags = optionFlags
        return SessionOptions(
            skipPermissions: flags?.skipPermissions != nil && skipPermissions,
            continueConversation: flags?.continueConversation != nil && continueConversation,
            model: flags?.model != nil ? Self.nonBlank(modelName) : nil,
            sandbox: flags?.sandbox != nil ? Self.nonBlank(sandbox) : nil,
            additionalArguments: ShellWords.split(additionalArguments))
    }

    private static func nonBlank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Result

    /// What the form asks for. With SSH and no host it names an empty host
    /// ID, which ``problem`` reports first.
    var request: SessionRequest {
        SessionRequest(
            location: isRemote ? .remote(host: selectedHostID ?? HostID(raw: "")) : .local,
            profileID: profileID,
            workingDirectory: workingDirectory,
            options: options)
    }

    /// Why the form cannot be started or saved, or `nil`.
    var problem: String? {
        if let problem = locationProblem { return problem }
        if let problem = directoryProblem { return problem }
        if let problem = model.requestProblem(request) { return problem }
        return hostProblem
    }

    /// A host just added in Settings › Hosts has no destination until one
    /// is typed there: starting on it could only fail.
    private var hostProblem: String? {
        guard isRemote, let host = selectedHostID.flatMap({ model.host($0) }),
              ArmadaleCore.Host.destinationProblem(host.sshDestination) != nil
        else { return nil }
        return "“\(host.displayName)” has no usable destination. Set one in Settings › Hosts."
    }

    var isValid: Bool { problem == nil }

    private var locationProblem: String? {
        guard isRemote, selectedHostID == nil else { return nil }
        return model.hosts.isEmpty ? "No hosts are saved. Add one with Add Host…" : "Choose a host."
    }

    private var directoryProblem: String? {
        workingDirectory.contains("\0") ? "The directory can’t contain a NUL character." : nil
    }

    /// The favorite's name: what the user typed, else the proposal for the
    /// current choices (``AppModel/proposedFavoriteName(for:)``), which
    /// follows every change until the user edits the name.
    var name: String {
        get { customName ?? model.proposedFavoriteName(for: request) }
        set {
            guard newValue != name else { return }
            customName = newValue
        }
    }

    /// Whether the name is the user's rather than the proposal.
    var hasCustomName: Bool { customName != nil }

    /// Start: saves the favorite first when Add to Favorites is on, then
    /// starts the session in the pane. Returns the session, or `nil` (and
    /// changes nothing) when the form is invalid, is not for a new session,
    /// or the pane is gone or already has a session.
    @discardableResult
    func start() -> SessionID? {
        guard case .newSession(let pane) = mode, isValid, model.pane(pane)?.isEmpty == true else { return nil }
        let request = request
        if addToFavorites { model.addFavorite(Favorite(name: name, request: request)) }
        return model.startSession(in: pane, request: request)
    }

    /// Whether ``save()`` would store the favorite. Looser than
    /// ``isValid`` for an existing favorite: one whose host or profile is
    /// gone can still be edited (and stays broken until another is picked),
    /// but never saved with SSH and no host at all, or with a NUL.
    var canSave: Bool {
        switch mode {
        case .newSession: false
        case .newFavorite: isValid
        case .editFavorite: locationProblem == nil && directoryProblem == nil
        }
    }

    /// Save: adds the new favorite or updates the edited one; nothing is
    /// started. Returns its ID, or `nil` when nothing was saved.
    @discardableResult
    func save() -> FavoriteID? {
        guard canSave else { return nil }
        switch mode {
        case .newSession:
            return nil
        case .newFavorite:
            return model.addFavorite(Favorite(name: name, request: request))
        case .editFavorite(let id):
            guard model.favorite(id) != nil else { return nil }
            model.updateFavorite(Favorite(id: id, name: name, request: request))
            return id
        }
    }

    // MARK: Words

    /// `words` as one line that ``ShellWords/split(_:)`` turns back into
    /// them: a word of only safe characters as it is, anything else in
    /// single quotes (a quote in it as `'\''`), an empty word as `''`.
    static func joinedShellWords(_ words: [String]) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        return words.map { word in
            if !word.isEmpty, word.allSatisfy(safe.contains) { return word }
            return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }.joined(separator: " ")
    }
}
