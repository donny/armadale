import AppKit
import ArmadaleCore
import ArmadaleSessions
import Foundation
import Testing

/// Updates (docs/DESIGN.md section 8, "Updates"): when the updater starts,
/// what Armadale tells the user before the quit Sparkle sends to install an
/// update, the gate that lets that quit through and never longer, the menu
/// bar reminder, the menus and the wording. Sparkle itself is not in this
/// bundle: ``UpdateCoordinator`` is driven here the way Sparkle's callbacks
/// drive it (SPUInstallerDriver.m, `installWithToolAndRelaunch:`).
@Suite("Updates")
@MainActor
struct UpdatesTests {
    // MARK: When the updater starts

    private static let shipped: [String: Any] = [
        "SUFeedURL": "https://armadale.dev/appcast.xml",
        "SUPublicEDKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    ]

    @Test func updaterPolicyTable() {
        let noKey: [String: Any] = ["SUFeedURL": "https://armadale.dev/appcast.xml"]
        let blankKey: [String: Any] = ["SUFeedURL": "https://armadale.dev/appcast.xml", "SUPublicEDKey": " "]
        let noFeed: [String: Any] = ["SUPublicEDKey": "AAAA"]
        let stateDir = ["ARMADALE_STATE_DIR": "/tmp/armadale-x"]
        let suite = ["ARMADALE_DEFAULTS_SUITE": "armadale-x"]
        let override = ["ARMADALE_UPDATER_FOR_TEST": "1"]
        func both(_ a: [String: String], _ b: [String: String]) -> [String: String] { a.merging(b) { $1 } }

        let debugOnly: [String: String] = [:]
        typealias Row = (fatal: Bool, debug: Bool, info: [String: Any], env: [String: String], args: [String],
                         expected: UpdaterPolicy.Verdict)
        let rows: [Row] = [
            // A Release build, nothing set: the only run that starts by itself.
            (false, false, Self.shipped, [:], [], .start),
            // A fatal launch: never, whatever else.
            (true, false, Self.shipped, [:], [], .off(.fatalLaunch)),
            (true, false, Self.shipped, override, [], .off(.fatalLaunch)),
            (true, true, Self.shipped, override, [], .off(.fatalLaunch)),
            // No key or no feed: never, the test switch included.
            (false, false, noKey, [:], [], .off(.noPublicKey)),
            (false, false, blankKey, [:], [], .off(.noPublicKey)),
            (false, false, noKey, both(stateDir, override), [], .off(.noPublicKey)),
            (false, true, noKey, override, [], .off(.noPublicKey)),
            (false, false, noFeed, [:], [], .off(.noFeed)),
            (false, true, noFeed, override, [], .off(.noFeed)),
            // A Debug build, however it was started.
            (false, true, Self.shipped, debugOnly, [], .off(.debugBuild)),
            (false, true, Self.shipped, stateDir, [], .off(.debugBuild)),
            (false, true, Self.shipped, ["ARMADALE_UPDATER_FOR_TEST": "yes"], [], .off(.debugBuild)),
            // An isolated Release run.
            (false, false, Self.shipped, stateDir, [], .off(.isolatedRun)),
            (false, false, Self.shipped, suite, [], .off(.isolatedRun)),
            (false, false, Self.shipped, [:], ["Armadale", "-ArmadaleDefaultsSuite", "armadale-x"], .off(.isolatedRun)),
            (false, false, Self.shipped, both(stateDir, suite), [], .off(.isolatedRun)),
            (false, false, Self.shipped, ["ARMADALE_STATE_DIR": ""], [], .start),
            (false, false, Self.shipped, both(stateDir, ["ARMADALE_UPDATER_FOR_TEST": "yes"]), [], .off(.isolatedRun)),
            // The test switch lifts the Debug build and the isolated run.
            (false, false, Self.shipped, both(both(stateDir, suite), override), [], .start),
            (false, true, Self.shipped, override, [], .start),
            (false, true, Self.shipped, both(both(stateDir, suite), override), [], .start),
        ]
        for row in rows {
            #expect(
                UpdaterPolicy.verdict(
                    launchIsFatal: row.fatal, isDebugBuild: row.debug, info: row.info, environment: row.env,
                    arguments: row.args) == row.expected,
                "debug \(row.debug) \(row.env) \(row.args)")
        }
        #expect(UpdaterPolicy.isDebugBuild, "the test bundle is built Debug")
    }

