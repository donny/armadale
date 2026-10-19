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
        #expect(MenuBarText.runningLine(1) == "1 session running")
        #expect(MenuBarText.runningLine(0) == "0 sessions running")
        #expect(MenuBarText.buttonTitle(attentionTotal: 0).isEmpty)
        #expect(MenuBarText.buttonTitle(attentionTotal: 2) == "2")
        #expect(MenuBarText.toolTip(attentionTotal: 1) == "Armadale: 1 session needs attention")
        let visible = [
            MenuBarText.alertMessage(running: 2), MenuBarText.alertInformative, MenuBarText.keepButton,
            MenuBarText.endButton, MenuBarText.cancelButton, MenuBarText.runningLine(2), MenuBarText.open,
            MenuBarText.settings, MenuBarText.quitKeepingSessions, MenuBarText.endSessionsAndQuit,
            MenuBarText.toolTip(attentionTotal: 0), MenuBarText.toolTip(attentionTotal: 2), MenuBarText.ending,
        ] + Choice.allCases.map(\.title)
        for text in visible {
            #expect(!text.lowercased().contains("zmx"), "the persistence runtime is never named: \(text)")
        }
        #expect(Choice.allCases.map(\.title) == ["Ask", "Keep running in the menu bar", "End sessions"])
        #expect(MenuBarText.ending == "Ending sessions…")
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
    func resolveExit(of session: Session) async -> ExitResolution { .ended }
}

@Suite("SessionRegistry running count and End Sessions")
@MainActor
struct RegistryQuitTests {
    @Test func countsRestoredSessionsAndEndsThemAll() async throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        let tab = try #require(model.newTab(in: group))
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
        #expect(registry.runningSessionCount() == 2)

        let ended = await registry.endAllSessions()
        #expect(restored.isSubset(of: ended))
        // Covered and never shown: gone, whatever the launch probe said.
        #expect(registry.sessionsRunning(after: ended).isEmpty)
        let killed = await backend.killed
        #expect(restored.isSubset(of: Set(killed)), "every restored session killed: \(killed)")
        #expect(await backend.alive.isEmpty)
        #expect(model.sessionIDs(ofTab: tab).count == 1, "the model is not changed")
    }

    @Test func aSecondPassCoversSessionsTheFirstDidNot() async throws {
        let model = AppModel(defaultWorkingDirectory: "/")
        let workspace = model.newWorkspace(name: "W")
        let group = try #require(model.workspace(workspace)?.selectedTabGroupID)
        _ = try #require(model.newTab(in: group))
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
        let remaining = registry.sessionsRunning(after: ended)
        #expect(remaining == restored.subtracting([first]))
        await registry.endAllSessions(only: remaining)
        #expect(Set(await backend.killed) == restored)
    }

    @Test func nothingRunningInAFreshModel() {
        let model = AppModel(defaultWorkingDirectory: "/")
        _ = model.newWorkspace(name: "W")
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
