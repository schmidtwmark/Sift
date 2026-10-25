import Foundation
import SiftKit
import UserNotifications

/// Local notifications and the app-icon badge. Both are off unless a sender
/// opts in, and permission is only requested the first time one does.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    /// Called with the thread id when an alert is clicked.
    var onOpen: ((String) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let threadId = response.notification.request.content.userInfo["threadId"] as? String else { return }
        await MainActor.run { onOpen?(threadId) }
    }

    /// Senders you asked to hear from still alert while Sift is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func requestAuthorization() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func post(_ messages: [MessageRecord]) async {
        guard !messages.isEmpty else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        for message in messages {
            let content = UNMutableNotificationContent()
            content.title = message.fromName?.isEmpty == false ? message.fromName! : message.fromEmail
            content.subtitle = message.subject
            content.body = message.preview
            content.threadIdentifier = message.threadId
            content.sound = .default
            content.userInfo = ["threadId": message.threadId]
            try? await center.add(UNNotificationRequest(identifier: message.id, content: content, trigger: nil))
        }
    }

    func setBadge(_ count: Int) {
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || count == 0 else { return }
            try? await center.setBadgeCount(count)
        }
    }
}
