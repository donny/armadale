import Foundation
import Testing
@testable import ArmadaleCore

private func named(_ name: String) -> PersistedState {
    var state = PersistedState()
    state.workspaces = [Workspace(name: name)]
    return state
}

private let garbage = Data("{ not json".utf8)
private let newer = Data(#"{"schemaVersion": 9, "fromTheFuture": true}"#.utf8)

/// Names and bytes of every file in `dir`, for "nothing was moved" checks.
private func snapshot(_ dir: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
        result[name] = try Data(contentsOf: dir.appendingPathComponent(name))
    }
    return result
}

// MARK: - The spared list and the incomplete flag

@Suite("Spared sessions in the state")
@MainActor
struct SparedSessionStateTests {
    @Test func aFileWithoutTheNewKeysDecodesToTheDefaults() throws {
        let json = #"{"schemaVersion": 1, "workspaces": [], "sessions": [], "hosts": [], "profiles": []}"#
        let state = try StateStore.decode(Data(json.utf8))
        #expect(state.sparedSessionIDs.isEmpty)
        #expect(!state.sessionListIncomplete)
        #expect(state.schemaVersion == 2, "upgraded by the version-only step 1 → 2")
    }

    @Test func roundTripWithTheNewKeys() throws {
        let ids = [SessionID.generate(), SessionID.generate()].sorted()
        let state = PersistedState(sparedSessionIDs: ids, sessionListIncomplete: true)
        let data = try StateStore.encode(state)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"sparedSessionIDs\"") && text.contains("\"sessionListIncomplete\" : true"))
        let decoded = try StateStore.decode(data)
        #expect(decoded.sparedSessionIDs == ids)
        #expect(decoded.sessionListIncomplete)
        #expect(decoded.schemaVersion == PersistedState.currentSchemaVersion)
    }

    @Test func repairKeepsASparedIDOutOfTheSessions() {
        let known = Session(profileID: Profile.shell.id, launch: LaunchSpec(program: "zsh"), workingDirectory: "/tmp")
        let other = SessionID.generate()
        let state = PersistedState(sessions: [known], sparedSessionIDs: [known.id, other, other])
        let (repaired, issues) = state.repaired()
        #expect(repaired.sparedSessionIDs == [other])
        #expect(!issues.isEmpty)
        #expect(PersistedState(sparedSessionIDs: [other]).repaired().issues.isEmpty)
    }

    @Test func modelCarriesBothFieldsAndTheIntentClearsTheFlag() {
        let a = SessionID.generate(), b = SessionID.generate()
        let model = AppModel(state: PersistedState(sparedSessionIDs: [a], sessionListIncomplete: true))
        #expect(model.persistedState.sparedSessionIDs == [a])
        #expect(model.persistedState.sessionListIncomplete)

        let before = model.changeCount
        model.recordOrphanReclaim(spared: [a, b])
        #expect(model.sparedSessionIDs == [a, b].sorted())
        #expect(!model.sessionListIncomplete)
        #expect(model.changeCount == before + 1)

        model.recordOrphanReclaim(spared: [b, a])
        #expect(model.changeCount == before + 1, "nothing differs: no change")
    }

    @Test func theIntentNeverSparesASessionInTheModel() {
        let model = AppModel(defaultWorkingDirectory: "/tmp")
        let workspace = model.newWorkspace(name: "W")
        model.fillEmptyPanes()
        let id = model.sessionIDs(in: workspace)[0]
        let other = SessionID.generate()
        model.recordOrphanReclaim(spared: [id, other])
        #expect(model.sparedSessionIDs == [other])
    }
}

// MARK: - The launch backup and the load order

@Suite("StateStore launch backup")
@MainActor
struct LaunchBackupTests {
    @Test func keepsTheFileAndReplacesThePreviousOne() throws {
        let dir = try TempDirectory()
        let launch = StateStore.launchBackupURL(for: dir.stateFile)
        #expect(launch.lastPathComponent == "state.json.launch.bak")
        try StateStore.save(named("one"), to: dir.stateFile)
        try StateStore.keepLaunchBackup(of: dir.stateFile)
        try StateStore.save(named("two"), to: dir.stateFile)
        try StateStore.save(named("three"), to: dir.stateFile)
        #expect(try StateStore.decode(Data(contentsOf: launch)).workspaces.map(\.name) == ["one"],
                "saves replace state.json by rename and leave the launch backup alone")

