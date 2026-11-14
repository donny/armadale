import Foundation
import Testing
@testable import ArmadaleCore

/// The state file's version rule, from the reading side (DESIGN §3): a file
/// saved by every released version, written by that version's own code
/// (scripts/state-fixtures), loads in this build unchanged. The other side,
/// released builds reading this build's file, is
/// scripts/check-state-compat.sh.
@Suite("State files of released versions")
@MainActor
struct StateFixtureTests {
    /// Every fixture: the release that wrote it, and the schema version
    /// that release wrote. A new release's fixture adds its line here
    /// (scripts/state-fixtures/README.md).
    nonisolated static let writtenSchema: [String: Int] = [
        "0.1.0": 1,
        "0.1.1": 1,
    ]
    /// In version order ("0.1.2" before "0.1.10").
    nonisolated static let versions = writtenSchema.keys.sorted { $0.compare($1, options: .numeric) == .orderedAscending }

    static func fixture(_ version: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "state-\(version)", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    // MARK: Every fixture

    @Test(arguments: versions)
    func loadsAtTheCurrentVersionWithoutRepairs(version: String) throws {
        let data = try Self.fixture(version)
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let written = try #require(Self.writtenSchema[version])
        #expect(raw["schemaVersion"] as? Int == written, "written as schema \(written)")
        #expect(written <= PersistedState.currentSchemaVersion)

        let dir = try TempDirectory()
        try data.write(to: dir.stateFile)
        let result = StateStore.load(from: dir.stateFile)
        guard case .loaded(let state, isFirstLaunch: false) = result else {
            Issue.record("expected .loaded, got \(result)"); return
        }
        #expect(state.schemaVersion == PersistedState.currentSchemaVersion)
        #expect(state == (try StateStore.decode(data)))
        #expect(state.repaired().issues.isEmpty)
        // Loading wrote and moved nothing.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path) == ["state.json"])
        #expect(try Data(contentsOf: dir.stateFile) == data)
    }

    @Test(arguments: versions)
    func roundTripsUnchanged(version: String) throws {
        let state = try StateStore.decode(Self.fixture(version))
        let again = try StateStore.decode(StateStore.encode(state))
        #expect(again == state)
    }

    /// A file one version ahead of this build is refused, not read and not
    /// treated as damaged, even with a readable backup next to it; nothing
    /// is moved or written.
    @Test func aFileOneVersionAheadIsRefusedAndLeftAlone() throws {
        let data = try Self.fixture("0.1.1")
        var raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ahead = PersistedState.currentSchemaVersion + 1
        raw["schemaVersion"] = ahead
        let dir = try TempDirectory()
        try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]).write(to: dir.stateFile)
        try data.write(to: StateStore.backupURL(for: dir.stateFile))
        let before = try Self.snapshot(dir.url)

