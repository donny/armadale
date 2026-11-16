import Foundation
import Testing
@testable import ArmadaleCore

@Suite("Favorites")
@MainActor
struct FavoriteTests {
    private func model() -> AppModel { AppModel(defaultWorkingDirectory: "/Users/me") }

    @Test func proposedNames() {
        let model = model()
        let host = model.addHost(name: "lima-default", sshDestination: "lima-default")
        #expect(model.proposedFavoriteName(for: SessionRequest()) == "Shell in ~")
        #expect(model.proposedFavoriteName(for: SessionRequest(workingDirectory: "~")) == "Shell in ~")
        #expect(model.proposedFavoriteName(for: SessionRequest(workingDirectory: "/Users/me")) == "Shell in ~")
        #expect(model.proposedFavoriteName(
            for: SessionRequest(profileID: Profile.claudeCode.id, workingDirectory: "/Users/me/work")) == "Claude Code in ~/work")
        #expect(model.proposedFavoriteName(for: SessionRequest(workingDirectory: "/Users/meow")) == "Shell in /Users/meow")
        #expect(model.proposedFavoriteName(for: SessionRequest(workingDirectory: "/tmp")) == "Shell in /tmp")
        #expect(model.proposedFavoriteName(for: SessionRequest(location: .remote(host: host))) == "Shell on lima-default in ~")
        #expect(model.proposedFavoriteName(
            for: SessionRequest(location: .remote(host: host), profileID: Profile.codex.id, workingDirectory: "/Users/me/x"))
            == "Codex on lima-default in /Users/me/x", "a remote path is the host's, never abbreviated")
    }

    @Test func addingNamesBlankFavoritesUniquely() throws {
        let model = model()
        let before = model.changeCount
        let first = model.addFavorite(Favorite(name: "  ", request: SessionRequest()))
        let second = model.addFavorite(Favorite(name: "", request: SessionRequest()))
        let named = model.addFavorite(Favorite(name: "  Agents  ", request: SessionRequest(profileID: Profile.claudeCode.id)))
        let same = model.addFavorite(Favorite(name: "Agents", request: SessionRequest()))
        #expect(model.favorite(first)?.name == "Shell in ~")
        #expect(model.favorite(second)?.name == "Shell in ~ 2")
        #expect(model.favorite(named)?.name == "Agents")
        #expect(model.favorite(same)?.name == "Agents", "a name the user typed is kept as is")
        #expect(model.favorites.map(\.id) == [first, second, named, same])
        #expect(model.changeCount == before + 4)
        #expect(model.persistedState.favorites == model.favorites, "favorites are persisted state")
    }

    @Test func addingWithATakenIDGetsANewOne() throws {
        let model = model()
        let favorite = Favorite(name: "A", request: SessionRequest())
        let first = model.addFavorite(favorite)
        let second = model.addFavorite(favorite)
        #expect(first == favorite.id)
        #expect(second != first)
        #expect(model.favorites.count == 2)
    }

    @Test func updateReplacesAndCleansTheName() throws {
        let model = model()
        let id = model.addFavorite(Favorite(name: "A", request: SessionRequest()))
        _ = model.addFavorite(Favorite(name: "", request: SessionRequest(profileID: Profile.codex.id)))
        var edited = try #require(model.favorite(id))
        edited.name = " B "
        edited.request = SessionRequest(profileID: Profile.claudeCode.id, workingDirectory: "/repo")
        let before = model.changeCount
        model.updateFavorite(edited)
        #expect(model.favorite(id)?.name == "B")
        #expect(model.favorite(id)?.request == edited.request)
        #expect(model.changeCount == before + 1)
        model.updateFavorite(try #require(model.favorite(id)))
        #expect(model.changeCount == before + 1, "no change, no save")

        edited.name = ""
        edited.request = SessionRequest(profileID: Profile.codex.id)
        model.updateFavorite(edited)
        #expect(model.favorite(id)?.name == "Codex in ~ 2", "unique among the others")
        edited = try #require(model.favorite(id))
        edited.request = SessionRequest(profileID: Profile.shell.id)
        model.updateFavorite(edited)
        #expect(model.favorite(id)?.name == "Codex in ~ 2", "a non-blank name stays")

        model.updateFavorite(Favorite(name: "Unknown", request: SessionRequest()))
        #expect(model.favorites.count == 2, "unknown IDs are ignored")
    }

    @Test func removeAndMove() throws {
        let model = model()
        let a = model.addFavorite(Favorite(name: "A", request: SessionRequest()))
        let b = model.addFavorite(Favorite(name: "B", request: SessionRequest()))
        let c = model.addFavorite(Favorite(name: "C", request: SessionRequest()))
        model.moveFavorite(c, to: 0)
        #expect(model.favorites.map(\.id) == [c, a, b])
        model.moveFavorite(c, to: 99)
        #expect(model.favorites.map(\.id) == [a, b, c])
        model.moveFavorite(a, to: 1)
        #expect(model.favorites.map(\.id) == [b, a, c])
        let before = model.changeCount
        model.moveFavorite(a, to: 1)
        #expect(model.changeCount == before, "moving to where it is changes nothing")
        model.removeFavorite(a)
        #expect(model.favorites.map(\.id) == [b, c])
        #expect(model.favorite(a) == nil)
        #expect(model.changeCount == before + 1)
    }

    /// A favorite whose host or profile is gone is kept and says why it
    /// cannot start; picking another host or profile mends it.
    @Test func brokenFavorites() throws {
        let model = model()
        let host = model.addHost(name: "VM", sshDestination: "vm")
        let profile = try #require(model.duplicateProfile(Profile.claudeCode.id))
        let onHost = model.addFavorite(Favorite(name: "Remote", request: SessionRequest(location: .remote(host: host))))
        let withProfile = model.addFavorite(Favorite(name: "Mine", request: SessionRequest(profileID: profile)))
        let both = model.addFavorite(Favorite(
            name: "Both", request: SessionRequest(location: .remote(host: host), profileID: profile)))
        for id in [onHost, withProfile, both] {
            #expect(model.favoriteProblem(try #require(model.favorite(id))) == nil)
        }
        model.removeHost(host)
        model.deleteProfile(profile)
        #expect(model.favorites.count == 3, "kept, broken")
        #expect(model.favoriteProblem(try #require(model.favorite(onHost))) == "Host removed")
        #expect(model.favoriteProblem(try #require(model.favorite(withProfile))) == "Profile removed")
        #expect(model.favoriteProblem(try #require(model.favorite(both))) == "Host removed", "the host is named first")

        var mended = try #require(model.favorite(withProfile))
        mended.request.profileID = Profile.claudeCode.id
        model.updateFavorite(mended)
        #expect(model.favoriteProblem(try #require(model.favorite(withProfile))) == nil)

        // A broken favorite cannot start a session.
        let ws = model.newWorkspace()
        let pane = try #require(model.emptyPaneIDs(in: ws).first)
        #expect(model.startSession(in: pane, request: try #require(model.favorite(onHost)).request) == nil)
        #expect(model.startSession(in: pane, request: mended.request) != nil)
    }

    /// A favorite on a host whose destination is blank or unusable (a host
    /// just added with "+") cannot start either, until the host is fixed.
    @Test func aFavoriteOnAHostWithoutADestinationIsBroken() throws {
        let model = model()
        let host = model.addHost(name: "New")
        let id = model.addFavorite(Favorite(name: "Remote", request: SessionRequest(location: .remote(host: host))))
        #expect(model.favoriteProblem(try #require(model.favorite(id))) == "Host has no usable destination")
        var fixed = try #require(model.host(host))
        fixed.sshDestination = "-oProxyCommand=x"
        model.updateHost(fixed)
        #expect(model.favoriteProblem(try #require(model.favorite(id))) == AppModel.unusableHostDestination)
        fixed.sshDestination = "me@box"
        model.updateHost(fixed)
        #expect(model.favoriteProblem(try #require(model.favorite(id))) == nil)
        model.removeHost(host)
        #expect(model.favoriteProblem(try #require(model.favorite(id))) == "Host removed", "removal is named first")
    }

    /// A host the New Session dialog is about to add has no saved name: the
    /// proposal can name it.
    @Test func aProposedNameCanNameAHostNotSavedYet() {
        let model = model()
        let request = SessionRequest(location: .remote(host: HostID(raw: "")), workingDirectory: "/srv")
        #expect(model.proposedFavoriteName(for: request) == "Shell on Host in /srv")
        #expect(model.proposedFavoriteName(for: request, hostName: "me@box") == "Shell on me@box in /srv")
        #expect(model.proposedFavoriteName(for: SessionRequest(), hostName: "ignored") == "Shell in ~", "local")
    }

    // MARK: Save as Favorite…

    /// A favorite's request from a running session: its location, profile
    /// and options, and its current directory with the home folder as `~`
    /// locally, a host's as it is.
    @Test func aRequestFromASessionUsesItsCurrentDirectory() throws {
        let host = ArmadaleCore.Host(name: "VM", sshDestination: "vm")
        let options = SessionOptions(skipPermissions: true, model: "opus", additionalArguments: ["--x"])
        let local = Session(
            profileID: Profile.claudeCode.id, launch: LaunchSpec(program: "claude"),
            workingDirectory: "/Users/me/start", options: options)
        let remote = Session(
            location: .remote(host: host.id), profileID: Profile.shell.id, launch: LaunchSpec(),
            workingDirectory: "/Users/me/on-the-host", options: SessionOptions())
        let old = Session(profileID: Profile.codex.id, launch: LaunchSpec(program: "codex"), workingDirectory: "/Users/me")
        let model = AppModel(
            state: PersistedState(sessions: [local, remote, old], hosts: [host]), defaultWorkingDirectory: "/Users/me")

        #expect(model.favoriteRequest(fromSession: local.id) == SessionRequest(
            profileID: Profile.claudeCode.id, workingDirectory: "~/start", options: options))
        model.setWorkingDirectory("/Users/me/src/app", for: local.id) // as OSC 7 reports it
        #expect(model.favoriteRequest(fromSession: local.id)?.workingDirectory == "~/src/app", "the current one")
        model.setWorkingDirectory("/opt/data", for: local.id)
        #expect(model.favoriteRequest(fromSession: local.id)?.workingDirectory == "/opt/data")

        #expect(model.favoriteRequest(fromSession: remote.id) == SessionRequest(
            location: .remote(host: host.id), profileID: Profile.shell.id, workingDirectory: "/Users/me/on-the-host"),
            "a host's path is never abbreviated")
        #expect(model.favoriteRequest(fromSession: old.id) == SessionRequest(
            profileID: Profile.codex.id, workingDirectory: "~"), "no options recorded: the defaults")
        #expect(model.favoriteRequest(fromSession: SessionID.generate()) == nil)
    }

    /// A session whose host or profile is gone still gives its request,
    /// which names them, so the form shows the favorite as broken.
    @Test func aRequestFromASessionKeepsARemovedHostOrProfile() throws {
        let model = model()
        let host = model.addHost(name: "VM", sshDestination: "vm")
        let profile = model.newProfile()
        let session = Session(
            location: .remote(host: host), profileID: profile, launch: LaunchSpec(), workingDirectory: "~")
        let restored = AppModel(
            state: PersistedState(sessions: [session], hosts: model.hosts, profiles: model.profiles),
            defaultWorkingDirectory: "/Users/me")
        restored.removeHost(host)
        restored.deleteProfile(profile)
        let request = try #require(restored.favoriteRequest(fromSession: session.id))
        #expect(request.location == .remote(host: host))
        #expect(request.profileID == profile)
        #expect(restored.requestProblem(request) == "Host removed")
    }
}
