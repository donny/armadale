import AppKit
import ArmadaleCore
import Observation

/// The updater as the rest of the app sees it (docs/DESIGN.md section 8,
/// "Updates"). The real one is `SparkleUpdater` (App/SparkleUpdater.swift,
/// the one file that imports Sparkle, kept out of the test bundle); the
/// tests use a fake. Every callback Sparkle makes goes through an
/// ``UpdateCoordinator``, which holds the decisions.
@MainActor
protocol AppUpdater: AnyObject {
    /// Starts the updater: the scheduled checks, and Sparkle's one question
    /// about automatic checks at the second launch. Throws when Sparkle
    /// refuses to start (it then never checks in this run).
    func start() throws
    /// Whether Check for Updates… can run now.
    var canCheckForUpdates: Bool { get }
    /// A check the user asked for; while an update is already being shown,
    /// it brings that update's window forward instead.
    func checkForUpdates()
    /// Settings › General › "Check for updates automatically", kept by
    /// Sparkle in the app's own defaults domain.
    var automaticallyChecksForUpdates: Bool { get set }
}

/// Whether this run starts the updater (docs/DESIGN.md section 8,
/// "Updates"). Pure, tested as a table.
enum UpdaterPolicy {
    enum Verdict: Equatable, Sendable {
        case start
        case off(Reason)
    }

    enum Reason: String, Equatable, Sendable {
        /// A fatal or locked-out launch: it only explains and quits.
        case fatalLaunch
        /// Info.plist has no `SUPublicEDKey`: no update could be verified.
        case noPublicKey
        /// Info.plist has no `SUFeedURL`.
        case noFeed
        /// A Debug build (Run in Xcode, the gate's build, a DerivedData copy
        /// started from the Dock or Finder without the isolation variables),
        /// without ``testVariable``: it would write Sparkle's settings into
        /// the real defaults domain and could offer to replace itself.
        case debugBuild
        /// `ARMADALE_STATE_DIR` or a defaults suite is set (Run in Xcode,
        /// test builds, `scripts/check-quit.sh`), without ``testVariable``.
        case isolatedRun
    }

    /// Set to `1` (in a test copy's `LSEnvironment`) to start the updater
    /// in a Debug build and in an isolated run, for the live test of a
    /// real update. It lifts those two only, never a missing key or feed or
    /// a fatal launch.
    static let testVariable = "ARMADALE_UPDATER_FOR_TEST"

    /// Whether this build is a Debug build: the one place that reads
    /// `DEBUG`, passed into ``verdict(launchIsFatal:isDebugBuild:info:environment:arguments:)``.
    static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    static func verdict(
        launchIsFatal: Bool, isDebugBuild: Bool, info: [String: Any], environment: [String: String],
        arguments: [String]
    ) -> Verdict {
        if launchIsFatal { return .off(.fatalLaunch) }
        guard let key = info["SUPublicEDKey"] as? String, !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .off(.noPublicKey)
        }
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty else { return .off(.noFeed) }
        let forTest = environment[testVariable] == "1"
        if isDebugBuild, !forTest { return .off(.debugBuild) }
        let isolated = !(environment[StateLocation.overrideVariable] ?? "").isEmpty
            || Preferences.suiteName(environment: environment, arguments: arguments) != nil
        if isolated, !forTest { return .off(.isolatedRun) }
        return .start
    }
}

/// The quit Sparkle sends to install an update goes straight through
/// (``QuitDecision/Context/isUpdateQuit``) only while this gate is open:
/// from just before Sparkle sends it (`updaterWillRelaunchApplication`,
/// after Armadale said yes) until the first quit that consults it (one
/// shot, whatever that quit's outcome) or the end of the update cycle, and
/// never longer than ``lifetime``. So a later ⌘Q gets the usual question
/// even if Sparkle's quit never came or was cancelled.
struct UpdateQuitGate: Equatable, Sendable {
    /// Sparkle's quit follows within a second or two of the gate opening;
    /// this is the most it is waited for.
    static let lifetime: TimeInterval = 60

    private(set) var openedAt: Date?

    mutating func open(at time: Date) { openedAt = time }
    mutating func close() { openedAt = nil }

    /// Open, and opened no more than ``lifetime`` ago (a clock set back
    /// closes it).
    func letsQuitThrough(at now: Date) -> Bool {
        guard let openedAt else { return false }
        let age = now.timeIntervalSince(openedAt)
        return age >= 0 && age <= Self.lifetime
    }
}

/// The answer to the question before an update's quit.
enum UpdateQuitAnswer: Equatable, Sendable {
    case install
    case cancel
    /// Cancel, and System Settings opened at Login Items & Extensions.
    case openSystemSettings
}

