import ArmadaleCore
import ArmadaleSessions
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
    /// A state directory of the test's own. Short, under `/tmp`, named as
    /// the sessions package's tests name theirs: a launch on it puts its
    /// runtime directory (and the ssh control directory) inside it, where a
    /// long path (the user's temporary directory) would make them fall back
    /// to the shared `/tmp/armadale-<uid>` a real Armadale may be using.
    private final class Directory {
        let url: URL
        var state: URL { url.appendingPathComponent("state.json") }
        var launchBackup: URL { StateStore.launchBackupURL(for: state) }
        init() throws {
            let random = String(UInt32.random(in: 0...UInt32.max), radix: 36)
            url = URL(fileURLWithPath: "/tmp/armadale-test-\(getpid())-\(random)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        deinit {
            if url.path.hasPrefix("/tmp/armadale-test-") { try? FileManager.default.removeItem(at: url) }
        }
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

    // MARK: Fatal launches use nothing in the state directory

    /// Relative paths and bytes (or `nil` for a directory or an unreadable
    /// file) of everything under `dir`.
    private func snapshot(_ dir: URL) throws -> [String: Data?] {
        var result: [String: Data?] = [:]
        let fm = FileManager.default
        for case let path as String in try #require(fm.enumerator(atPath: dir.path)) {
            result[path] = try? Data(contentsOf: dir.appendingPathComponent(path))
        }
        return result
    }

    /// A helper copy of another version in `bin/`, which the helper
    /// installer of a launch that uses the state directory would remove.
    private func addDecoyHelper(in dir: Directory) throws {
        let bin = dir.url.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("decoy".utf8).write(to: bin.appendingPathComponent("zmx-0.0.1"))
    }

    /// The environment of a launch on `dir`, as `ARMADALE_STATE_DIR` sets it.
    private func environment(_ dir: Directory) -> [String: String] {
        [StateLocation.overrideVariable: dir.url.path]
    }

    /// What a fatal plan sets up, checked against `dir`: settings with no
    /// themes folder, the plain PTY backend with no runtime and no failure
    /// (nothing was attempted), no SSH support, and no persistent runtime
    /// for the registry, whose backend maker is never called.
    private func expectNothingSetUp(_ plan: AppDelegate.LaunchPlan, in dir: Directory) {
        // Stands in for the shared settings, which read the real themes
        // folder; a fatal plan must not ask for them.
        let shared = AppSettings(
            preferences: .shared, themes: ThemeCatalog(directory: dir.url.appendingPathComponent("themes")),
            surfaces: .standard)
        var sharedAsked = false
        let services = AppDelegate.launchServices(
            plan: plan, restoring: [], environment: environment(dir),
            sharedSettings: { sharedAsked = true; return shared })
        #expect(!sharedAsked, "the shared settings read the themes folder")
        #expect(services.settings.themes.directory == nil)
        #expect(!services.sessions.setup.isPersistent)
        #expect(services.sessions.runtime == nil)
        #expect(services.sessions.failure == nil, "no persistent backend was attempted")
        #expect(services.remote == nil)
        var backendMade = false
        let runtime = AppDelegate.persistentRuntimeForRegistry(
            plan: plan, sessions: [], environment: environment(dir),
            makeBackend: { sessions, environment in
                backendMade = true
                return AppDelegate.makeSessionBackend(for: sessions, environment: environment)
            })
        #expect(runtime == nil)
        #expect(!backendMade)
    }

    /// A stale temporary file of an interrupted save, which a normal load
    /// removes: a fatal launch must leave it.
    private func addStaleTemporaryFile(in dir: Directory) throws {
        try Data("partial".utf8).write(to: dir.url.appendingPathComponent(".state.json.\(UUID().uuidString).tmp"))
    }

    @Test func aNormalLaunchUsesTheStateDirectory() throws {
        let dir = try Directory()
        try StateStore.save(named("w"), to: dir.state)
        let loaded = AppDelegate.launchState(refusal: nil, stateURL: dir.state)
        #expect(loaded.report == nil)
        let plan = AppDelegate.LaunchPlan(loaded)
        #expect(plan.usesStateDirectory)

        // The persistent path is taken: the helper installer runs against
        // this directory. Whether it succeeds depends on the helpers the
        // test bundle can find (`HelperLocator`), so either it installed
        // (a runtime, and the decoy of another version removed) or it
        // failed and said why.
        try addDecoyHelper(in: dir)
        // The runtime and ssh control directories stay inside the test's
        // directory; a path too long for a socket fails here instead of
        // using the shared fallback.
        let runtimeDirectory = ZmxRuntime.directory(forStateDirectory: dir.url)
        #expect(runtimeDirectory == dir.url.path + "/run")
        #expect(OpenSSHTransport.controlDirectory(forRuntimeDirectory: runtimeDirectory).hasPrefix(dir.url.path + "/"))
        let sentinel = AppSettings(preferences: .shared, themes: ThemeCatalog(directory: nil), surfaces: .standard)
        var sharedAsked = false
        let services = AppDelegate.launchServices(
            plan: plan, restoring: [], environment: environment(dir),
            sharedSettings: { sharedAsked = true; return sentinel })
        #expect(sharedAsked)
        #expect(services.remote != nil)
        if let runtime = services.sessions.runtime { #expect(runtime.directory == runtimeDirectory) }
        let decoyGone = !FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("bin/zmx-0.0.1").path)
        #expect((services.sessions.runtime != nil && decoyGone) || services.sessions.failure != nil)
        var backendMade = false
        _ = AppDelegate.persistentRuntimeForRegistry(
            plan: plan, sessions: [], environment: environment(dir),
            makeBackend: { _, _ in
                backendMade = true
                return AppDelegate.makeSessionBackend(for: [], environment: ["ARMADALE_BACKEND": "ephemeral"])
            })
        #expect(backendMade)
    }

    @Test func aLockedOutLaunchUsesNothing() throws {
        let dir = try Directory()
        try StateStore.save(named("w"), to: dir.state)
        try addStaleTemporaryFile(in: dir)
        try addDecoyHelper(in: dir)
        let before = try snapshot(dir.url)
        let refusal = try #require(InstanceLock.refusal(for: .heldByAnotherProcess(pid: 4242), stateDirectory: dir.url))
        let loaded = AppDelegate.launchState(refusal: refusal, stateURL: dir.state)
        #expect(loaded.report?.isFatal == true)
        #expect(!loaded.canSave)
        #expect(!AppDelegate.LaunchPlan(loaded).usesStateDirectory)
        expectNothingSetUp(AppDelegate.LaunchPlan(loaded), in: dir)
        #expect(try snapshot(dir.url) == before)
    }

    @Test func aNewerFileLaunchUsesNothing() throws {
        let dir = try Directory()
        try Data(#"{"schemaVersion": 9}"#.utf8).write(to: dir.state)
        try StateStore.save(named("w"), to: StateStore.backupURL(for: dir.state))
        try addStaleTemporaryFile(in: dir)
        try addDecoyHelper(in: dir)
        let before = try snapshot(dir.url)
        let loaded = AppDelegate.launchState(refusal: nil, stateURL: dir.state)
        #expect(loaded.report?.isFatal == true)
        #expect(!AppDelegate.LaunchPlan(loaded).usesStateDirectory)
        expectNothingSetUp(AppDelegate.LaunchPlan(loaded), in: dir)
        #expect(try snapshot(dir.url) == before)
    }

    @Test func anUnreadableFileLaunchUsesNothing() throws {
        let dir = try Directory()
        try StateStore.save(named("w"), to: dir.state)
        try addStaleTemporaryFile(in: dir)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.state.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.state.path) }
        try addDecoyHelper(in: dir)
        let before = try snapshot(dir.url)
        let loaded = AppDelegate.launchState(refusal: nil, stateURL: dir.state)
        #expect(loaded.report?.isFatal == true)
        #expect(!loaded.canSave)
        #expect(!AppDelegate.LaunchPlan(loaded).usesStateDirectory)
        expectNothingSetUp(AppDelegate.LaunchPlan(loaded), in: dir)
        #expect(try snapshot(dir.url) == before)
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
