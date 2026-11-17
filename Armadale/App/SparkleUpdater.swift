import AppKit
import os
import Sparkle

/// The updater (docs/DESIGN.md section 8, "Updates"): Sparkle's `SPUUpdater`
/// with its standard user interface. The only file that imports Sparkle;
/// it is kept out of `ArmadaleAppTests` (which does not link the framework),
/// and every decision is the ``UpdateCoordinator``'s, which the tests drive.
///
/// Isolation: `SPUUpdater`, `SPUStandardUserDriver` and `SPUUpdaterDelegate`
/// are main-actor in Swift (`NS_SWIFT_UI_ACTOR`). `SPUStandardUserDriverDelegate`
/// is not annotated, but the standard user driver calls it on the main
/// thread only (it asserts `NSThread.isMainThread` throughout), so the
/// conformance is `@preconcurrency`: Swift checks that at run time instead
/// of assuming it.
@MainActor
final class SparkleUpdater: NSObject, AppUpdater {
    private let coordinator: UpdateCoordinator
    private var userDriver: SPUStandardUserDriver?
    private var updater: SPUUpdater?
    private let log = Logger(subsystem: "com.tinylittleapps.armadale", category: "updates")

    init(coordinator: UpdateCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    /// Makes the user driver and the updater (both keep their delegates
    /// weakly; the app delegate keeps this object) and starts it.
    func start() throws {
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: self)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        try updater.start()
        userDriver = driver
        self.updater = updater
    }

    var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }

    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }
}

extension SparkleUpdater: SPUUpdaterDelegate {
    /// Called once per install, when the user chose Install and Relaunch
    /// (SPUInstallerDriver's `_postponedOnce`): Armadale decides on the next
    /// turn and then calls `installHandler`.
    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        coordinator.postponeRelaunch(resume: installHandler)
    }

    /// False aborts the install (SPUInstallerDriver's `mayUpdateAndRestart`).
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        coordinator.shouldRelaunch()
    }

    /// Just before Sparkle tells its installer to go on and quit Armadale.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        log.notice("Armadale: an update will be installed; Armadale quits and relaunches")
        coordinator.willRelaunch()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        log.notice("Armadale: update session ended: \(String(describing: error), privacy: .public)")
        coordinator.cycleEnded()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        coordinator.cycleEnded()
    }

    /// No system profile, even if `SUSendProfileInfo` were set in the
    /// defaults: Sparkle keeps only the profile entries whose keys are in
    /// this list (SPUUpdater.m 1299–1315), so an empty one leaves no
    /// parameter, and with no parameter the feed URL is used as it is
    /// (1270–1278).
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        []
    }

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        coordinator.checkScheduleChanged()
    }

    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        coordinator.checkScheduleChanged()
    }
}

extension SparkleUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    /// Sparkle's gentle reminders: in menu bar mode a scheduled check's
    /// update opens no window; the status menu offers it.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        coordinator.driverShowsScheduledUpdate()
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        coordinator.willShowUpdate(shownByDriver: handleShowingUpdate)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        coordinator.updateReceivedAttention()
    }

    func standardUserDriverWillFinishUpdateSession() {
        coordinator.updateSessionWillFinish()
    }
}
