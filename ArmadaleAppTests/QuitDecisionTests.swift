import AppKit
import ArmadaleCore
import ArmadaleSessions
import Foundation
import Testing

/// Quitting with running sessions (docs/DESIGN.md section 8): the decision,
/// what counts as running, the wording, and the status item's menu. The
/// alert and the activation-policy switch are AppKit and checked live.
@Suite("Quit decision and menu bar mode")
@MainActor
struct QuitDecisionTests {
    private typealias Choice = Preferences.QuitWithRunningSessions

    private func item(_ status: SessionStatus, mayExist: Bool = true, running: Bool = false) -> CloseRisk.Item {
        CloseRisk.Item(status: status, mayExist: mayExist, isRunning: running)
    }

    // MARK: Decision

    @Test func noRunningSessionsQuitsAtOnceWhateverThePreference() {
        for choice in Choice.allCases {
            #expect(QuitDecision.decide(running: 0, preference: choice, context: .init()) == .quitNow)
        }
    }

    @Test func runningSessionsFollowThePreference() {
        #expect(QuitDecision.decide(running: 3, preference: .ask, context: .init()) == .ask(running: 3))
        #expect(QuitDecision.decide(running: 1, preference: .keepInMenuBar, context: .init()) == .keepInMenuBar)
        #expect(QuitDecision.decide(running: 2, preference: .endSessions, context: .init()) == .endSessions)
    }

    @Test func aForcedQuitNeverAsksNorStays() {
        // SIGTERM (logout), a system quit event, a launch that cannot go on.
        let forced = QuitDecision.Context(isForced: true)
        for choice in Choice.allCases {
            #expect(QuitDecision.decide(running: 4, preference: choice, context: forced) == .quitNow)
        }
        // Even while End Sessions and Quit is under way: logout must not wait.
        let forcedWhileEnding = QuitDecision.Context(isForced: true, isEndingSessions: true)
        #expect(QuitDecision.decide(running: 4, preference: .ask, context: forcedWhileEnding) == .quitNow)
    }

    @Test func aQuitFromMenuBarModeKeepsTheSessions() {
        let inMenuBar = QuitDecision.Context(isInMenuBar: true)
        for choice in Choice.allCases {
            #expect(QuitDecision.decide(running: 2, preference: choice, context: inMenuBar) == .quitNow)
        }
    }

    /// After macOS was found to have ended sessions once (Background App
    /// Activity), a quit from menu bar mode that would leave local sessions
    /// to the system asks first; nothing else changes.
    @Test func aQuitFromMenuBarModeAsksWhileALossHasBeenSeen() {
        let atRisk = QuitDecision.Context(isInMenuBar: true, lossSeen: true, localAtRisk: 3)
        for choice in Choice.allCases {
            #expect(QuitDecision.decide(running: 4, preference: choice, context: atRisk) == .confirmLeavingSessions(atRisk: 3))
        }
        // No loss seen, or no local session left to the system (remote ones
        // only, the fallback runtime, nothing running): a plain quit.
        let noLoss = QuitDecision.Context(isInMenuBar: true, lossSeen: false, localAtRisk: 3)
        #expect(QuitDecision.decide(running: 3, preference: .ask, context: noLoss) == .quitNow)
        let remoteOnly = QuitDecision.Context(isInMenuBar: true, lossSeen: true, localAtRisk: 0)
        #expect(QuitDecision.decide(running: 2, preference: .ask, context: remoteOnly) == .quitNow)
        // Forced quits never ask; End Sessions and Quit's own quit and its
        // run are unchanged.
        let forced = QuitDecision.Context(isForced: true, isInMenuBar: true, lossSeen: true, localAtRisk: 3)
        #expect(QuitDecision.decide(running: 3, preference: .ask, context: forced) == .quitNow)
        let ended = QuitDecision.Context(isInMenuBar: true, sessionsEnded: true, lossSeen: true, localAtRisk: 1)
        #expect(QuitDecision.decide(running: 1, preference: .ask, context: ended) == .quitNow)
        let ending = QuitDecision.Context(isInMenuBar: true, isEndingSessions: true, lossSeen: true, localAtRisk: 1)
        #expect(QuitDecision.decide(running: 1, preference: .ask, context: ending) == .cancel)
        // Outside menu bar mode the ⌘Q question is unchanged: neither answer
        // leaves sessions to the system.
        let regular = QuitDecision.Context(lossSeen: true, localAtRisk: 2)
        #expect(QuitDecision.decide(running: 2, preference: .ask, context: regular) == .ask(running: 2))
        #expect(QuitDecision.decide(running: 2, preference: .keepInMenuBar, context: regular) == .keepInMenuBar)
        #expect(QuitDecision.decide(running: 2, preference: .endSessions, context: regular) == .endSessions)
    }

