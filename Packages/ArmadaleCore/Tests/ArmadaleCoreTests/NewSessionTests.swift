import Foundation
import Testing
@testable import ArmadaleCore

/// Step 10a: empty panes, `startSession(in:request:)`, the per-session
/// options and how they reach the launch, and the additive state format
/// (DESIGN §2, §3, §8 "New sessions").
@Suite("New sessions")
@MainActor
struct NewSessionTests {
    private func emptyPane() throws -> (AppModel, WorkspaceID, PaneID) {
        let model = AppModel(defaultWorkingDirectory: "/Users/me")
        let ws = model.newWorkspace(name: "W")
        return (model, ws, try #require(model.emptyPaneIDs(in: ws).first))
    }

    // MARK: startSession

    @Test func startingASessionBindsTheEmptyPane() throws {
        let (model, ws, pane) = try emptyPane()
        let before = model.changeCount
        let options = SessionOptions(skipPermissions: true, model: "opus")
        let request = SessionRequest(profileID: Profile.claudeCode.id, workingDirectory: "/repo", options: options)
        let id = try #require(model.startSession(in: pane, request: request))
        let session = try #require(model.session(id))
        #expect(model.pane(pane)?.sessionID == id)
        #expect(session.location == .local)
        #expect(session.profileID == Profile.claudeCode.id)
        #expect(session.workingDirectory == "/repo")
        #expect(session.options == options)
        #expect(session.launch == Profile.claudeCode.launchSpec(options: options))
        #expect(session.launch.arguments.suffix(3) == ["--dangerously-skip-permissions", "--model", "opus"])
        #expect(model.changeCount == before + 1)
        #expect(model.emptyPaneIDs(in: ws).isEmpty)
        #expect(model.focusedSessionID(in: ws) == id)
        #expect(model.place(of: id)?.pane == pane)
        #expect(model.displayTitle(for: try #require(model.selectedTab(in: ws))) == "Claude Code")
    }

    @Test func startingIsRefusedForAPaneThatHasASessionOrIsGone() throws {
        let (model, _, pane) = try emptyPane()
        let first = try #require(model.startSession(in: pane, request: SessionRequest()))
        let before = model.changeCount
        #expect(model.startSession(in: pane, request: SessionRequest()) == nil, "already has a session")
        #expect(model.pane(pane)?.sessionID == first)
        #expect(model.startSession(in: PaneID.generate(), request: SessionRequest()) == nil, "no such pane")
        #expect(model.sessions.map(\.id) == [first])
        #expect(model.changeCount == before)
    }

    @Test func startingIsRefusedForAMissingProfileOrHost() throws {
        let (model, _, pane) = try emptyPane()
        let missingProfile = SessionRequest(profileID: ProfileID(raw: "gone"))
        #expect(model.requestProblem(missingProfile) == "Profile removed")
        #expect(model.startSession(in: pane, request: missingProfile) == nil)
        let missingHost = SessionRequest(location: .remote(host: HostID.generate()))
        #expect(model.requestProblem(missingHost) == "Host removed")
        #expect(model.startSession(in: pane, request: missingHost) == nil)
        #expect(model.sessions.isEmpty)
        #expect(model.pane(pane)?.isEmpty == true)
        #expect(model.requestProblem(SessionRequest()) == nil)
    }

    @Test(arguments: [
        ("", "/Users/me"), ("~", "/Users/me"), ("  ", "/Users/me"), ("~/src", "/Users/me/src"),
        ("/tmp", "/tmp"), ("~bob", "~bob"), (" /tmp ", "/tmp"), (" ~/src\n", "/Users/me/src"),
    ])
    func localDirectories(given: String, resolved: String) throws {
        let (model, _, pane) = try emptyPane()
        let id = try #require(model.startSession(in: pane, request: SessionRequest(workingDirectory: given)))
        #expect(model.session(id)?.workingDirectory == resolved)
    }

    @Test(arguments: [
        ("", "~"), ("~", "~"), (" ~ ", "~"), ("~/src", "~/src"), ("/srv/app", "/srv/app"), (" /srv/app ", "/srv/app"),
    ])
    func remoteDirectoriesAreTheHosts(given: String, resolved: String) throws {
        let (model, _, pane) = try emptyPane()
        let host = model.addHost(name: "VM", sshDestination: "vm")
        let request = SessionRequest(location: .remote(host: host), workingDirectory: given)
        let id = try #require(model.startSession(in: pane, request: request))
        #expect(model.session(id)?.workingDirectory == resolved)
        #expect(model.session(id)?.location == .remote(host: host))
    }

    /// Every way to make a pane makes an empty one; closing empty panes
    /// cascades like any other close, with nothing to end.
    @Test func closingEmptyPanesCascades() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        var removed: Set<SessionID> = []
        model.onSessionsRemoved = { removed.formUnion($0) }
        let keep = model.newWorkspace(name: "Keep")
        model.fillEmptyPanes()
        let ws = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(ws)?.selectedTabGroupID)
        let pane = try #require(model.emptyPaneIDs(in: ws).first)
        let split = try #require(model.splitPane(pane, axis: .horizontal))
        let tab = try #require(model.tab(containing: pane)?.id)
        #expect(model.closePane(split) == .closedPane(split, in: tab))
        #expect(model.workspaceRemoved(byClosingPane: pane) == ws)
        #expect(model.closePane(pane) == .deletedWorkspace(ws))
        #expect(model.tabGroup(group) == nil)
        #expect(model.workspaces.map(\.id) == [keep])
        #expect(removed.isEmpty)
        #expect(model.sessions.count == 1)