    /// The app's own Info.plist (project.yml): the feed, verification before
    /// the DMG is mounted, no automatic installs, no system profile, and no
    /// automatic-check key, so Sparkle asks once.
    @Test func infoPlistCarriesTheUpdaterKeys() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Armadale/Resources/Info.plist")
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(plist["SUFeedURL"] as? String == "https://armadale.dev/appcast.xml")
        #expect(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(plist["SUAllowsAutomaticUpdates"] as? Bool == false)
        // No system profile, by any of Sparkle's keys, and no JavaScript in
        // release notes.
        for key in ["SUEnableSystemProfiling", "SUSendProfileInfo", "SUEnableJavaScript"] {
            #expect(plist[key] == nil, "\(key)")
        }
        #expect(plist["SUEnableAutomaticChecks"] == nil)
        #expect(plist["SUAutomaticallyUpdate"] == nil)
        for key in ["SUEnableInstallerLauncherService", "SUEnableDownloaderService"] {
            #expect(plist[key] == nil, "not sandboxed: no XPC services")
        }
    }

    // MARK: Before the update's quit

    private typealias Context = UpdateQuitDecision.Context

    @Test func updateQuitDecisionTable() {
        let rows: [(Context, UpdateQuitDecision)] = [
            // Every session survives a quit: nothing to tell.
            (Context(), .install),
            (Context(localAtRisk: 3), .install),
            // Sessions on the fallback, or on a host without the helper.
            (Context(endingAtQuit: 1), .confirmEnding(sessions: 1)),
            (Context(endingAtQuit: 2, localAtRisk: 4), .confirmEnding(sessions: 2)),
            // After a loss was seen, with local sessions left to macOS.
            (Context(lossSeen: true, localAtRisk: 2), .confirmLeavingSessions(atRisk: 2, ending: 0)),
            (Context(endingAtQuit: 1, lossSeen: true, localAtRisk: 2), .confirmLeavingSessions(atRisk: 2, ending: 1)),
            // A loss seen, but nothing local at risk.
            (Context(lossSeen: true), .install),
            (Context(endingAtQuit: 3, lossSeen: true), .confirmEnding(sessions: 3)),
            // End Sessions and Quit under way, or a quit going through.
            (Context(isEndingSessions: true), .refuse),
            (Context(isEndingSessions: true, endingAtQuit: 2, lossSeen: true, localAtRisk: 1), .refuse),
            (Context(isQuitting: true), .refuse),
        ]
        for (context, expected) in rows {
            #expect(UpdateQuitDecision.decide(context) == expected, "\(context)")
        }
    }

    /// The update's quit goes straight through, sessions kept, whatever the
    /// preference and in menu bar mode too; not past End Sessions and Quit.
    @Test func theUpdateQuitGoesStraightThrough() {
        for choice in Preferences.QuitWithRunningSessions.allCases {
            #expect(QuitDecision.decide(running: 3, preference: choice, context: .init(isUpdateQuit: true)) == .quitNow)
            #expect(
                QuitDecision.decide(
                    running: 3, preference: choice,
                    context: .init(isInMenuBar: true, lossSeen: true, localAtRisk: 3, isUpdateQuit: true)) == .quitNow)
        }
        #expect(
            QuitDecision.decide(running: 3, preference: .ask, context: .init(isEndingSessions: true, isUpdateQuit: true))
                == .cancel)
        // Written as a user's quit, as Quit, Keep Sessions Running is.
        #expect(AppDelegate.kindOfQuit(isSignal: false, isSystem: false, sessionsEnded: false) == .user)
    }

    @Test func theGateClosesAfterItsLifetime() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var gate = UpdateQuitGate()
        #expect(!gate.letsQuitThrough(at: start))
        gate.open(at: start)
        #expect(gate.letsQuitThrough(at: start))
        #expect(gate.letsQuitThrough(at: start.addingTimeInterval(UpdateQuitGate.lifetime)))
        #expect(!gate.letsQuitThrough(at: start.addingTimeInterval(UpdateQuitGate.lifetime + 1)))
        #expect(!gate.letsQuitThrough(at: start.addingTimeInterval(-5)), "a clock set back closes it")
        gate.close()
        #expect(!gate.letsQuitThrough(at: start))
    }

    // MARK: The coordinator, driven as Sparkle drives it

    private final class FakeHost: UpdateHost {
        var context = Context()
        var answer: UpdateQuitAnswer = .install
        var asked: [UpdateQuitDecision] = []
        var isInMenuBarMode = false
        var sessionEnds: [Bool] = []
        var settingsChanges = 0
        /// Changes the context while the alert is up.
        var whileAsking: (() -> Void)?

        func updateQuitContext() -> Context { context }
        func askBeforeUpdateQuit(_ decision: UpdateQuitDecision) -> UpdateQuitAnswer {
            asked.append(decision)
            whileAsking?()
            return answer
        }
        func updateSessionEnded(mayHide: Bool) { sessionEnds.append(mayHide) }
        func updateSettingsChanged() { settingsChanges += 1 }
    }

    /// A clock the test moves, and a coordinator whose decision runs only
    /// when the test says (as on Sparkle's next run-loop turn).
    private final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 5000)
    }

    private func coordinator(_ host: FakeHost, clock: Clock = Clock()) -> UpdateCoordinator {
        let coordinator = UpdateCoordinator(now: { clock.now }, scheduleDecision: { _ in })
        coordinator.host = host
        return coordinator
    }

    /// What Sparkle does after the user's Install and Relaunch, in
    /// `installWithToolAndRelaunch:` and the core driver: the relaunch check,
    /// the postpone hook once, then (when resumed) the check again and the
    /// relaunch notice. Returns whether Sparkle would go on to quit the app
    /// (false: it aborts the install).
    @MainActor
    private final class SparkleInstall {
        let coordinator: UpdateCoordinator
        var postponedOnce = false
        var outcome: Bool?

        init(_ coordinator: UpdateCoordinator) { self.coordinator = coordinator }

        func installAndRelaunch() {
            guard coordinator.shouldRelaunch() else {
                outcome = false
                // A no aborts with no error (SPUInstallerDriver.m 515–519);
                // the UI driver's abort calls dismissUpdateInstallation
                // (SPUUIBasedUpdateDriver.m 452–494), which tells the
                // delegate standardUserDriverWillFinishUpdateSession
                // (SPUStandardUserDriver.m 927–933).
                coordinator.updateSessionWillFinish()
                return
            }
            if !postponedOnce {
                postponedOnce = true
                if coordinator.postponeRelaunch(resume: { [weak self] in self?.installAndRelaunch() }) { return }
            }
            coordinator.willRelaunch()
            outcome = true
        }
    }

    @Test func nothingToTellInstallsAndLetsTheQuitThrough() {
        let host = FakeHost()
        let clock = Clock()
        let coordinator = coordinator(host, clock: clock)
        let install = SparkleInstall(coordinator)
        install.installAndRelaunch()
        #expect(install.outcome == nil, "postponed until the next turn")
        #expect(!coordinator.gateIsOpen)
        coordinator.runPendingDecision()
        #expect(install.outcome == true)
        #expect(host.asked.isEmpty)
        #expect(coordinator.gateIsOpen, "Sparkle's quit goes straight through")
        // A second turn does nothing.
        coordinator.runPendingDecision()
        #expect(install.outcome == true)
    }

    @Test func sessionsThatWouldEndAskAndInstallOnYes() {
        let host = FakeHost()
        host.context = Context(endingAtQuit: 2)
        let coordinator = coordinator(host)
        let install = SparkleInstall(coordinator)
        install.installAndRelaunch()
        coordinator.runPendingDecision()
        #expect(host.asked == [.confirmEnding(sessions: 2)])
        #expect(install.outcome == true)
        #expect(coordinator.gateIsOpen)
    }

    /// Cancel: Sparkle is resumed and told not to relaunch, which aborts
    /// its session (windows closed); the gate never opens, so a later ⌘Q
    /// gets the usual question.
    @Test func cancelAbortsAndALaterQuitIsOrdinary() {
        let host = FakeHost()
        host.context = Context(endingAtQuit: 1)
        host.answer = .cancel
        let coordinator = coordinator(host)
        let install = SparkleInstall(coordinator)
        install.installAndRelaunch()
        coordinator.runPendingDecision()
        #expect(install.outcome == false)
        #expect(!coordinator.gateIsOpen)
        #expect(host.sessionEnds == [true], "the session's end may hide the app in menu bar mode")
        coordinator.cycleEnded()
        #expect(!coordinator.gateIsOpen)

        // The update offered again (a later check resumes the prepared
        // install with a new installer driver): asked again, and yes works.
        host.answer = .install
        let again = SparkleInstall(coordinator)
        again.installAndRelaunch()
        coordinator.runPendingDecision()
        #expect(host.asked.count == 2)
        #expect(again.outcome == true)
        #expect(coordinator.gateIsOpen)
    }

    @Test func theLossWarningAndOpenSystemSettings() {
        let host = FakeHost()
        host.context = Context(endingAtQuit: 1, lossSeen: true, localAtRisk: 3)
        host.answer = .openSystemSettings
        let coordinator = coordinator(host)
        let install = SparkleInstall(coordinator)
        install.installAndRelaunch()
        coordinator.runPendingDecision()
        #expect(host.asked == [.confirmLeavingSessions(atRisk: 3, ending: 1)])
        #expect(install.outcome == false)
        #expect(!coordinator.gateIsOpen)
        #expect(host.sessionEnds == [false], "System Settings is coming forward: do not hide")
        // The next session's end hides again.
        coordinator.updateSessionWillFinish()
        #expect(host.sessionEnds == [false, true])
    }

    @Test func noInstallWhileEndSessionsAndQuitRuns() {
        let host = FakeHost()
        host.context = Context(isEndingSessions: true, endingAtQuit: 2)
        let coordinator = coordinator(host)
        let install = SparkleInstall(coordinator)
        install.installAndRelaunch()
        coordinator.runPendingDecision()
        #expect(host.asked.isEmpty, "refused without a question")
        #expect(install.outcome == false)
        #expect(!coordinator.gateIsOpen)
    }

    @Test func aQuitStartedWhileTheAlertWasUpRefusesTheInstall() {
        let host = FakeHost()
        host.context = Context(endingAtQuit: 1)
        host.whileAsking = { host.context.isEndingSessions = true }
        let coordinator = coordinator(host)
        let install = SparkleInstall(coordinator)
        install.installAndRelaunch()
        coordinator.runPendingDecision()
        #expect(install.outcome == false)
        #expect(!coordinator.gateIsOpen)
    }

    /// The gate does not leak: an install that fails or is aborted after the
    /// yes, or a quit that never comes, leaves later quits ordinary.
    @Test func theGateDoesNotLeak() {
        let host = FakeHost()
        let clock = Clock()
        let coordinator = coordinator(host, clock: clock)

        // Aborted (an installer error) before Sparkle's relaunch notice.
        _ = coordinator.postponeRelaunch(resume: {})
        coordinator.runPendingDecision()
        coordinator.cycleEnded()
        coordinator.willRelaunch()
        #expect(!coordinator.gateIsOpen, "the yes went with the cycle")

        // Opened, then the cycle ended without the app quitting.
        var install = SparkleInstall(coordinator)
        install.installAndRelaunch()
        coordinator.runPendingDecision()
        #expect(coordinator.gateIsOpen)
        coordinator.cycleEnded()
        #expect(!coordinator.gateIsOpen)

        // Opened, and Sparkle's quit never came.
        install = SparkleInstall(coordinator)
        install.installAndRelaunch()
        coordinator.runPendingDecision()
        #expect(coordinator.gateIsOpen)
        clock.now = clock.now.addingTimeInterval(UpdateQuitGate.lifetime + 1)
        #expect(!coordinator.gateIsOpen)
    }

    /// A no is one-shot: if the declined cycle's end is never reported,
    /// the next attempt still asks instead of aborting at once.
    @Test func aNoIsOneShot() {
        let host = FakeHost()
        host.context = Context(endingAtQuit: 1)
        host.answer = .cancel
        let coordinator = coordinator(host)
        let first = SparkleInstall(coordinator)
        first.installAndRelaunch()
        coordinator.runPendingDecision()
        #expect(first.outcome == false)
        // No cycleEnded() here.
        host.answer = .install
        let second = SparkleInstall(coordinator)
        second.installAndRelaunch()
        #expect(second.outcome == nil, "postponed and asked, not aborted")
        coordinator.runPendingDecision()
        #expect(host.asked.count == 2)
        #expect(second.outcome == true)
        #expect(coordinator.gateIsOpen)
    }

    /// The gate is one-shot: the first quit that consults it closes it,
    /// whatever that quit's outcome (Sparkle's quit cancelled while End
    /// Sessions and Quit runs, say), so a ⌘Q a moment later asks.
    @Test func theGateIsOneShot() {
        let host = FakeHost()
        let coordinator = coordinator(host)
        #expect(!coordinator.takeQuitThrough(), "closed before any yes")
        let install = SparkleInstall(coordinator)
        install.installAndRelaunch()
        coordinator.runPendingDecision()
        #expect(install.outcome == true)
        #expect(coordinator.takeQuitThrough(), "Sparkle's quit")
        #expect(!coordinator.gateIsOpen)
        #expect(!coordinator.takeQuitThrough(), "the next quit is ordinary")
    }

    /// A relaunch notice without Armadale's yes (no postpone hook asked)
    /// opens nothing: that quit would get the usual question.
    @Test func noYesNoGate() {
        let host = FakeHost()
        let coordinator = coordinator(host)
        #expect(coordinator.shouldRelaunch())
        coordinator.willRelaunch()
        #expect(!coordinator.gateIsOpen)
    }

    @Test func withoutAHostTheInstallIsDeclined() {
        let coordinator = UpdateCoordinator(now: { Date() }, scheduleDecision: { _ in })
        let install = SparkleInstall(coordinator)
        install.installAndRelaunch()
        coordinator.runPendingDecision()
        #expect(install.outcome == false)
        #expect(!coordinator.gateIsOpen)
    }

    @Test func menuBarModeHoldsAScheduledUpdateForTheStatusMenu() {
        let host = FakeHost()
        let coordinator = coordinator(host)
        #expect(coordinator.driverShowsScheduledUpdate())
        host.isInMenuBarMode = true
        #expect(!coordinator.driverShowsScheduledUpdate())
        coordinator.willShowUpdate(shownByDriver: true)
        #expect(!coordinator.reminderPending)
        coordinator.willShowUpdate(shownByDriver: false)
        #expect(coordinator.reminderPending)
        coordinator.updateReceivedAttention()
        #expect(!coordinator.reminderPending)
        coordinator.willShowUpdate(shownByDriver: false)
        coordinator.updateSessionWillFinish()
        #expect(!coordinator.reminderPending)
        #expect(host.sessionEnds == [true])
        coordinator.checkScheduleChanged()
        #expect(host.settingsChanges == 1)
    }

    // MARK: Settings

    private final class FakeUpdater: AppUpdater {
        var started = 0
        var checks = 0
        var canCheckForUpdates = true
        var automaticallyChecksForUpdates = false

        func start() throws { started += 1 }
        func checkForUpdates() { checks += 1 }
    }

    @Test func updateSettingsFollowTheUpdater() {
        let settings = UpdateSettings()
        #expect(!settings.isOn)
        #expect(!settings.automaticallyChecks)
        settings.automaticallyChecks = true
        #expect(!settings.automaticallyChecks, "nothing to change without an updater")

        let updater = FakeUpdater()
        settings.attach(updater)
        #expect(settings.isOn)
        settings.automaticallyChecks = true
        #expect(updater.automaticallyChecksForUpdates)
        updater.automaticallyChecksForUpdates = false // Sparkle's question answered
        settings.refresh()
        #expect(!settings.automaticallyChecks)
    }

    // MARK: Sessions that end at a quit

    @Test func sessionsThatEndAtQuit() {
        let running = CloseRisk.Item(status: .running, mayExist: true, isRunning: true)
        let ended = CloseRisk.Item(status: .ended, mayExist: true, isRunning: false)
        let local = Session(profileID: Profile.shell.id, launch: LaunchSpec(), workingDirectory: "/")
        var persistent = local
        persistent.runtimeVersion = "0.8.1"
        var remote = local
        remote.location = .remote(host: HostID.generate())
        var remotePersistent = remote
        remotePersistent.runtimeVersion = "0.8.1"

        func ends(_ s: Session, _ r: CloseRisk.Item, plain: Bool = false, note: Bool = false) -> Bool {
            SessionRegistry.endsAtQuit(s, risk: r, isPlainLocal: plain, hasPersistenceNote: note)
        }
        #expect(ends(local, running, plain: true), "the plain PTY fallback")
        #expect(!ends(local, running, plain: false), "being created by the persistent runtime")
        #expect(!ends(local, ended, plain: true), "nothing running")
        #expect(!ends(persistent, running, plain: true), "made by the persistent runtime")
        #expect(ends(remote, running, note: true), "a host without the persistence helper")
        #expect(!ends(remote, running, note: false))
        #expect(!ends(remotePersistent, running, note: true))
    }

    // MARK: Menus and wording

    @Test func checkForUpdatesIsUnderAbout() throws {
        _ = NSApplication.shared
        let menu = MainMenu.make(installsSpecialMenus: false)
        let app = try #require(menu.items.first?.submenu)
        #expect(app.items[0].title.hasPrefix("About "))
        let item = app.items[1]
        #expect(item.title == "Check for Updates…")
        #expect(item.action == #selector(AppDelegate.checkForUpdates(_:)))
        #expect(item.target == nil, "nil-targeted, so it reaches the app delegate")
        #expect(item.keyEquivalent.isEmpty)
        #expect(MainMenu.isOwnItem(item))
        #expect(item.identifier?.rawValue.hasPrefix(MainMenu.ownItemPrefix) == true)
        #expect(app.items[2].isSeparatorItem)
    }

    private final class Target: NSObject {
        @objc func any(_ sender: Any?) {}
    }

    private func statusMenu(updateAvailable: Bool) -> NSMenu {
        let action = #selector(Target.any(_:))
        return MenuBarStatusItem.makeMenu(
            target: Target(),
            actions: MenuBarStatusItem.Actions(
                open: action, settings: action, quitKeepingSessions: action, endSessionsAndQuit: action,
                showUpdate: #selector(AppDelegate.showUpdateFromMenuBar(_:))),
            running: 1, sessionsSurviveQuit: true, updateAvailable: updateAvailable)
    }

    @Test func theStatusMenuOffersAWaitingUpdate() {
        let hidden = statusMenu(updateAvailable: false)
        #expect(!hidden.items.filter { !$0.isHidden }.map(\.title).contains("Update Available…"))
        let shown = statusMenu(updateAvailable: true)
        #expect(shown.items.filter { !$0.isHidden }.map(\.title) == [
            "1 session running", "Open Armadale", "Settings…", "Update Available…", "",
            "Quit, Keep Sessions Running", "End Sessions and Quit",
        ])
        let item = shown.items[3]
        #expect(item.action == #selector(AppDelegate.showUpdateFromMenuBar(_:)))
        #expect(item.isEnabled)
    }

    @Test func wording() {
        #expect(UpdateText.endingMessage(1) == "1 session will end when Armadale quits to update")
        #expect(UpdateText.endingMessage(3) == "3 sessions will end when Armadale quits to update")
        #expect(UpdateText.endingInformative(1).hasPrefix("It can’t keep running"))
        #expect(UpdateText.endingInformative(2).hasPrefix("They can’t keep running"))
        #expect(UpdateText.endingInformative(2).hasSuffix(UpdateText.laterNote))
        let leaving = UpdateText.leavingInformative(atRisk: 2, ending: 1)
        #expect(leaving.hasPrefix(BackgroundActivityText.quitInformative(atRisk: 2)))
        #expect(leaving.contains("1 other session will end anyway"))
        #expect(!UpdateText.leavingInformative(atRisk: 2, ending: 0).contains("other session"))
        #expect(UpdateText.whatACheckSends.contains("armadale.dev"))
        let all = [
            UpdateText.checkForUpdates, UpdateText.updateAvailable, UpdateText.settingsHeader,
            UpdateText.automaticChecks, UpdateText.whatACheckSends, UpdateText.offInThisRun,
            UpdateText.endingMessage(2), UpdateText.endingInformative(2), leaving, UpdateText.laterNote,
            UpdateText.installAndRelaunchButton, UpdateText.installAnywayButton, UpdateText.cancelButton,
        ]
        for text in all {
            #expect(!text.lowercased().contains("zmx"))
            #expect(!text.contains("Sparkle"), "the framework is an implementation detail")
        }
    }
}