    @Test func endingSessionsCancelsOtherQuitsThenQuitsItself() {
        let ending = QuitDecision.Context(isEndingSessions: true)
        #expect(QuitDecision.decide(running: 2, preference: .ask, context: ending) == .cancel)
        #expect(QuitDecision.decide(running: 0, preference: .ask, context: ending) == .cancel)
        let inMenuBarEnding = QuitDecision.Context(isInMenuBar: true, isEndingSessions: true)
        #expect(QuitDecision.decide(running: 2, preference: .ask, context: inMenuBarEnding) == .cancel)
        // Its own quit, after the sessions ended (a kill that failed may
        // leave one counted as running): straight through.
        let ended = QuitDecision.Context(sessionsEnded: true)
        #expect(QuitDecision.decide(running: 1, preference: .ask, context: ended) == .quitNow)
    }

    // MARK: What counts as running

    @Test func runningCountUsesTheCloseConfirmationRule() {
        #expect(QuitDecision.runningCount([]) == 0)
        #expect(QuitDecision.runningCount([item(.running), item(.disconnected), item(.attention)]) == 3)
        // Restored and not yet probed: may well be alive.
        #expect(QuitDecision.runningCount([item(.pending, mayExist: true)]) == 1)
        // Created in this run, never shown: no process.
        #expect(QuitDecision.runningCount([item(.pending, mayExist: false)]) == 0)
        #expect(QuitDecision.runningCount([item(.ended), item(.unavailable)]) == 0)
        #expect(QuitDecision.runningCount([item(.running), item(.ended), item(.pending, mayExist: false)]) == 1)
    }

    // MARK: System quit events

