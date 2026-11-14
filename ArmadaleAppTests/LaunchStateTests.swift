import ArmadaleCore
import Foundation
import Testing

/// The launch's part of reclaim and save safety (docs/DESIGN.md sections 3
/// and 4): `AppDelegate.loadState(from:)` keeps the launch backup only
/// after reading `state.json` itself, marks the saved sessions incomplete
/// after any other load, and lets the orphan reclaim end sessions only
/// after a clean load of a file not so marked. The reclaim and saving
/// themselves need the live probe and are checked in ArmadaleSessions and
/// live.
@Suite("Launch state")
@MainActor
struct LaunchStateTests {
    private final class Directory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArmadaleLaunchState-\(UUID().uuidString)", isDirectory: true)
        var state: URL { url.appendingPathComponent("state.json") }
        var launchBackup: URL { StateStore.launchBackupURL(for: state) }
        init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private func named(_ name: String, incomplete: Bool = false) -> PersistedState {
        var state = PersistedState(sessionListIncomplete: incomplete)
        state.workspaces = [Workspace(name: name)]
        return state
    }

    @Test func aCleanLoadKeepsTheLaunchBackupAndMayReclaim() throws {
        let dir = try Directory()
        try StateStore.save(named("clean"), to: dir.state)
        let loaded = AppDelegate.loadState(from: dir.state)
        #expect(loaded.mayReclaimOrphans)
        #expect(!loaded.state.sessionListIncomplete)
        #expect(loaded.report == nil)
        #expect(try StateStore.decode(Data(contentsOf: dir.launchBackup)).workspaces.map(\.name) == ["clean"])
    }

    @Test func aFirstLaunchKeepsNoBackupAndMarksTheStateIncomplete() throws {
        let dir = try Directory()
        let loaded = AppDelegate.loadState(from: dir.state)
        #expect(!loaded.mayReclaimOrphans)
        #expect(loaded.state.sessionListIncomplete)
        #expect(loaded.canSave)
        #expect(!FileManager.default.fileExists(atPath: dir.launchBackup.path))
    }

    @Test func aRecoveryKeepsNoBackupAndMarksTheStateIncomplete() throws {
        let dir = try Directory()
        try StateStore.save(named("old"), to: dir.state)
        try StateStore.save(named("new"), to: dir.state)
        try Data("garbage".utf8).write(to: dir.state)
        let loaded = AppDelegate.loadState(from: dir.state)
        #expect(loaded.state.workspaces.map(\.name) == ["old"])
        #expect(!loaded.mayReclaimOrphans)
        #expect(loaded.state.sessionListIncomplete)
        #expect(!FileManager.default.fileExists(atPath: dir.launchBackup.path))
        #expect(loaded.report?.message == "Armadale restored its layout from a backup")
        let details = try #require(loaded.report?.details)
        #expect(details.contains("so the previous backup (state.json.bak) was used."), "\(details)")
        #expect(!details.contains(".)"), "no period before the closing parenthesis: \(details)")
        #expect(!details.contains(".."), "\(details)")
    }

    @Test func aRecoveryFromTheLaunchBackupSaysSo() throws {
        let dir = try Directory()
        try StateStore.save(named("kept"), to: dir.state)
        try StateStore.keepLaunchBackup(of: dir.state)
        try Data("garbage".utf8).write(to: dir.state)
        try Data("garbage".utf8).write(to: StateStore.backupURL(for: dir.state))
        let loaded = AppDelegate.loadState(from: dir.state)
        #expect(loaded.state.workspaces.map(\.name) == ["kept"])
        #expect(!loaded.mayReclaimOrphans)
        #expect(loaded.state.sessionListIncomplete)
        let details = try #require(loaded.report?.details)
        #expect(details.contains("so the backup kept at an earlier launch (state.json.launch.bak) was used."), "\(details)")
        #expect(!details.contains(".)") && !details.contains(".."), "\(details)")
        #expect(details.contains("The unreadable files were kept at"))
    }

    @Test func aFreshStartAfterUnreadableFilesHasOnePeriodPerSentence() throws {
        let dir = try Directory()
        try Data("garbage".utf8).write(to: dir.state)
        try Data("garbage".utf8).write(to: StateStore.backupURL(for: dir.state))
        let loaded = AppDelegate.loadState(from: dir.state)
        #expect(loaded.report?.message == "Armadale could not read its saved layout")
        let details = try #require(loaded.report?.details)
        #expect(!details.contains(".."), "\(details)")
        #expect(details.contains(". Armadale started with a new workspace. The unreadable files were kept at: "), "\(details)")
        #expect(loaded.state.sessionListIncomplete && !loaded.mayReclaimOrphans)
    }

    @Test func withoutFinalPeriodStripsOne() {
        #expect(AppDelegate.withoutFinalPeriod("format.") == "format")
        #expect(AppDelegate.withoutFinalPeriod("format") == "format")
        #expect(AppDelegate.withoutFinalPeriod("a..") == "a.")
        #expect(AppDelegate.withoutFinalPeriod("") == "")
    }

    /// The window: an unclean run saved before the live probe answered.
    @Test func aCleanLoadOfAFileMarkedIncompleteMayNotReclaim() throws {
        let dir = try Directory()
        try StateStore.save(named("saved early", incomplete: true), to: dir.state)
        let loaded = AppDelegate.loadState(from: dir.state)
        #expect(!loaded.mayReclaimOrphans)
        #expect(loaded.state.sessionListIncomplete)
        #expect(loaded.report == nil)
        #expect(FileManager.default.fileExists(atPath: dir.launchBackup.path), "the file itself was read")
    }

    @Test func aNewerFileIsNotTouchedAndNotMarked() throws {
        let dir = try Directory()
        let newer = Data(#"{"schemaVersion": 9}"#.utf8)
        try newer.write(to: dir.state)
        let loaded = AppDelegate.loadState(from: dir.state)
        #expect(!loaded.canSave)
        #expect(!loaded.mayReclaimOrphans)
        #expect(loaded.report?.isFatal == true)
        #expect(try Data(contentsOf: dir.state) == newer)
        #expect(!FileManager.default.fileExists(atPath: dir.launchBackup.path))
    }
}
