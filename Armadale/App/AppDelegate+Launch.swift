import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation
import os
import UserNotifications

/// Launch (docs/DESIGN.md section 8, "App lifecycle"): loading the state
/// and what a launch sets up (``LaunchPlan``, its services, the persistent
/// runtime and the helper install), and the launch housekeeping once the
/// live probe has answered.
extension AppDelegate {
    /// The state as loaded (and repaired), and what to make of it.
    struct LoadedState {
        var state: PersistedState
        var report: LoadReport?
        var canSave: Bool
        /// See ``AppDelegate/mayReclaimOrphans``.
        var mayReclaimOrphans: Bool
    }

    /// How much a launch sets up besides its windows (docs/DESIGN.md
    /// section 8, "A fatal launch"). A fatal launch, whatever made it fatal
    /// (``LoadReport/isFatal``: the lock is held by another process, the
    /// state file is newer or cannot be read), uses nothing in the state
    /// directory: no helper copies installed in `bin/` or other versions'
    /// copies removed, no persistent runtime prepared (so no session listed
    /// or probed, no log or exit file removed), no SSH support, no user
    /// themes read.
    struct LaunchPlan: Equatable {
        var usesStateDirectory: Bool

        init(_ loaded: LoadedState) {
            usesStateDirectory = loaded.report?.isFatal != true
        }
    }

    /// What a launch runs on: its settings, its local session backend and
    /// its SSH support.
    struct LaunchServices {
        var settings: AppSettings
        var sessions: SessionBackend
        var remote: RemoteSessionSupport?
    }

    /// The services `plan` allows. A fatal plan gets settings with no themes
    /// folder, the plain PTY backend and no SSH support, so nothing in the
    /// state directory is touched beyond the lock file's open (and, when the
    /// lock was taken, reading the state file): no helper installed or
    /// removed, no runtime prepared. A normal plan gets
    /// `sharedSettings()`, the persistent backend (``makeSessionBackend(for:environment:)``,
    /// falling back to plain PTY sessions) and SSH support. Internal, with
    /// `environment` and `sharedSettings` as parameters, for the tests.
    static func launchServices(
        plan: LaunchPlan,
        restoring sessions: [Session],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sharedSettings: () -> AppSettings = { AppSettings.shared }
    ) -> LaunchServices {
        guard plan.usesStateDirectory else {
            return LaunchServices(
                settings: AppSettings(preferences: .shared, themes: ThemeCatalog(directory: nil), surfaces: .standard),
                sessions: ephemeralBackend(failure: nil),
                remote: nil)
        }
        let backend = makeSessionBackend(for: sessions, environment: environment)
        return LaunchServices(
            settings: sharedSettings(),
            sessions: backend,
            remote: makeRemoteSupport(cttyExec: backend.cttyExec, environment: environment))
    }

    /// The persistent runtime the session registry asks for when it has none
    /// (a later attempt after the launch's failed): `nil` for a fatal plan
    /// (`makeBackend` is not called), with `ARMADALE_BACKEND=ephemeral`, or
    /// when the attempt gives no persistent backend. Internal, with
    /// `makeBackend` as a parameter, for the tests.
    static func persistentRuntimeForRegistry(
        plan: LaunchPlan,
        sessions: [Session],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        makeBackend: ([Session], [String: String]) -> SessionBackend = { AppDelegate.makeSessionBackend(for: $0, environment: $1) }
    ) -> SessionBackend? {
        guard plan.usesStateDirectory, environment["ARMADALE_BACKEND"] != "ephemeral" else { return nil }
        let backend = makeBackend(sessions, environment)
        return backend.setup.isPersistent ? backend : nil
    }

    /// The state this launch starts from: nothing when another process
    /// holds the lock (`refusal`), else `stateURL` loaded. Internal for the
    /// tests.
    static func launchState(refusal: InstanceLock.Refusal?, stateURL: URL) -> LoadedState {
        refusal.map(Self.lockedOut) ?? Self.loadState(from: stateURL)
    }

    /// Another process owns the state directory: nothing is loaded, nothing
    /// will be saved, and the alert explains before the app quits.
    private static func lockedOut(_ refusal: InstanceLock.Refusal) -> LoadedState {
        LoadedState(
            state: .empty,
            report: LoadReport(
                message: refusal.message, details: refusal.details, isFatal: true, bringForward: refusal.otherPID),
            canSave: false,
            mayReclaimOrphans: false)
    }

