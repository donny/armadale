import Foundation
import Testing
@testable import ArmadaleCore

/// A fresh temporary directory per test.
struct TempDirectory: ~Copyable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArmadaleCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    var stateFile: URL { url.appendingPathComponent("state.json") }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@MainActor
private func sampleState() -> PersistedState {
    let model = AppModel(defaultWorkingDirectory: "/tmp")
    let workspace = model.newWorkspace(name: "Agents")
    let group = model.workspace(workspace)?.tabGroups.first?.id
    if let group { model.newTab(in: group, profile: Profile.claudeCode.id) }
    if let pane = model.workspace(workspace)?.tabGroups.first?.tabs.first?.focusedPaneID {
        model.splitPane(pane, axis: .horizontal)
    }
    var state = model.persistedState
    state.hosts = [Host(name: "box", sshDestination: "me@box", port: 2222)]
    return state
}

/// Bytes of every file in `dir`, for "nothing was touched" assertions.
private func snapshot(_ dir: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
        result[name] = try Data(contentsOf: dir.appendingPathComponent(name))
    }
    return result
}

private func named(_ name: String) -> PersistedState {
    var state = PersistedState()
    state.workspaces = [Workspace(name: name)]
    return state
}

@Suite("StateStore")
@MainActor
struct StateStoreTests {
    @Test func roundTrip() throws {
        let dir = try TempDirectory()
        let state = sampleState()
        try StateStore.save(state, to: dir.stateFile)
        guard case .loaded(let loaded, let firstLaunch) = StateStore.load(from: dir.stateFile) else {
            Issue.record("expected .loaded"); return
        }
        #expect(!firstLaunch)
        // Dates survive at ISO 8601 (second) precision; compare after a round trip.
        let reencoded = try StateStore.decode(StateStore.encode(state))
        #expect(loaded == reencoded)
        #expect(loaded.schemaVersion == PersistedState.currentSchemaVersion)
        #expect(loaded.workspaces.first?.name == "Agents")
        #expect(loaded.hosts.first?.port == 2222)
    }

