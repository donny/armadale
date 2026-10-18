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
        let tab = try #require(model.newTab(in: group, onHost: host))
        let remote = try #require(model.sessionIDs(ofTab: tab).first)
        #expect(model.session(remote)?.location == .remote(host: host))
        #expect(model.session(remote)?.workingDirectory == "~", "the home directory on the host")
        #expect(model.sessionIDs(onHost: host) == [remote])

        // A split inherits the location.
        let pane = try #require(model.tab(tab)?.focusedPaneID)
        let split = try #require(model.splitPane(pane, axis: .horizontal))
        let splitSession = try #require(model.tab(tab)?.pane(split)?.sessionID)
        #expect(model.session(splitSession)?.location == .remote(host: host))

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

    @Test func newTabOnAnUnknownHostDoesNothing() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace()
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        #expect(model.newTab(in: group, onHost: HostID(raw: "missing")) == nil)
        #expect(model.tabGroup(group)?.tabs.count == 1)
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
}
