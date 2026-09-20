import Foundation
import UserNotifications

// MARK: - App icon badge
//
// The home-screen app-icon badge mirrors how many coding agents are paused
// waiting for an answer (the red `needsInput` tabs surfaced in "At a Glance"),
// so the count is visible without opening the app.

enum AppBadge {
    /// Headless screenshot runs on a simulator (no way to tap the permission
    /// alert away): `BROMURE_DEBUG_NO_PUSH_PROMPT=1` keeps the notification
    /// center untouched, so the system alert never comes up. Debug builds only.
    private static let silenced: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["BROMURE_DEBUG_NO_PUSH_PROMPT"] == "1"
        #else
        return false
        #endif
    }()

    /// Ask once for badge permission (also alert/sound, so notifications can be
    /// added later). Safe to call every launch — the system only prompts once.
    static func requestAuthorization() {
        guard !silenced else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.badge, .alert, .sound]) { _, _ in }
    }

    /// Set the app-icon badge to `count` (0 clears it). No-op failure if badge
    /// permission was denied.
    static func set(_ count: Int) {
        guard !silenced else { return }
        UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }
}