    @Test func aQuitEventWithAReasonIsASystemQuit() {
        func quitEvent(reason: OSType?, asAttribute: Bool = false) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID))
            if let reason {
                let value = NSAppleEventDescriptor(enumCode: reason)
                if asAttribute {
                    event.setAttribute(value, forKeyword: AEKeyword(kAEQuitReason))
                } else {
                    event.setParam(value, forKeyword: AEKeyword(kAEQuitReason))
                }
            }
            return event
        }
        #expect(!AppDelegate.isSystemQuit(nil), "⌘Q has no Apple event")
        #expect(!AppDelegate.isSystemQuit(quitEvent(reason: nil)), "the Dock's Quit, AppleScript's quit")
        #expect(AppDelegate.isSystemQuit(quitEvent(reason: OSType(kAEReallyLogOut))))
        #expect(AppDelegate.isSystemQuit(quitEvent(reason: OSType(kAEShutDown), asAttribute: true)))
        #expect(AppDelegate.isSystemQuit(quitEvent(reason: OSType(kAERestart))))
        let open = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        open.setParam(NSAppleEventDescriptor(enumCode: OSType(kAEShutDown)), forKeyword: AEKeyword(kAEQuitReason))
        #expect(!AppDelegate.isSystemQuit(open), "only a quit event")
    }

    // MARK: Wording and menu

    @Test func wording() {
        #expect(MenuBarText.alertMessage(running: 1) == "1 session is still running")
        #expect(MenuBarText.alertMessage(running: 3) == "3 sessions are still running")
        #expect(MenuBarText.alertInformative(running: 1).hasPrefix("Armadale can keep the session running"))
        #expect(MenuBarText.alertInformative(running: 1).hasSuffix("every program running in it."))
        #expect(!MenuBarText.alertInformative(running: 1).contains("them"), "one session is not \"them\"")
        #expect(MenuBarText.alertInformative(running: 2).hasPrefix("Armadale can keep them running"))
        #expect(MenuBarText.runningLine(1) == "1 session running")
        #expect(MenuBarText.runningLine(0) == "0 sessions running")
        #expect(MenuBarText.buttonTitle(attentionTotal: 0).isEmpty)
        #expect(MenuBarText.buttonTitle(attentionTotal: 2) == "2")
        #expect(MenuBarText.toolTip(attentionTotal: 1, isRunning: true) == "Armadale: 1 session needs attention")
        #expect(MenuBarText.toolTip(attentionTotal: 0, isRunning: true) == "Armadale: sessions running")
        #expect(MenuBarText.toolTip(attentionTotal: 0, isRunning: false) == "Armadale", "no session running")
        let visible = [
            MenuBarText.alertMessage(running: 2), MenuBarText.alertInformative(running: 1),
            MenuBarText.alertInformative(running: 2), MenuBarText.keepButton,
            MenuBarText.endButton, MenuBarText.cancelButton, MenuBarText.runningLine(2), MenuBarText.open,
            MenuBarText.settings, MenuBarText.quitKeepingSessions, MenuBarText.endSessionsAndQuit,
            MenuBarText.toolTip(attentionTotal: 0, isRunning: true), MenuBarText.toolTip(attentionTotal: 2, isRunning: true),
            MenuBarText.ending,
        ] + Choice.allCases.map(\.title) + backgroundActivityTexts
        for text in visible {
            #expect(!text.lowercased().contains("zmx"), "the persistence runtime is never named: \(text)")
        }
        #expect(Choice.allCases.map(\.title) == ["Ask", "Keep running in the menu bar", "End sessions"])
        #expect(MenuBarText.ending == "Ending sessions…")
    }

    private var backgroundActivityTexts: [String] {
        [
            BackgroundActivityText.lossMessage(ended: 1), BackgroundActivityText.lossMessage(ended: 3),
            BackgroundActivityText.lossInformative(ended: 1), BackgroundActivityText.lossInformative(ended: 3),
            BackgroundActivityText.quitMessage(atRisk: 1), BackgroundActivityText.quitMessage(atRisk: 3),
            BackgroundActivityText.quitInformative(atRisk: 1), BackgroundActivityText.quitInformative(atRisk: 3),
            BackgroundActivityText.openSettingsButton, BackgroundActivityText.notNowButton,
            BackgroundActivityText.quitAnywayButton, BackgroundActivityText.cancelButton,
        ]
    }

    @Test func backgroundActivityWording() {
        #expect(BackgroundActivityText.lossMessage(ended: 1) == "macOS ended 1 session after Armadale quit")
        #expect(BackgroundActivityText.lossMessage(ended: 3) == "macOS ended 3 sessions after Armadale quit")
        #expect(BackgroundActivityText.quitMessage(atRisk: 1) == "macOS may end 1 session when Armadale quits")
        #expect(BackgroundActivityText.quitMessage(atRisk: 3) == "macOS may end 3 sessions when Armadale quits")
        let path = "System Settings › General › Login Items & Extensions, under Background App Activity"
        for text in [1, 3].flatMap({ [BackgroundActivityText.lossInformative(ended: $0), BackgroundActivityText.quitInformative(atRisk: $0)] }) {
            #expect(text.contains(path), "\(text)")
            #expect(!text.contains("Allow in the Background"), "the name on macOS 13 to 26")
            #expect(!text.contains(".."), "\(text)")
        }
        #expect(BackgroundActivityText.lossInformative(ended: 1).hasPrefix("It was running when Armadale quit"))
        #expect(BackgroundActivityText.lossInformative(ended: 2).hasPrefix("They were running when Armadale quit"))
        #expect(BackgroundActivityText.lossInformative(ended: 2).hasSuffix("keep Armadale running in the menu bar instead."))
        let quitText = "After an earlier quit, macOS ended sessions a few seconds later. It does this when Armadale is "
            + "switched off in System Settings › General › Login Items & Extensions, under Background App Activity. "
            + "If you have switched Armadale on there since, the "
        #expect(BackgroundActivityText.quitInformative(atRisk: 1) == quitText + "session will keep running.")
        #expect(BackgroundActivityText.quitInformative(atRisk: 2) == quitText + "sessions will keep running.")
        #expect(BackgroundActivityText.openSettingsButton == "Open System Settings")
        #expect(BackgroundActivityText.notNowButton == "Not Now")
        #expect(BackgroundActivityText.quitAnywayButton == "Quit Anyway")
    }

    /// At launch Open System Settings answers Return; a late alert (up to
    /// 12 s after launch, maybe while typing into a pane) has no button that
    /// does. Not Now answers Escape in both.
    @Test func theLossAlertsKeys() {
        let atLaunch = BackgroundActivityText.lossAlert(ended: 2, late: false)
        #expect(atLaunch.message == "macOS ended 2 sessions after Armadale quit")
        #expect(atLaunch.informative == BackgroundActivityText.lossInformative(ended: 2))
        #expect(atLaunch.buttons == ["Open System Settings", "Not Now"])
        #expect(atLaunch.openSettingsKey == "\r")
        #expect(atLaunch.notNowKey == "\u{1b}")
        let late = BackgroundActivityText.lossAlert(ended: 1, late: true)
        #expect(late.message == "macOS ended 1 session after Armadale quit")
        #expect(late.buttons == atLaunch.buttons)
        #expect(late.openSettingsKey.isEmpty, "a stray Return does nothing")
        #expect(late.notNowKey == "\u{1b}")
    }

    /// A quit from menu bar mode that does not go through, like closing
    /// Settings there, hides the app when no window of its own is left.
    @Test func hidingInMenuBarMode() {
        #expect(AppDelegate.hidesInMenuBarMode(isInMenuBar: true, auxiliaryWindowVisible: false))
        #expect(!AppDelegate.hidesInMenuBarMode(isInMenuBar: true, auxiliaryWindowVisible: true), "⌘Q typed in Settings")
        #expect(!AppDelegate.hidesInMenuBarMode(isInMenuBar: false, auxiliaryWindowVisible: false))
        #expect(!AppDelegate.hidesInMenuBarMode(isInMenuBar: false, auxiliaryWindowVisible: true))
    }

    // MARK: Activation

    @Test func activationIsTakenFromAnotherFrontmostApp() throws {
        let current = NSRunningApplication.current
        let other = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != current.processIdentifier
        })
        #expect(AppActivation.source(frontmost: other, current: current) == other)
        #expect(AppActivation.source(frontmost: current, current: current) == nil, "already frontmost: a plain activate")
        #expect(AppActivation.source(frontmost: nil, current: current) == nil)
        let sameProcess = try #require(NSRunningApplication(processIdentifier: current.processIdentifier))
        #expect(AppActivation.source(frontmost: sameProcess, current: current) == nil, "compared by process, not object")
    }

    private final class Target: NSObject {
        @objc func open(_ sender: Any?) {}
        @objc func settings(_ sender: Any?) {}
        @objc func quit(_ sender: Any?) {}
        @objc func end(_ sender: Any?) {}
    }

    private func statusMenu(target: Target, sessionsSurviveQuit: Bool = true) -> NSMenu {
        MenuBarStatusItem.makeMenu(
            target: target,
            actions: MenuBarStatusItem.Actions(
                open: #selector(Target.open(_:)), settings: #selector(Target.settings(_:)),
                quitKeepingSessions: #selector(Target.quit(_:)), endSessionsAndQuit: #selector(Target.end(_:))),
            running: 2, sessionsSurviveQuit: sessionsSurviveQuit)
    }

    @Test func statusMenuItems() {
        let target = Target()
        let menu = statusMenu(target: target)
        #expect(menu.items.map(\.title) == [
            "2 sessions running", "Open Armadale", "Settings…", "", "Quit, Keep Sessions Running", "End Sessions and Quit",
        ])
        #expect(!menu.items[0].isEnabled, "the count is information only")
        #expect(menu.items[3].isSeparatorItem)
        #expect(menu.items[1].action == #selector(Target.open(_:)))
        #expect(menu.items[2].action == #selector(Target.settings(_:)))
        #expect(menu.items[4].action == #selector(Target.quit(_:)))
        #expect(menu.items[5].action == #selector(Target.end(_:)))
        for entry in menu.items where !entry.isSeparatorItem && entry.action != nil {
            #expect(entry.target === target)
            #expect(entry.isEnabled)
            #expect(entry.keyEquivalent.isEmpty)
            #expect(!entry.isHidden)
        }
    }

    @Test func withoutPersistenceTheKeepingQuitIsHidden() {
        // The fallback runtime: every local session would end with a quit.
        let menu = statusMenu(target: Target(), sessionsSurviveQuit: false)
        let visible = menu.items.filter { !$0.isHidden }.map(\.title)
        #expect(visible == ["2 sessions running", "Open Armadale", "Settings…", "", "End Sessions and Quit"])
    }

    @Test func endingDisablesTheStatusMenu() {
        let menu = statusMenu(target: Target())
        MenuBarStatusItem.showEnding(in: menu)
        #expect(menu.items[0].title == "Ending sessions…")
        #expect(menu.items.allSatisfy { !$0.isEnabled }, "nothing to choose until the app quits")
    }
}