    /// Loads `url` with ``StateStore``, repairs it, keeps it as the launch
    /// backup when `state.json` itself was read, and marks the saved
    /// sessions incomplete when it was not (docs/DESIGN.md sections 3 and
    /// 4). Internal so the tests can run it against a temporary directory.
    static func loadState(from url: URL) -> LoadedState {
        var droppedWorkspaces = 0
        let result = StateStore.load(from: url) { droppedWorkspaces = $0 }
        var state = result.state ?? .empty
        var report: LoadReport?

        switch result {
        case .loaded:
            break
        case .unparseable(let fullProblem, let recovered, let backup, let quarantined):
            // The problem is a sentence of its own ("…correct format."): one
            // period less, so it can sit inside another.
            let problem = Self.withoutFinalPeriod(fullProblem)
            let kept = quarantined.isEmpty
                ? ""
                : quarantined.count == 1
                    ? " The unreadable file was kept at: \(quarantined[0].path)."
                    : " The unreadable files were kept at: \(quarantined.map(\.path).joined(separator: ", "))."
            let which = switch backup {
            case .launch: "the backup kept at an earlier launch (\(StateStore.launchBackupURL(for: url).lastPathComponent))"
            case .previousSave, nil: "the previous backup (\(StateStore.backupURL(for: url).lastPathComponent))"
            }
            report = recovered == nil
                ? LoadReport(
                    message: "Armadale could not read its saved layout",
                    details: "\(problem). Armadale started with a new workspace.\(kept)",
                    isFatal: false)
                : LoadReport(
                    message: "Armadale restored its layout from a backup",
                    details: "The saved layout could not be read (\(problem)), so \(which) was used.\(kept)",
                    isFatal: false)
        case .newerVersion(let version, let file):
            report = LoadReport(
                message: "This version of Armadale is too old for your saved layout",
                details: "\(file.path) uses layout format \(version), but this version of Armadale only "
                    + "understands format \(PersistedState.currentSchemaVersion). Your layout has not been changed. "
                    + "Please open a newer version of Armadale.",
                isFatal: true)
        case .ioError(let message, let file):
            report = LoadReport(
                message: "Armadale could not read its saved layout",
                details: "\(file.path) could not be read: \(Self.withoutFinalPeriod(message)). The file has not been changed. "
                    + "Check its permissions and open Armadale again.",
                isFatal: true)
        }

        if droppedWorkspaces > 0 {
            stateLog.notice(
                "Armadale: dropped \(droppedWorkspaces, privacy: .public) closed workspace(s) with no tab groups from the saved layout")
        }
        let (repaired, issues) = state.repaired()
        if !issues.isEmpty {
            stateLog.notice("Armadale: repaired saved layout: \(issues.joined(separator: "; "), privacy: .public)")
            state = repaired
        }
        // Orphan reclaim needs `state.json` itself, read as written and not
        // marked incomplete: with no file at all (first launch, or a file the
        // user removed), a damaged one or a backup, the references are
        // unknown, and running sessions must not be ended. Such a launch
        // marks its state incomplete, so a file saved before the live probe
        // answers holds the reclaim back at the next launch too.
        let readStateFile = result.readStateFile
        let mayReclaim = readStateFile && !state.sessionListIncomplete
        if readStateFile {
            // Before the first save: a copy this build could read, kept
            // however many saves follow (docs/DESIGN.md section 3).
            do {
                try StateStore.keepLaunchBackup(of: url)
            } catch {
                stateLog.error("Armadale: could not keep the launch backup: \(String(describing: error), privacy: .public)")
            }
        } else if result.allowsSaving, !state.sessionListIncomplete {
            state.sessionListIncomplete = true
            stateLog.notice("Armadale: the saved layout was not read as written; no running session will be ended until the running ones are recorded")
        }
        return LoadedState(
            state: state, report: report, canSave: result.allowsSaving, mayReclaimOrphans: mayReclaim)
    }

