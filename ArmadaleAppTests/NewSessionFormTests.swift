import AppKit
import ArmadaleCore
import Testing

/// The New Session dialog's rules (``NewSessionForm``, DESIGN §8 "New
/// sessions"), without its view.
@Suite("New Session form")
@MainActor
struct NewSessionFormTests {
    /// A model with one workspace whose only pane is empty.
    private func fixture() throws -> (AppModel, PaneID) {
        let model = AppModel(defaultWorkingDirectory: "/Users/me")
        let workspace = model.newWorkspace(name: "W")
        let pane = try #require(model.emptyPaneIDs(in: workspace).first)
        return (model, pane)
    }

    @Test func aLocalShellByDefault() throws {
        let (model, pane) = try fixture()
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        #expect(form.title == "New Session")
        #expect(form.primaryButtonTitle == "Start")
        #expect(!form.isRemote)
        #expect(form.profileID == Profile.shell.id)
        #expect(form.workingDirectory == "~")
        #expect(form.request == SessionRequest(location: .local, profileID: Profile.shell.id, workingDirectory: "~"))
        #expect(form.isValid)
        #expect(!form.showsAgentOptions)
        #expect(!form.showsAdditionalArguments, "a login shell takes no arguments")
        #expect(!form.showsName)

        let session = try #require(form.start().flatMap { model.session($0) })
        #expect(model.pane(pane)?.sessionID == session.id)
        #expect(session.profileID == Profile.shell.id)
        #expect(session.location == .local)
        #expect(session.workingDirectory == "/Users/me")
        #expect(session.launch == Profile.shell.launchSpec)
        #expect(model.favorites.isEmpty)
        #expect(form.start() == nil, "the pane has a session now")
    }

