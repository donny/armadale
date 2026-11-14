import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation
import os
import UserNotifications

/// Attention and notifications (docs/DESIGN.md section 10): focus
/// tracking for ``AttentionCenter``, the Dock badge and the notification
/// centre's delegate.
extension AppDelegate {
    /// The Dock badge follows the attention total; a revealed session's
    /// window comes forward.
    func wireAttention() {
        registry.attention = attention
        attention.onBadgeChange = { label in
            NSApp.dockTile.badgeLabel = label
        }
        attention.showWorkspace = { [weak self] id in
            self?.showWorkspace(id)
        }
        // A badge set before macOS allowed one is not shown: set it again.
        notifications.onAuthorized = { [weak self] in
            guard let self else { return }
            NSApp.dockTile.badgeLabel = AttentionBadge.label(total: self.attention.total)
        }
    }

    /// Keeps ``AttentionCenter/isAppActive`` and
    /// ``AttentionCenter/keyWorkspaceID`` current, so a bell in the pane
    /// being looked at never sets attention, and looking at a pane clears it.
    func observeFocus() {
        let center = NotificationCenter.default
        let update: @MainActor (Notification.Name, NSWindow?) -> Void = { [weak self] name, window in
            guard let self else { return }
            self.attention.isAppActive = NSApp.isActive
            if name == NSWindow.didResignKeyNotification {
                // Key moves to another window next (did-become-key follows);
                // nil until then. NSApp.keyWindow still covers a sheet of
                // the same window taking over.
                if let window, self.workspaceID(of: window) == self.attention.keyWorkspaceID {
                    self.attention.keyWorkspaceID = NSApp.keyWindow.flatMap { $0 === window ? nil : self.workspaceID(of: $0) }
                }
            } else {
                self.attention.keyWorkspaceID = NSApp.keyWindow.flatMap { self.workspaceID(of: $0) }
            }
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            focusObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let name = notification.name
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    update(name, window)
                }
            })
        }
        attention.isAppActive = NSApp.isActive
        attention.keyWorkspaceID = NSApp.keyWindow.flatMap { workspaceID(of: $0) }
    }

    /// The workspace of `window`, or of the window it is a sheet of (a
    /// sheet, such as a close confirmation, takes key status from its
    /// window, whose focused pane is still the one being looked at).
    private func workspaceID(of window: NSWindow) -> WorkspaceID? {
        let owner = Self.sheetOwner(of: window)
        return windowControllers.first { $0.value.window === owner }?.key
    }

    /// The window a sheet (or a sheet of a sheet) is attached to; `window`
    /// itself if it is not a sheet.
    static func sheetOwner(of window: NSWindow) -> NSWindow {
        var owner = window
        while let parent = owner.sheetParent { owner = parent }
        return owner
    }

    /// A click on a notification: the session's pane, if it still exists;
    /// otherwise just the app. Either leaves menu bar mode (revealing a
    /// pane opens its window, which does).
    fileprivate func openNotification(for session: SessionID?) {
        if let session, attention.reveal(session) { return }
        if menuBarItem != nil {
            openFromMenuBar(nil)
        } else {
            NSApp.activate()
        }
    }
}

// MARK: - Notifications

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Clicking a notification brings its session forward (routed by the
    /// session ID in `userInfo`; a session that no longer exists only
    /// activates the app).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let session = AttentionNotification.sessionID(fromUserInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            self.openNotification(for: session)
        }
        completionHandler()
    }

    /// Shown while Armadale is active too (the pane is elsewhere, another
    /// tab or window, which is why it was posted), unless the user is
    /// looking at that session by the time it would appear.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let session = AttentionNotification.sessionID(fromUserInfo: notification.request.content.userInfo)
        let present = await MainActor.run { self.attention.shouldPresent(session) }
        return present ? [.banner, .list, .sound] : []
    }
}
