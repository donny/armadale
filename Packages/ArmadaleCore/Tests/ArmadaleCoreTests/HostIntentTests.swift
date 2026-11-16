import Foundation
import Testing
@testable import ArmadaleCore

@Suite("Host intents")
@MainActor
struct HostIntentTests {
    @Test func addHostCleansUpAndNamesUniquely() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let before = model.changeCount
        let first = model.addHost()
        let second = model.addHost()
        #expect(model.host(first)?.name == "New Host")
        #expect(model.host(second)?.name == "New Host 2")
        #expect(model.host(first)?.remoteDirectory == "~/.armadale")
        #expect(model.changeCount == before + 2)
        #expect(model.persistedState.hosts.map(\.id) == [first, second], "hosts are persisted state")

        let named = model.addHost(
            name: "  Build box ", sshDestination: " me@build ", port: 2222, identityFile: " ",
            sshConfigFile: " /tmp/lima.conf ", remoteDirectory: "/srv/armadale///")
        let host = try #require(model.host(named))
        #expect(host.name == "Build box")
        #expect(host.sshDestination == "me@build")
        #expect(host.port == 2222)
        #expect(host.identityFile == nil)
        #expect(host.sshConfigFile == "/tmp/lima.conf")
        #expect(host.remoteDirectory == "/srv/armadale")
    }

    @Test func updateHostStoresEveryFieldAndRejectsBadValues() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let id = model.addHost(name: "VM", sshDestination: "vm")
        var edited = try #require(model.host(id))
        edited.name = "Lima"
        edited.sshDestination = "lima-default"
        edited.port = 70000
        edited.identityFile = "~/.ssh/id_ed25519"
        edited.remoteDirectory = "relative/dir"
        let before = model.changeCount
        model.updateHost(edited)
        let host = try #require(model.host(id))
        #expect(host.name == "Lima")
        #expect(host.sshDestination == "lima-default")
        #expect(host.port == nil, "out of range")
        #expect(host.identityFile == "~/.ssh/id_ed25519")
        #expect(host.remoteDirectory == Host.defaultRemoteDirectory, "a relative directory is refused")
        #expect(model.changeCount == before + 1)

        // No change, no save.
        model.updateHost(host)
        #expect(model.changeCount == before + 1)
        // Unknown IDs are ignored.
        model.updateHost(Host(name: "x", sshDestination: "x"))
        #expect(model.hosts.count == 1)
    }

    @Test func removingAHostLeavesItsSessionsInTheirPanes() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace()
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let host = model.addHost(name: "VM", sshDestination: "vm")
        let tab = try #require(model.newTab(in: group))
        let pane = try #require(model.tab(tab)?.focusedPaneID)
        let request = SessionRequest(location: .remote(host: host))
        let remote = try #require(model.startSession(in: pane, request: request))
        #expect(model.sessionIDs(ofTab: tab) == [remote])
        #expect(model.session(remote)?.location == .remote(host: host))
        #expect(model.session(remote)?.workingDirectory == "~", "the home directory on the host")
        #expect(model.sessionIDs(onHost: host) == [remote])

        // A split asks again; started with the same request, it runs there too.
        let split = try #require(model.splitPane(pane, axis: .horizontal))
        #expect(model.tab(tab)?.pane(split)?.isEmpty == true)
        var directoryRequest = request
        directoryRequest.workingDirectory = "~/src"
        let splitSession = try #require(model.startSession(in: split, request: directoryRequest))
        #expect(model.session(splitSession)?.location == .remote(host: host))
        #expect(model.session(splitSession)?.workingDirectory == "~/src", "remote directories pass through")

        let left = model.removeHost(host)
        #expect(Set(left) == [remote, splitSession])
        #expect(model.host(host) == nil)
        #expect(model.session(remote) != nil, "sessions are not removed with their host")
        #expect(model.tab(tab) != nil)
        #expect(model.removeHost(host).isEmpty)
    }

    @Test func anUnconfinedRemoteDirectoryFallsBackToTheDefault() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        for directory in ["~", "/", "/opt", "~/../etc"] {
            let id = model.addHost(name: "VM", sshDestination: "vm", remoteDirectory: directory)
            #expect(model.host(id)?.remoteDirectory == Host.defaultRemoteDirectory, "\(directory)")
        }
    }

    @Test func aSessionOnAnUnknownHostIsRefused() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace()
        let pane = try #require(model.emptyPaneIDs(in: workspace).first)
        let before = model.changeCount
        let request = SessionRequest(location: .remote(host: HostID(raw: "missing")))
        #expect(model.startSession(in: pane, request: request) == nil)
        #expect(model.sessions.isEmpty)
        #expect(model.pane(pane)?.isEmpty == true)
        #expect(model.changeCount == before)
    }

    @Test func validation() {
        #expect(Host.destinationProblem("me@example.com") == nil)
        #expect(Host.destinationProblem("lima-default") == nil)
        #expect(Host.destinationProblem("") != nil)
        #expect(Host.destinationProblem("-oProxyCommand=evil") != nil)
        #expect(Host.destinationProblem("two words") != nil)
        #expect(Host.remoteDirectoryProblem("~/.armadale") == nil)
        #expect(Host.remoteDirectoryProblem("/opt/armadale") == nil)
        #expect(Host.remoteDirectoryProblem("~/tools/armadale") == nil)
        #expect(Host.remoteDirectoryProblem("~bob/x") != nil)
        #expect(Host.remoteDirectoryProblem(".armadale") != nil)
        // Never a folder that is not Armadale's own.
        for unconfined in ["~", "~/", "/", "/opt", "/opt/", "~/../x", "~/a/../b", "/opt/./x", "~/."] {
            #expect(Host.remoteDirectoryProblem(unconfined) != nil, "\(unconfined)")
        }
        #expect(Host(name: " ", sshDestination: "vm").displayName == "vm")
    }

    @Test func hostsWithoutAConfigFileDecodeFromOlderState() throws {
        let json = #"{"id":"abcdefghijklmnop","name":"VM","sshDestination":"vm","remoteDirectory":"~/.armadale"}"#
        let host = try JSONDecoder().decode(Host.self, from: Data(json.utf8))
        #expect(host.sshConfigFile == nil)
        #expect(host.port == nil)
    }

    // MARK: New Host… in the New Session dialog

    /// A host New Host… adds is named after its destination, made unique
    /// among the hosts' names, and sets nothing else.
    @Test func aHostForADestinationIsNamedAfterIt() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let before = model.changeCount
        let id = try #require(model.ensureHost(forDestination: "  me@build  "))
        let host = try #require(model.host(id))
        #expect(host.name == "me@build")
        #expect(host.sshDestination == "me@build", "trimmed")
        #expect(host.isPlain)
        #expect(model.changeCount == before + 1)

        // A host of that name with other settings is not reused: the new
        // one's name is made unique, as "New Host" is.
        let other = model.addHost(name: "box", sshDestination: "box", port: 2222)
        let fresh = try #require(model.ensureHost(forDestination: "box"))
        #expect(fresh != other)
        #expect(model.host(fresh)?.name == "box 2")
        #expect(model.host(fresh)?.port == nil)
    }

    /// No duplicate: a saved host with that destination and otherwise
    /// default settings is used, whatever its name.
    @Test func aPlainHostAlreadySavedIsUsedInsteadOfADuplicate() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let saved = model.addHost(name: "My VM", sshDestination: "lima-default")
        let before = model.changeCount
        #expect(model.plainHost(withDestination: " lima-default ") == saved)
        #expect(model.ensureHost(forDestination: "lima-default") == saved)
        #expect(model.hosts.count == 1)
        #expect(model.changeCount == before, "nothing added or changed")
        #expect(model.plainHost(withDestination: "Lima-Default") == nil, "the destination as typed")
        #expect(model.plainHost(withDestination: "") == nil)
    }

    /// A host that sets anything besides its destination is not "plain"
    /// and is never reused for New Host….
    @Test(arguments: [
        ArmadaleCore.Host(name: "p", sshDestination: "d", port: 22),
        ArmadaleCore.Host(name: "i", sshDestination: "d", identityFile: "~/.ssh/id"),
        ArmadaleCore.Host(name: "c", sshDestination: "d", sshConfigFile: "/tmp/c"),
        ArmadaleCore.Host(name: "r", sshDestination: "d", remoteDirectory: "~/.other"),
    ])
    func aHostWithOtherSettingsIsNotReused(_ configured: ArmadaleCore.Host) throws {
        #expect(!configured.isPlain)
        let model = AppModel(state: PersistedState(hosts: [configured]), defaultWorkingDirectory: "/")
        #expect(model.plainHost(withDestination: "d") == nil)
        let added = try #require(model.ensureHost(forDestination: "d"))
        #expect(added != configured.id)
        #expect(model.hosts.count == 2)
        #expect(model.ensureHost(forDestination: "d") == added, "the plain one is reused from then on")
    }

    /// A destination ``Host/destinationProblem(_:)`` refuses adds nothing.
    @Test(arguments: ["", "   ", "-oProxyCommand=x", "two words"])
    func aRefusedDestinationAddsNothing(_ destination: String) {
        let model = AppModel(defaultWorkingDirectory: "/")
        #expect(model.ensureHost(forDestination: destination) == nil)
        #expect(model.hosts.isEmpty)
    }

    /// The name a host added for a destination will get is known before it
    /// is added, and is the name it gets.
    @Test func theNewHostNameIsTheNameTheHostGets() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        #expect(model.newHostName(forDestination: " vm ") == "vm")
        model.addHost(name: "vm", sshDestination: "vm", port: 2200)
        let expected = model.newHostName(forDestination: "vm")
        #expect(expected == "vm 2")
        let added = try #require(model.ensureHost(forDestination: "vm"))
        #expect(model.host(added)?.name == expected)
    }
}