    /// `text` without one trailing period, for a sentence built around it.
    static func withoutFinalPeriod(_ text: String) -> String {
        text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    // MARK: Sessions

    /// What runs the app's (local) sessions, and how it was set up.
    struct SessionBackend {
        var setup: SessionRuntimeSetup
        var runtime: ZmxRuntime?
        var failure: String?
        /// The installed `ctty-exec`, when the installer ran.
        var cttyExec: String?
    }

    /// SSH hosts (docs/DESIGN.md section 6): the system's OpenSSH, with its
    /// shared connections' sockets in the runtime directory (or the `/tmp`
    /// fallback when that is too long for them).
    private static func makeRemoteSupport(cttyExec: String?, environment: [String: String]) -> RemoteSessionSupport {
        let runtimeDirectory = ZmxRuntime.directory(forStateDirectory: StateLocation.directory(environment: environment))
        let transport = OpenSSHTransport(
            controlDirectory: OpenSSHTransport.controlDirectory(forRuntimeDirectory: runtimeDirectory),
            environment: OpenSSHTransport.clientEnvironment(environment))
        return RemoteSessionSupport(
            transport: transport,
            cttyExec: cttyExec,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    }

    /// Plain PTY sessions that end when the app quits; nothing on disk.
    private static func ephemeralBackend(failure: String?) -> SessionBackend {
        SessionBackend(
            setup: SessionRuntimeSetup(
                backend: EphemeralBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            runtime: nil, failure: failure)
    }

    /// The persistent zmx backend, with the helpers installed into the
    /// state directory's `bin/`. If that cannot be set up the app still
    /// works, with sessions that end when it quits. `ARMADALE_BACKEND=ephemeral`
    /// selects those deliberately (tests, debugging).
    static func makeSessionBackend(for sessions: [Session], environment: [String: String]) -> SessionBackend {
        let ephemeral = ephemeralBackend(failure:)
        if environment["ARMADALE_BACKEND"] == "ephemeral" {
            return ephemeral(nil)
        }
        do {
            let installer = try HelperInstaller.forApp(environment: environment)
            let installed = try installer.install(
                referencedZmxVersions: Set(sessions.compactMap(\.runtimeVersion)))
            let runtime = ZmxRuntime(stateDirectory: StateLocation.directory(environment: environment))
            try runtime.prepare()
            let backend = LocalZmxBackend(configuration: LocalZmxBackend.Configuration(
                runtime: runtime,
                executables: installed.zmxExecutables,
                cttyExec: installed.cttyExec.path,
                resolver: LaunchResolver()))
            let versions = Dictionary(
                sessions.compactMap { session in session.runtimeVersion.map { (session.id, $0) } },
                uniquingKeysWith: { _, last in last })
            Task { await backend.noteRuntimeVersions(versions) }
            return SessionBackend(
                setup: SessionRuntimeSetup(
                    backend: backend, makeOutputFilter: { ZmxOutputFilter() }, isPersistent: true,
                    socketSessions: { runtime.sessionsAliveWithoutListing() }),
                runtime: runtime, failure: nil, cttyExec: installed.cttyExec.path)
        } catch {
            NSLog("Armadale: persistent sessions unavailable: %@", String(describing: error))
            return ephemeral(String(describing: error))
        }
    }

    /// Before any window shows: restored local sessions whose programs
    /// exited cleanly while Armadale was not running lose their panes
    /// (DESIGN §4, "Ended"), which may delete workspaces, every one
    /// included: it runs before ``AppModel/ensureWorkspacesToOpen()``, which
    /// then makes a fresh one. Their recorders' files say so; a file is
    /// only written once the program has ended, so this needs no listing
    /// and does not wait for the live probe.
    func closePanesOfSessionsThatEndedCleanly() {
        guard let runtime = zmxRuntime else { return }
        let closed = registry.closeLocalSessionsThatEndedCleanly(recordedIn: runtime)
        if !closed.isEmpty {
            stateLog.notice(
                "Armadale: closed \(closed.count, privacy: .public) pane(s) whose sessions exited cleanly while Armadale was not running")
        }
    }

    /// Launch housekeeping once the live probe has answered: ends live
    /// sessions no saved session refers to, unless they are spared, or
    /// spares them all when the saved sessions are not known to be complete
    /// (``OrphanReclaimer``), records the spared ones and, when that
    /// changed the model, saves at once;
    /// then removes the runtime's log and exit files of sessions that are
    /// neither alive (listed and not just ended, or with a socket:
    /// ``ZmxRuntime/aliveForHousekeeping(listed:ended:sockets:)``) nor in
    /// the model. Without the runtime or the probe's answer nothing is
    /// recorded, and the state stays marked incomplete.
    func collectGarbageAfterProbe() {
        guard let runtime = zmxRuntime else { return }
        let model = model
        let probe = registry.liveProbe
        let backend = registry.backend
        let mayReclaim = mayReclaimOrphans
        Task { [weak self] in
            guard let live = await probe.value else { return }
            // Sessions whose socket exists, listed or not (a stopped daemon
            // is not listed). Held back, they are spared too; on every
            // launch they count as running and keep their files.
            let sockets = runtime.sessionsWithSockets()
            let outcome = await OrphanReclaimer.reclaim(
                live: live, present: sockets, model: model, mayReclaim: mayReclaim, backend: backend)
            if outcome.changedModel { self?.saveNow() }
            let killed = outcome.ended
            let referenced = Set(model.sessions.map(\.id))
            stateLog.notice(
                "Armadale: launch reclaim \(mayReclaim ? "allowed" : "held back", privacy: .public): \(live.count, privacy: .public) live session(s), ended \(killed.count, privacy: .public) that no saved session refers to, \(outcome.spared.count, privacy: .public) recorded as spared (\(outcome.sparedRunning, privacy: .public) running)")
            let alive = ZmxRuntime.aliveForHousekeeping(listed: live, ended: Set(killed), sockets: sockets)
            let removed = runtime.collectGarbageLogs(live: alive, referenced: referenced)
            if !removed.isEmpty {
                stateLog.notice("Armadale: removed \(removed.count, privacy: .public) log file(s) of ended sessions")
            }
            let exitFiles = runtime.collectGarbageExitStatuses(live: alive, referenced: referenced)
            if !exitFiles.isEmpty {
                stateLog.notice("Armadale: removed \(exitFiles.count, privacy: .public) exit file(s) of ended sessions")
            }
        }
    }
}
