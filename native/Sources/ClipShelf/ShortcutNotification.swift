import UserNotifications
import ClipShelfLocalization

enum ShortcutNotification {
    /// Respect existing notification permission. The menu warning and diagnostic
    /// remain available when notifications are denied; never interrupt startup with a permission prompt.
    static func postIfAuthorized(_ message: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = L10n.text("ClipShelf 快捷键")
            content.body = message
            try? await center.add(UNNotificationRequest(identifier: "clipshelf-shortcut-status", content: content, trigger: nil))
        }
    }
}
