import AppKit
import ArmadaleCore
import UserNotifications

/// Posts ``AttentionNotification``s through UserNotifications. Permission is
/// asked for lazily, the first time a session needs attention (or a
/// notification would be posted), never at launch; once the user has answered, macOS remembers it, and a
/// notification posted while permission is denied is dropped. Each
/// session's notification replaces its previous one (same identifier), so
/// Notification Center keeps one per session.
///
/// The permission asked for includes badges. Verified on macOS 27: once an
/// app has registered with UserNotifications, its Dock badge
/// (`NSDockTile.badgeLabel`, ``AttentionCenter``'s count) only shows while
/// System Settings › Notifications › <app> › "Badge application icon" is on
/// (an unregistered process's badge always shows). ``onAuthorized`` lets
/// the app set the badge again when permission arrives.
///
/// Never made in tests: UserNotifications needs the app's bundle.
@MainActor
final class UserNotificationService: NotificationService {
    private let center: UNUserNotificationCenter
    /// The permission request in flight, so concurrent posts ask once.
    private var request: Task<Bool, Never>?
    /// Called whenever a post finds permission granted (cheap to repeat).
    var onAuthorized: () -> Void = {}
    private var hasReportedDenial = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() {
        Task { [weak self] in
            guard let self, await self.isAuthorized() else { return }
            self.onAuthorized()
        }
    }

    func withdraw(_ sessions: Set<SessionID>) {
        guard !sessions.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: sessions.map(Self.identifier))
    }

    /// One notification per session: a newer one replaces it.
    static func identifier(for session: SessionID) -> String {
        "attention." + session.raw
    }

    func post(_ notification: AttentionNotification) {
        Task { [weak self] in
            guard let self, await self.isAuthorized() else { return }
            self.onAuthorized()
            self.add(notification)
        }
    }

    private func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            if let request { return await request.value }
            let center = center
            let task = Task<Bool, Never> {
                do {
                    return try await center.requestAuthorization(options: [.alert, .sound, .badge])
                } catch {
                    NSLog("Armadale: notification permission request failed: %@", String(describing: error))
                    return false
                }
            }
            request = task
            let granted = await task.value
            request = nil
            return granted
        case .denied:
            if !hasReportedDenial {
                hasReportedDenial = true
                NSLog("Armadale: notifications are not allowed for Armadale (System Settings › Notifications)")
            }
            return false
        @unknown default:
            return false
        }
    }

    private func add(_ notification: AttentionNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.userInfo = notification.userInfo
        content.threadIdentifier = notification.sessionID.raw
        if notification.playsSound { content.sound = .default }
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: notification.sessionID), content: content, trigger: nil)
        center.add(request) { error in
            if let error { NSLog("Armadale: could not post a notification: %@", String(describing: error)) }
        }
    }
}