        let result = StateStore.load(from: dir.stateFile)
        guard case .newerVersion(let version, let file) = result else {
            Issue.record("expected .newerVersion, got \(result)"); return
        }
        #expect(version == ahead)
        #expect(file == dir.stateFile)
        #expect(!result.allowsSaving)
        #expect(try Self.snapshot(dir.url) == before)
    }

    // MARK: 0.1.0

    @Test func contentOf010() throws {
        let state = try StateStore.decode(Self.fixture("0.1.0"))
        try Self.checkCommonContent(state)
        #expect(state.favorites.isEmpty)
        #expect(state.sparedSessionIDs.isEmpty && !state.sessionListIncomplete)
        #expect(state.sessions.count == 9)
        #expect(state.sessions.allSatisfy { $0.options == nil })
        let panes = state.workspaces.flatMap(\.tabGroups).flatMap(\.tabs).flatMap(\.panes)
        #expect(panes.count == 9)
        #expect(panes.allSatisfy { $0.sessionID != nil && $0.themeID == nil }, "0.1.0 had neither")

        let editor = try Self.tab(titled: "Editor", in: state)
        let agents = editor.panes.dropFirst().compactMap { pane in state.sessions.first { $0.id == pane.sessionID } }
        #expect(agents.map(\.profileID) == [Profile.claudeCode.id, Profile.claudeCode.id])
        #expect(agents.map(\.title) == ["Claude Code", "second agent"])

        let notes = try #require(state.workspaces.first { $0.name == "Notes" })
        let notesSession = try #require(notes.tabGroups.first?.tabs.first?.panes.first?.sessionID)
        #expect(state.sessions.first { $0.id == notesSession }?.workingDirectory == "/Users/fixture")

        let codex = try #require(state.sessions.first { $0.profileID == Profile.codex.id })
        #expect(codex.location == .remote(host: try Self.buildBox(in: state).id))
        #expect(codex.workingDirectory == "~")
    }

    // MARK: 0.1.1

    @Test func contentOf011() throws {
        let state = try StateStore.decode(Self.fixture("0.1.1"))
        try Self.checkCommonContent(state)
        #expect(state.sparedSessionIDs.isEmpty && !state.sessionListIncomplete)
        #expect(state.sessions.count == 6)

        // A session carried over from a 0.1.0 file has no options.
        let scratch = try #require(state.workspaces.first { $0.name == "Scratch" })
        let carriedID = try #require(scratch.tabGroups.first?.tabs.first?.panes.first?.sessionID)
        let carried = try #require(state.sessions.first { $0.id == carriedID })
        #expect(carried.options == nil)
        #expect(carried.title == "from 0.1.0")
        #expect(state.sessions.filter { $0.options == nil }.map(\.id) == [carriedID])

        // The split's third pane is empty; the zoomed one has its own theme
        // and a session with options.
        let editor = try Self.tab(titled: "Editor", in: state)
        #expect(editor.panes[2].sessionID == nil)
        #expect(editor.panes[2].themeID == nil)
        let zoomedID = try #require(editor.zoomedPaneID)
        let zoomed = try #require(editor.pane(zoomedID))
        #expect(zoomed.themeID == "builtin.dracula")
        let agent = try #require(state.sessions.first { $0.id == zoomed.sessionID })
        #expect(agent.profileID == Profile.claudeCode.id)
        #expect(agent.options == SessionOptions(
            skipPermissions: true, continueConversation: true, model: "opus", additionalArguments: ["--verbose"]))
        #expect(agent.launch.arguments == ["--dangerously-skip-permissions", "--continue", "--model", "opus", "--verbose"])

        // The closed workspace's only pane is empty and has its own theme.
        let notes = try #require(state.workspaces.first { $0.name == "Notes" })
        let notesPane = try #require(notes.tabGroups.first?.tabs.first?.panes.first)
        #expect(notesPane.sessionID == nil)
        #expect(notesPane.themeID == "builtin.solarized-light")

        let codex = try #require(state.sessions.first { $0.profileID == Profile.codex.id })
        #expect(codex.location == .remote(host: try Self.buildBox(in: state).id))
        #expect(codex.options == SessionOptions(model: "gpt-5", sandbox: "workspace-write"))

        // Favorites, in order, one of them on the removed host.
        #expect(state.favorites.map(\.name) == ["Claude here", "Codex on build", "Old shell", "Build Watcher in ~"])
        #expect(state.favorites[1].request.options == SessionOptions(
            skipPermissions: true, sandbox: "read-only", additionalArguments: ["-c", "x=1"]))
        let model = AppModel(state: state, defaultWorkingDirectory: "/Users/fixture")
        #expect(state.favorites.map { model.favoriteProblem($0) } == [nil, nil, "Host removed", nil])
        let project = try #require(state.workspaces.first { $0.name == "Project" })
        #expect(model.emptyPaneIDs(in: project.id) == [editor.panes[2].id])
    }

    // MARK: Helpers

    /// What both released versions' generators make alike: four workspaces
    /// ("Project" full screen, "Notes" closed, "Inbox" with no frame,
    /// "Scratch" with no window state, a shape no version saves but older or
    /// hand-edited files hold), tab groups "Main" and
    /// "Ops", the "Editor" tab split three ways with its second pane
    /// zoomed, a renamed built-in, a custom command profile and an agent
    /// profile of another kind, a host with every optional field and one
    /// with none, and a session on a host that was removed.
    static func checkCommonContent(_ state: PersistedState) throws {
        #expect(state.workspaces.map(\.name) == ["Project", "Notes", "Inbox", "Scratch"])
        let project = state.workspaces[0], notes = state.workspaces[1]
        #expect(state.workspaces[2].window == WindowState(
            frame: nil, sidebarWidth: 180, sidebarCollapsed: false, isOpen: true, isFullScreen: false))
        #expect(state.workspaces[3].window == nil)
        #expect(state.workspaces[3].tabGroups.map(\.tabs.count) == [1])
        #expect(project.window == WindowState(
            frame: WindowFrame(x: 0, y: 0, width: 1512, height: 982), sidebarWidth: 260,
            sidebarCollapsed: false, isOpen: true, isFullScreen: true))
        #expect(notes.window == WindowState(
            frame: WindowFrame(x: 120.5, y: 80, width: 900, height: 600), sidebarWidth: nil,
            sidebarCollapsed: true, isOpen: false, isFullScreen: false))
        #expect(project.tabGroups.map(\.name) == ["Main", "Ops"])
        #expect(project.selectedTabGroup?.name == "Main")
        #expect(project.tabGroups.map(\.tabs.count) == [2, 2])

        let editor = try tab(titled: "Editor", in: state)
        #expect(project.tabGroups[0].selectedTabID == editor.id)
        #expect(editor.panes.count == 3)
        guard case .split(.horizontal, let ratio, .pane(let left), .split(.vertical, 0.5, .pane(let top), .pane(let bottom)))
            = editor.layout
        else {
            Issue.record("unexpected layout \(editor.layout)"); return
        }
        #expect(abs(ratio - 0.4) < 1e-9)
        #expect([left, top, bottom] == editor.panes.map(\.id))
        #expect(editor.focusedPaneID == top)
        #expect(editor.zoomedPaneID == top)
        let shell = try #require(state.sessions.first { $0.id == editor.panes[0].sessionID })
        #expect(shell.profileID == Profile.shell.id)
        #expect(shell.title == "vim Package.swift")
        #expect(shell.runtimeVersion == "0.8.1")
        #expect(shell.workingDirectory == "/Users/fixture/src/armadale")

        #expect(state.profiles.map(\.name) == ["Shell", "Claude (renamed)", "Codex", "Build Watcher", "Aider"])
        let aider = state.profiles[4]
        #expect(aider.kind == .agent(.other("aider")) && aider.program == "aider" && aider.icon == "bubble.left")
        let claude = state.profiles[1]
        #expect(claude.id == Profile.claudeCode.id && claude.icon == "star" && !claude.attentionIntegration)
        #expect(claude.kind == Profile.claudeCode.kind && claude.program == "claude")
        let custom = state.profiles[3]
        #expect(!custom.isBuiltIn && custom.kind == .command && custom.program == "/usr/bin/make")
        #expect(custom.arguments == ["-C", "src", "watch"] && custom.environment == ["MAKEFLAGS": "-j8"])
        #expect(custom.icon == "hammer")
        let watcher = try #require(state.sessions.first { $0.profileID == custom.id })
        #expect(watcher.workingDirectory == "/opt/build" && watcher.launch.program == "/usr/bin/make")

        let host = try buildBox(in: state)
        let bare = try #require(state.hosts.first { $0.name == "Bare" })
        #expect(state.hosts == [
            ArmadaleCore.Host(
                id: host.id, name: "Build Box", sshDestination: "dev@build.example.com", port: 2222,
                identityFile: "~/.ssh/id_build", sshConfigFile: "~/.ssh/config.build",
                remoteDirectory: "~/.armadale-build"),
            ArmadaleCore.Host(id: bare.id, name: "Bare", sshDestination: "bare.example.com"),
        ])
        let hostIDs = Set(state.hosts.map(\.id))
        let orphaned = state.sessions.filter { session in
            session.remoteHostID.map { !hostIDs.contains($0) } ?? false
        }
        #expect(orphaned.count == 1, "one session on the removed host")
    }

    static func tab(titled title: String, in state: PersistedState) throws -> Tab {
        try #require(state.workspaces.flatMap(\.tabGroups).flatMap(\.tabs).first { $0.customTitle == title })
    }

    static func buildBox(in state: PersistedState) throws -> ArmadaleCore.Host {
        try #require(state.hosts.first { $0.name == "Build Box" })
    }

    /// Names and bytes of every file in `dir`.
    static func snapshot(_ dir: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            result[name] = try Data(contentsOf: dir.appendingPathComponent(name))
        }
        return result
    }
}