    @Test func windowsSavedWithoutTheFullScreenFlagDecodeAsNotFullScreen() throws {
        // A window state as saved before `isFullScreen` existed.
        let json = #"{"frame":{"x":10,"y":20,"width":1100,"height":700},"sidebarWidth":240,"sidebarCollapsed":false,"isOpen":true}"#
        let old = try JSONDecoder().decode(WindowState.self, from: Data(json.utf8))
        #expect(!old.isFullScreen)
        #expect(old == WindowState(frame: WindowFrame(x: 10, y: 20, width: 1100, height: 700), sidebarWidth: 240))
        // Nor do the optional fields have to be there.
        let bare = try JSONDecoder().decode(WindowState.self, from: Data(#"{"sidebarCollapsed":true,"isOpen":false}"#.utf8))
        #expect(bare == WindowState(sidebarCollapsed: true, isOpen: false))

        var full = old
        full.isFullScreen = true
        let encoded = try JSONEncoder().encode(full)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""isFullScreen":true"#))
        #expect(try JSONDecoder().decode(WindowState.self, from: encoded) == full)

        // Through the store, in a whole state file.
        let dir = try TempDirectory()
        var state = sampleState()
        state.workspaces[0].window = full
        try StateStore.save(state, to: dir.stateFile)
        guard case .loaded(let loaded, _) = StateStore.load(from: dir.stateFile) else {
            Issue.record("expected .loaded"); return
        }
        #expect(loaded.workspaces.first?.window == full)
        #expect(loaded.schemaVersion == PersistedState.currentSchemaVersion)
    }

    @Test func missingFilesLoadEmpty() throws {
        let dir = try TempDirectory()
        let result = StateStore.load(from: dir.stateFile)
        guard case .loaded(let state, let firstLaunch) = result else { Issue.record("expected .loaded"); return }
        #expect(firstLaunch)
        #expect(state.workspaces.isEmpty)
        #expect(state.profiles == Profile.builtIns)
        #expect(result.allowsSaving)
    }

    @Test func savingKeepsPreviousFileAsBackup() throws {
        let dir = try TempDirectory()
        try StateStore.save(named("one"), to: dir.stateFile)
        #expect(!FileManager.default.fileExists(atPath: StateStore.backupURL(for: dir.stateFile).path))
        try StateStore.save(named("two"), to: dir.stateFile)

        let primary = try StateStore.decode(Data(contentsOf: dir.stateFile))
        let backup = try StateStore.decode(Data(contentsOf: StateStore.backupURL(for: dir.stateFile)))
        #expect(primary.workspaces.map(\.name) == ["two"])
        #expect(backup.workspaces.map(\.name) == ["one"])
    }

    @Test func saveLeavesNoTemporaryFiles() throws {
        let dir = try TempDirectory()
        for n in 0..<5 { try StateStore.save(named("w\(n)"), to: dir.stateFile) }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path).sorted()
        #expect(names == ["state.json", "state.json.bak"])
    }

    @Test func loadRemovesStaleTemporaryFiles() throws {
        let dir = try TempDirectory()
        try StateStore.save(named("x"), to: dir.stateFile)
        let stale = dir.url.appendingPathComponent(".state.json.\(UUID().uuidString).tmp")
        let unrelated = dir.url.appendingPathComponent("notes.tmp")
        try Data("partial".utf8).write(to: stale)
        try Data("keep".utf8).write(to: unrelated)
        _ = StateStore.load(from: dir.stateFile)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func saveCreatesMissingDirectory() throws {
        let dir = try TempDirectory()
        let nested = dir.url.appendingPathComponent("a/b/state.json")
        try StateStore.save(PersistedState(), to: nested)
        #expect(StateStore.load(from: nested).state != nil)
    }

    @Test func atomicSaveReplacesInodeAndKeepsOldContentInBackup() throws {
        // A reader holding the old file keeps seeing complete old content:
        // the save renames a new file over it rather than truncating it.
        let dir = try TempDirectory()
        try StateStore.save(named("old"), to: dir.stateFile)
        let handle = try FileHandle(forReadingFrom: dir.stateFile)
        defer { try? handle.close() }

        try StateStore.save(named("new"), to: dir.stateFile)

        let stillOld = try StateStore.decode(handle.readToEnd() ?? Data())
        #expect(stillOld.workspaces.map(\.name) == ["old"])
        #expect(StateStore.load(from: dir.stateFile).state?.workspaces.map(\.name) == ["new"])
    }

    @Test func corruptPrimaryFallsBackToBackupAndQuarantines() throws {
        let dir = try TempDirectory()
        try StateStore.save(named("good"), to: dir.stateFile)
        try StateStore.save(named("good"), to: dir.stateFile) // now a .bak exists too
        try Data("{ not json".utf8).write(to: dir.stateFile)

        let result = StateStore.load(from: dir.stateFile)
        guard case .unparseable(let problem, let recovered, let quarantined) = result else {
            Issue.record("expected .unparseable, got \(result)"); return
        }
        #expect(!problem.isEmpty)
        #expect(recovered?.workspaces.map(\.name) == ["good"])
        #expect(quarantined.count == 1)
        #expect(quarantined.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(!FileManager.default.fileExists(atPath: dir.stateFile.path))
        #expect(result.allowsSaving)

        // The next save must not rotate the corrupt file into the backup.
        try StateStore.save(try #require(recovered), to: dir.stateFile)
        guard case .loaded = StateStore.load(from: dir.stateFile) else { Issue.record("expected .loaded"); return }
    }

    @Test func missingPrimaryWithBackupRecoversWithoutQuarantine() throws {
        let dir = try TempDirectory()
        try StateStore.save(named("one"), to: dir.stateFile)
        try StateStore.save(named("two"), to: dir.stateFile)
        try FileManager.default.removeItem(at: dir.stateFile)
        guard case .unparseable(_, let recovered, let quarantined) = StateStore.load(from: dir.stateFile) else {
            Issue.record("expected .unparseable"); return
        }
        #expect(recovered?.workspaces.map(\.name) == ["one"])
        #expect(quarantined.isEmpty)
    }

    @Test func bothFilesCorruptQuarantinesBothAndStartsFresh() throws {
        let dir = try TempDirectory()
        try Data("garbage".utf8).write(to: dir.stateFile)
        try Data("garbage".utf8).write(to: StateStore.backupURL(for: dir.stateFile))
        guard case .unparseable(_, let recovered, let quarantined) = StateStore.load(from: dir.stateFile) else {
            Issue.record("expected .unparseable"); return
        }
        #expect(recovered == nil)
        #expect(quarantined.count == 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(!names.contains("state.json") && !names.contains("state.json.bak"))
    }

    @Test func corruptPrimaryWithoutBackupIsQuarantined() throws {
        let dir = try TempDirectory()
        try Data("garbage".utf8).write(to: dir.stateFile)
        guard case .unparseable(_, let recovered, let quarantined) = StateStore.load(from: dir.stateFile) else {
            Issue.record("expected .unparseable"); return
        }
        #expect(recovered == nil)
        #expect(quarantined.count == 1)
    }

    /// Switching to an older build must not destroy the newer build's layout.
    @Test func newerPrimaryWithOlderBackupIsLeftUntouched() throws {
        let dir = try TempDirectory()
        try StateStore.save(named("old build"), to: dir.stateFile)
        try StateStore.save(named("old build"), to: dir.stateFile)
        try Data(#"{"schemaVersion": 7, "fromTheFuture": true}"#.utf8).write(to: dir.stateFile)
        let before = try snapshot(dir.url)

        let result = StateStore.load(from: dir.stateFile)
        guard case .newerVersion(let version, let file) = result else {
            Issue.record("expected .newerVersion, got \(result)"); return
        }
        #expect(version == 7)
        #expect(file == dir.stateFile)
        #expect(!result.allowsSaving)
        #expect(result.state == nil)
        #expect(try snapshot(dir.url) == before)
    }

    @Test func corruptPrimaryWithNewerBackupIsLeftUntouched() throws {
        let dir = try TempDirectory()
        try Data("garbage".utf8).write(to: dir.stateFile)
        try Data(#"{"schemaVersion": 3}"#.utf8).write(to: StateStore.backupURL(for: dir.stateFile))
        let before = try snapshot(dir.url)
        guard case .newerVersion(3, _) = StateStore.load(from: dir.stateFile) else {
            Issue.record("expected .newerVersion(3)"); return
        }
        #expect(try snapshot(dir.url) == before)
    }

    @Test func unreadablePrimaryIsAnIOErrorAndLeftUntouched() throws {
        let dir = try TempDirectory()
        try StateStore.save(named("x"), to: dir.stateFile)
        try StateStore.save(named("x"), to: dir.stateFile)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.stateFile.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.stateFile.path) }

        let result = StateStore.load(from: dir.stateFile)
        guard case .ioError(let message, let file) = result else {
            Issue.record("expected .ioError, got \(result)"); return
        }
        #expect(!message.isEmpty)
        #expect(file == dir.stateFile)
        #expect(!result.allowsSaving)
        let names = try fm.contentsOfDirectory(atPath: dir.url.path).sorted()
        #expect(names == ["state.json", "state.json.bak"])
    }

    @Test func stateDirectoryHonoursOverride() {
        let url = StateLocation.directory(environment: [StateLocation.overrideVariable: "/tmp/x"])
        #expect(url.path == "/tmp/x")
        let defaultURL = StateLocation.directory(environment: [:])
        #expect(defaultURL.path.hasSuffix("Library/Application Support/Armadale"))
        #expect(StateLocation.stateFile(environment: [:]).lastPathComponent == "state.json")
    }
}

@Suite("Migrations")
struct MigrationTests {
    @Test func currentVersionPassesThrough() throws {
        let doc: Migrations.Document = ["schemaVersion": 1, "workspaces": []]
        let result = try Migrations.migrate(doc)
        #expect(result["schemaVersion"] as? Int == 1)
    }

    @Test func legacyDocumentWithoutVersionIsRejected() throws {
        let legacy = Data(#"{"windows": [{"title": "old"}]}"#.utf8)
        #expect(throws: MigrationError.missingSchemaVersion) { try Migrations.migrate(data: legacy) }
        #expect(throws: MigrationError.missingSchemaVersion) { try StateStore.decode(legacy) }
    }

    @Test func versionZeroHasNoMigrationPath() {
        #expect(throws: MigrationError.unsupportedVersion(0)) {
            try Migrations.migrate(["schemaVersion": 0])
        }
    }

    @Test func newerVersionIsRejected() {
        #expect(throws: MigrationError.newerVersion(99)) {
            try Migrations.migrate(["schemaVersion": 99])
        }
    }

    @Test func nonObjectIsRejected() {
        #expect(throws: MigrationError.notAnObject) { try Migrations.migrate(data: Data("[]".utf8)) }
    }

    @Test func stepsRunInOrderDeterministically() throws {
        let steps: [Int: Migrations.Step] = [
            0: { doc in
                var doc = doc
                doc["schemaVersion"] = 1
                doc["workspaces"] = doc.removeValue(forKey: "windows") ?? []
                return doc
            },
            1: { doc in
                var doc = doc
                doc["schemaVersion"] = 2
                doc["hosts"] = []
                return doc
            },
        ]
        let legacy: Migrations.Document = ["schemaVersion": 0, "windows": ["w"]]
        let first = try Migrations.migrate(legacy, to: 2, steps: steps)
        let second = try Migrations.migrate(legacy, to: 2, steps: steps)
        #expect(first["schemaVersion"] as? Int == 2)
        #expect(first["windows"] == nil)
        #expect(first["workspaces"] as? [String] == ["w"])
        #expect(first["hosts"] as? [String] == [])
        #expect(NSDictionary(dictionary: first) == NSDictionary(dictionary: second))
    }

    @Test func stepThatDoesNotAdvanceIsAnError() {
        let steps: [Int: Migrations.Step] = [0: { $0 }]
        #expect(throws: MigrationError.stepDidNotAdvance(from: 0)) {
            try Migrations.migrate(["schemaVersion": 0], to: 1, steps: steps)
        }
    }
}