/// A backend that starts nothing and records kills; `alive` is what its
/// launch probe reports.
actor KillRecordingBackend: PersistenceBackend {
    private(set) var alive: Set<SessionID>
    private(set) var killed: [SessionID] = []

    init(alive: Set<SessionID>) {
        self.alive = alive
    }

    func create(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        throw BackendError.runtimeFailure("recording test backend")
    }

    func attach(_ session: Session, size: PTYSize) async throws -> any ProcessHandle {
        throw BackendError.runtimeFailure("recording test backend")
    }

    func exists(_ id: SessionID) async throws -> Bool { alive.contains(id) }
    func liveSessions() async throws -> Set<SessionID> { alive }
    func kill(_ id: SessionID) async throws {
        killed.append(id)
        alive.remove(id)
    }
    func history(_ id: SessionID) async throws -> Data { throw BackendError.historyUnavailable(id) }
    func resolveExit(of session: Session) async -> ExitResolution { .ended(exitStatus: nil) }
}

@Suite("SessionRegistry running count and End Sessions")
@MainActor
struct RegistryQuitTests {
    @Test func countsRestoredSessionsAndEndsThemAll() async throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        model.fillEmptyPanes()
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let tab = try #require(model.newTab(in: group))
        model.fillEmptyPanes()
        let restored = Set(model.sessionIDs(in: workspace))
        #expect(restored.count == 2)
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let backend = KillRecordingBackend(alive: restored)
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: backend, makeOutputFilter: { IdentityOutputFilter() }, isPersistent: true),
            restoredSessionIDs: restored, settings: settings)
        // Before the probe has answered, restored sessions may be alive.
        #expect(registry.runningSessionCount() == 2)
        _ = await registry.liveProbe.value
        #expect(registry.runningSessionCount() == 2, "alive by the probe")

        // A tab created in this run and never shown has no process.
        _ = try #require(model.newTab(in: group))
        model.fillEmptyPanes()
        #expect(registry.runningSessionCount() == 2)

        let ended = await registry.endAllSessions()
        #expect(restored.isSubset(of: ended))
        // Covered and never shown: gone, whatever the launch probe said.
        #expect(registry.sessionsStillRunning().isEmpty)
        let killed = await backend.killed
        #expect(restored.isSubset(of: Set(killed)), "every restored session killed: \(killed)")
        #expect(await backend.alive.isEmpty)
        #expect(model.sessionIDs(ofTab: tab).count == 1, "the model is not changed")
    }

    @Test func aSecondPassCoversSessionsTheFirstDidNot() async throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        model.fillEmptyPanes()
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        _ = try #require(model.newTab(in: group))
        model.fillEmptyPanes()
        let restored = Set(model.sessionIDs(in: workspace))
        let first = try #require(restored.first)
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let backend = KillRecordingBackend(alive: restored)
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: backend, makeOutputFilter: { IdentityOutputFilter() }, isPersistent: true),
            restoredSessionIDs: restored, settings: settings)
        #expect(registry.sessionsSurviveQuit)
        _ = await registry.liveProbe.value
        // A pass that covered only one session leaves the other running.
        let ended = await registry.endAllSessions(only: [first])
        #expect(ended == [first])
        let remaining = registry.sessionsStillRunning()
        #expect(remaining == restored.subtracting([first]))
        await registry.endAllSessions(only: remaining)
        #expect(Set(await backend.killed) == restored)
    }

    /// What a quit leaves to the system (Background App Activity): local
    /// sessions of the persistent runtime that may be running; none in the
    /// fallback.
    @Test func localSessionsThatMayOutliveQuit() throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        model.fillEmptyPanes()
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        _ = try #require(model.newTab(in: group))
        model.fillEmptyPanes()
        _ = try #require(model.newTab(in: group))
        model.fillEmptyPanes()
        let ids = model.sessionIDs(in: workspace)
        #expect(ids.count == 3)
        // Two made by the persistent runtime, one by the plain PTY fallback
        // of an earlier run (no runtime version).
        model.setRuntimeVersion("0.8.1", for: ids[0])
        model.setRuntimeVersion("0.8.1", for: ids[1])
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        func registry(alive: Set<SessionID>, persistent: Bool) -> SessionRegistry {
            SessionRegistry(
                model: model,
                runtime: SessionRuntimeSetup(
                    backend: KillRecordingBackend(alive: alive), makeOutputFilter: { IdentityOutputFilter() },
                    isPersistent: persistent),
                restoredSessionIDs: Set(ids), settings: settings)
        }
        let persistent = registry(alive: Set(ids), persistent: true)
        #expect(Set(persistent.localSessionsThatMayOutliveQuit()) == [ids[0], ids[1]])
        #expect(persistent.runningSessionCount() == 3, "the quit question still counts every one")
        let fallback = registry(alive: Set(ids), persistent: false)
        #expect(fallback.localSessionsThatMayOutliveQuit().isEmpty)
    }

    /// One session's part of what a quit leaves to the system: local, made
    /// by the persistent runtime, possibly running; each condition matters.
    @Test func whichSessionMayOutliveAQuit() {
        func session(_ location: Location = .local, version: String? = "0.8.1") -> Session {
            Session(location: location, profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "/",
                    runtimeVersion: version)
        }
        let running = CloseRisk.Item(status: .running, mayExist: true)
        #expect(SessionRegistry.mayOutliveQuit(session(), risk: running))
        #expect(!SessionRegistry.mayOutliveQuit(session(.remote(host: HostID.generate())), risk: running),
                "remote: no local process")
        #expect(!SessionRegistry.mayOutliveQuit(session(version: nil), risk: running), "the plain PTY fallback's")
        #expect(!SessionRegistry.mayOutliveQuit(session(), risk: CloseRisk.Item(status: .ended, mayExist: true)), "ended")
        #expect(!SessionRegistry.mayOutliveQuit(session(), risk: CloseRisk.Item(status: .pending, mayExist: false)),
                "created in this run and never started")
        #expect(!SessionRegistry.mayOutliveQuit(session(), risk: CloseRisk.Item(status: .unavailable, mayExist: true)))
        #expect(SessionRegistry.mayOutliveQuit(session(), risk: CloseRisk.Item(status: .pending, mayExist: true)),
                "restored, not yet probed")
        #expect(SessionRegistry.mayOutliveQuit(session(), risk: CloseRisk.Item(status: .ended, mayExist: true, isRunning: true)),
                "its client still reports a process")
    }

    @Test func nothingRunningInAFreshModel() {
        let model = AppModel(defaultWorkingDirectory: "/")
        _ = model.newWorkspace(name: "W")
        model.fillEmptyPanes()
        let settings = AppSettings.forTesting()
        defer { settings.removeTestDefaults() }
        let registry = SessionRegistry(
            model: model,
            runtime: SessionRuntimeSetup(
                backend: InertBackend(), makeOutputFilter: { IdentityOutputFilter() }, isPersistent: false),
            restoredSessionIDs: [], settings: settings)
        #expect(!registry.sessionsSurviveQuit, "the fallback runtime")
        #expect(registry.runningSessionCount() == 0)
        #expect(QuitDecision.decide(
            running: registry.runningSessionCount(), preference: .ask, context: .init()) == .quitNow)
    }
}
