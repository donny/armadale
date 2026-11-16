import AppKit
import ArmadaleCore
import Synchronization
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

    /// SSH with no host saved goes straight to New Host…: the Destination
    /// field shows, and Start waits for a usable destination.
    @Test func sshWithoutAHostChoosesNewHost() throws {
        let (model, pane) = try fixture()
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        form.isRemote = true
        #expect(form.isAddingHost, "New Host… at once")
        #expect(form.hostChoice == .newHost)
        #expect(form.selectedHostID == nil)
        #expect(!form.isValid)
        #expect(form.problem == ArmadaleCore.Host.destinationProblem(""))
        #expect(form.start() == nil)
        #expect(model.sessions.isEmpty)
        #expect(model.hosts.isEmpty, "nothing added")
        #expect(model.pane(pane)?.isEmpty == true)
        form.newHostDestination = " -oProxyCommand=x "
        #expect(form.problem == "A destination can’t start with “-”.", "trimmed, then checked")
        form.newHostDestination = "me@box"
        #expect(form.isValid)
        form.isRemote = false
        #expect(form.request.location == .local)
        #expect(form.isValid)
    }

    /// Hosts added in Settings › Hosts while the dialog is open: while SSH
    /// is selected on a saved host each becomes the selected host; New
    /// Host… keeps what is being typed.
    @Test func hostsAddedMeanwhileAreSelectedButNotOverNewHost() throws {
        let (model, pane) = try fixture()
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        form.isRemote = true
        form.newHostDestination = "typing"
        let first = model.addHost(name: "A", sshDestination: "a")
        form.hostsDidChange()
        #expect(form.hostChoice == .newHost, "the selection stays on New Host…")
        #expect(form.newHostDestination == "typing")

        form.hostChoice = .host(first)
        #expect(!form.isAddingHost)
        #expect(form.selectedHostID == first)
        #expect(form.isValid)
        let second = model.addHost(name: "B", sshDestination: "b")
        form.hostsDidChange()
        #expect(form.selectedHostID == second, "added for this session")
        form.selectedHostID = first
        #expect(form.isValid)

        // Every host removed while SSH is chosen with nothing picked.
        form.hostChoice = .unchosen
        #expect(form.problem == "Choose a host.")
        model.removeHost(first)
        model.removeHost(second)
        form.hostsDidChange()
        #expect(form.hostChoice == .newHost)
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

    // MARK: New Host…

    /// Start with New Host… adds the host (named after its destination,
    /// trimmed) and starts on it; nothing is added before Start.
    @Test func newHostIsAddedOnStartAndUsed() throws {
        let (model, pane) = try fixture()
        model.addHost(name: "Other", sshDestination: "other", port: 2200)
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        form.isRemote = true
        #expect(!form.isAddingHost, "a host is saved: the usual rules")
        form.hostChoice = .newHost
        form.newHostDestination = "  me@box  "
        form.workingDirectory = "/srv"
        #expect(form.isValid)
        #expect(form.name == "Shell on me@box in /srv", "the proposal names the host to be added")
        #expect(model.hosts.count == 1, "nothing added while the form is open")

        let session = try #require(form.start().flatMap { model.session($0) })
        #expect(model.hosts.count == 2)
        let host = try #require(model.hosts.last)
        #expect(host.name == "me@box")
        #expect(host.sshDestination == "me@box")
        #expect(host.isPlain)
        #expect(session.location == .remote(host: host.id))
        #expect(session.workingDirectory == "/srv")
        #expect(form.hostChoice == .host(host.id), "the picker shows the host now")
        #expect(form.start() == nil, "once")
        #expect(model.hosts.count == 2)
    }

    /// The name shown is the name saved: a host New Host… adds may get a
    /// unique name ("vm 2" beside a configured "vm"), and the proposal
    /// already names it so, for Start with Add to Favorites and for Save.
    @Test func theProposedNameNamesTheHostAsItWillBeNamed() throws {
        let (model, pane) = try fixture()
        model.addHost(name: "vm", sshDestination: "vm", port: 2200)
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        form.isRemote = true
        form.hostChoice = .newHost
        form.newHostDestination = "vm"
        form.addToFavorites = true
        let shown = form.name
        #expect(shown == "Shell on vm 2 in ~")
        _ = try #require(form.start())
        #expect(model.hosts.last?.name == "vm 2")
        let favorite = try #require(model.favorites.first)
        #expect(favorite.name == shown)
        #expect(favorite.name == model.proposedFavoriteName(for: favorite.request), "keeps following when edited")

        let save = NewSessionForm(model: model, mode: .newFavorite, prefill: SessionRequest(workingDirectory: "/srv"))
        save.isRemote = true
        save.hostChoice = .newHost
        save.newHostDestination = "box"
        model.addHost(name: "box", sshDestination: "box", identityFile: "~/.ssh/k")
        let shownForSave = save.name
        #expect(shownForSave == "Shell on box 2 in /srv")
        let id = try #require(save.save())
        #expect(model.favorite(id)?.name == shownForSave)
    }

    /// No duplicate: a plain host already saved for the destination is used.
    @Test func newHostUsesAPlainHostAlreadySaved() throws {
        let (model, pane) = try fixture()
        let saved = model.addHost(name: "My VM", sshDestination: "lima-default")
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        form.isRemote = true
        form.hostChoice = .newHost
        form.newHostDestination = "lima-default"
        #expect(form.request.location == .remote(host: saved))
        #expect(form.name == "Shell on My VM in ~")
        form.addToFavorites = true
        let session = try #require(form.start().flatMap { model.session($0) })
        #expect(model.hosts.map(\.id) == [saved])
        #expect(session.location == .remote(host: saved))
        #expect(model.favorites.first?.request.location == .remote(host: saved))
    }

    /// Cancel (the sheet going away) adds nothing; a favorite of a new
    /// host is saved with that host.
    @Test func newHostInAFavoriteFormIsAddedOnSaveOnly() throws {
        let (model, _) = try fixture()
        let request = SessionRequest(profileID: Profile.claudeCode.id, workingDirectory: "~/work")
        let cancelled = NewSessionForm(model: model, mode: .newFavorite, prefill: request)
        cancelled.isRemote = true
        cancelled.newHostDestination = "vm"
        #expect(cancelled.canSave)
        #expect(model.hosts.isEmpty, "Cancel adds nothing")

        let form = NewSessionForm(model: model, mode: .newFavorite, prefill: request)
        form.isRemote = true
        #expect(form.isAddingHost)
        #expect(!form.canSave, "no destination yet")
        form.newHostDestination = "vm"
        let id = try #require(form.save())
        let favorite = try #require(model.favorite(id))
        let host = try #require(model.hosts.first)
        #expect(model.hosts.count == 1)
        #expect(favorite.request.location == .remote(host: host.id))
        #expect(favorite.name == "Claude Code on vm in ~/work")
        #expect(model.sessions.isEmpty, "nothing started")
    }

    /// The picker's choice: a saved host, New Host…, or nothing.
    @Test func theHostChoiceMapsToTheForm() throws {
        let (model, pane) = try fixture()
        let a = model.addHost(name: "A", sshDestination: "a")
        let b = model.addHost(name: "B", sshDestination: "b")
        let form = NewSessionForm(model: model, mode: .newSession(pane))
        form.isRemote = true
        #expect(form.hostChoice == .unchosen, "several hosts: Choose a Host")
        form.hostChoice = .host(b)
        #expect(form.selectedHostID == b)
        form.hostChoice = .newHost
        #expect(form.selectedHostID == nil)
        #expect(form.isAddingHost)
        form.selectedHostID = a
        #expect(!form.isAddingHost, "picking a host leaves New Host…")
        #expect(form.hostChoice == .host(a))
    }

    /// The aliases come from the injected loader, off the main actor, once,
    /// when New Host… is chosen.
    @Test func aliasesAreLoadedWhenNewHostIsChosen() async throws {
        let (model, pane) = try fixture()
        let calls = Calls()
        let form = NewSessionForm(model: model, mode: .newSession(pane), aliasLoader: {
            calls.record(onMain: Thread.isMainThread)
            return ["lima-default", "build", "my-lima"]
        })
        #expect(form.aliases.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.count == 0, "not before New Host…")
        form.isRemote = true // no host saved: New Host… at once
        for _ in 0..<80 where form.aliases.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(form.aliases == ["lima-default", "build", "my-lima"])
        #expect(calls.count == 1)
        #expect(calls.onMain == [false], "read off the main thread")
        form.newHostDestination = "lim"
        #expect(form.aliasSuggestions == ["lima-default", "my-lima"])
        form.hostChoice = .unchosen
        form.hostChoice = .newHost
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.count == 1, "once per form")

    }

    // MARK: Save as Favorite…

    /// A new favorite filled in from a session: its choices, a name that
    /// follows the proposal, and Save adds it without starting anything.
    @Test func aNewFavoriteFromASessionIsFilledIn() throws {
        let (model, _) = try fixture()
        let host = model.addHost(name: "VM", sshDestination: "vm")
        let request = SessionRequest(
            location: .remote(host: host), profileID: Profile.codex.id, workingDirectory: "/srv/app",
            options: SessionOptions(sandbox: "read-only", additionalArguments: ["a b"]))
        let form = NewSessionForm(model: model, mode: .newFavorite, prefill: request)
        #expect(form.title == "New Favorite")
        #expect(form.primaryButtonTitle == "Save")
        #expect(form.isRemote)
        #expect(form.selectedHostID == host)
        #expect(form.profileID == Profile.codex.id)
        #expect(form.workingDirectory == "/srv/app")
        #expect(form.sandbox == "read-only")
        #expect(form.additionalArguments == "'a b'")
        #expect(form.request == request)
        #expect(!form.hasCustomName)
        #expect(form.name == "Codex on VM in /srv/app")
        form.workingDirectory = "/srv"
        #expect(form.name == "Codex on VM in /srv", "follows until typed")
        let id = try #require(form.save())
        #expect(model.favorite(id)?.request.workingDirectory == "/srv")
        #expect(model.sessions.isEmpty)
    }

    /// A session whose profile or host is gone opens the form as a broken
    /// favorite would: Save waits for a valid choice.
    @Test func aNewFavoriteFromASessionWithAGoneHostOrProfileWaits() throws {
        let (model, _) = try fixture()
        let gone = model.addHost(name: "Old", sshDestination: "old")
        model.removeHost(gone)
        let form = NewSessionForm(
            model: model, mode: .newFavorite, prefill: SessionRequest(location: .remote(host: gone)))
        #expect(form.hostIsMissing)
        #expect(form.problem == "Host removed")
        #expect(!form.canSave)
        #expect(!form.canConfirm)
        #expect(form.save() == nil)
        form.isRemote = false
        #expect(form.save() != nil)

        let profile = model.newProfile()
        model.deleteProfile(profile)
        let noProfile = NewSessionForm(model: model, mode: .newFavorite, prefill: SessionRequest(profileID: profile))
        #expect(noProfile.problem == "Profile removed")
        #expect(!noProfile.canSave)
        noProfile.profileID = Profile.shell.id
        #expect(noProfile.canSave)
    }

    @Test(arguments: [
        [], ["a"], ["a b"], [""], ["it's"], [#"back\slash"#], [#""quoted""#, "--x=1", "~/dir", "$HOME"],
    ])
    func argumentsRoundTrip(_ words: [String]) {
        #expect(ShellWords.split(NewSessionForm.joinedShellWords(words)) == words)
    }
}

/// Counts a loader's calls and whether each ran on the main thread.
private final class Calls: Sendable {
    private let threads = Mutex<[Bool]>([])

    func record(onMain: Bool) {
        threads.withLock { $0.append(onMain) }
    }

    var count: Int { threads.withLock { $0.count } }
    var onMain: [Bool] { threads.withLock { $0 } }
}
