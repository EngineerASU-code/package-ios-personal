import DeviceActivity
import FamilyControls
import Foundation
import UserNotifications
import WidgetKit

final class ScreenTimeMonitor: DeviceActivityMonitor {
    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard activity == ScreenTimePolicy.activity else { return }
        Task { @MainActor in
            let now = Date()
            guard AuthorizationCenter.shared.authorizationStatus == .approved,
                  ScreenTimePolicy.rule?.eventID == event.rawValue, let policy = ScreenTimePolicy.delivery,
                  !policy.paused
            else { return }

            let night = policy.isNight(now)
            if night {
                guard (try? ScreenTimePolicy.recordNightEvent(eventID: event.rawValue, at: now)) == true else { return }
                WidgetCenter.shared.reloadTimelines(ofKind: "Companion")
            }
            guard policy.permits(now) else { return }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard AuthorizationCenter.shared.authorizationStatus == .approved,
                  ScreenTimePolicy.rule?.eventID == event.rawValue, let current = ScreenTimePolicy.delivery,
                  current.permits(now),
                  settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            else { return }
            let content = UNMutableNotificationContent()
            content.title = "Экранное время"
            content.body = night ? ScreenTimePolicy.nightLine(heroID: current.heroID)
                                 : "Достигнут выбранный дневной порог. Можно сделать перерыв."
            content.interruptionLevel = .passive
            let noticeID = night ? ScreenTimePolicy.nightNotificationID : ScreenTimePolicy.notificationID
            try? await center.add(UNNotificationRequest(identifier: noticeID,
                                                        content: content, trigger: nil))
        }
    }
}
