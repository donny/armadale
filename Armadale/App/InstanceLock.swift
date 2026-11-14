import AppKit
import ArmadaleCore

/// What the launch does about the state directory's lock (docs/DESIGN.md
/// section 8, "App lifecycle"; the lock itself is ``StateLock``). Only a
/// lock held by another process stops a launch; one that cannot be taken
/// at all is logged and the app runs as it did before the lock existed.
enum InstanceLock {
    /// A launch that must not go on: another process owns the state
    /// directory.
    struct Refusal: Equatable {
        /// The alert.
        var message: String
        var details: String
        /// For the log and standard error (may name internals; never shown
        /// in the alert).
        var logLine: String
        /// The other process, as its lock file records it.
        var otherPID: pid_t?
    }

    /// `nil` when the launch goes on: the lock was taken, or could not be
    /// taken for a reason other than another process holding it.
    static func refusal(for outcome: StateLock.Outcome, stateDirectory: URL) -> Refusal? {
        guard case .heldByAnotherProcess(let pid) = outcome else { return nil }
        let holder = pid.map { "another Armadale process (pid \($0))" } ?? "another Armadale process"
        return Refusal(
            message: "Armadale is already running",
            details: "Another copy of Armadale is using the same saved layout and sessions, in "
                + "\(stateDirectory.path). It may be running in the menu bar. This copy will quit, "
                + "so that the two don’t overwrite each other’s layout.",
            logLine: "Armadale: \(holder) holds the lock on \(StateLock.lockFile(in: stateDirectory).path); "
                + "quitting. Set \(StateLocation.overrideVariable) to run a separate copy.",
            otherPID: pid)
    }

    /// The log line for a lock that could not be taken at all, or `nil`.
    static func unavailableLogLine(for outcome: StateLock.Outcome) -> String? {
        guard case .unavailable(let reason) = outcome else { return nil }
        return "Armadale: no lock on the state directory (\(reason)); running without one"
    }

    /// Whether the other copy should be brought forward after the alert:
    /// only a running Armadale (same bundle identifier, so a recycled pid
    /// is never activated) that is not this process and is a regular app.
    /// One in menu bar mode (accessory) is left alone: activating it with
    /// its windows hidden would leave keystrokes going nowhere.
    static func shouldBringForward(
        pid: pid_t?, ownPID: pid_t, bundleIdentifier: String?, ownBundleIdentifier: String?,
        activationPolicy: NSApplication.ActivationPolicy?
    ) -> Bool {
        guard let pid, pid != ownPID, let bundleIdentifier, bundleIdentifier == ownBundleIdentifier else { return false }
        return activationPolicy == .regular
    }

    /// Best effort, after the alert: activates the copy that holds the
    /// lock, if ``shouldBringForward(pid:ownPID:bundleIdentifier:ownBundleIdentifier:activationPolicy:)``.
    @MainActor
    static func bringForward(pid: pid_t?) {
        let other = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        guard let other, shouldBringForward(
            pid: pid, ownPID: getpid(), bundleIdentifier: other.bundleIdentifier,
            ownBundleIdentifier: Bundle.main.bundleIdentifier, activationPolicy: other.activationPolicy)
        else { return }
        NSApp.yieldActivation(to: other)
        other.activate()
    }
}