        try StateStore.keepLaunchBackup(of: dir.stateFile)
        #expect(try StateStore.decode(Data(contentsOf: launch)).workspaces.map(\.name) == ["three"])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(!names.contains { $0.hasSuffix(".tmp") }, "\(names)")
    }

    @Test func recoversFromTheLaunchBackupWhenBothOthersAreUnreadable() throws {
        let dir = try TempDirectory()
        try StateStore.save(named("launch"), to: dir.stateFile)
        try StateStore.keepLaunchBackup(of: dir.stateFile)
        try garbage.write(to: dir.stateFile)
        try garbage.write(to: StateStore.backupURL(for: dir.stateFile))

        let result = StateStore.load(from: dir.stateFile)
        guard case .unparseable(_, let recovered, let backup, let quarantined) = result else {
            Issue.record("expected .unparseable, got \(result)"); return
        }
        #expect(recovered?.workspaces.map(\.name) == ["launch"])
        #expect(backup == .launch)
        #expect(quarantined.count == 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(!names.contains("state.json") && !names.contains("state.json.bak"))
        #expect(names.contains("state.json.launch.bak"))
        #expect(names.contains { $0.hasPrefix("state.json.corrupt-") })
        #expect(names.contains { $0.hasPrefix("state.json.bak.corrupt-") })
        #expect(!result.readStateFile)
    }

    @Test func thePreviousSaveComesBeforeTheLaunchBackup() throws {
        let dir = try TempDirectory()
        try StateStore.save(named("launch"), to: dir.stateFile)
        try StateStore.keepLaunchBackup(of: dir.stateFile)
        try StateStore.save(named("later"), to: dir.stateFile) // .bak is "launch" now
        try StateStore.save(named("latest"), to: dir.stateFile) // .bak is "later"
        try garbage.write(to: dir.stateFile)

        guard case .unparseable(_, let recovered, let backup, let quarantined) = StateStore.load(from: dir.stateFile)
        else { Issue.record("expected .unparseable"); return }
        #expect(recovered?.workspaces.map(\.name) == ["later"])
        #expect(backup == .previousSave)
        #expect(quarantined.count == 1)
    }

    @Test func stateJSONComesFirst() throws {
        let dir = try TempDirectory()
        try StateStore.save(named("only"), to: dir.stateFile)
        try StateStore.keepLaunchBackup(of: dir.stateFile)
        try garbage.write(to: StateStore.backupURL(for: dir.stateFile))
        let result = StateStore.load(from: dir.stateFile)
        guard case .loaded(let state, isFirstLaunch: false) = result else {
            Issue.record("expected .loaded, got \(result)"); return
        }
        #expect(state.workspaces.map(\.name) == ["only"])
        #expect(result.readStateFile)
    }

    @Test func missingFilesFallThroughToTheLaunchBackup() throws {
        let dir = try TempDirectory()
        try StateStore.save(named("launch"), to: dir.stateFile)
        try StateStore.keepLaunchBackup(of: dir.stateFile)
        try FileManager.default.removeItem(at: dir.stateFile)
        guard case .unparseable(_, let recovered, .launch, let quarantined) = StateStore.load(from: dir.stateFile)
        else { Issue.record("expected recovery from the launch backup"); return }
        #expect(recovered?.workspaces.map(\.name) == ["launch"])
        #expect(quarantined.isEmpty)
    }

    @Test func allThreeUnreadableStartsFresh() throws {
        let dir = try TempDirectory()
        for url in [dir.stateFile, StateStore.backupURL(for: dir.stateFile), StateStore.launchBackupURL(for: dir.stateFile)] {
            try garbage.write(to: url)
        }
        let result = StateStore.load(from: dir.stateFile)
        guard case .unparseable(_, nil, nil, let quarantined) = result else {
            Issue.record("expected a fresh start, got \(result)"); return
        }
        #expect(quarantined.count == 3)
        #expect(result.allowsSaving)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(names.allSatisfy { $0.contains(".corrupt-") }, "\(names)")
    }

    @Test func noFileAtAllIsAFirstLaunch() throws {
        let dir = try TempDirectory()
        let result = StateStore.load(from: dir.stateFile)
        guard case .loaded(_, isFirstLaunch: true) = result else { Issue.record("expected a first launch"); return }
        #expect(!result.readStateFile)
    }

    /// A newer-version file anywhere in the chain stops the launch, with
    /// every file where it was, the damaged ones before it included.
    @Test(arguments: [0, 1, 2])
    func aNewerFileAnywhereStopsTheLaunchWithNothingMoved(position: Int) throws {
        let dir = try TempDirectory()
        let chain = [dir.stateFile, StateStore.backupURL(for: dir.stateFile), StateStore.launchBackupURL(for: dir.stateFile)]
        for (index, url) in chain.enumerated() {
            try (index == position ? newer : index < position ? garbage : StateStore.encode(named("good"))).write(to: url)
        }
        let before = try snapshot(dir.url)
        let result = StateStore.load(from: dir.stateFile)
        guard case .newerVersion(9, let file) = result else {
            Issue.record("expected .newerVersion, got \(result)"); return
        }
        #expect(file == chain[position])
        #expect(!result.allowsSaving)
        #expect(try snapshot(dir.url) == before)
    }
}