    @Test func aRemoteClaudeSessionWithOptions() throws {
        let (model, pane) = try fixture()
        let host = model.addHost(name: "VM", sshDestination: "lima-default")
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        form.isRemote = true
        #expect(form.selectedHostID == host, "the only host is preselected")
        form.workingDirectory = " /srv/app "
        form.profileID = Profile.claudeCode.id
        #expect(form.skipPermissionsRow == NewSessionForm.OptionRow(
            title: "Skip permission checks", flag: "--dangerously-skip-permissions"))
        #expect(form.continueRow?.flag == "--continue")
        #expect(form.modelRow?.flag == "--model")
        #expect(form.sandboxRow == nil)
        #expect(form.showsAdditionalArguments)
        form.skipPermissions = true
        form.continueConversation = true
        form.modelName = " opus "
        form.additionalArguments = #"--verbose --append-system-prompt "be brief""#

        let session = try #require(form.start().flatMap { model.session($0) })
        #expect(session.location == .remote(host: host))
        #expect(session.workingDirectory == "/srv/app", "the model trims")
        #expect(session.options == SessionOptions(
            skipPermissions: true, continueConversation: true, model: "opus",
            additionalArguments: ["--verbose", "--append-system-prompt", "be brief"]))
        #expect(session.launch.program == "claude")
        #expect(session.launch.arguments == Profile.claudeCode.launchArguments + [
            "--dangerously-skip-permissions", "--continue", "--model", "opus",
            "--verbose", "--append-system-prompt", "be brief",
        ])
    }

    @Test func codexOffersItsOwnOptions() throws {
        let (model, pane) = try fixture()
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        form.profileID = Profile.codex.id
        #expect(form.skipPermissionsRow == NewSessionForm.OptionRow(
            title: "Skip approvals and sandbox", flag: "--dangerously-bypass-approvals-and-sandbox"))
        #expect(form.continueRow == nil)
        #expect(form.sandboxRow?.flag == "--sandbox")
        #expect(form.sandboxModes == ["read-only", "workspace-write", "danger-full-access"])
        form.sandbox = "workspace-write"
        form.modelName = "gpt-5"
        let session = try #require(form.start().flatMap { model.session($0) })
        #expect(session.launch.arguments == Profile.codex.launchArguments + [
            "--sandbox", "workspace-write", "--model", "gpt-5",
        ])
    }

    /// Options a profile does not show add nothing; the dangerous toggle
    /// never carries from one agent to another.
    @Test func hiddenOptionsAddNothing() throws {
        let (model, pane) = try fixture()
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        form.profileID = Profile.claudeCode.id
        form.skipPermissions = true
        form.continueConversation = true
        form.modelName = "opus"
        form.additionalArguments = "--x"
        form.profileID = Profile.codex.id
        #expect(!form.skipPermissions)
        #expect(!form.continueConversation)
        #expect(form.modelName.isEmpty, "a model name is the agent's own")
        #expect(form.options == SessionOptions(additionalArguments: ["--x"]))
        form.sandbox = "read-only"
        form.modelName = "gpt-5"
        form.profileID = Profile.claudeCode.id
        #expect(form.sandbox.isEmpty)
        #expect(form.modelName.isEmpty)
        form.profileID = Profile.codex.id
        form.profileID = Profile.shell.id
        #expect(form.options == SessionOptions())

        let command = model.newProfile()
        var profile = try #require(model.profile(command))
        profile.kind = .command
        profile.program = "htop"
        model.updateProfile(profile)
        form.profileID = command
        #expect(!form.showsAgentOptions)
        #expect(form.showsAdditionalArguments)
        #expect(form.options == SessionOptions(additionalArguments: ["--x"]))
    }

    @Test func sshWithoutAHostCannotStart() throws {
        let (model, pane) = try fixture()
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        form.isRemote = true
        #expect(form.selectedHostID == nil)
        #expect(!form.isValid)
        #expect(form.problem != nil)
        #expect(form.start() == nil)
        #expect(model.sessions.isEmpty)
        #expect(model.pane(pane)?.isEmpty == true)

        // Hosts added meanwhile (Add Host… opens Settings; the sheet stays),
        // while SSH is selected: each becomes the selected host.
        let first = model.addHost(name: "A", sshDestination: "a")
        form.hostsDidChange()
        #expect(form.selectedHostID == first)
        #expect(form.isValid)
        let second = model.addHost(name: "B", sshDestination: "b")
        form.hostsDidChange()
        #expect(form.selectedHostID == second, "added for this session")
        #expect(form.isValid)
        form.selectedHostID = first
        #expect(form.isValid)
        form.isRemote = false
        #expect(form.request.location == .local)
    }

    /// With Local selected, a new host is not picked; the only host, chosen
    /// implicitly, becomes an explicit choice when a second one appears,
    /// and an explicit choice is kept.
    @Test func anAddedHostIsSelectedOnlyForSSH() throws {
        let (model, pane) = try fixture()
        let only = model.addHost(name: "A", sshDestination: "a")
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        #expect(form.selectedHostID == only, "implicitly")
        model.addHost(name: "B", sshDestination: "b")
        form.hostsDidChange()
        form.isRemote = true
        #expect(form.selectedHostID == only, "kept, not switched to “Choose a Host”")
        #expect(form.isValid)
        let third = model.addHost(name: "C", sshDestination: "c")
        form.hostsDidChange()
        #expect(form.selectedHostID == third, "added while SSH is selected")
        form.selectedHostID = only
        form.isRemote = false
        model.addHost(name: "D", sshDestination: "d")
        form.hostsDidChange()
        #expect(form.selectedHostID == only, "an explicit choice stays")
    }

    /// A host added in Settings › Hosts has no destination until one is
    /// typed: the dialog waits for it.
    @Test func aHostWithoutADestinationCannotStart() throws {
        let (model, pane) = try fixture()
        let host = model.addHost()
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        form.isRemote = true
        #expect(form.selectedHostID == host)
        #expect(form.problem == "“New Host” has no usable destination. Set one in Settings › Hosts.")
        #expect(form.start() == nil)
        var edited = try #require(model.host(host))
        edited.sshDestination = "vm"
        model.updateHost(edited)
        #expect(form.isValid)
    }

    @Test func aDirectoryWithNULCannotStart() throws {
        let (model, pane) = try fixture()
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        form.workingDirectory = "/tmp/a\0b"
        #expect(!form.isValid)
        #expect(form.start() == nil)
    }

    @Test func aFavoriteIsAddedOnlyWhenAsked() throws {
        let (model, pane) = try fixture()
        let workspace = try #require(model.workspaces.first?.id)
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        form.start()
        #expect(model.favorites.isEmpty)

        let tab = try #require(model.newTab(in: group))
        let second = try #require(model.tab(tab)?.focusedPaneID)
        let asked = NewSessionForm(model: model, mode: .newSession(second))
        asked.workingDirectory = "~/work"
        asked.addToFavorites = true
        #expect(asked.showsName)
        let session = try #require(asked.start())
        #expect(model.favorites.count == 1)
        #expect(model.favorites.first?.name == "Shell in ~/work")
        #expect(model.favorites.first?.request == asked.request)
        #expect(model.pane(second)?.sessionID == session)
    }

    /// The proposed name follows every change until the user edits it.
    @Test func theNameFollowsTheChoicesUntilEdited() throws {
        let (model, pane) = try fixture()
        let host = model.addHost(name: "VM", sshDestination: "vm")
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        #expect(form.name == "Shell in ~")
        form.profileID = Profile.claudeCode.id
        form.workingDirectory = "~/work"
        #expect(form.name == "Claude Code in ~/work")
        form.isRemote = true
        #expect(form.name == "Claude Code on VM in ~/work")
        #expect(form.selectedHostID == host)
        #expect(!form.hasCustomName)
        form.name = "Claude Code on VM in ~/work" // the field writing back what it shows
        #expect(!form.hasCustomName)
        form.name = "Review"
        form.workingDirectory = "/srv"
        form.isRemote = false
        #expect(form.name == "Review")
        form.addToFavorites = true
        form.start()
        #expect(model.favorites.map(\.name) == ["Review"])
    }

    @Test func theDirectoryComesFromTheFocusedSession() throws {
        let (model, pane) = try fixture()
        let workspace = try #require(model.workspaces.first?.id)
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let local = try #require(model.newTab(in: group, starting: Profile.shell.id, workingDirectory: "/Users/me/src"))
        let localSession = try #require(model.sessionIDs(ofTab: local).first)
        #expect(NewSessionForm(model: model, mode: .newSession(pane), directorySession: localSession)
            .workingDirectory == "~/src")
        model.setWorkingDirectory("/opt/data", for: localSession)
        #expect(NewSessionForm(model: model, mode: .newSession(pane), directorySession: localSession)
            .workingDirectory == "/opt/data")

        let host = model.addHost(name: "VM", sshDestination: "vm")
        let remote = try #require(model.newTab(
            in: group, starting: Profile.shell.id, at: .remote(host: host), workingDirectory: "/srv"))
        let remoteSession = try #require(model.sessionIDs(ofTab: remote).first)
        let form = NewSessionForm(model: model, mode: .newSession(pane), directorySession: remoteSession)
        #expect(form.workingDirectory == "~", "a host's directory is not this Mac's")
        #expect(!form.isRemote)
        #expect(NewSessionForm(model: model, mode: .newSession(pane)).workingDirectory == "~")
    }

    /// Edit mode: the favorite's choices, Save updates it, nothing starts.
    @Test func editingAFavoriteSavesWithoutStarting() throws {
        let (model, _) = try fixture()
        let host = model.addHost(name: "VM", sshDestination: "vm")
        let request = SessionRequest(
            location: .remote(host: host), profileID: Profile.codex.id, workingDirectory: "/srv",
            options: SessionOptions(skipPermissions: true, sandbox: "read-only", additionalArguments: ["a b", "c"]))
        let id = model.addFavorite(Favorite(name: "Mine", request: request))
        let form = NewSessionForm(model: model, mode: .editFavorite(id))
        #expect(form.title == "Edit Favorite")
        #expect(form.primaryButtonTitle == "Save")
        #expect(form.showsName)
        #expect(form.name == "Mine")
        #expect(form.isRemote)
        #expect(form.selectedHostID == host)
        #expect(form.additionalArguments == "'a b' c")
        #expect(form.request == request)

        form.workingDirectory = "/srv/other"
        form.sandbox = ""
        #expect(form.start() == nil)
        #expect(form.save() == id)
        #expect(model.sessions.isEmpty)
        #expect(model.favorites.count == 1)
        let saved = try #require(model.favorite(id))
        #expect(saved.name == "Mine")
        #expect(saved.request.workingDirectory == "/srv/other")
        #expect(saved.request.options == SessionOptions(skipPermissions: true, additionalArguments: ["a b", "c"]))
    }

    /// A favorite named as proposed keeps following the choices.
    @Test func aProposedFavoriteNameKeepsFollowing() throws {
        let (model, _) = try fixture()
        let id = model.addFavorite(Favorite(name: "", request: SessionRequest(workingDirectory: "~/a")))
        #expect(model.favorite(id)?.name == "Shell in ~/a")
        let form = NewSessionForm(model: model, mode: .editFavorite(id))
        form.workingDirectory = "~/b"
        form.save()
        #expect(model.favorite(id)?.name == "Shell in ~/b")
    }

    /// A broken favorite says why; picking another host fixes it, and it
    /// can still be edited (and saved) while broken.
    @Test func aBrokenFavoriteCanBeRepaired() throws {
        let (model, _) = try fixture()
        let gone = model.addHost(name: "Old", sshDestination: "old")
        let id = model.addFavorite(Favorite(
            name: "X", request: SessionRequest(location: .remote(host: gone), profileID: Profile.claudeCode.id)))
        model.removeHost(gone)
        let other = model.addHost(name: "New", sshDestination: "new")
        let form = NewSessionForm(model: model, mode: .editFavorite(id))
        #expect(form.hostIsMissing)
        #expect(form.problem == "Host removed")
        #expect(!form.isValid)
        #expect(form.canSave)
        form.workingDirectory = "/tmp"
        #expect(form.save() == id)
        #expect(model.favorite(id)?.request.location == .remote(host: gone), "still broken")
        form.selectedHostID = other
        #expect(form.isValid)
        form.save()
        #expect(model.favoriteProblem(try #require(model.favorite(id))) == nil)
    }

    /// A favorite whose profile is gone keeps its options until another
    /// profile is picked.
    @Test func aFavoriteWithoutItsProfileKeepsItsOptions() throws {
        let (model, _) = try fixture()
        let profileID = model.newProfile()
        let options = SessionOptions(model: "m", additionalArguments: ["--y"])
        let id = model.addFavorite(Favorite(name: "P", request: SessionRequest(profileID: profileID, options: options)))
        model.deleteProfile(profileID)
        let form = NewSessionForm(model: model, mode: .editFavorite(id))
        #expect(form.profileIsMissing)
        #expect(form.problem == "Profile removed")
        #expect(form.request.options == options)
        form.profileID = Profile.shell.id
        #expect(form.isValid)
        #expect(form.request.options == SessionOptions())
    }

    @Test func aNewFavoriteIsAddedOnSave() throws {
        let (model, _) = try fixture()
        let form = NewSessionForm(model: model, mode: .newFavorite)
        #expect(form.title == "New Favorite")
        #expect(form.showsName)
        form.profileID = Profile.claudeCode.id
        form.continueConversation = true
        let id = try #require(form.save())
        #expect(model.favorite(id)?.name == "Claude Code in ~")
        #expect(model.favorite(id)?.request.options.continueConversation == true)
        #expect(model.sessions.isEmpty)
        form.isRemote = true
        #expect(form.save() == nil, "SSH with no host")
    }

    @Test(arguments: [
        [], ["a"], ["a b"], [""], ["it's"], [#"back\slash"#], [#""quoted""#, "--x=1", "~/dir", "$HOME"],
    ])
    func argumentsRoundTrip(_ words: [String]) {
        #expect(ShellWords.split(NewSessionForm.joinedShellWords(words)) == words)
    }
}
