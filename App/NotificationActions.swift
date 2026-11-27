import SwiftUI
import UserNotifications

@MainActor final class NotificationNavigation: ObservableObject {
    enum Destination: Equatable {
        case calendar, reminders, gift(String)
    }
    static let shared = NotificationNavigation()
    @Published var pending: Destination?
}

final class NotificationActions: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let done = UNNotificationAction(identifier: "complete", title: "Выполнено")
        let later = UNNotificationAction(identifier: "snooze", title: "Через 10 минут")
        center.setNotificationCategories([UNNotificationCategory(identifier: "MYCOMPANION_TASK",
            actions: [done, later], intentIdentifiers: [])])
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        NoticeDelivery.enabled ? [.banner, .list] : []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let id = response.notification.request.identifier
            let destination: NotificationNavigation.Destination
            if id.hasPrefix("companion.calendar.") { destination = .calendar }
            else if content.categoryIdentifier == "MYCOMPANION_TASK" { destination = .reminders }
            else if content.categoryIdentifier == "companion.gift", id.hasPrefix("companion.gift.") {
                destination = .gift(String(id.dropFirst("companion.gift.".count)))
            }
            else { return }
            await MainActor.run { NotificationNavigation.shared.pending = destination }
            return
        }
        guard content.categoryIdentifier == "MYCOMPANION_TASK",
              let rawID = content.userInfo["taskID"] as? String,
              let id = UUID(uuidString: rawID),
              let revision = content.userInfo["revision"] as? Int else { return }
        let delay: Int?
        switch response.actionIdentifier {
        case "complete": delay = nil
        case "snooze": delay = 10
        default: return
        }
        do {
            try await ReminderNotifications.shared.apply(id: id, revision: revision, snoozeMinutes: delay)
        } catch {
            // A stale notification must never change a newer revision.
            NSLog("Не удалось обработать действие напоминания")
        }
    }
}