/// What the coordinator needs from the app delegate.
@MainActor
protocol UpdateHost: AnyObject {
    /// Where the app is, for ``UpdateQuitDecision/decide(_:)``.
    func updateQuitContext() -> UpdateQuitDecision.Context
    /// Shows the alert for a ``UpdateQuitDecision/confirmEnding(sessions:)``
    /// or ``UpdateQuitDecision/confirmLeavingSessions(atRisk:ending:)`` and
    /// returns the answer.
    func askBeforeUpdateQuit(_ decision: UpdateQuitDecision) -> UpdateQuitAnswer
    /// In menu bar mode, a scheduled check's update opens no window.
    var isInMenuBarMode: Bool { get }
    /// An update session ended and its windows closed. `mayHide` is false
    /// right after the answer Open System Settings.
    func updateSessionEnded(mayHide: Bool)
    /// Sparkle's automatic-check setting may have changed.
    func updateSettingsChanged()
}

/// Between Sparkle's callbacks and the app (docs/DESIGN.md section 8,
/// "Updates"): the decision before an update's quit, the gate that lets
/// that quit through, and the menu bar reminder. Free of Sparkle so the
/// tests drive it as Sparkle would.
///
/// An install goes: the user clicks Install and Relaunch → Sparkle asks
/// ``postponeRelaunch(resume:)`` (once per install) → on the next run-loop
/// turn ``runPendingDecision()`` decides, asking if it must, and calls
/// `resume` either way. Yes: Sparkle asks ``shouldRelaunch()`` (true),
/// calls ``willRelaunch()`` (the gate opens) and sends its quit. No:
/// ``shouldRelaunch()`` answers false, which makes Sparkle abort the
/// session (its windows close; the installer, already prepared, waits and
/// installs when Armadale next quits, without relaunching it). Either way
/// ``cycleEnded()`` closes the gate when the cycle ends.
@MainActor
final class UpdateCoordinator {
    weak var host: (any UpdateHost)?
    private(set) var gate = UpdateQuitGate()
    /// The user (or nothing to tell) said yes to the install under way.
    private var approved = false
    /// The user said no: the next ``shouldRelaunch()`` answers false, once.
    private var declined = false
    /// Sparkle's install handler, waiting for ``runPendingDecision()``.
    private var pendingResume: (() -> Void)?
    /// A scheduled check found an update while in menu bar mode and its
    /// window was not shown: the status menu offers Update Available….
    private(set) var reminderPending = false
    /// The last answer was Open System Settings: the session's end must not
    /// hide the app (System Settings is coming forward).
    private var openedSystemSettings = false

    private let now: @MainActor () -> Date
    private let scheduleDecision: @MainActor (UpdateCoordinator) -> Void

    /// `scheduleDecision` runs ``runPendingDecision()`` later; by default on
    /// the next turn of the run loop in its default mode, outside the
    /// main-queue block Sparkle calls from, so the alert's modal session
    /// does not hold up the main queue (and the main actor's tasks).
    init(
        now: @escaping @MainActor () -> Date = { Date() },
        scheduleDecision: @escaping @MainActor (UpdateCoordinator) -> Void = UpdateCoordinator.onNextTurn
    ) {
        self.now = now
        self.scheduleDecision = scheduleDecision
    }

    static func onNextTurn(_ coordinator: UpdateCoordinator) {
        RunLoop.main.perform(inModes: [.default]) { [weak coordinator] in
            MainActor.assumeIsolated { coordinator?.runPendingDecision() }
        }
    }

    // MARK: The update's quit

    /// Sparkle's `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`:
    /// always postpones, to decide on the next turn.
    func postponeRelaunch(resume: @escaping () -> Void) -> Bool {
        approved = false
        declined = false
        openedSystemSettings = false
        pendingResume = resume
        scheduleDecision(self)
        return true
    }

    /// Decides (``UpdateQuitDecision``), asking when there is something to
    /// tell, then lets Sparkle go on.
    func runPendingDecision() {
        guard let resume = pendingResume else { return }
        pendingResume = nil
        var install = false
        if let host {
            let decision = UpdateQuitDecision.decide(host.updateQuitContext())
            switch decision {
            case .install:
                install = true
            case .refuse:
                install = false
            case .confirmEnding, .confirmLeavingSessions:
                let answer = host.askBeforeUpdateQuit(decision)
                install = answer == .install
                openedSystemSettings = answer == .openSystemSettings
                // Nothing may have started a quit meanwhile; check again.
                if install, UpdateQuitDecision.decide(host.updateQuitContext()) == .refuse { install = false }
            }
        }
        approved = install
        declined = !install
        resume()
    }

    /// Sparkle's `updaterShouldRelaunchApplication(_:)`: false aborts the
    /// install Sparkle is about to continue. A no is one-shot: Sparkle asks
    /// this before the postpone hook on every attempt
    /// (SPUInstallerDriver.m 515–519), so a no left standing (if the
    /// declined cycle's end were never reported) would abort the next
    /// install without a question.
    func shouldRelaunch() -> Bool {
        if declined {
            declined = false
            return false
        }
        return true
    }

    /// Sparkle's `updaterWillRelaunchApplication(_:)`, just before it sends
    /// its quit: the gate opens, if Armadale said yes.
    func willRelaunch() {
        if approved { gate.open(at: now()) }
        approved = false
    }

