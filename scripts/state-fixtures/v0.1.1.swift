// Writes the state fixture for Armadale 0.1.1 with 0.1.1's own code:
//
//   scripts/state-fixtures/run.sh v0.1.1 scripts/state-fixtures/v0.1.1.swift \
//       Packages/ArmadaleCore/Tests/ArmadaleCoreTests/Fixtures/state-0.1.1.json
//
// The state is built through 0.1.1's AppModel, the way the app makes it, and
// holds every kind of thing 0.1.1 saves. The tests that read the fixture
// (StateFixtureTests) check the names and values set here; change both
// together, and never regenerate a released version's fixture with a later
// version's code.
import ArmadaleCore
import Foundation

@main
enum Generate {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: \(arguments[0]) <output.json>\n".utf8))
            exit(2)
        }
        let model = AppModel(state: .empty, defaultWorkingDirectory: "/Users/fixture")

        // Profiles: a renamed built-in (only name, icon and the attention
        // toggle of a built-in can change) and a custom command profile.
        var claude = model.profile(Profile.claudeCode.id)!
        claude.name = "Claude (renamed)"
        claude.icon = "star"
        claude.attentionIntegration = false
        model.updateProfile(claude)
        let customID = model.newProfile()
        var custom = model.profile(customID)!
        custom.name = "Build Watcher"
        custom.kind = .command
        custom.program = "/usr/bin/make"
        custom.arguments = ["-C", "src", "watch"]
        custom.environment = ["MAKEFLAGS": "-j8"]
        custom.icon = "hammer"
        model.updateProfile(custom)
        // An agent profile of a kind Armadale has no integration for.
        let otherAgentID = model.newProfile()
        var otherAgent = model.profile(otherAgentID)!
        otherAgent.name = "Aider"
        otherAgent.kind = .agent(.other("aider"))
        otherAgent.program = "aider"
        otherAgent.icon = "bubble.left"
        model.updateProfile(otherAgent)

        // Hosts: one with every optional field set, one with only the
        // required ones, one removed further down.
        let buildHost = model.addHost(
            name: "Build Box", sshDestination: "dev@build.example.com", port: 2222,
            identityFile: "~/.ssh/id_build", sshConfigFile: "~/.ssh/config.build",
            remoteDirectory: "~/.armadale-build")
        _ = model.addHost(name: "Bare", sshDestination: "bare.example.com")
        let oldHost = model.addHost(name: "Old Box", sshDestination: "old.example.com")

        // Workspace "Project", full screen. Tab group "Main":
        //   tab "Editor": shell | (Claude with options, own theme, zoomed / empty pane)
        //   tab 2: Codex on Build Box with model and sandbox
        let project = model.newWorkspace(name: "Project")
        let main = model.workspace(project)!.tabGroups[0].id
        let editor = model.workspace(project)!.tabGroups[0].tabs[0].id
        let shellPane = model.tab(editor)!.panes[0].id
        let shell = model.startSession(
            in: shellPane, request: SessionRequest(profileID: Profile.shell.id, workingDirectory: "~/src/armadale"))!
        model.setTitle("vim Package.swift", for: shell)
        model.setRuntimeVersion("0.8.1", for: shell)
        let agentPane = model.splitPane(shellPane, axis: .horizontal)!
        let agent = model.startSession(in: agentPane, request: SessionRequest(
            profileID: Profile.claudeCode.id, workingDirectory: "~/src/armadale",
            options: SessionOptions(
                skipPermissions: true, continueConversation: true, model: "opus",
                additionalArguments: ["--verbose"])))!
        model.setTitle("Claude Code", for: agent)
        model.setTheme("builtin.dracula", forPane: agentPane)
        _ = model.splitPane(agentPane, axis: .vertical)!  // stays empty
        model.renameTab(editor, to: "Editor")
        model.focus(pane: agentPane)
        model.resizeFocusedPane(toward: .left, by: 0.1, in: project)
        model.toggleZoom(in: project)

        let remoteTab = model.newTab(in: main)!
        _ = model.startSession(in: model.tab(remoteTab)!.panes[0].id, request: SessionRequest(
            location: .remote(host: buildHost), profileID: Profile.codex.id, workingDirectory: "~/work",
            options: SessionOptions(model: "gpt-5", sandbox: "workspace-write")))!

        // Tab group "Ops": a custom-profile tab, and a tab on the host that
        // is removed below (its session stays, unreachable).
        let ops = model.newTabGroup(in: project, name: "Ops")!
        let opsTab = model.workspace(project)!.tabGroups.first { $0.id == ops }!.tabs[0].id
        _ = model.startSession(in: model.tab(opsTab)!.panes[0].id, request: SessionRequest(
            profileID: customID, workingDirectory: "/opt/build"))!
        let oldTab = model.newTab(in: ops)!
        _ = model.startSession(in: model.tab(oldTab)!.panes[0].id, request: SessionRequest(
            location: .remote(host: oldHost), profileID: Profile.shell.id, workingDirectory: ""))!
        model.select(tabGroup: main)
        model.select(tab: editor)
        model.updateWindowState(WindowState(
            frame: WindowFrame(x: 0, y: 0, width: 1512, height: 982), sidebarWidth: 260,
            sidebarCollapsed: false, isOpen: true, isFullScreen: true), for: project)

        // Workspace "Notes", closed: one tab of one empty pane with its own theme.
        let notes = model.newWorkspace(name: "Notes")
        let notesPane = model.workspace(notes)!.tabGroups[0].tabs[0].panes[0].id
        model.setTheme("builtin.solarized-light", forPane: notesPane)
        model.updateWindowState(WindowState(
            frame: WindowFrame(x: 120.5, y: 80, width: 900, height: 600), sidebarWidth: nil,
            sidebarCollapsed: true, isOpen: false, isFullScreen: false), for: notes)

        // Workspace "Inbox", open, with window state but no frame yet.
        let inbox = model.newWorkspace(name: "Inbox")
        model.updateWindowState(WindowState(
            frame: nil, sidebarWidth: 180, sidebarCollapsed: false, isOpen: true, isFullScreen: false), for: inbox)

        // Favorites: local with options, remote, one on the host about to be
        // removed, and one with a blank name (the proposed name is used).
        model.addFavorite(Favorite(name: "Claude here", request: SessionRequest(
            profileID: Profile.claudeCode.id, workingDirectory: "~/src/armadale",
            options: SessionOptions(continueConversation: true, model: "sonnet"))))
        model.addFavorite(Favorite(name: "Codex on build", request: SessionRequest(
            location: .remote(host: buildHost), profileID: Profile.codex.id, workingDirectory: "~/work",
            options: SessionOptions(skipPermissions: true, sandbox: "read-only", additionalArguments: ["-c", "x=1"]))))
        model.addFavorite(Favorite(name: "Old shell", request: SessionRequest(
            location: .remote(host: oldHost), profileID: Profile.shell.id, workingDirectory: "/srv")))
        model.addFavorite(Favorite(name: "", request: SessionRequest(
            profileID: customID, workingDirectory: "~")))

        model.removeHost(oldHost)

        var state = model.persistedState
        // Workspace "Scratch" with no window state: a shape no version
        // saves (a missing window counts as open at launch, and opening it
        // records a window state before anything is saved), which only older
        // or hand-edited files hold. It is added to the saved state
        // directly, so that decoding it stays covered.
        // Its pane shows a session without `options`, as one carried over
        // from a 0.1.0 file is saved (0.1.1 records options for every
        // session it starts).
        let carried = Session(
            profileID: Profile.shell.id, launch: Profile.shell.launchSpec, workingDirectory: "/tmp",
            title: "from 0.1.0")
        state.sessions.append(carried)
        state.workspaces.append(Workspace(
            name: "Scratch", tabGroups: [TabGroup(name: "Main", tabs: [Tab(pane: Pane(sessionID: carried.id))])],
            window: nil))
        let issues = state.repaired().issues
        guard issues.isEmpty else {
            FileHandle.standardError.write(Data("the state needs repairs: \(issues)\n".utf8))
            exit(1)
        }
        try StateStore.encode(state).write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
    }
}
