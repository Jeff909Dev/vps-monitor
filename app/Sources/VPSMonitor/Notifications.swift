import Foundation
import MonitorCore
import UserNotifications

/// Posts the Monitor's notifications. Permission is asked the first time there is something to post, so turning
/// notifications off means macOS never asks. UserNotifications crashes outside an app bundle (`swift run`), so there
/// it posts nothing.
struct NotificationPoster: Sendable {
    private let enabled: Bool

    static func make() -> NotificationPoster {
        NotificationPoster(enabled: Bundle.main.bundleIdentifier != nil)
    }

    func post(_ events: [NotificationEvent]) {
        guard enabled, !events.isEmpty else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { Self.add(events) }
        }
    }

    private static func add(_ events: [NotificationEvent]) {
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id, content: content,
                                                                         trigger: nil))
        }
    }
}