        // Tab, group and workspace closes with a mix of panes end only the sessions.
        let mixed = model.newWorkspace(name: "Mixed")
        let mixedGroup = try #require(model.workspace(mixed)?.selectedTabGroupID)
        let first = try #require(model.emptyPaneIDs(in: mixed).first)
        let started = try #require(model.startSession(in: first, request: SessionRequest()))
        _ = model.splitPane(first, axis: .vertical)
        let second = try #require(model.newTab(in: mixedGroup))
        let other = try #require(model.newTabGroup(in: mixed))
        #expect(model.closeOtherTabs(than: second).count == 1)
        #expect(removed == [started])
        #expect(model.closeTab(second) == .closedTabGroup(mixedGroup, in: mixed))
        #expect(model.closeTabGroup(other) == .deletedWorkspace(mixed))
        #expect(model.sessions.count == 1)

        let deleted = model.newWorkspace(name: "Deleted")
        model.deleteWorkspace(deleted)
        #expect(model.workspace(deleted) == nil)
        #expect(removed == [started])
    }

    /// A tab of empty panes moves like any other, and its emptied source
    /// group and workspace go as before.
    @Test func movingATabOfEmptyPanes() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let source = model.newWorkspace(name: "Source")
        let target = model.newWorkspace(name: "Target")
        let targetGroup = try #require(model.workspace(target)?.selectedTabGroupID)
        let tab = try #require(model.selectedTab(in: source)?.id)
        model.moveTab(tab, to: targetGroup, index: Int.max)
        #expect(model.workspace(source) == nil)
        #expect(model.tabGroup(targetGroup)?.tabs.last?.id == tab)
        #expect(model.emptyPaneIDs(in: target).count == 2)
    }

    // MARK: Launch composition

    @Test func claudeCodeOptions() {
        let options = SessionOptions(
            skipPermissions: true, continueConversation: true, model: " sonnet ", sandbox: "read-only",
            additionalArguments: ["--verbose", "--add-dir", "/x y"])
        #expect(AgentIntegration.claudeCode.arguments(for: options)
            == ["--dangerously-skip-permissions", "--continue", "--model", "sonnet"], "no sandbox flag")
        let launch = Profile.claudeCode.launchSpec(options: options)
        #expect(launch.program == "claude")
        #expect(launch.arguments == Profile.claudeCode.launchArguments
            + ["--dangerously-skip-permissions", "--continue", "--model", "sonnet", "--verbose", "--add-dir", "/x y"])
        #expect(launch.arguments.prefix(2) == ["--settings", #"{"preferredNotifChannel":"ghostty"}"#],
                "the attention integration's arguments come first")
    }

    @Test func codexOptions() {
        let options = SessionOptions(
            skipPermissions: true, continueConversation: true, model: "gpt-5", sandbox: "workspace-write",
            additionalArguments: ["--search"])
        #expect(AgentIntegration.codex.arguments(for: options)
            == ["--dangerously-bypass-approvals-and-sandbox", "--sandbox", "workspace-write", "--model", "gpt-5"],
            "Codex has no continue flag")
        #expect(Profile.codex.launchSpec(options: options).arguments
            == ["--dangerously-bypass-approvals-and-sandbox", "--sandbox", "workspace-write", "--model", "gpt-5",
                "--search"])
        #expect(OptionFlags.codex.sandboxModes == ["read-only", "workspace-write", "danger-full-access"])
    }

    @Test func blankOptionsAddNothing() {
        let blank = SessionOptions(model: "  ", sandbox: "")
        #expect(AgentIntegration.claudeCode.arguments(for: blank).isEmpty)
        #expect(AgentIntegration.codex.arguments(for: blank).isEmpty)
        #expect(Profile.codex.launchSpec(options: SessionOptions()) == Profile.codex.launchSpec)
        #expect(Profile.claudeCode.launchSpec(options: nil) == Profile.claudeCode.launchSpec)
    }

    /// A command or an unknown agent gets only the additional arguments;
    /// the login shell ignores every option.
    @Test func otherProfilesTakeOnlyAdditionalArguments() {
        let options = SessionOptions(
            skipPermissions: true, continueConversation: true, model: "m", sandbox: "read-only",
            additionalArguments: ["-n", "5"])
        let command = Profile(name: "Logs", kind: .command, program: "tail", arguments: ["-f"], icon: "doc")
        #expect(command.launchSpec(options: options) == LaunchSpec(program: "tail", arguments: ["-f", "-n", "5"]))
        let aider = Profile(name: "Aider", kind: .agent(.other("aider")), program: "aider", icon: "star")
        #expect(aider.launchSpec(options: options).arguments == ["-n", "5"])
        #expect(Profile.shell.launchSpec(options: options) == Profile.shell.launchSpec)
        #expect(Profile.shell.launchSpec(options: options).arguments.isEmpty)
    }

    /// Respawn: the profile as it is now, with the session's own options;
    /// the recorded launch when the profile is gone; the plain profile for
    /// a session saved before options existed.
    @Test func respawnKeepsTheSessionsOptions() throws {
        let (model, _, pane) = try emptyPane()
        let copy = try #require(model.duplicateProfile(Profile.codex.id))
        let options = SessionOptions(sandbox: "read-only", additionalArguments: ["--search"])
        let id = try #require(model.startSession(in: pane, request: SessionRequest(profileID: copy, options: options)))
        let session = try #require(model.session(id))
        #expect(session.launch.arguments == ["--sandbox", "read-only", "--search"])

        var profile = try #require(model.profile(copy))
        profile.arguments = ["--no-alt-screen"]
        model.updateProfile(profile)
        #expect(model.launchForRespawn(of: session).arguments == ["--no-alt-screen", "--sandbox", "read-only", "--search"])

        var old = session
        old.options = nil
        #expect(model.launchForRespawn(of: old).arguments == ["--no-alt-screen"], "no options recorded")

        model.deleteProfile(copy)
        #expect(model.launchForRespawn(of: session) == session.launch, "the profile is gone")
    }

    // MARK: State format

    /// A state file as written before step 10 (schema 1, no favorites, no
    /// session options, every pane bound to a session) loads unchanged.
    @Test func aStateFileFromBeforeStep10Loads() throws {
        let json = #"""
        {
          "hosts" : [],
          "profiles" : [
            { "arguments" : [], "attentionIntegration" : true, "environment" : {}, "icon" : "terminal",
              "id" : "builtin.shell", "kind" : { "type" : "shell" }, "name" : "Shell" }
          ],
          "schemaVersion" : 1,
          "sessions" : [
            { "createdAt" : "2026-10-20T10:00:00Z", "id" : "aaaaaaaaaaaaaaaa",
              "launch" : { "arguments" : [], "environment" : {} }, "location" : { "local" : {} },
              "profileID" : "builtin.shell", "runtimeVersion" : "0.8.1", "title" : "zsh",
              "workingDirectory" : "/Users/me" },
            { "createdAt" : "2026-10-20T10:01:00Z", "id" : "bbbbbbbbbbbbbbbb",
              "launch" : { "arguments" : [], "environment" : {} }, "location" : { "local" : {} },
              "profileID" : "builtin.shell", "title" : "", "workingDirectory" : "/tmp" }
          ],
          "workspaces" : [
            { "id" : "cccccccccccccccc", "name" : "Workspace", "selectedTabGroupID" : "dddddddddddddddd",
              "tabGroups" : [
                { "id" : "dddddddddddddddd", "name" : "Main", "selectedTabID" : "eeeeeeeeeeeeeeee",
                  "tabs" : [
                    { "focusedPaneID" : "gggggggggggggggg", "id" : "eeeeeeeeeeeeeeee",
                      "layout" : { "split" : { "axis" : "horizontal", "ratio" : 0.5,
                                               "first" : { "pane" : "ffffffffffffffff" },
                                               "second" : { "pane" : "gggggggggggggggg" } } },
                      "panes" : [ { "id" : "ffffffffffffffff", "sessionID" : "aaaaaaaaaaaaaaaa" },
                                  { "id" : "gggggggggggggggg", "sessionID" : "bbbbbbbbbbbbbbbb" } ] }
                  ] }
              ],
              "window" : { "isOpen" : true, "sidebarCollapsed" : false } }
          ]
        }
        """#
        let dir = try TempDirectory()
        try Data(json.utf8).write(to: dir.stateFile)
        guard case .loaded(let state, let firstLaunch) = StateStore.load(from: dir.stateFile) else {
            Issue.record("expected .loaded"); return
        }
        #expect(!firstLaunch)
        #expect(state.favorites.isEmpty)
        #expect(state.sessions.count == 2)
        #expect(state.sessions.allSatisfy { $0.options == nil })
        #expect(state.sessions[0].runtimeVersion == "0.8.1")
        let tab = try #require(state.workspaces.first?.tabGroups.first?.tabs.first)
        #expect(tab.panes.map(\.sessionID) == [SessionID(raw: "aaaaaaaaaaaaaaaa"), SessionID(raw: "bbbbbbbbbbbbbbbb")])
        #expect(state.repaired().issues.isEmpty)

        let model = AppModel(state: state, defaultWorkingDirectory: "/Users/me")
        #expect(model.emptyPaneIDs(in: WorkspaceID(raw: "cccccccccccccccc")).isEmpty)
        #expect(model.sessionOrder.count == 2)
        let session = try #require(model.session(SessionID(raw: "aaaaaaaaaaaaaaaa")))
        #expect(model.launchForRespawn(of: session) == Profile.shell.launchSpec)
    }

    /// An empty pane is saved without a session key, comes back empty, and
    /// the repair keeps it; options and favorites round-trip.
    @Test func emptyPanesOptionsAndFavoritesRoundTrip() throws {
        let (model, ws, pane) = try emptyPane()
        let split = try #require(model.splitPane(pane, axis: .vertical))
        let options = SessionOptions(continueConversation: true, additionalArguments: ["a b"])
        _ = try #require(model.startSession(
            in: split, request: SessionRequest(profileID: Profile.claudeCode.id, options: options)))
        model.addFavorite(Favorite(name: "Fav", request: SessionRequest(profileID: Profile.codex.id)))

        let data = try StateStore.encode(model.persistedState)
        let decoded = try StateStore.decode(data)
        let tab = try #require(decoded.workspaces.first?.tabGroups.first?.tabs.first)
        #expect(tab.pane(pane)?.isEmpty == true)
        #expect(tab.pane(split)?.sessionID != nil)
        #expect(decoded.sessions.first?.options == options)
        #expect(decoded.favorites == model.favorites)
        let (repaired, issues) = decoded.repaired()
        #expect(issues.isEmpty)
        #expect(repaired == decoded)
        let restored = AppModel(state: repaired)
        #expect(restored.emptyPaneIDs(in: ws) == [pane])
        #expect(restored.favorites == model.favorites)

        // The empty pane's record has no sessionID key at all.
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let workspaces = try #require(object["workspaces"] as? [[String: Any]])
        let groups = try #require(workspaces.first?["tabGroups"] as? [[String: Any]])
        let tabs = try #require(groups.first?["tabs"] as? [[String: Any]])
        let panes = try #require(tabs.first?["panes"] as? [[String: Any]])
        let emptyRecord = try #require(panes.first { $0["id"] as? String == pane.raw })
        #expect(emptyRecord["sessionID"] == nil)
    }

    @Test func optionsDecodeWithMissingKeys() throws {
        let options = try JSONDecoder().decode(SessionOptions.self, from: Data(#"{"model":"opus"}"#.utf8))
        #expect(options == SessionOptions(model: "opus"))
        let request = try JSONDecoder().decode(
            SessionRequest.self, from: Data(#"{"location":{"local":{}},"profileID":"builtin.codex"}"#.utf8))
        #expect(request == SessionRequest(profileID: Profile.codex.id))
    }

    @Test func repairDropsDuplicateFavoritesButKeepsBrokenOnes() {
        let broken = Favorite(name: "Gone", request: SessionRequest(location: .remote(host: HostID.generate())))
        let state = PersistedState(favorites: [broken, broken])
        let (repaired, issues) = state.repaired()
        #expect(repaired.favorites == [broken])
        #expect(issues == ["Dropped duplicate favorite \(broken.id)"])
    }
}
