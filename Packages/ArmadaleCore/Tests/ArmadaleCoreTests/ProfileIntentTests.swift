import Foundation
import Testing
@testable import ArmadaleCore

@Suite("Profile intents")
@MainActor
struct ProfileIntentTests {
    @Test func newProfileIsAUniquelyNamedShell() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let before = model.changeCount
        let first = model.newProfile()
        let second = model.newProfile()
        #expect(model.profile(first)?.name == "New Profile")
        #expect(model.profile(second)?.name == "New Profile 2")
        #expect(model.profile(first)?.kind == .shell)
        #expect(model.profile(first)?.isBuiltIn == false)
        #expect(model.profiles.suffix(2).map(\.id) == [first, second])
        #expect(model.changeCount == before + 2)
        #expect(model.persistedState.profiles.contains { $0.id == first }, "profiles are persisted state")
    }

    @Test func duplicateCopiesEverythingButTheIDAndIsEditable() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let copyID = try #require(model.duplicateProfile(Profile.claudeCode.id))
        let copy = try #require(model.profile(copyID))
        #expect(copy.id != Profile.claudeCode.id)
        #expect(copy.name == "Claude Code Copy")
        #expect(copy.kind == .agent(.claudeCode))
        #expect(copy.program == "claude")
        #expect(!copy.isBuiltIn)
        let index = try #require(model.profiles.firstIndex { $0.id == copyID })
        #expect(model.profiles[index - 1].id == Profile.claudeCode.id, "inserted after its source")
        #expect(model.profile(try #require(model.duplicateProfile(Profile.claudeCode.id)))?.name == "Claude Code Copy 2")
        #expect(model.duplicateProfile(ProfileID(raw: "missing")) == nil)
    }

    @Test func updateCleansUpAndStoresEveryField() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let id = model.newProfile()
        var edited = try #require(model.profile(id))
        edited.name = "  Logs  "
        edited.kind = .command
        edited.program = "  /usr/bin/tail "
        edited.arguments = ["-f", "/var/log/system.log"]
        edited.environment = ["LESS": "-R", " ": "dropped"]
        edited.icon = "doc.text"
        let before = model.changeCount
        model.updateProfile(edited)
        let stored = try #require(model.profile(id))
        #expect(stored.name == "Logs")
        #expect(stored.kind == .command)
        #expect(stored.program == "/usr/bin/tail")
        #expect(stored.arguments == ["-f", "/var/log/system.log"])
        #expect(stored.environment == ["LESS": "-R"])
        #expect(stored.icon == "doc.text")
        #expect(model.changeCount == before + 1)

        model.updateProfile(stored)
        #expect(model.changeCount == before + 1, "no change, no save")

        var blank = stored
        blank.name = " "
        blank.icon = ""
        blank.program = ""
        model.updateProfile(blank)
        #expect(model.profile(id)?.name == "Untitled")
        #expect(model.profile(id)?.icon == "terminal")
        #expect(model.profile(id)?.program == nil)
    }

    @Test func builtInsOnlyChangeNameAndIcon() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        var edited = Profile.codex
        edited.name = "OpenAI Codex"
        edited.icon = "brain"
        edited.kind = .shell
        edited.program = "/bin/rm"
        edited.arguments = ["-rf"]
        edited.environment = ["X": "1"]
        model.updateProfile(edited)
        let stored = try #require(model.profile(Profile.codex.id))
        #expect(stored.name == "OpenAI Codex")
        #expect(stored.icon == "brain")
        #expect(stored.kind == .agent(.codex))
        #expect(stored.program == "codex")
        #expect(stored.arguments.isEmpty)
        #expect(stored.environment.isEmpty)
    }

    @Test func builtInsCannotBeDeletedOthersCan() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        for builtIn in Profile.builtIns {
            #expect(!model.deleteProfile(builtIn.id))
            #expect(model.profile(builtIn.id) != nil)
        }
        let id = model.newProfile()
        let before = model.changeCount
        #expect(model.deleteProfile(id))
        #expect(model.profile(id) == nil)
        #expect(model.changeCount == before + 1)
        #expect(!model.deleteProfile(id))
    }

    @Test func newTabsUseTheEditedProfileAndExistingSessionsKeepTheirLaunch() throws {
        let model = AppModel(defaultWorkingDirectory: "/work")
        let workspace = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let id = model.newProfile()
        var profile = try #require(model.profile(id))
        profile.kind = .command
        profile.program = "htop"
        model.updateProfile(profile)
        let tab = try #require(model.newTab(in: group))
        let pane = try #require(model.tab(tab)?.focusedPaneID)
        let sessionID = try #require(model.startSession(in: pane, request: SessionRequest(profileID: id)))
        #expect(model.session(sessionID)?.launch == LaunchSpec(program: "htop"))
        #expect(model.session(sessionID)?.profileID == id)

        profile.program = "btop"
        profile.arguments = ["--utf-force"]
        model.updateProfile(profile)
        let session = try #require(model.session(sessionID))
        #expect(session.launch == LaunchSpec(program: "htop"), "a running session keeps its launch")
        #expect(model.launchForRespawn(of: session) == LaunchSpec(program: "btop", arguments: ["--utf-force"]),
                "a respawn uses the profile as it is now")

        model.deleteProfile(id)
        #expect(model.launchForRespawn(of: session) == LaunchSpec(program: "htop"),
                "with the profile gone, the stored launch")
    }

    @Test func editedProfilesSurviveARoundTrip() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let id = model.newProfile()
        var profile = try #require(model.profile(id))
        profile.kind = .agent(.other("aider"))
        profile.environment = ["A": "b"]
        model.updateProfile(profile)
        var renamedShell = Profile.shell
        renamedShell.name = "zsh"
        model.updateProfile(renamedShell)
        let data = try JSONEncoder().encode(model.persistedState)
        let restored = AppModel(state: try JSONDecoder().decode(PersistedState.self, from: data))
        #expect(restored.profile(id) == model.profile(id))
        #expect(restored.profile(Profile.shell.id)?.name == "zsh")
        #expect(restored.profiles.count == model.profiles.count)
    }

    @Test func environmentNamesAreValidated() throws {
        #expect(Profile.environmentNameProblem("EDITOR") == nil)
        #expect(Profile.environmentNameProblem("_private1") == nil)
        #expect(Profile.environmentNameProblem("") != nil)
        #expect(Profile.environmentNameProblem("A=B") != nil)
        #expect(Profile.environmentNameProblem("A B") != nil)
        #expect(Profile.environmentNameProblem("ZMX_SESSION") != nil)
        #expect(Profile.environmentNameProblem("ZMX_DIR") != nil)
        #expect(Profile.environmentNameProblem("ARMADALE_SESSION_ID") != nil)

        let model = AppModel(defaultWorkingDirectory: "/")
        let id = model.newProfile()
        var profile = try #require(model.profile(id))
        profile.environment = ["GOOD": "1", "A=B": "x", "ZMX_SESSION": "y", "ARMADALE_X": "z", " PADDED ": "2"]
        model.updateProfile(profile)
        #expect(model.profile(id)?.environment == ["GOOD": "1", "PADDED": "2"])
    }
}