    /// Sparkle's `updater(_:didAbortWithError:)` and
    /// `updater(_:didFinishUpdateCycleFor:error:)`: whatever happened, a
    /// later quit is an ordinary one.
    func cycleEnded() {
        gate.close()
        approved = false
        declined = false
        pendingResume = nil
    }

    /// Whether the gate is open now, without consuming it (for tests and
    /// logs; the quit itself uses ``takeQuitThrough()``).
    var gateIsOpen: Bool { gate.letsQuitThrough(at: now()) }

    /// For ``AppDelegate/applicationShouldTerminate(_:)``, once per quit:
    /// whether the gate lets this quit through. It closes the gate either
    /// way, so only the first quit after Armadale's yes is the update's.
    func takeQuitThrough() -> Bool {
        let through = gate.letsQuitThrough(at: now())
        gate.close()
        return through
    }

    // MARK: Menu bar mode's reminder (Sparkle's gentle reminders)

    /// `standardUserDriverShouldHandleShowingScheduledUpdate`: Sparkle shows
    /// a scheduled check's update itself, except in menu bar mode.
    func driverShowsScheduledUpdate() -> Bool {
        !(host?.isInMenuBarMode ?? false)
    }

    /// `standardUserDriverWillHandleShowingUpdate`: when Sparkle does not
    /// show it, the status menu offers it.
    func willShowUpdate(shownByDriver: Bool) {
        if !shownByDriver { reminderPending = true }
    }

    /// `standardUserDriverDidReceiveUserAttention`.
    func updateReceivedAttention() {
        reminderPending = false
    }

    /// `standardUserDriverWillFinishUpdateSession`.
    func updateSessionWillFinish() {
        reminderPending = false
        let mayHide = !openedSystemSettings
        openedSystemSettings = false
        host?.updateSessionEnded(mayHide: mayHide)
    }

    /// `updater(_:willScheduleUpdateCheckAfterDelay:)`,
    /// `updaterWillNotScheduleUpdateCheck(_:)`: after Sparkle's question
    /// about automatic checks, or a change in Settings.
    func checkScheduleChanged() {
        host?.updateSettingsChanged()
    }
}

/// Settings › General › Updates: the checkbox and whether updates are on
/// in this run.
@MainActor
@Observable
final class UpdateSettings {
    /// The updater runs in this run (``UpdaterPolicy``, and it started).
    private(set) var isOn = false
    @ObservationIgnored private weak var updater: (any AppUpdater)?
    /// Bumped to make views read Sparkle's setting again.
    private var revision = 0

    func attach(_ updater: any AppUpdater) {
        self.updater = updater
        isOn = true
        revision += 1
    }

    var automaticallyChecks: Bool {
        get {
            _ = revision
            return updater?.automaticallyChecksForUpdates ?? false
        }
        set {
            guard let updater, updater.automaticallyChecksForUpdates != newValue else { return }
            updater.automaticallyChecksForUpdates = newValue
            revision += 1
        }
    }

    /// Sparkle's setting may have changed outside the view.
    func refresh() {
        revision += 1
    }
}

/// The user-visible wording about updates.
enum UpdateText {
    static let checkForUpdates = "Check for Updates…"
    /// The status menu's item while an update waits to be shown.
    static let updateAvailable = "Update Available…"

    static let settingsHeader = "Updates"
    static let automaticChecks = "Check for updates automatically"
    /// What a check sends: one GET of the feed, whose user agent names
    /// Armadale's version; no system profile, no added parameters
    /// (docs/DESIGN.md section 8, "Updates").
    static let whatACheckSends = "A check downloads the list of versions from armadale.dev. "
        + "Besides what every web request carries, it sends only the version of Armadale and of its updater."
    static let offInThisRun = "Updates are off in this run of Armadale."

    private static func sessions(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }

    /// Sessions that cannot outlive the update's quit.
    static func endingMessage(_ count: Int) -> String {
        "\(sessions(count)) will end when Armadale quits to update"
    }

    static func endingInformative(_ count: Int) -> String {
        (count == 1
            ? "It can’t keep running while Armadale is closed. "
            : "They can’t keep running while Armadale is closed. ")
            + laterNote
    }

    /// The loss warning before the update's quit (``BackgroundActivityText``'s
    /// question, with this sentence added).
    static func leavingInformative(atRisk: Int, ending: Int) -> String {
        var text = BackgroundActivityText.quitInformative(atRisk: atRisk)
        if ending > 0 {
            text += ending == 1
                ? " 1 other session will end anyway: it can’t keep running while Armadale is closed."
                : " \(ending) other sessions will end anyway: they can’t keep running while Armadale is closed."
        }
        return text + " " + laterNote
    }

    static let laterNote = "If you cancel, the update stays ready and is normally installed the next time Armadale quits."
    static let installAndRelaunchButton = "Install and Relaunch"
    static let installAnywayButton = "Install Anyway"
    static let cancelButton = "Cancel"
}
