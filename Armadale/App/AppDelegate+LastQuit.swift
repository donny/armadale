import AppKit
import ArmadaleCore
import ArmadaleSessions
import os
import ServiceManagement

/// Sessions macOS ends after a quit (docs/DESIGN.md section 8, "Background
/// App Activity"): with Armadale switched off under Background App
/// Activity, macOS ends every local session a few seconds after Armadale
/// quits, and no API reads that setting. So the app records what each quit
/// left running (``LastQuitRecord``), checks at the next launch whether
/// those sessions were ended by SIGTERM just after it (``LastQuitCheck``),
/// says so, and asks before the next quit from menu bar mode that would
/// leave sessions to the system.
extension AppDelegate {
    /// The record's store for a launch: `nil` when the launch does not use
    /// its state directory or may not save (a fatal or locked-out launch
    /// never reads, writes or removes the file). Internal for the tests.
    static func lastQuitStore(plan: LaunchPlan, canSave: Bool, stateDirectory: URL) -> LastQuitStore? {
        guard plan.usesStateDirectory, canSave else { return nil }
        return LastQuitStore(stateDirectory: stateDirectory)
    }

    /// At launch: reads the record (its `lossSeenAt` holds for this run)
    /// and runs the check on its quit when it is due
    /// (``LastQuitCheck/schedule(of:now:)``). Returns the number of sessions
    /// ended when the check ran now and found them, for the alert after the
    /// other launch alerts. A check not due yet (a relaunch within
    /// ``LastQuitCheck/delay`` of the quit) runs when it is, and then tells
    /// by itself, without bringing the app forward and with no button that
    /// answers Return; in menu bar mode it tells nothing.
    func startLastQuitCheck() -> Int? {
        guard let store = lastQuitStore, let record = store.read() else { return nil }
        lossSeenAt = record.lossSeenAt
        guard let quit = record.quit else { return nil }
        switch LastQuitCheck.schedule(of: quit, now: Date()) {
        case .now:
            return Self.endedCount(runLastQuitCheck(on: quit, store: store, ranLate: false))
        case .after(let delay):
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !self.isTerminating,
                      let ended = Self.endedCount(self.runLastQuitCheck(on: quit, store: store, ranLate: true))
                else { return }
                // Not inside another alert's modal session: in the default
                // mode only, so it waits until that alert is answered.
                RunLoop.main.perform(inModes: [.default]) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.isTerminating else { return }
                        // Decided once, when it would show: an accessory
                        // app's modal alert, shown while it is not active,
                        // may sit behind other windows, so nothing is shown
                        // in menu bar mode. `lossSeenAt` is set, so the quit
                        // asks.
                        guard self.menuBarItem == nil else {
                            stateLog.notice("Armadale: last quit check: loss not told (menu bar mode)")
                            return
                        }
                        self.showSessionsEndedAfterQuit(ended, late: true)
                    }
                }
            }
            return nil
        }
    }

    private static func endedCount(_ verdict: LastQuitCheck.Verdict) -> Int? {
        if case .ended(let count) = verdict { return count }
        return nil
    }

    /// Runs the check once on `quit` (``LastQuitCheck/run(on:store:runtime:previous:ranLate:bootTime:auditSessionID:)``),
    /// takes its `lossSeenAt` for this run, and logs the verdict and
    /// whether the check ran late.
    private func runLastQuitCheck(
        on quit: LastQuitRecord.Quit, store: LastQuitStore, ranLate: Bool
    ) -> LastQuitCheck.Verdict {
        let outcome = LastQuitCheck.run(
            on: quit, store: store, runtime: zmxRuntime, previous: lossSeenAt, ranLate: ranLate,
            bootTime: LoginSession.bootTime(), auditSessionID: LoginSession.auditSessionID())
        lossSeenAt = outcome.lossSeenAt
        if let error = outcome.writeError {
            stateLog.error("Armadale: could not update the last quit record: \(String(describing: error), privacy: .public)")
        }
        let summary = switch outcome.verdict {
        case .ended(let count): "ended (\(count))"
        case .survived: "survived"
        case .undetermined(let reason): "undetermined (\(reason.rawValue))"
        }
        let ended = Self.endedCount(outcome.verdict) ?? 0
        stateLog.notice(
            "Armadale: last quit check\(ranLate ? " (late)" : "", privacy: .public): \(summary, privacy: .public) after a \(quit.kind.rawValue, privacy: .public) quit, \(quit.sessions.count, privacy: .public) session(s) recorded, \(ended, privacy: .public) ended by SIGTERM")
        return outcome.verdict
    }

    /// The alert after a loss (``BackgroundActivityText/lossAlert(ended:late:)``):
    /// what happened and what makes macOS do it, with Open System Settings
    /// and Not Now (Escape). At launch Open System Settings is the default;
    /// a late one has no button that answers Return.
    func showSessionsEndedAfterQuit(_ ended: Int, late: Bool) {
        let content = BackgroundActivityText.lossAlert(ended: ended, late: late)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.message
        alert.informativeText = content.informative
        let open = alert.addButton(withTitle: content.buttons[0])
        let notNow = alert.addButton(withTitle: content.buttons[1])
        open.keyEquivalent = content.openSettingsKey
        notNow.keyEquivalent = content.notNowKey
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// At quit, with the state (``applicationWillTerminate(_:)``, only when
    /// the state may be saved): the quit taken in
    /// ``applicationShouldTerminate(_:)`` and the `lossSeenAt` of this run
    /// (``LastQuitRecord/atQuit(_:lossSeenAt:)``). A check still waiting
    /// for its time is dropped: this quit replaces the one it was for. A
    /// failure is logged, never shown.
    func writeLastQuitRecord() {
        guard let store = lastQuitStore, let quit = quitToRecord else { return }
        do {
            try store.write(LastQuitRecord.atQuit(quit, lossSeenAt: lossSeenAt))
        } catch {
            stateLog.error("Armadale: could not write the last quit record: \(String(describing: error), privacy: .public)")
        }
    }
}
